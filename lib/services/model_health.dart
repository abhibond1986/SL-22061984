// lib/services/model_health.dart
//
// PER-MODEL HEALTH COUNTERS — "which model is actually working?"
//
// WHY THIS EXISTS (and why AiRunLog could not answer it)
//   AiRunLog writes exactly ONE record per scan, and that record names a model
//   only when the scan SUCCEEDED — every FAILED row is stamped with a
//   chain-level reason such as `providers_exhausted`, which can hide up to nine
//   individual model attempts across four providers. So the admin question
//   "is model X failing every single time, should I remove it from the list?"
//   was structurally unanswerable: successes were attributable, failures were
//   not.
//
//   This service records ONE ROW PER ATTEMPT instead of per scan. A single scan
//   that walks Groq → three Gemini models → three OpenRouter models → Nara
//   produces up to eight entries here and still exactly one row in AiRunLog.
//   The two are complements, not duplicates:
//
//     AiRunLog     "did the user get an answer, how fast, how often"  (per scan)
//     ModelHealth  "which slug earned it and which slug wasted time"  (per try)
//
// DELIBERATELY DEVICE-LOCAL
//   No Supabase mirror and no schema change. supabase_service's ai_runs mapping
//   warns that an unknown column kills the whole insert, and the value here is
//   an admin sitting in front of one device deciding whether to delete a slug —
//   which does not need fleet aggregation to be obvious. A model that is dead
//   is dead on every device, because the cause is the provider's catalogue.
//   Consequence to state in the UI: these numbers describe THIS phone/browser.
//
// BOUNDED BY CONSTRUCTION
//   Keys are model IDs, which come from fixed lists in code (GeminiVision's
//   chain, NaraVision.availableModels, the admin dropdowns). That is ~15 slugs
//   ever, so the map cannot grow with usage the way a log does. _maxModels is a
//   backstop against a provider that starts echoing request IDs as model names,
//   not an expected pressure.
//
// FAILURE KINDS ARE THE POINT
//   "40 failures" is not actionable; "40 failures, all dead_slug" means delete
//   the model, while "40 failures, all timeout" means raise its ceiling or
//   shrink the prompt, and "all quota" means the model is fine and the ACCOUNT
//   is the limit — removing it would be exactly the wrong move. Every call site
//   must therefore classify, and the kinds below are the vocabulary.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One model's running tally. Immutable snapshot handed to the UI.
class ModelHealthEntry {
  final String model;

  /// Which tier/provider last used this slug: `'groq'`, `'gemini'`,
  /// `'openrouter'`, `'nara'`. Stored because the SAME slug can be served by
  /// two providers at two prices (`qwen/qwen3.6-27b` is free on Groq and paid
  /// on OpenRouter), so the model ID alone does not identify the route.
  final String provider;

  final int attempts;
  final int successes;
  final int failures;

  /// `failKind` → count. Keys are the `kFail*` constants below.
  final Map<String, int> failKinds;

  /// Summed duration of SUCCESSFUL attempts only, in ms.
  ///
  /// Failures are excluded because a timeout contributes exactly its ceiling
  /// (20s or 35s) and would drag the average toward the cap, making a fast
  /// model that occasionally stalls look slower than a uniformly mediocre one.
  /// The question this column answers is "when it works, how long do I wait".
  final int okMsTotal;

  /// Duration of the most recent attempt, success or failure, in ms.
  final int lastMs;

  /// Epoch ms, 0 if never.
  final int lastOkAt;
  final int lastFailAt;
  final int firstSeenAt;

  /// Kind of the most recent failure, `''` if none yet.
  final String lastFailKind;

  const ModelHealthEntry({
    required this.model,
    required this.provider,
    required this.attempts,
    required this.successes,
    required this.failures,
    required this.failKinds,
    required this.okMsTotal,
    required this.lastMs,
    required this.lastOkAt,
    required this.lastFailAt,
    required this.firstSeenAt,
    required this.lastFailKind,
  });

  /// 0..100. Returns 0 for an unused model rather than throwing — the UI
  /// renders zero-attempt rows (a model that was configured but never reached
  /// is itself a finding).
  double get successRate =>
      attempts == 0 ? 0 : (successes * 100.0) / attempts;

