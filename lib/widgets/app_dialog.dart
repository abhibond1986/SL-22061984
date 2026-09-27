import 'package:flutter/material.dart';

/// Widest a dialog's card may be. 560 is the Material 3 maximum for basic
/// dialogs: about 75 characters of body text at 13px, which is a comfortable
/// line length.
const double kDialogMaxWidth = 560;

/// [showDialog], plus a maximum width.
///
/// WHY THIS EXISTS
/// ---------------
/// Flutter's AlertDialog sizes itself with IntrinsicWidth, with a 280px floor
/// and no ceiling. A paragraph of content therefore asks for its whole length on
/// one line, and the dialog grows until only the 40px inset is left on each
/// side. On a 1920px browser a two-sentence confirmation became a ~1840px-wide
/// strip with the Cancel and OK buttons at opposite edges of the monitor. There
/// is no theme setting for this (DialogTheme has no constraints in Flutter
/// 3.19), so every dialog goes through this wrapper instead.
///
/// On a phone the window is already narrower than the cap, so this is a no-op
/// there. Pass `maxWidth: double.infinity` for dialogs that are meant to fill
/// the window, such as the full-screen image viewer.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  double maxWidth = kDialogMaxWidth,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: (ctx) => DialogWidthCap(maxWidth: maxWidth, child: builder(ctx)),
  );
}

/// Caps the dialog card at [maxWidth] and keeps it centred.
///
/// Material dialogs add a 40px horizontal inset around the card. The cap is
/// widened by that amount so [maxWidth] is the width of the card itself, not of
/// the card plus its margin. The MediaQuery is narrowed to match, so a dialog
/// that picks its layout from the window width sees the space it has.
class DialogWidthCap extends StatelessWidget {
  const DialogWidthCap({
    super.key,
    required this.child,
    this.maxWidth = kDialogMaxWidth,
  });

  final double maxWidth;
  final Widget child;

  static const double _inset = 80; // Dialog's default 40px either side.

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cap = maxWidth + _inset;
    if (!cap.isFinite || mq.size.width <= cap) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cap),
        child: MediaQuery(
          data: mq.copyWith(size: Size(cap, mq.size.height)),
          child: child,
        ),
      ),
    );
  }
}
