import 'package:flutter/material.dart';

import '../main.dart' show AppColors, SL, SLLayout, SLText;
import 'bottom_nav_gap.dart';

/// One destination on the side rail. Same shape as the bottom bar's items.
class SideNavItem {
  final IconData icon, activeIcon;
  final String label;
  const SideNavItem(this.icon, this.activeIcon, this.label);
}

/// Vertical navigation for wide windows (laptops, desktops, tablets in
/// landscape).
///
/// WHY THIS EXISTS
/// ---------------
/// Both shells (HomeScreen and ContractorHomeScreen) had only a bottom tab bar.
/// On a 1440px browser that meant six targets spread 240px apart along the
/// bottom edge, far from the content column and far from each other. It is the
/// first thing that makes the web build look like a stretched phone app.
/// From [SLLayout.railBreak] (900px) up, the shells show this rail on the left
/// instead. Below that width nothing changes.
///
/// The rail is styled like the bottom bar (the same indigo wash, the same
/// selected pill, and `sl.accentText` for the selected label), so moving
/// between a phone and a laptop still looks like one app.
class SideNavRail extends StatelessWidget {
  const SideNavRail({
    super.key,
    required this.items,
    required this.selected,
    required this.onTap,
  });

  /// Rail width. 88 is enough for the longest label ("Near Miss") at 11px, plus
  /// the selected pill.
  static const double width = 88;

  /// True when the window is wide enough to use the rail instead of the bottom
  /// bar. It reads the WINDOW width, so call it from the shell, not from inside
  /// a tab. Tabs get a narrowed MediaQuery from [SideNavRail.wrapBody].
  static bool useRail(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= SLLayout.railBreak;

  /// Lays out the rail beside [body] and tells the body how much room it has.
  ///
  /// The MediaQuery override matters. Several tabs centre their content with
  /// `slGutter`, and the AI Scan tab picks its layout from
  /// `MediaQuery.size.width`. Both read the window width. Next to an 88px rail
  /// that would centre every column 44px to the right of the space it actually
  /// has. Narrowing `size` (and dropping the left inset the rail already
  /// consumed) makes all of those calls measure the body, with no change to
  /// any tab.
  ///
  /// [BottomNavScope] tells [BottomNavGap] that there is no bottom bar, so the
  /// tabs stop reserving 60px of empty space at the end of every scroll view.
  static Widget wrapBody(
    BuildContext context, {
    required Widget rail,
    required Widget body,
  }) {
    final mq = MediaQuery.of(context);
    final bodyWidth = (mq.size.width - width).clamp(0.0, double.infinity);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        rail,
        Expanded(
          child: MediaQuery(
            data: mq.copyWith(
              size: Size(bodyWidth, mq.size.height),
              padding: mq.padding.copyWith(left: 0),
              viewPadding: mq.viewPadding.copyWith(left: 0),
            ),
            child: BottomNavScope(hasBottomBar: false, child: body),
          ),
        ),
      ],
    );
  }

  final List<SideNavItem> items;

  /// Position in [items] of the selected destination.
  final int selected;

  /// Called with a position in [items].
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final idle = sl.isDark ? const Color(0xFFCBD5E1) : sl.text4;
    return Container(
      width: width,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: sl.isDark
              ? const [Color(0xFF191F38), Color(0xFF0D1117)]
              : const [Color(0xFFE9ECFB), Color(0xFFF8F9FE)],
        ),
        border: Border(
          right: BorderSide(
              color: AppColors.accent.withOpacity(sl.isDark ? 0.28 : 0.20),
              width: 1),
        ),
      ),
      child: SafeArea(
        right: false,
        child: SingleChildScrollView(
          // Short landscape windows: the destinations scroll instead of
          // overflowing.
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              for (var slot = 0; slot < items.length; slot++)
                _RailButton(
                  item: items[slot],
                  selected: slot == selected,
                  idleColor: idle,
                  onTap: () => onTap(slot),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.item,
    required this.selected,
    required this.idleColor,
    required this.onTap,
  });

  final SideNavItem item;
  final bool selected;
  final Color idleColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final color = selected ? sl.accentText : idleColor;
    return Semantics(
      label: item.label,
      selected: selected,
      button: true,
      container: true,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        child: SizedBox(
          width: SideNavRail.width,
          height: 68,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.accent.withOpacity(0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(selected ? item.activeIcon : item.icon,
                    size: 22, color: color),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: SLText.minBadge,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
