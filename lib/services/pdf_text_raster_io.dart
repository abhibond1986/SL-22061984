// lib/services/pdf_text_raster_io.dart
//
// Android / iOS / desktop (and flutter test): draw one word with Flutter's own
// text engine, which shapes Devanagari correctly. See pdf_text.dart.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;

const String _kFamily = 'SLPdfScript';
bool _loaded = false;

Future<void> ensureFonts(Uint8List regular, Uint8List bold) async {
  if (_loaded) return;
  final loader = FontLoader(_kFamily)
    ..addFont(Future.value(ByteData.sublistView(regular)))
    ..addFont(Future.value(ByteData.sublistView(bold)));
  await loader.load();
  _loaded = true;
}

/// PNG bytes and pixel width of [word], drawn at [px] per em in a box
/// [boxEm] em tall with the baseline [ascentEm] em from the top.
Future<(Uint8List, int)?> rasterWord(
  String word, {
  required bool bold,
  required int argb,
  required double px,
  required double ascentEm,
  required double boxEm,
}) async {
  final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
  ))
    ..pushStyle(ui.TextStyle(
      color: ui.Color(argb),
      fontFamily: _kFamily,
      // Latin letters and other scripts are not in the Devanagari font; the
      // engine falls back to the platform's fonts for them.
      fontFamilyFallback: const ['Roboto', 'Noto Sans', 'sans-serif'],
      fontSize: px,
      fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
    ))
    ..addText(word);
  final p = pb.build()..layout(const ui.ParagraphConstraints(width: 100000));
  final w = p.maxIntrinsicWidth.ceil() + 2;
  final h = (boxEm * px).ceil();
  if (w <= 2) return null;

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawParagraph(p, ui.Offset(1, ascentEm * px - p.alphabeticBaseline));
  final picture = rec.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (data == null) return null;
  return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w);
}
