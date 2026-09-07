// lib/services/near_miss_guard.dart
//
// A last check on the near-miss text classifier: did the hazard it reported
// actually come from the worker, or from the model?
//
// WHY THIS EXISTS
//
// "While walking inside his office he was singing a song" was classified as an
// Unsafe Act, Slip/Fall, MEDIUM severity, at 90% confidence, with a corrective
// action advising employees not to sing while walking. Nothing in that input
// names a hazard. The model supplied the entire dangerous part of the story —
// the distraction, the slip, the collision — and then reported its own
// invention back as the worker's observation at high confidence.
//
// `near_miss_prompt.dart` was rebalanced to stop asking for that, and most of
// the time the prompt is enough. This is the part that does not depend on the
// model choosing to obey: a claimed hazard is checked against the worker's own
// words before the form offers to file it.
//
// It is the text-side counterpart of the `sceneInventory` grounding gate on the
// vision path — same failure, same remedy: no finding without evidence the
// reporter actually supplied.
//
// HOW IT IS SAFE TO USE A WORD LIST HERE
//
// `near_miss_tab.dart` says, of WSA cause matching, "deliberately no keyword
// guessing: a wrong cause is worse than an absent one", and that is right. This
// is not that. It never assigns anything. It answers one question — does the
// worker's text carry ANY hazard signal at all — and it is used in one
// direction only:
//
//   • signal present  → say nothing, the model's answer stands.
//   • signal absent   → the hazard cannot have come from the text.
//   • cannot tell     → say nothing.
//
// That asymmetry is what makes the vocabulary safe to maintain. Adding a word
// can only make the guard quieter; it can never make it reject a report it was
// previously accepting. The only failure mode is a hazard word nobody thought
// of, so the list is deliberately over-inclusive and errs toward silence —
// missing a false positive costs one bad record that a supervisor can reject,
// while a wrongly-refused report is a worker who stops reporting.
//
// LANGUAGE
//
// The vocabulary is English. On anything else the guard returns null — NOT
// CHECKED — rather than judging text it has no vocabulary for, since a Hindi
// hazard report contains no English hazard words and would be refused wholesale.
// Hindi input is protected by the prompt alone.
//
// TWO gates are needed for that, not one. A script check catches Devanagari, but
// the shop-floor keyboard defaults to Latin and a great deal of real input is
// romanised Hindi — "chalte samay tel gira hua tha", "seedhi par railing nahi
// hai". That passes any script check, matches no English stem, and would be
// vetoed: a genuine oil-spill report thrown away by a guard that could not read
// it. So `_romanHindiMarkers` looks for Hindi function words in Latin script and
// bails out too. Function words, not hazard words, because they are the part of
// a sentence a speaker cannot avoid — "tel" might be missing from any given
// report, "tha" or "hai" or "nahi" will not be.
//
// If a Hindi hazard vocabulary is ever added it must be complete enough to carry
// the same asymmetry, or it will do exactly the damage these two gates prevent.

