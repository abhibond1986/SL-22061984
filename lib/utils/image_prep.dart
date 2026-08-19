// lib/utils/image_prep.dart
//
// Shared image downscaling. Lifted out of ai_scan_tab so the SOP scanner and
// the hazard scanner cannot drift apart.
//
// Pure Dart + the `image` package only — no dart:html, no dart:io, no Flutter
// widgets — so this compiles for web, Android and iOS alike.

import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImagePrep {
  /// Long-edge target for HAZARD analysis.
  ///
  /// 900px is deliberate and load-bearing: a smaller JPEG uploads faster and the
  /// vision model processes it faster, with negligible impact on spotting a
  /// missing helmet or an unguarded nip point. Do not raise this to "improve
  /// quality" — it was tuned against upload latency on a plant network.
  static const int hazardMaxEdge = 900;

  /// Long-edge target for OCR.
  ///
  /// Much larger, for a different reason: hazard detection needs shapes, OCR
  /// needs individual glyph strokes. Printed SOP body text is roughly 10pt, and
  /// at 900px on the long edge of an A4 page those characters land near 6–8
  /// pixels tall, which is below what any recogniser can read reliably — the
  /// result is not "slightly worse text", it is garbage or nothing.
  ///
  /// This single number is the biggest lever on scan accuracy. If OCR quality
  /// disappoints, raise this before touching prompts or engines.
  static const int ocrMaxEdge = 1800;

  /// JPEG quality for OCR. Higher than the hazard path's 72 because JPEG
  /// artefacts land exactly on the high-contrast edges that letterforms are
  /// made of, and ringing around glyphs costs more recognition accuracy than
  /// the extra kilobytes cost in upload time.
  static const int ocrJpegQuality = 88;

  /// Downscale [original] so its long edge is at most [maxEdge], re-encoding as
  /// JPEG at [quality]. Returns the original bytes unchanged if decoding fails
  /// or if the re-encoded copy would be larger.
  static Uint8List downscale(
    Uint8List original, {
    int maxEdge = hazardMaxEdge,
    int quality = 72,
  }) {
    try {
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;
      final img.Image resized =
          (decoded.width <= maxEdge && decoded.height <= maxEdge)
              ? decoded
              : (decoded.width >= decoded.height
                  ? img.copyResize(decoded, width: maxEdge)
                  : img.copyResize(decoded, height: maxEdge));
      final out = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      // Only use the re-encoded copy if it is actually smaller.
      return out.length < original.length ? out : original;
    } catch (_) {
      return original;
    }
  }

  /// Prepare a page photo for text recognition.
  ///
  /// Unlike [downscale] this returns the re-encoded bytes even when they are
  /// LARGER than the input. A phone camera hands back a heavily compressed JPEG;
  /// re-encoding at a higher quality after a grayscale + contrast pass can grow
  /// the file while still reading better, and for OCR readability wins over
  /// bytes. Falls back to the original on any decode failure.
  static Uint8List prepareForOcr(Uint8List original, {int? maxEdge}) {
    final edge = maxEdge ?? ocrMaxEdge;
    try {
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;

      img.Image work = decoded;
      // Downscale only. Upscaling a low-res photo invents no detail and just
      // makes every later step slower.
      if (work.width > edge || work.height > edge) {
        work = work.width >= work.height
            ? img.copyResize(work, width: edge)
            : img.copyResize(work, height: edge);
      }

      // Grayscale then a mild contrast lift. Printed pages photographed under
      // plant lighting are low-contrast and colour-cast; both recognisers do
      // better on flat grayscale. Kept mild on purpose — an aggressive curve or
      // a hard threshold destroys thin strokes and faint carbon-copy text,
      // which is common on shop-floor SOP printouts.
      work = img.grayscale(work);
      work = img.adjustColor(work, contrast: 1.15);

      return Uint8List.fromList(img.encodeJpg(work, quality: ocrJpegQuality));
    } catch (_) {
      return original;
    }
  }

  /// Small JPEG for a page thumbnail in the scan review list.
  static Uint8List thumbnail(Uint8List original, {int width = 160}) {
    try {
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;
      final thumb = img.copyResize(decoded, width: width);
      return Uint8List.fromList(img.encodeJpg(thumb, quality: 70));
    } catch (_) {
      return original;
    }
  }
}
