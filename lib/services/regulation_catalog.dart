/// The citable regulation catalogue used by hazard analysis.
///
/// WHY THIS FILE EXISTS
/// -------------------
/// The vision prompt has always ended with "NEVER invent regulation numbers not
/// in this table", and the table was a plain string literal inside
/// `GeminiVision._getHazardPrompt()`. That made the instruction unenforceable:
/// the app had no machine-readable idea of what the table contained, so a model
/// that cited "FA 1948 S45" or applied S21 to a gas cylinder was believed
/// without question, and the citation went on to appear in an official
/// observation record and PDF.
///
/// The same list now lives here as data. The prompt is GENERATED from it, so the
/// text the model is shown and the set the app validates against cannot drift
/// apart — which is the failure mode that made the old arrangement worthless.
///
/// This is deliberately not a general regulation database. It is the closed set
/// the model is permitted to cite from, plus enough structure to catch the
/// specific misapplications that the prompt's HARD RULES section warns about.
library;

/// One citable reference.
class RegulationEntry {
  const RegulationEntry({
    required this.group,
    required this.citation,
    required this.meaning,
    this.alsoUnder = const [],
    this.appliesTo = const [],
    this.neverFor = const [],
  });

  /// Heading this sits under in the prompt table, e.g. 'Machinery & Guards'.
  final String group;

  /// Extra headings this same citation is also listed under. Two references
  /// genuinely serve two subjects — S32 is both "Height & Access" and
  /// "Housekeeping", S37 is both "Gas Cylinders" and "Pressure & Fire" — and the
  /// grouping is a mapping cue for the model, so the row is repeated in the
  /// rendered table while remaining ONE entry here.
  final List<String> alsoUnder;

  /// Canonical display form, exactly as it should appear in a report.
  final String citation;

  /// What the reference actually covers — the right-hand side of the table.
  final String meaning;

  /// Subject keywords that ought to appear in a hazard citing this reference.
  /// Used only as positive corroboration; an empty list means "do not judge
  /// topical fit", never "always wrong".
  final List<String> appliesTo;

  /// Subject keywords that make this citation a MISAPPLICATION. These encode
  /// the prompt's HARD RULES, which previously existed only as a plea to the
  /// model: S21 is machinery fencing and has nothing to do with gas cylinders,
  /// S36 is confined space and not work at height.
  final List<String> neverFor;
}

class RegulationCatalog {
  RegulationCatalog._();

