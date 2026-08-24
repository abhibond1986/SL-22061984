// lib/widgets/my_assignments_card.dart
// SAIL Safety Lens — "Assigned to you" card for the top of the Home screen.
//
// Mounted by HomeTab (home_tab.dart). This is the first thing an investigator
// should see when they open the app. It is a WORKLIST, not a message feed, and
// the difference drives every decision here:
//
//   • It cannot be dismissed. A hazard investigation is a job with a target
//     date, and a swipe-to-clear notification would let it be cleared without
//     being done — which is precisely the failure this card exists to prevent.
//     It disappears when the case leaves the open statuses, i.e. when the work
//     is actually finished.
//   • Worst case first. Somebody holding six investigations needs to know which
//     one to pick up; overdue items are called out in words ("4 DAYS OVERDUE"),
//     not left as a date to compare against today.
//   • It renders nothing at all when there is nothing assigned. An empty
//     "you have 0 notifications" panel would push the real dashboard content
//     down the screen every single day for the majority of users.
//
// The reporter-side rows are visually quieter on purpose: "your report is being
// investigated by X" is news, not a task, and must not compete with a job.
//
// VISUAL NOTES
// The surface is a plain card with a hairline border and a soft shadow, the same
// language as the stat tiles below it, rather than a coloured alert panel — the
// card is permanent furniture for an investigator and a permanently alarming
// panel stops being read. Priority is carried by one 4px rail down the left edge
// and by chips, both of which survive being glanced at on a phone in a plant.
// Every foreground colour comes from the theme-aware SL getters; the bare
// AppColors status tokens fail contrast as foregrounds.

import 'package:flutter/material.dart';
import '../main.dart';
import '../services/assignment_inbox.dart';

class MyAssignmentsCard extends StatelessWidget {
  final List<AssignmentItem> items;

  /// Keys from [AssignmentInbox.unseen] — shown with a NEW flag.
  final Set<String> unseen;

  /// Open the incident. The host screen owns navigation and the refresh that
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

    final jobs = items.where((i) => i.kind == AssignmentKind.assignedToMe).toList();
    final news =
        items.where((i) => i.kind == AssignmentKind.myReportAssigned).toList();

