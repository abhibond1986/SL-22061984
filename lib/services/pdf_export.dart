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
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'admin_master_data.dart';
import 'image_storage.dart';
import 'line_of_fire.dart';
import 'pdf_export_stub.dart' if (dart.library.html) 'pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

class PdfExport {
  static final PdfColor _sailBlue    = PdfColor.fromHex('#0D47A1');
  static final PdfColor _sailLight   = PdfColor.fromHex('#E3F2FD');
  static final PdfColor _critCol     = PdfColor.fromHex('#C62828');
  static final PdfColor _critBg      = PdfColor.fromHex('#FFEBEE');
  static final PdfColor _highCol     = PdfColor.fromHex('#E65100');
  static final PdfColor _highBg      = PdfColor.fromHex('#FFF3E0');
  static final PdfColor _medCol      = PdfColor.fromHex('#00838F');
  static final PdfColor _medBg       = PdfColor.fromHex('#E0F7FA');
  static final PdfColor _lowCol      = PdfColor.fromHex('#2E7D32');
  static final PdfColor _lowBg       = PdfColor.fromHex('#E8F5E9');
  static final PdfColor _divider     = PdfColor.fromHex('#9E9E9E');
  static final PdfColor _textDark    = PdfColor.fromHex('#212121');
  static final PdfColor _textMed     = PdfColor.fromHex('#616161');
  static final PdfColor _textLight   = PdfColor.fromHex('#9E9E9E');
  static final PdfColor _rowAlt      = PdfColor.fromHex('#F8FAFF');
  static final PdfColor _rowNorm     = PdfColors.white;

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

