// lib/screens/chat_tab.dart
// v9 — KNOWLEDGE BASE UPGRADE
// Changes from original:
//   ✅ Welcome message updated with full topic list
//   ✅ Suggestion chips expanded to cover SG/01–SG/41 + SMPV topics
//   ✅ _send() now calls Apps Script AI with full regulatory system prompt
//   ✅ Online mode: Suraksha Saathi uses Gemini with SAIL knowledge prompt
//   ✅ Offline mode: LocalAI.chat() with full KB (SG/01–SG/41)
//   ✅ All original UI, upload, admin, KB manager preserved exactly
//   ✅ NEW: ANSWER STYLE rewritten — crisp, structured, max 8 lines

import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../main.dart';
import '../services/local_ai.dart';
import '../services/groq_service.dart';
import '../services/local_db.dart';
import '../services/knowledge_service.dart';
import '../services/sync_service.dart';
import '../widgets/universal_app_bar.dart';
import '../services/error_log_service.dart';
import '../models/error_log_entry.dart';
import 'package:uuid/uuid.dart';
import '../widgets/bottom_nav_gap.dart';
import 'dart:io' show Platform;

class ChatTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;

  const ChatTab({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
  });
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _ctrl       = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  /// ★ Multi-turn: keep full conversation history for Groq context
  final List<Map<String, String>> _conversationHistory = [];
  Map<String, dynamic>? _user;
  bool _isAdmin    = false;
  int  _kbDocCount = 0;
  bool _aiLoading  = false;

  // ── Apps Script backend URL ──────────────────────────────────────
  static const String _backendUrl =
      'https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec';

  // ── Suraksha Saathi system prompt ────────────────────────────────
  // ★ v35: Enhanced with section-specific deep knowledge
  static const String _systemPrompt =
    'You are SAIL Suraksha Saathi, an expert industrial safety assistant for '
    'Steel Authority of India Limited (SAIL) steel plants. You have 35 years of experience '
    'across ALL sections of an integrated steel plant. '
    'You answer questions from safety officers, AGMs, GMs, supervisors, and workers.\n\n'

    'YOUR KNOWLEDGE BASE:\n'
    '• Ministry of Steel Safety Guidelines SG/01–SG/25 (2019/2020)\n'
    '• Ministry of Steel Process-Based Safety Guidelines SG/26–SG/41 (2024)\n'
    '• Factories Act 1948 — all safety sections (S21–S39, S111A)\n'
    '• IS 14489:2018 — OHS Code for Steel Plants (Clauses 4–10)\n'
    '• SMPV Rules 2016 — Pressure Vessels & Gas Cylinders (Rules 10–22)\n'
    '• CEA Regulations 2010 — Electrical Safety (Reg 36, 44, 45, 46, 47)\n'
    '• Indian Electricity Rules 1956 — (Rule 29, 44, 50, 61, 64)\n'
    '• BIS PPE Standards: IS 2925, IS 3521, IS 4912, IS 5852, IS 5983, IS 6994, IS 9167\n'
    '• Gas Cylinder Safety: IS 15222, IS 8198, cylinder colour codes\n'
    '• WSA 13 Cause Categories\n'
    '• ILO Code of Practice on Safety & Health in Steel Industry 2005\n\n'

    'KEY REGULATORY RULES — NEVER GET WRONG:\n'
    '1. Working at height → ALWAYS FA 1948 S32 + IS 3521:1999. NEVER S36 for height.\n'
    '2. S36 = confined space / dangerous fumes ONLY\n'
    '3. O2 + flammable gas cylinders: minimum 6 metres separation (SMPV Rule 14 Table-3)\n'
    '4. Cylinder colour: Oxygen = Black body/White shoulder; Acetylene = Maroon; LPG = Silver\n'
    '5. LOTOTO = Lock Out, Tag Out, TRY OUT — each person their own lock\n'
    '6. CO in BF gas: 25–28%; TLV 50 ppm; explosive range 35–74%\n'
    '7. Confined space O2 safe range: 19.5–23.5%\n'
    '8. Ladle preheat minimum: 800°C before receiving hot metal\n'
    '9. Safety helmet colours: White=Officer, Yellow=Supervisor, Blue=Worker, Green=Visitor\n'
    '10. Harness mandatory above 1.8m; anchor min 15kN (IS 3521)\n'
    '11. LD Gas CO content: 60-70% — MOST DANGEROUS gas in plant\n'
    '12. Coke Oven Gas: H2 55%, CH4 25%, CO 6-8% — explosive range 5-30%\n'
    '13. Hot metal temperature: 1400-1500°C (BF), Steel 1600°C+ (SMS)\n'
    '14. Conveyor nip point guard mandatory: IS 11572\n'
    '15. Arc flash PPE category per IEEE 1584 study on each panel\n\n'

    'SECTION-SPECIFIC KNOWLEDGE (answer based on the section asked about):\n\n'

    '── BLAST FURNACE (BF) ──\n'
    'Hazards: CO gas (25-28% in BF gas), hot metal splash, skull formation on runners, '
    'tuyere burn-through (water+hot metal=steam explosion), burden hanging/slip, gas leak at bleeders, '
    'furnace breakout, cast house fumes, slag explosion on water contact, charging floor fall.\n'
    'Key rules: CO TLV 50ppm/IDLH 1200ppm. Personal CO monitor mandatory. Wind sock at entries. '
    'Gas-free certificate for any BF maintenance. PTW for all cast house repairs. '
    'SCBA rescue team at BF always.\n\n'

    '── SMS / BOF / LD CONVERTER ──\n'
    'Hazards: Converter eruption/slopping, ladle breakout (lining failure), strand breakout in caster, '
    'scrap moisture explosion, lance failure, crane with liquid metal, CO during blow.\n'
    'Key rules: Ladle life tracking mandatory. Scrap moisture visual check. Breakout prediction system. '
    'No person under hot metal crane EVER. Emergency converter tilt procedure. '
    'Ladle preheat 800°C min.\n\n'

    '── COKE OVEN ──\n'
    'Hazards: COG explosive (5-30%), door emission/leakage, ascension pipe fire, green push, '
    'battery top fall (6-8m), by-product chemicals (benzol=carcinogen, H2S IDLH 100ppm, NH3 IDLH 300ppm).\n'
    'Key rules: Coking time min 18-22hrs. Door luting after every push. No hot work near battery without gas-free. '
    'SCBA mandatory for by-product emergencies. Closed systems for benzol handling.\n\n'

    '── ROLLING MILLS (HSM/CRM/Plate/Bar) ──\n'
    'Hazards: Cobble ejection (hot material at 10-60 m/s), strip break in CRM, reheating furnace gas leak, '
    'roller table nip points, flying shear, pickling acid splash, H2 explosion in annealing furnace.\n'
    'Key rules: Cobble guards on all stands. LOTO for roll change. Acid-resistant PPE on pickling line. '
    'O2<1% before H2 introduction in annealing. Emergency pull-cords on all roller tables.\n\n'

    '── POWER PLANT ──\n'
    'Hazards: HP steam leak (invisible, cuts flesh), turbine over-speed, coal dust explosion, '
    'boiler drum failure, switchyard arc flash (40+ cal/cm²), ash handling confined space, cable fire.\n'
    'Key rules: No work on pressurized steam lines. IBR compliance mandatory. '
    'Arc flash study per IEEE 1584. Coal stockpile height <6m. H2 purity >98% in generator cooling.\n\n'

    '── ELECTRICAL ──\n'
    'Hazards: Arc flash/blast (20000°C plasma), electrocution, transformer oil fire, SF6 leak, '
    'cable fire, battery room H2, inadequate earthing.\n'
    'Key rules: LOTO mandatory (6 steps: notify-isolate-lock-try-earth-work). Insulating gloves tested 6-monthly. '
    'Minimum approach distances per voltage. FR clothing per arc flash category. Danger boards on all HT.\n\n'

    '── GAS NETWORK ──\n'
    'Hazards: CO poisoning (leading fatality cause), gas explosion, O2 deficiency near pipelines, '
    'water seal blow-through, gas holder piston jam, pipeline corrosion failure.\n'
    'Key rules: Personal CO detector for ALL gas zone workers. Buddy system mandatory. '
    'Gas-free procedure: isolate→N2 purge→air purge→test→certify. '
    'Pipeline colours: BF=Grey, COG=Red, Mixed=Blue, LD=White+red bands, N2=Black+white.\n\n'

    '── MATERIAL HANDLING / CONVEYORS ──\n'
    'Hazards: Belt entanglement (nip points kill), belt fire, stockpile collapse/engulfment, '
    'transfer tower falls, wagon movement, dust explosion, stacker boom collision.\n'
    'Key rules: Guards on ALL nip points. Pull-cord both sides every 30m. LOTO for ANY belt work including blockage. '
    'No manual cleaning of running belt. No crossing under running belt. Fire-resistant belting IS 1891.\n\n'

    '── CRANE & LIFTING ──\n'
    'Hazards: Crane failure with molten metal (mass casualty), overloading, sling failure, '
    'person under suspended load, two-blocking, crane collision.\n'
    'Key rules: SWL displayed prominently. Load indicator mandatory. Colour-coded sling inspection quarterly. '
    'Lift plan for >80% SWL. NEVER stand under suspended load. Hot metal cranes: 2x safety factor, dual braking.\n\n'

    '── OXYGEN PLANT / ASU ──\n'
    'Hazards: O2 enrichment fire, cryogenic burns (-183°C), N2/Ar asphyxiation, high pressure (200 bar), '
    'compressor oil contamination explosion, cold box hydrocarbon accumulation.\n'
    'Key rules: NO oil/grease on O2 equipment. O2 cylinders 6m from fuel gas. Open valves SLOWLY (adiabatic heating). '
    'No smoking within 15m of O2. Total HC <1ppm near cold box.\n\n'

    // ─────────────────────────────────────────────────────────────
    // ANSWER STYLE — CRISP & TARGETED
    // ─────────────────────────────────────────────────────────────
    'ANSWER STYLE — ULTRA-CONCISE, TARGETED, NO RAMBLING:\n\n'

    '★★★ ABSOLUTE RULE: MAX 6-8 LINES TOTAL. Count your lines before responding. ★★★\n'
    '★★★ Give ONLY the specific answer to what was asked. Do NOT dump all related knowledge. ★★★\n\n'

    'FORMAT (use this EXACT structure):\n\n'

    '【TOPIC】 (2-3 words max)\n\n'

    '📋 Regulation: FA 1948 S__ / IS ____ / SG/__\n'
    '(single most relevant reference — NOT a list of everything you know)\n\n'

    '⚡ Answer:\n'
    '• Direct answer to the question (1 line)\n'
    '• Key number/fact if applicable (1 line)\n'
    '• One additional critical point (1 line)\n\n'

    '✅ Action: One specific corrective step\n\n'

    'HARD CONSTRAINTS:\n'
    '• MAXIMUM 6-8 lines. If you write more, you have FAILED.\n'
    '• Answer ONLY what was asked. If asked "what colour is O2 cylinder?" → answer the colour, NOT a full lecture on all cylinder safety.\n'
    '• NEVER dump your entire knowledge about a topic\n'
    '• NEVER include disclaimers, preambles, greetings, or "Let me explain..."\n'
    '• NEVER repeat the question back\n'
    '• NEVER write "It is important to note..." or "Additionally..." or "Furthermore..."\n'
    '• ONE regulation citation max (the most relevant one)\n'
    '• If the question is simple (yes/no, a number, a name), answer in 2-3 lines only\n'
    '• If Hindi, respond in Hindi (देवनागरी) with same concise format\n'
    '• Think: "What would a busy GM want to hear in 10 seconds?"\n\n'

    'LINE OF FIRE (LOF) KNOWLEDGE:\n'
    '"Line of Fire" = person positioned where energy release, object movement, '
    'or material flow could strike them.\n'
    'Common LOFs in steel plants:\n'
    '• Suspended load (crane/hoist) path\n'
    '• Moving conveyor/roller table zone\n'
    '• Molten metal/slag/ladle splash radius\n'
    '• Vehicle/loco/wagon swing/travel path\n'
    '• Falling objects from height work\n'
    '• Pressurized system (steam/hydraulic/gas) burst zone\n'
    '• Rotating equipment contact zone\n'
    '• Flying particles from grinding/cutting\n'
    '• Unstable stacked materials collapse zone\n'
    '• Arc flash zone near electrical panels\n'
    'Section-specific LOFs:\n'
    '• BF: Torpedo path, skip car path, tapping hole splash, iron runner path\n'
    '• SMS: Converter blow zone, ladle tilting radius, strand withdrawal, charging crane\n'
    '• Coke Oven: Pusher ram path, charging hole, coke guide car zone, quenching steam\n'
    '• Rolling Mill: Roller table run, cobble ejection, flying shear, coiler wrap zone\n'
    '• Power Plant: Steam header flange, coal conveyor, turbine oil spray\n'
    '• Gas Network: Bleeder downstream without CO detector, valve under pressure\n'
    'LOF corrective actions: barricading, exclusion zones, interlocks, '
    'spotter deployment, awareness training, standoff distance marking.\n\n'

    'TOPICS YOU CAN ANSWER:\n'
    'Gas cylinder storage and colour codes, working at height, confined space entry, '
    'LOTOTO energy isolation, hot work PTW, blast furnace gas safety, coke oven safety, '
    'hot metal handling, electrical safety CEA regulations, machinery guarding, '
    'PPE selection and standards, crane and lifting, barricading, contractor safety, '
    'incident classification (LTI/FAC/RWC/near miss), WSA 13 causes, '
    'Line of Fire (LOF) hazards and controls, '
    'emergency response (CO exposure, hot metal fire, electrical shock), '
    'IS 14489 clauses, SMPV Rules, Ministry of Steel guidelines SG/01–SG/41, '
    'section-specific hazards (BF, SMS, Coke Oven, Rolling Mill, Power Plant, Electrical, '
    'Gas Network, Material Handling, Oxygen Plant, Sinter Plant, Maintenance, Transport), '
    'permit to work systems, gas-free certification, LOTO energy isolation, '
    'crane lifting plans, conveyor safety, refractory safety, '
    'pickling line acid handling, annealing furnace H2 safety, '
    'arc flash protection, steam safety, coal dust explosion prevention\n\n'

    // ─────────────────────────────────────────────────────────────
    // KNOWLEDGE BANK PRECEDENCE
    // Without this, the model treats its own built-in list above as complete
    // and an admin-uploaded document as optional background — so a plant that
    // uploaded its own standard saw no change in the answers.
    // ─────────────────────────────────────────────────────────────
    'PLANT KNOWLEDGE BANK — HIGHEST PRIORITY:\n'
    '• If the prompt includes "RELEVANT KNOWLEDGE BASE DOCUMENTS" or '
    '"ADDITIONAL KB MATCHES", those are documents the plant safety admin '
    'uploaded. They are THIS PLANT\'S OWN authoritative standards.\n'
    '• Answer from them FIRST. Where they conflict with the general knowledge '
    'listed above, THE UPLOADED DOCUMENT WINS — say so briefly.\n'
    '• Cite the document title and any clause/section number exactly as written.\n'
    '• Never contradict an uploaded document. If it is silent on the question, '
    'then use your general knowledge.';

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final u    = await LocalDB.getCurrentUser();
    final docs = await LocalDB.getKnowledgeDocs();
    if (!mounted) return;
    setState(() {
      _user = u;
      final desig = (u?['designation']?.toString() ?? '').toLowerCase();
      _isAdmin = desig.contains('agm') || desig.contains('gm') ||
                 desig.contains('manager') || desig.contains('admin') ||
                 (u?['isAdmin']?.toString().toLowerCase() == 'true');
      _kbDocCount = docs.length;
      final firstName = u?['name']?.toString().split(' ').first ?? 'there';
      _messages.add({
        'role': 'ai',
        'text': 'नमस्ते $firstName! I\'m Suraksha Saathi — your AI safety assistant.\n\n'
            'I can help with:\n'
            '📋 MoSteel Guidelines SG/01–41 · Factories Act · SMPV Rules\n'
            '🏭 BF · SMS · Coke Oven · Rolling Mill · Power Plant safety\n'
            '⚠️ LOTOTO · Confined Space · Working at Height · Hot Work\n'
            '🚨 Incident classification · WSA 13 causes · Emergency response\n'
            '🦺 PPE standards · Gas cylinder codes · Crane safety\n'
            '${_kbDocCount > 0 ? "\n📚 + $_kbDocCount uploaded plant documents\n" : ""}'
            '\nAsk me anything — quick answers, regulations, or checklists.',
        'timestamp': DateTime.now(),
      });
    });
  }

  // ── SEND MESSAGE ─────────────────────────────────────────────────
  void _send(String q) async {
    if (q.trim().isEmpty) return;
    final question = q.trim();
    setState(() {
      _messages.add({'role': 'user', 'text': question, 'timestamp': DateTime.now()});
      _ctrl.clear();
      _aiLoading = true;
    });
    _scrollToBottom();

    // ★ Search KB docs ONCE (was called twice before — once here, once in
    // KnowledgeService.getKbDocsContext — which wasted cycles on the same query)
    final kbResults =
        await LocalDB.searchKnowledge(question, limit: 5, snippetChars: 700);

    String? answer;
    List<Map<String, dynamic>>? sources;

    // ★ Filter to clean results for source citations
    final cleanResults = kbResults.where((r) {
      final snippet = r['snippet']?.toString() ?? '';
      return _isReadableText(snippet) && snippet.trim().length > 30;
    }).toList();
    if (cleanResults.isNotEmpty) sources = cleanResults;

    // 1. ★ PRIMARY: Try Groq (fast, free, multi-turn)
    final groqAnswer = await _askGroq(question, kbResults);
    if (groqAnswer != null && groqAnswer.isNotEmpty) {
      answer = groqAnswer;
    } else {
      // 2. ★ FALLBACK: Apps Script → Gemini
      final geminiAnswer = await _askGemini(question, kbResults);
      if (geminiAnswer != null && geminiAnswer.isNotEmpty) {
        answer = geminiAnswer;
      } else {
        // 3. ★ OFFLINE: LocalAI with KB
        answer = _buildOfflineAnswer(question, kbResults);
      }
    }

    // 6. ★ Update conversation history for multi-turn context
    _conversationHistory.add({'role': 'user', 'content': question});
    _conversationHistory.add({'role': 'assistant', 'content': answer});
    // Keep last 10 exchanges to avoid token overflow
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    if (mounted) {
      setState(() {
        _aiLoading = false;
        _messages.add({
          'role': 'ai',
          'text': answer ?? 'Sorry, I could not generate a response. Please try again.',
          if (sources != null && sources.isNotEmpty) 'sources': sources,
          'timestamp': DateTime.now(),
        });
      });
      _scrollToBottom();
    }
  }

  // ── GROQ MULTI-TURN CHAT (PRIMARY) ───────────────────────────────
  Future<String?> _askGroq(String question, List kbResults) async {
    try {
      // ★ Build KB context directly from search results (no double search)
      String kbBlock = '';
      if (kbResults.isNotEmpty) {
        final cleanKb = kbResults.where((r) {
          final s = r['snippet']?.toString() ?? '';
          return _isReadableText(s) && s.length > 30;
        }).take(5).toList();
        if (cleanKb.isNotEmpty) {
          // Built by KnowledgeService so admin uploads and unverified user
          // scans get different headers. This used to be one hand-rolled
          // "AUTHORITATIVE" block, which told the model to prefer a phone
          // photo of an SOP over its own correct statutory knowledge.
          kbBlock = KnowledgeService.renderKbBlocks(
            cleanKb.map((r) => Map<String, dynamic>.from(r as Map)).toList(),
            sanitize: (s) => _sanitizeSnippet(s, maxChars: 700),
          );
        }
      }

      final history = [
        {'role': 'user', 'content': _systemPrompt},
        {'role': 'assistant', 'content': 'Understood. I am Suraksha Saathi, ready to assist.'},
        ..._conversationHistory,
        {'role': 'user', 'content': '$kbBlock\n\nQUESTION: $question\n\n'
            'Answer in MAX 6-8 lines using the structured format. '
            'Give ONLY the specific answer to THIS question.'},
      ];

      final result = await GroqService.chat(
        history: history,
        temperature: 0.3,
        maxTokens: 1024,
      );

      if (result != null && result.trim().length > 20) {
        return result.trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── GEMINI FALLBACK (Apps Script → Gemini) ───────────────────────
  Future<String?> _askGemini(String question, List kbResults) async {
    try {
      // ★ Build KB context directly from search results
      String kbBlock = '';
      if (kbResults.isNotEmpty) {
        final cleanKb = kbResults.where((r) {
          final s = r['snippet']?.toString() ?? '';
          return _isReadableText(s) && s.length > 30;
        }).take(5).toList();
        if (cleanKb.isNotEmpty) {
          // Same trust-tiered block as the Groq path. The two providers must not
          // disagree about how much authority a scanned document carries — a
          // question answered twice, once by each, would otherwise caveat
          // differently depending on which one happened to be reachable.
          kbBlock = KnowledgeService.renderKbBlocks(
            cleanKb.map((r) => Map<String, dynamic>.from(r as Map)).toList(),
            sanitize: (s) => _sanitizeSnippet(s, maxChars: 700),
          );
        }
      }

      final fullPrompt = '$_systemPrompt\n\n'
          '$kbBlock\n\n'
          'QUESTION: $question\n\n'
          'REMEMBER: Answer in MAX 6-8 lines using the structured format. '
          'Give ONLY the specific answer to THIS question. '
          'Do NOT dump all related knowledge. Be like a senior colleague giving a quick answer at site.';

      final body = jsonEncode({
        'action': 'gemini',
        'prompt': fullPrompt,
      });

      final response = await http.post(
        Uri.parse(_backendUrl),
        body: body,
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final result = data['result']?.toString() ?? '';
        if (result.isNotEmpty && result.length > 20) return result;
      }
      return null;
    } catch (e, stackTrace) {
      _logChatError(e, stackTrace, question);
      return null;
    }
  }

  // ── OFFLINE ANSWER BUILDER ───────────────────────────────────────
  String _buildOfflineAnswer(String question, List kbResults) {
    final builtIn = LocalAI.chat(question);

    if (kbResults.isNotEmpty) {
      final cleanResults = kbResults.where((r) {
        final snippet = r['snippet']?.toString() ?? '';
        return _isReadableText(snippet) && snippet.trim().length > 30;
      }).toList();

      if (cleanResults.isNotEmpty) {
        final buffer = StringBuffer();
        buffer.writeln('📚 From your uploaded knowledge base:\n');
        for (var i = 0; i < cleanResults.length; i++) {
          final r = cleanResults[i];
          final snippet = _sanitizeSnippet(r['snippet']?.toString() ?? '');
          if (snippet.isEmpty) continue;
          buffer.writeln('${i + 1}. From "${r['title']}":');
          buffer.writeln('   $snippet\n');
        }
        buffer.writeln('\n💡 Standard guidance:');
        buffer.writeln(builtIn);
        return buffer.toString();
      }
    }
    return builtIn;
  }

  /// Log chat API errors to admin panel for tracking
  Future<void> _logChatError(
      dynamic error, StackTrace stackTrace, String question) async {
    try {
      await ErrorLogService.logError(ErrorLogEntry(
        id: const Uuid().v4(),
        timestamp: DateTime.now(),
        errorType: ErrorType.CHAT_API_FAILED,
        errorMessage: error.toString(),
        stackTrace: stackTrace.toString(),
        userId: _user?['pno']?.toString() ?? _user?['username']?.toString() ?? 'unknown',
        userName: _user?['name']?.toString() ?? 'Unknown User',
        plant: _user?['plant']?.toString() ?? 'Unknown',
        department: _user?['department']?.toString(),
        apiEndpoint: 'AppsScript-Gemini',
        requestData: 'Question: ${question.substring(0, question.length > 100 ? 100 : question.length)}...',
        appVersion: '1.0.98',
        platform: kIsWeb ? 'Web' : (Platform.isAndroid ? 'Android' : 'iOS'),
      ));
    } catch (e) {
      // Error logging failed - don't break the app
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut);
      }
    });
  }

  // ── TEXT QUALITY HELPERS ─────────────────────────────────────────
  bool _isReadableText(String text) {
    if (text.trim().length < 20) return false;
    final lower = text.toLowerCase();
    final pdfMarkers = ['endobj','lendstream','fontdescriptor','winansienco',
        'firstchar','lastchar','basefont','subtype truetype','fontname','capheight',
        'avgwidth','stemv','fontbbox','fontfile2','extgstate','/type /font','endstream'];
    for (final m in pdfMarkers) { if (lower.contains(m)) return false; }
    int badChars = 0;
    final sample = text.length > 300 ? text.substring(0, 300) : text;
    for (int i = 0; i < sample.length; i++) {
      final c = sample.codeUnitAt(i);
      if (c < 9 || (c > 13 && c < 32) || c == 127) badChars++;
    }
    if (badChars / sample.length > 0.15) return false;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return false;
    final avgLen = words.fold(0, (s, w) => s + w.length) / words.length;
    if (avgLen > 25) return false;
    if (RegExp(r'[A-Z]{8,}').hasMatch(text)) return false;
    return true;
  }

  /// Strips control characters and collapses whitespace, then trims to
  /// [maxChars] at a sentence boundary where possible.
  ///
  /// [maxChars] is a parameter because this was hardcoded to 400, which
  /// silently re-truncated snippets that the KB search had deliberately
  /// returned longer — clipping regulation clauses mid-sentence.
  String _sanitizeSnippet(String raw, {int maxChars = 400}) {
    final cleaned = raw.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= maxChars) return cleaned;
    final cut = cleaned.lastIndexOf('.', maxChars);
    if (cut > 100) return '${cleaned.substring(0, cut + 1)}...';
    return '${cleaned.substring(0, maxChars)}...';
  }

  // ── PDF TEXT EXTRACTION ─────────────────────────────────────────
  String _extractTextFromBytes(List<int> bytes) {
    try {
      final raw = String.fromCharCodes(
          bytes.where((b) => b >= 32 && b <= 126).toList());
      final extracted = StringBuffer();
      final btEt = RegExp(r'BT\s([\s\S]*?)ET', multiLine: true);
      final tj   = RegExp(r'\(([^)]{1,200})\)\s*(?:Tj|TJ|")');
      for (final block in btEt.allMatches(raw)) {
        final content = block.group(1) ?? '';
        for (final m in tj.allMatches(content)) {
          final word = m.group(1)?.trim() ?? '';
          if (word.length >= 2 && _looksLikeWord(word)) {
            extracted.write('$word ');
          }
        }
      }
      String result = extracted.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (result.length < 100) {
        final wordList = <String>[];
        final wordRx = RegExp(r'\b[A-Za-z]{2,}(?:[A-Za-z0-9 ,.\-:]{0,60})?\b');
        for (final m in wordRx.allMatches(raw)) {
          final w = m.group(0)?.trim() ?? '';
          if (w.length >= 3 && _looksLikeWord(w)) wordList.add(w);
        }
        result = wordList.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      }
      return result;
    } catch (_) { return ''; }
  }

  bool _looksLikeWord(String w) {
    if (w.isEmpty) return false;
    final letters = w.replaceAll(RegExp(r'[^a-zA-Z]'), '');
    if (letters.length / w.length < 0.6) return false;
    if (RegExp(r'[A-Z]{6,}').hasMatch(w)) return false;
    return true;
  }

  String _cleanExtractedText(String text) {
    final words = text.split(RegExp(r'\s+'));
    final clean = words.where((w) {
      if (w.length < 2) return false;
      final letters = RegExp(r'[a-zA-Z]').allMatches(w).length;
      if (letters == 0) return false;
      if (letters / w.length < 0.5) return false;
      final lower = w.toLowerCase();
      final rejects = ['endobj','stream','xref','trailer','startxref',
                       'fontname','encoding','widths','bbox','procset'];
      for (final r in rejects) { if (lower == r) return false; }
      return true;
    });
    return clean.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ── KB UPLOAD ────────────────────────────────────────────────────
  Future<void> _uploadKnowledgeDoc() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final filename = file.name;
      final bytes = file.bytes;
      if (bytes == null) {
        _showSnack('Cannot read file.', AppColors.red); return;
      }
      String extractedText = '';
      final ext = filename.split('.').last.toLowerCase();
      if (ext == 'txt') {
        try { extractedText = utf8.decode(bytes, allowMalformed: false); }
        catch (_) { extractedText = String.fromCharCodes(bytes.where((b) => b >= 32 && b <= 126).toList()); }
      } else {
        extractedText = _extractTextFromBytes(bytes);
        extractedText = _cleanExtractedText(extractedText);
      }
      if (!_isReadableText(extractedText) || extractedText.trim().length < 50) {
        if (mounted) _showPdfHelpDialog(filename); return;
      }
      final newIds = await LocalDB.addKnowledgeDocs([
        {
          'title': filename
              .replaceAll(RegExp(r'\.(pdf|txt|doc|docx)$', caseSensitive: false), '')
              .replaceAll('_', ' ')
              .trim(),
          'content': extractedText,
          'source':  filename,
        }
      ]);
      // Push only the new doc. This used to push the ENTIRE knowledge base,
      // which duplicated every existing row on the server.
      try {
        await SyncService.pushNewKbDocs(newIds);
      } catch (_) {}
      final docs = await LocalDB.getKnowledgeDocs();
      if (mounted) {
        setState(() => _kbDocCount = docs.length);
        _showSnack('Added "$filename" to knowledge base', AppColors.green);
      }
    } catch (e) { _showSnack('Upload failed: $e', AppColors.red); }
  }

  void _showPdfHelpDialog(String filename) {
    final sl = SL.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.info_outline, color: sl.amberText, size: 20),
          const SizedBox(width: 8),
          Text('Could not read file', style: TextStyle(
              color: sl.text1, fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"$filename" appears to be image-based or binary-encoded.',
                style: TextStyle(color: sl.text2, fontSize: 13)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accent.withOpacity(0.3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('✅  Better options:', style: TextStyle(
                    color: sl.accentText, fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('1. Copy text → paste via Admin Panel → Add Text Entry',
                    style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4)),
                Text('2. Save as .txt and upload that instead',
                    style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4)),
                Text('3. Use a text-based PDF (not scanned/image PDF)',
                    style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4)),
              ])),
          ]),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it', style: TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  Future<void> _showKnowledgeManager() async {
    final docs = await LocalDB.getKnowledgeDocs();
    if (!mounted) return;
    final sl = SL.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: sl.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSB) {
        return Padding(
          padding: EdgeInsets.only(left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.library_books_outlined,
                    color: sl.amberText, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Knowledge Base (Admin)',
                    style: TextStyle(color: sl.text1,
                        fontSize: 15, fontWeight: FontWeight.w700))),
                IconButton(icon: Icon(Icons.close, color: sl.text3),
                    onPressed: () => Navigator.pop(ctx)),
              ]),
              Text('💡 Best results with .txt files or Admin Panel text entries.',
                  style: TextStyle(color: sl.text3, fontSize: 11, height: 1.4)),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  await _uploadKnowledgeDoc();
                  final fresh = await LocalDB.getKnowledgeDocs();
                  setSB(() { docs..clear()..addAll(fresh); });
                },
                icon: const Icon(Icons.upload_file, color: Colors.white),
                label: const Text('Upload document (.txt recommended)',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: const Size(double.infinity, 0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
              const SizedBox(height: 14),
              Text('UPLOADED (${docs.length})',
                  style: TextStyle(color: sl.text4, fontSize: 9,
                      letterSpacing: 0.8, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              docs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(child: Text(
                        'No documents yet. Upload reference material to enhance the chatbot.',
                        style: TextStyle(color: sl.text4, fontSize: 11),
                        textAlign: TextAlign.center)))
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true, itemCount: docs.length,
                      itemBuilder: (_, i) {
                        final d = docs[i];
                        final charCount = (d['content']?.toString() ?? '').length;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: sl.card2,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: sl.border)),
                          child: Row(children: [
                            Icon(Icons.description_outlined,
                                color: sl.amberText, size: 16),
                            const SizedBox(width: 8),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(d['title']?.toString() ?? '',
                                  style: TextStyle(color: sl.text1,
                                      fontSize: 11, fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis),
                              Text('$charCount chars · ${d['uploadedBy'] ?? '—'}',
                                  style: TextStyle(color: sl.text4, fontSize: 9)),
                            ])),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  color: sl.redText, size: 18),
                              onPressed: () async {
                                await LocalDB.deleteKnowledgeDoc(d['id'].toString());
                                final fresh = await LocalDB.getKnowledgeDocs();
                                setSB(() { docs..clear()..addAll(fresh); });
                                if (mounted) setState(() => _kbDocCount = fresh.length);
                              }),
                          ]));
                      })),
            ]));
      }),
    );
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── BUILD ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return SafeArea(
      child: Column(children: [
        // ── Header ────────────────────────────────────────────────
        UniversalAppBar(
          title: 'Suraksha Saathi',
          subtitle: _aiLoading ? 'Thinking...' : 'AI Safety Assistant',
          user: widget.user ?? _user,
          toggleTheme: widget.toggleTheme,
          onSignOut: widget.onSignOut,
          isDark: widget.isDark,
          showExport: false,
        ),

        // ── Messages ──────────────────────────────────────────────
        Expanded(
          child: ListView(
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            children: [
              ..._messages.map((m) => _bubble(
                  m['role'].toString(), m['text'].toString(),
                  m['sources'] as List?,
                  m['timestamp'] as DateTime?)),
              if (_aiLoading) _loadingBubble(),
              if (!_aiLoading) _suggestionChips(),
            ],
          ),
        ),

        // ── Input bar ─────────────────────────────────────────────
        Container(
          // The bottom pad is measured, not 8: the shell sets `extendBody: true`,
          // so this Column reaches the physical bottom of the screen and the
          // frosted nav bar paints on top of it. Without the extra inset the
          // whole compose row — the only way to talk to the assistant — sits
          // underneath the bar.
          padding: EdgeInsets.fromLTRB(
              10, 8, 10, BottomNavGap.height(context) + 8),
          decoration: BoxDecoration(
            color: sl.bg2,
            border: Border(top: BorderSide(color: sl.border, width: 0.8))),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: TextStyle(color: sl.text1, fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Ask about LOTOTO, gas safety, height regulations, permits...',
                  hintStyle: TextStyle(color: sl.text4, fontSize: 11),
                  filled: true, fillColor: sl.card2,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sl.border, width: 1.5)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sl.border, width: 1.5)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.amber, width: 2))),
                onSubmitted: _aiLoading ? null : _send)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _aiLoading ? null : () => _send(_ctrl.text),
              child: Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: _aiLoading ? sl.border : AppColors.amber,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: _aiLoading ? null : [BoxShadow(
                      color: AppColors.amber.withOpacity(0.35),
                      blurRadius: 10, offset: const Offset(0, 3))]),
                child: _aiLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, color: Colors.white, size: 18))),
          ]),
        ),
      ]),
    );
  }

  // ── LOADING BUBBLE ───────────────────────────────────────────────
  Widget _loadingBubble() {
    final sl = SL.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 30, height: 30,
          decoration: const BoxDecoration(shape: BoxShape.circle,
            gradient: LinearGradient(colors: [AppColors.amber, Color(0xFFFF8C00)])),
          child: const Icon(Icons.shield_outlined, color: Colors.white, size: 14)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(14).copyWith(
                topLeft: const Radius.circular(4)),
            border: Border.all(color: sl.border.withOpacity(0.5))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.amber)),
            const SizedBox(width: 8),
            Text(_aiLoading ? 'Searching knowledge base...' : 'Thinking...',
                style: TextStyle(color: sl.text3, fontSize: 11)),
          ])),
      ]));
  }

  Widget _bubble(String role, String text, List? sources, [DateTime? ts]) {
    final isUser = role == 'user';
    final sl     = SL.of(context);
    final timeStr = ts != null
        ? '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}'
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(width: 30, height: 30,
              decoration: const BoxDecoration(shape: BoxShape.circle,
                gradient: LinearGradient(
                    colors: [AppColors.amber, Color(0xFFFF8C00)])),
              child: const Icon(Icons.shield_outlined,
                  color: Colors.white, size: 14)),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? AppColors.accent : sl.card,
                borderRadius: BorderRadius.circular(14).copyWith(
                  topLeft: isUser ? const Radius.circular(14) : const Radius.circular(4),
                  topRight: isUser ? const Radius.circular(4) : const Radius.circular(14)),
                border: Border.all(color: isUser
                    ? AppColors.accentDark : sl.border.withOpacity(0.5))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ★ Colored rich text for AI responses
                if (!isUser)
                  _coloredAiText(text, sl)
                else
                  Text(text, style: const TextStyle(
                      color: Colors.white, fontSize: 12.5, height: 1.55)),
                if (sources != null && sources.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _sourcesChip(sources, sl),
                ],
                // ★ Timestamp
                if (timeStr.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(timeStr, style: TextStyle(
                      color: sl.text4, fontSize: 8)),
                ],
              ]),
            )),
          if (isUser) const SizedBox(width: 30),
        ]));
  }

  /// Citations under an AI answer.
  ///
  /// Names the documents rather than just counting them ("2 sources from
  /// knowledge base" told the user nothing they could check), and marks any
  /// unverified scan explicitly. The prompt asks the model to caveat those, but
  /// a model instruction is not a guarantee — this label is, because it is
  /// derived from the row's own `verified` flag.
  Widget _sourcesChip(List sources, SL sl) {
    final docs = sources
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList(growable: false);
    final unverified =
        docs.where(KnowledgeService.isUnverifiedScan).length;
    final anyUnverified = unverified > 0;

    // Amber already means "AI response" in this screen's avatar and input
    // accent, so an amber citation chip cannot also mean "caution". Verified
    // sources get the neutral card treatment; only an unverified scan gets a
    // warning colour, so the colour carries information.
    final accentFill = anyUnverified
        ? AppColors.amber.withOpacity(0.12)
        : sl.card2;
    final accentLine = anyUnverified
        ? AppColors.amber.withOpacity(0.45)
        : sl.border;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: accentFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accentLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(anyUnverified
                  ? Icons.warning_amber_rounded
                  : Icons.menu_book_outlined,
              size: 12,
              color: anyUnverified ? sl.amberText : sl.text3),
          const SizedBox(width: 5),
          Expanded(child: Text(
            anyUnverified
                ? 'Based on ${docs.length} knowledge base source'
                    '${docs.length > 1 ? 's' : ''} — '
                    '$unverified unverified scan'
                    '${unverified > 1 ? 's' : ''}'
                : 'Based on ${docs.length} knowledge base source'
                    '${docs.length > 1 ? 's' : ''}',
            style: TextStyle(
                color: anyUnverified ? sl.amberText : sl.text3,
                fontSize: 11, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 4),
        // Cap the list: a query can retrieve five clauses of the same SOP and
        // five lines of citation would be taller than the answer.
        ...docs.take(3).map((d) {
          final cite = KnowledgeService.citationFor(d);
          final scan = KnowledgeService.isUnverifiedScan(d);
          return Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '• ${d['title'] ?? 'Untitled'}'
              '${cite.isEmpty ? '' : '  ($cite)'}'
              '${scan ? '  — unverified scan' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: sl.text3, fontSize: 11, height: 1.3)),
          );
        }),
        if (docs.length > 3)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('• + ${docs.length - 3} more',
                style: TextStyle(color: sl.text4, fontSize: 11))),
        if (anyUnverified)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Unverified scans were photographed from printed copies and read '
              'by OCR. Check numbers against the printed document.',
              style: TextStyle(color: sl.text4, fontSize: 11, height: 1.3)),
          ),
      ]),
    );
  }

  /// ★ Render AI response with colored sections for visual appeal
  Widget _coloredAiText(String text, SL sl) {
    final lines = text.split('\n');
    final widgets = <Widget>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        widgets.add(const SizedBox(height: 4));
        continue;
      }

      // 【TOPIC】 header — bold, accent colored
      if (trimmed.startsWith('【') && trimmed.contains('】')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 2),
          child: Text(trimmed, style: TextStyle(
            color: sl.accentText, fontSize: 13,
            fontWeight: FontWeight.w800))));
      }
      // 📋 Regulation line — blue (dark-safe)
      else if (trimmed.startsWith('📋')) {
        widgets.add(Text(trimmed, style: TextStyle(
          color: sl.isDark ? const Color(0xFF64B5F6) : const Color(0xFF1565C0),
          fontSize: 12, fontWeight: FontWeight.w700, height: 1.5)));
      }
      // ⚡ Key Points header — amber
      else if (trimmed.startsWith('⚡')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(trimmed, style: TextStyle(
            color: sl.amberText, fontSize: 12,
            fontWeight: FontWeight.w700, height: 1.5))));
      }
      // ✅ Action line — green (dark-safe)
      else if (trimmed.startsWith('✅')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(trimmed, style: TextStyle(
            color: sl.isDark ? const Color(0xFF69F0AE) : const Color(0xFF2E7D32),
            fontSize: 12, fontWeight: FontWeight.w700, height: 1.5))));
      }
      // ⚠️ Warning lines — red/orange (dark-safe)
      else if (trimmed.startsWith('⚠️') || trimmed.startsWith('🚨')) {
        widgets.add(Text(trimmed, style: TextStyle(
          color: sl.isDark ? const Color(0xFFFF8A65) : const Color(0xFFE65100),
          fontSize: 12, fontWeight: FontWeight.w600, height: 1.5)));
      }
      // • Bullet points — slightly indented, normal color
      else if (trimmed.startsWith('•') || trimmed.startsWith('-')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text(trimmed, style: TextStyle(
            color: sl.text1, fontSize: 12, height: 1.5))));
      }
      // Normal text
      else {
        widgets.add(Text(trimmed, style: TextStyle(
          color: sl.text1, fontSize: 12.5, height: 1.55)));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _suggestionChips() {
    final sl = SL.of(context);
    // ★ Dynamic suggestions: context-aware follow-ups after first message,
    //    or topic starters when chat is empty
    final bool hasConversation = _messages.length > 1;
    final List<String> suggestions;

    if (hasConversation) {
      // Follow-up suggestions based on last AI response
      final lastAi = _messages.lastWhere(
        (m) => m['role'] == 'ai', orElse: () => {'text': ''});
      final lastText = lastAi['text']?.toString().toLowerCase() ?? '';

      if (lastText.contains('lototo') || lastText.contains('lock out')) {
        suggestions = [
          'LOTOTO steps for electrical panel',
          'LOTOTO vs isolation — difference?',
          'Who authorises LOTO in BF?',
        ];
      } else if (lastText.contains('height') || lastText.contains('harness')) {
        suggestions = [
          'Harness inspection checklist',
          'Fall arrest vs fall restraint',
          'Safety net regulation',
        ];
      } else if (lastText.contains('confined space')) {
        suggestions = [
          'Gas test before confined space entry',
          'SCBA vs SABA — when to use',
          'Confined space rescue plan',
        ];
      } else if (lastText.contains('gas') || lastText.contains('cylinder')) {
        suggestions = [
          'O2 cylinder colour code',
          'Cylinder storage distance table',
          'Gas-free certificate procedure',
        ];
      } else if (lastText.contains('hot work') || lastText.contains('permit')) {
        suggestions = [
          'Hot work permit checklist',
          'Fire watch duration after hot work',
          'Where is hot work NOT allowed?',
        ];
      } else if (lastText.contains('electrical') || lastText.contains('arc flash')) {
        suggestions = [
          'LOTO for electrical safety',
          'Arc flash PPE categories',
          'Minimum approach distance HV',
        ];
      } else {
        suggestions = [
          'LOTOTO explained',
          'Confined space entry steps',
          'Working at height regulation',
          'Hot work permit requirements',
          'Gas cylinder colour codes',
          'Fire extinguisher types use',
        ];
      }
    } else {
      suggestions = [
        'LOTOTO step by step',
        'Gas cylinder colour codes',
        'Working at height regulation',
        'Confined space entry checklist',
        'Hot work permit requirements',
        'Blast furnace gas safety',
        'CO gas exposure emergency',
        'Incident classification LTI FAC RWC',
        'WSA 13 causes list',
        'Contractor safety requirements',
        'Line of Fire hazards',
        'Electrical arc flash PPE',
      ];
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hasConversation ? 'FOLLOW-UP QUESTIONS' : 'SUGGESTED QUESTIONS',
          style: TextStyle(color: sl.text4, fontSize: 9,
              fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6,
          children: suggestions.map((s) => GestureDetector(
            onTap: () => _send(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: sl.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sl.border)),
              child: Text(s, style: TextStyle(color: sl.text2, fontSize: 10)))
          )).toList()),
      ]));
  }
}
