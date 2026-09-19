// lib/services/pdf_kb_extractor_stub.dart
//
// Android/iOS stub — no dart:html, dart:js, or dart:js_util.
// The eBook-to-KB generator is a web-only Admin Panel feature
// (requires pdf.js which only works in a browser context).
//
// All methods compile and run on Android/iOS but return empty/message results.

import 'dart:typed_data';

class PdfKbExtractor {
  /// False on mobile. Callers MUST check this before offering a PDF picker or
  /// before interpreting an empty [extractTextFromPdf] result.
  ///
  /// Without it, `admin_screen`'s Knowledge Base upload read the unconditional
  /// `''` below as "extraction ran and found nothing" and told the admin
  /// *"No text found in document. It may be image-based."* — a wrong diagnosis
  /// that sent them off to re-scan a perfectly good text PDF, on every Android
  /// upload. DOCX was unaffected, which made it look like a per-file problem
  /// rather than a per-platform one.
  static bool get isSupported => false;

  /// Always returns empty string on mobile — no pdf.js available.
  /// Check [isSupported] first; an empty result here does NOT mean the PDF is
  /// image-based.
  static Future<String> extractTextFromPdf(Uint8List pdfBytes) async {
    return '';
  }

  /// Returns a user-friendly message explaining this is web-only.
  static Future<String> processEbook({
    required Uint8List pdfBytes,
    required String bookTitle,
    void Function(int current, int total, String message)? onProgress,
  }) async {
    onProgress?.call(1, 1, 'Not available on mobile');
    return '// eBook → KB generation is a web-only feature.\n'
        '// Open the SAIL Safety Lens web app (PWA) and use\n'
        '// Admin Panel → eBook → Knowledge Base to generate KB entries.';
  }

  /// No-op on mobile — returns the input unchanged.
  static String flagDuplicates(String dartCode) => dartCode;
}