  /// The closed citable set. Order is preserved when rendering the prompt table,
  /// because the grouping is what teaches the model which family to reach for.
  static const List<RegulationEntry> entries = [
    // ── Gas Cylinders ──
    RegulationEntry(
      group: 'Gas Cylinders',
      citation: 'SMPV Rules 2016 Rule 14',
      meaning: 'Storage (upright, chained, segregated, ventilated)',
      appliesTo: ['cylinder', 'gas', 'lpg', 'oxygen', 'acetylene', 'storage'],
    ),
    RegulationEntry(
      group: 'Gas Cylinders',
      citation: 'SMPV Rules 2016 Rule 10',
      meaning: 'Valve caps',
      appliesTo: ['cylinder', 'valve', 'cap', 'gas'],
    ),
    RegulationEntry(
      group: 'Gas Cylinders',
      citation: 'IS 4379:1981',
      meaning: 'Colour code identification',
      appliesTo: ['cylinder', 'colour', 'color', 'code', 'identification', 'gas'],
    ),
    RegulationEntry(
      group: 'Gas Cylinders',
      citation: 'IS 7312:1987',
      meaning: 'Storage of gas cylinders',
      appliesTo: ['cylinder', 'storage', 'gas'],
    ),

    // ── Machinery & Guards ──
    RegulationEntry(
      group: 'Machinery & Guards',
      citation: 'FA 1948 S21',
      meaning: 'Fencing of machinery (rotating/moving parts ONLY)',
      appliesTo: [
        'machine', 'machinery', 'guard', 'fencing', 'rotating', 'moving',
        'shaft', 'belt', 'pulley', 'gear', 'conveyor', 'nip', 'coupling',
      ],
      // The single most common misapplication in this app's history.
      neverFor: ['cylinder', 'confined space', 'harness', 'scaffold'],
    ),
    RegulationEntry(
      group: 'Machinery & Guards',
      citation: 'FA 1948 S22',
      meaning: 'Work near machinery in motion',
      appliesTo: ['machinery', 'motion', 'moving', 'lubricat', 'cleaning', 'adjust'],
    ),

    // ── Height & Access ──
    RegulationEntry(
      group: 'Height & Access',
      citation: 'FA 1948 S32',
      meaning: 'Floors, stairs, means of access (trip/slip/fall, safe access)',
      alsoUnder: ['Housekeeping'],
      appliesTo: [
        'floor', 'stair', 'access', 'trip', 'slip', 'fall', 'walkway',
        'housekeeping', 'passage', 'ladder', 'handrail', 'railing', 'obstruct',
      ],
      neverFor: ['confined space', 'fume'],
    ),
    RegulationEntry(
      group: 'Height & Access',
      citation: 'FA 1948 S33',
      meaning: 'Pits, sumps, openings in floors',
      appliesTo: ['pit', 'sump', 'opening', 'hole', 'uncovered', 'floor', 'cover'],
    ),
    RegulationEntry(
      group: 'Height & Access',
      citation: 'IS 3521:1999',
      meaning: 'Safety harness for work at height',
      alsoUnder: ['PPE'],
      appliesTo: ['harness', 'height', 'fall', 'lanyard', 'anchor', 'lifeline'],
    ),

    // ── Crane & Lifting ──
    RegulationEntry(
      group: 'Crane & Lifting',
      citation: 'FA 1948 S28',
      meaning: 'Hoists and lifts',
      appliesTo: ['hoist', 'lift', 'elevator', 'cage'],
    ),
    RegulationEntry(
      group: 'Crane & Lifting',
      citation: 'FA 1948 S29',
      meaning: 'Lifting machines, chains, ropes, tackles',
      appliesTo: [
        'crane', 'lifting', 'chain', 'rope', 'sling', 'tackle', 'load',
        'hook', 'suspended', 'shackle',
      ],
    ),

    // ── Pressure & Fire ──
    RegulationEntry(
      group: 'Pressure & Fire',
      citation: 'FA 1948 S31',
      meaning: 'Pressure plant',
      appliesTo: ['pressure', 'vessel', 'boiler', 'compressor', 'pipeline', 'steam'],
    ),
    RegulationEntry(
      group: 'Pressure & Fire',
      citation: 'FA 1948 S37',
      meaning: 'Explosive/inflammable gas, dust (No Smoking, separation)',
      alsoUnder: ['Gas Cylinders'],
      appliesTo: [
        'explosive', 'inflammable', 'flammable', 'gas', 'dust', 'smoking',
        'ignition', 'spark', 'vapour',
      ],
    ),
    RegulationEntry(
      group: 'Pressure & Fire',
      citation: 'FA 1948 S38',
      meaning: 'Fire precautions (exits, extinguishers)',
      appliesTo: ['fire', 'exit', 'extinguisher', 'escape', 'hydrant', 'evacuat'],
    ),
    RegulationEntry(
      group: 'Pressure & Fire',
      citation: 'IS 2190:2010',
      meaning: 'Fire extinguisher maintenance',
      appliesTo: ['extinguisher', 'fire', 'refill', 'inspection', 'expired'],
    ),

    // ── Electrical ──
    RegulationEntry(
      group: 'Electrical',
      citation: 'CEA Regulations 2010 Reg 36',
      meaning: 'Earthing',
      appliesTo: ['earth', 'ground', 'bonding', 'electrical'],
    ),
    RegulationEntry(
      group: 'Electrical',
      citation: 'CEA Regulations 2010 Reg 45',
      meaning: 'Insulation of conductors',
      appliesTo: ['insulation', 'conductor', 'cable', 'wire', 'exposed', 'electrical'],
    ),
    RegulationEntry(
      group: 'Electrical',
      citation: 'CEA Regulations 2010 Reg 46',
      meaning: 'Protection against shock',
      appliesTo: ['shock', 'live', 'panel', 'electrical', 'energised', 'energized'],
    ),
    RegulationEntry(
      group: 'Electrical',
      citation: 'Indian Electricity Rules 1956 Rule 50',
      meaning: 'Danger notice on HV',
      appliesTo: ['danger', 'notice', 'signage', 'high voltage', 'hv', 'electrical'],
    ),

    // ── PPE ──
    RegulationEntry(
      group: 'PPE',
      citation: 'FA 1948 S35',
      meaning: 'Protection of eyes',
      appliesTo: ['eye', 'goggle', 'face shield', 'welding', 'grinding', 'spectacle'],
    ),
    RegulationEntry(
      group: 'PPE',
      citation: 'FA 1948 S41C',
      meaning: 'PPE provision (employer duty)',
      appliesTo: [
        'ppe', 'helmet', 'glove', 'apron', 'shoe', 'boot', 'protective',
        'hot metal', 'slag', 'ladle',
      ],
    ),
    RegulationEntry(
      group: 'PPE',
      citation: 'IS 2925:1984',
      meaning: 'Safety helmets',
      appliesTo: ['helmet', 'hard hat', 'head'],
    ),
    RegulationEntry(
      group: 'PPE',
      citation: 'IS 15298:2011',
      meaning: 'Safety footwear',
      appliesTo: ['footwear', 'shoe', 'boot', 'foot'],
    ),

    // ── Confined Space & Fumes ──
    RegulationEntry(
      group: 'Confined Space & Fumes',
      citation: 'FA 1948 S36',
      meaning: 'Dangerous fumes/gases (confined space ONLY)',
      appliesTo: ['confined', 'fume', 'vessel entry', 'manhole', 'tank', 'oxygen deficien'],
      neverFor: ['height', 'scaffold', 'harness', 'floor opening'],
    ),

    // ── Chemical ──
    RegulationEntry(
      group: 'Chemical',
      citation: 'MSIHC Rules 1989',
      meaning: 'Hazardous chemical storage/labelling',
      appliesTo: ['chemical', 'label', 'msds', 'sds', 'drum', 'acid', 'solvent', 'toxic'],
    ),
  ];