    final severity   = incident['severity']?.toString() ?? 'MEDIUM';
    final isAiScan   = incident['type']?.toString() == 'AI_SCAN';
    // Reconciled ONCE, here, so the banner, the score block and anything added
    // later all print the same figure. See AdminMasterData.scoreForDisplay for the
    // "23 / 100 beside RISK: CRITICAL" report that made this necessary — the rule
    // lives there because the screens have to obey it too, and a stored incident
    // exported months later still carries the number it was filed with.
    final riskScore  =
        AdminMasterData.scoreForDisplay(severity, incident['riskScore'] ?? 0);
    final confidence = incident['confidence'] ?? 0;

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 32),
      header: (ctx) => _pageHeader(ctx.pageNumber > 1),
      footer: (ctx) => _pageFooter(ctx.pageNumber, ctx.pagesCount, reporterName, dateStr),
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
        final viewCaveat = incident['viewCaveat']?.toString().trim() ?? '';
        if (viewCaveat.isNotEmpty) {
          w.add(pw.SizedBox(height: 5));
          w.add(_caveatBar(viewCaveat));
        }
        w.add(pw.SizedBox(height: 7));
        w.add(_sectionTitle('INCIDENT DETAILS'));
        w.add(pw.SizedBox(height: 3));
        w.add(_detailsGrid(incident, dateStr, reporterName, reporterPno));
        w.add(pw.SizedBox(height: 7));
        if (imgBytes != null) {
          w.add(_sectionTitle('EVIDENCE PHOTOGRAPH  &  INCIDENT SUMMARY'));
          w.add(pw.SizedBox(height: 3));
          w.add(_photoAndSummary(imgBytes, hazards.length, summary,
              severity, riskScore, confidence, hazards));
          w.add(pw.SizedBox(height: 7));
        } else {
          w.add(_sectionTitle('INCIDENT SUMMARY'));
          w.add(pw.SizedBox(height: 3));
          w.add(_summaryBox(summary));
          w.add(pw.SizedBox(height: 7));
        }
        if (hazards.isNotEmpty) {
          w.add(_sectionTitle('HAZARDS IDENTIFIED  —  ${hazards.length} TOTAL'));
          w.add(pw.SizedBox(height: 3));
          w.add(_hazardsTable(hazards));
          // NOTE: the TOTAL RISK SCORE / OVERALL RISK bar used to be added here.
          // It was a verbatim duplicate of the risk score already shown in the
          // right-hand panel of _photoAndSummary (and of the severity pill in
          // the banner), and being ~100pt tall it was the single biggest reason
          // the report ran to a second page. Removed deliberately — do not
          // re-add it. The page-1 panel is the one source of the score.
          w.add(pw.SizedBox(height: 7));
        } else {
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
            w.add(pw.SizedBox(height: 3));
            w.add(_actionBox(action));
            w.add(pw.SizedBox(height: 7));
          }
        }
        // GPS is now a single compact strip rather than a ~145pt bordered card
        // with its own section title, because the coordinates and a Maps link
        // are all a reader needs.
        final gpsSection = _gpsLocationSection(incident);
        if (gpsSection != null) {
          w.add(gpsSection);
          w.add(pw.SizedBox(height: 7));
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
      padding: const pw.EdgeInsets.only(bottom: 7),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _sailBlue, width: 1.2))),
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
          pw.Text('CONFIDENTIAL · INTERNAL USE', style: pw.TextStyle(
            fontSize: 7, color: _textLight, fontStyle: pw.FontStyle.italic)),
        ],
      ),
    );
  }

  static pw.Widget _pageFooter(int pg, int tot, String reporter, String date) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _sailBlue, width: 0.8))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('SAIL Safety Lens  ·  $date',
            style: pw.TextStyle(fontSize: 7, color: _textLight)),
          pw.Text('Page $pg of $tot',
            style: pw.TextStyle(fontSize: 7, color: _textMed,
              fontWeight: pw.FontWeight.bold)),
          pw.Text('CONFIDENTIAL  ·  IS 14489:2018',
            style: pw.TextStyle(fontSize: 7, color: _textLight)),
        ],
      ),
    );
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
      border: pw.Border.all(color: PdfColor.fromHex('#F9A825'), width: 0.8)),
    child: pw.Text(_safe(text), style: pw.TextStyle(
      fontSize: 7.5, color: PdfColor.fromHex('#7A4F01'), lineSpacing: 1.2,
      fontWeight: pw.FontWeight.bold)),
  );

  static pw.Widget _banner(Map<String, dynamic> inc, String sev, bool isAi,
      dynamic score, dynamic conf, pw.MemoryImage? logoImage) {
    final sc = _getSevCol(sev);
    final sb = _getSevBg(sev);
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(12, 9, 12, 9),
        color: _sailBlue,
        child: pw.Row(children: [
          // ★ v28: Use actual SAIL Safety Lens badge logo
          // 46pt -> 36pt. The logo is the tallest child of this row, so it —
          // not the text beside it (which needs only ~31pt) — sets the whole
          // banner height. Shrinking it is 10pt of page for no lost legibility;
          // the badge is still larger than the 11pt title text next to it.
          logoImage != null
            ? pw.Container(
                width: 36, height: 36,
                child: pw.Image(logoImage, fit: pw.BoxFit.contain))
            : pw.Container(width: 34, height: 34, color: PdfColors.white,
                alignment: pw.Alignment.center,
                child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text('SAIL', style: pw.TextStyle(color: _sailBlue, fontSize: 10,
                      fontWeight: pw.FontWeight.bold)),
                    pw.Text('सेल', style: pw.TextStyle(
                      color: PdfColor.fromHex('#1565C0'), fontSize: 5)),
                  ])),
          pw.SizedBox(width: 10),
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('STEEL AUTHORITY OF INDIA LIMITED', style: pw.TextStyle(
                color: PdfColors.white, fontSize: 11,
                fontWeight: pw.FontWeight.bold)),
              pw.Text('Safety Lens  ·  Workplace Hazard Report',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#BBDEFB'), fontSize: 8)),
            ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              color: sc,
              child: pw.Text(sev, style: pw.TextStyle(
                color: PdfColors.white, fontSize: 11,
                fontWeight: pw.FontWeight.bold))),
            pw.SizedBox(height: 3),
            pw.Text('IS 14489:2018  |  Factories Act 1948',
              style: pw.TextStyle(
                color: PdfColor.fromHex('#90CAF9'), fontSize: 6)),
          ]),
        ]),
      ),
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(12, 5, 12, 5),
        color: sb,
        child: pw.Row(children: [
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(_safe(inc['title']?.toString() ?? 'Safety Incident Report'),
                style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold,
                  color: _textDark)),
              pw.SizedBox(height: 2),
              pw.Text(isAi
                  ? 'AI-Powered Hazard Scan  ·  SAIL Safety Lens'
                  : 'Near Miss / Unsafe Condition Report',
                style: pw.TextStyle(fontSize: 8, color: _textMed)),
            ])),
          pw.SizedBox(width: 8),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: sc, width: 1)),
            child: pw.Text(isAi ? 'AI HAZARD SCAN' : 'NEAR MISS REPORT',
              style: pw.TextStyle(color: sc, fontSize: 8,
                fontWeight: pw.FontWeight.bold))),
        ]),
      ),
    ]);
  }

  // 4pt -> 3pt vertical padding. There are three of these per report, so it is
  // 6pt of page for no loss of prominence (the blue bar and the fill do the
  // work, not the padding).
  // Note the _safe() on the title text: callers pass headings like
  // 'HAZARDS IDENTIFIED — 6 TOTAL' with an em-dash, and this widget used to print
  // it raw, which put an empty box in the middle of the largest heading on the
  // page. Every string that reaches a pw.Text must go through _safe().
  static pw.Widget _sectionTitle(String t) => pw.Container(
    padding: const pw.EdgeInsets.fromLTRB(10, 3, 10, 3),
    decoration: pw.BoxDecoration(
      color: _sailLight,
      border: pw.Border(left: pw.BorderSide(color: _sailBlue, width: 3)),
    ),
    child: pw.Text(_safe(t), style: pw.TextStyle(
      fontSize: 8.5, fontWeight: pw.FontWeight.bold,
      color: _sailBlue, letterSpacing: 0.5)),
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
    pw.Widget cell(String lbl, String val, {bool hi = false}) =>
      pw.Container(
        // 7pt -> 4pt vertical. 12 cells in 3 rows, so each point of vertical
        // padding costs 6pt of page. The 2pt label-to-value gap is deliberately
        // NOT cut: it is what stops the grey caption reading as part of the
        // value above it, and it is only 6pt of page in total.
        padding: const pw.EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColor.fromHex('#E0E0E0'), width: 0.5),
          color: hi ? _sailLight : PdfColors.white),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_safe(lbl).toUpperCase(), style: pw.TextStyle(
              fontSize: 6.5, color: _textLight,
              fontWeight: pw.FontWeight.bold, letterSpacing: 0.3)),
            pw.SizedBox(height: 2),
            pw.Text(val.isEmpty ? '-' : _safe(val), style: pw.TextStyle(
              fontSize: 8.5, color: _textDark,
              fontWeight: pw.FontWeight.bold)),
          ]));

    return pw.Table(
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
          cell('Reference No.', (inc['id']?.toString() ?? 'N/A').length > 8
              ? inc['id'].toString().substring(0, 8)
              : inc['id']?.toString() ?? 'N/A'),
          cell('People Involved', inc['people']?.toString() ?? '0'),
        ]),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  PHOTO + SUMMARY (with bbox overlays)
  // ─────────────────────────────────────────────────────────────────────────
  static pw.Widget _photoAndSummary(Uint8List img, int count, String summary,
      String severity, dynamic score, dynamic conf,
      List<Map<String, dynamic>> hazards) {
    final sc = _getSevCol(severity);
    final sb = _getSevBg(severity);
    final s  = (score is int ? score : int.tryParse('$score') ?? 0).clamp(0, 100);
    final c  = (conf is int ? conf : int.tryParse('$conf') ?? 0).clamp(0, 100);

    const photoH = 132.0; // 185 -> 148 -> 132 toward the one-page target

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
        ? (probeW * (photoH / probeH)).clamp(118.0, 250.0).toDouble()
        : 250.0;

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
    final lofPick = LineOfFireGeometry.pickOne(hazards);
    final lofLegend = lofPick == null
        ? ''
        : _safe(LineOfFireGeometry.caption(
            lofPick.index, lofPick.lof, arrow: '->'));

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _divider, width: 0.6)),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Fixed to the photo's own drawn width (+ 5pt padding each side).
          pw.SizedBox(
            width: photoW + 10,
            child: pw.Column(children: [
              pw.Container(
                padding: const pw.EdgeInsets.all(5),
                child: annotatedPhoto),
              if (lofLegend.isNotEmpty)
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.fromLTRB(5, 2.5, 5, 2.5),
                  // Pale red tint, not the translucent overlay used before: this
                  // strip is on paper now, so the fill must be opaque and light
                  // enough for #B3261E text (5.7:1).
                  color: PdfColor.fromHex('#FDECEA'),
                  child: pw.Row(children: [
                    // A short bar in the same red as the shaft on the image, so
                    // the reader can tie this line to the mark above it without a
                    // "see the red arrow" instruction.
                    pw.Container(width: 9, height: 2.4, color: _lofHot),
                    pw.SizedBox(width: 4),
                    pw.Expanded(
                      child: pw.Text(lofLegend,
                        maxLines: 2,
                        style: pw.TextStyle(
                          fontSize: 6.8,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#B3261E')))),
                  ])),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.fromLTRB(5, 2, 5, 3),
                color: PdfColor.fromHex('#F5F5F5'),
                // Shortened: the caption now sits in a column as narrow as the
                // photo, and the old sentence wrapped to three lines there. The
                // "see table below" instruction was redundant — the table is
                // directly beneath under its own heading.
                // A withdrawn box (HazardQuality.auditBoxPrecision) would
                // otherwise show up here as a silently smaller "marked on photo"
                // figure, which reads as the drawing having failed. Say instead
                // that the location could not be pinned, so the reader knows to
                // look for it on site rather than on the page.
                child: pw.Text(
                  bboxedCount > 0
                    ? '$count hazard(s) - $bboxedCount marked on photo'
                        '${unpinnedCount > 0 ? ", $unpinnedCount not locatable in this view" : ""}'
                    : unpinnedCount > 0
                      ? '$count hazard(s) - none locatable in this view'
                      : '$count hazard(s) identified',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: 6.5, color: _textMed,
                    fontStyle: pw.FontStyle.italic))),
            ])),
          pw.Container(width: 0.5, color: _divider),
          // Takes ALL remaining width, so anything the photo column gives back
          // becomes summary line-length rather than margin.
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.fromLTRB(9, 8, 9, 8),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                    color: sb,
                    child: pw.Row(children: [
                      pw.Container(width: 3, height: 3, color: sc),
                      pw.SizedBox(width: 4),
                      pw.Text('RISK: $severity', style: pw.TextStyle(
                        fontSize: 8, fontWeight: pw.FontWeight.bold, color: sc)),
                    ])),
                  pw.SizedBox(height: 5),
                  // Score and confidence on one baseline. The headline figure
                  // drops 22pt -> 18pt and confidence 16pt -> 14pt: still by far
                  // the largest type on the page, so it keeps its job as the
                  // at-a-glance number, but ~5pt shorter.
                  pw.Row(children: [
                    pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('$s / 100', style: pw.TextStyle(
                          fontSize: 18, fontWeight: pw.FontWeight.bold,
                          color: sc)),
                        pw.Text('Risk Score', style: pw.TextStyle(
                          fontSize: 6.5, color: _textLight)),
                      ]),
                    pw.SizedBox(width: 12),
                    pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('$c%', style: pw.TextStyle(
                          fontSize: 14, fontWeight: pw.FontWeight.bold,
                          color: _textMed)),
                        pw.Text('Confidence', style: pw.TextStyle(
                          fontSize: 6.5, color: _textLight)),
                      ]),
                  ]),
                  pw.SizedBox(height: 5),
                  pw.Container(height: 0.5, color: _divider),
                  pw.SizedBox(height: 5),
                  pw.Text('SUMMARY', style: pw.TextStyle(
                    fontSize: 7, fontWeight: pw.FontWeight.bold,
                    color: _sailBlue, letterSpacing: 0.5)),
                  pw.SizedBox(height: 3),
                  // lineSpacing 1.5 -> 1.1. At fontSize 8 that is still clear
                  // leading, and on an 8-line summary it saves ~3pt per line.
                  // _safe() matters here: AI summaries routinely contain em
                  // dashes and curly quotes, and the offline-fallback summary
                  // starts with one. The bundled font has no glyph for them, so
                  // without this they render as tofu boxes.
                  pw.Text(
                    summary.isEmpty
                        ? 'See hazards table below.'
                        : _safe(summary),
                    style: pw.TextStyle(fontSize: 8, color: _textDark,
                      lineSpacing: 1.1)),
                ],
              ),
            )),
        ],
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

    // THE line of fire — one per photograph, chosen by the shared contract so
    // this page and the AI Scan screen annotate the same hazard. Its number is
    // the hazards-table row number.
    //
    // It used to draw one per hazard. On a wide plant view with three paths the
    // result was three arrows and three full-width caption plates crossing a
    // picture about 60mm wide on the printed page.
    final pick = LineOfFireGeometry.pickOne(hazards);
    final lofs = <({int index, LineOfFire lof})>[
      if (pick != null) (index: pick.index, lof: pick.lof),
    ];

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

          // LINE OF FIRE — a tapered corridor from the energy source to the
          // person in its path, with an arrowhead giving the DIRECTION of
          // travel. It used to be an axis-aligned rectangle from min/max of the
          // two points, which showed a region rather than a direction and told
          // the reader nothing about which end the danger comes from.
          ...(lofs.isEmpty
              ? const <pw.Widget>[]
              : _lofLayers(lofs, offsetX, offsetY, displayedW, displayedH)),

          ...bboxed.map((i) {
            final h     = hazards[i];
            final bbMap = h['bbox'] as Map;

            final bx = _asDouble(bbMap['x']);
            final by = _asDouble(bbMap['y']);
            // ✅ Accept BOTH "width"/"height" AND "w"/"h" key conventions
            final bw = _asDouble(bbMap['width']  ?? bbMap['w']);
            final bh = _asDouble(bbMap['height'] ?? bbMap['h']);

            if (bw <= 0 || bh <= 0) return pw.SizedBox();

            final sev   = h['severity']?.toString() ?? 'MEDIUM';
            final color = _getSevCol(sev);

            // Clamp to [0,1]
            final cx = bx.clamp(0.0, 1.0);
            final cy = by.clamp(0.0, 1.0);
            final cw = (bx + bw > 1.0 ? 1.0 - cx : bw).clamp(0.0, 1.0);
            final ch = (by + bh > 1.0 ? 1.0 - cy : bh).clamp(0.0, 1.0);

            final rectLeft = offsetX + (cx * displayedW);
            final rectTop  = offsetY + (cy * displayedH);
            final rectW    = cw * displayedW;
            final rectH    = ch * displayedH;

            return pw.Positioned(
              left: rectLeft, top: rectTop,
              child: pw.Container(
                width: rectW, height: rectH,
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: color, width: 1.4)),
                child: pw.Stack(children: [
                  pw.Positioned(
                    left: -1, top: -1,
                    child: pw.Container(
                      width: 13, height: 13,
                      color: color,
                      alignment: pw.Alignment.center,
                      child: pw.Text('${i + 1}',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold)))),
                ]),
              ),
            );
          }),
        ],
      ),
    );
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
          color: _sailBlue,
          child: pw.Text(t, style: pw.TextStyle(
            color: PdfColors.white, fontSize: 7.5,
            fontWeight: pw.FontWeight.bold, letterSpacing: 0.3),
            textAlign: align));

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColor.fromHex('#BDBDBD'), width: 0.5),
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

          return pw.TableRow(children: [
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(4, 4, 4, 4),
              color: PdfColor.fromHex('#E3F2FD'),
              alignment: pw.Alignment.center,
              child: pw.Text('${i + 1}', style: pw.TextStyle(
                fontSize: 9, fontWeight: pw.FontWeight.bold,
                color: _sailBlue),
                textAlign: pw.TextAlign.center)),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              color: bg,
              child: pw.Text(_safe(h['name']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 8,
                  fontWeight: pw.FontWeight.bold, color: _textDark,
                  lineSpacing: 1.3))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(4, 4, 4, 4),
              color: sb,
              alignment: pw.Alignment.center,
              child: pw.Text(sev, style: pw.TextStyle(
                fontSize: 7.5, fontWeight: pw.FontWeight.bold,
                color: sc),
                textAlign: pw.TextAlign.center)),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              color: bg,
              child: pw.Text(_safe(h['description']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7.5, color: _textDark,
                  lineSpacing: 1.4))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              color: bg,
              child: pw.Text(_safe(h['regulation']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7, color: _textMed,
                  lineSpacing: 1.3))),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(6, 4, 6, 4),
              color: bg,
              child: pw.Text(_safe(h['correctiveAction']?.toString() ?? ''),
                style: pw.TextStyle(fontSize: 7.5, color: _textDark,
                  lineSpacing: 1.4))),
          ]);
        }),
      ],
    );
  }

  // _riskScoreBar() was deleted here. It rendered TOTAL RISK SCORE / OVERALL
  // RISK with a 0/50/75/90+ scale bar and was appended after the hazards
  // table, which put a ~100pt duplicate of the page-1 risk panel at the top
  // of page 2. The score, severity and confidence all still appear in the
  // right-hand panel of _photoAndSummary and as the banner severity pill.

  // hazards_countBySev() was deleted here too: it was dead code that always
  // returned 0 and had no callers.


  static pw.Widget _summaryBox(String summary) => pw.Container(
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: _divider, width: 0.5),
      color: PdfColor.fromHex('#FAFAFA')),
    child: pw.Text(summary.isEmpty ? 'No summary provided.' : _safe(summary),
      style: pw.TextStyle(fontSize: 9, color: _textDark, lineSpacing: 1.6)));

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
      padding: const pw.EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _divider, width: 0.5),
        color: PdfColor.fromHex('#FAFAFA')),
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
      padding: const pw.EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColor.fromHex('#00838F'), width: 0.6),
        color: PdfColor.fromHex('#E0F7FA')),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text('LOCATION  ', style: pw.TextStyle(
            fontSize: 7, color: PdfColor.fromHex('#00695C'),
            fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
          // Expanded (not Spacer) so the row cannot wrap onto a second line and
          // undo the saving. displayLocation is pre-checked to fit, so maxLines
          // here is a backstop, not the mechanism.
          pw.Expanded(
            child: pw.Text(displayLocation,
              maxLines: 1,
              style: pw.TextStyle(
                fontSize: 8.5, color: _textDark,
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
  static pw.Widget _signOff(String reporter, String pno) => pw.Container(
    padding: const pw.EdgeInsets.fromLTRB(9, 7, 9, 7),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: _sailBlue, width: 0.8),
      color: _sailLight),
    child: pw.Column(children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('REPORTED BY', style: pw.TextStyle(
                fontSize: 7, color: _textLight,
                fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
              pw.SizedBox(height: 4),
              pw.Text(reporter, style: pw.TextStyle(
                fontSize: 10, fontWeight: pw.FontWeight.bold,
                color: _textDark)),
              if (pno.isNotEmpty) pw.Text('P.No.: $pno',
                style: pw.TextStyle(fontSize: 8, color: _textMed)),
              pw.SizedBox(height: 10),
              pw.Container(width: 120, height: 0.5, color: _textDark),
              pw.SizedBox(height: 3),
              pw.Text('Signature', style: pw.TextStyle(
                fontSize: 7, color: _textLight)),
            ])),
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('REVIEWED BY', style: pw.TextStyle(
                fontSize: 7, color: _textLight,
                fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
              pw.SizedBox(height: 4),
              pw.Text('Safety Officer / HOD', style: pw.TextStyle(
                fontSize: 9, color: _textMed)),
              pw.SizedBox(height: 10),
              pw.Container(width: 120, height: 0.5, color: _textDark),
              pw.SizedBox(height: 3),
              pw.Text('Signature & Date', style: pw.TextStyle(
                fontSize: 7, color: _textLight)),
            ])),
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('APPROVED BY', style: pw.TextStyle(
                fontSize: 7, color: _textLight,
                fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
              pw.SizedBox(height: 4),
              pw.Text('Plant Head / GM (Safety)', style: pw.TextStyle(
                fontSize: 9, color: _textMed)),
              pw.SizedBox(height: 10),
              pw.Container(width: 120, height: 0.5, color: _textDark),
              pw.SizedBox(height: 3),
              pw.Text('Signature & Date', style: pw.TextStyle(
                fontSize: 7, color: _textLight)),
            ])),
        ]),
      pw.SizedBox(height: 5),
      pw.Container(height: 0.5, color: PdfColor.fromHex('#BBDEFB')),
      pw.SizedBox(height: 3),
      pw.Text(
        'This report is generated by SAIL Safety Lens AI system. '
        'All observations are subject to verification by the Safety Department.',
        style: pw.TextStyle(fontSize: 7, color: _textLight,
          fontStyle: pw.FontStyle.italic),
        textAlign: pw.TextAlign.center),
    ]));

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
      final blob   = html.Blob([bytes], 'application/pdf');
      final url    = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', fn)..click();
      html.Url.revokeObjectUrl(url);
    } else {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fn');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path)],
          text: 'SAIL Safety Lens Report', subject: 'Incident Report');
    }
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
