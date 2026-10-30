// lib/services/pdf_text.dart
//
// Non-Latin text (Hindi and any other script) in the PDF reports.
//
// WHY THIS FILE EXISTS (2026-10-30)
//
// A near miss typed in Hindi produced a broken PDF. The report uses the PDF
// built-in Helvetica, which only has Latin-1, and the `pdf` package throws
// "Cannot decode the string to Latin1. This font does not support Unicode
// characters" for the first Devanagari letter it meets.
//
// Embedding a Devanagari TTF is NOT enough. The `pdf` package (3.11) has no
// shaping engine for Indic scripts (it only shapes Arabic): it would place
// every code point as a separate glyph, so "हिंदी" prints with the i-matra
// after the consonant, half-forms and conjuncts (क्ष, त्र, श्र) fall apart, and
// the text reads as misspelt Hindi. On a safety record that is not acceptable.
//
// So each non-Latin WORD is drawn by a real text engine and placed in the
// report as a small high-resolution image:
//   * Android / iOS / desktop: Flutter's own engine (dart:ui, HarfBuzz shaping)
//     with the bundled Noto Sans Devanagari (assets/fonts/, SIL OFL).
//   * Web: the browser's canvas (its own shaping), with the same font loaded as
//     a FontFace, falling back to the system's Devanagari font. This is used on
//     every web renderer, including the HTML renderer that mobile browsers get.
// Shaping never crosses a space, so word-by-word is exact, and the words flow
// in a pw.Wrap, so line breaking follows whatever width the layout gives.
// Latin words inside a Hindi sentence stay real Helvetica text, baseline-
// aligned with the images. Other scripts (Bengali, Odia, Tamil ...) take the
// same path and use the device's system font.
//
// HOW IT IS WIRED IN
//
// pdf_export.dart imports `package:pdf/widgets.dart` as pw WITH `hide Text`,
// and imports this file under the same `pw` prefix. Every existing
// `pw.Text(...)` call therefore lands on the [Text] function below:
// Latin-1 strings get the ordinary pw.Text (zero change for English reports);
// anything else gets the shaped word images.
//
// Images must exist BEFORE the page is laid out, and layout is synchronous,
// so [PdfScript.run] builds the document twice when (and only when) the
// report contains non-Latin text: pass 1 records the words it needs, they are
// rasterised, pass 2 builds the real document. English reports are built once.
//
// Trade-off: the Hindi words are pictures, so they cannot be selected or
// searched in a PDF viewer. They print sharply (about 320 dpi at 8 pt).

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_text_raster_io.dart'
    if (dart.library.html) 'pdf_text_raster_web.dart' as raster;

// Line box of a rasterised word, in em: room for Devanagari top matras and
// the below-base signs. Helvetica's own box is 0.931 + 0.225 em; Latin words
// in a mixed line are padded to the same box so every word shares a baseline.
const double _kAscentEm = 0.96;
const double _kDescentEm = 0.42;
const double _kBoxEm = _kAscentEm + _kDescentEm;
const double _kHelvAscentEm = 0.931;
const double _kHelvDescentEm = 0.225;

/// Reference size the words are drawn at. 40 px per em is about 320 dpi for
/// 9 pt text, sharp on paper while keeping each word image a few KB.
const double _kRasterPx = 40;

/// Drop-in replacement for `pw.Text` (same parameters). Reached as
/// `pw.Text(...)` from pdf_export.dart.
// ignore: non_constant_identifier_names
pw.Widget Text(
  String text, {
  pw.TextStyle? style,
  pw.TextAlign? textAlign,
  pw.TextDirection? textDirection,
  bool? softWrap,
  bool tightBounds = false,
  double textScaleFactor = 1.0,
  int? maxLines,
  pw.TextOverflow? overflow,
}) {
  if (!PdfScript.needsShaping(text)) {
    return pw.Text(text,
        style: style,
        textAlign: textAlign,
        textDirection: textDirection,
        softWrap: softWrap,
        tightBounds: tightBounds,
        textScaleFactor: textScaleFactor,
        maxLines: maxLines,
        overflow: overflow);
  }
  return PdfScript.shapedText(text,
      style: style,
      textAlign: textAlign,
      textScaleFactor: textScaleFactor,
      maxLines: maxLines);
}

class _Word {
  final pw.MemoryImage image;
  final int widthPx;
  _Word(this.image, this.widthPx);
}

class PdfScript {
  PdfScript._();

  static final Map<String, _Word> _cache = <String, _Word>{};
  static const int _kCacheMax = 3000;

  /// Words requested during the current pass that have no image yet.
  /// Key -> (word, bold, argb).
  static final Map<String, (String, bool, int)> _pending =
      <String, (String, bool, int)>{};

  static bool _fontsTried = false;
  static pw.Font? _fallbackRegular;
  static pw.Font? _fallbackBold;

  /// True when [s] has a character Helvetica cannot print (above U+00FF).
  static bool needsShaping(String s) {
    for (final c in s.codeUnits) {
      if (c > 0xFF) return true;
    }
    return false;
  }

  /// Build a PDF with [build], rasterising non-Latin words in between.
  /// [build] must be repeatable (it is called twice when there is Hindi).
  static Future<T> run<T>(Future<T> Function() build) async {
    _pending.clear();
    final first = await build();
    if (_pending.isEmpty) return first;
    await _rasterisePending();
    _pending.clear();
    return build();
  }

