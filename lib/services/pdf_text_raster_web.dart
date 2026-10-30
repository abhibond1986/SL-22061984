// lib/services/pdf_text_raster_web.dart
//
// Web: draw one word on a browser canvas. The browser shapes Devanagari
// itself, so this is correct on every Flutter web renderer (mobile browsers
// get the HTML renderer, where Picture.toImage is not dependable). The bundled
// Noto Sans Devanagari is registered as a FontFace; if that fails the stack
// falls back to the system's Devanagari font (Nirmala UI on Windows, Kohinoor
// on iPhone/Mac, Noto on Android). See pdf_text.dart.

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'dart:typed_data';

const String _kFamily = 'SLPdfScript';
bool _loaded = false;

const String _kStack = '"$_kFamily", "Noto Sans Devanagari", "Nirmala UI", '
    '"Kohinoor Devanagari", "Devanagari Sangam MN", "Mangal", '
    'Helvetica, Arial, "Noto Sans", sans-serif';

Future<void> ensureFonts(Uint8List regular, Uint8List bold) async {
  if (_loaded) return;
  _loaded = true;
  final set = html.document.fonts;
  if (set == null) return;
  for (final (bytes, weight) in [(regular, '400'), (bold, '700')]) {
    try {
      // A fresh copy so the ArrayBuffer holds exactly the font file.
      final face = html.FontFace(
          _kFamily, Uint8List.fromList(bytes).buffer, {'weight': weight});
      await face.load();
      set.add(face);
    } catch (_) {
      // System fonts will be used instead.
    }
  }
}

Future<(Uint8List, int)?> rasterWord(
  String word, {
  required bool bold,
  required int argb,
  required double px,
  required double ascentEm,
  required double boxEm,
}) async {
  final font = '${bold ? '700' : '400'} ${px}px $_kStack';
  final probe = html.CanvasElement(width: 1, height: 1);
  final pctx = probe.context2D..font = font;
  final measured = pctx.measureText(word).width ?? 0;
  final w = measured.ceil() + 2;
  final h = (boxEm * px).ceil();
  if (w <= 2) return null;

  final canvas = html.CanvasElement(width: w, height: h);
  final ctx = canvas.context2D
    ..font = font
    ..textBaseline = 'alphabetic';
  final a = ((argb >> 24) & 0xFF) / 255.0;
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  ctx.fillStyle = 'rgba($r,$g,$b,$a)';
  ctx.fillText(word, 1, ascentEm * px);
  final url = canvas.toDataUrl('image/png');
  final comma = url.indexOf(',');
  if (comma < 0) return null;
  return (base64Decode(url.substring(comma + 1)), w);
}
