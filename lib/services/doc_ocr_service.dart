// lib/services/doc_ocr_service.dart
//
// Client for the self-hosted PaddleOCR service (see ocr_service/ in this repo).
//
// WHY THIS EXISTS
// The existing on-device OCR (google_mlkit_text_recognition, wired up in
// sop_ocr_device_mlkit.dart) has NO web implementation — sop_ocr_device.dart
// routes web to a stub. Safety Lens ships primarily as Flutter Web, so web
// users had no OCR path at all. This service fills that gap and additionally
// handles PDF and DOCX, which ML Kit never could.
//
// It talks to a plain HTTP service, NOT to Apps Script, because Apps Script
// cannot run Python. No API keys are involved on the Gemini side here, so
// there is no key-exposure concern; the optional shared token only rate-limits
// abuse of your own CPU quota.
//
// SET-UP: deploy ocr_service/ (Hugging Face Spaces free tier works — see
// ocr_service/README.md), then either edit [defaultServiceUrl] below or set
// the URL at runtime via [setServiceUrl] from the admin screen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One page of extracted text.
class DocPage {
  final int page;
  final String text;

  /// 'text-layer' (embedded PDF text), 'paddleocr' (real OCR), or 'docx'.
  final String method;

  /// Mean OCR box confidence 0..1. Null when no OCR ran on this page.
  final double? confidence;

  const DocPage({
    required this.page,
    required this.text,
    required this.method,
    this.confidence,
  });

  bool get isOcr => method == 'paddleocr';

  factory DocPage.fromJson(Map<String, dynamic> j) {
    return DocPage(
      page: (j['page'] as num?)?.toInt() ?? 0,
      text: (j['text'] ?? '').toString(),
      method: (j['method'] ?? '').toString(),
      confidence: (j['confidence'] as num?)?.toDouble(),
    );
  }
}

/// One retrievable chunk, normally a single SOP clause.
class DocChunk {
  final int index;
  final String text;
  final String? clauseNo;
  final String? heading;
  final int? pageFrom;
  final int? pageTo;

  const DocChunk({
    required this.index,
    required this.text,
    this.clauseNo,
    this.heading,
    this.pageFrom,
    this.pageTo,
  });

  factory DocChunk.fromJson(Map<String, dynamic> j) {
    return DocChunk(
      index: (j['index'] as num?)?.toInt() ?? 0,
      text: (j['text'] ?? '').toString(),
      clauseNo: (j['clause_no'] as String?)?.trim().isEmpty == true
          ? null
          : j['clause_no'] as String?,
      heading: (j['heading'] as String?)?.trim().isEmpty == true
          ? null
          : j['heading'] as String?,
      pageFrom: (j['page_from'] as num?)?.toInt(),
      pageTo: (j['page_to'] as num?)?.toInt(),
    );
  }

  /// Human-readable citation, e.g. "Clause 4.2.1 (p.3)".
  String get citation {
    final parts = <String>[];
    if (clauseNo != null) {
      parts.add('Clause $clauseNo');
    } else if (heading != null) {
      parts.add(heading!);
    }
    if (pageFrom != null) {
      parts.add(pageFrom == pageTo || pageTo == null
          ? 'p.$pageFrom'
          : 'pp.$pageFrom-$pageTo');
    }
    return parts.isEmpty ? 'Document extract' : parts.join(' · ');
  }
}

/// Result of a successful extraction.
class DocExtraction {
  final String fileName;
  final String kind; // pdf | docx | image | text
  final String text;
  final List<DocPage> pages;
  final List<DocChunk> chunks;

  final int pageCount;
  final int ocrPageCount;
  final int charCount;
  final double? meanConfidence;
  final bool ocrDerived;
  final bool truncated;
  final int elapsedMs;

  /// Set when extraction succeeded but produced no usable text.
  final String? note;

  const DocExtraction({
    required this.fileName,
    required this.kind,
    required this.text,
    required this.pages,
    required this.chunks,
    required this.pageCount,
    required this.ocrPageCount,
    required this.charCount,
    required this.meanConfidence,
    required this.ocrDerived,
    required this.truncated,
    required this.elapsedMs,
    this.note,
  });

