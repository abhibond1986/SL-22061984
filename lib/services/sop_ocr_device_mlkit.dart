// lib/services/sop_ocr_device_mlkit.dart
//
// MOBILE ONLY (Android / iOS) — compiled only when dart:library.html is absent.
// Never import this file directly; import sop_ocr_device.dart.
//
// On-device text recognition via ML Kit. Free, offline, no quota, and fast
// (tens of milliseconds per page rather than the seconds a network round trip
// costs), which is why it is tried before the AI tier.
//
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

class SopOcrDevice {
  /// One recogniser per script, created on first use and kept.
  ///
  /// A map rather than a single field because constructing a TextRecognizer
  /// loads a native model; building one per page would dominate the recognition
  /// time this tier exists to save. Bounded by the number of scripts, which is
  /// two.
  static final Map<TextRecognitionScript, TextRecognizer> _recognizers = {};

  /// True on Android and iOS. The stub returns false on web.
  static bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  static String get unavailableReason => isAvailable
      ? ''
      : 'on-device text recognition is not available on this platform';

  static TextRecognizer _ensure(TextRecognitionScript script) =>
      _recognizers[script] ??= TextRecognizer(script: script);

  /// Recognise text in a JPEG. Returns '' on any failure — never throws, so the
  /// caller's tier logic sees "produced nothing" and moves on.
  ///
  /// Goes via a temp FILE rather than `InputImage.fromBytes`. The bytes
  /// constructor needs width, height, rotation and a raw pixel format that
  /// matches the platform's expectation exactly; handing it JPEG bytes yields
  /// either an exception or, worse, silent garbage. `fromFilePath` lets ML Kit
  /// do its own decoding, which is the only reliable path for an encoded image.
  static Future<String> recognise(Uint8List jpegBytes) =>
      _recogniseWith(jpegBytes, TextRecognitionScript.latin);

  /// Read a page that may be in English or Hindi.
  ///
  /// Latin runs first and, in the overwhelming majority of plant documents, is
  /// the only pass that happens. Devanagari is attempted only when the Latin
  /// result is too thin to be a real page of text, because:
  ///
  ///   • The two models disagree productively. Latin on a Devanagari page does
  ///     not fail — it returns a short scatter of stray marks it mistook for
  ///     Roman letters, which is exactly why the test below is on VOLUME and
  ///     not on whether an error was thrown.
  ///   • A page really is sometimes bilingual (an English SOP with a Hindi
  ///     safety warning block). Taking the longer of the two results is a
  ///     deliberate simplification: merging both outputs would interleave two
  ///     reading orders and destroy the line structure the clause splitter
  ///     depends on.
  ///
  /// The second pass costs one more on-device inference, tens of milliseconds,
  /// no network and no quota — cheap enough not to need a user-facing setting,
  /// which is why there is no language picker for this.
  static Future<String> recogniseMultiScript(Uint8List jpegBytes) async {
    if (!isAvailable) return '';
    final latin = await _recogniseWith(jpegBytes, TextRecognitionScript.latin);
    if (_weight(latin) >= _latinIsEnough) return latin;

    // NOTE THE SPELLING: the enum member is `devanagiri`, not `devanagari`.
    // That is a typo in google_mlkit_text_recognition itself — verified against
    // the plugin's text_recognizer.dart, where the enum reads
    // `latin, chinese, devanagiri, japanese, korean`. It is load-bearing:
    // "correcting" it here does not compile, and it differs from the Android
    // artifact name (…-text-recognition-devanagari), which is spelled properly.
    final devanagari =
        await _recogniseWith(jpegBytes, TextRecognitionScript.devanagiri);
    return _weight(devanagari) > _weight(latin) ? devanagari : latin;
  }

  /// Alphanumeric/Devanagari character count, ignoring layout noise.
  ///
  /// Raw `length` would be fooled by the punctuation spray a mismatched script
  /// model produces on a page it cannot read.
  static int _weight(String s) =>
      s.replaceAll(RegExp('[^A-Za-z0-9\\u0900-\\u097F]'), '').length;

  /// Below this, the Latin pass is treated as "did not read this page".
  ///
  /// 40 characters, set against SopOcrService.minChars (200): well under the
  /// threshold at which a page is accepted at all, so this only ever fires on
  /// pages that were going to fail the quality gate anyway. Raising it would
  /// start spending a second pass on sparse-but-valid pages such as a signature
  /// sheet or a title page.
  static const int _latinIsEnough = 40;

  static Future<String> _recogniseWith(
      Uint8List jpegBytes, TextRecognitionScript script) async {
    if (!isAvailable) return '';
    File? temp;
    try {
      final dir = await getTemporaryDirectory();
      temp = File(
          '${dir.path}/sop_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await temp.writeAsBytes(jpegBytes, flush: true);

      final result = await _ensure(script).processImage(
        InputImage.fromFilePath(temp.path),
      );

      // `result.text` joins blocks with newlines in reading order, which is
      // what we want for a single-column SOP page. Multi-column layouts come
      // back interleaved — that is one of the cases the quality gate in
      // sop_ocr_service.dart is meant to catch, so the AI tier can re-read the
      // page with layout awareness.
      return result.text;
    } catch (e) {
      print('SopOcrDevice: recognition failed (${script.name}) — $e');
      return '';
    } finally {
      // Always clean up: a 20-page scan would otherwise leave 20 full-size
      // JPEGs in the temp directory on every attempt.
      try {
        await temp?.delete();
      } catch (_) {}
    }
  }

  /// Release every native recogniser that was created. Safe to call repeatedly.
  ///
  /// Iterates a COPY of the values and clears the map first, so a close() that
  /// throws cannot leave a half-emptied map holding a dead recogniser that the
  /// next scan would then reuse.
  static Future<void> dispose() async {
    final open = _recognizers.values.toList();
    _recognizers.clear();
    for (final r in open) {
      try {
        await r.close();
      } catch (_) {}
    }
  }
}
