import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
  static const phone = '8986880340';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.viewInsets.bottom > 0) return child; // keyboard open

    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF060B24) : const Color(0xFFF3F5FA);
    final fg = dark ? const Color(0xFF9AA6BF) : const Color(0xFF5B6680);
    final edge = dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);
    final base = TextStyle(
      fontSize: 9.5,
      height: 1.2,
      letterSpacing: 0.2,
      color: fg,
    );

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
            // One line when it fits; on narrow phones the contact drops to
            // a second centred line instead of truncating the name.
            child: LayoutBuilder(builder: (context, c) {
              // Typical phones (360-430 px) keep it beside the name by
              // stepping the size down a touch; only very narrow screens
              // wrap.
              final oneLine = c.maxWidth >= 335;
              final style = c.maxWidth >= 400 || !oneLine
                  ? base
                  : base.copyWith(fontSize: 8.4, letterSpacing: 0);
              final copy = Text('© ${DateTime.now().year} $text',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  // Fixed size: ignore the user's text scale so the strip
                  // stays small on every device.
                  textScaler: TextScaler.noScaling,
                  style: style);
              // Tap to call on phones (tel: link); harmless on desktop.
              final contact = MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => launchUrl(Uri.parse('tel:+91$phone')),
                  child: Text('Contact: $phone',
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                      style: style),
                ),
              );
              if (oneLine) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: copy),
                    Text('  |  ',
                        textScaler: TextScaler.noScaling, style: style),
                    contact,
                  ],
                );
              }
              return Column(mainAxisSize: MainAxisSize.min, children: [
                copy,
                const SizedBox(height: 1),
                contact,
              ]);
            }),
          ),
        ),
      ],
    );
  }
}