  static String _key(String word, bool bold, int argb) =>
      '${bold ? 'b' : 'r'}$argb|$word';

  static Future<void> _loadFonts() async {
    if (_fontsTried) return;
    _fontsTried = true;
    try {
      final r = await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf');
      final b = await rootBundle.load('assets/fonts/NotoSansDevanagari-Bold.ttf');
      _fallbackRegular = pw.Font.ttf(r);
      _fallbackBold = pw.Font.ttf(b);
      await raster.ensureFonts(
          r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes),
          b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
    } catch (e) {
      debugPrint('PdfScript: font load failed: $e');
    }
  }

  static Future<void> _rasterisePending() async {
    await _loadFonts();
    if (_cache.length > _kCacheMax) _cache.clear();
    for (final e in _pending.entries) {
      if (_cache.containsKey(e.key)) continue;
      final (word, bold, argb) = e.value;
      try {
        final r = await raster.rasterWord(word,
            bold: bold,
            argb: argb,
            px: _kRasterPx,
            ascentEm: _kAscentEm,
            boxEm: _kBoxEm);
        if (r != null) {
          _cache[e.key] = _Word(pw.MemoryImage(r.$1), r.$2);
        }
      } catch (err) {
        debugPrint('PdfScript: raster failed for "$word": $err');
      }
    }
  }

  /// The shaped replacement for a pw.Text whose string is not Latin-1.
  static pw.Widget shapedText(
    String text, {
    pw.TextStyle? style,
    pw.TextAlign? textAlign,
    double textScaleFactor = 1.0,
    int? maxLines,
  }) {
    final fontSize = (style?.fontSize ?? 12) * textScaleFactor;
    final bold = style?.fontWeight == pw.FontWeight.bold;
    final color = style?.color ?? PdfColors.black;
    final argb = color.toInt();
    final latinStyle = (style ?? const pw.TextStyle()).copyWith(
        fontSize: fontSize, lineSpacing: 0, letterSpacing: 0);

    pw.Widget wordWidget(String w) {
      if (!needsShaping(w)) {
        // Real text, padded to the image line box so baselines match.
        return pw.Padding(
          padding: pw.EdgeInsets.only(
              top: (_kAscentEm - _kHelvAscentEm) * fontSize,
              bottom: (_kDescentEm - _kHelvDescentEm) * fontSize),
          child: pw.Text(w, style: latinStyle),
        );
      }
      final k = _key(w, bold, argb);
      final img = _cache[k];
      if (img != null) {
        final scale = fontSize / _kRasterPx;
        return pw.Image(img.image,
            width: img.widthPx * scale, height: _kBoxEm * fontSize);
      }
      // Not rasterised yet: this is pass 1 (record it), or rasterising failed.
      _pending[k] = (w, bold, argb);
      final f = bold ? (_fallbackBold ?? _fallbackRegular) : _fallbackRegular;
      if (f != null) {
        // Last resort: the TTF itself. Unshaped, but legible and never throws.
        return pw.SizedBox(
          height: _kBoxEm * fontSize,
          child: pw.Text(w, style: latinStyle.copyWith(font: f, fontBold: f)),
        );
      }
      // Pass 1 before fonts are loaded: a blank of roughly the right width.
      return pw.SizedBox(
          width: w.runes.length * fontSize * 0.5, height: _kBoxEm * fontSize);
    }

    final wrapAlign = switch (textAlign) {
      pw.TextAlign.center => pw.WrapAlignment.center,
      pw.TextAlign.right || pw.TextAlign.end => pw.WrapAlignment.end,
      _ => pw.WrapAlignment.start,
    };
    final runSpacing = (style?.lineSpacing ?? 0) * textScaleFactor;
    final gap = fontSize * 0.28;

    pw.Widget paragraph(String line) {
      final words = line.split(RegExp(r'[ \t]+')).where((w) => w.isNotEmpty);
      final children = words.map(wordWidget).toList();
      if (children.isEmpty) {
        return pw.SizedBox(height: _kBoxEm * fontSize);
      }
      if (maxLines == 1) {
        // Single-line slots (titles, badges): shrink to fit, never wrap.
        return pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: wrapAlign == pw.WrapAlignment.center
              ? pw.Alignment.center
              : pw.Alignment.centerLeft,
          child: pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) pw.SizedBox(width: gap),
                children[i],
              ],
            ],
          ),
        );
      }
      return pw.Wrap(
        alignment: wrapAlign,
        spacing: gap,
        runSpacing: runSpacing,
        children: children,
      );
    }

    final lines = const LineSplitter().convert(text);
    if (lines.length <= 1 || maxLines == 1) {
      return paragraph(lines.isEmpty ? '' : lines.join(' '));
    }
    return pw.Column(
      crossAxisAlignment: wrapAlign == pw.WrapAlignment.center
          ? pw.CrossAxisAlignment.center
          : (wrapAlign == pw.WrapAlignment.end
              ? pw.CrossAxisAlignment.end
              : pw.CrossAxisAlignment.start),
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0 && runSpacing > 0) pw.SizedBox(height: runSpacing),
          paragraph(lines[i]),
        ],
      ],
    );
  }
}