  /// Citations the model must never use for an individual hazard, with the
  /// reason. `IS 14489:2018` is an audit standard for a whole workplace, not a
  /// finding-level reference; the prompt says so, and now the app can check it.
  static const Map<String, String> bannedForHazards = {
    'IS14489': 'IS 14489:2018 is a workplace audit standard, not a hazard-level reference',
  };

  // ── Prompt rendering ─────────────────────────────────────────────────────

  /// Renders the catalogue as the prompt's reference table. Generated rather
  /// than hand-maintained so the model can never be shown an entry the
  /// validator does not know, or vice versa.
  /// Heading order in the rendered table. Explicit rather than derived from
  /// [entries], because a citation can appear under more than one heading and
  /// the sequence itself matters: the model reads this top to bottom.
  static const List<String> groupOrder = [
    'Gas Cylinders',
    'Machinery & Guards',
    'Height & Access',
    'Crane & Lifting',
    'Pressure & Fire',
    'Electrical',
    'PPE',
    'Confined Space & Fumes',
    'Housekeeping',
    'Chemical',
  ];

  static String promptTable() {
    final buf = StringBuffer();
    for (final group in groupOrder) {
      final rows = entries
          .where((e) => e.group == group || e.alsoUnder.contains(group))
          .toList();
      if (rows.isEmpty) continue;
      buf.writeln('── $group ──');
      for (final e in rows) {
        buf.writeln('  ${e.citation} = ${e.meaning}');
      }
    }
    return buf.toString().trimRight();
  }

  // ── Citation matching ────────────────────────────────────────────────────

