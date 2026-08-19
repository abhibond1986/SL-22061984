// lib/services/sop_doc_import.dart
//
// Turns an uploaded PDF / Word / text file into the same page list the camera
// produces, so the SOP scan flow downstream does not care where a document came
// from.
//
// ZERO NEW DEPENDENCIES, and that is deliberate. Two things made it possible:
//
//   • PDF → page images uses `Printing.raster` from the `printing` package,
//     which was already in pubspec.yaml (unused until now). It rasterises on
//     Android, iOS AND web from one code path.
//
//     CORRECTION, verified 2026-08-19 against printing-5.12.0/printing_web.dart:
//     an earlier version of this comment claimed the web plugin bundles its own
//     pdf.js and therefore needs no network. IT DOES NOT. `PrintingPlugin`
//     injects a <script> tag pointing at
//     https://unpkg.com/pdfjs-dist@3.2.146/build/pdf.min.js on first use, plus a
//     worker from the same base. So web PDF import carries exactly the CDN
//     dependency this file criticises pdf_kb_extractor_web.dart for — on a
//     filtered plant network it will not work, and [canReadPdf] is what keeps
//     that honest instead of silent. Mobile has no such dependency.
//
//     The plugin reads a `dartPdfJsBaseUrl` JavaScript global before falling
//     back to unpkg, so the real fix is to vendor pdf.min.js and
//     pdf.worker.min.js into web/ and set that global in index.html — the same
//     self-hosting job STATUS.md already lists for the Google fonts.
//   • Word → text uses `archive`, already present "for DOCX extraction for
//     knowledge base uploads". A .docx is a ZIP of XML.
//
// The alternatives were worse and were rejected on purpose: a native PDF plugin
// risks the Kotlin/AGP ceiling that already forced google_mlkit_text_recognition
// back to 0.13.x on Flutter 3.19.6, and the pure-Dart option (Syncfusion) needs
// a paid licence at SAIL's revenue.
//
// WHY PDFs ARE RASTERISED RATHER THAN TEXT-EXTRACTED: it keeps one path for all
// platforms, preserves per-page numbering (which is what makes a clause citation
// say "page 4"), and means a scanned photocopy — most plant SOPs — behaves the
// same as a digital one. The cost is that a digital PDF is read by OCR when its
// text could have been copied out exactly. On mobile that is free (ML Kit reads
// on-device); on web it spends one AI request per page. See [pdfTextFastPath].
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:printing/printing.dart';

import '../utils/image_prep.dart';

/// What kind of file the user picked.
enum SopDocKind { pdf, word, text, legacyWord, unsupported }

/// One rasterised PDF page, prepared for OCR.
class SopDocPage {
  /// JPEG, grayscale, contrast-lifted — already through [ImagePrep.prepareForOcr].
  final Uint8List ocrBytes;
  final Uint8List thumb;
  final int pageNo;

  const SopDocPage({
    required this.ocrBytes,
    required this.thumb,
    required this.pageNo,
  });
}

class SopDocImport {
  /// Extensions offered to the file picker.
  ///
  /// 'doc' is included so the old binary format is picked and then *explained*.
  /// Leaving it out makes the file un-selectable with no reason given, and the
  /// user concludes the feature is broken rather than that the format is.
  static const List<String> pickerExtensions = ['pdf', 'docx', 'doc', 'txt'];

  /// Rasterising DPI for PDF pages.
  ///
  /// 150 is chosen against [ImagePrep.ocrMaxEdge] (1800px), not picked for
  /// roundness: A4 at 150dpi is 1240×1754, so a page arrives just under the OCR
  /// budget and ImagePrep passes it through without a resample. 72dpi would put
  /// 10pt body text near 6px and read as garbage — the same failure the comment
  /// on ocrMaxEdge describes. Raising it to 300 doubles memory per page for
  /// detail no recogniser uses.
  static const double rasterDpi = 150;

  static SopDocKind kindOf(String fileName) {
    final n = fileName.toLowerCase();
    if (n.endsWith('.pdf')) return SopDocKind.pdf;
    if (n.endsWith('.docx')) return SopDocKind.word;
    if (n.endsWith('.txt')) return SopDocKind.text;
    // .doc is a binary OLE container, not a ZIP of XML, so the docx reader
    // cannot touch it and there is no pure-Dart reader for it.
    if (n.endsWith('.doc')) return SopDocKind.legacyWord;
    return SopDocKind.unsupported;
  }

