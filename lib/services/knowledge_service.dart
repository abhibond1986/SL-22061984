// lib/services/knowledge_service.dart
// ★ v25: Centralized Knowledge Base Service
//
// PURPOSE: Single source of safety knowledge for ALL AI calls across the app.
// - Pre-loaded expert safety knowledge (compact, no large assets)
// - Admin-uploaded PDF/Word extracted text (stored in LocalDB)
// - Combines both into context injected into every AI prompt
//
// USAGE:
//   final context = await KnowledgeService.getContextForPrompt('height safety');
//   final fullPrompt = '$systemPrompt\n\n$context\n\nUser query: ...';

import 'local_db.dart';
import 'admin_master_data.dart';

class KnowledgeService {
  // ═══════════════════════════════════════════════════════════════
  //  EXPERT SAFETY KNOWLEDGE — Pre-loaded (no file I/O needed)
  //  Compact but comprehensive — covers all critical areas
  // ═══════════════════════════════════════════════════════════════

  static const String expertSystemPrompt = '''
You are an expert Safety Officer at a steel manufacturing plant (SAIL — Steel Authority of India Limited). You have deep expertise in:

REGULATORY FRAMEWORK:
• Factories Act 1948 — Chapter IV Safety (S21–S41), Chapter IVA Hazardous Processes (S41A–H)
• IS 14489:2018 — Occupational Health & Safety Code of Practice for Iron & Steel Industry
• SMPV Rules 2016 — Static & Mobile Pressure Vessels (Rules 10–22)
• CEA Regulations 2010 — Electrical Safety (Reg 36, 44, 45, 46, 47)
• Indian Electricity Rules 1956 — (Rule 29, 44, 50, 61, 64)
• Ministry of Steel Safety Guidelines SG/01–SG/41 (2019–2024)
• ILO Code of Practice: Safety & Health in Iron & Steel Industry 2005
• BIS PPE Standards: IS 2925 (helmets), IS 3521 (harness), IS 4912 (goggles), IS 5852 (boots), IS 5983 (gloves), IS 6994 (ear muffs), IS 9167 (respirators)

CRITICAL SAFETY RULES — NEVER GET WRONG:
1. Working at height (>1.8m) → FA 1948 S32 + IS 3521:1999. Full body harness mandatory. Anchor min 15kN.
2. S36 = Confined space / dangerous fumes ONLY (NOT height).
3. O₂ + Flammable gas cylinders: minimum 6m separation (SMPV Rule 14 Table-3).
4. Cylinder colours: O₂=Black/White shoulder, C₂H₂=Maroon, LPG=Silver, N₂=Grey/Black, CO₂=Grey.
5. LOTOTO = Lock Out, Tag Out, TRY OUT. Each worker applies own lock.
6. CO in BF gas: 25–28% concentration. TLV=50ppm. Explosive range 35–74%.
7. Confined space O₂ safe: 19.5–23.5%. Below 19.5% = O₂ deficient. Above 23.5% = O₂ enriched (fire risk).
8. Ladle preheat minimum: 800°C before hot metal receipt.
9. Helmet colours: White=Officer, Yellow=Supervisor, Blue=Worker, Green=Visitor, Red=Fire crew.
10. Gas cutting: min 6m from combustibles. Fire watcher mandatory. Hot work permit required.
11. PTW (Permit to Work): mandatory for hot work, confined space, height, electrical, excavation.
12. Crane signals: Standard IS 3757. Never stand under suspended load.
13. Electrical isolation: 5-step LOTOTO (Identify→Isolate→Lock→Tag→TryOut→Start work).
14. BF tapping: min 5m exclusion zone. Full PPE: aluminized suit, face shield, safety shoes.
15. Coke oven: CO + H₂S hazard. Continuous gas monitoring mandatory. Emergency escape routes.

{{WSA_CAUSES}}

NEAR MISS DEFINITION:
An unplanned event that DID NOT result in injury, illness, or damage but HAD THE POTENTIAL to do so. It involves an unexpected hazardous exposure, a close call, or a condition that could have led to an accident if not corrected.

NOT A NEAR MISS: routine observations, planned maintenance activities, general complaints, requests for supplies, work orders, scheduled inspections, situations with absolutely no potential for harm.

RISK ASSESSMENT (5×5 Matrix):
• CRITICAL: Fatality/permanent disability likely. Immediate stop work. S=5, L≥3.
• HIGH: Major injury possible. Immediate corrective action. S≥4, L≥2.
• MEDIUM: Minor injury possible. Corrective action within 48h. S=3, L=2–3.
• LOW: First aid or less. Schedule improvement. S≤2 or L=1.

COMMON STEEL PLANT HAZARDS:
• Hot metal splash/spill — burns, fire
• Crane/overhead load — struck by, crush
• Gas leaks (CO, H₂S, BF gas) — asphyxiation, poisoning, explosion
• Electrical flash/shock — electrocution, burns
• Height falls — fractures, fatality
• Moving machinery — entanglement, amputation
• Confined spaces — O₂ deficiency, toxic atmosphere
• Dust/fumes — respiratory disease (silicosis, asbestosis)
• Noise (>85dB) — hearing loss
• Thermal stress — heat exhaustion, heat stroke
• Chemical exposure — acid burns, poisoning
• Vehicle/mobile equipment — collision, run-over
• Structural collapse — crush injuries
• Fire/explosion — burns, blast injuries
''';

