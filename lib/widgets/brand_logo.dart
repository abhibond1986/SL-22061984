import 'package:flutter/material.dart';
import '../services/branding.dart';

/// The company logo, wherever the app shows one.
///
/// With no custom logo this is the bundled `assets/images/app_icon.png`,
/// exactly as before. With a custom logo (Admin → Company Branding) it shows
/// that image on a small white rounded backing, because an arbitrary uploaded
/// logo is usually dark-on-transparent or has its own white background and
/// would otherwise vanish on the dark theme / gradient screens.
///
/// Rebuilds itself when the brand changes, so no caller needs to listen.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 40, this.fallbackColor});

  final double size;

  /// Colour of the shield shown if even the bundled asset fails to load.
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Branding.revision,
        builder: (context, _, __) {
          final bytes = Branding.logoBytes;
          if (bytes != null) {
            return Container(
              width: size,
              height: size,
              padding: EdgeInsets.all(size * 0.08),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(size * 0.2),
              ),
              child: Image.memory(bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => _fallback()),
            );
          }
          return SizedBox(
            width: size,
            height: size,
            child: Image.asset('assets/images/app_icon.png',
                fit: BoxFit.contain, errorBuilder: (_, __, ___) => _fallback()),
          );
        },
      );

  Widget _fallback() => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fallbackColor ?? const Color(0xFF4F46E5)),
        child: Icon(Icons.shield, color: Colors.white, size: size * 0.5),
      );
}

/// Rebuilds [builder] whenever the brand changes — for text such as
/// `Branding.appTitle` that is not inside a [BrandLogo].
class BrandBuilder extends StatelessWidget {
  const BrandBuilder({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: Branding.revision,
      builder: (context, _, __) => builder(context));
}

/// Frameless brand mark for hero spots (login, splash). 2026-10-05, user
/// request: the login logo looked cluttered because THREE rounded frames were
/// nested (a glass tile, BrandLogo's white backing, and the rounded border
/// baked into app_icon.png).
///
/// So this draws no frame at all:
///  * default SAIL brand with no uploaded logo → the bare SAIL emblem
///    (`sail_emblem.png`, or `sail_emblem_white.png` on dark backgrounds);
///  * an uploaded logo (Admin → Company Branding) → that image as-is;
///  * a renamed brand with no logo → the generic app icon.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 104, this.onDark = false});

  /// Height of the mark; the width follows the image's aspect ratio.
  final double size;

  /// True when the mark sits on a dark background, which selects the white emblem.
  final bool onDark;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Branding.revision,
        builder: (context, _, __) {
          final bytes = Branding.logoBytes;
          final Widget img;
          if (bytes != null) {
            img = Image.memory(bytes,
                height: size, fit: BoxFit.contain, gaplessPlayback: true);
          } else if (Branding.shortName.trim().toUpperCase() ==
              Branding.defaultShortName.toUpperCase()) {
            img = Image.asset(
                onDark
                    ? 'assets/images/sail_emblem_white.png'
                    : 'assets/images/sail_emblem.png',
                height: size,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium);
          } else {
            img = Image.asset('assets/images/app_icon.png',
                height: size, fit: BoxFit.contain);
          }
          return Semantics(
              label: '${Branding.companyName} logo', image: true, child: img);
        },
      );
}