  bool get isEmpty => text.trim().isEmpty;

  /// True when the text came from OCR with mediocre confidence, so the UI
  /// should warn the user before they act on a quoted clause. 0.80 is the
  /// point below which faded photocopies start dropping digits — and a
  /// misread digit in "isolate breaker 4" is exactly the kind of error that
  /// gets somebody hurt.
  bool get needsHumanCheck =>
      ocrDerived && (meanConfidence == null || meanConfidence! < 0.80);

  factory DocExtraction.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DocExtraction(
      fileName: (j['filename'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      text: (j['text'] ?? '').toString(),
      pages: ((j['pages'] as List?) ?? const [])
          .map((e) => DocPage.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      chunks: ((j['chunks'] as List?) ?? const [])
          .map((e) => DocChunk.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      pageCount: (meta['pageCount'] as num?)?.toInt() ?? 0,
      ocrPageCount: (meta['ocrPageCount'] as num?)?.toInt() ?? 0,
      charCount: (meta['charCount'] as num?)?.toInt() ?? 0,
      meanConfidence: (meta['meanConfidence'] as num?)?.toDouble(),
      ocrDerived: meta['ocrDerived'] == true,
      truncated: meta['truncated'] == true,
      elapsedMs: (meta['elapsedMs'] as num?)?.toInt() ?? 0,
      note: (j['note'] as String?),
    );
  }
}

/// Thrown with a message that is safe and useful to show a plant user.
class DocOcrException implements Exception {
  final String message;
  final int? statusCode;
  const DocOcrException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class DocOcrService {
  DocOcrService._();

  // ── Configuration ───────────────────────────────────────────────────────

  static const String kPrefsServiceUrl = 'doc_ocr_service_url';
  static const String kPrefsServiceToken = 'doc_ocr_service_token';

  /// Base URL of your deployed OCR service, with NO trailing slash.
  ///
  /// Hugging Face Spaces URLs look like:
  ///   https://<user>-<space-name>.hf.space
  ///
  /// Left blank on purpose: an unconfigured build then fails with a clear
  /// "not configured" message instead of silently timing out against a
  /// placeholder host. Override at build time with
  ///   --dart-define=DOC_OCR_URL=https://you-safetylens-ocr.hf.space
  static const String defaultServiceUrl = String.fromEnvironment(
    'DOC_OCR_URL',
    defaultValue: '',
  );

  /// Optional shared secret. This is NOT a Gemini key — it only stops
  /// strangers burning your OCR CPU quota. Safe enough to ship in the client,
  /// but treat it as public: anyone can read it out of the web bundle.
  static const String defaultServiceToken = String.fromEnvironment(
    'DOC_OCR_TOKEN',
    defaultValue: '',
  );

  static SharedPreferences? _prefs;

  /// OCR of a scanned 40-page SOP on a free CPU tier genuinely takes minutes.
  /// This is deliberately long; the UI shows progress so the wait is visible
  /// rather than looking like a hang.
  static const Duration extractTimeout = Duration(minutes: 5);
  static const Duration healthTimeout = Duration(seconds: 20);

  /// Free hosts suspend idle containers, so the first call after a sleep pays
  /// container boot + model load. Generous, and only used by [warmUp].
  static const Duration warmupTimeout = Duration(seconds: 90);

  static Future<String> getServiceUrl() async {
    _prefs ??= await SharedPreferences.getInstance();
    final saved = (_prefs!.getString(kPrefsServiceUrl) ?? '').trim();
    final url = saved.isNotEmpty ? saved : defaultServiceUrl;
    return _normaliseUrl(url);
  }

  static Future<void> setServiceUrl(String url) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(kPrefsServiceUrl, _normaliseUrl(url));
  }

  static Future<String> getServiceToken() async {
    _prefs ??= await SharedPreferences.getInstance();
    final saved = (_prefs!.getString(kPrefsServiceToken) ?? '').trim();
    return saved.isNotEmpty ? saved : defaultServiceToken;
  }

  static Future<void> setServiceToken(String token) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(kPrefsServiceToken, token.trim());
  }

  static String _normaliseUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    // A user pasting a bare host into the admin field is the likeliest
    // misconfiguration; default to https rather than failing obscurely.
    if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    return u;
  }

  static Future<bool> get isConfigured async =>
      (await getServiceUrl()).isNotEmpty;

  // ── Supported inputs ────────────────────────────────────────────────────

  /// Extensions to hand to FilePicker.
  ///
  /// MUST stay in sync with [kindOf] and with the service's _dispatch(). When
  /// this list was narrower than [kindOf], a user who typed a path or drag-
  /// dropped a .gif/.md/.csv got it silently filtered out by the picker even
  /// though the pipeline would have handled it — an invisible failure with no
  /// message to explain it. The service remains the authority and rejects
  /// anything it cannot read.
  static const List<String> pickerExtensions = <String>[
    'pdf', 'docx',
    'png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff', 'gif',
    'txt', 'md', 'csv',
  ];

  static const int maxUploadBytes = 25 * 1024 * 1024; // mirrors MAX_UPLOAD_MB

  static String kindOf(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    if (ext == 'pdf') return 'pdf';
    if (ext == 'docx') return 'docx';
    if (ext == 'doc') return 'legacyWord';
    if (ext == 'txt' || ext == 'md' || ext == 'csv') return 'text';
    if (const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff', 'gif']
        .contains(ext)) {
      return 'image';
    }
    return 'unsupported';
  }

  /// Strip the extension and tidy separators into a readable title.
  static String titleFromFileName(String fileName) {
    var name = fileName;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    name = name.replaceAll(RegExp(r'\s{2,}'), ' ');
    return name.isEmpty ? 'Untitled document' : name;
  }

  // ── Health / warm-up ────────────────────────────────────────────────────

  /// Returns null when healthy, or a human-readable problem description.
  static Future<String?> checkHealth() async {
    final base = await getServiceUrl();
    if (base.isEmpty) {
      return 'The OCR service URL is not configured. An administrator must '
          'set it in Settings before documents can be read.';
    }
    try {
      final resp = await http
          .get(Uri.parse('$base/health'))
          .timeout(healthTimeout);
      if (resp.statusCode != 200) {
        return 'The OCR service replied ${resp.statusCode}. It may still be '
            'starting up — please try again in a minute.';
      }
      if (resp.body.trimLeft().startsWith('<')) {
        return 'That URL returned a web page, not the OCR service. Please '
            'check the address.';
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['ok'] == true ? null : 'The OCR service reported a problem.';
    } on TimeoutException {
      return 'The OCR service did not respond. Free hosting suspends the '
          'service when idle; the first request can take up to a minute.';
    } catch (e) {
      return 'Could not reach the OCR service: $e';
    }
  }

  /// True when the model is already loaded, so the next extraction is fast.
  static Future<bool> isWarm() async {
    final base = await getServiceUrl();
    if (base.isEmpty) return false;
    try {
      final resp =
          await http.get(Uri.parse('$base/health')).timeout(healthTimeout);
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['modelWarm'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget model pre-load. Call when the Q&A screen opens so the
  /// model is warm by the time the user has picked a file. Never throws.
  static Future<void> warmUp({String lang = 'en'}) async {
    final base = await getServiceUrl();
    if (base.isEmpty) return;
    try {
      final token = await getServiceToken();
      final req = http.MultipartRequest('POST', Uri.parse('$base/warmup'))
        ..fields['lang'] = lang;
      if (token.isNotEmpty) req.fields['token'] = token;
      final streamed = await req.send().timeout(warmupTimeout);
      // Drain the body. An unread response stream keeps the underlying HTTP
      // connection checked out of the client's pool; leaving several of those
      // behind (the Q&A screen calls warmUp on every open) eventually stalls
      // the real extract request behind them.
      await streamed.stream.drain<void>().timeout(warmupTimeout);
    } catch (_) {
      // Warm-up is best-effort by design: a failure here must never block the
      // user, because the real extract call will surface any genuine problem.
    }
  }

  // ── Extraction ──────────────────────────────────────────────────────────

  /// Extract text (and chunks) from [bytes].
  ///
  /// Throws [DocOcrException] with a user-presentable message on failure.
  static Future<DocExtraction> extract({
    required String fileName,
    required Uint8List bytes,
    String lang = 'en',
    bool forceOcr = false,
    bool chunk = true,
  }) async {
    final base = await getServiceUrl();
    if (base.isEmpty) {
      throw const DocOcrException(
        'The OCR service is not configured yet. An administrator needs to set '
        'the service address in Settings.',
      );
    }

    if (bytes.isEmpty) {
      throw const DocOcrException('That file appears to be empty.');
    }
    if (bytes.length > maxUploadBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw DocOcrException(
        'That file is $mb MB. The limit is '
        '${maxUploadBytes ~/ (1024 * 1024)} MB — please split it into smaller '
        'documents.',
      );
    }

    final kind = kindOf(fileName);
    if (kind == 'legacyWord') {
      throw const DocOcrException(
        'Older .doc files are not supported. Open it in Word, choose '
        'Save As and pick .docx, then upload again.',
      );
    }
    if (kind == 'unsupported') {
      throw DocOcrException(
        'That file type is not supported. Please upload a PDF, a Word .docx, '
        'or a photo (JPG/PNG). File: $fileName',
      );
    }

    final token = await getServiceToken();

    try {
      final req = http.MultipartRequest('POST', Uri.parse('$base/extract'))
        ..fields['lang'] = lang
        ..fields['forceOcr'] = forceOcr.toString()
        ..fields['chunk'] = chunk.toString()
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ));
      if (token.isNotEmpty) req.fields['token'] = token;

      final streamed = await req.send().timeout(extractTimeout);
      // The timeout on send() only bounds the RESPONSE HEADERS. Without a
      // second timeout here, a stalled response body leaves the user watching
      // a spinner forever with no error ever raised.
      final resp =
          await http.Response.fromStream(streamed).timeout(extractTimeout);

      return _parseExtractResponse(resp);
    } on TimeoutException {
      throw const DocOcrException(
        'Reading the document took too long and was stopped. Scanned '
        'documents are slow to read — try uploading fewer pages at a time.',
      );
    } on DocOcrException {
      rethrow;
    } catch (e) {
      // On web a CORS rejection surfaces here as an opaque ClientException
      // with no useful detail, so name the likely cause explicitly rather
      // than showing the user a raw exception.
      final hint = kIsWeb
          ? ' If this keeps happening, the OCR service may need this site '
              'added to its ALLOWED_ORIGINS setting.'
          : '';
      throw DocOcrException('Could not reach the OCR service.$hint ($e)');
    }
  }

  static DocExtraction _parseExtractResponse(http.Response resp) {
    // Check for an HTML body BEFORE decoding: hosting platforms return HTML
    // error/queue pages, and jsonDecode would otherwise throw a
    // FormatException that tells nobody anything useful.
    if (resp.body.trimLeft().startsWith('<')) {
      throw DocOcrException(
        'The OCR service returned a web page instead of a result '
        '(HTTP ${resp.statusCode}). It may be starting up or sleeping — '
        'please wait a minute and try again.',
        statusCode: resp.statusCode,
      );
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw DocOcrException(
        'The OCR service sent a reply that could not be understood '
        '(HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }

    if (resp.statusCode != 200) {
      // FastAPI puts human-readable text in `detail`; our own handlers write
      // messages there that are already phrased for a plant user.
      final detail = (data['detail'] ?? data['error'] ?? '').toString();
      throw DocOcrException(
        detail.isNotEmpty
            ? detail
            : 'The OCR service failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }

    if (data['ok'] != true) {
      throw DocOcrException(
        (data['detail'] ?? data['error'] ?? 'Extraction failed.').toString(),
      );
    }

    return DocExtraction.fromJson(data);
  }
}
