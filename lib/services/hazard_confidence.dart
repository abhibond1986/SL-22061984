/// Per-hazard confidence scoring.
///
/// Deliberately has NO Flutter or plugin imports. Everything here is pure
/// arithmetic over a set of observed signals, which means it can be exercised
/// directly with the standalone Dart VM — the scoring rules of a safety tool
/// should be testable without booting an emulator, because a silently wrong
/// adjustment here would mislead a safety officer rather than crash.
///
/// WHY ADJUST THE MODEL'S OWN NUMBER AT ALL
/// ----------------------------------------
/// The vision model reports its own certainty, which is the model grading its
/// own homework: it is confident in proportion to how fluent its answer felt,
/// not to whether the regulation it cited exists. So the model's figure is used
/// as the STARTING POINT and then moved by things the app can check
/// independently — whether the citation is real, whether it fits the subject,
/// whether visual evidence was actually given, whether the plant's own knowledge
/// base corroborates it.
///
/// Adjustments are bounded and always itemised in [ConfidenceReason]s, so a
/// score can be explained to the person reading the report. An unexplainable
/// number would be worse than no number.
library;

/// One reason a hazard's confidence moved, for display and for audit.
class ConfidenceReason {
  const ConfidenceReason(this.label, this.delta, {this.severe = false});

  /// Human-readable, shown verbatim in the UI. Written for a safety officer,
  /// not a developer.
  final String label;

  /// Points added or removed. Zero is allowed: some reasons are informational
  /// (they explain a score without changing it).
  final int delta;

  /// Marks a reason that should be surfaced prominently even when the resulting
  /// score is still highish — an invented citation matters regardless.
  final bool severe;

  Map<String, dynamic> toJson() =>
      {'label': label, 'delta': delta, if (severe) 'severe': true};
}

/// What the validator managed to determine about one hazard.
class HazardSignals {
  const HazardSignals({
    this.modelConfidence,
    this.reportConfidence,
    this.hasVisualEvidence = false,
    this.evidenceLooksGeneric = false,
    this.descriptionStartsWithVisible = false,
    this.citationPresent = false,
    this.citationInCatalogue = false,
    this.citationInKnowledgeBase = false,
    this.citationBanned = false,
    this.citationMisapplied = false,
    this.topicalFit,
    this.kbCorroborated = false,
    this.severityKnown = true,
    this.typeKnown = true,
    this.wsaCauseKnown,
    this.hasUsableBbox = true,
    this.evidenceUngrounded,
    this.findingIsBoilerplate = false,
  });

  /// The model's own per-hazard figure, if it supplied one.
  final int? modelConfidence;

  /// Report-level figure, used only as a fallback starting point.
  final int? reportConfidence;

  final bool hasVisualEvidence;

  /// Evidence text that hedges instead of describing ("typically found",
  /// "not visible but..."). Present-but-generic is worse than absent, because it
  /// looks like proof at a glance.
  final bool evidenceLooksGeneric;

  final bool descriptionStartsWithVisible;

  final bool citationPresent;

  /// Found in the closed catalogue the model was told to cite from.
  final bool citationInCatalogue;

  /// Not in the catalogue but present in the plant's own uploaded standards,
  /// which are equally citable.
  final bool citationInKnowledgeBase;

  /// Barred at hazard level, e.g. an audit standard cited for one finding.
  final bool citationBanned;

  /// Cited for a subject the reference explicitly does not cover.
  final bool citationMisapplied;

  /// Whether the hazard's subject matches what the citation covers. Null means
  /// the catalogue expresses no opinion, which must not be read as a mismatch.
  final bool? topicalFit;

  /// The knowledge base independently discusses this hazard.
  final bool kbCorroborated;

  final bool severityKnown;
  final bool typeKnown;

  /// Null when the provider does not emit a WSA cause at all.
  final bool? wsaCauseKnown;

  final bool hasUsableBbox;

  /// The hazard's stated visual evidence names nothing that appears in the
  /// model's own scene inventory — the one self-consistency check available
  /// inside a single response. Null when the model returned no inventory, which
  /// must score as "not checked" rather than as a pass or a failure.
  ///
  /// Treated as a strong negative signal rather than a disqualifying one. The
  /// check is crude word overlap, and a hazard can be real while described in
  /// vocabulary that misses the inventory entirely; what it cannot be is
  /// something a safety officer should read without being told.
  final bool? evidenceUngrounded;

