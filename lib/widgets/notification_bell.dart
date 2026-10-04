// lib/widgets/notification_bell.dart
//
// Bell icon with an unread badge, shown in the top-right of UniversalAppBar.
// Tap → notification panel (anchored drop-down on desktop/laptop, bottom sheet
// on phones). Tapping a notification marks it read and opens the case.
//
// State lives in AssignmentNotifications (lib/services/assignment_notifications.dart);
// several bells can be mounted at once (every tab has an app bar), so the
// "new assignment" toast is guarded by a static generation counter and shows
// once, not once per bell.

import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL, SLRadius;
import '../screens/incident_detail_screen.dart';
import '../services/assignment_inbox.dart';
import '../services/assignment_notifications.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  /// Last arrival generation that has been toasted, shared by all bells.
  static int _toastedGen = 0;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    AssignmentNotifications.start();
    AssignmentNotifications.state.addListener(_onState);
  }

  @override
  void dispose() {
    AssignmentNotifications.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final s = AssignmentNotifications.state.value;
    if (s.arrivals.isEmpty || s.arrivalGen <= NotificationBell._toastedGen) {
      return;
    }
    // Only a bell that is actually on screen announces it (tabs in an
    // IndexedStack keep their app bars mounted offstage).
    if (!mounted || !(TickerMode.of(context))) return;
    NotificationBell._toastedGen = s.arrivalGen;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final first = s.arrivals.first;
    final text = s.arrivals.length == 1
        ? (first.kind == AssignmentKind.assignedToMe
            ? 'New case assigned to you: ${first.title}'
            : '${first.investigator} is now investigating your report: ${first.title}')
        : '${s.arrivals.length} new case assignments';
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF1E293B),
      duration: const Duration(seconds: 6),
      content: Row(children: [
        const Icon(Icons.notifications_active_rounded,
            color: AppColors.amber, size: 20),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white))),
      ]),
      action: SnackBarAction(
        label: s.arrivals.length == 1 ? 'OPEN' : 'VIEW',
        textColor: AppColors.amber,
        onPressed: () {
          if (!mounted) return;
          if (s.arrivals.length == 1) {
            _openItem(Navigator.of(context), first);
          } else {
            showNotificationPanel(context);
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return ValueListenableBuilder<NotificationState>(
      valueListenable: AssignmentNotifications.state,
      builder: (context, s, _) {
        final n = s.unreadCount;
        return IconButton(
          tooltip: n == 0 ? 'Notifications' : 'Notifications ($n unread)',
          onPressed: () => showNotificationPanel(context),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text(n > 99 ? '99+' : '$n',
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w800)),
            backgroundColor: AppColors.crit,
            textColor: Colors.white,
            offset: const Offset(6, -5),
            child: Icon(
              n > 0
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              color: n > 0 ? AppColors.amber : sl.text2,
              size: 22,
            ),
          ),
        );
      },
    );
  }
}

/// Opens the notification list. Drop-down under the bell on wide screens,
/// bottom sheet on phones.
Future<void> showNotificationPanel(BuildContext context) {
  AssignmentNotifications.refresh();
  final wide = MediaQuery.sizeOf(context).width >= 600;
  if (!wide) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
        child: const NotificationPanel(sheet: true),
      ),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close notifications',
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, __) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 54, right: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 400,
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
            child: const NotificationPanel(),
          ),
        ),
      ),
    ),
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.03), end: Offset.zero)
              .animate(a),
          child: child),
    ),
  );
}

void _openItem(NavigatorState nav, AssignmentItem item) {
  AssignmentNotifications.markRead(item);
  nav.push(MaterialPageRoute(
    builder: (_) => IncidentDetailScreen(
      incident: item.incident,
      onStatusChanged: AssignmentNotifications.refresh,
    ),
  ));
}

