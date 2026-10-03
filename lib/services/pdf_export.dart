// lib/services/pdf_export.dart
// SAIL Safety Lens — branded PDF report generator
// ✅ All existing functionality preserved
// ✅ NEW: Hazard bounding-box overlays on the evidence photograph
//    Reads `bbox` per hazard as either {x,y,w,h} OR {x,y,width,height}
//    Coordinates are normalized 0–1, top-left origin.
//    Each box is severity-coloured with a numbered tag matching the
//    "#" column in the hazards table below.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'admin_master_data.dart';
import 'hazard_quality.dart';
import 'image_storage.dart';
import 'line_of_fire.dart';
import 'pdf_export_stub.dart' if (dart.library.html) 'pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

class PdfExport {
  static final PdfColor _sailBlue    = PdfColor.fromHex('#0D47A1');
  static final PdfColor _critCol     = PdfColor.fromHex('#C62828');
  static final PdfColor _critBg      = PdfColor.fromHex('#FFEBEE');
  static final PdfColor _highCol     = PdfColor.fromHex('#E65100');
  static final PdfColor _highBg      = PdfColor.fromHex('#FFF3E0');
  static final PdfColor _medCol      = PdfColor.fromHex('#00838F');
  static final PdfColor _medBg       = PdfColor.fromHex('#E0F7FA');
  static final PdfColor _lowCol      = PdfColor.fromHex('#2E7D32');
  static final PdfColor _lowBg       = PdfColor.fromHex('#E8F5E9');
  static final PdfColor _textDark    = PdfColor.fromHex('#212121');
  static final PdfColor _textMed     = PdfColor.fromHex('#616161');
  static final PdfColor _rowAlt      = PdfColor.fromHex('#F5F8FC');
  static final PdfColor _rowNorm     = PdfColors.white;
  // ★ 2026-10-03 report redesign. A restrained ink/navy/steel set: navy for
  // structure, severity colours ONLY where they carry meaning, and soft
  // panels + hairlines instead of heavy boxes.
  static final PdfColor _navyDeep    = PdfColor.fromHex('#0A2E6E');
  static final PdfColor _ink         = PdfColor.fromHex('#1B2433');
  static final PdfColor _steel       = PdfColor.fromHex('#5B6B82');
  static final PdfColor _hair        = PdfColor.fromHex('#D9E0EA');
  static final PdfColor _panel       = PdfColor.fromHex('#F4F7FB');
  static const pw.BorderRadius _r3   = pw.BorderRadius.all(pw.Radius.circular(3));