  /// The finding would fit any steel-plant photograph — it names no object, no
  /// location and no specific deviation. Scored separately from
  /// [evidenceLooksGeneric] because the failure is different: hedged evidence
  /// admits its own weakness, whereas boilerplate states a definite-sounding
  /// conclusion about nothing in particular, and reads as a real finding until
  /// someone tries to act on it.
  final bool findingIsBoilerplate;
}

class HazardConfidence {
  HazardConfidence._();

  /// Used when neither the hazard nor the report carried a figure. Sits below
  /// the review threshold on purpose: a model that would not say how sure it is
  /// has not earned a confident-looking badge.
  static const int neutralBase = 55;

  /// At or below this, the hazard is marked as needing a human check.
  static const int reviewThreshold = 60;

  /// Scores never reach 0 or 100. A hazard is shown to a human either way, so
  /// 0 would imply "certainly false" — which the app cannot know — and 100 would
  /// imply the app has verified reality rather than paperwork.
  static const int floor = 5;
  static const int ceiling = 97;

  /// Ceiling applied when a hazard has a DISQUALIFYING defect — no visual
  /// evidence, hedged evidence, or a citation that is barred or misapplied.
  ///
  /// Deltas alone were not enough. A model claiming 95 with no evidence at all
  /// still landed at 83, which reads as trustworthy at a glance even though the
  /// one thing the prompt calls REQUIRED is missing. Subtraction lets a
  /// sufficiently confident model out-shout the evidence; a cap does not.
  /// Set just below [reviewThreshold] so such a hazard can never present itself
  /// as needing no review.
  static const int defectCeiling = 55;

  /// Ceiling for a citation that simply could not be vouched for. Softer than
  /// [defectCeiling] because the plant may just not have uploaded the standard
  /// yet — the hazard itself may be perfectly real.
  static const int unverifiedCitationCeiling = 75;