  /// Average ms per SUCCESSFUL attempt, or 0 if it has never succeeded.
  int get avgOkMs => successes == 0 ? 0 : (okMsTotal / successes).round();

  /// The failure kind that accounts for the most failures, `''` if none.
  ///
  /// This is the field that turns the panel into a decision: it names WHY the
  /// model is failing, and only `dead_slug` / `unparseable` argue for removal.
  String get dominantFailKind {
    String best = '';
    int bestN = 0;
    failKinds.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        best = k;
      }
    });
    return best;
  }

  int get dominantFailCount => failKinds[dominantFailKind] ?? 0;

  /// True when this model has been tried enough times to judge and has never
  /// once worked. The threshold exists so a single unlucky 429 on a model's
  /// first use does not get it deleted.
  bool get isHopeless => attempts >= 3 && successes == 0;

  Map<String, dynamic> toJson() => {
        'p': provider,
        'a': attempts,
        's': successes,
        'f': failures,
        'k': failKinds,
        'ms': okMsTotal,
        'lms': lastMs,
        'ok': lastOkAt,
        'fa': lastFailAt,
        'fs': firstSeenAt,
        'lk': lastFailKind,
      };

  /// Short keys above are not premature optimisation: this whole map is one
  /// SharedPreferences string read on every admin-panel open, and on web that
  /// is a synchronous localStorage hit.
  factory ModelHealthEntry.fromJson(String model, Map<String, dynamic> j) {
    final rawKinds = j['k'];
    final kinds = <String, int>{};
    if (rawKinds is Map) {
      rawKinds.forEach((k, v) {
        final n = v is int ? v : int.tryParse('$v') ?? 0;
        if (n > 0) kinds['$k'] = n;
      });
    }
    int i(String key) {
      final v = j[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}') ?? 0;
    }

    return ModelHealthEntry(
      model: model,
      provider: (j['p'] ?? '').toString(),
      attempts: i('a'),
      successes: i('s'),
      failures: i('f'),
      failKinds: kinds,
      okMsTotal: i('ms'),
      lastMs: i('lms'),
      lastOkAt: i('ok'),
      lastFailAt: i('fa'),
      firstSeenAt: i('fs'),
      lastFailKind: (j['lk'] ?? '').toString(),
    );
  }

  ModelHealthEntry _withAttempt({
    required String provider,
    required bool ok,
    required int ms,
    required String failKind,
    required int now,
  }) {
    final kinds = Map<String, int>.from(failKinds);
    if (!ok) {
      final kind = failKind.isEmpty ? ModelHealth.kFailUnknown : failKind;
      kinds[kind] = (kinds[kind] ?? 0) + 1;
    }
    return ModelHealthEntry(
      model: model,
      // Last writer wins on provider: if a slug moves tiers, the current route
      // is the useful one to display.
      provider: provider.isEmpty ? this.provider : provider,
      attempts: attempts + 1,
      successes: successes + (ok ? 1 : 0),
      failures: failures + (ok ? 0 : 1),
      failKinds: kinds,
      okMsTotal: okMsTotal + (ok ? ms : 0),
      lastMs: ms,
      lastOkAt: ok ? now : lastOkAt,
      lastFailAt: ok ? lastFailAt : now,
      firstSeenAt: firstSeenAt == 0 ? now : firstSeenAt,
      lastFailKind: ok ? lastFailKind : (failKind.isEmpty ? ModelHealth.kFailUnknown : failKind),
    );
  }
}

class ModelHealth {
  ModelHealth._();

  static const String _kStore = 'model_health_v1';

  /// Backstop only — see the header note. Eviction drops the LEAST RECENTLY
  /// TOUCHED entry, so an actively-used chain is never displaced by noise.
  static const int _maxModels = 40;

  // ── Failure kinds ─────────────────────────────────────────────────────────
  // Stable short codes so they group across app versions. Each maps to a
  // DIFFERENT remedy, which is why they are not collapsed into "error".

  /// The attempt hit its per-attempt ceiling. Remedy: raise the ceiling or
  /// shrink the output — NOT removal.
  static const String kFailTimeout = 'timeout';