  // ─── MAIN ENTRY ──────────────────────────────────────────────────────────
  static Future<Uint8List> generateIncidentReportBytes({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
    Uint8List? imageBytes,
  }) async {
    final pdf = pw.Document();
    final dateStr = DateFormat('dd MMM yyyy, HH:mm').format(
      DateTime.parse(incident['date'] ?? DateTime.now().toIso8601String()));

    // ★ v28: Load SAIL Safety Lens logo for PDF header
    pw.MemoryImage? logoImage;
    try {
      final logoData = await rootBundle.load('assets/images/app_icon.png');
      logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
      _cachedLogo = logoImage; // Cache for page headers (pages 2+)
    } catch (_) {
      // Logo load failed — will use text fallback
    }

    Uint8List? imgBytes = imageBytes;
    if (imgBytes == null && incident['imageBase64'] != null) {
      try { imgBytes = base64Decode(incident['imageBase64'].toString()); } catch (_) {}
    }
    // Defense-in-depth: if the caller didn't pass bytes and there's no inline
    // base64 (stripped on mobile), resolve from file storage via imageRef.
    // Guarantees the evidence photo appears regardless of how it was saved.
    if (imgBytes == null) {
      try {
        imgBytes = await ImageStorage.getImageForIncident(incident);
      } catch (_) {}
    }

    List<Map<String, dynamic>> hazards = _parseHazards(incident['hazards']);
    String summary = _cleanSummary(incident);

    // ?? 'MEDIUM' until 2026-09-21. A row with no stored severity printed a
    // MEDIUM badge and a MEDIUM-banded score on paper — the one copy of the
    // report that outlives the app and carries no caveat. 'UNKNOWN' is the
    // canonical non-assessment label (AdminMasterData._kNoAssessmentLabels) and
    // scores 0, so an unrated row prints as unrated.
    var severity     = () {
      final s = incident['severity']?.toString().trim() ?? '';
      return s.isEmpty ? 'UNKNOWN' : s;
    }();
    final isAiScan   = incident['type']?.toString() == 'AI_SCAN';
    // ── WAS THIS PHOTO ACTUALLY ANALYSED? ────────────────────────────────────
    //
    // Defence in depth for rows the app can no longer refuse to create: reports
    // already filed by an older build, and rows arriving from another device.
    // The scan screen now blocks saving an unanalysed scan at source, but this
    // exporter is reached by the incident log's own PDF button, where the only
    // evidence available is the stored row.
    //
    // Three independent tells, any one of which is sufficient:
    //
    //  1. `aiAnalysed == false` — the flag, for rows written after this change.
    //     String-tolerant because Apps Script hands booleans back as "false",
    //     and `== false` on a String is silently untrue.
    //  2. An AI_SCAN with no hazards and no real severity — today's failure
    //     shape, for any row that slipped through before the save guard existed.
    //  3. The failure sentence in the summary. This is the only tell that
    //     catches the reports that caused this work: they were filed by a build
    //     whose offline fallback emitted a generic 12-item checklist, so they
    //     carry HIGH severity and 12 hazard rows and look fully analysed by
    //     tells 1 and 2. Their summary still says so, in either the old wording
    //     ("AI Vision models unavailable") or the current one ("This image was
    //     NOT analysed"), and matching it demotes those rows on re-export.
    //
    //     ⚠ MATCH THE WHOLE SENTENCE, NOT "WAS NOT ANALYSED". The loose
    //     substring was tried first and is wrong: a GENUINE report whose summary
    //     reads "...the far bay was not analysed in detail" matches it, and this
    //     predicate then voids a real severity and drops a real hazard table —
    //     the mirror image of the bug being fixed, and worse, because it hides
    //     findings that exist. These two strings are emitted verbatim by
    //     GeminiVision._offlineFallback and by the pre-2026-08-14 build; if that
    //     wording changes, tells 1 and 2 are what carry the load, so this stays
    //     narrow on purpose. Also gated on `isAiScan` — a near-miss narrative is
    //     free text and must never be pattern-matched for a failure sentence.
    final summaryTell = summary.toUpperCase();
    final summarySaysFailed = isAiScan &&
        (summaryTell.contains('AI VISION MODELS UNAVAILABLE') ||
         summaryTell.contains('THIS IMAGE WAS NOT ANALYSED'));
    final notAnalysed = incident['aiAnalysed'] == false ||
        incident['aiAnalysed']?.toString().toLowerCase() == 'false' ||
        summarySaysFailed ||
        (isAiScan &&
            hazards.isEmpty &&
            AdminMasterData.severityRating(const {}, severity) == 0);

    // ★ NEUTRALISE AT SOURCE, DO NOT BRANCH AT EVERY WIDGET.
    //
    // Every figure below is derived from `severity`, `hazards` and `confidence`,
    // and the page is assembled from ~8 widgets that each read some of them. If
    // this were an `if (notAnalysed)` at each render site, the next section
    // someone adds would print the un-neutralised value by default and nobody
    // would notice — which is precisely how the original defect survived: the
    // screen suppressed the hazard table while the PDF and the share text, built
    // from the same map, kept printing it.
    //
    // Zeroing here means the existing "unrated" rendering does the work: the
    // severity pill reads UNKNOWN, `matrixScore == 0` prints "—  NOT RATED",
    // `scoreForDisplay` returns 0, and `hazards.isEmpty` takes the no-table
    // branch. The reader is told why by `_notAnalysedNotice` below.
    if (notAnalysed) {
      severity = 'UNKNOWN';
      // Dropped, not printed under a caveat. These rows are either absent
      // (today's failure) or generic checklist items an older build synthesised
      // without ever reading the photograph; on paper, beside an evidence
      // photograph and above a signature block, a labelled list of severities
      // and regulations still reads as findings about that photograph.
      hazards = <Map<String, dynamic>>[];
    }
    // Reconciled ONCE, here, so the banner, the score block and anything added
    // later all print the same figure. See AdminMasterData.scoreForDisplay for the
    // "23 / 100 beside RISK: CRITICAL" report that made this necessary — the rule
    // lives there because the screens have to obey it too, and a stored incident
    // exported months later still carries the number it was filed with.
    final riskScore  = notAnalysed
        ? 0
        : AdminMasterData.scoreForDisplay(severity, incident['riskScore'] ?? 0);
    // 0, never the stored figure: confidence also feeds the likelihood axis via
    // likelihoodFromConfidence, so a stale 35 here would rebuild a real-looking
    // L×S score for a photo nothing assessed.
    final confidence = notAnalysed ? 0 : (incident['confidence'] ?? 0);
    // ── The 1–25 initial risk estimate, when the row carries one ────────────
    //
    // Read from the stored L and S and MULTIPLIED HERE rather than trusting a
    // stored `matrixScore`, so the printed product always agrees with the two
    // factors printed beside it — a stored total and stored factors can drift
    // apart, and on paper there is no way to tell which one is wrong.
    //
    // Absent on every row filed before this feature, and on near-miss rows, so
    // it is strictly additive: `matrixScore == 0` keeps the old 0–100 block
    // exactly as it was. A legacy report must not silently re-render on a scale
    // it was never filed against.
    // `num.tryParse(...)?.round()`, not `int.tryParse`: Apps Script hands back
    // "4.0" for an integer cell, which `int.tryParse` rejects.
    int axis(dynamic v) => num.tryParse('${v ?? 0}')?.round() ?? 0;
    var mL = axis(incident['matrixLikelihood']);
    var mS = axis(incident['matrixSeverity']);
    // String-tolerant: the field is a bool in the local row but comes back from
    // Apps Script as the text "true", and `== true` on a String is silently
    // false — which would drop the "(est.)" qualifier from every synced report
    // while keeping it on every local one.
    final rawEst = incident['matrixLikelihoodEstimated'];
    var matrixEstimated =
        rawEst == true || rawEst.toString().toLowerCase() == 'true';

    // ★ RE-DERIVE THE MATRIX WHEN THE ROW DOES NOT CARRY IT.
    //
    // The matrix fields are written by the scan screen but they do NOT survive a
    // server round-trip: `SupabaseService._appToDb` is an allow-list with no
    // `matrix*` entries, and `_toRow`/`_fromRow` silently drop unmapped keys. So
    // the same incident would export "12 / 25" on the device that filed it and
    // "45 / 100" on every other device — the cross-device class of defect this
    // repo has been bitten by before, and worse here because both numbers look
    // plausible.
    //
    // Rather than add columns, re-derive from the two fields that DO sync:
    // `severity` gives the severity rating and `confidence` gives the estimated
    // likelihood, which is exactly how the screen produced the defaults in the
    // first place. The result is therefore identical to the filing device's
    // unless the officer hand-picked an axis — and that case is marked, because
    // a re-derived likelihood is by definition an estimate and says so.
    //
    // Gated on `isAiScan`: a near-miss row has a real 0–100 score of its own and
    // must keep printing it, not acquire a matrix it was never rated on.
    //
    // ALSO gated on `!notAnalysed` — 2026-09-21. This block exists to RECOVER a
    // matrix that a sync dropped, and it is the one place that would rebuild one
    // from nothing: a legacy unanalysed row carries a stored mL/mS of 0, which is
    // exactly the trigger condition, so without this gate the re-derivation would
    // hand an unassessed photo a fresh L×S score and mark it merely "(est.)".
    // Neutralising `severity` and `confidence` above already starves it — both
    // helpers return 0 — but relying on that would make the guard depend on two
    // distant assignments staying zero.
    if (isAiScan && !notAnalysed && AdminMasterData.matrixScore(mL, mS) == 0) {
      final scores = await AdminMasterData.getSeverityScores();
      if (mS == 0) mS = AdminMasterData.severityRating(scores, severity);
      if (mL == 0) {
        mL = AdminMasterData.likelihoodFromConfidence(confidence);
        if (mL > 0) matrixEstimated = true;
      }
    }
    if (notAnalysed) { mL = 0; mS = 0; matrixEstimated = false; }
    final matrixScore = AdminMasterData.matrixScore(mL, mS);

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 32),
      header: (ctx) => _pageHeader(ctx.pageNumber > 1),
      footer: (ctx) => _pageFooter(
          ctx.pageNumber, ctx.pagesCount, _refNo(incident), dateStr),
      // ─── ONE-PAGE LAYOUT ───────────────────────────────────────────────
      // Target: the whole report on page 1. Every spacer below is deliberately
      // tight (10pt between sections, 4pt under a section title) — these were
      // 18pt and 6pt, which alone pushed ~55pt of whitespace onto a second
      // page. If you add a section here, keep to the same budget.
      build: (context) {
        final w = <pw.Widget>[];
        w.add(_banner(incident, severity, isAiScan, riskScore, confidence, logoImage));
        // Immediately under the severity badge, not in a footnote: if the
        // photograph is a general view, the severity above it is capped and
        // provisional, and the reader has to know that before reading anything
        // else. See HazardQuality.capSeverityForView.
        // Before the view caveat and before the details grid: if nothing
        // assessed this photograph, that fact outranks every other qualification
        // on the page, including the general-view caveat (which qualifies a
        // severity that no longer exists here).
        if (notAnalysed) {
          w.add(pw.SizedBox(height: 5));
          w.add(_notAnalysedNotice());
        }
        final viewCaveat = incident['viewCaveat']?.toString().trim() ?? '';
        if (viewCaveat.isNotEmpty && !notAnalysed) {
          w.add(pw.SizedBox(height: 5));
          w.add(_caveatBar(viewCaveat));
        }
        w.add(pw.SizedBox(height: 10));
        w.add(_sectionTitle('INCIDENT DETAILS'));
        w.add(pw.SizedBox(height: 4));
        w.add(_detailsGrid(incident, dateStr, reporterName, reporterPno));
        w.add(pw.SizedBox(height: 10));
        if (imgBytes != null) {
          w.add(_sectionTitle('EVIDENCE PHOTOGRAPH  &  INCIDENT SUMMARY'));
          w.add(pw.SizedBox(height: 4));
          // Close-ups sit INSIDE the summary column (which otherwise has
          // blank space beside a tall photo) rather than in their own band.
          final closeUps = _closeUps(imgBytes, hazards);
          w.add(_photoAndSummary(imgBytes, hazards.length, summary,
              severity, riskScore, confidence, hazards,
              verifyCount: _verifyOnSiteCount(incident),
              matrixL: mL, matrixS: mS,
              matrixScore: matrixScore,
              matrixEstimated: matrixEstimated,
              matrixApplies: isAiScan,
              analysed: !notAnalysed,
              closeUps: closeUps));
          w.add(pw.SizedBox(height: 10));
        } else {
          w.add(_sectionTitle('INCIDENT SUMMARY'));
          w.add(pw.SizedBox(height: 4));
          w.add(_summaryBox(summary));
          w.add(pw.SizedBox(height: 10));
        }
        if (hazards.isNotEmpty) {
          w.add(_sectionTitle('HAZARDS IDENTIFIED  —  ${hazards.length} TOTAL'));
          w.add(pw.SizedBox(height: 4));
          w.add(_hazardsTable(hazards));
          // NOTE: the TOTAL RISK SCORE / OVERALL RISK bar used to be added here.
          // It was a verbatim duplicate of the risk score already shown in the
          // right-hand panel of _photoAndSummary (and of the severity pill in
          // the banner), and being ~100pt tall it was the single biggest reason
          // the report ran to a second page. Removed deliberately — do not
          // re-add it. The page-1 panel is the one source of the score.
          w.add(pw.SizedBox(height: 10));
          w.addAll(_verifyOnSiteSection(incident));
        } else {
          // No confirmed hazards. The verify list may still have content, and on
          // this branch it is the only substantive finding section in the report,
          // so it must be added before the near-miss corrective-action box below.
          w.addAll(_verifyOnSiteSection(incident));
          // Near-miss reports have no hazards list, so the table above is
          // skipped — and with the IMMEDIATE CORRECTIVE ACTION box gone, the
          // reporter's own corrective action would appear NOWHERE in the PDF.
          // For an AI scan that box was duplication (the hazards table carries
          // the same text per hazard); for a near miss it is the only copy, and
          // it is user-entered, statutorily relevant content. So it is restored
          // for exactly the case that needs it, and only then — a report with a
          // hazards table has ~200pt less headroom and does not get this.
          final action = _safe(incident['immediateAction']?.toString() ?? '')
              .trim();
          if (action.isNotEmpty) {
            w.add(_sectionTitle('IMMEDIATE CORRECTIVE ACTION TAKEN'));
            w.add(pw.SizedBox(height: 4));
            w.add(_actionBox(action));
            w.add(pw.SizedBox(height: 10));
          }
        }
        // GPS is now a single compact strip rather than a ~145pt bordered card
        // with its own section title, because the coordinates and a Maps link
        // are all a reader needs.
        final gpsSection = _gpsLocationSection(incident);
        if (gpsSection != null) {
          w.add(gpsSection);
          w.add(pw.SizedBox(height: 10));
        }
        // NOTE: ROOT CAUSE ANALYSIS (WSA 13) and IMMEDIATE CORRECTIVE ACTION
        // used to be a two-column row here (~95pt with its spacer). Both were
        // pure duplication, which is why removing them costs the reader nothing:
        //   • The WSA box showed 'Category' and 'People involved' — both are
        //     already cells in _detailsGrid above ('WSA Category',
        //     'People Involved').
        //   • The corrective-action box showed the FIRST hazard's corrective
        //     action verbatim, which the CORRECTIVE ACTION column of the hazards
        //     table already lists for every hazard, not just one — but ONLY when
        //     there is a hazards table. Reports without one keep the box; see
        //     the else-branch above.
        // Do not re-add them for AI scans. If a genuinely new field is ever
        // needed, put it in _detailsGrid as a cell rather than another box.
        w.add(_signOff(reporterName, reporterPno));
        return w;
      },
    ));
    return pdf.save();
  }

  // ─── PAGE CHROME ─────────────────────────────────────────────────────────
  static pw.MemoryImage? _cachedLogo; // ★ v28: cache for page headers

  static pw.Widget _pageHeader(bool show) {
    if (!show) return pw.SizedBox();
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      margin: const pw.EdgeInsets.only(bottom: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _hair, width: 0.8))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Row(children: [
            if (_cachedLogo != null)
              pw.Container(width: 20, height: 20,
                child: pw.Image(_cachedLogo!, fit: pw.BoxFit.contain))
            else
              pw.Container(width: 18, height: 18, color: _sailBlue,
                alignment: pw.Alignment.center,
                child: pw.Text('SAIL', style: pw.TextStyle(
                  color: PdfColors.white, fontSize: 5,
                  fontWeight: pw.FontWeight.bold))),
            pw.SizedBox(width: 5),
            pw.Text('SAFETY LENS', style: pw.TextStyle(
              color: _sailBlue, fontSize: 8, fontWeight: pw.FontWeight.bold)),
          ]),
          pw.Text('Workplace Hazard Report  (continued)', style: pw.TextStyle(
            fontSize: 7, color: _steel)),
        ],
      ),
    );
  }

  static pw.Widget _pageFooter(int pg, int tot, String ref, String date) {
    final st = pw.TextStyle(fontSize: 6.5, color: _steel);
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.only(top: 5),
      decoration: pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _hair, width: 0.8))),
      child: pw.Row(
        children: [
          pw.Expanded(child: pw.Text(
            _safe('SAIL Safety Lens  ·  Ref. $ref  ·  $date'), style: st)),
          pw.Text('CONFIDENTIAL - INTERNAL USE', style: pw.TextStyle(
            fontSize: 6.5, color: _steel, letterSpacing: 0.6)),
          pw.Expanded(child: pw.Text('Page $pg of $tot',
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(fontSize: 6.5, color: _ink,
              fontWeight: pw.FontWeight.bold))),
        ],
      ),
    );
  }

  /// Short reference printed in the banner and on every footer.
  static String _refNo(Map<String, dynamic> inc) {
    final id = inc['id']?.toString() ?? '';
    if (id.isEmpty) return 'N/A';
    return (id.length > 8 ? id.substring(0, 8) : id).toUpperCase();
  }

  // ─── BANNER ──────────────────────────────────────────────────────────────
  /// A qualification that applies to the whole report, printed directly under the
  /// banner. Amber, bordered, and in body-size type: it has to compete with a
  /// coloured severity badge two lines above it, and a caveat nobody reads is the
  /// same as no caveat.
  static pw.Widget _caveatBar(String text) => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(9, 5, 9, 5),
    decoration: pw.BoxDecoration(
      color: PdfColor.fromHex('#FFF8E1'),
      borderRadius: _r3,
      border: pw.Border.all(color: PdfColor.fromHex('#F9A825'), width: 0.8)),
    child: pw.Text(_safe(text), style: pw.TextStyle(
      fontSize: 7.5, color: PdfColor.fromHex('#7A4F01'), lineSpacing: 1.2,
      fontWeight: pw.FontWeight.bold)),
  );

  /// The notice that replaces every rating on a report whose photograph was
  /// never assessed. Red rather than the amber of [_caveatBar], because this is
  /// not a qualification on a finding — it is the statement that there is no
  /// finding, and it has to survive being photocopied and initialled.
  ///
  /// Wording rule: say what did NOT happen, then what the reader should do.
  /// "Analysis unavailable" alone gets read as "analysed, nothing found".
  static pw.Widget _notAnalysedNotice() => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(9, 6, 9, 6),
    decoration: pw.BoxDecoration(
      color: PdfColor.fromHex('#FDECEA'),
      borderRadius: _r3,
      border: pw.Border.all(color: PdfColor.fromHex('#C62828'), width: 1.0)),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // _safe(): the em dashes in this notice printed as empty boxes.
        pw.Text(_safe('THIS PHOTOGRAPH WAS NOT ANALYSED — NOT A HAZARD ASSESSMENT'),
          style: pw.TextStyle(
            fontSize: 8, color: PdfColor.fromHex('#8E1B16'),
            fontWeight: pw.FontWeight.bold, letterSpacing: 0.3)),
        pw.SizedBox(height: 2),
        pw.Text(_safe(
          'The AI hazard scan did not complete, so no risk rating, risk score '
          'or hazard list has been produced for this image. Any rating shown '
          'elsewhere on this page is void. This document records only that a '
          'photograph was taken and that the scan failed — it must not be '
          'signed off as an inspection. Rescan the location, or raise the '
          'observation on the Near Miss form.'),
          style: pw.TextStyle(
            fontSize: 7.2, color: PdfColor.fromHex('#7A1512'), lineSpacing: 1.2)),
      ]),
  );

  // ─── TO VERIFY ON SITE ───────────────────────────────────────────────────
  /// Observations the analysis itself said this photograph could not confirm.
  ///
  /// These are **not** hazards and must never be counted as such — that is the
  /// entire reason `HazardQuality.auditUnverifiable` moves them out of `hazards`.
  /// They are still printed, because a distant corrosion lead is worth an
  /// inspector's time; it is just not a non-conformance yet. The distinction the
  /// reader must be able to make is "someone saw this" vs "someone should go and
  /// look", so the heading says TO VERIFY and the intro line says why they moved.
  ///
  /// Deliberately compact — one wrapped line per item in a single bordered box,
  /// no table grid and no per-row header, because the one-page budget documented
  /// in [build] leaves only ~40pt of slack once the hazards table is present.
  /// Returns an empty list (not a null widget) so both branches of `build` can
  /// `addAll` it unconditionally.
  static List<Map<String, dynamic>> _verifyOnSiteItems(
      Map<String, dynamic> inc) {
    final raw = inc[HazardQuality.kVerifyOnSiteKey];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final e in raw)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  static int _verifyOnSiteCount(Map<String, dynamic> inc) =>
      _verifyOnSiteItems(inc).length;

  static List<pw.Widget> _verifyOnSiteSection(Map<String, dynamic> inc) {
    final items = _verifyOnSiteItems(inc);
    if (items.isEmpty) return const <pw.Widget>[];

    final lines = <pw.Widget>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final name = _safe(it['name']?.toString().trim() ?? '');
      // The description is the useful part (it is what carries "distant view",
      // "silhouetted", the actual observation) but it is also long, so it is
      // clipped. correctiveAction is the fallback because a row can arrive with
      // an empty description; a numbered line with nothing after the dash would
      // read as a formatting bug.
      var detail = _safe(it['description']?.toString().trim() ?? '');
      if (detail.isEmpty) {
        detail = _safe(it['correctiveAction']?.toString().trim() ?? '');
      }
      if (detail.length > 240) detail = '${detail.substring(0, 240)}...';
      final loc = _safe(it['location']?.toString().trim() ?? '');
      final head = name.isEmpty ? 'Observation ${i + 1}' : name;
      if (i > 0) lines.add(pw.SizedBox(height: 3));
      lines.add(pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 13,
            child: pw.Text('${i + 1}.',
                style: pw.TextStyle(
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                    color: _textMed)),
          ),
          // Two stacked pw.Text widgets rather than one pw.RichText: RichText and
          // TextSpan appear nowhere else in this file, and with no Flutter/pdf
          // package resolvable in this environment their API cannot be checked
          // by the analyzer. Every widget used here is one the report already
          // renders successfully somewhere above.
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(loc.isEmpty ? head : '$head  ($loc)',
                    style: pw.TextStyle(
                        fontSize: 7.5,
                        fontWeight: pw.FontWeight.bold,
                        color: _textDark)),
                if (detail.isNotEmpty)
                  pw.Text(detail,
                      style: pw.TextStyle(
                          fontSize: 7, color: _textMed, lineSpacing: 1.1)),
              ],
            ),
          ),
        ],
      ));
    }

    return <pw.Widget>[
      _sectionTitle('TO VERIFY ON SITE  —  ${items.length} '
          'ITEM${items.length == 1 ? '' : 'S'}'),
      pw.SizedBox(height: 3),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#FFF8E1'),
            borderRadius: _r3,
            border:
                pw.Border.all(color: PdfColor.fromHex('#F9A825'), width: 0.8)),
        child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                  _safe('NOT counted as hazards. The analysis stated it could '
                      'not confirm these from the photograph - check them at '
                      'close range before recording a finding.'),
                  style: pw.TextStyle(
                      fontSize: 7,
                      color: PdfColor.fromHex('#7A4F01'),
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              ...lines,
            ]),
      ),
      pw.SizedBox(height: 7),
    ];
  }

  /// True for the four rated bands. 'UNKNOWN' / not-rated must never borrow
  /// a band colour (the default branch of [_getSevCol] is LOW green, which
  /// on a banner reads as "assessed: low risk").
  static bool _isRated(String s) =>
      const {'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'}.contains(s.toUpperCase());

  // ─── BANNER (★ 2026-10-03 redesign) ─────────────────────────────────────
  // One navy masthead + a severity-coloured rule + a white title block, in
  // place of the old two stacked colour bands. The severity is stated once,
  // in a single badge, and the report type and reference sit in the
  // masthead where a filing clerk looks for them.
  static pw.Widget _banner(Map<String, dynamic> inc, String sev, bool isAi,
      dynamic score, dynamic conf, pw.MemoryImage? logoImage) {
    final rated = _isRated(sev);
    final sc = rated ? _getSevCol(sev) : _steel;
    final title = _safe(inc['title']?.toString().trim().isNotEmpty == true
        ? inc['title'].toString().trim()
        : (isAi ? 'AI Hazard Scan' : 'Near Miss Report'));
    final plant = _safe(inc['plant']?.toString() ?? '');
    final loc = _safe(inc['location']?.toString() ?? '');
    final where = [plant, loc].where((s) => s.trim().isNotEmpty).join('  ·  ');
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: pw.BoxDecoration(
          color: _navyDeep,
          borderRadius: const pw.BorderRadius.only(
            topLeft: pw.Radius.circular(4), topRight: pw.Radius.circular(4))),
        child: pw.Row(children: [
          logoImage != null
            ? pw.Container(
                width: 34, height: 34,
                padding: const pw.EdgeInsets.all(2),
                decoration: const pw.BoxDecoration(
                  color: PdfColors.white, shape: pw.BoxShape.circle),
                child: pw.Image(logoImage, fit: pw.BoxFit.contain))
            : pw.Container(width: 34, height: 34,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.white, shape: pw.BoxShape.circle),
                alignment: pw.Alignment.center,
                child: pw.Text('SAIL', style: pw.TextStyle(color: _sailBlue,
                  fontSize: 9, fontWeight: pw.FontWeight.bold))),
          pw.SizedBox(width: 11),
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('STEEL AUTHORITY OF INDIA LIMITED', style: pw.TextStyle(
                color: PdfColor.fromHex('#9FC2F5'), fontSize: 6.5,
                fontWeight: pw.FontWeight.bold, letterSpacing: 1.4)),
              pw.SizedBox(height: 2),
              pw.Text('Workplace Hazard Report', style: pw.TextStyle(
                color: PdfColors.white, fontSize: 15,
                fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 1.5),
              pw.Text('Safety Lens  ·  IS 14489:2018  ·  Factories Act 1948',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#BBD3F7'), fontSize: 6.5)),
            ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: pw.BoxDecoration(
                borderRadius: _r3,
                border: pw.Border.all(
                  color: PdfColor.fromHex('#9FC2F5'), width: 0.7)),
              child: pw.Text(isAi ? 'AI HAZARD SCAN' : 'NEAR MISS REPORT',
                style: pw.TextStyle(color: PdfColors.white, fontSize: 7,
                  fontWeight: pw.FontWeight.bold, letterSpacing: 0.8))),
            pw.SizedBox(height: 4),
            pw.Text('REF.  ${_refNo(inc)}', style: pw.TextStyle(
              color: PdfColor.fromHex('#BBD3F7'), fontSize: 7,
              letterSpacing: 0.6)),
          ]),
        ]),
      ),
      // Severity rule: the band colour runs the full width of the masthead,
      // so the rating is visible even on a thumbnail of the page.
      pw.Container(height: 3, color: sc),
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(2, 8, 0, 7),
        decoration: pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _hair, width: 0.8))),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(title, maxLines: 2, style: pw.TextStyle(
                  fontSize: 13.5, fontWeight: pw.FontWeight.bold, color: _ink)),
                pw.SizedBox(height: 2),
                pw.Text(
                  isAi
                    ? 'AI-assisted photographic hazard assessment'
                        '${where.isEmpty ? '' : '  ·  $where'}'
                    : 'Near miss / unsafe condition report'
                        '${where.isEmpty ? '' : '  ·  $where'}',
                  maxLines: 1,
                  style: pw.TextStyle(fontSize: 7.5, color: _steel)),
              ])),
            pw.SizedBox(width: 10),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(12, 4, 12, 5),
              decoration: pw.BoxDecoration(color: sc, borderRadius: _r3),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('RISK LEVEL', style: pw.TextStyle(
                    color: PdfColor.fromHex('#FFFFFF'), fontSize: 5.5,
                    fontWeight: pw.FontWeight.bold, letterSpacing: 1.0)),
                  pw.SizedBox(height: 1),
                  pw.Text(rated ? sev.toUpperCase() : 'NOT RATED',
                    style: pw.TextStyle(color: PdfColors.white, fontSize: 11.5,
                      fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
                ])),
          ]),
      ),
    ]);
  }

  // ─── SECTION HEADING ────────────────────────────────────────────────────
  // Small tracked navy caps followed by a hairline to the margin: reads as a
  // document heading rather than a UI chip, and costs ~12pt of height.
  // Every string that reaches a pw.Text must go through _safe() — callers
  // pass headings with em dashes.
  static pw.Widget _sectionTitle(String t) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 2, bottom: 1),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Container(width: 3, height: 9, color: _sailBlue),
        pw.SizedBox(width: 5),
        pw.Text(_safe(t), style: pw.TextStyle(
          fontSize: 7.8, fontWeight: pw.FontWeight.bold,
          color: _navyDeep, letterSpacing: 1.1)),
        pw.SizedBox(width: 7),
        pw.Expanded(child: pw.Container(height: 0.7, color: _hair)),
      ]),
  );

  /// Replace glyphs the bundled PDF font can't render (em/en-dashes, fancy
  /// quotes, arrows, stars) so they don't show as tofu boxes in the report.
  ///
  /// The font is Helvetica's built-in encoding: Latin-1 only. `·` (U+00B7) is in
  /// it and prints fine; anything above U+00FF does not and comes out as an empty
  /// rectangle. That is what happened to the line-of-fire captions, which used
  /// `→` and read "1 crane load [] worker below".
  static String _safe(String s) => s
      .replaceAll(RegExp(r'[‒–—―]'), '-') // ‒–—―  → -
      .replaceAll('‘', "'").replaceAll('’', "'")      // ‘ ’ → '
      .replaceAll('“', '"').replaceAll('”', '"')      // “ ” → "
      .replaceAll('…', '...')                              // …  → ...
      .replaceAll(RegExp(r'[→⟶➔➜►]'), '->')      // arrows → ASCII
      .replaceAll(RegExp(r'[★☆✦✱]'), '*')          // stars  → *
      .replaceAll('✓', 'Y').replaceAll('✗', 'X')      // ticks/crosses
      .replaceAll('•', '-')                                // bullet → hyphen
      .replaceAll('≥', '>=').replaceAll('≤', '<=');

  static pw.Widget _detailsGrid(Map<String, dynamic> inc, String date,
      String reporter, String pno) {
    // ★ 2026-10-03 redesign: one soft panel with hairline rules between
    // cells, instead of twelve individually bordered boxes with an uneven
    // pale-blue fill. `hi` is kept in the signature for the call sites but
    // now only darkens the value, which is where emphasis belongs.
    pw.Widget cell(String lbl, String val, {bool hi = false}) =>
      pw.Container(
        // 4pt vertical: 12 cells in 3 rows, so each point costs 6pt of page.
        padding: const pw.EdgeInsets.fromLTRB(8, 4.5, 8, 4.5),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_safe(lbl).toUpperCase(), style: pw.TextStyle(
              fontSize: 5.8, color: _steel,
              fontWeight: pw.FontWeight.bold, letterSpacing: 0.7)),
            pw.SizedBox(height: 2),
            pw.Text(val.isEmpty ? '-' : _safe(val), maxLines: 2,
              style: pw.TextStyle(
                fontSize: 8.3, color: hi ? _navyDeep : _ink,
                fontWeight: pw.FontWeight.bold)),
          ]));

    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _panel, borderRadius: _r3,
        border: pw.Border.all(color: _hair, width: 0.7)),
      child: pw.Table(
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _hair, width: 0.6),
        verticalInside: pw.BorderSide(color: _hair, width: 0.6)),
      columnWidths: const {
        0: pw.FlexColumnWidth(1.6),
        1: pw.FlexColumnWidth(1.4),
        2: pw.FlexColumnWidth(1.2),
        3: pw.FlexColumnWidth(1.2),
      },
      children: [
        pw.TableRow(children: [
          cell('Plant / Unit', inc['plant']?.toString() ?? '', hi: true),
          cell('Department', inc['dept']?.toString() ?? ''),
          cell('Location', inc['location']?.toString() ?? ''),
          cell('Date & Time', date, hi: true),
        ]),
        pw.TableRow(children: [
          cell('Reported By', reporter),
          cell('Personnel No.', pno),
          cell('Observation Type', inc['obsType']?.toString() ?? 'N/A'),
          cell('Status', inc['status']?.toString() ?? 'OPEN', hi: true),
        ]),
        pw.TableRow(children: [
          cell('Report Type',
            inc['type'] == 'AI_SCAN' ? 'AI Image Scan' : 'Near Miss'),
          cell('WSA Category', inc['wsaCategory']?.toString() ?? ''),
          cell('Reference No.', _refNo(inc)),
          cell('People Involved', inc['people']?.toString() ?? '0'),
        ]),
      ],
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  PHOTO + SUMMARY (with bbox overlays)
  // ─────────────────────────────────────────────────────────────────────────
  /// [verifyCount] is the length of the Verify-on-site list, NOT part of [count].
  /// It exists so the caption can say "0 hazard(s) identified, 3 to verify on
  /// site" instead of a bare "0 hazard(s) identified" under a photograph the
  /// analysis clearly had something to say about. Keeping the two figures
  /// separate is the point of the whole feature — never fold it into [count].
  static pw.Widget _photoAndSummary(Uint8List img, int count, String summary,
      String severity, dynamic score, dynamic conf,
      List<Map<String, dynamic>> hazards, {int verifyCount = 0,
      int matrixL = 0, int matrixS = 0, int matrixScore = 0,
      bool matrixEstimated = false, bool matrixApplies = false,
      bool analysed = true, pw.Widget? closeUps}) {
    final sc = _getSevCol(severity);
    final sb = _getSevBg(severity);
    final s  = (score is int ? score : int.tryParse('$score') ?? 0).clamp(0, 100);
    // Parsed exactly like AdminMasterData.likelihoodFromConfidence, and it has
    // to stay that way: this prints the confidence, that derives the likelihood
    // FROM the confidence, and both read the same field. With `int.tryParse`
    // here a JSON `90.0` printed "0% Confidence" beside "L4 × S3 (L est.)" —
    // the derived likelihood contradicting the number it was derived from.
    final c  = (conf is num
            ? conf.round()
            : num.tryParse('$conf'.replaceAll('%', '').trim())?.round() ?? 0)
        .clamp(0, 100);
    // The headline number takes ITS OWN band's colour. `sc` is the severity
    // colour and stays on the "RISK: <severity>" line beside it; a matrix score
    // of 12 (HIGH) printed in the teal of a MEDIUM worst-hazard would be the
    // same self-contradiction in ink instead of in text.
    final scNum = matrixApplies
        ? (matrixScore > 0
            ? _getSevCol(AdminMasterData.matrixBandFor(matrixScore))
            // Unrated: grey. A severity colour on a dash would imply a rating.
            : _textMed)
        : sc;

    // 132 -> 175 (★ 2026-10-03). At 132pt the hazard boxes — the report's
    // primary evidence — were too small to read on the printed page (the
    // sample's hazard 2 was a few-point outline). Small boxes additionally get
    // an enlarged crop in the close-up strip (see _closeUps).
    const photoH = 175.0;

    // ── WHY THE PHOTO COLUMN IS SIZED FROM THE IMAGE, NOT BY flex ─────────────
    // This used to be `Expanded(flex: 5)` around a fixed 278pt-wide box. The
    // photo inside is drawn BoxFit.contain and centred (see _buildAnnotatedPhoto:
    // it computes offsetX = (containerW - displayedW) / 2), so any photo that is
    // not exactly 278:148 left a band of white inside the cell — on a portrait
    // phone photo the image rendered ~110pt wide in a 278pt box, i.e. ~170pt of
    // dead paper, which is the gap visible to the right of the picture.
    //
    // So measure the image and make the column exactly as wide as the photo will
    // actually be drawn. Every point saved goes to the summary column via its
    // Expanded, and a wider summary wraps to FEWER LINES — which shortens the
    // whole row, because a Row is as tall as its tallest child.
    final probe = pw.MemoryImage(img);
    final probeW = (probe.width ?? 0).toDouble();
    final probeH = (probe.height ?? 0).toDouble();
    // Bounds, not preferences:
    //   max 250 — a wide panorama must not squeeze the summary into a ribbon.
    //   min 118 — the bbox rectangles and their number tags are drawn ON this
    //             image and are the report's primary evidence; below ~118pt a
    //             tag stops being readable. A very tall portrait photo therefore
    //             keeps a little white space rather than becoming illegible.
    final double photoW = (probeW > 0 && probeH > 0)
        ? (probeW * (photoH / probeH)).clamp(140.0, 300.0).toDouble()
        : 300.0;

    final annotatedPhoto = _buildAnnotatedPhoto(img, hazards, photoW, photoH);

    final bboxedCount = hazards.where((h) => h['bbox'] != null).length;
    final unpinnedCount =
        hazards.where((h) => h['locationUnpinned'] == true).length;

    // The line-of-fire wording used to be printed ON the photograph, in an opaque
    // banner the full width of the image. At the sizes this column actually gets
    // (118-250pt) three of those banners covered the evidence and were still too
    // small to read. So the same one line goes UNDER the picture, at a font size
    // that survives printing, and the image is left alone. One entry only —
    // _buildAnnotatedPhoto draws a single path, the worst one.
    // One legend line per drawn path (see _allLofs), and — new — an explicit
    // "none identified" line when there is no path, so the reader can tell
    // "no line of fire" apart from "the report doesn't cover line of fire".
    final lofLines = [
      for (final e in _allLofs(hazards))
        _safe(LineOfFireGeometry.caption(e.index, e.lof, arrow: '->')),
    ];
    // A hazard the model CALLED line of fire but whose path could not be
    // located on the photo still has to be said out loud.
    final claimedUnlocated = <int>[
      for (var i = 0; i < hazards.length; i++)
        if (LineOfFireGeometry.claimsLineOfFire(hazards[i]) &&
            LineOfFireGeometry.parse(hazards[i]) == null)
          i + 1,
    ];
    if (claimedUnlocated.isNotEmpty) {
      lofLines.add('Line of fire in hazard ${claimedUnlocated.join(', ')} - '
          'path not locatable on photo, check on site');
    }
    final lofNone = lofLines.isEmpty;
    final lofLocated = _allLofs(hazards).length;
    // The line-of-fire strip and the at-a-glance figures are FINDINGS. They
    // are printed only for a photograph the AI actually assessed: on an
    // unanalysed scan, or a near-miss photo nobody ran through the model,
    // "Line of fire: none identified" would be a claim about an image that
    // was never looked at.
    // An AI scan, or any report that carries AI hazard rows (a near miss
    // filed with an analysed photo), counts as assessed.
    final assessed = analysed && (matrixApplies || hazards.isNotEmpty);
    final rated = _isRated(severity);
    final scR = rated ? sc : _steel;
    final sbR = rated ? sb : _panel;

    pw.Widget metric(String value, String label, {PdfColor? color}) =>
        pw.Expanded(child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_safe(value), style: pw.TextStyle(
              fontSize: 11, fontWeight: pw.FontWeight.bold,
              color: color ?? _ink)),
            pw.SizedBox(height: 1),
            pw.Text(_safe(label).toUpperCase(), style: pw.TextStyle(
              fontSize: 5.4, color: _steel, letterSpacing: 0.6,
              fontWeight: pw.FontWeight.bold)),
          ]));

    final riskCard = pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(9, 7, 9, 7),
      decoration: pw.BoxDecoration(
        color: sbR, borderRadius: _r3,
        border: pw.Border.all(color: scR, width: 0.8)),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('OVERALL RISK', style: pw.TextStyle(
                fontSize: 5.6, color: _steel, letterSpacing: 1.0,
                fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 1.5),
              pw.Text(rated ? severity.toUpperCase() : 'NOT RATED',
                style: pw.TextStyle(fontSize: 12.5,
                  fontWeight: pw.FontWeight.bold, color: scR)),
              pw.SizedBox(height: 2),
              // "0%" on an unanalysed scan reads as a measured confidence.
              pw.Text(analysed ? 'AI confidence  $c%'
                  : 'AI confidence  not assessed', style: pw.TextStyle(
                fontSize: 6.8, color: _textMed)),
            ])),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              // An AI scan prints the 1-25 matrix figure; a near-miss row keeps
              // its own 0-100 score. The two factors are printed under the
              // number so a reader who disagrees knows WHICH axis to argue
              // about; "(L est.)" marks a likelihood inferred from confidence.
              // An unrated AI scan prints "- / 25", never the 0-100 score —
              // falling back to `$s / 100` gave an unrated photo a number on
              // paper. ASCII hyphen, not an em dash (Latin-1 font, see _safe).
              pw.Text(!matrixApplies
                  ? '$s / 100'
                  : matrixScore > 0
                      ? '$matrixScore / 25'
                      : '-  / 25', style: pw.TextStyle(
                fontSize: 19, fontWeight: pw.FontWeight.bold,
                color: scNum)),
              pw.Text(!matrixApplies
                  ? 'Risk score'
                  : matrixScore > 0
                      ? 'L$matrixL × S$matrixS'
                          '${matrixEstimated ? '  (L est.)' : ''}'
                      : 'Risk score - not rated',
                style: pw.TextStyle(fontSize: 6.3, color: _steel)),
            ]),
        ]));

    final summaryCol = pw.Padding(
      padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: pw.Column(
        // spaceBetween: the table cell below is given the PHOTO's height
        // (TableCellVerticalAlignment.full), so the figures sit on the
        // bottom edge instead of leaving a blank block under the summary.
        mainAxisAlignment: assessed
            ? pw.MainAxisAlignment.spaceBetween
            : pw.MainAxisAlignment.start,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              riskCard,
              pw.SizedBox(height: 8),
              pw.Text('SUMMARY', style: pw.TextStyle(
                fontSize: 6.5, fontWeight: pw.FontWeight.bold,
                color: _navyDeep, letterSpacing: 1.1)),
              pw.SizedBox(height: 3),
              // _safe(): AI summaries routinely contain em dashes and curly
              // quotes, which the bundled font cannot draw.
              pw.Text(
                summary.isEmpty ? 'See hazards table below.' : _safe(summary),
                style: pw.TextStyle(fontSize: 8, color: _ink,
                  lineSpacing: 1.6)),
              if (closeUps != null) ...[
                pw.SizedBox(height: 8),
                closeUps,
              ],
            ]),
          if (assessed)
            pw.Container(
              margin: const pw.EdgeInsets.only(top: 8),
              padding: const pw.EdgeInsets.only(top: 6),
              decoration: pw.BoxDecoration(
                border: pw.Border(top: pw.BorderSide(color: _hair, width: 0.7))),
              child: pw.Row(children: [
                metric('$count', count == 1 ? 'Hazard' : 'Hazards'),
                metric('$bboxedCount', 'Marked on photo'),
                metric(
                  lofLocated > 0
                      ? '$lofLocated'
                      : claimedUnlocated.isNotEmpty ? '?' : 'None',
                  'Line of fire',
                  color: (lofLocated > 0 || claimedUnlocated.isNotEmpty)
                      ? _lofHot
                      : _lowCol),
                metric('$verifyCount', 'To verify'),
              ])),
          // Sacrificial 1pt spacer: under TableCellVerticalAlignment.full the
          // tallest cell is re-laid at exactly its own height and the pdf
          // Flex may drop its LAST child on float rounding. Let it be this.
          pw.SizedBox(height: 1),
        ]));

    final photoCol = pw.Column(children: [
      pw.Container(
        padding: const pw.EdgeInsets.all(5),
        child: annotatedPhoto),
      if (assessed)
        pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.fromLTRB(5, 0, 5, 0),
          padding: const pw.EdgeInsets.fromLTRB(6, 3, 6, 3),
          // Pale tint, opaque: on paper, so it must be light enough for the
          // #B3261E text (5.7:1). Pale green when no path was found.
          decoration: pw.BoxDecoration(
            borderRadius: _r3,
            color: PdfColor.fromHex(lofNone ? '#EEF6EE' : '#FDECEA')),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: lofNone
              ? [pw.Text('LINE OF FIRE: none identified in this photo',
                  style: pw.TextStyle(fontSize: 6.8,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#2E7D32')))]
              : [
                  pw.Text('LINE OF FIRE  (red arrow / dashed zone on photo)',
                    style: pw.TextStyle(fontSize: 6.2,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColor.fromHex('#B3261E'),
                      letterSpacing: 0.4)),
                  for (final line in lofLines)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 1.5),
                      child: pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          // Short bar in the shaft's red ties each line to
                          // the mark above it.
                          pw.Padding(
                            padding: const pw.EdgeInsets.only(top: 3),
                            child: pw.Container(
                              width: 9, height: 2.4, color: _lofHot)),
                          pw.SizedBox(width: 4),
                          pw.Expanded(
                            child: pw.Text(line,
                              maxLines: 2,
                              style: pw.TextStyle(
                                fontSize: 6.8,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColor.fromHex('#B3261E')))),
                        ])),
                ])),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.fromLTRB(5, 3, 5, 4),
        // A withdrawn box (HazardQuality.auditBoxPrecision) is reported as
        // "not locatable in this view" rather than silently missing, so the
        // reader knows to look on site rather than on the page.
        child: pw.Text(
          (bboxedCount > 0
              ? '$count hazard(s) - $bboxedCount marked on photo'
                  '${unpinnedCount > 0 ? ", $unpinnedCount not locatable in this view" : ""}'
              : unpinnedCount > 0
                ? '$count hazard(s) - none locatable in this view'
                : '$count hazard(s) identified') +
            (verifyCount > 0 ? ', $verifyCount to verify on site' : ''),
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 6.3, color: _steel,
            fontStyle: pw.FontStyle.italic))),
      pw.SizedBox(height: 1), // sacrificial, see summaryCol
    ]);

    // A one-row Table rather than a Row: with TableCellVerticalAlignment.full
    // both cells are laid out at the height of the taller one, which a Row
    // cannot do inside a MultiPage (its `stretch` would take the whole page).
    return pw.Container(
      decoration: pw.BoxDecoration(
        borderRadius: _r3,
        border: pw.Border.all(color: _hair, width: 0.8)),
      child: pw.Table(
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
        border: pw.TableBorder(
          verticalInside: pw.BorderSide(color: _hair, width: 0.8)),
        columnWidths: {
          // Fixed to the photo's own drawn width (+ 5pt padding each side),
          // so every spare point becomes summary line-length.
          0: pw.FixedColumnWidth(photoW + 10),
          1: const pw.FlexColumnWidth(1),
        },
        children: [pw.TableRow(children: [photoCol, summaryCol])],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  ANNOTATED PHOTO BUILDER (image + bbox rectangles)
  //
  //  Accepts bbox in EITHER format:
  //    {x, y, w, h}           ← short form (Apps Script v9 default)
  //    {x, y, width, height}  ← long form
  //  All values normalised 0..1, top-left origin.
  // ─────────────────────────────────────────────────────────────────────────
  static pw.Widget _buildAnnotatedPhoto(
      Uint8List imgBytes,
      List<Map<String, dynamic>> hazards,
      double containerW,
      double containerH) {

    final memImage = pw.MemoryImage(imgBytes);
    final imgW = (memImage.width  ?? 0).toDouble();
    final imgH = (memImage.height ?? 0).toDouble();

    // Find hazards that have a usable bbox
    final bboxed = <int>[];
    for (var i = 0; i < hazards.length; i++) {
      if (hazards[i]['bbox'] is Map) bboxed.add(i);
    }

    // EVERY line of fire the analysis located, primary first.
    //
    // ★ 2026-10-03: this used to draw only LineOfFireGeometry.pickOne() — one
    // arrow per photograph — because at the old 118-250pt photo size three
    // arrows and three caption plates buried the picture. Captions now live in
    // the strip under the photo and the photo is larger, so each located path
    // is drawn (capped at [_maxLofDrawn]); a second energy path that goes
    // unmarked is a hazard the reader never sees.
    final lofs = _allLofs(hazards);
    // Nothing to annotate, or undecodable image → plain image. A hazard can
    // carry a line of fire without a bbox, so the LOF list has to be consulted
    // too — otherwise the one annotation that shows WHO is in danger is the one
    // that gets dropped.
    if ((bboxed.isEmpty && lofs.isEmpty) || imgW <= 0 || imgH <= 0) {
      return pw.Image(memImage, height: containerH, fit: pw.BoxFit.contain);
    }

    // BoxFit.contain math — preserve aspect ratio
    final scaleX = containerW / imgW;
    final scaleY = containerH / imgH;
    final scale  = scaleX < scaleY ? scaleX : scaleY;

    final displayedW = imgW * scale;
    final displayedH = imgH * scale;
    final offsetX   = (containerW - displayedW) / 2;
    final offsetY   = (containerH - displayedH) / 2;
    final rects = _boxRects(hazards, offsetX, offsetY, displayedW, displayedH);

    return pw.SizedBox(
      width: containerW,
      height: containerH,
      child: pw.Stack(
        children: [
          pw.Positioned(
            left: offsetX, top: offsetY,
            child: pw.Image(memImage,
              width: displayedW, height: displayedH,
              fit: pw.BoxFit.fill)),

          // Spotlight dim, painted UNDER the line-of-fire arrow so the arrow
          // keeps its full red (it used to be painted after it and darkened it).
          if (rects.isNotEmpty)
            pw.Positioned(
              left: 0, top: 0,
              child: pw.CustomPaint(
                size: PdfPoint(containerW, containerH),
                painter: (canvas, size) =>
                    _paintDim(canvas, rects, containerH,
                        offsetX, offsetY, displayedW, displayedH),
              ),
            ),

          // LINE OF FIRE — a tapered corridor from the energy source to the
          // person in its path, with an arrowhead giving the DIRECTION of
          // travel. It used to be an axis-aligned rectangle from min/max of the
          // two points, which showed a region rather than a direction and told
          // the reader nothing about which end the danger comes from.
          ...(lofs.isEmpty
              ? const <pw.Widget>[]
              : _lofLayers(lofs, offsetX, offsetY, displayedW, displayedH)),

          // Hazard boxes. Painted, not built from bordered Containers: a
          // Container border is one flat stroke, which vanished on the sample
          // report (a thin teal outline over teal-grey plant). Each box now gets
          // a white halo under a heavier severity-colour stroke, so it reads over
          // light AND dark backgrounds, in colour AND on a mono printer.
          if (rects.isNotEmpty)
            pw.Positioned(
              left: 0, top: 0,
              child: pw.CustomPaint(
                size: PdfPoint(containerW, containerH),
                painter: (canvas, size) =>
                    _paintBoxes(canvas, rects, containerH),
              ),
            ),

          // Number tags, OUTSIDE the box where there is room (above its
          // top-left corner, else below its bottom-left), so the tag never
          // covers the thing it labels. Same number as the hazards-table row.
          ...rects.map((r) {
            const t = _tagSize;
            final imgTop = offsetY, imgBottom = offsetY + displayedH;
            double top;
            if (r.top - t >= imgTop) {
              top = r.top - t;
            } else if (r.top + r.h + t <= imgBottom) {
              top = r.top + r.h;
            } else {
              top = r.top; // box fills the frame: tag inside its corner
            }
            // Upper bound never below the lower one: clamp() throws if a
            // very narrow image (displayedW < tag size) inverts them.
            final left = r.left
                .clamp(offsetX, math.max(offsetX, offsetX + displayedW - t))
                .toDouble();
            return pw.Positioned(
              left: left, top: top,
              child: pw.Container(
                width: t, height: t,
                alignment: pw.Alignment.center,
                decoration: pw.BoxDecoration(
                  color: r.color,
                  border: pw.Border.all(color: PdfColors.white, width: 1)),
                child: pw.Text('${r.index + 1}',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold))),
            );
          }),
        ],
      ),
    );
  }

  static const double _tagSize = 14;
  static const int _maxLofDrawn = 3;

  /// Smallest a box is drawn, in points. A 0.02 x 0.03 box from the model is a
  /// 4pt speck on the page — accurate and useless. It is grown about its own
  /// centre; the close-up strip shows the real crop.
  static const double _minBoxPt = 14;

  /// Every located line of fire, the [LineOfFireGeometry.pickOne] choice first,
  /// then by severity, capped at [_maxLofDrawn].
  static List<({int index, LineOfFire lof})> _allLofs(
      List<Map<String, dynamic>> hazards) {
    final pick = LineOfFireGeometry.pickOne(hazards);
    final out = <({int index, LineOfFire lof})>[
      if (pick != null) (index: pick.index, lof: pick.lof),
    ];
    for (var i = 0; i < hazards.length; i++) {
      if (pick != null && i == pick.index) continue;
      final lof = LineOfFireGeometry.parse(hazards[i]);
      if (lof != null) out.add((index: i, lof: lof));
    }
    return out.take(_maxLofDrawn).toList();
  }

  /// Hazard boxes in CONTAINER points, already clamped to the image and grown
  /// to [_minBoxPt]. Null-box and zero-size entries are skipped.
  static List<({int index, double left, double top, double w, double h,
      PdfColor color})> _boxRects(List<Map<String, dynamic>> hazards,
      double offsetX, double offsetY, double displayedW, double displayedH) {
    final out = <({int index, double left, double top, double w, double h,
        PdfColor color})>[];
    for (var i = 0; i < hazards.length; i++) {
      final bb = hazards[i]['bbox'];
      if (bb is! Map) continue;
      final rx = _asDouble(bb['x']), ry = _asDouble(bb['y']);
      // Accept BOTH "width"/"height" AND "w"/"h" key conventions.
      var bw = _asDouble(bb['width'] ?? bb['w']);
      var bh = _asDouble(bb['height'] ?? bb['h']);
      // NaN/Infinity from a malformed model reply would poison every
      // coordinate below (NaN survives clamp) and break the page stream.
      if (!rx.isFinite || !ry.isFinite || !bw.isFinite || !bh.isFinite) {
        continue;
      }
      final bx = rx.clamp(0.0, 1.0).toDouble();
      final by = ry.clamp(0.0, 1.0).toDouble();
      if (bw <= 0 || bh <= 0) continue;
      bw = math.min(bw, 1.0 - bx);
      bh = math.min(bh, 1.0 - by);
      if (bw <= 0 || bh <= 0) continue;

      var left = offsetX + bx * displayedW;
      var top = offsetY + by * displayedH;
      var w = bw * displayedW;
      var h = bh * displayedH;
      if (w < _minBoxPt) {
        left -= (_minBoxPt - w) / 2;
        w = math.min(_minBoxPt, displayedW);
      }
      if (h < _minBoxPt) {
        top -= (_minBoxPt - h) / 2;
        h = math.min(_minBoxPt, displayedH);
      }
      left = left.clamp(offsetX, offsetX + displayedW - w).toDouble();
      top = top.clamp(offsetY, offsetY + displayedH - h).toDouble();
      out.add((
        index: i, left: left, top: top, w: w, h: h,
        color: _getSevCol(hazards[i]['severity']?.toString() ?? 'MEDIUM'),
      ));
    }
    return out;
  }

  /// Mild spotlight: the image OUTSIDE the boxes is dimmed slightly so the
  /// eye lands on the marked areas. Skipped when the boxes already cover most
  /// of the frame — dimming the remainder would then hide context for no gain.
  /// Overlapping boxes are cut out individually (non-zero winding would undo
  /// the overlap), so a region inside two boxes is not re-dimmed.
  static void _paintDim(
      PdfGraphics canvas,
      List<({int index, double left, double top, double w, double h,
          PdfColor color})> rects,
      double ch,
      double offsetX, double offsetY, double displayedW, double displayedH) {
    double fy(double v) => ch - v;
    final covered = rects.fold<double>(0, (a, r) => a + r.w * r.h);
    if (covered >= displayedW * displayedH * 0.55) return;
    // Outer rectangle clockwise, each box counter-clockwise: with the
    // non-zero rule every box is a hole, including where boxes overlap
    // (even-odd re-filled those intersections).
    canvas
      ..saveContext()
      ..setGraphicState(PdfGraphicState(opacity: 0.30))
      ..setFillColor(PdfColors.black);
    final x0 = offsetX, x1 = offsetX + displayedW;
    final yT = fy(offsetY), yB = fy(offsetY + displayedH);
    canvas
      ..moveTo(x0, yB)..lineTo(x0, yT)..lineTo(x1, yT)..lineTo(x1, yB)
      ..closePath();
    for (final r in rects) {
      final l = r.left, rr = r.left + r.w;
      final t = fy(r.top), b = fy(r.top + r.h);
      canvas
        ..moveTo(l, b)..lineTo(rr, b)..lineTo(rr, t)..lineTo(l, t)
        ..closePath();
    }
    canvas
      ..fillPath()
      ..restoreContext();
  }

  static void _paintBoxes(
      PdfGraphics canvas,
      List<({int index, double left, double top, double w, double h,
          PdfColor color})> rects,
      double ch) {
    double fy(double v) => ch - v;

    for (final r in rects) {
      // halo, then colour, then a thin inner white line: three passes so the
      // box edge survives any background.
      canvas
        ..setLineJoin(PdfLineJoin.miter)
        ..setStrokeColor(PdfColors.white)
        ..setLineWidth(4.2)
        ..drawRect(r.left, fy(r.top + r.h), r.w, r.h)
        ..strokePath()
        ..setStrokeColor(r.color)
        ..setLineWidth(2.4)
        ..drawRect(r.left, fy(r.top + r.h), r.w, r.h)
        ..strokePath();
      // Heavier corner brackets: they still identify the box if a printer
      // drops the thinner edge strokes.
      final arm = math.min(9.0, math.min(r.w, r.h) * 0.35);
      final x0 = r.left, x1 = r.left + r.w;
      final y0 = fy(r.top), y1 = fy(r.top + r.h);
      canvas
        ..setStrokeColor(r.color)
        ..setLineWidth(3.6)
        ..setLineCap(PdfLineCap.butt)
        ..moveTo(x0, y0 - arm)..lineTo(x0, y0)..lineTo(x0 + arm, y0)
        ..moveTo(x1 - arm, y0)..lineTo(x1, y0)..lineTo(x1, y0 - arm)
        ..moveTo(x0, y1 + arm)..lineTo(x0, y1)..lineTo(x0 + arm, y1)
        ..moveTo(x1 - arm, y1)..lineTo(x1, y1)..lineTo(x1, y1 + arm)
        ..strokePath();
    }
  }

  /// Enlarged crops of the SMALL marked areas, printed under the photo row.
  ///
  /// A box that covers a few percent of the frame is correct but cannot be
  /// read on paper — the sample report's hazard 2 was such a box. Each crop is
  /// the box plus a margin, bordered in its severity colour and numbered like
  /// the table. Returns null when no box is small or the image cannot be
  /// decoded (the report is then exactly as before).
  static pw.Widget? _closeUps(Uint8List imgBytes,
      List<Map<String, dynamic>> hazards) {
    try {
      final small = <int>[];
      for (var i = 0; i < hazards.length; i++) {
        final bb = hazards[i]['bbox'];
        if (bb is! Map) continue;
        final w = _asDouble(bb['width'] ?? bb['w']);
        final h = _asDouble(bb['height'] ?? bb['h']);
        final x = _asDouble(bb['x']), y = _asDouble(bb['y']);
        if (!w.isFinite || !h.isFinite || !x.isFinite || !y.isFinite) continue;
        if (w <= 0 || h <= 0) continue;
        if (w * h < 0.12 || math.min(w, h) < 0.22) small.add(i);
      }
      if (small.isEmpty) return null;
      // Decoding a full-resolution phone photo in pure Dart runs on the UI
      // isolate on web and can freeze the tab for seconds. Above ~3 MB the
      // close-ups are skipped there; the boxes on the main photo still show.
      if (kIsWeb && imgBytes.lengthInBytes > 3 * 1024 * 1024) return null;
      final src = img.decodeImage(imgBytes);
      if (src == null) return null;
      final oriented = img.bakeOrientation(src);
      final iw = oriented.width.toDouble(), ih = oriented.height.toDouble();

      final tiles = <pw.Widget>[];
      for (final i in small.take(4)) {
        final bb = hazards[i]['bbox'] as Map;
        final bx = _asDouble(bb['x']).clamp(0.0, 1.0);
        final by = _asDouble(bb['y']).clamp(0.0, 1.0);
        final bw = _asDouble(bb['width'] ?? bb['w']);
        final bh = _asDouble(bb['height'] ?? bb['h']);
        // 35% margin each side, and never narrower than 12% of the frame,
        // so the crop shows what the hazard is attached to.
        final mw = math.max(bw * 0.35, (0.12 - bw) / 2).clamp(0.0, 1.0);
        final mh = math.max(bh * 0.35, (0.12 - bh) / 2).clamp(0.0, 1.0);
        final x0 = ((bx - mw).clamp(0.0, 1.0) * iw).round();
        final y0 = ((by - mh).clamp(0.0, 1.0) * ih).round();
        final x1 = ((bx + bw + mw).clamp(0.0, 1.0) * iw).round();
        final y1 = ((by + bh + mh).clamp(0.0, 1.0) * ih).round();
        if (x1 - x0 < 4 || y1 - y0 < 4) continue;
        var crop = img.copyCrop(oriented,
            x: x0, y: y0, width: x1 - x0, height: y1 - y0);
        if (crop.width > 480 || crop.height > 480) {
          crop = crop.width >= crop.height
              ? img.copyResize(crop, width: 480)
              : img.copyResize(crop, height: 480);
        }
        final jpg = Uint8List.fromList(img.encodeJpg(crop, quality: 82));
        const tileH = 54.0;
        // Width follows the crop's own aspect so BoxFit.contain shows ALL of
        // it (cover cut the head off a tall person box in the audit render).
        final tileW = (tileH * crop.width / crop.height).clamp(30.0, 110.0)
            .toDouble();
        final sev = hazards[i]['severity']?.toString() ?? 'MEDIUM';
        final col = _getSevCol(sev);
        tiles.add(pw.Container(
          width: math.max(tileW + 4, 60),
          margin: const pw.EdgeInsets.only(right: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: col, width: 2)),
                child: pw.Stack(children: [
                  pw.Image(pw.MemoryImage(jpg),
                      width: tileW, height: tileH, fit: pw.BoxFit.contain),
                  pw.Positioned(left: 0, top: 0, child: pw.Container(
                    width: _tagSize, height: _tagSize, color: col,
                    alignment: pw.Alignment.center,
                    child: pw.Text('${i + 1}', style: pw.TextStyle(
                      color: PdfColors.white, fontSize: 8,
                      fontWeight: pw.FontWeight.bold)))),
                ])),
              pw.SizedBox(height: 2),
              pw.Text(_safe(hazards[i]['name']?.toString() ?? ''),
                maxLines: 2,
                style: pw.TextStyle(fontSize: 6.3, color: _textDark,
                  fontWeight: pw.FontWeight.bold)),
            ])));
      }
      if (tiles.isEmpty) return null;
      return pw.Container(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('CLOSE-UP OF MARKED AREAS', style: pw.TextStyle(
              fontSize: 6.5, fontWeight: pw.FontWeight.bold,
              color: _navyDeep, letterSpacing: 1.1)),
            pw.SizedBox(height: 4),
            // Wrap, not Row: four wide crops can exceed the 531pt content
            // width, and a Row would overflow the page edge.
            pw.Wrap(spacing: 0, runSpacing: 4, children: tiles),
          ]));
    } catch (_) {
      // A crop is a convenience. Never let it cost the report.
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  LINE-OF-FIRE OVERLAY (PDF)
  //
  //  The screen renderer (widgets/hazard_annotated_image.dart) and this one both
  //  draw from LineOfFireGeometry.plan(), so the printed report shows the same
  //  arrow the officer approved on screen.
  //
  //  COORDINATES. pw.CustomPaint hands the painter a canvas translated to the
  //  widget box's bottom-left corner with y growing UPWARD (PDF convention),
  //  whereas plan() works in screen space with y growing downward. Everything
  //  below therefore passes vertical values through _fy(). Getting this wrong
  //  does not throw — it silently mirrors the arrow, so the report would point
  //  the danger at the wrong person.
  // ─────────────────────────────────────────────────────────────────────────
  static final PdfColor _lofHot  = PdfColor.fromHex('#E53935');
  static final PdfColor _lofHalo = PdfColor.fromHex('#FFFFFF');

  static List<pw.Widget> _lofLayers(
      List<({int index, LineOfFire lof})> lofs,
      double offsetX,
      double offsetY,
      double displayedW,
      double displayedH) {

    final plans = <({int index, LineOfFire lof, LofPlan plan})>[
      for (final e in lofs)
        (
          index: e.index,
          lof: e.lof,
          plan: LineOfFireGeometry.plan(e.lof, displayedW, displayedH),
        ),
    ];

    return <pw.Widget>[
      // All corridors and arrows in one painter: a single graphics stream keeps
      // the clip/opacity save-restore pairs local and avoids one widget per
      // hazard fighting over the same pixels.
      pw.Positioned(
        left: offsetX,
        top: offsetY,
        child: pw.CustomPaint(
          size: PdfPoint(displayedW, displayedH),
          painter: (canvas, size) {
            for (final p in plans) {
              _paintLof(canvas, p.plan, displayedH,
                  personVisible: p.lof.personVisible);
            }
          },
        ),
      ),

      // No caption is drawn on the image any more — see _lofLegend(), which puts
      // it in a strip under the photograph where it can be read.
    ];
  }

  static void _paintLof(PdfGraphics canvas, LofPlan plan, double boxH,
      {bool personVisible = true}) {
    double fy(double v) => boxH - v;

    // Nobody is in the photograph. Mark the ZONE where a person would be struck,
    // dashed, and draw no arrow: an arrow asserts a person at its head. See
    // LineOfFire.personVisible.
    if (!personVisible) {
      _paintZone(canvas, plan, boxH);
      return;
    }

    // No usable direction (source and person resolved to the same spot). Mark
    // the place instead of drawing a zero-length arrow that reads as a smudge.
    if (plan.degenerate || plan.corridor.length != 4) {
      _ring(canvas, plan.personX, fy(plan.personY),
          math.max(9.0, plan.halfWidth * 0.6));
      return;
    }

    // ONE arrow, source dot, ring on the person. Nothing else.
    //
    // The shaded, hatched corridor that used to be drawn here has gone. Two
    // reasons, both about the person reading the printout: the wash and the
    // hatching sat over the equipment they were being told to inspect, and at
    // the size this photo appears on an A4 page the corridor read as a printing
    // defect rather than as information. An arrow says "this could hit that
    // person" in one glance, and it says it in black and white too.

    final ux = (plan.personX - plan.sourceX) / plan.length;
    final uy = (plan.personY - plan.sourceY) / plan.length;

    final ringR = math.max(7.5, math.min(plan.halfWidth * 0.62, 26.0));
    final headLen = math.max(6.0, math.min(plan.length * 0.22, 14.0));

    // Tip lands on the ring, not on the person: their posture and PPE are
    // frequently the actual finding, so nothing is drawn over them.
    final tipD = math.max(headLen + 1.0, plan.length - ringR);
    final tipX = plan.sourceX + ux * tipD;
    final tipY = plan.sourceY + uy * tipD;
    final baseX = tipX - ux * headLen;
    final baseY = tipY - uy * headLen;

    // Tail starts clear of the source dot.
    final tailD = math.min(4.5, plan.length * 0.15);
    final tailX = plan.sourceX + ux * tailD;
    final tailY = plan.sourceY + uy * tailD;

    // ── shaft, haloed so it reads over rust, red machinery and dark steel ──
    for (final pass in const [(w: 3.6, halo: true), (w: 1.8, halo: false)]) {
      canvas
        ..setStrokeColor(pass.halo ? _lofHalo : _lofHot)
        ..setLineWidth(pass.w)
        ..setLineCap(PdfLineCap.round)
        ..moveTo(tailX, fy(tailY))
        ..lineTo(baseX, fy(baseY))
        ..strokePath();
    }

    // ── arrowhead, drawn twice: a white outline pass then the red fill ────
    final nx = -uy;
    final ny = ux;
    final halfHead = headLen * 0.46;
    void head(double grow) {
      canvas
        ..moveTo(tipX + ux * grow, fy(tipY + uy * grow))
        ..lineTo(baseX + nx * (halfHead + grow), fy(baseY + ny * (halfHead + grow)))
        ..lineTo(baseX - nx * (halfHead + grow), fy(baseY - ny * (halfHead + grow)))
        ..closePath()
        ..fillPath();
    }
    canvas.setFillColor(_lofHalo);
    head(1.5);
    canvas.setFillColor(_lofHot);
    head(0);

    // ── small dot on the energy source ────────────────────────────────────
    // Enough to say "it starts here"; small enough not to compete with the ring
    // on the person, who is the point of the drawing.
    const r = 2.6;
    canvas
      ..setFillColor(_lofHalo)
      ..drawEllipse(plan.sourceX, fy(plan.sourceY), r + 1.2, r + 1.2)
      ..fillPath()
      ..setFillColor(_lofHot)
      ..drawEllipse(plan.sourceX, fy(plan.sourceY), r, r)
      ..fillPath();

    // ── ring on the exposed person ────────────────────────────────────────
    // A ring, never a filled disc: the officer has to be able to see the
    // person's posture and PPE to judge the finding.
    _ring(canvas, plan.personX, fy(plan.personY), ringR);
  }

  /// The area a person would be struck in, when there is no person to point at.
  ///
  /// A dashed square where the model placed the exposure, a dashed stub back
  /// toward the source, and no arrowhead anywhere. Dashes carry the meaning here:
  /// every solid mark in this overlay says "this is here", and the point of a
  /// zone is that nobody is.
  static void _paintZone(PdfGraphics canvas, LofPlan plan, double boxH) {
    double fy(double v) => boxH - v;
    final half = math.max(9.0, math.min(plan.halfWidth * 0.75, 30.0));

    // Solid halo pass first: a dashed red outline vanishes over rust and red
    // machinery, and this report gets printed.
    canvas
      ..setStrokeColor(_lofHalo)
      ..setLineWidth(3.0)
      ..setLineDashPattern()
      ..drawRect(plan.personX - half, fy(plan.personY) - half, half * 2, half * 2)
      ..strokePath()
      ..setStrokeColor(_lofHot)
      ..setLineWidth(1.4)
      // 3pt on, 2pt off. Any finer and the dashes close up into a solid line at
      // print resolution, which would make the zone read as a certainty.
      ..setLineDashPattern(const [3, 2])
      ..drawRect(plan.personX - half, fy(plan.personY) - half, half * 2, half * 2)
      ..strokePath();

    if (plan.length > half * 1.8) {
      final ux = (plan.personX - plan.sourceX) / plan.length;
      final uy = (plan.personY - plan.sourceY) / plan.length;
      final fromD = math.min(4.0, plan.length * 0.12);
      final toD = plan.length - half * 1.3;
      canvas
        ..setLineWidth(1.2)
        ..moveTo(plan.sourceX + ux * fromD, fy(plan.sourceY + uy * fromD))
        ..lineTo(plan.sourceX + ux * toD, fy(plan.sourceY + uy * toD))
        ..strokePath();
      const r = 2.2;
      canvas
        ..setLineDashPattern()
        ..setFillColor(_lofHalo)
        ..drawEllipse(plan.sourceX, fy(plan.sourceY), r + 1.1, r + 1.1)
        ..fillPath()
        ..setFillColor(_lofHot)
        ..drawEllipse(plan.sourceX, fy(plan.sourceY), r, r)
        ..fillPath();
    }

    // Dashes are graphics state: leaving them set would dot every later stroke
    // on the page, including the table borders.
    canvas.setLineDashPattern();
  }

  static void _ring(PdfGraphics canvas, double x, double y, double radius) {
    canvas
      ..setStrokeColor(_lofHalo)
      ..setLineWidth(2.6)
      ..drawEllipse(x, y, radius, radius)
      ..strokePath()
      ..setStrokeColor(_lofHot)
      ..setLineWidth(1.4)
      ..drawEllipse(x, y, radius, radius)
      ..strokePath();
  }

  // _lofLabel() was here: a red plate with white text, drawn on top of the
  // photograph beside the arrow's midpoint. It is gone deliberately. At the
  // 118-250pt this column gets, one plate covered a meaningful slice of the
  // evidence and its 6.5pt text was still hard to read; three of them, which is
  // what a busy stockyard scan produced, made both the picture and the words
  // useless. The same sentence — from the one shared LineOfFireGeometry.caption()
  // — is now printed in an opaque strip immediately BELOW the photo, where it can
  // be as large as it needs to be and hides nothing. See _buildAnnotatedPhoto.

  static double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  // ─── HAZARDS TABLE ───────────────────────────────────────────────────────
  static pw.Widget _hazardsTable(List<Map<String, dynamic>> hazards) {
    pw.Widget hdrCell(String t, {pw.TextAlign align = pw.TextAlign.left}) =>
        pw.Container(
          // 6pt -> 4pt horizontal. The `pdf` package gives FlexColumnWidth no
          // intrinsic minimum and does not clip, so a header word wider than
          // its cell bleeds across the border instead of wrapping. 'SEVERITY'
          // and 'REGULATION' are the tightest; 4pt padding buys each of them
          // 4pt of clearance without touching the body cells' width.
          padding: const pw.EdgeInsets.fromLTRB(4, 5, 4, 5),
          color: _navyDeep,
          child: pw.Text(t, style: pw.TextStyle(
            color: PdfColors.white, fontSize: 6.6,
            fontWeight: pw.FontWeight.bold, letterSpacing: 0.4),
            textAlign: align));

    // ★ 2026-10-03 redesign: horizontal hairlines only (no cage of vertical
    // rules), zebra rows that fill the full row height, a severity-coloured
    // number tag that matches the tag on the photograph, and a pill for the
    // severity itself.
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _hair, width: 0.8)),
      // Zebra fill via TableRow.decoration, NOT per-cell colour + `full`
      // alignment: `full` re-lays the tallest cell at exactly its own height
      // and the pdf Flex can then drop its last child on rounding — which
      // silently removed the "not marked on photo" note in the audit render.
      child: pw.Table(
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _hair, width: 0.6)),
      // ── COLUMN BUDGET ────────────────────────────────────────────────────
      // Width is taken from the two columns that hold nothing but short labels
      // and given to the two that hold sentences, because row height is driven
      // by whichever cell wraps to the most lines:
      //   #           20  -> 16   (fixed; one or two digits plus padding)
      //   HAZARD      1.8 -> 1.4  (a hazard name is 2-4 words)
      //   REGULATION  1.5 -> 1.25 ("FA 1948 S21" is ~11 characters)
      //   DESCRIPTION 2.6 -> 3.05 } the two multi-line cells, and the ones the
      //   CORRECTIVE  2.4 -> 2.9  } reader actually needs to act on
      // Widening DESCRIPTION by ~17% typically drops a 6-line cell to 5 lines,
      // which is ~11pt off every hazard row.
      //
      // REGULATION did not go all the way down to 1.0 even though its VALUES
      // are short: at 1.0 it computes to ~55pt, and the word 'REGULATION' in
      // 7.5pt bold needs ~53pt of inner width, so the header would have
      // overflowed its cell. A citation wrapping to two lines would also set
      // the row height, cancelling the saving. Content width, not label width,
      // is the reason it stops at 1.25.
      columnWidths: const {
        0: pw.FixedColumnWidth(16),
        1: pw.FlexColumnWidth(1.4),
        2: pw.FixedColumnWidth(52),
        3: pw.FlexColumnWidth(3.05),
        4: pw.FlexColumnWidth(1.25),
        5: pw.FlexColumnWidth(2.9),
      },
      children: [
        pw.TableRow(children: [
          hdrCell('#', align: pw.TextAlign.center),
          hdrCell('HAZARD'),
          hdrCell('SEVERITY', align: pw.TextAlign.center),
          hdrCell('DESCRIPTION'),
          hdrCell('REGULATION'),
          hdrCell('CORRECTIVE ACTION'),
        ]),
        ...List.generate(hazards.length, (i) {
          final h   = hazards[i];
          final sev = h['severity']?.toString().toUpperCase() ?? 'MEDIUM';
          final sc  = _getSevCol(sev);
          final sb  = _getSevBg(sev);
          final bg  = i % 2 == 0 ? _rowNorm : _rowAlt;

          return pw.TableRow(
            decoration: pw.BoxDecoration(color: bg),
            children: [
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(2, 5, 2, 4),
              alignment: pw.Alignment.topCenter,
              child: pw.Container(
                width: 12, height: 12,
                alignment: pw.Alignment.center,
                color: sc,
                child: pw.Text('${i + 1}', style: pw.TextStyle(
                  fontSize: 7, fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white)))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(_safe(h['name']?.toString() ?? ''),
                    style: pw.TextStyle(fontSize: 7.8,
                      fontWeight: pw.FontWeight.bold, color: _ink,
                      lineSpacing: 1.3)),
                  // Line-of-fire tag, so the table says which rows the arrow
                  // on the photo belongs to.
                  if (LineOfFireGeometry.parse(h) != null ||
                      LineOfFireGeometry.claimsLineOfFire(h))
                    pw.Container(
                      margin: const pw.EdgeInsets.only(top: 2.5),
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1.2),
                      decoration: pw.BoxDecoration(
                        color: _lofHot, borderRadius: _r3),
                      child: pw.Text(
                        LineOfFireGeometry.parse(h) != null
                            ? 'LINE OF FIRE'
                            : 'LINE OF FIRE (not located)',
                        style: pw.TextStyle(fontSize: 5.8,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white))),
                  if (h['bbox'] is! Map && h['locationUnpinned'] == true)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 2),
                      child: pw.Text('not marked on photo',
                        style: pw.TextStyle(fontSize: 6,
                          fontStyle: pw.FontStyle.italic,
                          color: _textMed))),
                ])),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(3, 4, 3, 4),
              alignment: pw.Alignment.topCenter,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 4, vertical: 1.8),
                decoration: pw.BoxDecoration(
                  color: sb, borderRadius: _r3,
                  border: pw.Border.all(color: sc, width: 0.6)),
                child: pw.Text(sev, style: pw.TextStyle(
                  fontSize: 6.2, fontWeight: pw.FontWeight.bold,
                  color: sc, letterSpacing: 0.3),
                  textAlign: pw.TextAlign.center))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: pw.Text(_safe(h['description']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7.3, color: _ink,
                  lineSpacing: 1.4))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: pw.Text(_safe(h['regulation']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7, color: _textMed,
                  lineSpacing: 1.3))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: pw.Text(_safe(h['correctiveAction']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7.3, color: _ink,
                  lineSpacing: 1.4))),
          ]);
        }),
      ],
    ));
  }

  // _riskScoreBar() was deleted here. It rendered TOTAL RISK SCORE / OVERALL
  // RISK with a 0/50/75/90+ scale bar and was appended after the hazards
  // table, which put a ~100pt duplicate of the page-1 risk panel at the top
  // of page 2. The score, severity and confidence all still appear in the
  // right-hand panel of _photoAndSummary and as the banner severity pill.

  // hazards_countBySev() was deleted here too: it was dead code that always
  // returned 0 and had no callers.


  static pw.Widget _summaryBox(String summary) => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(11, 9, 11, 9),
    decoration: pw.BoxDecoration(
      borderRadius: _r3,
      border: pw.Border.all(color: _hair, width: 0.8),
      color: _panel),
    child: pw.Text(summary.isEmpty ? 'No summary provided.' : _safe(summary),
      style: pw.TextStyle(fontSize: 8.8, color: _ink, lineSpacing: 1.6)));

  /// Corrective action for reports that have no hazards table (near misses).
  /// The reporter enters these as one field joined with ' | ', so it is split
  /// back into lines: a single run-on paragraph of three actions separated by
  /// pipes is much harder to check off than three lines. Tighter than
  /// [_summaryBox] (8.5pt, 1.2 spacing) because this section only ever appears
  /// on the report that has room for it.
  static pw.Widget _actionBox(String action) {
    final items = action
        .split(' | ')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.fromLTRB(11, 7, 11, 7),
      decoration: pw.BoxDecoration(
        borderRadius: _r3,
        border: pw.Border.all(color: _hair, width: 0.8),
        color: _panel),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: items.length <= 1
          // _safe(): these come straight from the model, which writes "—" and
          // "•" freely, and an action the officer is meant to carry out is the
          // worst place on the page for an unreadable character.
          ? [pw.Text(_safe(action), style: pw.TextStyle(
              fontSize: 8.5, color: _textDark, lineSpacing: 1.2))]
          : [
              for (var i = 0; i < items.length; i++)
                pw.Padding(
                  padding: pw.EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 3),
                  child: pw.Text('${i + 1}.  ${_safe(items[i])}',
                    style: pw.TextStyle(
                    fontSize: 8.5, color: _textDark, lineSpacing: 1.2))),
            ],
      ));
  }

  // ✅ GPS LOCATION SECTION — Place name FIRST, coordinates as link only
  static pw.Widget? _gpsLocationSection(Map<String, dynamic> inc) {
    final lat = inc['latitude'];
    final lon = inc['longitude'];

    if (lat == null || lon == null) return null; // No GPS data

    final acc = inc['locationAccuracy'];
    final addr = inc['locationAddress']?.toString() ?? '';
    final timestamp = inc['locationTimestamp']?.toString() ?? '';
    final mapsUrl = 'https://www.google.com/maps?q=$lat,$lon';

    final coordText =
        '${_toDouble(lat).toStringAsFixed(4)}, ${_toDouble(lon).toStringAsFixed(4)}';

    // Prefer the reverse-geocoded place name, but ONLY if it fits the one-line
    // strip. The `pdf` package has no ellipsis (TextOverflow is span/clip/visible
    // — there is no fade or '…'), so `maxLines: 1` on a long address silently
    // drops the tail with no indication that anything is missing. Half an address
    // with no marker is worse than no address at all in a safety document, so a
    // long one is cut with an EXPLICIT '...' and the coordinates appended, so
    // the reader can see that the place name was shortened AND still has an
    // exact position.
    //
    // Width budget for the 64pt-wide Expanded slot: the strip's other children
    // (the LOCATION label, the accuracy chip, the timestamp, the Maps link)
    // take ~200pt of the 515pt inner width, leaving ~315pt. At 8.5pt bold that
    // is ~70 characters, so 64 is a safe full-address threshold — the previous
    // 46 was over-cautious and threw away readable place names that fitted.
    // The shortened form is 40 + '... (' + 18 + ')' = ~64 characters, ~282pt.
    final String displayLocation;
    if (addr.isEmpty) {
      displayLocation = coordText;
    } else if (addr.length <= 64) {
      displayLocation = addr;
    } else {
      displayLocation = '${addr.substring(0, 40).trimRight()}... ($coordText)';
    }

    // Compact single-row strip. This was a ~145pt bordered card with its own
    // 'GPS LOCATION' section title, a large place name, an accuracy line, a
    // 'View on Google Maps' link AND the raw URL printed again underneath — the
    // URL was redundant because the link text is already clickable, and the
    // whole block was the second-biggest contributor to the report spilling
    // onto page 2. Now one line, ~26pt, carrying the same information.
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(9, 6, 9, 6),
      decoration: pw.BoxDecoration(
        borderRadius: _r3,
        border: pw.Border.all(color: _hair, width: 0.8),
        color: _panel),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text('GPS LOCATION   ', style: pw.TextStyle(
            fontSize: 6.3, color: _navyDeep,
            fontWeight: pw.FontWeight.bold, letterSpacing: 1.0)),
          // Expanded (not Spacer) so the row cannot wrap onto a second line and
          // undo the saving. displayLocation is pre-checked to fit, so maxLines
          // here is a backstop, not the mechanism.
          pw.Expanded(
            child: pw.Text(displayLocation,
              maxLines: 1,
              style: pw.TextStyle(
                fontSize: 8.3, color: _ink,
                fontWeight: pw.FontWeight.bold))),
          if (acc != null)
            pw.Text('  +/-${_toDouble(acc).toStringAsFixed(0)}m',
              style: pw.TextStyle(fontSize: 7, color: _textMed)),
          if (timestamp.isNotEmpty)
            pw.Text('  ${_formatGpsTimestamp(timestamp)}',
              style: pw.TextStyle(fontSize: 7, color: _textMed)),
          pw.SizedBox(width: 6),
          pw.UrlLink(
            destination: mapsUrl,
            child: pw.Text('Google Maps',
              style: pw.TextStyle(fontSize: 7.5, color: PdfColor.fromHex('#0D47A1'),
                fontWeight: pw.FontWeight.bold,
                decoration: pw.TextDecoration.underline)),
          ),
        ]));
  }

  static double _toDouble(dynamic val) {
    if (val is double) return val;
    if (val is int) return val.toDouble();
    return double.tryParse(val?.toString() ?? '0') ?? 0.0;
  }

  static String _formatGpsTimestamp(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return DateFormat('dd MMM yyyy, HH:mm:ss').format(dt);
    } catch (_) {
      return iso;
    }
  }

  // _twoCol() lived here — the ROOT CAUSE ANALYSIS (WSA 13) and IMMEDIATE
  // CORRECTIVE ACTION boxes. Deleted, not just unused: see the note in build()
  // for why both were duplicates of _detailsGrid cells and of the hazards
  // table's CORRECTIVE ACTION column. `incident['immediateAction']` and
  // `incident['wsaCategory']` are still read elsewhere, so nothing is orphaned.

  // Signature gaps trimmed 20pt -> 10pt and padding 14pt -> 9/7pt. Still room
  // to sign by hand (10pt of clear space above each rule, and the rule itself
  // sits 3pt above its caption) while giving back ~38pt toward one page. The
  // horizontal padding stays at 9pt: the three 120pt rules have to fit side by
  // side, so squeezing left/right would start clipping them, not just crowd.
  // ★ 2026-10-03 redesign: a proper sign-off block. Three equal columns,
  // each with role caption, name line and a signature rule with room to sign
  // by hand (18pt clear), on white with hairline dividers rather than a flat
  // blue rectangle. The reporter's name and P.No. are pre-printed.
  static pw.Widget _signOff(String reporter, String pno) {
    pw.Widget col(String role, String who, String sub, String caption) =>
      pw.Expanded(child: pw.Padding(
        padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(role, style: pw.TextStyle(
              fontSize: 5.8, color: _steel,
              fontWeight: pw.FontWeight.bold, letterSpacing: 1.0)),
            pw.SizedBox(height: 3),
            pw.Text(_safe(who), maxLines: 1, style: pw.TextStyle(
              fontSize: 8.8, fontWeight: pw.FontWeight.bold, color: _ink)),
            pw.Text(_safe(sub), maxLines: 1,
              style: pw.TextStyle(fontSize: 6.8, color: _steel)),
            pw.SizedBox(height: 18),
            pw.Container(height: 0.6, color: _ink),
            pw.SizedBox(height: 2.5),
            pw.Text(caption, style: pw.TextStyle(
              fontSize: 6.2, color: _steel)),
          ])));
    return pw.Column(children: [
      pw.Container(
        decoration: pw.BoxDecoration(
          borderRadius: _r3,
          border: pw.Border.all(color: _hair, width: 0.8)),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            col('REPORTED BY', reporter,
                pno.isNotEmpty ? 'P.No. $pno' : 'Reporting officer',
                'Signature & date'),
            pw.Container(width: 0.7, height: 62, color: _hair),
            col('REVIEWED BY', 'Safety Officer / HOD', 'Name:',
                'Signature & date'),
            pw.Container(width: 0.7, height: 62, color: _hair),
            col('APPROVED BY', 'Plant Head / GM (Safety)', 'Name:',
                'Signature & date'),
          ])),
      pw.SizedBox(height: 5),
      pw.Text(
        'Generated by SAIL Safety Lens. AI observations are advisory and '
        'subject to verification by the Safety Department before any '
        'finding is recorded.',
        style: pw.TextStyle(fontSize: 6.3, color: _steel,
          fontStyle: pw.FontStyle.italic),
        textAlign: pw.TextAlign.center),
    ]);
  }

  static List<Map<String, dynamic>> _parseHazards(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) {
      return raw.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is List) return d.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (_) {}
    }
    return [];
  }

  static String _cleanSummary(Map<String, dynamic> inc) {
    final s = inc['summary']?.toString() ?? '';
    if (s.isNotEmpty && !s.contains('===')) return s;
    final d = inc['desc']?.toString() ?? '';
    if (d.isEmpty) return '';
    final lines = d.split('\n');
    final clean = <String>[];
    for (final line in lines) {
      if (line.startsWith('===')) break;
      clean.add(line);
    }
    return clean.join(' ').replaceAll('Summary: ', '').trim();
  }

  static PdfColor _getSevCol(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return _critCol;
      case 'HIGH':     return _highCol;
      case 'MEDIUM':   return _medCol;
      default:         return _lowCol;
    }
  }

  static PdfColor _getSevBg(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return _critBg;
      case 'HIGH':     return _highBg;
      case 'MEDIUM':   return _medBg;
      default:         return _lowBg;
    }
  }

  // ─── PUBLIC API ──────────────────────────────────────────────────────────
  static Future<void> downloadOrShareIncident({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
    Uint8List? imageBytes,
  }) async {
    final bytes = await generateIncidentReportBytes(
      incident: incident, reporterName: reporterName,
      reporterPno: reporterPno, imageBytes: imageBytes);
    final fn = 'SafetyLens_${incident['type'] ?? 'Report'}'
        '_${incident['id'] ?? DateTime.now().millisecondsSinceEpoch}.pdf';
    if (kIsWeb) {
      _downloadWeb(bytes, fn);
    } else {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fn');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path)],
          text: 'SAIL Safety Lens Report', subject: 'Incident Report');
    }
  }

  /// Share an incident AS A PDF FILE — the one entry point every WhatsApp /
  /// Email / More share button uses (★ 2026-10-03; they used to send a text
  /// summary, or a Drive link that was often not uploaded yet).
  ///
  /// Mobile: the PDF is written to the temp dir and handed to the system share
  /// sheet, where the user picks WhatsApp, Gmail, etc. Android/iOS do not let an
  /// app attach a file to a specific app silently, so WhatsApp and Email both go
  /// through the sheet — but what arrives is the PDF, not text.
  ///
  /// Web: Web Share Level 2 (`navigator.share({files})`) where the browser
  /// supports it (Chrome Android, Safari, Edge); otherwise — desktop Firefox,
  /// or the tap's user activation expired while the PDF was being built — the
  /// PDF is DOWNLOADED so the user can attach it themselves.
  ///
  /// Returns 'shared', 'dismissed' or 'downloaded' so the caller can tell the
  /// user what happened. Throws only if the PDF itself could not be generated.
  static Future<String> shareIncidentPdf({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
    Uint8List? imageBytes,
    String? text,
    String? subject,
  }) async {
    final bytes = await generateIncidentReportBytes(
      incident: incident, reporterName: reporterName,
      reporterPno: reporterPno, imageBytes: imageBytes);
    final fn = pdfFileName(incident);
    final title = incident['title']?.toString().trim() ?? '';
    // text == '' means "no caption": WhatsApp on Android drops the file
    // attachment when the intent also carries EXTRA_TEXT (see
    // incident_detail_screen), so WhatsApp shares pass ''.
    final caption =
        text ?? 'SAIL Safety Lens report${title.isEmpty ? '' : ': $title'}';
    return sharePdfBytes(bytes,
        fileName: fn,
        text: caption.isEmpty ? null : caption,
        subject: subject ??
            'Safety Lens ${incident['type'] ?? 'Report'}'
                '${title.isEmpty ? '' : ' - $title'}');
  }

  /// A file name that survives every share target: no spaces, slashes or
  /// colons (WhatsApp and some mail clients mangle them).
  static String pdfFileName(Map<String, dynamic> incident) {
    String clean(String v) =>
        v.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    final type = clean(incident['type']?.toString() ?? 'Report');
    final id = clean(incident['id']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString());
    return 'SafetyLens_${type}_$id.pdf';
  }

  /// See [shareIncidentPdf].
  static Future<String> sharePdfBytes(Uint8List bytes, {
    required String fileName,
    String? text,
    String? subject,
  }) async {
    if (kIsWeb) {
      try {
        final res = await Share.shareXFiles(
          [XFile.fromData(bytes, mimeType: 'application/pdf', name: fileName)],
          text: text, subject: subject);
        // share_plus 9 on web returns `unavailable` AFTER A SUCCESSFUL share
        // (the Web Share API does not report the chosen target), and THROWS
        // when the browser cannot share files. So only the throw means
        // "fall back to a download".
        return res.status == ShareResultStatus.dismissed ? 'dismissed' : 'shared';
      } catch (_) {
        _downloadWeb(bytes, fileName);
        return 'downloaded';
      }
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    final res = await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/pdf', name: fileName)],
      text: text, subject: subject);
    return res.status == ShareResultStatus.dismissed ? 'dismissed' : 'shared';
  }

  static void _downloadWeb(Uint8List bytes, String fileName) {
    final blob = html.Blob([bytes], 'application/pdf');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    // Revoked later, not immediately: Safari/Firefox can cancel a download
    // whose blob URL is revoked in the same tick as the click.
    Future.delayed(const Duration(seconds: 30),
        () => html.Url.revokeObjectUrl(url));
  }

  static Future<File> generateIncidentReport({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
  }) async {
    final bytes = await generateIncidentReportBytes(
      incident: incident, reporterName: reporterName,
      reporterPno: reporterPno);
    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/SafetyLens_${incident['id']}.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<File> generateConsolidatedReport({
    required List<Map<String, dynamic>> incidents,
    String reporterName = 'SAIL Safety Officer',
    String? reportTitle,
    String? plant,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final pdf   = pw.Document();
    final now   = DateTime.now();
    final title = reportTitle
        ?? 'SAIL Safety Lens — Consolidated Incident Report';

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => _pageHeader(ctx.pageNumber > 1),
      footer: (ctx) => _pageFooter(ctx.pageNumber, ctx.pagesCount,
          reporterName, DateFormat('dd MMM yyyy').format(now)),
      build: (ctx) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          color: _sailBlue,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('SAIL SAFETY LENS', style: pw.TextStyle(
                color: PdfColors.white, fontSize: 18,
                fontWeight: pw.FontWeight.bold)),
              pw.Text(title, style: pw.TextStyle(
                color: PdfColor.fromHex('#BBDEFB'), fontSize: 11)),
              pw.Text('Generated: ${DateFormat('dd MMM yyyy, HH:mm').format(now)}',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#90CAF9'), fontSize: 9)),
            ])),
        pw.SizedBox(height: 16),
        pw.Text('Total Incidents: ${incidents.length}',
          style: pw.TextStyle(fontSize: 12,
            fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColor.fromHex('#9E9E9E'), width: 0.8),
          columnWidths: const {
            0: pw.FixedColumnWidth(22),
            1: pw.FixedColumnWidth(54),
            2: pw.FlexColumnWidth(2.0),
            3: pw.FlexColumnWidth(1.5),
            4: pw.FixedColumnWidth(58),
            5: pw.FixedColumnWidth(46),
          },
          children: [
            pw.TableRow(children: [
              for (final h in ['#', 'Date', 'Title', 'Plant', 'Severity', 'Status'])
                pw.Container(
                  padding: const pw.EdgeInsets.fromLTRB(6, 5, 6, 5),
                  color: _sailBlue,
                  child: pw.Text(h, style: pw.TextStyle(
                    color: PdfColors.white, fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold))),
            ]),
            ...List.generate(incidents.length, (i) {
              final inc = incidents[i];
              final sev = inc['severity']?.toString() ?? 'MEDIUM';
              final bg  = i % 2 == 0 ? _rowNorm : _rowAlt;
              pw.Widget c(String t) => pw.Container(
                padding: const pw.EdgeInsets.fromLTRB(6, 5, 6, 5),
                color: bg,
                child: pw.Text(t,
                  style: const pw.TextStyle(fontSize: 8)));
              return pw.TableRow(children: [
                c('${i + 1}'),
                c(inc['date'] != null
                    ? DateFormat('dd/MM/yy')
                        .format(DateTime.parse(inc['date'])) : ''),
                c(inc['title']?.toString() ?? ''),
                c(inc['plant']?.toString() ?? ''),
                pw.Container(
                  padding: const pw.EdgeInsets.fromLTRB(6, 5, 6, 5),
                  color: _getSevBg(sev),
                  child: pw.Text(sev, style: pw.TextStyle(
                    fontSize: 7, fontWeight: pw.FontWeight.bold,
                    color: _getSevCol(sev)))),
                c(inc['status']?.toString() ?? 'OPEN'),
              ]);
            }),
          ]),
      ]));

    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/SafetyLens_Consolidated_'
        '${DateFormat('yyyyMMdd').format(now)}.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  static Future<void> sharePdf(File file, {String? subject}) async {
    await Share.shareXFiles([XFile(file.path)],
        subject: subject ?? 'Safety Lens Report',
        text: 'Safety report generated by SAIL Safety Lens');
  }
}
