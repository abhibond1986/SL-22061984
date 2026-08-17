// lib/services/gemini_direct_vision.dart
// ★ v28: Direct Gemini Vision API for hazard image analysis
//
// Free tier: 15 requests/minute, 1M tokens/day, image input via base64,
// no billing required — just an API key from https://aistudio.google.com/apikey
//
// This runs as TIER 2 of the vision chain in gemini_vision.dart, on a quota
// separate from OpenRouter's, so it still works when OpenRouter returns 429.
//
// ⚠ MODEL IDS EXPIRE. Google retires models on published shutdown dates, after
// which the endpoint returns HTTP 404 "This model is no longer available" and
// analysis fails silently. On 2026-08-15 this file still pointed at
// gemini-2.0-flash and gemini-2.0-flash-lite, both shut down 2026-06-01, so
// every direct-Gemini scan 404'd. Before editing the chain below, check
// https://ai.google.dev/gemini-api/docs/deprecations for shutdown dates and add
// any newly-retired ID to [_retiredModels] so saved user preferences migrate.

import 'dart:convert';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_master_data.dart';

class GeminiDirectVision {
  static const String _kApiKey = 'gemini_vision_api_key';
  static const String _kModel = 'gemini_vision_model';
  /// Default Tier 2 model when no admin selection is saved.
  ///
  /// Flash-Lite, not Flash, since 2026-08-17. Reordering [_modelFallbackChain]
  /// alone would NOT have taken effect: [analyzeImage] puts the admin's
  /// `selected` model at the head of the attempt list, and `selected` falls back
  /// to this constant — so with 3.6-flash here, Flash still went first on every
  /// device that had never touched the admin dropdown, and the reordered chain
  /// below only applied from the second attempt onward.
  ///
  /// ⚠ Devices with a model ALREADY saved in SharedPreferences keep using it —
  /// see [_retiredModels] for why changing this constant does not reach them.
  /// An admin who previously pinned 3.6 Flash must change it in
  /// Admin → System Health to pick up this new default.
  static const String defaultModel = 'gemini-3.1-flash-lite';

  /// Retired model IDs → their documented replacement.
  ///
  /// Why this map is essential and not just cosmetic: the selected model is
  /// persisted in SharedPreferences on each device. Changing [defaultModel]
  /// alone does NOT help anyone who already has a retired ID saved — their
  /// browser keeps sending the dead model forever. [getModel] rewrites through
  /// this map so existing installs self-heal on the next scan.
  static const Map<String, String> _retiredModels = {
    'gemini-2.0-flash': 'gemini-3.6-flash',
    'gemini-2.0-flash-001': 'gemini-3.6-flash',
    'gemini-2.0-flash-lite': 'gemini-3.1-flash-lite',
    'gemini-2.0-flash-lite-001': 'gemini-3.1-flash-lite',
    'gemini-1.5-flash': 'gemini-3.6-flash',
    'gemini-1.5-pro': 'gemini-2.5-pro',
    'gemini-2.5-flash-preview-09-25': 'gemini-3.6-flash',
  };

  static SharedPreferences? _prefs;

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Check if Gemini API key is configured
  static Future<bool> get isConfigured async {
    await _ensurePrefs();
    final key = _prefs!.getString(_kApiKey) ?? '';
    return key.isNotEmpty && key.length > 20;
  }

  /// Get stored API key
  static Future<String> getApiKey() async {
    await _ensurePrefs();
    return _prefs!.getString(_kApiKey) ?? '';
  }

  /// Save API key (from Admin panel)
  static Future<void> setApiKey(String key) async {
    await _ensurePrefs();
    await _prefs!.setString(_kApiKey, key.trim());
  }

  /// Get current model, transparently upgrading a retired saved ID.
  ///
  /// The rewrite is persisted so the admin panel dropdown also stops showing a
  /// dead model, and so this costs one write rather than one lookup per scan.
  static Future<String> getModel() async {
    await _ensurePrefs();
    final saved = _prefs!.getString(_kModel);
    if (saved == null || saved.isEmpty) return defaultModel;
    final replacement = _retiredModels[saved];
    if (replacement != null) {
      print('GeminiDirectVision: ⚙ Saved model "$saved" was retired by Google '
          '— migrating to "$replacement"');
      await _prefs!.setString(_kModel, replacement);
      return replacement;
    }
    return saved;
  }

  /// Set model preference
  static Future<void> setModel(String model) async {
    await _ensurePrefs();
    await _prefs!.setString(_kModel, model);
  }

  /// Models offered in the Admin panel dropdown.
  /// All are current, non-preview, and accept image input. Verified against
  /// https://ai.google.dev/gemini-api/docs/models on 2026-08-15.
  // Order mirrors [_modelFallbackChain] and [defaultModel] — Flash-Lite first.
  // Keep all three in step; a dropdown that disagrees with the runtime chain is
  // how an admin ends up "selecting" a model that is not actually tried first.
  static const List<Map<String, String>> availableModels = [
    {'id': 'gemini-3.1-flash-lite', 'name': 'Gemini 3.1 Flash-Lite (Recommended — highest quota, fastest)'},
    {'id': 'gemini-3.6-flash',      'name': 'Gemini 3.6 Flash (fast)'},
    {'id': 'gemini-3.7-flash',      'name': 'Gemini 3.7 Flash (Newest)'},
    {'id': 'gemini-2.5-flash',      'name': 'Gemini 2.5 Flash (Older, still supported)'},
    {'id': 'gemini-2.5-pro',        'name': 'Gemini 2.5 Pro (Most accurate, low quota)'},
  ];

  /// Tried in order after the admin's selected model, so a per-model rate limit
  /// or an unexpected retirement does not end the scan. Each entry is a distinct
  /// model with its own quota bucket.
  // ORDER = HIGHEST QUOTA + LOWEST LATENCY FIRST (set 2026-08-17 on admin
  // request). Flash-Lite leads because this tier only ever runs when Tier 1 has
  // already failed — usually because a shared free allowance is spent — so the
  // model with the most quota headroom and the fastest response is the one most
  // likely to actually finish the scan. The heavier Flash models follow as
  // quality fallbacks.
  static const List<String> _modelFallbackChain = [
    'gemini-3.1-flash-lite', // FIRST: highest quota, fastest; documented replacement for 2.0-flash-lite
    'gemini-3.6-flash',      // Documented replacement for 2.0-flash
    'gemini-2.5-flash',      // Older generation, still supported — extra headroom
  ];

  // ★ v25: Track if quota is exhausted (429) — all models on same key are blocked
  static bool _quotaExhausted = false;
  static DateTime? _quotaExhaustedAt;

