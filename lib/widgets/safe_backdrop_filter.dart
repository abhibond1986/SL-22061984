import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// True on a phone or tablet BROWSER (iPhone Safari/Chrome, Android Chrome).
///
/// 2026-10-08: safetylens.in crashed on iPhone with Safari's "A problem
/// repeatedly occurred" page — the WebKit content process being killed for
/// memory. Flutter 3.19's web build uses the HTML renderer on mobile, where:
///
///  * every BackdropFilter becomes a CSS `backdrop-filter` compositing layer
///    (the shell alone stacks an app bar, a nav bar and up to ~10 glass cards);
///  * Safari has no canvas `ctx.filter`, so every `MaskFilter.blur` draw is
///    emitted as a separate DOM element with a CSS blur — and the login
///    backdrop's animated overlay issued ~60 of them per frame, every frame,
///    underneath the sign-in card's 26 px backdrop blur.
///
/// Together those exhaust WebKit's GPU/memory budget and the tab is killed,
/// then killed again on the automatic reload. Every iPhone browser is WebKit,
/// so Chrome on iPhone crashes the same way. On these devices the app paints
/// the same layout with opaque-enough fills instead of live blur.
///
/// The Android/iOS APP (not web) and desktop browsers are unaffected.
bool get kLiteWebEffects =>
    kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// Drop-in replacement for [BackdropFilter]. Identical on desktop browsers and
/// in the native app; on a mobile browser ([kLiteWebEffects]) it returns
/// [child] unblurred. Callers that relied on blur for legibility should also
/// raise their fill opacity when [kLiteWebEffects] is true.
///
/// Do not use a raw BackdropFilter anywhere in lib/ — see the note above.
class SafeBackdropFilter extends StatelessWidget {
  const SafeBackdropFilter({
    super.key,
    required this.filter,
    this.child,
    this.blendMode = BlendMode.srcOver,
  });

  final ImageFilter filter;
  final Widget? child;
  final BlendMode blendMode;

  @override
  Widget build(BuildContext context) {
    if (kLiteWebEffects) return child ?? const SizedBox.shrink();
    return BackdropFilter(filter: filter, blendMode: blendMode, child: child);
  }
}