  /// 429/402 that belongs to OUR account (daily or per-minute quota, or no
  /// credit). The model is innocent; removing it does nothing.
  static const String kFailQuota = 'quota';

  /// 429 raised by the provider BEHIND one model ("rate-limited upstream").
  /// Transient and per-model; see [[vision-chain-failures]]. Not our limit.
  static const String kFailUpstream = 'upstream_429';

  /// The provider says this slug does not exist / is not available. THE ONE
  /// KIND THAT MEANS "DELETE IT". Note NaraRouter reports this as 400, not 404.
  static const String kFailDeadSlug = 'dead_slug';

  /// Key invalid, revoked, or forbidden. Affects every model on that provider,
  /// so a whole tier's entries will show it together — a tell that the fix is
  /// the key, not the list.
  static const String kFailKeyBlocked = 'key_blocked';

  /// HTTP 200 but the body could not be turned into the hazard schema (JSON is
  /// prompt-instructed, not enforced by `response_format`). Persistent
  /// unparseable IS an argument for removal: the model cannot follow the
  /// schema.
  static const String kFailUnparseable = 'unparseable';

  /// HTTP 200, parsed fine, but no usable content (no candidates, empty text,
  /// or the thinking budget ate `maxOutputTokens`).
  static const String kFailEmpty = 'empty';

  /// Network/socket error, or the attempt was never sent.
  static const String kFailNetwork = 'network';

  /// Any other non-2xx or thrown exception.
  static const String kFailError = 'error';

  /// Recorded when a call site fails to classify. If this dominates any model,
  /// the bug is in the instrumentation, not the model.
  static const String kFailUnknown = 'unknown';

  /// Human labels for the panel. Kept beside the codes so a new kind cannot be
  /// added without a label.
  static const Map<String, String> failKindLabels = {
    kFailTimeout: 'Timed out',
    kFailQuota: 'Our quota / credit',
    kFailUpstream: 'Provider busy (upstream 429)',
    kFailDeadSlug: 'Model not available',
    kFailKeyBlocked: 'API key blocked',
    kFailUnparseable: 'Bad JSON',
    kFailEmpty: 'Empty reply',
    kFailNetwork: 'Network',
    kFailError: 'Other error',
    kFailUnknown: 'Unclassified',
  };

  static String failKindLabel(String kind) =>
      failKindLabels[kind] ?? (kind.isEmpty ? '—' : kind);

  /// Kinds that argue for taking the model OUT of the chain, as opposed to
  /// fixing something around it. Used by the panel to colour its advice.
  static const Set<String> removalWorthyKinds = {
    kFailDeadSlug,
    kFailUnparseable,
  };

  // ── State ─────────────────────────────────────────────────────────────────

  /// In-memory mirror. Loaded once, then kept in step with every write, so the
  /// hot path (a vision attempt) never waits on a disk read.
  static Map<String, ModelHealthEntry>? _cache;