  /// Analyze image for safety hazards
  /// Returns structured hazard data or null on failure
  /// [kbContext] — optional knowledge bank content to inject into prompt for accurate regulations
  /// ★ v25: FAST BAIL on 429 — all models share same key/quota, no point trying others
  static Future<Map<String, dynamic>?> analyzeImage(Uint8List imageBytes, {String? kbContext}) async {
    if (!await isConfigured) return null;

    // If quota was exhausted recently (within 60s), skip entirely
    if (_quotaExhausted && _quotaExhaustedAt != null &&
        DateTime.now().difference(_quotaExhaustedAt!).inSeconds < 60) {
      print('GeminiDirectVision: ⏭ Skipping — quota exhausted ${DateTime.now().difference(_quotaExhaustedAt!).inSeconds}s ago');
      return null;
    }
    _quotaExhausted = false;

    final apiKey = await getApiKey();
    final selected = await getModel();
    final base64Image = base64Encode(imageBytes);

    // Admin's choice first, then the rest of the chain. Deduplicated so the
    // selected model is not retried, and filtered through _retiredModels so a
    // dead ID can never enter the attempt list.
    final attempts = <String>[
      selected,
      ..._modelFallbackChain,
    ].map((m) => _retiredModels[m] ?? m).toSet().toList();

    for (int i = 0; i < attempts.length; i++) {
      final model = attempts[i];
      print('GeminiDirectVision: ▶ [${i + 1}/${attempts.length}] $model');
      final result =
          await _callModel(model, apiKey, base64Image, kbContext: kbContext);

      // 429/403 is key-wide, not model-specific, so every remaining attempt
      // would fail the same way. This bail is correct — unlike the previous
      // one, which also gave up after a 404, a per-MODEL error the next model
      // in the chain would have survived.
      if (_quotaExhausted) {
        print('GeminiDirectVision: ⚡ Quota/key blocked on $model — '
            'remaining models share the same key, bailing');
        return null;
      }

      if (result != null &&
          result['hazards'] != null &&
          (result['hazards'] as List).isNotEmpty) {
        print('GeminiDirectVision: ✓ SUCCESS on $model');
        result['_source'] = 'gemini_direct';
        result['_model'] = model;
        return result;
      }
    }

    print('GeminiDirectVision: ✗ All ${attempts.length} model(s) failed: '
        '${attempts.join(", ")}');
    return null;
  }