  // ═══════════════════════════════════════════════════════════════
  //  GET CONTEXT FOR AI PROMPTS
  //  Combines: expert knowledge + relevant KB docs from admin uploads
  // ═══════════════════════════════════════════════════════════════

  /// Returns combined knowledge context for any AI prompt.
  /// [query] is the user's input/question — used to search KB docs.
  /// [maxKbDocs] limits how many uploaded KB entries to include (to control token size).
  /// [includeExpertPrompt] whether to include the full expert system prompt.
  static Future<String> getContextForPrompt(
    String query, {
    int maxKbDocs = 3,
    bool includeExpertPrompt = true,
    int snippetChars = 400,
  }) async {
    final buffer = StringBuffer();

    // 1. Expert system prompt (compact, always available), with the WSA cause
    //    list injected live from the admin panel — see resolvedExpertPrompt().
    if (includeExpertPrompt) {
      buffer.writeln(await resolvedExpertPrompt());
    }

    // 2. Relevant KB documents from admin uploads.
    //    maxKbDocs is passed INTO the search: it used to search with the
    //    default (which capped at 3 internally) and then .take(maxKbDocs) the
    //    result, so asking for more than 3 documents was silently impossible.
    if (query.trim().length >= 3) {
      try {
        final kbResults = await LocalDB.searchKnowledge(
          query,
          limit: maxKbDocs,
          snippetChars: snippetChars,
        );
        if (kbResults.isNotEmpty) {
          buffer.writeln(
              '\n\nRELEVANT KNOWLEDGE BASE DOCUMENTS (uploaded by the safety '
              'admin — these are authoritative for this plant and OVERRIDE '
              'any general knowledge that conflicts with them):');
          for (int i = 0; i < kbResults.length; i++) {
            final doc = kbResults[i];
            buffer.writeln('--- KB Doc ${i + 1}: ${doc['title'] ?? 'Untitled'} ---');
            buffer.writeln(doc['snippet'] ?? '');
          }
        }
      } catch (_) {
        // KB search failed — continue without it
      }
    }

    return buffer.toString();
  }

