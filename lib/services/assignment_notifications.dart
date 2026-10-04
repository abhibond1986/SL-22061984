// lib/services/assignment_notifications.dart
//
// The app-wide state behind the bell icon in the top-right of every screen.
//
// WHAT COUNTS AS A NOTIFICATION
// Exactly the AssignmentInbox items (see assignment_inbox.dart for why these
// are derived from the incidents rather than stored):
//   * a case assigned to me (or re-assigned to me), and
//   * my own report, now that someone has been put on it.
// A notification disappears by itself when the case is closed or reassigned
// away, because it is recomputed from the incident every time.
//
// READ STATE
// Kept per account under `notif_read_<username>` — deliberately NOT the
// `assignment_seen_` set the dashboard uses. The dashboard marks everything
// seen the moment it renders, so sharing that set would empty the bell before
// the user ever saw it. Here an item stays unread until it is tapped or
// "Mark all read" is pressed.
//
// WHEN IT REFRESHES
//   * on start, and whenever RealtimeSync / a full sync bumps
//     [RealtimeSync.incidentsRevision] (an assignment made on another device),
//   * when the admin's status ladder changes ([AdminMasterData.revision]),
//   * right after an assignment is saved on this device (IncidentAssign),
//   * every [_pollEvery] as a fallback for when realtime is not connected.
//
// LIMIT: this is an in-app notification. A push to a phone whose app is closed
// needs FCM wired up plus a server-side trigger on `incidents.assigned_to`.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_master_data.dart';
import 'assignment_inbox.dart';
import 'local_db.dart';
import 'realtime_sync.dart';

@immutable
class NotificationState {
  /// Every current notification, worst-first (AssignmentInbox order).
  final List<AssignmentItem> items;

  /// `seenKey`s of the items not yet read.
  final Set<String> unread;

  /// Items that arrived during this session since the previous refresh.
  /// Empty on the first load of a session, so opening the app does not toast
  /// the whole backlog — the badge already shows it.
  final List<AssignmentItem> arrivals;

  /// Bumped whenever [arrivals] is non-empty; used to show each toast once.
  final int arrivalGen;

  const NotificationState({
    this.items = const [],
    this.unread = const {},
    this.arrivals = const [],
    this.arrivalGen = 0,
  });

  int get unreadCount => unread.length;
  bool isUnread(AssignmentItem i) => unread.contains(i.seenKey);
}

class AssignmentNotifications {
  AssignmentNotifications._();

  static const _pollEvery = Duration(seconds: 60);

  static final ValueNotifier<NotificationState> state =
      ValueNotifier(const NotificationState());

  static bool _started = false;
  static Timer? _timer;
  static String? _loadedFor; // username the current state belongs to
  static int _gen = 0; // discards superseded refreshes
  static bool _refreshQueued = false;

  /// Overridable for tests (no LocalDB / master data in a widget test).
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function() userLoader =
      LocalDB.getCurrentUser;
  @visibleForTesting
  static Future<List<Map<String, dynamic>>> Function() incidentLoader =
      LocalDB.getIncidents;
  @visibleForTesting
  static Future<Set<String>> Function() openStatusLoader =
      AdminMasterData.getOpenStatuses;

  static String _readKey(String username) =>
      'notif_read_${username.trim().toLowerCase()}';

  /// Idempotent. Called by the first bell that mounts.
  static void start() {
    if (_started) return;
    _started = true;
    RealtimeSync.incidentsRevision.addListener(_onChange);
    AdminMasterData.revision.addListener(_onChange);
    _timer = Timer.periodic(_pollEvery, (_) => refresh());
    refresh();
  }

  static void _onChange() {
    // A sync bumps these several times in a row; coalesce into one reload.
    if (_refreshQueued) return;
    _refreshQueued = true;
    Future.delayed(const Duration(milliseconds: 300), () {
      _refreshQueued = false;
      refresh();
    });
  }

  @visibleForTesting
  static void resetForTest() {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      RealtimeSync.incidentsRevision.removeListener(_onChange);
      AdminMasterData.revision.removeListener(_onChange);
    }
    _started = false;
    _loadedFor = null;
    state.value = const NotificationState();
  }

  /// Recompute from the incidents on this device.
  static Future<void> refresh() async {
    final gen = ++_gen;
    try {
      final user = await userLoader();
      final username = user?['username']?.toString().trim().toLowerCase() ?? '';
      if (username.isEmpty) {
        if (gen == _gen) {
          _loadedFor = null;
          state.value = const NotificationState();
        }
        return;
      }
      // Built from the UNSCOPED list, same as the dashboard inbox: a job given
      // to you from another plant is still your job.
      final incidents = await incidentLoader();
      final open = await openStatusLoader();
      final items = AssignmentInbox.build(
          user: user, incidents: incidents, openStatuses: open);

      final prefs = await SharedPreferences.getInstance();
      final read = (prefs.getStringList(_readKey(username)) ?? const []).toSet();
      if (gen != _gen) return;

      final keys = items.map((i) => i.seenKey).toSet();
      final unread = keys.difference(read);

      // New arrivals = unread keys we did not have last time, same account.
      final prev = state.value;
      final sameUser = _loadedFor == username;
      final prevKeys = prev.items.map((i) => i.seenKey).toSet();
      final arrivals = sameUser
          ? items
              .where((i) => unread.contains(i.seenKey) && !prevKeys.contains(i.seenKey))
              .toList()
          : const <AssignmentItem>[];

      // Keep the read-set from growing forever: drop keys for items that no
      // longer exist (closed / reassigned). Skipped when nothing loaded, so an
      // empty cache during start-up cannot wipe the user's read history.
      if (incidents.isNotEmpty && !read.every(keys.contains)) {
        await prefs.setStringList(
            _readKey(username), read.intersection(keys).toList());
      }

      _loadedFor = username;
      state.value = NotificationState(
        items: items,
        unread: unread,
        arrivals: arrivals,
        arrivalGen: arrivals.isEmpty ? prev.arrivalGen : prev.arrivalGen + 1,
      );
    } catch (e) {
      debugPrint('[AssignmentNotifications] refresh failed: $e');
    }
  }

  static Future<void> _setRead(Iterable<String> keys) async {
    final username = _loadedFor;
    if (username == null) return;
    final prefs = await SharedPreferences.getInstance();
    final read = (prefs.getStringList(_readKey(username)) ?? const []).toSet()
      ..addAll(keys);
    await prefs.setStringList(_readKey(username), read.toList());
    final s = state.value;
    state.value = NotificationState(
      items: s.items,
      unread: s.unread.difference(keys.toSet()),
      arrivals: const [],
      arrivalGen: s.arrivalGen,
    );
  }

  static Future<void> markRead(AssignmentItem item) => _setRead([item.seenKey]);

  static Future<void> markAllRead() =>
      _setRead(state.value.items.map((i) => i.seenKey));
}