  /// Call a specific Gemini model for image analysis
  static Future<Map<String, dynamic>?> _callModel(String model, String apiKey, String base64Image, {String? kbContext}) async {
    final url = 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

    // KB context goes INTO the prompt builder so it lands inside the citable
    // reference table, not after the instruction forbidding outside citations.
    final String prompt =
        await resolvedComprehensivePrompt(kbContext: kbContext ?? '');

    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text': prompt
            },
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.15,
        'topP': 0.8,
        'maxOutputTokens': 8192,
        'responseMimeType': 'application/json',
      }
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        // ★ v29 FIX: Force UTF-8 decode for non-English text support
        final responseText = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseText) as Map<String, dynamic>;
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            final text = parts[0]['text']?.toString() ?? '';
            return _parseHazardResponse(text);
          }
        }
        print('GeminiDirectVision: [$model] No candidates in response');
        return null;
      } else if (response.statusCode == 429) {
        print('GeminiDirectVision: [$model] Rate limited (429) — ALL models on this key are blocked');
        _quotaExhausted = true;
        _quotaExhaustedAt = DateTime.now();
        return null;
      } else if (response.statusCode == 403) {
        print('GeminiDirectVision: [$model] API key invalid or quota exceeded (403)');
        _quotaExhausted = true;
        _quotaExhaustedAt = DateTime.now();
        return null;
      } else if (response.statusCode == 404) {
        // Model retired by Google. This is per-MODEL, so _quotaExhausted must
        // NOT be set — the caller has to be free to try the next model. Getting
        // this wrong is what made the whole tier fail on 2026-08-15.
        print('GeminiDirectVision: [$model] ⚠ MODEL RETIRED (404) — this ID no '
            'longer exists. Trying next model in chain.');
        print('GeminiDirectVision:   If this repeats for every model, update '
            'availableModels/_modelFallbackChain against '
            'https://ai.google.dev/gemini-api/docs/deprecations');
        return null;
      } else {
        print('GeminiDirectVision: [$model] Error ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        return null;
      }
    } catch (e) {
      print('GeminiDirectVision: [$model] Exception: $e');
      return null;
    }
  }

  /// [_getComprehensivePrompt] with the admin's live severity, observation-type
  /// and WSA-cause vocabularies substituted in. Callers must use this, never the
  /// raw template — otherwise renaming a severity or a cause in the admin panel
  /// leaves this model emitting labels the app's dropdowns no longer accept.
  static Future<String> resolvedComprehensivePrompt({String kbContext = ''}) async {
    List<String> sevs;
    List<String> types;
    List<String> causes;
    try {
      sevs = await AdminMasterData.getSeverities();
    } catch (_) {
      sevs = List<String>.from(AdminMasterData.defaultSeverities);
    }
    try {
      types = await AdminMasterData.getObsTypes();
    } catch (_) {
      types = List<String>.from(AdminMasterData.defaultObservationTypes);
    }
    try {
      causes = await AdminMasterData.getWsaCauses();
    } catch (_) {
      causes = List<String>.from(AdminMasterData.defaultWsaCauses);
    }
    final sevEnum = sevs.isEmpty
        ? 'LOW'
        : sevs.reversed.map((s) => s.toUpperCase()).join('|');
    // 'Line of Fire' drives the lofZone field, so keep it available regardless.
    final typeList = <String>[
      ...types,
      if (!types.any((t) => t.toLowerCase() == 'line of fire')) 'Line of Fire',
    ];
    final causeBlock = causes.isEmpty
        ? 'HAZARD CATEGORIES: none configured — omit "wsaCause" and "wsa".'
        : 'HAZARD CATEGORIES (use the EXACT wording below for "wsaCause" and "wsa"):\n'
            '${causes.join('\n')}';
    // Admin-uploaded knowledge is spliced INTO the verified reference table.
    // Appending it after the table (as the caller used to) placed it after
    // "You MUST ONLY cite regulations from this table" and "NEVER invent
    // section numbers", which told the model to disregard it — so uploaded
    // documents had no real effect on hazard analysis.
    final kbBlock = kbContext.trim().isEmpty
        ? ''
        : '\n── PLANT KNOWLEDGE BANK (uploaded by the safety admin) ──\n'
            'These entries are PART OF THIS TABLE and ARE citable. Where they\n'
            'conflict with the generic entries above, THESE TAKE PRECEDENCE —\n'
            'they are this plant\'s own standards. Cite clause/section numbers\n'
            'exactly as written below.\n'
            '$kbContext\n';

    return _getComprehensivePrompt()
        .replaceAll('{{SEVERITIES}}', sevEnum)
        .replaceAll('{{OBS_TYPES}}', typeList.join('|'))
        .replaceAll('{{WSA_CAUSES}}', causeBlock)
        .replaceAll('{{KB_CONTEXT}}', kbBlock);
  }

  /// ★ v36: FINE-TUNED Comprehensive hazard analysis prompt
  /// Anti-hallucination guardrails + evidence-based reporting + verified statutory references
  /// Section detection enables auto-mapping of hazards to correct department
  static String _getComprehensivePrompt() {
    return '''You are a senior industrial safety inspector for SAIL (Steel Authority of India Limited) with 35+ years of experience across ALL sections of an integrated steel plant.

═══════════════════════════════════════════════════════
★★★ ANTI-HALLUCINATION PROTOCOL — READ BEFORE ANYTHING ★★★
═══════════════════════════════════════════════════════
These rules OVERRIDE all other instructions:

1. ONLY report hazards with CLEAR VISUAL EVIDENCE in THIS image.
2. For EACH hazard, you MUST identify the specific object/condition/person you are looking at.
3. If you cannot describe exactly WHAT you see that constitutes the hazard, DO NOT report it.
4. NEVER assume typical plant hazards exist just because it's an industrial scene.
5. NEVER pad your response with generic checklist items not visible in the image.
6. 3-5 well-evidenced hazards >>> 8-10 assumed/generic ones.
7. "confidence" reflects image clarity AND certainty of hazard identification:
   - 85-100: Crystal clear evidence, unambiguous hazard
   - 65-84: Good evidence, minor interpretation
   - 45-64: Partial evidence, moderate assumption
   - Below 45: Poor image quality or uncertain identification
8. If the image shows a SAFE scene with good practices, SAY SO — report LOW risk.
9. Each "description" MUST start with "Visible: [specific thing seen]" as proof.
10. WRONG regulation = worse than no regulation. When unsure, use the broader category.

SELF-CHECK BEFORE OUTPUTTING EACH HAZARD:
  □ Can I point to a specific area in this image? → If NO, delete this hazard.
  □ Would another inspector looking at this image agree? → If unlikely, delete.
  □ Am I reporting this because I SEE it or because it's "typical"? → If typical, delete.
  □ Is my regulation citation from the VERIFIED table? → If not, fix or delete.

═══════════════════════════════════════════════════════
METHODOLOGY — EVIDENCE-BASED SYSTEMATIC INSPECTION
═══════════════════════════════════════════════════════
Conduct a THOROUGH inspection of the entire image.
Scan in zones: foreground → middle ground → background, then left → right.
For EACH zone, check categories below — but ONLY report what you actually observe.

═══════════════════════════════════════════════════════
STEP 0 — IDENTIFY THE SECTION/DEPARTMENT
═══════════════════════════════════════════════════════
Before analyzing hazards, IDENTIFY which plant section this image belongs to using visual cues below.
Output the detected section in the "detectedSection" field.

── SECTION VISUAL IDENTIFICATION GUIDE ──

BLAST FURNACE (BF):
  Visual cues: Tall cylindrical furnace structure, cast house with tapping holes, slag runners, torpedo ladle on tracks, skip car/conveyor charging system, hot blast stoves (tall cylindrical with checker-work), gas cleaning plant (cyclones/electrostatic precipitators), stock house with bins, bell-less/bell-type charging equipment, burden probes, tuyere area with blow-pipes, monkey/slag notch, iron runners, pig casting machine
  Unique hazards: CO gas (25-28% in BF gas), hot metal splash (1400-1500°C), skull formation on runners, tuyere burnout/burst, hanging/slipping of burden, gas leakage at bleeder valves, furnace breakout, cast house fumes, slag explosion (water contact), charging floor fall, goat (solidified iron in hearth)

STEEL MELTING SHOP / SMS (BOF/LD Converter):
  Visual cues: LD converter vessel (pear-shaped, tilting), charging crane, hot metal transfer ladle, scrap charging box, lance (oxygen blowing), sublance, slag pot on slag car, continuous casting machine (tundish, mould, strand), ladle turret, steel ladle with shroud, fume extraction hood, alloy addition system, argon rinsing station, RH/VAD degasser
  Unique hazards: Hot metal/steel splash (1600°C+), lance failure/burn-through, converter eruption/blow, ladle breakout (lining failure), tundish overflow, mould breakout, SEN clogging, strand breakout (liquid steel escape), slag foaming/slopping, CO gas from converter, overhead crane with liquid metal, scrap moisture explosion

COKE OVEN & BY-PRODUCT PLANT:
  Visual cues: Battery of tall narrow ovens (4-7m high), pusher machine, coke guide car, quenching tower, wharf (hot coke platform), coal tower, gas collecting main, ascension pipes with gooseneck, standpipes, charging car on top, by-product plant (tar decanters, benzol scrubbers, ammonia still, H2S removal)
  Unique hazards: Coke oven gas (H2+CH4+CO, explosive), door leakage/emissions, ascension pipe blockage/fire, charging emission, green push (undercooked coke - fire/gas), falling from battery top, coal dust explosion, by-product chemicals (benzol-carcinogen, tar, ammonia, H2S), quenching car burns, pusher ram failure, oven wall collapse/cross-wall failure

SINTER PLANT:
  Visual cues: Sinter strand (long travelling grate), ignition hood, wind boxes below strand, circular cooler, raw material proportioning bins, mixing drum, nodulizing drum, crusher (spike/roll), hot screening, electrostatic precipitator for de-dusting, sinter cake on strand, wind legs, exhaust fans
  Unique hazards: Hot sinter (700-900°C), dust exposure (iron ore + limestone), burns from ignition hood, conveyor entanglement, hot screening area burns, ESP fire (carbon in dust), fan impeller failure, material surge from bin collapse, heat stress

ROLLING MILLS (HSM/CRM/Bar & Rod/Plate/Section):
  Visual cues: Reheating furnace (walking beam/pusher type), roughing stand, finishing stand, run-out table (ROT) with laminar cooling, coiler/down-coiler, hot plate on roller table, flying shear, crop shear, cold rolling stand (4-hi/6-hi), pickling line (acid tanks), annealing furnace, skin pass mill, tension reel, slitter, cut-to-length line, cooling bed (for long products)
  Unique hazards: Hot material ejection (cobble), strip breakage in cold rolling (flying strip), reheating furnace gas leak, skid mark burns, roller table entanglement, flying shear proximity, cooling bed material falling, pickling acid splash (HCl/H2SO4), annealing furnace H2 atmosphere explosion, crane handling hot coils, emulsion fire in cold rolling

POWER PLANT (CPP/BPPP/TPS):
  Visual cues: Boiler structure (tall, multi-level), turbine hall, cooling towers, coal handling plant (conveyors, bunkers, crushers), ash handling (slurry pumps, ash pond), chimney/stack, DM plant, steam headers, control room with DCS panels, switchyard (HT transformers, isolators, bus-bars), cable galleries
  Unique hazards: High-pressure steam leak (boiler 100+ kg/cm²), turbine over-speed, coal dust explosion in bunkers, confined space in boiler drums, electrical arc flash in switchyard, ash slurry pipe burst, condenser tube leak, H2 cooling system leak (generator), ammonia leak (DM plant), fall from boiler structure, coal fire in stockpile

ELECTRICAL (Substation/Panel Rooms/Cable Galleries):
  Visual cues: HT/LT panels, transformers (oil-filled), switchgear (VCB/SF6), bus-bar chambers, cable trays/racks, battery rooms, UPS, capacitor banks, earthing pit, relay panels, SCADA/DCS, motor control centres (MCC), overhead lines, CT/PT, lightning arresters
  Unique hazards: Arc flash/blast (incident energy), electrocution, transformer oil fire, SF6 gas leak, battery room H2 accumulation, cable fire, inadequate earthing, working on live equipment, unauthorized switching, absence of LOTO, missing danger boards, step/touch potential

GAS NETWORK (BF Gas/CO Gas/Mixed Gas/LD Gas):
  Visual cues: Gas holders (cylindrical storage), gas pipelines (large diameter with colour coding), gas boosters, gas mixing station, bleeder stacks, condensate pots, water seals, gas flare stack, valve stations, gas pressure regulators, purging connections
  Unique hazards: CO poisoning (BF gas 25-28% CO, coke oven gas 6-8% CO, LD gas 60-70% CO), gas leak/explosion, oxygen deficiency in pipeline vicinity, purging failures, water seal blow-through, gas holder piston jam, condensate accumulation causing pressure surge, static electricity ignition

MATERIAL HANDLING (RMHP/Ore Handling/Coal Handling):
  Visual cues: Stacker-reclaimer, ship unloader, wagon tippler, conveyor belt system (long runs), transfer towers, belt feeders, vibrating screens, crushing plant, stockyard with stock piles, hoppers, tripper cars, ore/coal wagons, trestle, sampling station
  Unique hazards: Conveyor entanglement (nip points), belt fire, chute blockage clearing (confined space), falling material from height, stockpile collapse/engulfment, dust explosion, wagon movement (rail track), stacker boom collision, material fall from transfer tower, belt snapping

MAINTENANCE SHOPS (Mechanical/Electrical/Civil):
  Visual cues: Machine tools (lathe, milling, drilling, grinding), welding bays, gas cutting sets, overhead crane (EOT), assembly area, stores/spares racks, hydraulic press, plate bending/rolling machine, heat treatment furnace, paint booth, battery charging area, forklifts, tool cribs
  Unique hazards: Grinding wheel burst, welding fumes/UV, gas cylinder in use, compressed air misuse, crane operation in confined shop, chemical exposure (cutting oil, solvents), noise, hot work near flammables, fall from equipment under repair, stored energy release, inadequate scaffolding

WATER SUPPLY & TREATMENT:
  Visual cues: Pump house, clarifier/thickener, filter house, cooling tower, ETP (effluent treatment), chemical dosing (chlorine, alum, polyelectrolyte), raw water reservoir, overhead tank, pipeline gallery, sludge handling
  Unique hazards: Chlorine gas leak (IDLH 10 ppm), drowning in tanks/reservoir, confined space (clarifier/sump), chemical burns (acid/alkali for pH), pump cavitation, high-pressure pipeline burst, electrical in wet environment, slip/fall on wet surfaces, biological hazards

TRANSPORT & RAILWAY:
  Visual cues: Internal rail tracks, diesel/electric loco, hot metal torpedo ladle on tracks, slag pot car, flat wagons, rail crossings, marshalling yard, rail-mounted cranes, tipping arrangements, point/switch, signal system
  Unique hazards: Train/loco collision with persons, derailment (especially torpedo), hot metal spillage during transport, unauthorized track crossing, shunting accidents, coupling/uncoupling injuries, level crossing violations, signal failure

REFRACTORY & LINING:
  Visual cues: Ladle/converter/tundish with broken/worn lining visible, refractory bricks stacked, gunning machine, brick laying in vessel, castable preparation, tundish drying/preheating, skull removal operation
  Unique hazards: Silica dust exposure (silicosis), confined space inside vessels, fall from vessel edge, hot surface burns, refractory collapse during removal, dust from demolition, crystalline silica (IARC Group 1 carcinogen), material handling (heavy bricks)

OXYGEN PLANT / AIR SEPARATION UNIT:
  Visual cues: Cold box (tall insulated column), LOX/LIN/LAR storage tanks (white/silver cryogenic), vaporizers, compressor house, O2/N2/Ar filling manifold, gas cylinders in bulk, pipeline manifold, safety relief valves venting
  Unique hazards: Oxygen enrichment (fire/explosion risk), cryogenic burns (-183°C LOX), asphyxiation (N2/Ar in confined area), high-pressure systems (200+ bar), compressor lube oil contamination (explosion), cold box hydrocarbon accumulation

CIVIL & CONSTRUCTION:
  Visual cues: Scaffolding, formwork, concrete pouring, excavation/trenching, rebar tying, brick masonry, structural steel erection, tower crane, mobile crane, batching plant, road work
  Unique hazards: Fall from height (scaffolding/edge), excavation collapse, struck-by (falling object/crane load), electrocution (overhead lines), concrete pump hose whip, hot bitumen burns, silica from cutting, formwork collapse

LABORATORY / QC:
  Visual cues: Chemical analysis equipment, spectrometer, sample preparation area, furnaces (muffle), acid hoods/fume cupboards, gas cylinders (carrier gases), sample cutting/polishing machines
  Unique hazards: Chemical exposure (acids, solvents), burns from muffle furnace, compressed gas cylinder, broken glassware cuts, radiation (XRF), electrical equipment in wet lab

═══════════════════════════════════════════════════════
STEP 1 — OBSERVE (silently)
═══════════════════════════════════════════════════════
Before listing any hazard, internally note:
  • Scene type (workshop, storage area, panel room, walkway, etc.)
  • Which SECTION this belongs to (from the guide above)
  • Equipment, structures, surfaces visible
  • People count, what they are doing
  • Materials/substances stored or in use

═══════════════════════════════════════════════════════
STEP 2 — GROUNDING RULES
═══════════════════════════════════════════════════════
Only report hazards ACTUALLY VISIBLE in the image.
When relevant items (cylinders, drums, extinguishers, wires) ARE visible, analyze ALL associated hazards thoroughly.

═══════════════════════════════════════════════════════
VERIFIED REGULATION REFERENCE TABLE
═══════════════════════════════════════════════════════
★★★ CRITICAL: You MUST ONLY cite regulations from this table. ★★★
★★★ Do NOT invent or hallucinate section numbers. ★★★
★★★ If unsure which regulation applies, use the closest match from this table. ★★★

── FACTORIES ACT 1948 (Chapter IV — Safety) ──
  S21  = Fencing of machinery (missing guards on moving parts)
  S22  = Work on or near machinery in motion
  S23  = Employment of young persons on dangerous machines
  S24  = Striking gear and devices for cutting off power
  S25  = Self-acting machines
  S26  = Casing of new machinery
  S28  = Hoists and lifts
  S29  = Lifting machines, chains, ropes, lifting tackles
  S30  = Revolving machinery
  S31  = Pressure plant
  S32  = Floors, stairs, means of access (safe access, trip/slip/fall)
  S33  = Pits, sumps, openings in floors, etc.
  S34  = Excessive weights
  S35  = Protection of eyes
  S36  = Precautions against dangerous fumes/gases (CONFINED SPACE ONLY)
  S36A = Portable electric light in confined space (24V limit)
  S37  = Explosive or inflammable dust, gas, etc. (flammables, No Smoking zones)
  S38  = Precautions in case of fire (extinguishers, exits, fire routes)
  S39  = Power to require specifications of defective parts or tests of stability
  S40  = Safety of buildings and machinery (structural safety)
  S40A = Maintenance of buildings
  S40B = Safety Officers appointment
  S41B = Compulsory disclosure of hazard information to workers
  S41C = Specific responsibility of occupier — PPE provision
  S45  = First-aid appliances (first-aid box requirement)
  S87  = Penalty for using false certificate of fitness

── FACTORIES ACT 1948 (Chapter III — Health) ──
  S11  = Cleanliness
  S12  = Disposal of wastes and effluents
  S13  = Ventilation and temperature
  S14  = Dust and fume
  S15  = Artificial humidification
  S16  = Overcrowding
  S17  = Lighting
  S18  = Drinking water
  S19  = Latrines and urinals (DO NOT cite for safety violations)
  S20  = Spittoons

── FACTORIES ACT 1948 (Chapter IV-A — Hazardous Processes) ──
  S41A = Constitution of Site Appraisal Committee
  S41B = Compulsory disclosure of information
  S41C = Specific responsibility of occupier (health/safety/PPE)
  S41E = Emergency standards / Disaster management plan
  S41F = Permissible limits of exposure to chemicals
  S41G = Workers participation in safety management
  S41H = Right of workers to warn about imminent danger

── GAS CYLINDER RULES ──
  SMPV Rules 2016, Rule 10 = Valve protection (caps on idle cylinders)
  SMPV Rules 2016, Rule 14 = Storage requirements (upright, chained, segregated, ventilated)
  Gas Cylinder Rules 2004, Rule 14 = Transport and handling
  IS 4379:1981 = Gas cylinder identification (colour codes)
  IS 7312:1987 = Storage of gas cylinders

── ELECTRICAL SAFETY ──
  CEA (Measures relating to Safety & Electricity Supply) Regulations 2010:
    Reg 36 = Earthing (all equipment must be earthed)
    Reg 44 = Protection against excess current
    Reg 45 = Insulation and protection of conductors
    Reg 46 = Protection against electric shock
    Reg 47 = Accessibility of bare conductors
    Reg 50 = Distinction of different circuits
    Reg 53 = Inspection and testing
    Reg 67 = Connection with earth (neutral earthing)
  Indian Electricity Rules 1956:
    Rule 29 = Overhead lines clearance
    Rule 44 = Earthing
    Rule 45 = Protection against lightning
    Rule 46 = Precautions against leakage
    Rule 50 = Danger notice on HV equipment
    Rule 51 = Handling of electric supply lines
    Rule 61 = Work near live conductors
    Rule 64 = Precautions for portable apparatus

── FIRE SAFETY ──
  IS 2190:2010 = Fire extinguisher selection, installation, maintenance
  IS 15683:2006 = Fire exit signs
  NBC 2016 Part 4 = Fire protection requirements
  FA 1948 S37 = Prevention — explosive/inflammable materials
  FA 1948 S38 = Fire precautions (exits, alarms, drills)
  Petroleum Rules 2002 = Storage of petroleum products

── PPE STANDARDS ──
  IS 2925:1984 = Industrial safety helmets
  IS 15298 (Part 2):2011 = Safety footwear
  IS 5983:1980 = Eye protectors (goggles)
  IS 8520:1977 = Face shields
  IS 4770:1991 = Rubber gloves for electrical work
  IS 6994 (Part 1):1973 = Leather safety gloves
  IS 3521:1999 = Industrial safety belts/harness (working at height)
  IS 9167:1979 = Ear protectors
  IS 8523:1977 = Industrial safety face shield
  IS 15748:2007 = Aluminised suit (heat protection)
  FA 1948 S35 = Protection of eyes (employer duty)
  FA 1948 S41C = PPE provision (employer duty)

── WORKING AT HEIGHT ──
  FA 1948 S32 = Safe means of access (employer to provide safe access)
  IS 3521:1999 = Industrial safety belts and harnesses
  IS 3696 (Part 1):1987 = Scaffolds — safety requirements
  IS 4014:1967 = Steel tubular scaffolding
  IS 11057:1984 = Safety nets

── PRESSURE VESSELS & BOILERS ──
  FA 1948 S31 = Pressure plant (joint must be kept in repair)
  SMPV Rules 2016 = Manufacture, storage, use of pressure vessels
  Indian Boiler Regulations 1950 = Boiler operation, testing, certification
  IS 2825:1969 = Code for unfired pressure vessels

── CHEMICAL SAFETY ──
  MSIHC Rules 1989 = Manufacture, Storage & Import of Hazardous Chemicals
  HW(M&TBM) Rules 2016 = Hazardous Waste Management & Transboundary Movement
  FA 1948 S41F = Permissible limits of chemical exposure

── HOUSEKEEPING & ACCESS ──
  FA 1948 S32 = Floors, stairs and means of access
  FA 1948 S33 = Pits, sumps, openings in floors

── STRUCTURAL INTEGRITY / EQUIPMENT CONDITION ──
  FA 1948 S39 = Testing of defective parts/stability
  FA 1948 S40 = Safety of buildings and machinery
  FA 1948 S40A = Maintenance of buildings

── CRANE & LIFTING ──
  FA 1948 S28 = Hoists and lifts
  FA 1948 S29 = Lifting machines, chains, ropes, lifting tackles
  IS 807:2006 = Crane design and manufacture
  IS 13367:1992 = Safe use of cranes
  IS 3177:1999 = Lifting chain slings

── NOISE & ENVIRONMENT ──
  FA 1948 S14 = Dust and fume (workplace air quality)
  IS 9876 (Part 1):1981 = Permissible noise exposure
  Noise Pollution Rules 2000 = Ambient noise limits

── MINING (only if mine/quarry scene) ──
  Mines Act 1952, S18 = Mining safety supervision
  Mines Rules 1955 = Mining safety requirements
  DGMS Circular = Technical directives
{{KB_CONTEXT}}
═══════════════════════════════════════════════════════
HAZARD CHECKLIST — Check EVERY applicable category
═══════════════════════════════════════════════════════

── GAS CYLINDER STORAGE (if any cylinders visible) ──
  • Cylinders not chained/secured → SMPV Rules 2016, Rule 14
  • Full and empty not segregated → SMPV Rules 2016, Rule 14
  • Oxidizers and fuel gases not separated by 6m/firewall → IS 7312:1987
  • Valve protection caps missing → SMPV Rules 2016, Rule 10
  • Cylinders not stored upright → SMPV Rules 2016, Rule 14
  • Contents not identified/labelled → IS 4379:1981
  • No ventilated storage area → SMPV Rules 2016, Rule 14
  • Combustibles stored near cylinders → FA 1948 S37
  • No "No Smoking" signage → FA 1948 S37
  • Exposed to heat sources → SMPV Rules 2016, Rule 14

── FIRE SAFETY (if extinguishers, drums, flammables visible) ──
  • Extinguishers obstructed/inaccessible → IS 2190:2010
  • Access path blocked by materials → FA 1948 S38
  • Flammable materials near ignition sources → FA 1948 S37
  • No fire exit/emergency route signage → FA 1948 S38
  • Missing/expired extinguisher inspection tags → IS 2190:2010
  • Wrong extinguisher type for hazard class → IS 2190:2010

── HOUSEKEEPING & ACCESS ──
  • Trip hazards (hoses, cables, materials on floor) → FA 1948 S32
  • Congested storage blocking emergency access → FA 1948 S32
  • Spills creating slip hazard → FA 1948 S32
  • Walkways/aisles obstructed → FA 1948 S32
  • Open pits/floor holes without covers/barriers → FA 1948 S33

── ELECTRICAL (if panels, wires, equipment visible) ──
  • Exposed/damaged wiring → CEA Regulations 2010, Reg 45
  • Open/uncovered electrical panels → CEA Regulations 2010, Reg 46
  • Missing DANGER signs on HV apparatus → Indian Electricity Rules 1956, Rule 50
  • Missing insulating mats → IS 4770:1991
  • Inadequate clearance before switchboards → CEA Regulations 2010, Reg 47

── SIGNAGE & LABELLING ──
  • Missing hazard warning signs → FA 1948 S41B
  • No "No Smoking" in hazardous area → FA 1948 S37
  • Unlabelled containers/drums → MSIHC Rules 1989
  • No emergency information posted → FA 1948 S41E

── STORAGE & CHEMICAL ──
  • Incompatible materials stored together → MSIHC Rules 1989
  • Chemicals without secondary containment → MSIHC Rules 1989
  • Drums without proper labelling → MSIHC Rules 1989

── EQUIPMENT / STRUCTURAL INTEGRITY ──
  • Corroded structural elements → FA 1948 S40
  • Damaged equipment condition → FA 1948 S39
  • Missing safety guards on machinery → FA 1948 S21
  • Visible cracks, deformation, or leaks → FA 1948 S39

── WORKER-RELATED (only if workers ACTUALLY visible) ──
  • Missing helmet → IS 2925:1984, FA 1948 S41C
  • Missing safety footwear → IS 15298:2011, FA 1948 S41C
  • Missing eye protection → IS 5983:1980, FA 1948 S35
  • Missing gloves → IS 6994:1973, FA 1948 S41C
  • Worker at height without harness → IS 3521:1999, FA 1948 S32
  • Unsafe body positioning → FA 1948 S22

── LINE OF FIRE (only if workers visible near energy sources) ──
  • Person in path of crane/suspended load → FA 1948 S29
  • Person near moving machinery → FA 1948 S22
  • Person near hot metal/slag → FA 1948 S41C
  • Person in vehicle swing radius → FA 1948 S32
  • Person below work at height → FA 1948 S33
  • Person near pressurized lines → FA 1948 S31

── SECTION-SPECIFIC LINE OF FIRE (check based on detected section) ──
  BF: Person in torpedo ladle path, person below skip car, person near tapping hole splash radius, person in cast house runner path
  SMS: Person in converter blow zone, person near ladle tilting radius, person in strand withdrawal zone, person below charging crane with scrap
  COKE OVEN: Person in pusher ram path, person on battery top near open charging hole, person in coke guide car movement zone, person near quenching car steam
  ROLLING MILL: Person in roller table run, person in cobble ejection path, person near flying shear, person in coiler wrap zone
  POWER PLANT: Person near steam header flange, person below coal conveyor, person in turbine oil spray zone
  GAS NETWORK: Person downstream of bleeder without CO detector, person near valve under pressure

── LOF ZONE (mandatory for type "Line of Fire") ──
  For EVERY hazard with type "Line of Fire", include "lofZone" in the JSON.
  lofZone defines the DANGER PATH from energy source to person:
    "lofZone": {"x1": <source x 0-1>, "y1": <source y 0-1>, "x2": <person x 0-1>, "y2": <person y 0-1>}
  (x1,y1) = center of energy source/hazard origin; (x2,y2) = center of exposed person.
  This draws a shaded corridor showing the line of fire path on the image.

═══════════════════════════════════════════════════════
GAS CYLINDER COLOUR CODES (IS 4379:1981)
═══════════════════════════════════════════════════════
  Oxygen = Black body / White neck
  Acetylene = Maroon
  Nitrogen = Grey body / Black neck
  Hydrogen = Red
  Argon = Peacock Blue
  CO₂ = Aluminium/Silver
  LPG = Dark Red/Silver
  Chlorine = Golden Yellow

═══════════════════════════════════════════════════════
PIPE vs WIRE DIFFERENTIATION
═══════════════════════════════════════════════════════
  Brackets/clamps/pipe supports → PIPE (IS 2379:1963 colour codes)
  PVC insulation/cable trays/conduit/junction boxes → WIRE/CABLE

═══════════════════════════════════════════════════════
CRITICAL RULES — ACCURACY OVER VOLUME
═══════════════════════════════════════════════════════
1. MAXIMUM 7 hazards. Quality over quantity. Each must have visual proof.
2. ONLY cite regulations from the VERIFIED TABLE above. NEVER invent section numbers.
3. Working at height → FA 1948 S32. Confined space → FA 1948 S36. Never confuse these.
4. S19 is "Latrines & urinals" — NEVER cite it for safety violations.
5. S21 = machinery fencing ONLY. NEVER for gas cylinders, access, or PPE.
6. IS 14489:2018 is an AUDIT standard — do NOT cite it for individual hazards.
7. Every corrective action MUST start with an action verb and be SPECIFIC.
8. Bounding box values: normalized 0.0–1.0.
9. If image is too blurry/dark, return: overallRisk "LOW", confidence <30, and 0-1 hazards.
10. NEVER report "missing PPE" if no workers are visible in the image.
11. NEVER report "Line of Fire" if no persons are visible near the energy source.
12. If a scene looks generally safe/well-maintained, acknowledge it — don't force-find problems.

═══════════════════════════════════════════════════════
COMMON FALSE POSITIVE TRAPS — AVOID THESE
═══════════════════════════════════════════════════════
• Reporting "no safety signage visible" when signage may exist outside camera frame
• Reporting "missing fire extinguisher" when it may be just out of view
• Reporting PPE violations when workers are too far/small to assess PPE
• Citing S21 (machinery fencing) for non-machinery issues
• Reporting "inadequate lighting" from a photo taken with flash/poor camera
• Assuming gas cylinders are "not separated" when you can't see the full storage area
• Reporting housekeeping issues in areas that are actually work-in-progress

═══════════════════════════════════════════════════════
SECTION-SPECIFIC HAZARD PRIORITIES
═══════════════════════════════════════════════════════
Once you identify the section, apply these PRIORITY checks (but ONLY report what is VISIBLE):

BLAST FURNACE → Check: CO gas exposure, hot metal splash guards, cast house ventilation, tuyere area barricading, torpedo ladle track clearance, burden material fall, gas leak at bleeders, skip car movement
SMS/BOF → Check: Converter mouth clearance, lance integrity, ladle condition, strand breakout indicators, crane with molten metal, scrap moisture, slag pot overflow, emergency tilt mechanism
COKE OVEN → Check: Door emission, battery top fall protection, ascension pipe condition, pushing emission, quenching safety, by-product chemical exposure, coal dust control, coke guide alignment
SINTER PLANT → Check: Hot sinter fall protection, ignition hood clearance, ESP fire indicators, dust mask usage, conveyor guards, heat stress indicators
ROLLING MILLS → Check: Cobble guards, reheating furnace gas system, roller table nip points, flying shear barricade, pickling line PPE, H2 safety in annealing, cooling bed side guards, crane hot coil handling
POWER PLANT → Check: Steam leak indicators, boiler access, coal dust accumulation, ash handling confined space, switchyard clearance, turbine area oil leaks, cable gallery fire protection
ELECTRICAL → Check: Arc flash boundaries, LOTO compliance, danger boards, earthing, insulating mats, cable condition, panel door condition, HT clearance, battery room ventilation
GAS NETWORK → Check: CO detector presence, gas leak indicators (dead birds/vegetation), pipeline colour code, valve station access, purging procedure display, emergency isolation knowledge, wind sock/direction
MAINTENANCE → Check: Grinding guards, welding screens, gas cylinder security, crane operation, chemical storage, housekeeping, fall protection for equipment repair, stored energy isolation

═══════════════════════════════════════════════════════
{{WSA_CAUSES}}

═══════════════════════════════════════════════════════
OUTPUT FORMAT — valid JSON ONLY, no markdown, no preamble
═══════════════════════════════════════════════════════
{
  "overallRisk": "{{SEVERITIES}}",
  "riskScore": 0-100,
  "confidence": 0-100 (reflects YOUR certainty based on image clarity + evidence strength),
  "people": <integer count of ACTUALLY VISIBLE persons, 0 if none>,
  "detectedSection": "BLAST FURNACE|SMS|COKE OVEN|SINTER PLANT|ROLLING MILL|POWER PLANT|ELECTRICAL|GAS NETWORK|MATERIAL HANDLING|MAINTENANCE|WATER TREATMENT|TRANSPORT|REFRACTORY|OXYGEN PLANT|CIVIL|LABORATORY|GENERAL",
  "sectionConfidence": 0-100,
  "sectionCues": "brief list of visual cues that led to section identification",
  "summary": "Sentence 1: what is physically visible and which section. Sentence 2: highest-priority concern with SPECIFIC visual evidence. Sentence 3: applicable regulation.",
  "hazards": [
    {
      "name": "max 5 words describing what is VISIBLE",
      "severity": "{{SEVERITIES}}",
      "description": "MUST START WITH 'Visible: [specific object/condition seen].' Then: why dangerous, potential consequence in THIS SECTION.",
      "visualEvidence": "What specific object/condition/person in the image PROVES this hazard exists (1 sentence)",
      "regulation": "MUST be from verified table above e.g. FA 1948 S37",
      "correctiveAction": "starts with action verb; specific measurable steps relevant to this section",
      "type": "{{OBS_TYPES}}",
      "wsaCause": "EXACT wording from the hazard category list below",
      "bbox": {"x": 0.1, "y": 0.1, "w": 0.3, "h": 0.4},
      "lofZone": {"x1": 0.2, "y1": 0.3, "x2": 0.5, "y2": 0.7}
    }
  ],
  "wsa": ["list of WSA causes ACTUALLY applicable — only those with visual evidence"],
  "preventive": ["long-term measure with IS standard from table above — SECTION-SPECIFIC"],
  "ptw_required": "PTW types needed based on VISIBLE work activities or \\"None\\"",
  "nearest_standard": "primary IS standard from verified table",
  "section_specific_risks": ["top 3 section-inherent risks that are contextually relevant to what is VISIBLE"]
}

★ FINAL CHECK: Before outputting, verify EVERY hazard has a "visualEvidence" field that describes something you can actually SEE. Delete any hazard where you wrote generic text like "not visible but typically..." or "commonly found in...".

''';
  }

  /// Parse the AI text response into structured hazard data
  /// ★ v33: Added JSON repair for truncated responses
  static Map<String, dynamic>? _parseHazardResponse(String text) {
    try {
      String jsonStr = text.trim();
      // Remove markdown fences if present
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll(RegExp(r'\n?```$'), '');
      }
      // Extract JSON object
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
      if (jsonMatch != null) jsonStr = jsonMatch.group(0)!;

      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _validateAndReturn(parsed);
    } catch (e) {
      print('GeminiDirectVision: JSON parse error: $e');
      print('GeminiDirectVision: Raw text: ${text.substring(0, text.length.clamp(0, 300))}');

      // ★ v33: Attempt to repair truncated JSON responses
      final repaired = _repairTruncatedJson(text);
      if (repaired != null) {
        print('GeminiDirectVision: ✓ Repaired truncated JSON — salvaged ${(repaired['hazards'] as List?)?.length ?? 0} hazards');
        return repaired;
      }
      return null;
    }
  }

  /// Validate and add metadata to parsed response
  static Map<String, dynamic> _validateAndReturn(Map<String, dynamic> parsed) {
    if (parsed['hazards'] == null) parsed['hazards'] = [];
    if (parsed['overallRisk'] == null) parsed['overallRisk'] = 'UNKNOWN';
    if (parsed['riskScore'] == null) parsed['riskScore'] = 0;
    if (parsed['confidence'] == null) parsed['confidence'] = 0;
    if (parsed['people'] == null) parsed['people'] = 0;
    if (parsed['summary'] == null) parsed['summary'] = 'Analysis complete.';
    if (parsed['detectedSection'] == null) parsed['detectedSection'] = 'GENERAL';
    if (parsed['sectionConfidence'] == null) parsed['sectionConfidence'] = 0;
    if (parsed['sectionCues'] == null) parsed['sectionCues'] = '';
    if (parsed['section_specific_risks'] == null) parsed['section_specific_risks'] = [];

    // Add metadata
    parsed['_source'] = 'gemini_direct';
    parsed['_isOnline'] = true;

    return parsed;
  }

  /// ★ v33: Repair truncated JSON — salvage partial responses
  /// When maxOutputTokens cuts off mid-response, we still have valuable data
  static Map<String, dynamic>? _repairTruncatedJson(String text) {
    try {
      String jsonStr = text.trim();
      // Remove markdown fences
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll(RegExp(r'\n?```$'), '');
      }
      // Must start with {
      final startIdx = jsonStr.indexOf('{');
      if (startIdx < 0) return null;
      jsonStr = jsonStr.substring(startIdx);

      // Strategy 1: Try to close open arrays and objects progressively
      // Find the "hazards" array and try to close it
      final hazardsStart = jsonStr.indexOf('"hazards"');
      if (hazardsStart < 0) {
        // No hazards array found — try to just close the root object
        // Extract top-level fields we can find
        return _extractTopLevelFields(jsonStr);
      }

      // Try closing arrays/objects from the end
      String attempt = jsonStr;
      // Count unclosed brackets
      int braces = 0, brackets = 0;
      bool inString = false;
      bool escaped = false;
      for (int i = 0; i < attempt.length; i++) {
        final c = attempt[i];
        if (escaped) { escaped = false; continue; }
        if (c == '\\') { escaped = true; continue; }
        if (c == '"') { inString = !inString; continue; }
        if (inString) continue;
        if (c == '{') braces++;
        if (c == '}') braces--;
        if (c == '[') brackets++;
        if (c == ']') brackets--;
      }

      // Trim back to last complete object in the hazards array
      // Find the last complete "}" that's part of a hazard object
      int lastCompleteHazard = attempt.lastIndexOf('},');
      if (lastCompleteHazard < 0) lastCompleteHazard = attempt.lastIndexOf('}]');
      if (lastCompleteHazard < 0) {
        // Try to find any complete hazard object
        lastCompleteHazard = attempt.lastIndexOf('}');
      }

      if (lastCompleteHazard > hazardsStart) {
        // Cut after the last complete hazard object and close everything
        attempt = attempt.substring(0, lastCompleteHazard + 1);
        // Close: ], then any remaining }
        attempt += ']';
        // Close remaining braces
        int remainingBraces = 0;
        bool inStr = false;
        bool esc = false;
        for (int i = 0; i < attempt.length; i++) {
          final c = attempt[i];
          if (esc) { esc = false; continue; }
          if (c == '\\') { esc = true; continue; }
          if (c == '"') { inStr = !inStr; continue; }
          if (inStr) continue;
          if (c == '{') remainingBraces++;
          if (c == '}') remainingBraces--;
        }
        for (int i = 0; i < remainingBraces; i++) {
          attempt += '}';
        }

        try {
          final parsed = jsonDecode(attempt) as Map<String, dynamic>;
          if (parsed['hazards'] != null && (parsed['hazards'] as List).isNotEmpty) {
            return _validateAndReturn(parsed);
          }
        } catch (_) {}
      }

      // Strategy 2: Extract fields with regex
      return _extractTopLevelFields(jsonStr);
    } catch (_) {
      return null;
    }
  }

  /// Last-resort field extraction from partial JSON
  static Map<String, dynamic>? _extractTopLevelFields(String json) {
    try {
      final riskMatch = RegExp(r'"overallRisk"\s*:\s*"(\w+)"').firstMatch(json);
      final scoreMatch = RegExp(r'"riskScore"\s*:\s*(\d+)').firstMatch(json);
      final confMatch = RegExp(r'"confidence"\s*:\s*(\d+)').firstMatch(json);
      final peopleMatch = RegExp(r'"people"\s*:\s*(\d+)').firstMatch(json);
      final summaryMatch = RegExp(r'"summary"\s*:\s*"([^"]+)"').firstMatch(json);

      if (riskMatch == null && scoreMatch == null) return null;

      // Try to extract complete hazard objects
      final hazardObjects = <Map<String, dynamic>>[];
      final hazardRegex = RegExp(r'\{\s*"name"\s*:\s*"[^"]+?"[^}]*?"correctiveAction"\s*:\s*"[^"]+?"[^}]*?\}', dotAll: true);
      for (final m in hazardRegex.allMatches(json)) {
        try {
          final h = jsonDecode(m.group(0)!) as Map<String, dynamic>;
          hazardObjects.add(h);
        } catch (_) {}
      }

      if (hazardObjects.isEmpty && riskMatch == null) return null;

      final result = <String, dynamic>{
        'overallRisk': riskMatch?.group(1) ?? 'UNKNOWN',
        'riskScore': int.tryParse(scoreMatch?.group(1) ?? '0') ?? 0,
        'confidence': int.tryParse(confMatch?.group(1) ?? '0') ?? 0,
        'people': int.tryParse(peopleMatch?.group(1) ?? '0') ?? 0,
        'summary': summaryMatch?.group(1) ?? 'Analysis complete (partial response recovered).',
        'hazards': hazardObjects,
        '_source': 'gemini_direct_repaired',
        '_isOnline': true,
      };

      return result;
    } catch (_) {
      return null;
    }
  }
}