/// The list itself. Public so the render test can pump it directly.
class NotificationPanel extends StatelessWidget {
  const NotificationPanel({super.key, this.sheet = false});
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final radius = sheet
        ? const BorderRadius.vertical(top: Radius.circular(SLRadius.lg))
        : BorderRadius.circular(SLRadius.md);
    return Material(
      color: sl.card,
      elevation: 12,
      shadowColor: Colors.black45,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<NotificationState>(
        valueListenable: AssignmentNotifications.state,
        builder: (context, s, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (sheet)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: sl.border,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              // Fixed height so the header does not shrink when the
              // "Mark all read" button is hidden.
              child: SizedBox(height: 40, child: Row(children: [
                const Icon(Icons.notifications_rounded,
                    color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Text('Notifications',
                    style: TextStyle(
                        color: sl.text1,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                if (s.unreadCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppColors.crit,
                        borderRadius: BorderRadius.circular(SLRadius.pill)),
                    child: Text('${s.unreadCount} new',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
                const Spacer(),
                if (s.unreadCount > 0)
                  TextButton(
                    onPressed: AssignmentNotifications.markAllRead,
                    child: const Text('Mark all read'),
                  ),
              ])),
            ),
            Divider(height: 1, color: sl.border),
            if (s.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
                child: Column(children: [
                  Icon(Icons.notifications_off_outlined,
                      size: 40, color: sl.text4),
                  const SizedBox(height: 10),
                  Text("You're all caught up",
                      style: TextStyle(
                          color: sl.text1,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      'You will be notified here when a case is assigned to you.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: sl.text3, fontSize: 12)),
                ]),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: s.items.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: sl.border),
                  itemBuilder: (ctx, i) => _NotifTile(
                    item: s.items[i],
                    unread: s.isUnread(s.items[i]),
                    onTap: () {
                      final item = s.items[i];
                      // Grab the navigator first: popping disposes this panel.
                      final nav = Navigator.of(ctx);
                      nav.pop();
                      _openItem(nav, item);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  const _NotifTile(
      {required this.item, required this.unread, required this.onTap});
  final AssignmentItem item;
  final bool unread;
  final VoidCallback onTap;

  static Color _sevColor(String sev) {
    switch (sev) {
      case 'CRITICAL':
        return AppColors.crit;
      case 'HIGH':
        return AppColors.red;
      case 'MEDIUM':
        return AppColors.amber;
      case 'LOW':
        return AppColors.green;
      default:
        return const Color(0xFF64748B);
    }
  }

  static String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 30) return '${d.inDays} d ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final mine = item.kind == AssignmentKind.assignedToMe;
    final sev = item.severity;
    final sevC = _sevColor(sev);
    final overdue = item.daysOverdue;
    final ago = _ago(item.assignedAt);
    final iconC = mine ? AppColors.accent : const Color(0xFF0F766E);
    final meta = [
      if (item.plant.isNotEmpty) item.plant,
      if (ago.isNotEmpty) ago,
    ].join('  ·  ');

    return Material(
      color: unread
          ? AppColors.accent.withOpacity(sl.isDark ? 0.14 : 0.06)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: iconC.withOpacity(0.12), shape: BoxShape.circle),
              child: Icon(
                  mine
                      ? Icons.assignment_ind_rounded
                      : Icons.person_search_rounded,
                  color: iconC,
                  size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        mine
                            ? 'Case assigned to you'
                            : 'Your report is being investigated',
                        style: TextStyle(
                            // Lifted on dark: the 700-weight tones are too dim.
                            color: sl.isDark
                                ? Color.lerp(iconC, Colors.white, 0.45)
                                : iconC,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2)),
                    const SizedBox(height: 2),
                    Text(item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 13.5,
                            height: 1.25,
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w500)),
                    if (!mine && item.investigator.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('Investigator: ${item.investigator}',
                          style: TextStyle(color: sl.text2, fontSize: 12)),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (sev.isNotEmpty) _chip(sev, sevC),
                          if (overdue != null)
                            _chip('OVERDUE ${overdue}d', AppColors.crit),
                          if (meta.isNotEmpty)
                            Text(meta,
                                style:
                                    TextStyle(color: sl.text4, fontSize: 11.5)),
                        ]),
                  ]),
            ),
            if (unread)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 4),
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                    color: AppColors.crit, shape: BoxShape.circle),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _chip(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: c.withOpacity(0.14),
            borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(
                color: c, fontSize: 10, fontWeight: FontWeight.w800)),
      );
}