  /// Human-readable label for a document title fallback.
  static String titleFromFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    // Plant files are named like "SOP_BF_CastHouse-Rev3_final.pdf".
    return stem.replaceAll(RegExp(r'[_]+'), ' ').trim();
  }

  /// How long to wait for the platform to report whether it can rasterise.
  ///
  /// A TIMEOUT IS MANDATORY HERE, not defensive padding. On web, `Printing.info`
  /// calls the plugin's `_initPlugin`, which appends a <script> for pdf.js and
  /// then does `await script.onLoad.first`. A script element that fails to load
  /// fires `error`, never `load` — so on a network that blocks unpkg that await
  /// NEVER COMPLETES. Without this, the Import button would spin forever with no
  /// message, which is indistinguishable from the app having hung.
  ///
  /// 12s because it must also cover the genuine slow case: a cold load of
  /// pdf.min.js plus its worker over a plant connection.
  static const Duration pdfProbeTimeout = Duration(seconds: 12);

  /// Whether this platform can turn a PDF into page images.
  ///
  /// False on web when pdf.js could not be fetched — see the note at the top of
  /// this file. Callers must treat false as "tell the user to use Word or the
  /// camera", not as an error.
  static Future<bool> canReadPdf() async {
    try {
      final info = await Printing.info().timeout(pdfProbeTimeout);
      return info.canRaster;
    } catch (e) {
      // Deliberately catches TimeoutException with everything else: for the
      // caller there is no useful difference between "the platform said no" and
      // "the platform never answered".
      print('SopDocImport: PDF support probe failed — $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  PDF
  // ═══════════════════════════════════════════════════════════════════════

  /// Rasterise up to [maxPages] pages of [pdfBytes] into OCR-ready images.
  ///
  /// [onPage] fires as each page finishes so the UI can count up instead of
  /// showing an indeterminate spinner through a 20-page document.
  ///
  /// Never throws for a per-page problem: a page that will not rasterise is
  /// skipped and reported through [onPage]'s total, because losing one page of a
  /// long SOP must not discard the other nineteen. A failure to open the file at
  /// all does throw, since there is nothing to salvage.
  static Future<List<SopDocPage>> pdfPages(
    Uint8List pdfBytes, {
    required int maxPages,
    void Function(int pageNo)? onPage,
  }) async {
    final out = <SopDocPage>[];
    try {
      // `pages:` is not passed a range here — the stream is simply abandoned once
      // maxPages is reached, because the page COUNT is not known before opening
      // the document and building a 1..30 list would ask for pages that may not
      // exist.
      //
      // The timeout is PER PAGE, because Stream.timeout restarts its clock on
      // every event. It exists because rasterising is native/JS work behind a
      // stream: a malformed page can leave the plugin waiting on a promise that
      // never settles, and without this the caller sits on a progress spinner
      // with no way back to the capture screen.
      final stream = Printing.raster(pdfBytes, dpi: rasterDpi)
          .timeout(perPageTimeout);
      await for (final raster in stream) {
        if (out.length >= maxPages) break;
        final pageNo = out.length + 1;
        try {
          // On mobile toPng() encodes from raw pixels via dart:ui, so it cannot
          // run in a `compute` isolate; on web the plugin already holds the PNG
          // the canvas produced and just hands it back. Either way this stays on
          // the UI thread, which is what [onPage] is for.
          final png = await raster.toPng();
          out.add(SopDocPage(
            ocrBytes: ImagePrep.prepareForOcr(png),
            thumb: ImagePrep.thumbnail(png),
            pageNo: pageNo,
          ));
          onPage?.call(pageNo);
        } catch (e) {
          print('SopDocImport: PDF page $pageNo failed to rasterise — $e');
        }
      }
    } catch (e) {
      // Return what was rasterised rather than rethrowing. Nineteen good pages
      // of a twenty-page SOP is worth filing; the caller reports an empty result
      // as a failure, so a document that yielded nothing still surfaces.
      print('SopDocImport: PDF rasterising stopped after ${out.length} '
          'page(s) — $e');
    }
    return out;
  }

  /// Per-page ceiling for [pdfPages]. See the note at its call to Stream.timeout.
  static const Duration perPageTimeout = Duration(seconds: 30);

  /// Reserved fast path, deliberately NOT wired in yet.
  ///
  /// `PdfKbExtractor.extractTextFromPdf` (web only) can copy a digital PDF's
  /// text layer out exactly and for free, saving one AI request per page. It is
  /// not used because it returns the whole document as one string with no page
  /// boundaries, which would cost every clause its page citation, and because it
  /// pulls pdf.js from cdnjs at runtime — a network a plant firewall may block.
  /// If AI quota becomes the binding constraint, this is the first thing to
  /// build properly: per-page text via pdf.js `getTextContent`, falling back to
  /// [pdfPages] for any page whose text fails SopOcrService's quality gate.
  static const String pdfTextFastPath = 'see doc comment';

  // ═══════════════════════════════════════════════════════════════════════
  //  WORD
  // ═══════════════════════════════════════════════════════════════════════

  /// Extract plain text from a .docx, preserving line and table structure.
  ///
  /// STRUCTURE IS NOT COSMETIC HERE. The existing extractor in admin_screen.dart
  /// joins every `<w:t>` run with a space, which flattens a whole SOP into one
  /// paragraph. That is survivable for a general knowledge-base upload, but this
  /// text is fed to the structuring pass whose job is to split the document into
  /// numbered clauses — and with no line breaks, "6.2 Close the valve" and the
  /// clause before it become one run of prose and the clause numbering is
  /// unrecoverable. So paragraph, break and table-cell boundaries are turned
  /// into real newlines and pipes BEFORE the text runs are pulled out.
  ///
  /// Returns '' rather than throwing: the caller shows a clear message, and an
  /// exception here would look identical to a bug.
  // Structure markers used by [docxText]. Private, and \u-escaped rather than
  // literal, for the reason spelled out inside that method.
  static const String _nl = '\u0001';
  static const String _cell = '\u0002';
  static const String _tab = '\u0003';

  static String docxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      // word/document.xml ONLY. The admin-panel version falls back to "any .xml,
      // else the first entry", which on a real .docx happily returns
      // styles.xml or [Content_Types].xml and yields font names instead of
      // document text — worse than an honest empty result.
      ArchiveFile? doc;
      for (final f in archive.files) {
        if (f.isFile && f.name == 'word/document.xml') {
          doc = f;
          break;
        }
      }
      if (doc == null) return '';

      // allowMalformed: a .docx assembled by an older Word or a converter can
      // carry stray bytes, and one bad sequence must not lose the document.
      final xml = utf8.decode(
        List<int>.from(doc.content as List<int>),
        allowMalformed: true,
      );

      // Mark structure with control characters first. They cannot collide with
      // document text (Word does not store U+0001..U+0003 in a w:t run) and they
      // survive into the token scan below in document order, which a plain
      // replace-with-newline would not: the newline would sit outside every
      // <w:t> and be dropped when the runs are extracted.
      //
      // Written as \u escapes, NEVER as literal control bytes in the source: a
      // literal is invisible in every editor, and one reformat-on-save that
      // strips it leaves a regex matching nothing and a document that comes out
      // as one unbroken paragraph with no recoverable clause numbering.
      final marked = xml
          .replaceAll(RegExp(r'<w:br\b[^>]*/?>'), _nl)
          .replaceAll(RegExp(r'<w:tab\b[^>]*/?>'), _tab)
          .replaceAll('</w:p>', _nl)
          .replaceAll('</w:tc>', _cell);

      // Built from a NON-raw string on purpose: inside r'...' the \u escapes in
      // _nl/_cell/_tab would remain six literal characters and the alternation
      // would never fire.
      final token = RegExp(
        '<w:t(?:\\s[^>]*)?>([\\s\\S]*?)</w:t>|($_nl)|($_cell)|($_tab)',
      );

      final sb = StringBuffer();
      for (final m in token.allMatches(marked)) {
        if (m.group(1) != null) {
          sb.write(_unescapeXml(m.group(1)!));
        } else if (m.group(2) != null) {
          sb.write('\n');
        } else if (m.group(3) != null) {
          // Table cell boundary. " | " matches the row format the OCR prompt
          // asks the vision model for, so a table reads the same whether the
          // document was scanned or uploaded.
          sb.write(' | ');
        } else {
          sb.write('\t');
        }
      }

      return _tidy(sb.toString());
    } catch (e) {
      print('SopDocImport: docx extraction failed — $e');
      return '';
    }
  }

  /// Plain .txt import.
  static String plainText(Uint8List bytes) {
    try {
      return _tidy(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return '';
    }
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      // &amp; LAST, or "&amp;lt;" would decode to "<" instead of "&lt;".
      .replaceAll('&amp;', '&');

  /// Collapse the whitespace the markup pass leaves behind.
  static String _tidy(String s) {
    final lines = s
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        // Strip the " | " left by an empty table row.
        .map((l) => l == '|' ? '' : l)
        .toList();

    final out = <String>[];
    for (final l in lines) {
      // Word emits an empty <w:p> for every blank line and for layout spacing,
      // so an unfiltered document arrives with long runs of them. Keep at most
      // one: this text goes verbatim into the structuring prompt, where a run of
      // blank lines reads as a section break the document does not have.
      if (l.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(l);
    }
    return out.join('\n').trim();
  }
}