  /// Collapses a citation to a comparable signature, so the many ways a model
  /// writes the same reference all land on one key.
  ///
  /// "FA 1948 S21", "Factories Act, 1948 – Section 21", "FA1948 Sec. 21" and
  /// "factories act 1948 s 21" must all match, or the validator would reject
  /// correct citations purely on spelling and every hazard would look doubtful.
  /// Returns an empty string when no recognisable reference is present.
  static String signature(String raw) {
    if (raw.trim().isEmpty) return '';
    var t = raw.toUpperCase();

    // Long forms → the short forms used in the catalogue.
    t = t
        .replaceAll(RegExp(r'THE\s+FACTORIES\s+ACT'), 'FA')
        .replaceAll(RegExp(r'FACTORIES\s+ACT'), 'FA')
        .replaceAll(RegExp(r'INDIAN\s+ELECTRICITY\s+RULES?'), 'IER')
        .replaceAll(RegExp(r'CENTRAL\s+ELECTRICITY\s+AUTHORITY'), 'CEA')
        .replaceAll(RegExp(r'\bCEA\s+REGULATIONS?'), 'CEA')
        .replaceAll(RegExp(r'\bSECTIONS?\b|\bSEC\b'), 'S')
        .replaceAll(RegExp(r'\bREGULATIONS?\b|\bREGN?\b'), 'REG')
        .replaceAll(RegExp(r'\bRULES?\b'), 'RULE')
        .replaceAll(RegExp(r'\bINDIAN\s+STANDARD\b|\bIS\s*:'), 'IS');

    // Which instrument?
    String family = '';
    if (RegExp(r'\bFA\b.*1948|1948').hasMatch(t) && t.contains('FA')) {
      family = 'FA1948';
    } else if (t.contains('SMPV')) {
      family = 'SMPV2016';
    } else if (t.contains('MSIHC')) {
      family = 'MSIHC1989';
    } else if (t.contains('IER') || RegExp(r'ELECTRICITY\s+RULE').hasMatch(t)) {
      family = 'IER1956';
    } else if (t.contains('CEA')) {
      family = 'CEA2010';
    } else {
      final is_ = RegExp(r'\bIS\s*(\d{3,5})').firstMatch(t);
      // The year suffix is dropped on purpose: IS numbers are stable but the
      // revision year a model quotes often is not, and "IS 2925:1989" is the
      // same standard as "IS 2925:1984" for the purpose of deciding whether the
      // citation was invented.
      if (is_ != null) return 'IS${is_.group(1)}';
    }
    if (family.isEmpty) return '';

    // Which clause within it?
    final sec = RegExp(r'\bS\s*\.?\s*(\d{1,3}\s*[A-Z]?)\b').firstMatch(t);
    final rule = RegExp(r'\bRULE\s*\.?\s*(\d{1,3})\b').firstMatch(t);
    final reg = RegExp(r'\bREG\s*\.?\s*(\d{1,3})\b').firstMatch(t);
    String clause = '';
    if (family == 'FA1948' && sec != null) {
      clause = 'S${sec.group(1)!.replaceAll(RegExp(r'\s+'), '')}';
    } else if (rule != null) {
      clause = 'RULE${rule.group(1)}';
    } else if (reg != null) {
      clause = 'REG${reg.group(1)}';
    }
    return clause.isEmpty ? family : '$family|$clause';
  }

  static final Map<String, RegulationEntry> _bySignature = {
    for (final e in entries) signature(e.citation): e,
  };

  /// The catalogue entry a citation refers to, or null if it is not in the
  /// permitted set. Null means "cannot be vouched for", not "definitely wrong":
  /// the plant's own uploaded standards are also citable and live in the
  /// knowledge base, not here.
  static RegulationEntry? lookup(String citation) {
    final sig = signature(citation);
    if (sig.isEmpty) return null;
    return _bySignature[sig];
  }

  /// Non-null when a citation is barred at hazard level, with the reason.
  static String? bannedReason(String citation) {
    final sig = signature(citation);
    for (final entry in bannedForHazards.entries) {
      if (sig == entry.key) return entry.value;
    }
    return null;
  }

  /// Whether [entry] is being applied to a subject it explicitly does not
  /// cover. [hazardText] should be the hazard's name, description and evidence
  /// concatenated.
  static String? misapplication(RegulationEntry entry, String hazardText) {
    final t = hazardText.toLowerCase();
    for (final bad in entry.neverFor) {
      if (t.contains(bad)) {
        return '${entry.citation} does not cover "$bad" — it is for '
            '${entry.meaning.toLowerCase()}';
      }
    }
    return null;
  }

  /// How well the hazard's subject matches what the citation actually covers.
  /// Returns null when the entry declares no subject keywords, so "no opinion"
  /// is distinguishable from "no match".
  static bool? topicalFit(RegulationEntry entry, String hazardText) {
    if (entry.appliesTo.isEmpty) return null;
    final t = hazardText.toLowerCase();
    return entry.appliesTo.any(t.contains);
  }
}
