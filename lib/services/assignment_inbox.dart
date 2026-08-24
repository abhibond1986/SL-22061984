// lib/services/assignment_inbox.dart
// SAIL Safety Lens — "what has been handed to me" for the dashboard.
//
// When a supervisor assigns a hazard or near-miss investigation on the incident
// detail screen, the person receiving it had no way of finding out: nothing in
// the app told them, and the case looked like any other row in a list. They
// learned about it when somebody phoned them.
//
// WHY THIS IS DERIVED, NOT STORED
// There is no notifications table and this file deliberately does not add one.
// A stored notification is a copy of the truth that immediately starts rotting:
// reassign the case and the old recipient still has the message; close it and
// the message still says "action required". The assignment already lives on the
// incident (`assignedTo`, `assignedToName`, `assignedAt`), so the inbox is
// computed from the incidents the device already holds. That makes it correct by
// construction, works offline, needs no migration, and cannot drift.
//
// The only thing persisted is which items the user has already been shown, so
// "NEW" can mean something. That is per-account and is a set of ids — losing it
// costs a badge, not a job.
//
// SCOPE NOTE — read this before changing the matching.
// Two different identities are in play. Assignment is recorded as a USERNAME
// (for imported employees that is their SAIL P.no, lower-cased). Reporting is
// recorded as a NAME plus a P.no, because a report can be filed before anyone
// knows the reporter's account. So "assigned to me" matches on username and
// "my report" matches on P.no — they are not interchangeable.

import 'package:shared_preferences/shared_preferences.dart';

/// Why an item is in someone's inbox.
enum AssignmentKind {
  /// I have to investigate this.
  assignedToMe,

  /// I reported this and somebody has now been put on it. Informational: it
  /// closes the loop for the reporter, who otherwise never hears anything back.
  myReportAssigned,
}

class AssignmentItem {
  final Map<String, dynamic> incident;
  final AssignmentKind kind;

  const AssignmentItem(this.incident, this.kind);

  String get id => incident['id']?.toString() ?? '';

  /// Stable key for the seen-set. Includes the kind because the same incident
  /// can legitimately appear for one person as a job and for another as news,
  /// and because a reassignment should re-notify.
  String get seenKey {
    final who = incident['assignedTo']?.toString().trim().toLowerCase() ?? '';
    return '${kind.name}:$id:$who';
  }

  String get title {
    final t = incident['title']?.toString().trim() ?? '';
    if (t.isNotEmpty) return t;
    // Older records and some AI-scan rows have no title, only a description.
    final d = incident['description']?.toString().trim() ?? '';
    if (d.isEmpty) return 'Untitled report';
    return d.length <= 60 ? d : '${d.substring(0, 57)}…';
  }

  String get severity =>
      incident['severity']?.toString().trim().toUpperCase() ?? '';

  String get status => incident['status']?.toString().trim().toUpperCase() ?? '';

  String get plant => incident['plant']?.toString().trim() ?? '';

  /// Who is on it — the denormalised name if we have it, else the username.
  String get investigator {
    final n = incident['assignedToName']?.toString().trim() ?? '';
    if (n.isNotEmpty) return n;
    return incident['assignedTo']?.toString().trim() ?? '';
  }

  DateTime? get assignedAt {
    final s = incident['assignedAt']?.toString().trim() ?? '';
    return s.isEmpty ? null : DateTime.tryParse(s);
  }

  DateTime? get targetDate {
    for (final k in const ['targetDate', 'target_date']) {
      final s = incident[k]?.toString().trim() ?? '';
      if (s.isEmpty) continue;
      final d = DateTime.tryParse(s);
      if (d != null) return d;
    }
    return null;
  }

  /// Days past the target date, or null when there is no target or it is future.
  int? get daysOverdue {
    final t = targetDate;
    if (t == null) return null;
    final days = DateTime.now().difference(t).inDays;
    return days > 0 ? days : null;
  }
}

class AssignmentInbox {
  /// Per-account, because more than one person uses a shared plant terminal and
  /// one user's "seen" must not silence another user's new assignment.
  static String _seenKeyFor(String username) =>
      'assignment_seen_${username.trim().toLowerCase()}';

  /// Every identity string that means "this is me".
  ///
  /// Returned lower-cased. Includes the P.no because an imported account's
  /// username IS the P.no, and a manually-created account's is not — matching on
  /// only one of the two silently misses whole categories of user.
  static Set<String> identities(Map<String, dynamic>? user) {
    if (user == null) return {};
    final out = <String>{};
    for (final k in const ['username', 'pno']) {
      final v = user[k]?.toString().trim().toLowerCase() ?? '';
      if (v.isNotEmpty) out.add(v);
    }
    return out;
  }

