// lib/services/sop_ocr_device.dart
//
// Platform router for ON-DEVICE text recognition — conditional export picks the
// implementation, exactly as pdf_kb_extractor.dart does for pdf.js:
//
//   Web (dart.library.html available):
//     → sop_ocr_device_stub.dart   (reports unavailable; ML Kit has no web build)
//
//   Mobile (Android / iOS):
//     → sop_ocr_device_mlkit.dart  (google_mlkit_text_recognition)
//
// Import THIS file everywhere. Never import either implementation directly.
//
// Note the condition is inverted relative to pdf_kb_extractor: there the WEB
// build got the real implementation, here the web build gets the stub. Read the
// `if (dart.library.html)` clause carefully before editing.

export 'sop_ocr_device_mlkit.dart'
    // ignore: uri_does_not_exist
    if (dart.library.html) 'sop_ocr_device_stub.dart';
