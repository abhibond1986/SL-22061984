// lib/services/pdf_kb_extractor_web.dart
//
// WEB ONLY — compiled only for Flutter Web builds.
// Never import this file directly. Import pdf_kb_extractor.dart instead.
//
// Uses pdf.js 3.11.174 (loaded from cdnjs CDN at runtime).
// Zero new pubspec.yaml dependencies.
//
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
// dart:js_util removed — using only dart:js for consistent interop
import 'dart:typed_data';
// No package:http and no dart:convert: the one backend call here goes through
// SyncService.callAiText, which owns the URL, the prefs override, the app secret
// and the JSON/UTF-8 handling.
import 'sync_service.dart';

class PdfKbExtractor {
  // REMOVED 2026-09-03: a pinned `_appsScriptUrl` constant. It ignored the
  // `sync_backend_url` override and could not carry the `_appSecret` the
  // `gemini` action now requires.

  static const int _chunkSize = 3000;
  static bool _pdfJsLoaded = false;

  static Future<void> _ensurePdfJs() async {
    if (_pdfJsLoaded) return;
    final completer = Completer<void>();
    try {
      final existing = js.context['pdfjsLib'];
      if (existing != null) { _pdfJsLoaded = true; completer.complete(); }
    } catch (_) {}
    if (_pdfJsLoaded) return;

    final script = html.ScriptElement()
      ..src = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js'
      ..type = 'text/javascript'
      ..async = false;

    script.onLoad.listen((_) {
      js.context.callMethod('eval', [
        "pdfjsLib.GlobalWorkerOptions.workerSrc = "
        "'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';"
      ]);
      _pdfJsLoaded = true;
      completer.complete();
    });
    script.onError.listen((_) {
      completer.completeError(
          Exception('Failed to load pdf.js — check internet connection.'));
    });
    html.document.head!.append(script);
    await completer.future;
  }

  static Future<String> extractTextFromPdf(Uint8List pdfBytes) async {
    await _ensurePdfJs();

    // ★ v27 FIX: Use a callback approach to avoid dart:js JsObject ↔ dart:js_util
    // Promise interop issues. The JS function calls onSuccess/onError callbacks
    // which resolve a Dart Completer — no promiseToFuture needed.
    js.context.callMethod('eval', ['''
      if (!window.__safetyLensExtractPdf) {
        window.__safetyLensExtractPdf = function(byteArray, onSuccess, onError) {
          try {
            var uint8 = new Uint8Array(byteArray);
            var loadingTask = pdfjsLib.getDocument({data: uint8});
            loadingTask.promise.then(function(pdfDoc) {
              var numPages = pdfDoc.numPages;
              var textParts = [];
              var processed = 0;
              if (numPages === 0) { onSuccess(''); return; }
              for (var i = 1; i <= numPages; i++) {
                (function(pageNum) {
                  pdfDoc.getPage(pageNum).then(function(page) {
                    return page.getTextContent();
                  }).then(function(content) {
                    textParts[pageNum - 1] = content.items.map(function(item) { return item.str || ''; }).join(' ');
                  }).catch(function(e) {
                    textParts[pageNum - 1] = '[Page ' + pageNum + ': error]';
                  }).finally(function() {
                    processed++;
                    if (processed === numPages) {
                      onSuccess(textParts.join('\\n'));
                    }
                  });
                })(i);
              }
            }).catch(function(e) {
              onError('PDF load error: ' + (e.message || e));
            });
          } catch(e) {
            onError('PDF parse error: ' + (e.message || e));
          }
        };
      }
    ''']);

    final completer = Completer<String>();

    // Create JS callback functions that resolve our Dart Completer
    final onSuccess = js.JsFunction.withThis((thisArg, String text) {
      if (!completer.isCompleted) completer.complete(text);
    });
    final onError = js.JsFunction.withThis((thisArg, String error) {
      if (!completer.isCompleted) completer.completeError(Exception(error));
    });

    // Convert Dart bytes to JS array and call extraction with callbacks
    final jsArray = js.JsObject.jsify(pdfBytes.toList());
    js.context.callMethod('__safetyLensExtractPdf', [jsArray, onSuccess, onError]);

    final result = await completer.future;

    if (result.trim().isEmpty) {
      throw Exception('No text found in PDF — it may be image-based (scanned).');
    }

    return result.trim();
  }

