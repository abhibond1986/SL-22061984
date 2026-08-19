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
  static TextRecognizer? _recognizer;

  /// True on Android and iOS. The stub returns false on web.
  static bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  static String get unavailableReason => isAvailable
      ? ''
      : 'on-device text recognition is not available on this platform';

  static TextRecognizer _ensure() =>
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  /// Recognise text in a JPEG. Returns '' on any failure — never throws, so the
  /// caller's tier logic sees "produced nothing" and moves on.
  ///
  /// Goes via a temp FILE rather than `InputImage.fromBytes`. The bytes
  /// constructor needs width, height, rotation and a raw pixel format that
  /// matches the platform's expectation exactly; handing it JPEG bytes yields
  /// either an exception or, worse, silent garbage. `fromFilePath` lets ML Kit
  /// do its own decoding, which is the only reliable path for an encoded image.
  static Future<String> recognise(Uint8List jpegBytes) async {
    if (!isAvailable) return '';
    File? temp;
    try {
      final dir = await getTemporaryDirectory();
      temp = File(
          '${dir.path}/sop_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await temp.writeAsBytes(jpegBytes, flush: true);

      final result = await _ensure().processImage(
        InputImage.fromFilePath(temp.path),
      );

      // `result.text` joins blocks with newlines in reading order, which is
      // what we want for a single-column SOP page. Multi-column layouts come
      // back interleaved — that is one of the cases the quality gate in
      // sop_ocr_service.dart is meant to catch, so the AI tier can re-read the
      // page with layout awareness.
      return result.text;
    } catch (e) {
      print('SopOcrDevice: recognition failed — $e');
      return '';
    } finally {
      // Always clean up: a 20-page scan would otherwise leave 20 full-size
      // JPEGs in the temp directory on every attempt.
      try {
        await temp?.delete();
      } catch (_) {}
    }
  }

  /// Release the native recogniser. Safe to call repeatedly.
  static Future<void> dispose() async {
    try {
      await _recognizer?.close();
    } catch (_) {}
    _recognizer = null;
  }
}
