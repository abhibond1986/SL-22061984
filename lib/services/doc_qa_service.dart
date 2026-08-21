// lib/services/doc_qa_service.dart
//
// Orchestrates the Document Q&A flow:
//
//   upload -> Supabase Storage
//          -> PaddleOCR service (extract + chunk)
//          -> doc_library + doc_chunks rows
//          -> question -> retrieve chunks -> Gemini (via Apps Script) -> answer
//
// DESIGN DECISIONS WORTH KNOWING
//
// * Retrieval runs in Postgres (search_doc_chunks RPC), not on the client, so
//   we never download a whole document just to rank it. There is a local
//   keyword fallback for when the RPC is unavailable — see [_rankLocally].
//
// * There are NO vector embeddings. That is deliberate and matches the rest of
//   this project (LocalDB.searchKnowledge is keyword + synonym scoring).
//   Safety queries lean hard on exact tokens — "LOTO", "SOP 4.2.1", "H2S",
//   "EOT crane" — which lexical search handles better than embeddings blur.
//
// * Answers are GROUNDED: the model is instructed to use only the supplied
//   extracts and to refuse otherwise. A confidently invented answer about an
//   isolation procedure is more dangerous than "the document does not say".
//
// * The Gemini call goes through Apps Script (DocQaProxy.gs). Never call
//   Gemini from the client — Google disabled this project's keys once already
//   after detecting them in browser traffic.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List, debugPrint;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'doc_ocr_service.dart';
import 'nara_vision.dart' show NaraVision;
import 'supabase_service.dart' show SupabaseService;

/// A stored document.
class DocLibraryItem {
  final int? id;
  final String clientId;
  final String title;
  final String fileName;
  final String fileKind;
  final int pageCount;
  final int chunkCount;
  final int charCount;
  final bool ocrDerived;
  final double? meanConfidence;
  final String status;
  final String? errorMessage;
  final DateTime? createdAt;

  /// Chunks held in memory for THIS session.
  ///
  /// Populated straight after ingest and, crucially, on the fallback paths
  /// where the database write failed or Supabase is switched off. Without it
  /// those paths have no `id` and no chunks, so every question would fall to
  /// the local ranker with an empty list and answer "I could not find
  /// anything" — silently defeating the offline design. Empty for documents
  /// loaded back out of the database, which retrieve server-side by `id`.
  final List<DocChunk> chunks;

  const DocLibraryItem({
    this.id,
    required this.clientId,
    required this.title,
    required this.fileName,
    required this.fileKind,
    this.pageCount = 0,
    this.chunkCount = 0,
    this.charCount = 0,
    this.ocrDerived = false,
    this.meanConfidence,
    this.status = 'pending',
    this.errorMessage,
    this.createdAt,
    this.chunks = const [],
  });

  bool get isReady => status == 'ready';

  /// OCR text below 0.80 mean confidence should be human-checked before
  /// anyone acts on a quoted figure.
  bool get needsHumanCheck =>
      ocrDerived && (meanConfidence == null || meanConfidence! < 0.80);

  factory DocLibraryItem.fromRow(Map<String, dynamic> r) {
    return DocLibraryItem(
      id: (r['id'] as num?)?.toInt(),
      clientId: (r['client_id'] ?? '').toString(),
      title: (r['title'] ?? '').toString(),
      fileName: (r['file_name'] ?? '').toString(),
      fileKind: (r['file_kind'] ?? '').toString(),
      pageCount: (r['page_count'] as num?)?.toInt() ?? 0,
      chunkCount: (r['chunk_count'] as num?)?.toInt() ?? 0,
      charCount: (r['char_count'] as num?)?.toInt() ?? 0,
      ocrDerived: r['ocr_derived'] == true,
      meanConfidence: (r['mean_confidence'] as num?)?.toDouble(),
      status: (r['status'] ?? 'pending').toString(),
      errorMessage: r['error_message'] as String?,
      createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()),
    );
  }
}

/// A chunk retrieved for a question, with its relevance score.
class RetrievedChunk {
  final int? id;
  final String content;
  final String? clauseNo;
  final String? heading;
  final int? pageFrom;
  final int? pageTo;
  final double score;

  const RetrievedChunk({
    this.id,
    required this.content,
    this.clauseNo,
    this.heading,
    this.pageFrom,
    this.pageTo,
    this.score = 0,
  });

  String get citation {
    final parts = <String>[];
    if (clauseNo != null && clauseNo!.isNotEmpty) {
      parts.add('Clause $clauseNo');
    } else if (heading != null && heading!.isNotEmpty) {
      parts.add(heading!);
    }
    if (pageFrom != null) {
      parts.add((pageTo == null || pageTo == pageFrom)
          ? 'p.$pageFrom'
          : 'pp.$pageFrom-$pageTo');
    }
    return parts.isEmpty ? 'Extract' : parts.join(' · ');
  }

