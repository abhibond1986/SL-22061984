import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'local_db.dart';
import 'auth_token_service.dart';
import 'app_logger.dart';
import 'admin_alerts.dart';
import 'supabase_service.dart';
import 'supabase_config.dart';
import 'image_storage.dart';
// For RealtimeSync.incidentsRevision — a completed fullSync bumps it so open
// screens repaint from the refreshed LocalDB. This DOES close an import cycle
// (realtime_sync.dart → admin_master_data.dart → this file), the same one the
// admin_master_data import below already documents. Harmless: both notifiers are
// `static final`, so they initialise lazily on first touch, and no top-level in
// either file reads state from the other at load time.
import 'realtime_sync.dart';
// Cyclic with admin_master_data (which calls pushMasterData/pullMasterData).
// Dart permits import cycles; there are no cross-file const/static
// initialisers between the two, so load order can't bite us here.
import 'admin_master_data.dart';

/// SAIL Safety Lens — Google Sheets Sync Service
///
/// Periodic push/pull to Google Sheet via Google Apps Script Web App.
/// Pros: completely free, admin can open sheet in browser.
/// Cons: ~60 req/min rate limit, eventual consistency.
class SyncService {
  static const String _defaultBackendUrl =
      'https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec';
  static const String _kBackendUrl   = 'sync_backend_url';
  static const String _kPendingQueue = 'sync_pending_queue';
  static const String _kLastSyncTime = 'sync_last_time';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static Future<String> getBackendUrl() async {
    _prefs ??= await SharedPreferences.getInstance();
    final saved = _prefs!.getString(_kBackendUrl);
    if (saved != null && saved.isNotEmpty) return saved;
    return _defaultBackendUrl;
  }