  /// Computes the adjusted confidence and the itemised reasons behind it.
  static ({int confidence, String basis, List<ConfidenceReason> reasons})
      score(HazardSignals s) {
    final reasons = <ConfidenceReason>[];

    int base;
    String basis;
    if (s.modelConfidence != null) {
      base = s.modelConfidence!.clamp(0, 100);
      basis = 'model';
    } else if (s.reportConfidence != null) {
      // Falling back to the report figure is flagged as such: it is the same
      // number on every hazard, so it says nothing about this one.
      base = s.reportConfidence!.clamp(0, 100);
      basis = 'report';
      reasons.add(const ConfidenceReason(
          'Model gave no per-hazard score — using the report-level figure', 0));
    } else {
      base = neutralBase;
      basis = 'default';
      reasons.add(const ConfidenceReason('Model gave no confidence score', 0));
    }

    int score = base;
    void apply(String label, int delta, {bool severe = false}) {
      if (delta == 0) {
        reasons.add(ConfidenceReason(label, 0, severe: severe));
        return;
      }
      score += delta;
      reasons.add(ConfidenceReason(label, delta, severe: severe));
    }

    // ── Citation ───────────────────────────────────────────────────────────
    if (s.citationBanned) {
      apply('Citation is not valid for a single hazard', -30, severe: true);
    } else if (!s.citationPresent) {
      apply('No regulation cited', -8);
    } else if (s.citationMisapplied) {
      // The worst case: a real section number attached to the wrong subject. It
      // survives review more easily than an invented one because it looks
      // correct, so it is penalised hardest.
      apply('Regulation cited does not cover this subject', -30, severe: true);
    } else if (s.citationInCatalogue) {
      apply('Regulation verified against the citable table', 8);
      if (s.topicalFit == false) {
        apply('Regulation is real but an odd fit for this hazard', -12);
      }
    } else if (s.citationInKnowledgeBase) {
      apply('Regulation matched in the plant knowledge base', 6);
    } else {
      apply('Regulation could not be verified', -15, severe: true);
    }

    // ── Evidence ───────────────────────────────────────────────────────────
    if (!s.hasVisualEvidence) {
      apply('No visual evidence given', -20, severe: true);
    } else if (s.evidenceLooksGeneric) {
      apply('Evidence is generic, not specific to this image', -18,
          severe: true);
    } else {
      apply('Visual evidence provided', 4);
    }
    if (!s.descriptionStartsWithVisible && s.hasVisualEvidence) {
      // Minor: the content can still be sound when the required opening phrase
      // is missing, so this is a nudge and not a verdict.
      apply('Description does not open with what is visible', -3);
    }

    // ── Grounding against the model's own scene inventory ──────────────────
    // Only meaningful when an inventory came back; null is silent rather than
    // neutral-with-a-reason, because a line saying "not checked" on every
    // hazard from a tier that never returns one is noise a safety officer has
    // to read past on every report.
    if (s.evidenceUngrounded == true) {
      apply('Evidence names nothing the model itself listed as visible', -22,
          severe: true);
    } else if (s.evidenceUngrounded == false) {
      apply('Evidence matches the model\'s own list of what is visible', 5);
    }

    // ── Specificity ────────────────────────────────────────────────────────
    // Kept separate from the evidence checks: a boilerplate finding can arrive
    // with a perfectly concrete evidence string attached, and the finding is
    // still unusable because the name and description name nothing.
    if (s.findingIsBoilerplate) {
      apply('Finding is generic enough to fit any plant photograph', -20,
          severe: true);
    }

    // ── Independent corroboration ──────────────────────────────────────────
    if (s.kbCorroborated) {
      apply('Corroborated by the plant knowledge base', 6);
    }

    // ── Vocabulary and geometry ────────────────────────────────────────────
    if (!s.severityKnown) apply('Severity label is not one the app uses', -6);
    if (!s.typeKnown) apply('Observation type is not one the app uses', -4);
    if (s.wsaCauseKnown == false) {
      apply('WSA cause does not match the configured list', -4);
    }
    if (!s.hasUsableBbox) apply('No usable location marked on the image', -3);

    // ── Caps ───────────────────────────────────────────────────────────────
    // Applied after the deltas so they act as a hard limit rather than another
    // subtraction the model's own optimism can absorb.
    int cap = ceiling;
    String? capLabel;
    if (!s.hasVisualEvidence || s.evidenceLooksGeneric) {
      cap = defectCeiling;
      capLabel = 'Capped: a hazard without specific visual evidence cannot be '
          'rated highly';
    } else if (s.findingIsBoilerplate) {
      // Capped rather than only penalised, for the same reason as missing
      // evidence: a model asserting 95 on "PPE not worn — risk of injury"
      // otherwise still lands in the seventies and presents itself as a finding
      // that needs no checking. The text is the defect, whatever the model
      // thinks of it.
      cap = defectCeiling;
      capLabel = 'Capped: the finding names no object, place or specific '
          'deviation';
    } else if (s.evidenceUngrounded == true) {
      // Softer than [defectCeiling]: the check is word overlap on two short
      // strings, so it is capable of being wrong about a real hazard. It still
      // must not sit above the review line.
      cap = unverifiedCitationCeiling;
      capLabel = 'Capped: evidence does not match what the model said it could '
          'see';
    } else if (s.citationBanned || s.citationMisapplied) {
      cap = defectCeiling;
      capLabel = 'Capped: the regulation cited is wrong for this hazard';
    } else if (s.citationPresent &&
        !s.citationInCatalogue &&
        !s.citationInKnowledgeBase) {
      cap = unverifiedCitationCeiling;
      capLabel = 'Capped: the regulation cited could not be found';
    }
    if (capLabel != null && score > cap) {
      reasons.add(ConfidenceReason(capLabel, cap - score, severe: true));
      score = cap;
    }

    return (
      confidence: score.clamp(floor, ceiling),
      basis: basis,
      reasons: reasons,
    );
  }

  /// Whether a scored hazard should be flagged for a human check. Kept beside
  /// the scoring so the badge and the threshold can never disagree.
  static bool needsReview(int confidence, HazardSignals s) =>
      confidence <= reviewThreshold ||
      s.citationBanned ||
      s.citationMisapplied ||
      !s.hasVisualEvidence ||
      s.evidenceLooksGeneric ||
      s.findingIsBoilerplate ||
      s.evidenceUngrounded == true ||
      (s.citationPresent &&
          !s.citationInCatalogue &&
          !s.citationInKnowledgeBase);
}