  /// Serialises read-modify-write, exactly as AiRunLog._writeChain does and for
  /// the same reason: a chain walk fires several recordAttempt() calls in quick
  /// succession and interleaved writes would silently drop counts.
  static Future<void> _writeChain = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() action) {
    final completer = _writeChain.then((_) => action());
    _writeChain = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  static Future<Map<String, ModelHealthEntry>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, ModelHealthEntry>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStore);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is Map) {
              out['$k'] =
                  ModelHealthEntry.fromJson('$k', Map<String, dynamic>.from(v));
            }
          });
        }
      }
    } catch (_) {
      // A corrupt blob must not break scanning — telemetry is never allowed to
      // be load-bearing. Start clean; the next write repairs the store.
    }
    _cache = out;
    return out;
  }

  static Future<void> _save(Map<String, ModelHealthEntry> map) async {
    if (map.length > _maxModels) {
      final keys = map.keys.toList()
        ..sort((a, b) {
          int seen(ModelHealthEntry e) =>
              e.lastOkAt > e.lastFailAt ? e.lastOkAt : e.lastFailAt;
          return seen(map[a]!).compareTo(seen(map[b]!));
        });
      for (final k in keys.take(map.length - _maxModels)) {
        map.remove(k);
      }
    }
    _cache = map;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kStore,
        jsonEncode({for (final e in map.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // Keep the in-memory numbers even if persistence fails; the current
      // session's panel is still correct.
    }
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  /// Records ONE attempt against ONE model.
  ///
  /// Fire-and-forget from the vision chain — callers must NOT await this on the
  /// hot path, and it never throws.
  ///
  /// [ms] is the wall time of that single attempt, not of the whole scan.
  /// [failKind] is ignored when [ok] is true and required in spirit when it is
  /// false: an unclassified failure is recorded as [kFailUnknown], which the
  /// panel shows as a bug in the instrumentation.
  static Future<void> recordAttempt({
    required String model,
    required String provider,
    required bool ok,
    int ms = 0,
    String failKind = '',
  }) async {
    final id = model.trim();
    if (id.isEmpty) return; // nothing to attribute the attempt to
    try {
      await _locked(() async {
        final map = Map<String, ModelHealthEntry>.from(await _load());
        final now = DateTime.now().millisecondsSinceEpoch;
        final existing = map[id] ??
            ModelHealthEntry(
              model: id,
              provider: provider,
              attempts: 0,
              successes: 0,
              failures: 0,
              failKinds: const {},
              okMsTotal: 0,
              lastMs: 0,
              lastOkAt: 0,
              lastFailAt: 0,
              firstSeenAt: now,
              lastFailKind: '',
            );
        map[id] = existing._withAttempt(
          provider: provider,
          ok: ok,
          ms: ms < 0 ? 0 : ms,
          failKind: ok ? '' : failKind,
          now: now,
        );
        await _save(map);
      });
    } catch (_) {
      // Never let telemetry fail a scan.
    }
  }

  /// Convenience wrapper for a successful attempt.
  static Future<void> recordSuccess(String model, String provider, int ms) =>
      recordAttempt(model: model, provider: provider, ok: true, ms: ms);

  /// Convenience wrapper for a failed attempt.
  static Future<void> recordFailure(
          String model, String provider, String failKind, [int ms = 0]) =>
      recordAttempt(
          model: model, provider: provider, ok: false, ms: ms, failKind: failKind);

  // ── Reading ───────────────────────────────────────────────────────────────

  /// Every model we have ever attempted, worst first.
  ///
  /// Ordering is the feature: the admin opened this panel to find the model to
  /// delete, so the sort puts the most-failing model at the top. Within the
  /// same success rate, more attempts ranks higher because it is better
  /// evidence.
  static Future<List<ModelHealthEntry>> snapshot() async {
    final map = await _load();
    final list = map.values.toList()
      ..sort((a, b) {
        final r = a.successRate.compareTo(b.successRate);
        if (r != 0) return r;
        return b.attempts.compareTo(a.attempts);
      });
    return list;
  }

  /// One model's counters, or null if it has never been attempted on this
  /// device. Used by the compact line above each admin dropdown.
  static Future<ModelHealthEntry?> forModel(String model) async {
    final map = await _load();
    return map[model.trim()];
  }

  /// Cheap synchronous read for widgets that already triggered a load.
  ///
  /// Returns null before the first [snapshot]/[forModel] call rather than
  /// blocking, so a build() method can render "—" and fill in on the next
  /// frame.
  static ModelHealthEntry? cachedFor(String model) =>
      _cache?[model.trim()];

  static bool get isLoaded => _cache != null;

  // ── Maintenance ───────────────────────────────────────────────────────────

  /// Clears every counter. Offered in the panel because these numbers are
  /// cumulative and a chain change (new slug, new timeout) invalidates the
  /// history — without a reset the admin would be judging a fixed model on its
  /// broken past.
  static Future<void> resetAll() => _locked(() async {
        _cache = <String, ModelHealthEntry>{};
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_kStore);
        } catch (_) {}
      });

  /// Drops one model's counters — used after removing a slug from the chain, so
  /// an orphaned row stops cluttering the panel.
  static Future<void> forget(String model) => _locked(() async {
        final map = Map<String, ModelHealthEntry>.from(await _load());
        map.remove(model.trim());
        await _save(map);
      });
}
