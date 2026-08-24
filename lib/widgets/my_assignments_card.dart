// lib/widgets/my_assignments_card.dart
// SAIL Safety Lens — "Assigned to you" card for the top of the dashboard.
//
// This is the first thing an investigator should see when they open the app. It
// is a WORKLIST, not a message feed, and the difference drives every decision
// here:
//
//   • It cannot be dismissed. A hazard investigation is a job with a target
//     date, and a swipe-to-clear notification would let it be cleared without
//     being done — which is precisely the failure this card exists to prevent.
//     It disappears when the case leaves the open statuses, i.e. when the work
//     is actually finished.
//   • Worst case first. Somebody holding six investigations needs to know which
//     one to pick up; overdue items are called out in words ("4 days overdue"),
//     not left as a date to compare against today.
//   • It renders nothing at all when there is nothing assigned. An empty
//     "you have 0 notifications" panel would push the real dashboard content
//     down the screen every single day for the majority of users.
//
// The reporter-side rows are visually quieter on purpose: "your report is being
// investigated by X" is news, not a task, and must not compete with a job.

import 'package:flutter/material.dart';
import '../main.dart';
import '../services/assignment_inbox.dart';

class MyAssignmentsCard extends StatelessWidget {
  final List<AssignmentItem> items;

  /// Keys from [AssignmentInbox.unseen] — shown with a NEW flag.
  final Set<String> unseen;

  /// Open the incident. The dashboard owns navigation and the refresh that
  /// follows it, so this widget stays a pure function of its inputs.
  final void Function(Map<String, dynamic> incident) onOpen;

  const MyAssignmentsCard({
    super.key,
    required this.items,
    required this.unseen,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final sl = SL.of(context);

    final jobs = items
        .where((i) => i.kind == AssignmentKind.assignedToMe)
        .toList();
    final news = items
        .where((i) => i.kind == AssignmentKind.myReportAssigned)
        .toList();

    // The accent is driven by the work, not by the news: an amber card for
    // "somebody is looking at your report" would cry wolf.
    final overdue = jobs.where((i) => i.daysOverdue != null).length;
    final accent = jobs.isEmpty
        ? AppColors.cyan
        : (overdue > 0 ? AppColors.crit : AppColors.amber);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.2),
      ),
      child: Column(children: [
        _header(sl, accent, jobs.length, overdue, news.length),
        for (var i = 0; i < jobs.length; i++)
          _row(sl, jobs[i], first: i == 0),
        for (var i = 0; i < news.length; i++)
          _row(sl, news[i], first: jobs.isEmpty && i == 0),
      ]),
    );
  }

  Widget _header(SL sl, Color accent, int jobs, int overdue, int news) {
    final String line;
    if (jobs > 0) {
      line = jobs == 1
          ? '1 investigation assigned to you'
          : '$jobs investigations assigned to you';
    } else {
      line = news == 1
          ? 'Your report is being investigated'
          : 'Your reports are being investigated';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
      ),
      child: Row(children: [
        Icon(jobs > 0 ? Icons.assignment_late_outlined : Icons.forum_outlined,
            size: 18, color: accent),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13,
                      fontWeight: FontWeight.w800)),
              if (overdue > 0) ...[
                const SizedBox(height: 2),
                Text(
                    overdue == 1
                        ? '1 is past its target date'
                        : '$overdue are past their target date',
                    style: TextStyle(
                        color: sl.critText,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  Widget _row(SL sl, AssignmentItem item, {required bool first}) {
    final isJob = item.kind == AssignmentKind.assignedToMe;
    final sev = _sevColor(sl, item.severity);
    final over = item.daysOverdue;
    final isNew = unseen.contains(item.seenKey);

    return InkWell(
      onTap: () => onOpen(item.incident),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 10, 11, 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: sl.border, width: first ? 1 : 0.5)),
        ),
        child: Row(children: [
          // Severity as a bar rather than a dot: at a glance down a list of six,
          // a 3px stripe reads faster than coloured text.
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: isJob ? sev : sl.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (isNew) ...[
                    Container(
                      margin: const EdgeInsets.only(right: 5),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text('NEW',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w800)),
                    ),
                  ],
                  Expanded(
                    child: Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 12.5,
                            fontWeight:
                                isJob ? FontWeight.w700 : FontWeight.w500)),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(_subtitle(item, isJob),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: over != null ? sl.critText : sl.text4,
                        fontSize: 10.5,
                        fontWeight:
                            over != null ? FontWeight.w700 : FontWeight.w400)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right_rounded, size: 18, color: sl.text4),
        ]),
      ),
    );
  }

  /// The one line of context that decides whether to act now.
  String _subtitle(AssignmentItem item, bool isJob) {
    if (!isJob) {
      final who = item.investigator;
      return who.isEmpty
          ? 'Assigned for investigation'
          : 'Now with $who';
    }
    final bits = <String>[];
    final over = item.daysOverdue;
    if (over != null) {
      bits.add(over == 1 ? '1 day overdue' : '$over days overdue');
    } else {
      final t = item.targetDate;
      if (t != null) bits.add('due ${_shortDate(t)}');
    }
    if (item.severity.isNotEmpty) bits.add(_titleCase(item.severity));
    if (item.plant.isNotEmpty) bits.add(item.plant);
    return bits.isEmpty ? 'Tap to investigate' : bits.join(' · ');
  }

  String _titleCase(String s) => s.isEmpty
      ? s
      : s.substring(0, 1).toUpperCase() + s.substring(1).toLowerCase();

  String _shortDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]}';
  }

  /// Mirrors the severity palette used everywhere else on the dashboard. Uses
  /// the theme-aware foreground getters, because these are text/graphic colours
  /// and the bare AppColors status tokens fail contrast as foregrounds.
  Color _sevColor(SL sl, String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL':
        return sl.critText;
      case 'HIGH':
        return sl.redText;
      case 'MEDIUM':
      case 'MODERATE':
        return sl.amberText;
      default:
        return sl.greenText;
    }
  }
}
