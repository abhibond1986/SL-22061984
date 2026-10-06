import 'package:flutter/material.dart';

/// App-wide copyright line, pinned below every route by `MaterialApp.builder`
/// in main.dart (owner request 2026-10-06: "at the bottom of each page",
/// small font).
///
/// It is a thin strip *below* the routes rather than an overlay on top of
/// them, so it never covers a bottom navigation bar or a form button. The
/// strip owns the bottom safe-area inset (iPhone home indicator); the route
/// above it gets that inset removed so it isn't padded twice. While the
/// on-screen keyboard is open the strip hides, so phone forms keep every
/// pixel.
class CopyrightFooter extends StatelessWidget {
  final Widget child;
  const CopyrightFooter({super.key, required this.child});

  static const text =
      'Designed & developed by Abhishek Kumar, AGM(SSO)';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.viewInsets.bottom > 0) return child; // keyboard open

    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF060B24) : const Color(0xFFF3F5FA);
    final fg = dark ? const Color(0xFF9AA6BF) : const Color(0xFF5B6680);
    final edge = dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);

    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: child,
          ),
        ),
        Material(
          color: bg,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: edge, width: 0.5)),
            ),
            padding: EdgeInsets.fromLTRB(12, 3, 12, 3 + mq.padding.bottom),
            child: Text(
              '© ${DateTime.now().year} $text',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // Fixed size: ignore the user's text scale so the strip stays
              // a single small line on every device.
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.2,
                letterSpacing: 0.2,
                color: fg,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