/// Verdict on whether the worker's own words carry a hazard signal.
class NearMissGuard {
  /// Does [workerText] name anything unsafe?
  ///
  /// Returns `true` when it does, `false` when it demonstrably does not, and
  /// `null` when this guard has no business judging — mixed or non-Latin script,
  /// or too few words to read. Callers MUST treat `null` as "not checked" and
  /// leave the model's verdict alone; reading it as either verdict is the bug
  /// this three-state return exists to prevent.
  static bool? hazardSignalInText(String workerText) {
    final text = workerText.trim();
    if (text.length < 8) return null;

    // Script check before vocabulary check. Counting letters rather than all
    // characters so that digits, punctuation and spaces — which are shared by
    // both scripts — cannot dilute the ratio and make Devanagari text look
    // Latin enough to judge.
    var latinLetters = 0;
    var otherLetters = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
        latinLetters++;
      } else if (rune > 0x7F && !_isPunctuationOrSymbol(rune)) {
        otherLetters++;
      }
    }
    final letters = latinLetters + otherLetters;
    if (letters < 6) return null;
    // 15%: enough to let a stray accented character or a single Hindi word in a
    // mostly-English sentence through, not enough to let a Hindi report be
    // judged against an English list.
    if (otherLetters / letters > 0.15) return null;

    final tokens = text
        .toLowerCase()
        .split(RegExp(r"[^a-z0-9]+"))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length < 3) return null;

    // Second language gate: romanised Hindi. Exact match, not startsWith — these
    // are two- and three-letter words and a prefix match would swallow half the
    // English dictionary ("kar" would take "career", "me" would take "metal").
    //
    // THIS LOOP MUST STAY ABOVE THE STEM LOOP. The two vocabularies overlap by
    // accident: "hota", "hoti" and "hote" all begin with the hazard stem "hot",
    // so a Hindi sentence containing the commonest verb in the language would
    // otherwise be reported as naming a heat hazard. Checked in this order, it
    // correctly returns null instead.
    for (final token in tokens) {
      if (_romanHindiMarkers.contains(token)) return null;
    }

    for (final token in tokens) {
      for (final stem in _hazardStems) {
        if (token.startsWith(stem)) return true;
      }
    }
    return false;
  }

  /// Devanagari and most Indic scripts sit above U+0900; this only needs to
  /// exclude the common non-letter characters above ASCII that would otherwise
  /// be counted as foreign letters — curly quotes, dashes, the rupee sign, the
  /// degree sign, non-breaking space.
  static bool _isPunctuationOrSymbol(int rune) {
    if (rune == 0x00A0 || rune == 0x00B0 || rune == 0x00B7) return true;
    if (rune >= 0x2000 && rune <= 0x206F) return true; // general punctuation
    if (rune >= 0x20A0 && rune <= 0x20BF) return true; // currency symbols
    if (rune >= 0x2100 && rune <= 0x2BFF) return true; // symbols, arrows, shapes
    return false;
  }

  /// Hindi words in Latin script. Their presence means the guard is looking at
  /// romanised Hindi and must not judge it against an English vocabulary.
  ///
  /// Mostly function words and verb endings, because those are what a Hindi
  /// sentence cannot do without. Two kinds of word are deliberately EXCLUDED
  /// even though they are common Hindi: anything that is also a common English
  /// word — the (were), me, to, is, us, hum, hi, band, sir, na — because one of
  /// those in an English report would switch the guard off for every report. A
  /// missing marker only costs a little accuracy; a marker that fires on English
  /// costs the whole guard.
  static const Set<String> _romanHindiMarkers = <String>{
    // particles, postpositions, conjunctions
    'ka', 'ki', 'ke', 'ko', 'se', 'mein', 'aur', 'par', 'lekin', 'kyunki',
    'kyun', 'liye', 'bhi', 'jab', 'tab', 'phir', 'abhi', 'baad', 'pehle',
    'wapas', 'kuch', 'koi', 'sab', 'sabhi', 'yahan', 'wahan', 'jahan', 'aisa',
    'aise', 'itna', 'bahut', 'zyada', 'kam',
    // copula and common verb forms
    'hai', 'hain', 'tha', 'thi', 'thay', 'raha', 'rahi', 'rahe', 'hua', 'hui',
    'huye', 'gaya', 'gayi', 'gaye', 'nahi', 'nahin', 'kar', 'karna', 'karne',
    'karta', 'karti', 'karte', 'kiya', 'kiye', 'diya', 'dena', 'dekha',
    'dekhna', 'mila', 'laga', 'lagi', 'lage', 'gira', 'girne', 'chal',
    'chalna', 'chalte', 'hokar', 'hone', 'hota', 'hoti', 'hote',
    // possessives and pronouns that are not English words
    'apna', 'apne', 'uska', 'uski', 'unka', 'unke', 'iska', 'iski', 'mera',
    'meri', 'tumhara', 'aapka', 'humne', 'usne', 'unhone',
    // everyday nouns and adjectives that recur in spoken reports
    // ('log', 'logon' and 'pair' belong here in Hindi and are left out: "log
    // book", "log the reading" and "a pair of gloves" are ordinary English in
    // this domain, and a Hindi speaker will always supply another marker.)
    'aadmi', 'admi', 'mazdoor', 'kaam', 'kaamgar', 'jagah',
    'samay', 'upar', 'niche', 'andar', 'bahar', 'haath', 'aankh',
    'tel', 'pani', 'aag', 'bijli', 'gaadi', 'seedhi', 'chhat', 'deewar',
    'aawaz', 'garam', 'thanda', 'bhaari', 'halka', 'toota', 'tuta', 'khula',
    'kharab', 'theek', 'sahi', 'galat', 'saaf', 'safai', 'dhyan', 'chot',
    'khatra', 'khatarnak', 'suraksha', 'ghatna', 'darr',
  };

  /// Word beginnings that mean the worker has named something unsafe.
  ///
  /// Stems, not words: matched with `startsWith`, so `slip` covers slipped,
  /// slippery and slipping, and no inflection table is needed. Grouped by what
  /// they are, because the way this list fails is by omission and a reviewer can
  /// only spot an omission within a group.
  ///
  /// Over-inclusion is harmless (see the file header) so borderline words are
  /// kept. What must NOT be added is anything so common that every sentence
  /// matches — a stem like `no` or `not` would silence the guard entirely.
  static const List<String> _hazardStems = <String>[
    // ── substances, states of matter, housekeeping ──
    'oil', 'grease', 'lubric', 'water', 'wet', 'damp', 'slip', 'spill', 'leak',
    'drip', 'seep', 'mud', 'slurry', 'sludge', 'dust', 'fume', 'smoke', 'smok',
    'steam', 'gas', 'vapour', 'vapor', 'acid', 'alkali', 'caustic', 'chemical',
    'solvent', 'toxic', 'poison', 'asbest', 'silica', 'hot', 'heat', 'molten',
    'cold', 'cryo', 'sharp', 'jagged', 'burr', 'rust', 'corrod', 'crack',
    'broke', 'break', 'damag', 'defect', 'fault', 'worn', 'torn', 'loose',
    'unsecure', 'unstable', 'wobbl', 'tilt', 'sag', 'bulg', 'missing', 'absent',
    'expos', 'bare', 'uncover', 'unguard', 'uneven', 'pothole', 'hole', 'pit',
    'trench', 'excavat', 'opening', 'gap', 'obstruct', 'block', 'congest',
    'clutter', 'debris', 'scrap', 'waste', 'garbage', 'housekeep', 'dark',
    'unlit', 'light', 'noise', 'vibrat', 'odour', 'odor', 'stink',

    // ── plant, equipment, stored energy ──
    'crane', 'hoist', 'sling', 'shackle', 'chain', 'rope', 'wire', 'cable',
    'load', 'lift', 'forklift', 'trolley', 'wagon', 'locomot', 'rail', 'track',
    'truck', 'vehicle', 'tractor', 'dumper', 'tipper', 'excavator', 'conveyor',
    'belt', 'pulley', 'roller', 'gear', 'shaft', 'coupling', 'motor', 'pump',
    'fan', 'blower', 'compressor', 'valve', 'pipe', 'hose', 'duct', 'cylinder',
    'lpg', 'oxygen', 'acetylene', 'nitrogen', 'argon', 'ammonia', 'boiler',
    'furnace', 'converter', 'ladle', 'tundish', 'caster', 'mill', 'coke',
    'sinter', 'blast', 'slag', 'ingot', 'billet', 'bloom', 'coil', 'plate',
    'scaffold', 'ladder', 'stair', 'platform', 'walkway', 'gangway', 'grating',
    'handrail', 'railing', 'guard', 'barricade', 'fenc', 'height', 'elevat',
    'overhead', 'above', 'below', 'underneath', 'roof', 'girder', 'beam',
    'floor', 'ramp', 'sump', 'tank', 'vessel', 'drum', 'weld', 'grind', 'torch',
    'flame', 'spark', 'fire', 'explos', 'electr', 'conductor', 'panel',
    'switch', 'breaker', 'transformer', 'busbar', 'volt', 'ampere', 'insulat',
    'earthing', 'short', 'pressur', 'vacuum',

    // ── PPE and procedure ──
    'ppe', 'helmet', 'hardhat', 'glove', 'goggle', 'shield', 'mask',
    'respirator', 'apron', 'harness', 'lanyard', 'boot', 'shoe', 'earplug',
    'earmuff', 'vest', 'wear', 'permit', 'ptw', 'loto', 'lockout', 'tagout',
    'isolat', 'safety', 'without', 'unauthor', 'untrained', 'bypass',
    'override', 'shortcut', 'sign',

    // ── behaviour that is itself the hazard ──
    'speed', 'rush', 'run', 'jump', 'climb', 'lean', 'reach', 'overload',
    'overreach', 'horseplay', 'quarrel', 'fight', 'drunk', 'alcohol',
    'intoxicat', 'sleep', 'mobile', 'phone', 'distract',

    // ── harm, and events that nearly caused it ──
    'fall', 'fell', 'trip', 'stumbl', 'collaps', 'overturn', 'topple', 'derail',
    'drop', 'swing', 'swung', 'hit', 'struck', 'strike', 'collid', 'crash',
    'jam', 'trap', 'caught', 'entangl', 'pinch', 'crush', 'severe', 'severed',
    'amput', 'cut', 'lacerat', 'punctur', 'burn', 'scald', 'blister', 'shock',
    'electrocut', 'asphyx', 'suffocat', 'choke', 'inhal', 'splash', 'spray',
    'eject', 'rupture', 'burst', 'releas', 'escap', 'injur', 'hurt', 'wound',
    'bleed', 'fractur', 'accident', 'incident', 'hazard', 'danger', 'risk',
    'unsafe', 'emergency', 'casualt', 'fatal', 'death', 'died', 'nearly',
    'almost', 'narrow', 'avoid',
  ];
}