  /// Builds a retrieval query for a case where there is no user question —
  /// principally AI image analysis.
  ///
  /// Why this exists: the hazard analyser searched the KB with one FIXED
  /// string ('safety regulation statutory reference factories act IS
  /// standard'). That query matches whatever happens to use those generic
  /// words, so an uploaded document about, say, ladle handling was
  /// unreachable no matter how relevant it was. Seeding the query from the
  /// admin's OWN cause categories and observation types means retrieval
  /// widens automatically as the admin adds vocabulary, and every configured
  /// hazard domain gets a chance to match.
  static Future<String> buildImageAnalysisQuery({String extraContext = ''}) async {
    final terms = <String>{};
    try {
      for (final c in await AdminMasterData.getWsaCauses()) {
        // Cause entries look like "3. Working at height" — drop the number.
        terms.addAll(c
            .replaceFirst(RegExp(r'^\s*\d+\s*[.)]\s*'), '')
            .toLowerCase()
            .split(RegExp(r'[^a-z0-9]+'))
            .where((w) => w.length > 3));
      }
    } catch (_) {}
    try {
      for (final t in await AdminMasterData.getObsTypes()) {
        terms.addAll(t
            .toLowerCase()
            .split(RegExp(r'[^a-z0-9]+'))
            .where((w) => w.length > 3));
      }
    } catch (_) {}
    if (extraContext.trim().isNotEmpty) {
      terms.addAll(extraContext
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.length > 3));
    }
    // Drop words so common in safety documents that they match everything and
    // therefore rank nothing.
    terms.removeAll(const {'safety', 'unsafe', 'other', 'others', 'general'});
    if (terms.isEmpty) {
      return 'safety hazard regulation statutory reference';
    }
    return terms.join(' ');
  }

  /// Lightweight version — only searches KB docs, no expert prompt.
  /// Use when the expert prompt is already included in the caller's system prompt.
  static Future<String> getKbDocsContext(String query,
      {int maxDocs = 3, int snippetChars = 400}) async {
    return getContextForPrompt(query,
        maxKbDocs: maxDocs,
        includeExpertPrompt: false,
        snippetChars: snippetChars);
  }

  /// The expert system prompt with the `{{WSA_CAUSES}}` placeholder replaced
  /// by the CURRENT admin-configured cause list. This is why the raw
  /// [expertSystemPrompt] must never be sent to a model directly — every AI
  /// path has to go through here, otherwise renaming a cause in the admin
  /// panel leaves the AI emitting labels that no longer exist in the dropdown.
  static Future<String> resolvedExpertPrompt() async {
    List<String> causes;
    try {
      causes = await AdminMasterData.getWsaCauses();
    } catch (_) {
      causes = List<String>.from(AdminMasterData.defaultWsaCauses);
    }
    final block = causes.isEmpty
        ? 'HAZARD CATEGORIES: none configured — do not assign a category.'
        : 'HAZARD CATEGORIES (assign ONE, and use the exact wording below):\n'
            '${causes.join('\n')}';
    return expertSystemPrompt.replaceAll('{{WSA_CAUSES}}', block);
  }

  /// Returns just the expert system prompt (no KB search).
  /// Use when you need the static knowledge without query-based doc search.
  /// NOTE: prefer [resolvedExpertPrompt] — this synchronous version still
  /// contains the unresolved `{{WSA_CAUSES}}` placeholder.
  static Future<String> getExpertPrompt() => resolvedExpertPrompt();

  /// Get total knowledge base stats for display.
  static Future<Map<String, dynamic>> getKbStats() async {
    final docs = await LocalDB.getKnowledgeDocs();
    int totalChars = 0;
    int uploadedCount = 0;
    int seededCount = 0;
    for (final doc in docs) {
      final content = doc['content']?.toString() ?? '';
      totalChars += content.length;
      if (doc['source'] == 'uploaded' || doc['source'] == 'pdf_upload' || doc['source'] == 'docx_upload') {
        uploadedCount++;
      } else {
        seededCount++;
      }
    }
    return {
      'totalDocs': docs.length,
      'uploadedDocs': uploadedCount,
      'seededDocs': seededCount,
      'totalChars': totalChars,
      'estimatedTokens': (totalChars / 4).round(), // ~4 chars per token
    };
  }
}