  static List<String> _chunkText(String text) {
    final chunks = <String>[];
    int start = 0;
    while (start < text.length) {
      int end = (start + _chunkSize).clamp(0, text.length);
      if (end < text.length) {
        final boundary = text.lastIndexOf('.', end);
        if (boundary > start) end = boundary + 1;
      }
      final chunk = text.substring(start, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      start = end;
    }
    return chunks;
  }

  static Future<String> _generateKbFromChunk(
      String chunk, String bookTitle) async {
    final prompt =
        'You are a safety knowledge base builder for SAIL.\n\n'
        'Analyze this text from "$bookTitle" and extract key safety knowledge.\n\n'
        "Generate Dart code entries for a keyword→response map:\n\n"
        "      ['keyword1', 'keyword2']:\n"
        "        'Topic Title:\\n\\n• Point 1\\n• Point 2\\n\\nRef: Source',\n\n"
        'Rules:\n'
        '- 2–5 lowercase keywords per entry\n'
        '- Practical safety info only\n'
        '- Bullet points for lists, numbers for procedures\n'
        '- Include regulation refs where present\n'
        '- Generate 3–6 entries per chunk\n'
        '- Output ONLY Dart map entries, no ``` fences\n'
        '- If no safety content: output: // No safety content found in this chunk\n\n'
        'Text:\n---\n$chunk\n---';
    try {
      // 2026-09-03: was a raw http.post to a pinned _appsScriptUrl. Routed
      // through SyncService so it picks up the `sync_backend_url` override and
      // the `_appSecret` that the `gemini` action now requires.
      final data = await SyncService.callAiText(prompt);
      if (data == null) return '// Backend unreachable or refused';
      if (data['success'] == true) return data['result']?.toString() ?? '// No result';
      return '// Gemini error: ${data['error']}';
    } catch (e) {
      return '// Exception: $e';
    }
  }

  static Future<String> processEbook({
    required Uint8List pdfBytes,
    required String bookTitle,
    void Function(int current, int total, String message)? onProgress,
  }) async {
    onProgress?.call(0, 1, 'Extracting text from PDF…');
    final String fullText;
    try {
      fullText = await extractTextFromPdf(pdfBytes);
    } catch (e) {
      return '// ERROR: $e\n// Use Admin Panel → Add Text Entry to paste text manually.';
    }
    if (fullText.trim().isEmpty) {
      return '// ERROR: No text found — PDF may be image-based.\n'
          '// Use Admin Panel → Add Text Entry to paste text manually.';
    }
    final chunks = _chunkText(fullText);
    onProgress?.call(0, chunks.length, 'Text extracted. ${chunks.length} sections…');
    final output = StringBuffer()
      ..writeln('// ═══════════════════════════════════════')
      ..writeln('// KB entries from: $bookTitle')
      ..writeln('// Date: ${DateTime.now().toIso8601String()}')
      ..writeln('// Paste inside the kb map in local_ai.dart')
      ..writeln('// ═══════════════════════════════════════')
      ..writeln();
    int skipped = 0;
    for (int i = 0; i < chunks.length; i++) {
      onProgress?.call(i + 1, chunks.length,
          'Generating KB: section ${i + 1} of ${chunks.length}…');
      final result = await _generateKbFromChunk(chunks[i], bookTitle);
      final trimmed = result.trim();
      if (trimmed.startsWith('// No safety content')) { skipped++; continue; }
      output..writeln('      // — Section ${i + 1} —')..writeln(trimmed)..writeln();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    output
      ..writeln('// Total: ${chunks.length} | With content: ${chunks.length - skipped} | Skipped: $skipped');
    return output.toString();
  }

  static String flagDuplicates(String dartCode) {
    final pattern = RegExp(r"\['([^']+)'");
    final seen = <String, int>{};
    final result = StringBuffer();
    for (final line in dartCode.split('\n')) {
      bool hasDup = false;
      for (final m in pattern.allMatches(line)) {
        final kw = m.group(1)!;
        seen[kw] = (seen[kw] ?? 0) + 1;
        if (seen[kw]! > 1) hasDup = true;
      }
      if (hasDup) result.writeln('// ⚠️ DUPLICATE KEYWORD — review:');
      result.writeln(line);
    }
    return result.toString();
  }
}