  factory RetrievedChunk.fromRow(Map<String, dynamic> r) {
    return RetrievedChunk(
      id: (r['id'] as num?)?.toInt(),
      content: (r['content'] ?? '').toString(),
      clauseNo: r['clause_no'] as String?,
      heading: r['heading'] as String?,
      pageFrom: (r['page_from'] as num?)?.toInt(),
      pageTo: (r['page_to'] as num?)?.toInt(),
      score: (r['score'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// An answer plus the extracts it was built from.
class DocAnswer {
  final String answer;
  final List<RetrievedChunk> sources;

  /// 'high' | 'medium' | 'low' | 'none'
  final String confidence;
  final String model;
  final int latencyMs;
  final bool fromCache;

  /// True when the answer came from keyword extraction because the AI was
  /// unreachable. The UI must label these — they are raw document text, not
  /// a synthesised answer.
  final bool extractive;

  const DocAnswer({
    required this.answer,
    this.sources = const [],
    this.confidence = 'medium',
    this.model = '',
    this.latencyMs = 0,
    this.fromCache = false,
    this.extractive = false,
  });

  /// Whether the UI should show a "verify this yourself" warning.
  bool get isWeak =>
      extractive || confidence == 'low' || confidence == 'none';
}

class DocQaService {
  DocQaService._();

  static SupabaseClient get _db => Supabase.instance.client;

  /// MUST be SupabaseService.isReady, not SupabaseConfig.enabled: the latter
  /// only says the feature flag is on, while Supabase.instance.client THROWS
  /// if Supabase.initialize() has not run yet. isReady checks both.
  static bool get _ready => SupabaseService.isReady;

  /// Surfaced in the UI when something fails, mirroring the
  /// `incidentsLastError` convention in SupabaseService.
  static String lastError = '';

  static const String bucket = 'doc-library';

  /// How many chunks to feed the model. Six ~1400-char chunks is ~2k tokens:
  /// enough coverage for a multi-part question, small enough that the model
  /// does not lose the question among the context.
  static const int retrieveLimit = 6;

  static const Duration answerTimeout = Duration(seconds: 45);

  // ══════════════════════════════════════════════════════════════════════
  //  INGEST
  // ══════════════════════════════════════════════════════════════════════

  /// Upload, extract and store a document.
  ///
  /// [onProgress] receives short status strings for the UI.
  /// Throws [DocOcrException] with a user-presentable message on failure.
  static Future<DocLibraryItem> ingest({
    required String fileName,
    required Uint8List bytes,
    String? title,
    String lang = 'en',
    String? plant,
    String? createdBy,
    bool forceOcr = false,
    void Function(String status)? onProgress,
  }) async {
    lastError = '';
    final clientId = _docClientId(fileName, bytes.length);
    final docTitle = (title == null || title.trim().isEmpty)
        ? DocOcrService.titleFromFileName(fileName)
        : title.trim();

    // ── 1. Extract FIRST, before writing anything ────────────────────────
    // Extraction is the step that actually fails (unsupported file, blank
    // scan, service asleep). Doing it first avoids littering doc_library with
    // 'failed' rows for files that were never viable, which would otherwise
    // fill the user's document list with rubbish they have to clean up.
    onProgress?.call('Reading the document…');
    // No try/catch here on purpose. DocOcrService.extract already converts
    // every failure into a DocOcrException carrying a message written for a
    // plant user, so wrapping it just to rethrow would add nothing. Callers
    // catch DocOcrException and show `message` directly.
    final extraction = await DocOcrService.extract(
      fileName: fileName,
      bytes: bytes,
      lang: lang,
      forceOcr: forceOcr,
    );

    if (extraction.isEmpty) {
      throw DocOcrException(
        extraction.note ??
            'No readable text was found in that file. If it is a photo, try '
                'better lighting and hold the camera square to the page.',
      );
    }

    onProgress?.call(
      'Read ${extraction.charCount} characters '
      '(${extraction.chunks.length} sections).',
    );

    // ── 2. Upload the original (best-effort) ─────────────────────────────
    // A failed upload must NOT sink the ingest: the extracted text is the
    // valuable part and is already in hand. Losing the ability to re-download
    // the original is a minor inconvenience by comparison.
    String? storagePath;
    String? storageUrl;
    if (_ready) {
      onProgress?.call('Saving the file…');
      final uploaded = await _uploadOriginal(clientId, fileName, bytes);
      storagePath = uploaded?.$1;
      storageUrl = uploaded?.$2;
    }

    // ── 3. Persist ───────────────────────────────────────────────────────
    if (!_ready) {
      // Supabase off: still return the extraction so the session works
      // in-memory. Q&A will use the local fallback ranker.
      return DocLibraryItem(
        clientId: clientId,
        title: docTitle,
        fileName: fileName,
        fileKind: extraction.kind,
        pageCount: extraction.pageCount,
        chunkCount: extraction.chunks.length,
        charCount: extraction.charCount,
        ocrDerived: extraction.ocrDerived,
        meanConfidence: extraction.meanConfidence,
        status: 'ready',
        chunks: extraction.chunks,
      );
    }

    onProgress?.call('Indexing sections…');

    final row = <String, dynamic>{
      'client_id': clientId,
      'title': docTitle,
      'file_name': fileName,
      'file_kind': extraction.kind,
      'file_size': bytes.length,
      'storage_path': storagePath,
      'storage_url': storageUrl,
      'page_count': extraction.pageCount,
      'ocr_page_count': extraction.ocrPageCount,
      'char_count': extraction.charCount,
      'chunk_count': extraction.chunks.length,
      'mean_confidence': extraction.meanConfidence,
      'ocr_derived': extraction.ocrDerived,
      'truncated': extraction.truncated,
      'status': 'ready',
      'full_text': extraction.text,
      'plant': plant,
      'created_by': createdBy,
      'language': lang,
    };

    int? documentId;
    try {
      final inserted = await _db
          .from('doc_library')
          .upsert(row, onConflict: 'client_id')
          .select('id')
          .timeout(const Duration(seconds: 30));
      final list = inserted as List;
      if (list.isNotEmpty) {
        documentId = ((list.first as Map)['id'] as num?)?.toInt();
      }
    } catch (e) {
      lastError = _describe(e);
      debugPrint('DocQaService.ingest: doc_library insert failed -> $lastError');
      // Fall through: return the extraction so the user can still ask
      // questions this session via the local ranker.
      return DocLibraryItem(
        clientId: clientId,
        title: docTitle,
        fileName: fileName,
        fileKind: extraction.kind,
        pageCount: extraction.pageCount,
        chunkCount: extraction.chunks.length,
        charCount: extraction.charCount,
        ocrDerived: extraction.ocrDerived,
        meanConfidence: extraction.meanConfidence,
        status: 'ready',
        errorMessage: 'Saved for this session only: $lastError',
        chunks: extraction.chunks,
      );
    }

    if (documentId != null && extraction.chunks.isNotEmpty) {
      await _insertChunks(documentId, clientId, extraction.chunks);
    }

    return DocLibraryItem(
      id: documentId,
      clientId: clientId,
      title: docTitle,
      fileName: fileName,
      fileKind: extraction.kind,
      pageCount: extraction.pageCount,
      chunkCount: extraction.chunks.length,
      charCount: extraction.charCount,
      ocrDerived: extraction.ocrDerived,
      meanConfidence: extraction.meanConfidence,
      status: 'ready',
      chunks: extraction.chunks,
    );
  }

  /// Returns (path, publicUrl) or null. Never throws.
  static Future<(String, String)?> _uploadOriginal(
      String clientId, String fileName, Uint8List bytes) async {
    final safeName = fileName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_{2,}'), '_');
    final path = 'doc_${clientId}_$safeName';
    final contentType = _mimeFor(fileName);

    try {
      await _db.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: contentType, upsert: false),
          );
      return (path, _db.storage.from(bucket).getPublicUrl(path));
    } catch (_) {
      // The bucket may only carry INSERT+SELECT policies, so a re-upload of
      // the same path needs upsert. Same two-step fallback as
      // SupabaseService.uploadIncidentImage.
      try {
        await _db.storage.from(bucket).uploadBinary(
              path,
              bytes,
              fileOptions: FileOptions(contentType: contentType, upsert: true),
            );
        return (path, _db.storage.from(bucket).getPublicUrl(path));
      } catch (e) {
        debugPrint('DocQaService: original upload failed -> ${_describe(e)}');
        return null;
      }
    }
  }

  static Future<void> _insertChunks(
      int documentId, String clientId, List<DocChunk> chunks) async {
    // Clear first. Because client_id is now deterministic, re-uploading the
    // same file UPDATES the doc_library row instead of adding one — so without
    // this delete the chunks would accumulate a second time and retrieval would
    // return the same clause twice, wasting context and making the answer look
    // like the document repeats itself.
    try {
      await _db
          .from('doc_chunks')
          .delete()
          .eq('document_id', documentId)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('DocQaService: chunk clear failed -> ${_describe(e)}');
    }

    final rows = chunks
        .map((c) => <String, dynamic>{
              'document_id': documentId,
              'doc_client_id': clientId,
              'chunk_index': c.index,
              'content': c.text,
              'clause_no': c.clauseNo,
              'heading': c.heading,
              'page_from': c.pageFrom,
              'page_to': c.pageTo,
              'char_count': c.text.length,
              'indexed': true,
            })
        .toList();

    // Batch the insert. A 300-page SOP yields hundreds of chunks and one
    // giant request risks a PostgREST payload limit or a timeout, which would
    // lose every chunk rather than one batch.
    const batchSize = 100;
    for (var i = 0; i < rows.length; i += batchSize) {
      final end = (i + batchSize < rows.length) ? i + batchSize : rows.length;
      try {
        await _db
            .from('doc_chunks')
            .insert(rows.sublist(i, end))
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        lastError = _describe(e);
        debugPrint('DocQaService: chunk batch $i failed -> $lastError');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  RETRIEVAL
  // ══════════════════════════════════════════════════════════════════════

  /// Rank chunks for [question] against one document.
  ///
  /// Prefers the Postgres RPC; falls back to local scoring over
  /// [localChunks] when the RPC is unavailable (Supabase off, migration not
  /// run, or the document was only stored in-session).
  static Future<List<RetrievedChunk>> retrieve({
    int? documentId,
    required String question,
    List<DocChunk> localChunks = const [],
    int limit = retrieveLimit,
  }) async {
    if (_ready && documentId != null) {
      try {
        final res = await _db.rpc('search_doc_chunks', params: {
          'p_document_id': documentId,
          'p_query': question,
          'p_limit': limit,
        }).timeout(const Duration(seconds: 20));

        final list = (res as List?) ?? const [];
        if (list.isNotEmpty) {
          return list
              .map((r) =>
                  RetrievedChunk.fromRow((r as Map).cast<String, dynamic>()))
              .toList();
        }
        // Empty is a legitimate answer (nothing matched), but if we hold local
        // chunks it is worth a second opinion before telling the user no.
        if (localChunks.isEmpty) return const [];
      } catch (e) {
        lastError = _describe(e);
        debugPrint('DocQaService.retrieve: RPC failed -> $lastError');
        // A missing function (migration_doc_qa.sql not run) lands here.
        if (localChunks.isEmpty) {
          final fetched = await _fetchAllChunks(documentId);
          return _rankLocally(question, fetched, limit);
        }
      }
    }

    return _rankLocally(question, localChunks, limit);
  }

  static Future<List<DocChunk>> _fetchAllChunks(int documentId) async {
    try {
      final rows = await _db
          .from('doc_chunks')
          .select('id, content, clause_no, heading, page_from, page_to, chunk_index')
          .eq('document_id', documentId)
          .eq('indexed', true)
          // ascending MUST be explicit: postgrest-dart's .order() defaults to
          // DESCENDING, which would hand back the document backwards.
          .order('chunk_index', ascending: true)
          .timeout(const Duration(seconds: 25));
      return ((rows as List?) ?? const [])
          .map((r) {
            final m = (r as Map).cast<String, dynamic>();
            return DocChunk(
              index: (m['chunk_index'] as num?)?.toInt() ?? 0,
              text: (m['content'] ?? '').toString(),
              clauseNo: m['clause_no'] as String?,
              heading: m['heading'] as String?,
              pageFrom: (m['page_from'] as num?)?.toInt(),
              pageTo: (m['page_to'] as num?)?.toInt(),
            );
          })
          .toList();
    } catch (e) {
      debugPrint('DocQaService: chunk fetch failed -> ${_describe(e)}');
      return const [];
    }
  }

  /// Safety-term synonyms, deliberately aligned with LocalDB._safetySynonyms
  /// so online and offline retrieval behave the same way. Without these,
  /// "lockout" fails to find a clause that only ever says "LOTO" — which in
  /// SAIL SOPs is most of them.
  static const Map<String, List<String>> _synonyms = {
    'loto': ['lockout', 'tagout', 'isolation', 'isolate', 'de-energise'],
    'lockout': ['loto', 'tagout', 'isolation', 'isolate'],
    'tagout': ['loto', 'lockout', 'isolation'],
    'ppe': [
      'helmet', 'gloves', 'goggles', 'shield', 'boots', 'harness',
      'respirator', 'mask', 'apron', 'suit'
    ],
    'helmet': ['ppe', 'hard hat', 'head protection'],
    'height': ['fall', 'harness', 'scaffold', 'ladder', 'platform', 'railing'],
    'fall': ['height', 'harness', 'guard rail', 'railing'],
    'crane': ['hoist', 'lifting', 'sling', 'eot', 'load'],
    'lifting': ['crane', 'hoist', 'sling', 'load'],
    'gas': ['leak', 'co', 'h2s', 'oxygen', 'asphyxiation', 'toxic'],
    'confined': ['vessel', 'tank', 'manhole', 'entry', 'oxygen'],
    'hot': ['molten', 'ladle', 'furnace', 'burn', 'radiant', 'slag'],
    'permit': ['clearance', 'authorisation', 'work permit', 'sanction'],
    'fire': ['extinguisher', 'hydrant', 'evacuation', 'alarm'],
    'electrical': ['shock', 'earthing', 'breaker', 'isolator', 'live'],
    'emergency': ['evacuation', 'alarm', 'assembly', 'rescue', 'first aid'],
  };

  /// Local keyword+synonym ranker — the offline mirror of search_doc_chunks.
  static List<RetrievedChunk> _rankLocally(
      String question, List<DocChunk> chunks, int limit) {
    if (chunks.isEmpty) return const [];

    final raw = question.toLowerCase().trim();
    if (raw.isEmpty) return const [];

    // Drop question words: they appear in every chunk and in every question,
    // so they add noise and no discrimination.
    const stop = {
      'what', 'which', 'when', 'where', 'who', 'why', 'how', 'the', 'and',
      'for', 'are', 'is', 'was', 'were', 'do', 'does', 'did', 'can', 'should',
      'must', 'may', 'this', 'that', 'with', 'from', 'have', 'has', 'any',
      'all', 'need', 'needed', 'required', 'about', 'into', 'not', 'you',
      'your', 'there', 'they', 'them', 'will', 'would', 'been', 'being',
    };

    final words = raw
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 1 && !stop.contains(w))
        .toSet()
        .toList();

    if (words.isEmpty) return const [];

    final scored = <(double, DocChunk)>[];

    for (final chunk in chunks) {
      final body = chunk.text.toLowerCase();
      final heading = (chunk.heading ?? '').toLowerCase();
      var score = 0.0;

      for (final word in words) {
        final hits = _countOccurrences(body, word);
        if (hits > 0) score += hits;
        if (heading.contains(word)) score += 5;

        for (final syn in (_synonyms[word] ?? const <String>[])) {
          final synHits = _countOccurrences(body, syn);
          if (synHits > 0) score += synHits * 0.5;
          if (heading.contains(syn)) score += 2;
        }
      }

      // Exact phrase match is the strongest signal there is.
      if (body.contains(raw)) score += 10;

      // A question naming a clause ("what does 4.2.1 say") should surface that
      // clause even if it shares no other vocabulary with the question.
      if (chunk.clauseNo != null && raw.contains(chunk.clauseNo!)) score += 12;

      if (score > 0) scored.add((score, chunk));
    }

    scored.sort((a, b) => b.$1.compareTo(a.$1));

    return scored
        .take(limit)
        .map((e) => RetrievedChunk(
              content: e.$2.text,
              clauseNo: e.$2.clauseNo,
              heading: e.$2.heading,
              pageFrom: e.$2.pageFrom,
              pageTo: e.$2.pageTo,
              score: e.$1,
            ))
        .toList();
  }

  static int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var index = haystack.indexOf(needle);
    while (index != -1) {
      count++;
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ASK
  // ══════════════════════════════════════════════════════════════════════

  /// Answer [question] about a document.
  static Future<DocAnswer> ask({
    required String question,
    int? documentId,
    String? documentTitle,
    List<DocChunk> localChunks = const [],
    bool ocrDerived = false,
    String language = 'en',
    String? askedBy,
    String? plant,
    bool useCache = true,
  }) async {
    lastError = '';
    final started = DateTime.now();
    final trimmed = question.trim();

    if (trimmed.isEmpty) {
      return const DocAnswer(
        answer: 'Please type a question first.',
        confidence: 'none',
      );
    }

    final key = _questionKey(trimmed);

    // ── 1. Cache ──────────────────────────────────────────────────────────
    if (useCache && _ready && documentId != null) {
      final cached = await _cachedAnswer(documentId, key);
      if (cached != null) return cached;
    }

    // ── 2. Retrieve ───────────────────────────────────────────────────────
    final chunks = await retrieve(
      documentId: documentId,
      question: trimmed,
      localChunks: localChunks,
    );

    if (chunks.isEmpty) {
      // Answer locally instead of spending a model call to say "I don't know".
      return DocAnswer(
        answer: 'I could not find anything about that in this document. Try '
            'different words — for example the exact term the document would '
            'use — or check that you opened the right document.',
        confidence: 'none',
        latencyMs: DateTime.now().difference(started).inMilliseconds,
      );
    }

    // ── 3. Ask Gemini via Apps Script ─────────────────────────────────────
    final context = _buildContext(chunks);
    DocAnswer answer;
    try {
      answer = await _askGemini(
        question: trimmed,
        context: context,
        title: documentTitle,
        language: language,
        ocrDerived: ocrDerived,
        chunks: chunks,
        started: started,
      );
    } catch (e) {
      lastError = _describe(e);
      debugPrint('DocQaService.ask: AI failed -> $lastError');
      answer = _extractiveAnswer(chunks, started);
    }

    // ── 4. Log (best-effort) ──────────────────────────────────────────────
    if (_ready && documentId != null) {
      _logQuestion(
        documentId: documentId,
        question: trimmed,
        questionKey: key,
        answer: answer,
        askedBy: askedBy,
        plant: plant,
      ); // intentionally not awaited: logging must not delay the answer
    }

    return answer;
  }

  /// Numbered extracts. Numbering matters: the model cites [1], [2], and the
  /// UI maps those back to these chunks so "show source" works.
  static String _buildContext(List<RetrievedChunk> chunks) {
    final sb = StringBuffer();
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      sb.writeln('[${i + 1}] ${c.citation}');
      sb.writeln(c.content.trim());
      sb.writeln();
    }
    return sb.toString().trim();
  }

  static Future<DocAnswer> _askGemini({
    required String question,
    required String context,
    required String? title,
    required String language,
    required bool ocrDerived,
    required List<RetrievedChunk> chunks,
    required DateTime started,
  }) async {
    // Reuse the Nara proxy URL: DocQaProxy.gs is installed in that same
    // Apps Script project, so there is one deployment to manage, not two.
    final url = await NaraVision.getProxyUrl();
    if (url.isEmpty) {
      throw const DocOcrException('The AI service address is not configured.');
    }

    final body = <String, dynamic>{
      'action': 'answerFromDocument',
      'question': question,
      'context': context,
      'title': title ?? '',
      'language': language,
      'unverified': ocrDerived,
    };

    // text/plain, NOT application/json: application/json triggers a CORS
    // preflight that Apps Script cannot answer (it has no doOptions), so the
    // POST is blocked before it is sent. Apps Script reads
    // e.postData.contents either way. See nara_vision.dart for the long note.
    final resp = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode(body),
        )
        .timeout(answerTimeout);

    // Apps Script serves HTML error pages for archived deployments or wrong
    // access settings. Checking first turns a cryptic FormatException into a
    // diagnosable message.
    if (resp.body.trimLeft().startsWith('<')) {
      throw const DocOcrException(
        'The AI service returned a web page instead of an answer. The Apps '
        'Script deployment may need "Who has access: Anyone".',
      );
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['ok'] != true) {
      throw DocOcrException(
        (data['error'] ?? 'The AI service reported an error.').toString(),
      );
    }

    // `body` is double-encoded by design (it mirrors handleAnalyzeImageNara_'s
    // envelope). A null here means ok:true arrived without a payload, which
    // would otherwise become the literal string "null" and then fail to decode
    // with a FormatException that names neither cause.
    final rawBody = data['body'];
    if (rawBody == null || rawBody.toString().trim().isEmpty) {
      throw const DocOcrException(
        'The AI service replied without an answer. Check that DocQaProxy.gs is '
        'installed in the Apps Script project and redeployed.',
      );
    }
    final inner = jsonDecode(rawBody.toString()) as Map<String, dynamic>;

    // Map the model's [1],[2] citations back onto real chunks. 1-based in the
    // prompt, so subtract 1; out-of-range indices are dropped rather than
    // trusted, because a hallucinated citation would attach a real clause
    // number to text it did not come from.
    //
    // num.tryParse, not `as num?`: models sometimes emit sources as strings
    // ("1") or as "[1]", and a cast would throw and lose an otherwise perfectly
    // good answer over a formatting detail.
    final cited = <RetrievedChunk>[];
    for (final s in ((inner['sources'] as List?) ?? const [])) {
      final n = s is num
          ? s.toInt()
          : int.tryParse(s.toString().replaceAll(RegExp(r'[^0-9]'), ''));
      if (n != null && n >= 1 && n <= chunks.length) cited.add(chunks[n - 1]);
    }

    final answerText = (inner['answer'] ?? '').toString().trim();
    // Empty means the model returned nothing usable. Throwing hands control to
    // ask()'s catch, which falls back to the extractive answer — showing the
    // user the relevant clauses verbatim is far better than an empty bubble
    // that looks like the app broke.
    if (answerText.isEmpty) {
      throw const DocOcrException('The AI returned an empty answer.');
    }

    return DocAnswer(
      answer: answerText,
      // If the model cited nothing, show the retrieved chunks anyway so the
      // user always has something to verify against.
      sources: cited.isNotEmpty ? cited : chunks.take(3).toList(),
      confidence: (inner['confidence'] ?? 'medium').toString(),
      model: (inner['model'] ?? '').toString(),
      latencyMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  /// Last resort when the AI is unreachable: hand back the best-matching
  /// extracts verbatim. Clearly labelled as extractive so nobody mistakes raw
  /// document text for a considered answer.
  static DocAnswer _extractiveAnswer(
      List<RetrievedChunk> chunks, DateTime started) {
    final sb = StringBuffer()
      ..writeln('The AI assistant is unavailable, so here are the most '
          'relevant parts of the document. Please read them yourself:')
      ..writeln();
    for (final c in chunks.take(3)) {
      sb.writeln('— ${c.citation}');
      final text = c.content.trim();
      sb.writeln(text.length > 600 ? '${text.substring(0, 600)}…' : text);
      sb.writeln();
    }
    return DocAnswer(
      answer: sb.toString().trim(),
      sources: chunks.take(3).toList(),
      confidence: 'low',
      extractive: true,
      latencyMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  CACHE / LOG / LIST
  // ══════════════════════════════════════════════════════════════════════

  static Future<DocAnswer?> _cachedAnswer(int documentId, String key) async {
    try {
      final rows = await _db
          .from('doc_questions')
          .select('answer, sources, model, chunk_count')
          .eq('document_id', documentId)
          .eq('question_key', key)
          // Only reuse answers a human did not mark unhelpful. `not helpful
          // is false` keeps NULL (no feedback) rows, which are the majority.
          .not('helpful', 'is', false)
          .not('answer', 'is', null)
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 12));

      final list = (rows as List?) ?? const [];
      if (list.isEmpty) return null;

      final r = (list.first as Map).cast<String, dynamic>();
      final answer = (r['answer'] ?? '').toString();
      if (answer.trim().isEmpty) return null;

      final sources = <RetrievedChunk>[];
      for (final s in ((r['sources'] as List?) ?? const [])) {
        final m = (s as Map).cast<String, dynamic>();
        sources.add(RetrievedChunk(
          id: (m['chunkId'] as num?)?.toInt(),
          content: (m['content'] ?? '').toString(),
          clauseNo: m['clauseNo'] as String?,
          pageFrom: (m['pageFrom'] as num?)?.toInt(),
        ));
      }

      return DocAnswer(
        answer: answer,
        sources: sources,
        model: (r['model'] ?? '').toString(),
        fromCache: true,
        // Cached answers keep 'medium': the stored row does not carry the
        // original confidence, and inventing 'high' here would overstate it.
        confidence: 'medium',
      );
    } catch (e) {
      debugPrint('DocQaService: cache lookup failed -> ${_describe(e)}');
      return null;
    }
  }

  static Future<void> _logQuestion({
    required int documentId,
    required String question,
    required String questionKey,
    required DocAnswer answer,
    String? askedBy,
    String? plant,
  }) async {
    try {
      await _db.from('doc_questions').insert({
        'client_id': _newClientId(),
        'document_id': documentId,
        'question': question,
        'question_key': questionKey,
        'answer': answer.answer,
        'sources': answer.sources
            .map((s) => {
                  'chunkId': s.id,
                  'clauseNo': s.clauseNo,
                  'pageFrom': s.pageFrom,
                  'score': s.score,
                  // Store a snippet so a cached answer can still show its
                  // sources without re-querying doc_chunks.
                  'content': s.content.length > 400
                      ? s.content.substring(0, 400)
                      : s.content,
                })
            .toList(),
        'model': answer.model,
        'answered_by': answer.extractive ? 'extractive' : 'gemini',
        'latency_ms': answer.latencyMs,
        'chunk_count': answer.sources.length,
        'asked_by': askedBy,
        'plant': plant,
      }).timeout(const Duration(seconds: 15));
    } catch (e) {
      // Never surface a logging failure: the user already has their answer.
      debugPrint('DocQaService: question log failed -> ${_describe(e)}');
    }
  }

  /// Record whether an answer helped. Feeds the same review loop as
  /// ai_corrections, and suppresses bad answers from the cache.
  ///
  /// Returns true only if a row was actually updated. This matters because
  /// `_logQuestion` is fired and NOT awaited, so a user who rates quickly can
  /// race it and match zero rows — and a UI that says "thanks, noted" over a
  /// no-op teaches people their feedback is being collected when it is not.
  static Future<bool> rateAnswer({
    required int documentId,
    required String question,
    required bool helpful,
  }) async {
    if (!_ready) return false;
    try {
      final rows = await _db
          .from('doc_questions')
          .update({'helpful': helpful})
          .eq('document_id', documentId)
          .eq('question_key', _questionKey(question))
          .select('id')
          .timeout(const Duration(seconds: 12));
      return (rows as List).isNotEmpty;
    } catch (e) {
      debugPrint('DocQaService: rating failed -> ${_describe(e)}');
      return false;
    }
  }

  /// Documents available to the current user, newest first.
  static Future<List<DocLibraryItem>> listDocuments({
    String? createdBy,
    String? plant,
    int limit = 50,
  }) async {
    if (!_ready) return const [];
    try {
      var query = _db
          .from('doc_library')
          .select(
              'id, client_id, title, file_name, file_kind, page_count, '
              'chunk_count, char_count, ocr_derived, mean_confidence, '
              'status, error_message, created_at')
          .eq('status', 'ready');

      if (createdBy != null && createdBy.isNotEmpty) {
        query = query.eq('created_by', createdBy);
      }
      if (plant != null && plant.isNotEmpty) {
        query = query.eq('plant', plant);
      }

      final rows = await query
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 20));

      return ((rows as List?) ?? const [])
          .map((r) => DocLibraryItem.fromRow((r as Map).cast<String, dynamic>()))
          .toList();
    } catch (e) {
      lastError = _describe(e);
      debugPrint('DocQaService.listDocuments failed -> $lastError');
      return const [];
    }
  }

  /// Delete a document. Chunks and questions cascade in the database.
  static Future<bool> deleteDocument(DocLibraryItem doc) async {
    if (!_ready || doc.id == null) return false;
    try {
      await _db.from('doc_library').delete().eq('id', doc.id!);
      return true;
    } catch (e) {
      lastError = _describe(e);
      debugPrint('DocQaService.deleteDocument failed -> $lastError');
      return false;
    }
  }

  /// Previously asked questions, for a "recent questions" list.
  static Future<List<String>> recentQuestions(int documentId,
      {int limit = 8}) async {
    if (!_ready) return const [];
    try {
      final rows = await _db
          .from('doc_questions')
          .select('question')
          .eq('document_id', documentId)
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 12));
      final seen = <String>{};
      final out = <String>[];
      for (final r in ((rows as List?) ?? const [])) {
        final q = ((r as Map)['question'] ?? '').toString().trim();
        if (q.isNotEmpty && seen.add(q.toLowerCase())) out.add(q);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ══════════════════════════════════════════════════════════════════════

  /// Same shape as the ids used elsewhere in this project: '<millis>-<n>'.
  /// Used for doc_questions rows, where every ask genuinely is a new record.
  static int _seq = 0;
  static String _newClientId() {
    _seq = (_seq + 1) % 100000;
    return '${DateTime.now().millisecondsSinceEpoch}-$_seq';
  }

  /// Stable id for a document, derived from its name and byte length.
  ///
  /// It MUST be deterministic. `upsert(row, onConflict: 'client_id')` can only
  /// do its job if re-ingesting the same file produces the same client_id; with
  /// a timestamp-based id the conflict target could never match, so a user who
  /// retried a slow upload got a second copy of the document and every question
  /// afterwards searched only one of the two.
  ///
  /// Name + length rather than a content hash: hashing 25 MB on the web UI
  /// thread would visibly freeze the app, and this is precise enough — an edited
  /// document almost always changes length, and a same-name same-length file is
  /// for practical purposes the same upload. Dart's String.hashCode is NOT used
  /// because it is not stable across runs or platforms, which would silently
  /// reintroduce the duplicate.
  static String _docClientId(String fileName, int byteLength) {
    final safe = fileName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-');
    final trimmed = safe.length > 80 ? safe.substring(safe.length - 80) : safe;
    return 'doc-$trimmed-$byteLength';
  }

  /// Cache key: lowercased, punctuation-stripped, whitespace-collapsed, so
  /// "What PPE?" and "what  ppe" hit the same cached answer.
  static String _questionKey(String q) {
    return q
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _mimeFor(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (ext == 'pdf') return 'application/pdf';
    if (ext == 'docx') {
      return 'application/vnd.openxmlformats-officedocument'
          '.wordprocessingml.document';
    }
    if (ext == 'png') return 'image/png';
    if (ext == 'webp') return 'image/webp';
    if (ext == 'tif' || ext == 'tiff') return 'image/tiff';
    if (ext == 'txt') return 'text/plain';
    return 'image/jpeg';
  }

  /// Turn a PostgREST/Storage exception into something worth logging.
  static String _describe(Object e) {
    if (e is PostgrestException) {
      final code = e.code ?? '';
      // 42703 = undefined column, 42P01 = undefined table, 42883 = no such
      // function. All three mean migration_doc_qa.sql has not been run.
      //
      // PGRST202/PGRST205 are the codes the user will ACTUALLY see: PostgREST
      // resolves names against its own cached schema and reports "function not
      // found in schema cache" / "table not found" rather than passing the
      // query to Postgres, so the raw SQLSTATEs above never surface for a
      // missing RPC or table. Omitting these two hid the single most likely
      // failure — the migration not having been run.
      if (code == '42703' ||
          code == '42P01' ||
          code == '42883' ||
          code == 'PGRST202' ||
          code == 'PGRST205') {
        return '${e.message} (code $code — run migration_doc_qa.sql in the '
            'Supabase SQL editor)';
      }
      return '${e.message}${code.isEmpty ? '' : ' (code $code)'}';
    }
    if (e is StorageException) return e.message;
    if (e is TimeoutException) return 'timed out';
    return e.toString();
  }
}