    // The rail colour is driven by the work, not by the news: a red rail for
    // "somebody is looking at your report" would cry wolf.
    final overdue = jobs.where((i) => i.daysOverdue != null).length;
    final rail = jobs.isEmpty
        ? AppColors.cyan
        : (overdue > 0 ? AppColors.crit : AppColors.accent);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sl.border, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(sl.isDark ? 0.22 : 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      // Clipped so the rail's square outer edge takes the card's radius instead
      // of poking out of the corners.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: rail),
            Expanded(
              child: Column(children: [
                _header(sl, rail, jobs.length, overdue, news.length),
                for (var i = 0; i < jobs.length; i++)
                  _row(sl, jobs[i], divider: true),
                for (var i = 0; i < news.length; i++)
                  _row(sl, news[i], divider: true),
                const SizedBox(height: 4),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  // ── HEADER ────────────────────────────────────────────────────────
  Widget _header(SL sl, Color rail, int jobs, int overdue, int news) {
    final hasJobs = jobs > 0;
    final String line = hasJobs
        ? 'Assigned to you'
        : (news == 1 ? 'Your report' : 'Your reports');
    final String sub = hasJobs
        ? (overdue > 0
            ? (overdue == 1
                ? '1 case is past its target date'
                : '$overdue cases are past their target date')
            : (jobs == 1
                ? '1 investigation waiting on you'
                : '$jobs investigations waiting on you'))
        : (news == 1
            ? 'Now under investigation'
            : '$news of your reports are under investigation');

    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 13, 12, 11),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: rail.withOpacity(0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
              hasJobs
                  ? Icons.assignment_ind_outlined
                  : Icons.visibility_outlined,
              size: 17,
              color: hasJobs
                  ? (overdue > 0 ? sl.critText : sl.accentText)
                  : sl.cyanText),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1)),
              const SizedBox(height: 1.5),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: overdue > 0 ? sl.critText : sl.text4,
                      fontSize: 11,
                      fontWeight:
                          overdue > 0 ? FontWeight.w700 : FontWeight.w500)),
            ],
          ),
        ),
        if (hasJobs) _countPill(sl, jobs, overdue),
      ]),
    );
  }

  /// Compact total on the right of the header, so the card reads as a workload
  /// at a glance without counting rows.
  Widget _countPill(SL sl, int jobs, int overdue) {
    final c = overdue > 0 ? sl.critText : sl.accentText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withOpacity(0.28)),
      ),
      child: Text('$jobs OPEN',
          style: TextStyle(
              color: c,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
    );
  }

  // ── ROWS ──────────────────────────────────────────────────────────
  Widget _row(SL sl, AssignmentItem item, {required bool divider}) {
    final isJob = item.kind == AssignmentKind.assignedToMe;
    final over = item.daysOverdue;
    final isNew = unseen.contains(item.seenKey);

    return Container(
      decoration: divider
          ? BoxDecoration(
              border: Border(top: BorderSide(color: sl.border, width: 0.6)))
          : null,
      // Material, transparent: the card's own Container paints a colour, and an
      // InkWell splashes on the nearest Material ANCESTOR — which is the page
      // behind the card, so without this the ripple is drawn underneath the card
      // and the row looks unresponsive to the touch.
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onOpen(item.incident),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 10, 11),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isJob ? sl.text1 : sl.text2,
                            fontSize: 12.5,
                            height: 1.3,
                            fontWeight:
                                isJob ? FontWeight.w700 : FontWeight.w500)),
                    const SizedBox(height: 7),
                    // Wrap, not Row: three chips plus a long plant name overflows
                    // a narrow phone, and clipping the plant would hide which
                    // unit the case belongs to.
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: _chips(sl, item, isJob, isNew, over),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 19, color: sl.text4),
            ]),
          ),
        ),
      ),
    );
  }

  List<Widget> _chips(
      SL sl, AssignmentItem item, bool isJob, bool isNew, int? over) {
    final out = <Widget>[];

    if (isNew) {
      out.add(_chip(
        'NEW',
        fg: Colors.white,
        bg: AppColors.accent,
        solid: true,
      ));
    }

    if (over != null) {
      out.add(_chip(
        over == 1 ? '1 DAY OVERDUE' : '$over DAYS OVERDUE',
        fg: sl.critText,
        bg: sl.critText.withOpacity(0.12),
      ));
    }

    if (isJob) {
      final sev = item.severity;
      if (sev.isNotEmpty) {
        final c = _sevColor(sl, sev);
        out.add(_chip(sev, fg: c, bg: c.withOpacity(0.12)));
      }
    } else {
      final who = item.investigator;
      out.add(_chip(
        who.isEmpty ? 'UNDER INVESTIGATION' : 'WITH ${who.toUpperCase()}',
        fg: sl.cyanText,
        bg: sl.cyanText.withOpacity(0.10),
      ));
    }

    if (item.plant.isNotEmpty) {
      out.add(_chip(item.plant, fg: sl.text3, bg: sl.card2, border: sl.border));
    }

    // The target date is the one thing that is not a category, so it is plain
    // text rather than a chip — a fourth pill would make the row a wall of them.
    if (over == null && isJob) {
      final t = item.targetDate;
      if (t != null) {
        out.add(Text('Due ${_shortDate(t)}',
            style: TextStyle(
                color: sl.text4, fontSize: 10.5, fontWeight: FontWeight.w600)));
      }
    }

    return out;
  }

  Widget _chip(String text,
      {required Color fg, required Color bg, Color? border, bool solid = false}) {
    return Container(
      // 5.0, not 5: `solid ? 5 : 6.5` infers `num`, which will not assign to the
      // double this parameter wants.
      padding: EdgeInsets.symmetric(horizontal: solid ? 5.0 : 6.5, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: border == null ? null : Border.all(color: border, width: 0.8),
      ),
      child: Text(text,
          style: TextStyle(
              color: fg,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4)),
    );
  }

  String _shortDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]}';
  }

  /// Mirrors the severity palette used everywhere else. Uses the theme-aware
  /// foreground getters, because these are text colours and the bare AppColors
  /// status tokens fail contrast as foregrounds.
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