  /// Build the inbox.
  ///
  /// [openStatuses] comes from the admin's own status ladder — NOT a hardcoded
  /// 'OPEN'/'CLOSED' pair — so adding a stage in the admin panel cannot make
  /// live investigations vanish from the person doing them. A record whose
  /// status is blank counts as open: an unstatused case that somebody has been
  /// assigned is exactly the case that must not be hidden.
  ///
  /// Sorted worst-first: overdue before on-time, then by severity, then newest
  /// assignment. Somebody holding six investigations needs to know which one to
  /// pick up, and alphabetical order would not tell them.
  static List<AssignmentItem> build({
    required Map<String, dynamic>? user,
    required List<Map<String, dynamic>> incidents,
    required Set<String> openStatuses,
  }) {
    final me = identities(user);
    if (me.isEmpty) return const [];
    final myName = user?['name']?.toString().trim().toLowerCase() ?? '';

    // The reporter side is matched against the P.no ONLY, not against the full
    // identity set. `me` deliberately contains the username as well, which is
    // right for "assigned to me" but wrong here: a manually-created username
    // could coincide with somebody else's P.no and that person's report would
    // show up in the wrong inbox. Falls back to the username only when the
    // account genuinely has no P.no, which is the case where the username IS
    // the P.no anyway.
    final myPnoRaw = user?['pno']?.toString().trim().toLowerCase() ?? '';
    final myPno = myPnoRaw.isNotEmpty
        ? myPnoRaw
        : (user?['username']?.toString().trim().toLowerCase() ?? '');

    final open = openStatuses.map((s) => s.trim().toUpperCase()).toSet();
    bool isOpen(Map<String, dynamic> i) {
      final s = i['status']?.toString().trim().toUpperCase() ?? '';
      return s.isEmpty || open.isEmpty || open.contains(s);
    }

    final items = <AssignmentItem>[];
    for (final i in incidents) {
      if (!isOpen(i)) continue;

      final assignee = i['assignedTo']?.toString().trim().toLowerCase() ?? '';
      if (assignee.isEmpty) continue;   // nobody assigned: nothing to notify

      if (me.contains(assignee)) {
        items.add(AssignmentItem(i, AssignmentKind.assignedToMe));
        continue;                        // never tell someone about their own case twice
      }

      // Reporter side. Matched on P.no first; the name is a fallback for
      // records filed before reportedByPno was populated correctly, and is
      // only trusted when it is non-empty on both sides.
      final repPno = i['reportedByPno']?.toString().trim().toLowerCase() ?? '';
      final repName = i['reportedBy']?.toString().trim().toLowerCase() ?? '';
      final mine = (repPno.isNotEmpty && myPno.isNotEmpty && repPno == myPno) ||
          (repPno.isEmpty && myName.isNotEmpty && repName == myName);
      if (mine) {
        items.add(AssignmentItem(i, AssignmentKind.myReportAssigned));
      }
    }

    const sevRank = {'CRITICAL': 0, 'HIGH': 1, 'MEDIUM': 2, 'MODERATE': 2, 'LOW': 3};
    items.sort((a, b) {
      // My own jobs always above news about someone else's progress.
      if (a.kind != b.kind) {
        return a.kind == AssignmentKind.assignedToMe ? -1 : 1;
      }
      final ao = a.daysOverdue ?? -1, bo = b.daysOverdue ?? -1;
      if (ao != bo) return bo.compareTo(ao);
      final ar = sevRank[a.severity] ?? 4, br = sevRank[b.severity] ?? 4;
      if (ar != br) return ar.compareTo(br);
      final ad = a.assignedAt, bd = b.assignedAt;
      if (ad != null && bd != null) return bd.compareTo(ad);
      return 0;
    });
    return items;
  }

  /// Which of [items] this user has not been shown before.
  ///
  /// Returns an empty set on any storage failure rather than throwing: a badge
  /// is not worth breaking the dashboard over.
  static Future<Set<String>> unseen(
      Map<String, dynamic>? user, List<AssignmentItem> items) async {
    if (items.isEmpty) return {};
    final uname = user?['username']?.toString().trim() ?? '';
    if (uname.isEmpty) return {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList(_seenKeyFor(uname))?.toSet() ?? {};
      return items
          .map((i) => i.seenKey)
          .where((k) => !seen.contains(k))
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// Record that these items have been shown.
  ///
  /// Only the keys currently in the inbox are kept. Pruning matters: without it
  /// the list grows by one entry per assignment forever, and a device that has
  /// seen a few thousand cases would carry them all in SharedPreferences.
  static Future<void> markSeen(
      Map<String, dynamic>? user, List<AssignmentItem> items) async {
    final uname = user?['username']?.toString().trim() ?? '';
    if (uname.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _seenKeyFor(uname), items.map((i) => i.seenKey).toList());
    } catch (_) {}
  }
}