  static Future<void> setBackendUrl(String url) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kBackendUrl, url.trim());
  }

  static Future<bool> get isConfigured async {
    // Supabase counts as "configured" so fullSync and other guarded flows run.
    if (SupabaseConfig.enabled) return true;
    final url = await getBackendUrl();
    return url.isNotEmpty && url.startsWith('https://');
  }

  /// Helper: POST to Apps Script, then follow 302 redirect with GET.
  /// Apps Script processes the POST and redirects to a result URL that
  /// must be fetched with GET to receive the JSON response.
  ///
  /// ★ On Flutter Web: the browser automatically follows redirects, so
  ///   we get the final response directly. No manual redirect needed.
  /// ★ On mobile/desktop: http.Client does NOT follow redirects by default,
  ///   so we manually follow the 302 with a GET.
  /// ★ Includes auth token in body for server-side validation.
  static Future<http.Response?> _postWithRedirect(
      String url, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      // Attach auth token to request body for server-side validation
      final authHeaders = await AuthTokenService.getAuthHeaders();
      if (authHeaders.isNotEmpty) {
        body['_authToken'] = authHeaders['X-Auth-Token'] ?? '';
        body['_authUser'] = authHeaders['X-User-Id'] ?? '';
      }

      // ✅ FIX: Always ensure _authUser is present — fall back to current
      // logged-in user's identity if auth token is missing/expired.
      // The deployed Apps Script requires at least a username to identify requests.
      if ((body['_authUser'] == null || body['_authUser'].toString().isEmpty)) {
        try {
          final currentUser = await LocalDB.getCurrentUser();
          if (currentUser != null) {
            body['_authUser'] = currentUser['pno']?.toString()
                ?? currentUser['username']?.toString()
                ?? '';
          }
        } catch (_) {}
      }

      final encodedBody = jsonEncode(body);

      if (kIsWeb) {
        // ═══ WEB PATH ═══
        // On web, the browser's fetch API follows redirects automatically.
        // Apps Script processes the POST, redirects to googleusercontent.com
        // with the JSON result. The browser follows this and we get the
        // final response (status 200 + JSON body) directly.
        //
        // Using 'text/plain' content-type avoids CORS preflight (simple request).
        final resp = await http
            .post(
              Uri.parse(url),
              body: encodedBody,
              headers: {'Content-Type': 'text/plain;charset=utf-8'},
            )
            .timeout(timeout);

        // Debug: log what we got
        print('SyncService[web]: POST ${body['action']} → status=${resp.statusCode}, '
            'bodyLen=${resp.body.length}, '
            'isHtml=${resp.body.trimLeft().startsWith('<')}');

        return resp;
      } else {
        // ═══ MOBILE/DESKTOP PATH ═══
        // http.Client does not auto-follow redirects, so we must manually
        // follow the 302 → GET to get the JSON response.
        final client = http.Client();
        try {
          var resp = await client
              .post(
                Uri.parse(url),
                body: encodedBody,
                headers: {'Content-Type': 'text/plain;charset=utf-8'},
              )
              .timeout(timeout);

          // Apps Script always redirects POST → GET result URL
          if (resp.statusCode == 302 || resp.statusCode == 301) {
            final loc = resp.headers['location'] ?? '';
            if (loc.isNotEmpty) {
              resp = await client.get(Uri.parse(loc)).timeout(timeout);
            }
          }
          return resp;
        } finally {
          client.close();
        }
      }
    } catch (e, stack) {
      AppLogger.error('SyncService', 'POST request failed',
          error: e, stack: stack, action: body['action']?.toString());
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  HEALTH CHECK
  // ═══════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> ping() async {
    if (!await isConfigured) {
      return {'ok': false, 'error': 'Backend URL not configured'};
    }
    try {
      final url = await getBackendUrl();
      final response = await http
          .get(Uri.parse('$url?action=health'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'ok': false, 'error': 'HTTP ${response.statusCode}'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  USERS
  // ═══════════════════════════════════════════════════════════════

  /// Fetch all registered users from Apps Script backend.
  /// Used by the dashboard user-switcher dropdown.
  /// Results are automatically cached in LocalDB for offline use.
  static Future<List<Map<String, dynamic>>> fetchUsers() async {
    // ★ Supabase path.
    if (SupabaseConfig.enabled) {
      final users = await SupabaseService.fetchUsers();
      if (users.isNotEmpty) await LocalDB.cacheUsers(users);
      return users;
    }
    if (!await isConfigured) return [];
    try {
      final url = await getBackendUrl();
      final response = await http
          .get(Uri.parse('$url?action=listUsers'))
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        List<Map<String, dynamic>> users = [];

        // New backend format: { success: true, users: [...] }
        if (data['success'] == true && data['users'] is List) {
          users = (data['users'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        // Old backend format: { ok: true, items: [...] }
        else if (data['ok'] == true && data['items'] is List) {
          users = (data['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }

        // Cache for offline use
        if (users.isNotEmpty) {
          await LocalDB.cacheUsers(users);
        }

        return users;
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v24: AI TEXT CALL (for refinement / validation)
  // ═══════════════════════════════════════════════════════════════

  /// Send a text prompt to the backend AI (Gemini) and return the response body.
  /// Used for near-miss description refinement, not image analysis.
  static Future<Map<String, dynamic>?> callAiText(String prompt) async {
    if (!await isConfigured) return null;
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {
        'action': 'gemini',
        'prompt': prompt,
      }, timeout: const Duration(seconds: 30));
      if (resp != null && resp.statusCode == 200) {
        // ★ v29 FIX: Force UTF-8 decode for Hindi text
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v25: KNOWLEDGE BASE SYNC
  //  Push KB docs from admin → backend, pull on all devices
  // ═══════════════════════════════════════════════════════════════

  /// Push all KB documents to backend (called after admin uploads).
  /// Uses existing 'addKnowledge' action — sends each doc individually.
  /// For bulk: clears server KB sheet first, then re-adds all.
  static Future<bool> pushKbDocs(List<Map<String, dynamic>> docs) async {
    if (SupabaseConfig.enabled) {
      int ok = 0;
      for (final doc in docs) {
        if (await SupabaseService.addKnowledgeDoc(doc)) ok++;
      }
      return ok > 0;
    }
    if (!await isConfigured) return false;
    try {
      final url = await getBackendUrl();
      // Push each doc using existing addKnowledge endpoint
      int success = 0;
      for (final doc in docs) {
        final resp = await _postWithRedirect(url, {
          'action': 'addKnowledge',
          'id': doc['id']?.toString() ?? '',
          'title': doc['title']?.toString() ?? '',
          'content': doc['content']?.toString() ?? '',
          'source': doc['source']?.toString() ?? 'uploaded',
          'uploadedAt': doc['uploadedAt']?.toString() ?? DateTime.now().toIso8601String(),
          'uploadedBy': doc['uploadedBy']?.toString() ?? 'admin',
        }, timeout: const Duration(seconds: 15));
        if (resp != null && resp.statusCode == 200) success++;
      }
      return success > 0;
    } catch (_) {
      return false;
    }
  }

  /// Pull KB documents from backend using existing 'listKnowledge' action.
  /// All devices call this on startup/sync to get admin-uploaded knowledge.
  static Future<List<Map<String, dynamic>>?> pullKbDocs() async {
    if (SupabaseConfig.enabled) {
      final docs = await SupabaseService.fetchKnowledgeDocs();
      return docs.isEmpty ? null : docs;
    }
    if (!await isConfigured) return null;
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {'action': 'listKnowledge'},
          timeout: const Duration(seconds: 30));
      if (resp != null && resp.statusCode == 200) {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map && parsed['rows'] != null) {
          return (parsed['rows'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        // Alternate response format
        if (parsed is Map && parsed['data'] != null) {
          return (parsed['data'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Sync KB: pull from server and merge into local (server wins).
  /// Called on app startup and after admin uploads.
  static Future<bool> syncKnowledgeBase() async {
    try {
      final serverDocs = await pullKbDocs();
      if (serverDocs == null || serverDocs.isEmpty) return false;
      // Server is source of truth — replace local KB with server version
      await LocalDB.replaceAllKnowledgeDocs(serverDocs);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v24: MASTER DATA SYNC (plants, departments, WSA, etc.)
  // ═══════════════════════════════════════════════════════════════

  /// Push master data (plants, depts, WSA causes etc.) to backend.
  /// Called whenever admin edits these lists.
  static Future<bool> pushMasterData({
    List<Map<String, String>>? plants,
    List<String>? departments,
    List<String>? wsaCauses,
    List<String>? severities,
    List<String>? statuses,
    List<String>? obsTypes,
    String? updatedBy,
  }) async {
    if (SupabaseConfig.enabled) {
      bool any = false;
      if (plants != null)      any |= await SupabaseService.setMasterData('plants', plants);
      if (departments != null) any |= await SupabaseService.setMasterData('departments', departments);
      if (wsaCauses != null)   any |= await SupabaseService.setMasterData('wsa_causes', wsaCauses);
      if (severities != null)  any |= await SupabaseService.setMasterData('severities', severities);
      if (statuses != null)    any |= await SupabaseService.setMasterData('statuses', statuses);
      if (obsTypes != null)    any |= await SupabaseService.setMasterData('obs_types', obsTypes);
      return any;
    }
    if (!await isConfigured) return false;
    try {
      final url = await getBackendUrl();
      final body = <String, dynamic>{'action': 'saveMasterData'};
      if (plants != null)      body['plants'] = plants;
      if (departments != null) body['departments'] = departments;
      if (wsaCauses != null)   body['wsaCauses'] = wsaCauses;
      if (severities != null)  body['severities'] = severities;
      if (statuses != null)    body['statuses'] = statuses;
      if (obsTypes != null)    body['obsTypes'] = obsTypes;
      if (updatedBy != null)   body['updatedBy'] = updatedBy;

      final resp = await _postWithRedirect(url, body);
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['ok'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Pull latest master data from backend. Returns the data map or null.
  static Future<Map<String, dynamic>?> pullMasterData() async {
    if (SupabaseConfig.enabled) {
      final raw = await SupabaseService.fetchMasterData();
      // Map DB keys → the camelCase keys AdminMasterData.syncFromBackend expects.
      final out = <String, dynamic>{
        if (raw['plants'] != null)      'plants':      raw['plants'],
        if (raw['departments'] != null) 'departments': raw['departments'],
        if (raw['wsa_causes'] != null)  'wsaCauses':   raw['wsa_causes'],
        if (raw['severities'] != null)  'severities':  raw['severities'],
        if (raw['statuses'] != null)    'statuses':    raw['statuses'],
        if (raw['obs_types'] != null)   'obsTypes':    raw['obs_types'],
      };

      // ★ CRITICAL: AI API keys (OpenRouter/Gemini/Groq) do NOT live in the
      // Supabase master_data table — they live server-side in the Apps Script
      // Script Properties. Without them the device can't reach OpenRouter and
      // every image scan silently falls back to OFFLINE analysis.
      // So always pull the keys from Apps Script, even under Supabase.
      try {
        final keys = await _fetchApiKeysFromAppsScript();
        if (keys != null) {
          // This is a WHITELIST: anything absent here is silently dropped
          // before AdminMasterData.syncFromBackend() ever sees it, and Supabase
          // is enabled by default, so this is the live path. A new key added to
          // the Apps Script payload MUST be added here too or it will never
          // reach the device — 'openRouterApiKey2' was exactly that bug.
          for (final k in const [
            'openRouterApiKey',
            'openRouterApiKey2',
            'geminiApiKey',
            'groqApiKey',
            'geminiModel',
            // Tier 1b (NaraRouter). Added 2026-08-17 — and added HERE at the
            // same time as everywhere else precisely because omitting this line
            // is the bug that stopped 'openRouterApiKey2' from ever reaching a
            // device: the key existed on the backend, the handler existed on the
            // device, and this whitelist silently dropped it in between.
            'naraApiKey',
            // The model too, not just the key. Syncing the key alone would let
            // every OTHER device fall back to NaraVision.defaultModel — the
            // costliest option on the list — however carefully the admin picked
            // a cheap one. 'geminiModel' already syncs; this keeps the pair
            // symmetrical.
            'naraModel',
          ]) {
            if (keys[k] != null && keys[k].toString().isNotEmpty) {
              out[k] = keys[k];
            }
          }
        }
      } catch (_) {}

      return out.isEmpty ? null : out;
    }
    if (!await isConfigured) return null;
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {'action': 'getMasterData'});
      if (resp != null && resp.statusCode == 200) {
        final parsed = jsonDecode(resp.body);
        if (parsed['ok'] == true && parsed['data'] != null) {
          return Map<String, dynamic>.from(parsed['data'] as Map);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetch ONLY the AI API keys from Apps Script (getMasterData injects them
  /// from Script Properties). Used when Supabase is the primary backend but the
  /// keys still need to come from the Apps Script AI proxy. Returns the raw
  /// `data` map (with openRouterApiKey, openRouterApiKey2, geminiApiKey,
  /// groqApiKey, geminiModel) or null on any failure.
  static Future<Map<String, dynamic>?> _fetchApiKeysFromAppsScript() async {
    try {
      final url = await getBackendUrl();
      if (url.isEmpty || !url.startsWith('https://')) return null;
      final resp = await _postWithRedirect(url, {'action': 'getMasterData'});
      if (resp != null && resp.statusCode == 200) {
        final bodyText = resp.body.trim();
        if (bodyText.startsWith('<') || bodyText.startsWith('<!')) return null;
        final parsed = jsonDecode(bodyText);
        if (parsed['ok'] == true && parsed['data'] != null) {
          return Map<String, dynamic>.from(parsed['data'] as Map);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  INCIDENTS
  // ═══════════════════════════════════════════════════════════════

  /// Push a single incident to the backend.
  /// If offline/failed, adds to pending queue for later retry.
  /// Set [fromQueue] = true when called from drainPendingQueue to avoid
  /// re-adding to the queue (the caller handles retry tracking).
  static Future<bool> pushIncident(
      Map<String, dynamic> incident, {bool fromQueue = false}) async {
    // ★ Supabase path: upload image to Storage (once), then upsert the row.
    if (SupabaseConfig.enabled) {
      try {
        final row = Map<String, dynamic>.from(incident);
        final id = row['id']?.toString() ?? '';
        // Upload the evidence image if we don't already have a Storage URL.
        if ((row['imageUrl']?.toString() ?? '').isEmpty && id.isNotEmpty) {
          Uint8List? bytes;
          try { bytes = await ImageStorage.getImageForIncident(row); } catch (_) {}
          if (bytes == null) {
            final b64 = row['imageBase64']?.toString() ?? '';
            if (b64.isNotEmpty && b64 != '[image]') {
              try { bytes = base64Decode(b64); } catch (_) {}
            }
          }
          if (bytes != null && bytes.isNotEmpty) {
            final imgUrl = await SupabaseService.uploadIncidentImage(id, bytes);
            if (imgUrl != null) row['imageUrl'] = imgUrl;
          }
        }
        // Don't store bulky base64 in the DB row — the image lives in Storage.
        row.remove('imageBase64');
        row.remove('shareImageBase64');
        final ok = await SupabaseService.upsertIncident(row);
        if (!ok && !fromQueue) await _addToPendingQueue('addIncident', incident);
        return ok;
      } catch (e) {
        if (!fromQueue) await _addToPendingQueue('addIncident', incident);
        return false;
      }
    }
    if (!await isConfigured) {
      if (!fromQueue) await _addToPendingQueue('addIncident', incident);
      return false;
    }
    try {
      final url = await getBackendUrl();

      // Build body — strip large image data but KEEP thumbnails (they're only 2-4KB)
      final body = <String, dynamic>{'action': 'addIncident'};
      incident.forEach((k, v) {
        if (k == 'imageBase64') {
          body[k] = '[image]'; // never send raw base64 to Sheets (too large)
          return;
        }
        if (k == 'shareImageBase64') {
          body[k] = ''; // strip medium image too (50-80KB)
          return;
        }
        // Keep thumbnailBase64 — it's only 2-4KB and needed for log display
        if (v == null) { body[k] = ''; return; }
        if (v is List || v is Map) {
          body[k] = jsonEncode(v); // serialize nested objects
          return;
        }
        final str = v.toString();
        // Truncate any single field > 5000 chars (raised from 2000 to accommodate thumbnail base64)
        body[k] = str.length > 5000 ? str.substring(0, 5000) : str;
      });

      // Use the shared helper that handles redirects + logging
      final resp = await _postWithRedirect(url, body);

      if (resp == null) {
        AppLogger.error('SyncService', 'pushIncident: no response (network/timeout)',
            action: 'addIncident');
        if (!fromQueue) await _addToPendingQueue('addIncident', incident);
        return false;
      }

      if (resp.statusCode == 200) {
        final bodyText = resp.body.trim();
        // Guard against HTML error pages from Apps Script
        if (bodyText.startsWith('<') || bodyText.startsWith('<!')) {
          AppLogger.error('SyncService',
              'pushIncident: got HTML instead of JSON (check Apps Script deployment)',
              action: 'addIncident');
          if (!fromQueue) await _addToPendingQueue('addIncident', incident);
          return false;
        }
        try {
          final data = jsonDecode(bodyText);
          if (data['ok'] == true) {
            await _markSyncTime();
            print('SyncService: pushIncident SUCCESS — id=${incident['id']}, type=${incident['type']}');
            // ★ v25: Auto-fire alerts for CRITICAL incidents
            _checkAndFireAlerts(incident);
            return true;
          }
          // Apps Script returned a structured error
          final errMsg = data['error']?.toString() ?? 'Unknown error';
          AppLogger.error('SyncService',
              'pushIncident: server rejected — $errMsg',
              action: 'addIncident');
        } catch (e) {
          AppLogger.error('SyncService',
              'pushIncident: JSON parse failed — body=${bodyText.length > 200 ? bodyText.substring(0, 200) : bodyText}',
              error: e, action: 'addIncident');
        }
      } else {
        AppLogger.error('SyncService',
            'pushIncident: HTTP ${resp.statusCode}',
            action: 'addIncident');
      }

      if (!fromQueue) await _addToPendingQueue('addIncident', incident);
      return false;
    } catch (e, stack) {
      AppLogger.error('SyncService', 'pushIncident: exception',
          error: e, stack: stack, action: 'addIncident');
      if (!fromQueue) await _addToPendingQueue('addIncident', incident);
      return false;
    }
  }

  /// Fetch all incidents from backend.
  static Future<List<Map<String, dynamic>>> fetchIncidents() async {
    // ★ Supabase path (single source of truth) when enabled.
    if (SupabaseConfig.enabled) {
      return SupabaseService.fetchIncidents();
    }
    if (!await isConfigured) return [];
    try {
      final url = await getBackendUrl();
      final response = await http
          .get(Uri.parse('$url?action=listIncidents'))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['ok'] == true && data['items'] is List) {
          return (data['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  KNOWLEDGE BASE
  // ═══════════════════════════════════════════════════════════════

  static Future<bool> pushKnowledgeDoc(
      Map<String, dynamic> doc) async {
    if (SupabaseConfig.enabled) {
      return SupabaseService.addKnowledgeDoc(doc);
    }
    if (!await isConfigured) return false;
    try {
      final url  = await getBackendUrl();
      final body = <String, dynamic>{'action': 'addKnowledge'};
      doc.forEach((k, v) => body[k] = (v ?? '').toString());

      final resp = await _postWithRedirect(url, body);
      return resp != null && resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<void> syncKnowledgeFromCloud() async {
    final docs = await fetchKnowledgeDocs();
    if (docs.isEmpty) return;
    for (final doc in docs) {
      await LocalDB.addKnowledgeDoc(
        title:   doc['title']?.toString()   ?? 'Untitled',
        content: doc['content']?.toString() ?? '',
        source:  doc['source']?.toString()  ?? 'cloud',
      );
    }
  }

  static Future<List<Map<String, dynamic>>> fetchKnowledgeDocs() async {
    if (SupabaseConfig.enabled) {
      return SupabaseService.fetchKnowledgeDocs();
    }
    if (!await isConfigured) return [];
    try {
      final url = await getBackendUrl();
      final response = await http
          .get(Uri.parse('$url?action=listKnowledge'))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['ok'] == true && data['items'] is List) {
          return (data['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  PENDING QUEUE (offline writes)
  // ═══════════════════════════════════════════════════════════════

  static Future<void> _addToPendingQueue(
      String action, Map<String, dynamic> payload) async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw   = _prefs!.getString(_kPendingQueue);
    final queue = raw != null ? (jsonDecode(raw) as List) : [];
    queue.add({
      'action':    action,
      'payload':   payload,
      'queuedAt':  DateTime.now().toIso8601String(),
    });
    await _prefs!.setString(_kPendingQueue, jsonEncode(queue));
  }

  /// Push every queued offline item, serialised against any other drain or sync.
  ///
  /// THE LOCK IS THE POINT. [_drainPendingQueueUnguarded] is not re-entrant: two
  /// overlapping drains each read the same queue snapshot and push every item, so
  /// on the Apps Script path (which APPENDS rather than upserts) the sheet gets
  /// duplicate rows, and a concurrent fullSync can hold a server snapshot taken
  /// before the drain finished — its reconcile then deletes the just-pushed
  /// incident straight back out of LocalDB. Overlap was reachable from app
  /// startup alone: main.dart calls this and fullSync() within a few lines of
  /// each other.
  static Future<int> drainPendingQueue() =>
      _runExclusive(_drainPendingQueueUnguarded);

  /// The raw drain. Call [drainPendingQueue] instead — EXCEPT from code already
  /// running inside [_runExclusive], which must call this one: taking the lock
  /// again from inside the lock would wait on its own release and deadlock.
  static Future<int> _drainPendingQueueUnguarded() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kPendingQueue);
    if (raw == null) return 0;
    final queue =
        (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    if (queue.isEmpty) return 0;
    if (!await isConfigured) return 0;

    final remaining = <Map<String, dynamic>>[];
    int synced = 0;
    for (final item in queue) {
      final action  = item['action']?.toString();
      final payload = Map<String, dynamic>.from(item['payload'] ?? {});
      bool ok = false;
      if (action == 'addIncident') {
        // ✅ FIX: Pass fromQueue=true to prevent pushIncident from
        // re-adding to the queue (which caused duplicate entries)
        ok = await pushIncident(payload, fromQueue: true);
      } else if (action == 'upsertUser') {
        // Retry a user registration/update that couldn't reach the backend.
        ok = await pushUser(payload);
      } else if (action == 'deleteIncident') {
        ok = await deleteIncident(payload['id']?.toString() ?? '');
      } else if (action == 'deleteUser') {
        ok = await deleteUser(payload['username']?.toString() ?? '');
      } else {
        // Unknown/legacy action — drop it so the queue can't wedge forever.
        ok = true;
      }
      if (ok) {
        synced++;
      } else {
        remaining.add(item);
      }
    }
    // MERGE, don't overwrite. The loop above spans many network awaits, and
    // [_addToPendingQueue] is NOT under the sync lock — a write the user makes
    // while offline mid-drain lands in the queue after our snapshot was taken.
    // Blindly writing `remaining` would erase it and that incident would be
    // lost for good. Since enqueue only ever appends, drains are serialised
    // against each other, and nothing else rewrites the queue, anything past
    // the snapshot length is a genuine newcomer and must survive.
    final latestRaw = _prefs!.getString(_kPendingQueue);
    if (latestRaw != null) {
      final latest = (jsonDecode(latestRaw) as List).cast<Map<String, dynamic>>();
      if (latest.length > queue.length) {
        remaining.addAll(latest.sublist(queue.length));
      }
    }
    await _prefs!.setString(_kPendingQueue, jsonEncode(remaining));
    return synced;
  }

  static Future<int> pendingQueueSize() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kPendingQueue);
    if (raw == null) return 0;
    return (jsonDecode(raw) as List).length;
  }

  /// Alias for widget use
  static Future<int> getPendingCount() => pendingQueueSize();

  // ═══════════════════════════════════════════════════════════════
  //  STATUS
  // ═══════════════════════════════════════════════════════════════

  static Future<DateTime?> getLastSyncTime() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kLastSyncTime);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> _markSyncTime() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!
        .setString(_kLastSyncTime, DateTime.now().toIso8601String());
  }

  // ═══════════════════════════════════════════════════════════════
  //  FULL SYNC
  // ═══════════════════════════════════════════════════════════════

  // ── FULL SYNC COALESCING ───────────────────────────────────────────────────
  //
  // WHY THIS EXISTS. fullSync() is called from six places: app startup
  // (main.dart), both home shells' _loadUser, HomeTab.initState and its
  // pull-to-refresh, and Settings → Sync Now — the last two forced. On the
  // Supabase path one call means a queue drain, a full incident fetch, a user
  // fetch and an Apps Script getMasterData round-trip. HomeTab is rebuilt from
  // scratch every time the user returns to the Home tab (the bottom nav swaps
  // widgets through an AnimatedSwitcher rather than keeping them alive), so
  // every navigation fired the whole sequence again — visible in the web console
  // as getMasterData POSTs and "key synced" lines repeating without end.
  //
  // Three guards, deliberately different:
  //   • _inFlightFullSync coalesces CONCURRENT unforced callers onto one network
  //     round — startup fires three of these within milliseconds of each other.
  //   • _lastFullSyncOk suppresses REPEAT syncs for a short window, which is
  //     what makes tab navigation free. Does not apply to a forced sync.
  //   • _syncLock serialises EVERY run, forced or not. This one is not an
  //     optimisation but a correctness requirement: the queue drain is not
  //     re-entrant, so two overlapping runs each push every queued item
  //     (duplicate rows on the Apps Script path, which appends rather than
  //     upserts), and the run that started earlier holds a server snapshot taken
  //     before the other drained the queue — so its reconcile deletes the
  //     just-pushed incident back out of LocalDB. Overlap was reachable three
  //     ways: two forced calls, an unforced call arriving during a forced one,
  //     and two unforced calls that both suspended on the same await inside the
  //     freshness check. A lock closes all three at once.
  static Future<Map<String, dynamic>>? _inFlightFullSync;
  static DateTime? _lastFullSyncOk;

  /// Tail of the chain of sync runs. Each run waits on the previous one's
  /// completion before starting, so runs queue instead of racing.
  static Future<void> _syncLock = Future<void>.value();

  /// Run [body] with no other sync in progress.
  ///
  /// Deliberately NOT `async`: the swap of [_syncLock] must happen in the same
  /// synchronous turn as reading it, or two callers could read the same
  /// predecessor and both queue behind it — which is the race this is here to
  /// prevent. `whenComplete` releases the lock even if [body] throws.
  static Future<T> _runExclusive<T>(Future<T> Function() body) {
    final predecessor = _syncLock;
    final release = Completer<void>();
    _syncLock = release.future;
    return predecessor
        .then((_) => body())
        .whenComplete(release.complete);
  }

  /// True when a recent successful sync can stand in for a new one.
  ///
  /// SYNCHRONOUS ON PURPOSE. It takes [userKey] as a parameter rather than
  /// reading the current user itself, because an await between this check and
  /// the assignment of [_inFlightFullSync] lets two callers both decide to sync.
  static bool _syncIsFresh(String userKey) {
    final last = _lastFullSyncOk;
    return last != null &&
        DateTime.now().difference(last) < _kFullSyncMinInterval &&
        userKey == _lastFullSyncUser;
  }

  static Map<String, dynamic> _throttledResult() => {
        'ok': true,
        'skipped': 'throttled',
        'syncTime': _lastFullSyncOk?.toIso8601String(),
      };

  /// Who [_lastFullSyncOk] belongs to.
  ///
  /// The throttle is static and survives a sign-out, so without this a second
  /// user logging in on the same device within the window would be served the
  /// previous session's cached incidents, users and master data — LocalDB's
  /// sign-out only clears the current-user key, not the cached data. Comparing
  /// identity rather than hooking the sign-out paths means this holds however the
  /// session changes, including a switch the sign-out UI does not go through.
  static String? _lastFullSyncUser;

  /// Identity of the signed-in user, for [_lastFullSyncUser].
  ///
  /// USERNAME FIRST, and each candidate must be non-empty. Order matters: no user
  /// map in this app carries an `id` (see SupabaseService._userAppToDb and the
  /// registration path in login_screen.dart), and `email` is absent from
  /// registration entirely — so an email-first check would resolve to '' for a
  /// whole class of users, they would all compare equal, and the throttle would
  /// survive a switch between them, which is the exact bug this guards. Username
  /// is set on every login path, so it is the reliable one.
  static Future<String> _currentUserKey() async {
    try {
      final u = await LocalDB.getCurrentUser();
      if (u == null) return '';
      for (final field in const ['username', 'pno', 'email']) {
        final v = (u[field] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  /// How long a successful sync is considered fresh enough to reuse.
  ///
  /// Sized against how the data actually changes: incidents arrive over
  /// RealtimeSync (a Supabase subscription that updates LocalDB and bumps
  /// `incidentsRevision` within a second), and master-data edits arrive the same
  /// way. So this window is NOT the staleness bound the user experiences — it
  /// only bounds how often the belt-and-braces full reconcile runs. 90s is long
  /// enough to make navigation free and short enough that a device whose
  /// realtime socket dropped still self-heals quickly.
  ///
  /// TWO LIMITS ON THAT ARGUMENT, worth knowing before shortening this window in
  /// the hope of fresher data — it would not help:
  ///  • On the Apps Script backend RealtimeSync never starts (it requires
  ///    Supabase), so this throttle is the ONLY freshness bound there, not a
  ///    second line of defence.
  ///  • Nothing polls fullSync. Its unforced callers are app startup, each home
  ///    shell's _loadUser and HomeTab.initState — so the real bound is "90s AND a
  ///    visit to the Home tab", and a user parked on Home gets no further full
  ///    sync at all. That was equally true before this throttle existed; realtime, or a
  ///    pull-to-refresh, is what actually keeps a parked screen current.
  static const Duration _kFullSyncMinInterval = Duration(seconds: 90);

  /// Reconcile local data with the backend.
  ///
  /// Repeat calls within [_kFullSyncMinInterval] of a success return
  /// `{'ok': true, 'skipped': 'throttled'}` WITHOUT touching the network, and
  /// concurrent unforced calls share one round-trip. Runs never overlap — see
  /// [_runExclusive] and the block comment above [_inFlightFullSync].
  ///
  /// Pass `force: true` for anything the user explicitly asked for —
  /// pull-to-refresh, Settings → Sync Now. A forced sync ignores the freshness
  /// window and does not JOIN an in-flight run: the queue drain happens at the
  /// START of a run, so joining one already in progress would report success
  /// without ever pushing the record the user just typed. It queues behind that
  /// run instead.
  static Future<Map<String, dynamic>> fullSync({bool force = false}) async {
    // Resolved BEFORE the checks below, because from the first check to the
    // assignment of _inFlightFullSync there must be no await — otherwise two
    // callers suspend at the same point, both resume to find no run in progress,
    // and both start one.
    final userKey = await _currentUserKey();

    if (!force) {
      final inFlight = _inFlightFullSync;
      if (inFlight != null) return inFlight;
      if (_syncIsFresh(userKey)) return _throttledResult();
    }

    final run = _runExclusive(() async {
      // Re-checked INSIDE the lock. While this run sat in the queue the run
      // ahead of it may have refreshed everything, in which case there is
      // nothing left to do — this is what stops a tab switch during startup from
      // costing a second full round-trip.
      if (!force && _syncIsFresh(userKey)) return _throttledResult();

      final result = await _fullSyncUnguarded();
      // Only a genuine success refreshes the window. A failed sync that set it
      // would lock the app out of retrying for 90s — exactly when it most needs
      // to retry.
      if (result['ok'] == true) {
        _lastFullSyncOk = DateTime.now();
        _lastFullSyncUser = userKey;
        // TELL THE SCREENS. A sync rewrites LocalDB's incident set via
        // LocalDB.replaceAllIncidents, which notifies nobody — so a completed
        // sync left every open screen showing pre-sync numbers. Both home shells
        // worked around that by changing HomeTab's ValueKey to force a full
        // remount, which threw away its state and re-ran its initState sync.
        // Bumping the notifier every screen already listens to does the same job
        // without the remount. Safe against loops: listeners re-read LocalDB and
        // none of them write to it.
        RealtimeSync.incidentsRevision.value++;
      }
      return result;
    });

    // Only an unforced run is publishable as the shared in-flight future; a
    // forced one must not absorb later callers into a round that may predate
    // their data. No await between the checks above and this line.
    if (!force) _inFlightFullSync = run;
    try {
      return await run;
    } finally {
      // identical() so a forced run finishing later cannot clear an unforced
      // run's future out from under callers still awaiting it.
      if (identical(_inFlightFullSync, run)) _inFlightFullSync = null;
    }
  }

  /// The actual sync. Call [fullSync] instead — this one has no coalescing, no
  /// freshness check and no mutual exclusion, and will happily run concurrently
  /// with itself.
  static Future<Map<String, dynamic>> _fullSyncUnguarded() async {
    if (!await isConfigured) {
      return {
        'ok': false,
        'error':
            'Backend URL not configured. Open Settings to add Apps Script URL.',
      };
    }

    // ★ Supabase path: server-authoritative reconcile.
    // The server is the single source of truth for the shared incident set.
    // Order matters: (1) drain the queue so genuinely-new offline incidents
    // reach the server FIRST (they'll then survive the reconcile); (2) pull the
    // full server set; (3) delete any local incident the server no longer has
    // (covers admin wipes / deletes made on other devices); (4) merge server
    // rows over local. We use fetchIncidentsOrNull so a network failure (null)
    // never triggers a destructive reconcile.
    if (SupabaseConfig.enabled) {
      // Already inside the sync lock — must use the unguarded drain.
      final pushed = await _drainPendingQueueUnguarded();

      final serverRows = await SupabaseService.fetchIncidentsOrNull();
      if (serverRows == null) {
        // Couldn't reach the server — do NOT touch local data.
        return {
          'ok': false,
          'error': 'Could not reach Supabase — local data left unchanged.',
          'pushed': pushed,
        };
      }

      final serverIds = <String>{};
      for (final r in serverRows) {
        final id = r['id']?.toString() ?? '';
        if (id.isNotEmpty) serverIds.add(id);
      }

      // (3) Drop local incidents that no longer exist on the server.
      final removed = await LocalDB.reconcileWithServer(serverIds);
      // Server confirmed its full set → prune tombstones it no longer knows
      // about (they're now truly gone) so they can't linger forever.
      await LocalDB.pruneIncidentTombstones(serverIds);

      // (4) Merge server rows over local (server wins on conflicts).
      final activeTombstones = LocalDB.deletedIncidentIds();
      final localMap = <String, Map<String, dynamic>>{};
      for (final l in await LocalDB.getIncidents()) {
        final id = l['id']?.toString() ?? '';
        if (id.isNotEmpty) localMap[id] = l;
      }
      for (final remote in serverRows) {
        final id = remote['id']?.toString() ?? '';
        if (id.isEmpty || activeTombstones.contains(id)) continue;
        if (!localMap.containsKey(id)) {
          localMap[id] = remote;
        } else {
          // Use LocalDB's single merge rule rather than a local variant. The
          // old inline merge let ANY non-empty server value overwrite local,
          // so a Sync Now discarded a corrective action typed while offline
          // (and the realtime path had different behaviour again).
          localMap[id] = LocalDB.mergeServerIncident(
              local: localMap[id]!, server: remote);
        }
      }
      await LocalDB.replaceAllIncidents(localMap.values.toList());

      // Refresh cached users too.
      final users = await fetchUsers();
      if (users.isNotEmpty) await LocalDB.cacheUsers(users);

      // Refresh master data (plants, departments, severities, statuses, WSA
      // causes, observation types, AI keys). Without this, "Sync Now" left the
      // device on stale lists and the frontend deviated from the admin panel
      // until the next cold start.
      final masterUpdated = await AdminMasterData.syncFromBackend();

      await _markSyncTime();
      return {
        'ok': true,
        'pushed': pushed,
        'pulled': serverRows.length,
        'removed': removed,
        'users': users.length,
        'masterData': masterUpdated,
        'syncTime': DateTime.now().toIso8601String(),
      };
    }

    // Push any queued offline writes
    // Already inside the sync lock — must use the unguarded drain.
    final pushed = await _drainPendingQueueUnguarded();

    // Pull latest incidents from Sheets
    final pulled = await fetchIncidents();
    final serverIds = <String>{};
    for (final r in pulled) {
      final id = r['id']?.toString() ?? '';
      if (id.isNotEmpty) serverIds.add(id);
    }

    // Push local-only incidents to server (ones that never made it).
    // IMPORTANT: never re-push a tombstoned (locally-deleted) incident — doing
    // so resurrects rows the user deleted, refilling a cleared sheet.
    final tombstoned = LocalDB.deletedIncidentIds();
    final localIncidents = await LocalDB.getIncidents(); // already excludes tombstoned
    int extraPushed = 0;
    for (final local in localIncidents) {
      final id = local['id']?.toString() ?? '';
      if (id.isEmpty || tombstoned.contains(id)) continue;
      // Only push a genuinely NEW local incident (has a pending-queue marker or
      // a fresh flag). A row that's simply "not on the server" may have been
      // deleted server-side — re-pushing it would resurrect it.
      final isUnsynced = local['_synced'] != true && local['_pushedOnce'] != true;
      if (!serverIds.contains(id) && isUnsynced) {
        final ok = await pushIncident(local, fromQueue: true);
        if (ok) {
          extraPushed++;
          local['_pushedOnce'] = true; // don't auto-push again next cycle
        }
      }
    }
    if (extraPushed > 0) {
      print('SyncService.fullSync: pushed $extraPushed local-only incidents to server');
      // Re-fetch to get complete server data after our pushes
      pulled.clear();
      pulled.addAll(await fetchIncidents());
    }

    // Merge: server is source of truth for shared data.
    // Prune tombstones the server no longer knows about (confirmed deleted),
    // and never re-add a still-tombstoned id from the server.
    await LocalDB.pruneIncidentTombstones(serverIds);
    final activeTombstones = LocalDB.deletedIncidentIds();
    if (pulled.isNotEmpty) {
      final localMap = <String, Map<String, dynamic>>{};
      for (final l in localIncidents) {
        final id = l['id']?.toString() ?? '';
        if (id.isNotEmpty) localMap[id] = l;
      }
      for (final remote in pulled) {
        final id = remote['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (activeTombstones.contains(id)) continue; // deleted locally — keep hidden
        if (!localMap.containsKey(id)) {
          localMap[id] = remote;
        } else {
          // Existing — merge via LocalDB's single shared rule, which protects
          // unsynced local workflow edits and device-only fields.
          localMap[id] = LocalDB.mergeServerIncident(
              local: localMap[id]!, server: remote);
        }
      }
      // Replace all local incidents with merged data
      await LocalDB.replaceAllIncidents(localMap.values.toList());
    }

    // Pull latest users from Sheets and cache them
    final users = await fetchUsers();
    if (users.isNotEmpty) {
      await LocalDB.cacheUsers(users);
    }

    // Refresh master data on the Apps Script path too, for the same reason.
    final masterUpdated = await AdminMasterData.syncFromBackend();

    await _markSyncTime();
    return {
      'ok':         true,
      'pushed':     pushed,
      'pulled':     pulled.length,
      'users':      users.length,
      'masterData': masterUpdated,
      'syncTime':   DateTime.now().toIso8601String(),
    };
  }
  // ═══════════════════════════════════════════════════════════════
  //  ADMIN — USER MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  static Future<bool> updateUserField(
      String username, String field, String value) async {
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {
        'action':   'updateRole',
        'username': username,
        field:      value,
      });
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['success'] == true;
      }
      return false;
    } catch (_) { return false; }
  }

  static Future<bool> deleteUser(String username) async {
    // ★ Supabase path.
    if (SupabaseConfig.enabled) {
      return SupabaseService.deleteUser(username);
    }
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {
        'action': 'deleteUser', 'username': username,
      });
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['success'] == true;
      }
      return false;
    } catch (_) { return false; }
  }

  static Future<bool> registerUser(Map<String, dynamic> params) async {
    try {
      final url = await getBackendUrl();
      final body = Map<String, dynamic>.from(params);
      body['action'] = 'register';
      final resp = await _postWithRedirect(url, body);
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['success'] == true;
      }
      return false;
    } catch (_) { return false; }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW (admin v5): PUSH USER
  //  Insert-or-update a user record on the Apps Script backend.
  //  Used by Admin Command Centre after upsertUser() local write.
  //
  //  Strategy: try `register` first (handles new + existing in v9+);
  //  if backend doesn't recognise it, fall back to upsertUser action.
  //  Returns true on backend success, false on any failure (caller
  //  wraps in try/catch and treats it as best-effort).
  // ═══════════════════════════════════════════════════════════════
  static Future<bool> pushUser(Map<String, dynamic> user) async {
    // ★ Supabase path.
    if (SupabaseConfig.enabled) {
      return SupabaseService.upsertUser(user);
    }
    if (!await isConfigured) return false;

    final uname = (user['username']?.toString() ?? '').trim();
    if (uname.isEmpty) return false;

    final url = await getBackendUrl();

    // Build clean body from user data
    final body = <String, dynamic>{};
    user.forEach((k, v) {
      if (v == null) { body[k] = ''; return; }
      if (v is List || v is Map) { body[k] = jsonEncode(v); return; }
      body[k] = v.toString();
    });

    // Attempt 1: action=upsertUser (creates or updates user on server)
    try {
      final b1 = Map<String, dynamic>.from(body)..['action'] = 'upsertUser';
      final resp = await _postWithRedirect(url, b1);
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && (data['success'] == true || data['ok'] == true)) {
          print('SyncService: pushUser SUCCESS via upsertUser for $uname');
          return true;
        }
        print('SyncService: pushUser upsertUser response: ${resp.body}');
      }
    } catch (e) {
      print('SyncService: pushUser upsertUser error: $e');
    }

    // Attempt 2: fall back to register (for older backend versions)
    try {
      final b2 = Map<String, dynamic>.from(body)..['action'] = 'register';
      final resp = await _postWithRedirect(url, b2);
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && (data['success'] == true || data['ok'] == true)) {
          print('SyncService: pushUser SUCCESS via register for $uname');
          return true;
        }
        print('SyncService: pushUser register response: ${resp.body}');
      }
    } catch (e) {
      print('SyncService: pushUser register error: $e');
    }

    return false;
  }

  /// Push a user to the backend; if it fails (offline / backend down),
  /// enqueue it so it retries later. Prevents "registered users never reach
  /// the admin panel on other devices" when the one-shot push is missed.
  static Future<bool> pushUserReliable(Map<String, dynamic> user) async {
    final ok = await pushUser(user).catchError((_) => false);
    if (!ok) {
      await _addToPendingQueue('upsertUser', user);
    }
    return ok;
  }

  static Future<void> pushAllIncidents(
      List<Map<String, dynamic>> incidents) async {
    for (final inc in incidents) {
      await pushIncident(inc);
    }
  }

  /// Push error log to backend for admin visibility
  static Future<bool> pushErrorLog(Map<String, dynamic> errorLog) async {
    // ★ Supabase path (if implemented)
    // if (SupabaseConfig.enabled) {
    //   return SupabaseService.insertErrorLog(errorLog);
    // }

    if (!await isConfigured) return false;

    try {
      final url = await getBackendUrl();
      final body = Map<String, dynamic>.from(errorLog);
      body['action'] = 'pushErrorLog';

      // Clean nulls
      body.removeWhere((key, value) => value == null);

      final resp = await _postWithRedirect(url, body,
          timeout: const Duration(seconds: 15));

      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && (data['success'] == true || data['ok'] == true)) {
          print('SyncService: pushErrorLog SUCCESS for ${errorLog['errorType']}');
          return true;
        }
        print('SyncService: pushErrorLog response: ${resp.body}');
      }
    } catch (e) {
      print('SyncService: pushErrorLog error: $e');
    }

    return false;
  }

  // ═══════════════════════════════════════════════════════════════
  //  DEBUG — returns full response for diagnosing Sheets issues
  // ═══════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>> testPush() async {
    final url = await getBackendUrl();
    final testBody = jsonEncode({
      'action':  'addIncident',
      'id':      'TEST_${DateTime.now().millisecondsSinceEpoch}',
      'title':   'Test from Flutter app',
      'plant':   'Test Plant',
      'dept':    'Safety',
      'severity':'HIGH',
      'status':  'OPEN',
      'type':    'AI_SCAN',
      'date':    DateTime.now().toIso8601String(),
      'reportedBy': 'System Test',
    });
    try {
      final client = http.Client();
      http.Response resp;
      try {
        resp = await client.post(Uri.parse(url),
          body: testBody,
          headers: {'Content-Type': 'text/plain;charset=utf-8'})
          .timeout(const Duration(seconds: 30));
        if (resp.statusCode == 302 || resp.statusCode == 301) {
          final loc = resp.headers['location'] ?? '';
          if (loc.isNotEmpty) {
            resp = await client.get(Uri.parse(loc))
              .timeout(const Duration(seconds: 30));
          }
        }
      } finally { client.close(); }
      return {
        'statusCode': resp.statusCode,
        'body': resp.body.length > 500
            ? resp.body.substring(0, 500) : resp.body,
        'headers': resp.headers,
        'url': url,
      };
    } catch (e) {
      return {'error': e.toString(), 'url': url};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ONLINE LOGIN — tries Apps Script; returns user map or null
  //  ★ v25: Also stores the server-issued session token for
  //  authenticated API calls (addIncident, updateIncident, etc.)
  // ═══════════════════════════════════════════════════════════════
  //
  //  This is now the LEGACY (Apps Script) path only. Do not add callers:
  //  AuthService.signIn is the single entry point for authentication, and it
  //  reaches this method only when Supabase is disabled.
  //
  //  A Supabase branch used to sit at the top of this method and accepted the
  //  login when the client's TRANSPORTED hash equalled the STORED hash. That
  //  makes the hash itself a working credential — and `app_users` is readable
  //  with the anon key that ships in every build, so anyone who could read a
  //  row could log in as that person without ever knowing their password. It
  //  has been removed. Cross-device login now happens in AuthService.signIn,
  //  which re-hashes the typed password with the row's OWN salt and never
  //  compares two hashes that both came off the wire.
  // ═══════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>?> loginOnline(
      String username, String passwordHash) async {
    if (!await isConfigured) {
      print('SyncService.loginOnline: backend not configured');
      return null;
    }
    try {
      final url = await getBackendUrl();
      // SECURITY: never log the credential hash. Log only the (non-secret) username.
      assert(() {
        print('SyncService.loginOnline: attempting login for "$username"');
        return true;
      }());
      final resp = await _postWithRedirect(url, {
        'action': 'login',
        'username': username,
        'passwordHash': passwordHash,
      });

      if (resp == null) {
        print('SyncService.loginOnline: null response (network error or timeout)');
        return null;
      }

      print('SyncService.loginOnline: status=${resp.statusCode}, bodyLen=${resp.body.length}');

      if (resp.statusCode == 200) {
        final bodyText = resp.body.trim();
        if (bodyText.startsWith('<')) {
          print('SyncService.loginOnline: got HTML response, not JSON');
          return null;
        }
        final data = jsonDecode(bodyText) as Map<String, dynamic>;
        print('SyncService.loginOnline: response data=${data.keys.toList()}, success=${data['success']}');

        if (data['success'] == true) {
          // ✅ Store the server-issued session token
          final serverToken = data['sessionToken']?.toString() ?? '';
          if (serverToken.isNotEmpty) {
            final userId = username;
            await AuthTokenService.storeServerToken(serverToken, userId);
            print('SyncService.loginOnline: stored server token for $userId');
          }

          if (data['user'] is Map) {
            return Map<String, dynamic>.from(data['user'] as Map);
          }
          // Flat format (admin hardcode path)
          final flat = Map<String, dynamic>.from(data);
          flat.remove('success');
          flat.remove('sessionToken');
          flat.remove('tokenExpiry');
          if (flat['username'] != null) return flat;
        } else {
          print('SyncService.loginOnline: login rejected — ${data['error'] ?? 'unknown error'}');
        }
      }
      return null;
    } catch (e) {
      print('SyncService.loginOnline: exception — $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  REGISTER ONLINE — direct call to Apps Script 'register' action
  // ═══════════════════════════════════════════════════════════════
  static Future<bool> registerOnline(Map<String, dynamic> userData) async {
    // ★ Supabase path: upsert into app_users (creates the account row).
    if (SupabaseConfig.enabled) {
      return SupabaseService.upsertUser(userData);
    }
    if (!await isConfigured) return false;
    try {
      final url = await getBackendUrl();
      final body = <String, dynamic>{'action': 'register'};
      userData.forEach((k, v) {
        if (v != null) body[k] = v.toString();
      });
      final resp = await _postWithRedirect(url, body);
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && data['success'] == true) {
          print('SyncService: registerOnline SUCCESS for ${userData['username']}');
          return true;
        }
        print('SyncService: registerOnline failed: ${resp.body}');
      }
      return false;
    } catch (e) {
      print('SyncService: registerOnline error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  UPLOAD PDF TO DRIVE — returns shareable URL, updates incident
  // ═══════════════════════════════════════════════════════════════
  static Future<String?> uploadPdfToDrive({
    required String incidentId,
    required Uint8List pdfBytes,
    String? fileName,
  }) async {
    if (!await isConfigured) return null;
    try {
      final url = await getBackendUrl();
      final name = fileName ?? 'SafetyLens_${incidentId}.pdf';
      final body = jsonEncode({
        'action':     'uploadPdfToDrive',
        'incidentId': incidentId,
        'fileName':   name,
        'pdfBase64':  base64Encode(pdfBytes),
      });

      print('PDF Upload: sending ${body.length} bytes to Apps Script...');

      // Apps Script redirects POST → GET on googleusercontent.com
      // Must follow redirect with GET (not re-POST) to get the JSON response
      final client = http.Client();
      http.Response resp;
      try {
        resp = await client.post(
          Uri.parse(url),
          body: body,
          headers: {'Content-Type': 'text/plain;charset=utf-8'},
        ).timeout(const Duration(seconds: 90));

        // Apps Script always redirects POST to a result URL via 302
        // The redirect is a GET — the response JSON is at that URL
        if (resp.statusCode == 302 || resp.statusCode == 301) {
          final loc = resp.headers['location'] ?? '';
          print('PDF Upload: following redirect to ${loc.length > 80 ? loc.substring(0, 80) : loc}...');
          if (loc.isNotEmpty) {
            // ✅ FIX: Use GET for the redirect (Apps Script returns result via GET)
            resp = await client.get(
              Uri.parse(loc),
              headers: {'Accept': 'application/json'},
            ).timeout(const Duration(seconds: 30));
          }
        }
      } finally { client.close(); }

      print('PDF Upload: response status=${resp.statusCode}, bodyLen=${resp.body.length}');

      if (resp.statusCode == 200) {
        // Guard against HTML error pages
        final bodyTrimmed = resp.body.trim();
        if (bodyTrimmed.startsWith('<')) {
          print('PDF Upload: got HTML instead of JSON');
          return null;
        }
        try {
          final data = jsonDecode(bodyTrimmed);
          if (data['success'] == true) {
            return data['pdfUrl']?.toString();
          }
          print('PDF Upload: server error: ${data['error'] ?? 'unknown'}');
        } catch (e) {
          print('PDF Upload: JSON parse error: $e');
        }
      }
      return null;
    } catch (e) {
      print('PDF Upload: exception — $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  DELETE INCIDENT from Sheets (admin action)
  // ═══════════════════════════════════════════════════════════════
  static Future<bool> deleteIncident(String id) async {
    // ★ Supabase path — a real DELETE (no resurrection possible).
    if (SupabaseConfig.enabled) {
      return SupabaseService.deleteIncident(id);
    }
    if (!await isConfigured) return false;
    try {
      final url = await getBackendUrl();
      final resp = await _postWithRedirect(url, {
        'action': 'deleteIncident', 'id': id,
      });
      if (resp != null && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['ok'] == true || data['success'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ★ v25: Auto-fire alerts when a CRITICAL incident is synced
  /// ★ v35: Enhanced alert evaluation — supports all trigger types
  /// Fires backend-triggered SMS/Email for incidents, AI scans, and near misses
  static Future<void> _checkAndFireAlerts(Map<String, dynamic> incident) async {
    try {
      final severity = (incident['severity']?.toString() ?? '').toUpperCase();
      final type = incident['type']?.toString() ?? '';

      // Determine what type of alert data this is
      final isAiScan = type == 'ai_scan' || incident.containsKey('detectedSection');
      final isNearMiss = type == 'near_miss' || type == 'Near Miss';

      // ★ Backend-triggered approach: tell backend to evaluate and send alerts
      // Backend has the full rule set (synced via syncAlertRules) and handles delivery
      await AdminAlerts.fireImmediateAlert(
        type: isAiScan ? 'ai_scan' : (isNearMiss ? 'near_miss' : 'incident'),
        data: {
          'id': incident['id'] ?? '',
          'title': incident['title'] ?? incident['desc'] ?? '',
          'severity': severity,
          'plant': incident['plant'] ?? '',
          'dept': incident['dept'] ?? incident['department'] ?? '',
          'detectedSection': incident['detectedSection'] ?? '',
          'date': incident['date'] ?? DateTime.now().toIso8601String(),
          'reportedBy': incident['reportedBy'] ?? '',
          'summary': incident['summary'] ?? '',
          'riskScore': incident['riskScore'] ?? 0,
          'hazardCount': (incident['hazards'] is List)
              ? (incident['hazards'] as List).length : 0,
          'topHazards': (incident['hazards'] is List)
              ? (incident['hazards'] as List)
                  .take(3)
                  .map((h) => h is Map ? '${h['name']} (${h['severity']})' : h.toString())
                  .toList()
              : [],
        },
      );

      // Also do local evaluation for immediate rules (backup if backend is slow)
      if (severity == 'CRITICAL' || severity == 'HIGH' || isAiScan || isNearMiss) {
        final rules = await AdminAlerts.getRules();
        final firingRules = AdminAlerts.evaluate(
          rules,
          [incident],
          latestAiScan: isAiScan ? incident : null,
          latestNearMiss: isNearMiss ? incident : null,
          // Pass the admin's live status ladder and plant list so a renamed
          // stage or plant doesn't quietly stop rules from matching.
          openStatuses: await AdminMasterData.getOpenStatuses(),
          plants: await AdminMasterData.getPlants(),
        );

        if (firingRules.isNotEmpty) {
          await AdminAlerts.deliver(firingRules, [incident]);
          print('[SyncService] Auto-fired ${firingRules.length} alert(s) for $type (severity: $severity)');
        }
      }
    } catch (e) {
      print('[SyncService] Alert fire error (non-fatal): $e');
    }
  }

}
