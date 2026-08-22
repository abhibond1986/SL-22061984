// lib/screens/sop_scan_screen.dart
//
// Photograph a printed SOP / SMP, read it, and file it in the Knowledge Base so
// the AI chat can answer questions about it and cite the clause.
//
// THREE STAGES, one screen, no back-navigation between them beyond an explicit
// "Start over": Capture → Reading → Review & save. The stage is a single enum
// rather than a set of bools, because the earlier bool-pair pattern in this app
// permits impossible states (busy AND showing results) and this flow has real
// unsaved work in it — a page the user walked across the shop floor to
// photograph. Losing that to a state glitch is not recoverable by retrying.
//
// WHAT THIS SCREEN MUST NEVER DO: invent text. A page the readers could not
// handle is shown as failed with a Retake button. It is never saved with a
// placeholder, and it never contributes to the document. See the offline-scan
// history in gemini_vision.dart for what generated stand-in safety content
// costs.
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';
// FontFeature only. Imported explicitly rather than relied on from material's
// re-export of dart:ui, which is not guaranteed to include it.
import 'dart:ui' show FontFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart' show AppColors, SL, SLText;
import '../services/local_db.dart';
import '../services/network_checker.dart';
import '../services/plant_scope.dart';
import '../services/sop_doc_import.dart';
import '../services/sop_ocr_device.dart';
import '../services/sop_ocr_service.dart';
import '../services/sop_safety_analysis.dart';
import '../services/sync_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/universal_app_bar.dart';
import '../widgets/voice_text_field.dart';
import '../utils/image_prep.dart';

enum _Stage { capture, reading, review }

/// One page of the document and whatever we know about it so far.
///
/// Two kinds, which is why the byte fields can be empty. An IMAGE page came from
/// the camera, the gallery or a rasterised PDF, and has to be read by an OCR
/// tier. A TEXT page came from a Word or .txt file, where the text is already
/// exact — reading it again through OCR would be strictly worse: it would spend
/// an AI request to turn perfect text into an approximation of itself.
class _Page {
  /// OCR-prepared bytes (grayscale, contrast-lifted, long edge 1800).
  /// EMPTY for a text page — check [isText] before handing this to anything.
  Uint8List ocrBytes;

  /// Small preview. Kept separately so the grid is not decoding a 1800px image
  /// per thumbnail on every rebuild — with 30 pages that is what makes the
  /// review list stutter. Empty for a text page, which has nothing to show.
  Uint8List thumb;

  /// Text lifted straight out of an uploaded document. Empty for an image page.
  final String importedText;

  /// What to call this page in the list. Empty falls back to "Page N", which is
  /// right for photographs; an imported file says where it came from instead,
  /// because "Page 1" next to no thumbnail looks like a page that failed.
  final String label;

  /// Where [importedText] came from, recorded on the resulting PageOcr so the
  /// raw KB row is honest about its provenance. 'document' is an exact copy out
  /// of a .docx/.txt; 'text-layer' is an exact copy out of a PDF's text layer;
  /// 'paddleocr' is a recognition result that can misread a digit and must be
  /// flagged for checking. Meaningless for an image page.
  final String sourceEngine;

  PageOcr? result;

  _Page({
    required this.ocrBytes,
    required this.thumb,
    this.importedText = '',
    this.label = '',
    this.sourceEngine = 'document',
  });

  _Page.fromText({
    required String text,
    required this.label,
    this.sourceEngine = 'document',
  })  : ocrBytes = Uint8List(0),
        thumb = Uint8List(0),
        importedText = text;

  /// True when the text is already known and no reader is needed.
  ///
  /// Tested on the text rather than on a separate bool flag so the two can never
  /// disagree: a "text page" carrying no text would otherwise reach _readAll,
  /// skip OCR because the flag said so, and be filed as an empty page.
  bool get isText => importedText.trim().isNotEmpty;

  bool get failed => result != null && !result!.ok;
}

class SopScanScreen extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;

  /// True when this is a bottom-nav tab rather than a pushed route.
  ///
  /// Changes two things: saving resets the flow instead of calling
  /// Navigator.pop (there is nothing to pop), and [hasUnsavedWork] is kept
  /// current so HomeScreen can warn before a tab tap throws the pages away.
  final bool isTab;

  const SopScanScreen({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
    this.isTab = false,
  });

  /// Whether a scan in progress holds pages that are not in the KB yet.
  ///
  /// Static because the tab's State is DESTROYED on every bottom-nav switch —
  /// HomeScreen rebuilds the selected tab through an AnimatedSwitcher keyed by
  /// index, so by the time anything could ask the State whether it had unsaved
  /// work, the State is gone and the photographs with it. The flag has to live
  /// above the widget that owns the pages. Reset in dispose() so a stale `true`
  /// cannot block navigation forever.
  static final ValueNotifier<bool> hasUnsavedWork = ValueNotifier<bool>(false);

  @override
  State<SopScanScreen> createState() => _SopScanScreenState();
}

class _SopScanScreenState extends State<SopScanScreen> {
  _Stage _stage = _Stage.capture;

  final List<_Page> _pages = [];
  SopExtract? _extract;

  /// The safety read of the document: hazards, critical requirements, checklist.
  ///
  /// SEPARATE from [_extract] and nullable on purpose. The clause extract is what
  /// gets SAVED to the Knowledge Base; this is a reading aid shown on this screen
  /// only. Keeping them apart means a failed safety pass cannot block the save,
  /// and the save path in _save() needs no knowledge of this field at all — the
  /// user still files a perfectly good document when the analysis model is down.
  SopSafetyAnalysis? _safety;

  /// Whether the raw transcription is expanded in the review list.
  ///
  /// Collapsed by default: it is 20 pages of unformatted OCR text and would bury
  /// the requirements the screen exists to surface. It has to be REACHABLE
  /// though — it is the only way for the user to see what the AI actually read,
  /// and so the only way to tell a wrong requirement from a misread page.
  bool _showOcr = false;

  /// True when these pages came from an uploaded file rather than the camera.
  ///
  /// Kept as a flag rather than inferred from the pages, because a rasterised
  /// PDF page is byte-for-byte the same kind of thing as a photograph — the
  /// difference is only in what advice to give when it cannot be read, and
  /// "retake the photo" is the wrong thing to say about a file.
  bool _imported = false;

  // ── Reading progress ────────────────────────────────────────────────────
  //
  // Six fields rather than one spinner, because "it feels hung" was the actual
  // complaint and a spinner cannot answer any of the three questions a waiting
  // user is asking: how far along is it, how long has it been, and how much
  // longer. A read here can legitimately take four minutes — thirty pages on a
  // free vision tier — and four honest minutes is tolerable where forty
  // unexplained seconds is not.
  //
  // Pages are only part of the work. Two model calls follow the last page (the
  // clause split, then the safety pass) and each takes as long as a page, so a
  // bar that hit 100% at the last page would sit full and frozen through the
  // slowest part of the wait. [_phaseDone] counts those two, and the bar is
  // driven by pages + phases over total + 2.
  int _readDone = 0;

  /// Pages to read, or 0 when not yet known — which is genuinely the case while
  /// the OCR service is chewing on a whole document in one request. 0 means the
  /// bar goes indeterminate; it must never mean "no work".
  int _readTotal = 0;

  /// Completed post-read phases, 0–2: structure, then safety.
  int _phaseDone = 0;

  /// True when nothing has to be recognised — a .docx, or a PDF whose text layer
  /// the service read directly. Changes the estimate by two orders of magnitude,
  /// so it is worth telling the user which kind of wait they are in for.
  bool _fastRead = false;

  DateTime? _readStartedAt;
  Duration _elapsed = Duration.zero;

  /// Repaints the elapsed clock once a second. Nothing else in this screen ticks,
  /// so this is the only thing keeping the view visibly alive during a page that
  /// takes 40 seconds to come back — which is precisely the moment it looks dead.
  Timer? _elapsedTicker;

  String _progressNote = '';

  /// Warning about pages the OCR service could not read, held until after the
  /// read finishes. See where it is set in _importViaService.
  String _skippedPagesNote = '';

  // Review fields. Pre-filled from the extract, always editable — the AI's read
  // of a stamped, revised, hand-annotated plant document is a starting point,
  // not an authority.
  final _titleCtl = TextEditingController();
  final _sopNoCtl = TextEditingController();
  final _deptCtl = TextEditingController();

  PlantScope? _scope;
  // Resolved once in _loadScope, NOT in build(): selectablePlants() reads admin
  // master data, and a FutureBuilder whose `future:` is created inside build
  // re-runs that read on every rebuild — and this screen rebuilds on every page
  // captured, every OCR result and every keystroke in the title field.
  List<String> _plantOptions = const [];
  String _plant = '';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadScope();
  }

  @override
  void dispose() {
    // Before anything else: a live periodic timer calling setState on a disposed
    // State throws once a second into a console nobody is reading.
    _stopClock();
    _titleCtl.dispose();
    _sopNoCtl.dispose();
    _deptCtl.dispose();
    // Release the native ML Kit recogniser. Harmless on web (no-op stub) and
    // harmless if it was never created.
    SopOcrDevice.dispose();
    // Clear the guard unconditionally. If we are being disposed the pages are
    // already gone, so leaving it true would block every future tab switch on a
    // dialog about work that no longer exists.
    SopScanScreen.hasUnsavedWork.value = false;
    super.dispose();
  }

  /// Keeps [SopScanScreen.hasUnsavedWork] in step with the page list.
  ///
  /// Call after ANY mutation of _pages or after a save. Unsaved means "pages
  /// exist that are not in the KB yet" — which includes read pages sitting on
  /// the review screen, not just un-read captures, because those cost the same
  /// walk across the plant to replace.
  void _syncUnsavedFlag() {
    SopScanScreen.hasUnsavedWork.value = _pages.isNotEmpty;
  }

  Future<void> _loadScope() async {
    final scope = await PlantScope.forUser();
    // Only org-level users get a choice, so only they need the list.
    List<String> options = const [];
    if (!scope.isLocked) {
      try {
        options = await scope.selectablePlants();
      } catch (_) {
        // Master data unavailable — fall through with an empty list, which hides
        // the field rather than blocking the scan. Plant is metadata here; the
        // document is still worth saving without it.
      }
    }
    if (!mounted) return;
    setState(() {
      _scope = scope;
      _plantOptions = options;
      _plant = scope.plant;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  CAPTURE
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _addPages(ImageSource source) async {
    if (_imported) {
      // Same reasoning as the guard in _addDocument, from the other direction.
      _snack('Start over first — photographs cannot be added to an '
          'imported document.');
      return;
    }
    if (_pages.length >= SopOcrService.maxPages) {
      _snack('Maximum ${SopOcrService.maxPages} pages per document.');
      return;
    }
    final picker = ImagePicker();
    try {
      final List<XFile> picked;
      if (source == ImageSource.gallery) {
        // Multi-select: a user who has already photographed the document with
        // the phone's own camera app should not have to re-shoot it one page at
        // a time.
        picked = await picker.pickMultiImage();
      } else {
        // No imageQuality/maxWidth here, unlike the hazard scan. The picker's
        // own resize is aggressive and optimised for "is there a hazard in this
        // scene"; small printed body text does not survive it. ImagePrep does the
        // resizing, to the larger OCR budget.
        final one = await picker.pickImage(source: ImageSource.camera);
        picked = one == null ? const [] : [one];
      }
      if (picked.isEmpty) return;

      final room = SopOcrService.maxPages - _pages.length;
      final take = picked.take(room).toList();
      if (take.length < picked.length) {
        _snack('Added $room page(s) — limit is ${SopOcrService.maxPages}.');
      }

      for (final file in take) {
        // readAsBytes, not File — this is the one path that works identically on
        // web and mobile.
        final raw = await file.readAsBytes();
        final prepared = await _prepare(raw);
        if (!mounted) return;
        setState(() => _pages.add(prepared));
        _syncUnsavedFlag();
      }

      // Picking from the gallery is ONE action that delivers a whole document,
      // so reading starts by itself. The camera path deliberately does not:
      // there, pages arrive one at a time, and auto-reading after the first shot
      // would move the screen off capture before page 2 could be taken — and
      // spend an AI request per press of the shutter.
      if (source == ImageSource.gallery) await _autoRead();
    } catch (e) {
      print('SopScan: capture failed — $e');
      _snack('Could not open the camera or gallery.');
    }
  }

  /// Starts reading without being asked, after an upload delivered a document.
  ///
  /// Separate from calling [_readAll] directly so the one condition that must
  /// hold — that we are still sitting on the capture stage with pages — is
  /// stated once. Without it a slow rasterise finishing after the user pressed
  /// "Read" or "Start over" would restart the read underneath them.
  Future<void> _autoRead() async {
    if (!mounted || _stage != _Stage.capture || _pages.isEmpty) return;
    await _readAll();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  DOCUMENT IMPORT (PDF / Word / text)
  // ═══════════════════════════════════════════════════════════════════════

  /// Import a PDF, .docx or .txt as pages, then read it.
  ///
  /// PDF and Word take opposite routes on purpose. A Word file's text is exact,
  /// so it is used as-is. A PDF is rasterised and sent through OCR even when it
  /// has a perfectly good text layer, because most plant SOPs in circulation are
  /// scans of a signed paper copy — where there IS no text layer — and one path
  /// that always works beats two paths where the good one silently produces
  /// nothing. See SopDocImport.pdfTextFastPath for the other half of that trade.
  Future<void> _addDocument() async {
    if (_pages.isNotEmpty) {
      // Mixing an imported document into photographed pages produces one KB
      // entry claiming to be a single document, with two different page
      // numberings inside it. Refuse rather than quietly interleave.
      _snack('Start over first — a document is imported on its own.');
      return;
    }
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: SopDocImport.pickerExtensions,
        withData: true, // Required on web, where there is no file path.
      );
    } catch (e) {
      print('SopScan: file picker failed — $e');
      _snack('Could not open the file picker.');
      return;
    }
    if (result == null || result.files.isEmpty) return;
    // The picker is a long async gap during which the user can tap another
    // bottom-nav tab, and HomeScreen's AnimatedSwitcher DISPOSES this State when
    // they do. Every setState below would then throw. Checked once here rather
    // than before each one, since nothing between here and the end can remount.
    if (!mounted) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      _snack('Could not read that file.');
      return;
    }

    final kind = SopDocImport.kindOf(file.name);
    if (kind == SopDocKind.legacyWord) {
      // Named explicitly. ".doc" is a binary OLE container with no pure-Dart
      // reader, and a generic "unsupported file" leaves the user retrying the
      // same file instead of doing the one thing that fixes it.
      setState(() => _error =
          'Old Word format (.doc) cannot be read. Open it in Word and use '
          'Save As → Word Document (.docx), or print it to PDF.');
      return;
    }
    if (kind == SopDocKind.unsupported) {
      setState(() => _error = 'Pick a PDF, a Word .docx, or a .txt file.');
      return;
    }

    // Pre-fill the title from the filename now, before the read. The AI usually
    // overwrites it from the document's own header, but if the structuring pass
    // cannot be reached the filename is a far better fallback than blank — and
    // an empty title is the one thing that blocks saving.
    if (_titleCtl.text.trim().isEmpty) {
      _titleCtl.text = SopDocImport.titleFromFileName(file.name);
    }

    // ── Fast path: hand the whole file to the PaddleOCR service ───────────
    //
    // Tried first for every supported type, because it is better than every
    // route below it on the axis the user complained about. A PDF here skips
    // three separate costs: the pdf.js probe (fetched from a public CDN on
    // first use, and blocked on some plant networks), rasterising every page on
    // the UI thread, and then one vision-LLM request PER PAGE. A digital PDF
    // comes back in seconds having never touched an LLM.
    //
    // Returning null means "not configured or not reachable", and we fall
    // through to the original routes unchanged — so this is strictly additive.
    // A new document is an explicit fresh attempt, so clear any "service is
    // unreachable" verdict left over from a previous file. Otherwise a single
    // failure would send the next three minutes of imports down the slow path
    // even after the container has woken up.
    SopOcrService.resetServiceBreaker();
    if (await SopOcrService.serviceAvailable) {
      final handled = await _importViaService(bytes, file.name);
      if (handled) return; // _importViaService ran the read itself.
      if (!mounted) return;
    }

    if (kind == SopDocKind.pdf) {
      await _importPdf(bytes);
    } else {
      final text = kind == SopDocKind.word
          ? SopDocImport.docxText(bytes)
          : SopDocImport.plainText(bytes);
      if (text.trim().isEmpty) {
        setState(() => _error =
            'That file has no text in it. If it is a scan saved as a Word '
            'file, export it as a PDF and import that instead.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = null;
        _imported = true;
        _pages.add(_Page.fromText(text: text, label: file.name));
      });
      _syncUnsavedFlag();
    }

    await _autoRead();
  }

  /// Read a whole file through the PaddleOCR service.
  ///
  /// Returns true when it handled the file — including having run the read — so
  /// the caller stops. Returns false to mean "not available, use the old route",
  /// leaving no visible trace behind: the stage is put back and no error is
  /// shown, because a sleeping free-tier container is not something to report to
  /// a user who is about to get their document read anyway.
  Future<bool> _importViaService(Uint8List bytes, String fileName) async {
    setState(() {
      _error = null;
      _stage = _Stage.reading;
      _readDone = 0;
      // Genuinely unknown: the service reads the whole file in one request and
      // only reports a page count when it answers. Left at 0 so the bar shows
      // indeterminate rather than a made-up fraction.
      _readTotal = 0;
      _phaseDone = 0;
      _fastRead = false;
      _progressNote = 'Sending the document to the reader…';
    });
    _startClock(restart: true);

    final pages = await SopOcrService.readDocumentViaService(
      fileName: fileName,
      bytes: bytes,
      onProgress: (note) {
        if (mounted) setState(() => _progressNote = note);
      },
    );

    if (!mounted) return true; // Disposed — nothing left to do either way.
    if (pages == null) {
      // Falling back to the old route, which starts its own clock from zero.
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        _progressNote = '';
      });
      return false;
    }

    final readable = pages.where((p) => p.ok).toList();
    if (readable.isEmpty) {
      // readDocumentViaService only returns a list when at least one page read,
      // so this is unreachable today. Handled anyway rather than trusting a
      // guarantee made in another file.
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        _progressNote = '';
      });
      return false;
    }

    final skipped = pages.length - readable.length;
    setState(() {
      _imported = true;
      _pages.clear();
      for (final p in readable) {
        _pages.add(_Page.fromText(
          text: p.text,
          label: 'Page ${p.pageNo}',
          sourceEngine: p.engine,
        ));
      }
      // Say which pages were lost. This screen only carries text pages on this
      // route, so an unreadable one cannot be shown with a Retake button the way
      // a photograph can — it is simply absent, and the review screen's page
      // count would otherwise be computed over the survivors and look complete.
      // A user filing an SOP needs to know that clause 7 never made it in.
      //
      // Held in a field rather than written to _error here, because _readAll()
      // clears _error on entry and runs immediately below — the warning would be
      // wiped before it was ever painted.
      if (skipped > 0) {
        final lost = pages.where((p) => !p.ok).map((p) => p.pageNo).join(', ');
        _skippedPagesNote =
            '$skipped of ${pages.length} page(s) had no readable text and were '
            'left out (page $lost). If those pages matter, photograph them and '
            'scan them separately.';
      } else {
        _skippedPagesNote = '';
      }
    });
    _syncUnsavedFlag();

    // _readAll now has nothing to OCR — every page is a text page — so it goes
    // straight to structuring. Reused rather than duplicated so the structuring
    // pass, the safety pass, the failure messages and the stage transitions stay
    // in exactly one place.
    await _readAll();
    // Surface the skipped-pages warning only now, and only if _readAll did not
    // put a more urgent message of its own on screen.
    if (mounted && _skippedPagesNote.isNotEmpty && _error == null) {
      setState(() => _error = _skippedPagesNote);
    }
    return true;
  }

  Future<void> _importPdf(Uint8List bytes) async {
    // Enter the reading stage BEFORE the probe, not after. The probe itself can
    // take seconds on the browser — it fetches pdf.js on first use — and
    // _progressNote is only rendered by the reading view, so setting the note
    // while still on the capture stage would show the user nothing at all and
    // leave a dead-looking button, which is the exact failure this guards.
    setState(() {
      _error = null;
      _stage = _Stage.reading;
      _readDone = 0;
      _readTotal = 0; // Page count unknown until the PDF is opened.
      _phaseDone = 0;
      _fastRead = false;
      _progressNote = 'Checking PDF support…';
    });
    _startClock(restart: true);
    if (!await SopDocImport.canReadPdf()) {
      if (!mounted) return;
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        _progressNote = '';
        // Names the actual cause on web. The browser build fetches its PDF
        // engine from a public CDN on first use, and a plant network that blocks
        // it produces exactly this — a network problem, not a broken file, and
        // the user needs to know which.
        _error = kIsWeb
            ? 'This browser could not load its PDF engine — it is fetched from '
                'the internet on first use and may be blocked on this network. '
                'Use the phone app for PDFs, or import a Word .docx.'
            : 'PDFs cannot be opened on this device. Import a Word .docx, or '
                'photograph the pages.';
      });
      return;
    }
    if (!mounted) return;
    // Already on the reading stage from the probe above — this only advances the
    // note. It matters that this is a stage and not a snackbar: rasterising 20
    // pages takes real seconds on the UI thread (on mobile PdfRaster.toPng
    // encodes through dart:ui and cannot be moved to an isolate), and a screen
    // that looks idle while frozen reads as a crash.
    setState(() => _progressNote = 'Opening the PDF…');
    try {
      final pages = await SopDocImport.pdfPages(
        bytes,
        maxPages: SopOcrService.maxPages,
        onPage: (n) {
          if (!mounted) return;
          setState(() => _progressNote = 'Opening page $n…');
        },
      );
      if (!mounted) return;
      if (pages.isEmpty) {
        _stopClock();
        setState(() {
          _stage = _Stage.capture;
          _error = 'No pages could be opened from that PDF. It may be '
              'password-protected or damaged.';
        });
        return;
      }
      setState(() {
        _stage = _Stage.capture;
        _progressNote = '';
        _imported = true;
        for (final p in pages) {
          _pages.add(_Page(
              ocrBytes: p.ocrBytes,
              thumb: p.thumb,
              label: 'PDF page ${p.pageNo}'));
        }
      });
      _syncUnsavedFlag();
    } catch (e) {
      print('SopScan: PDF import failed — $e');
      if (!mounted) return;
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        _error = 'Could not open that PDF.';
      });
    }
  }

  /// Image preparation, off the UI thread where possible.
  ///
  /// Decoding and re-encoding an 1800px JPEG is tens of milliseconds of pure
  /// CPU; doing 30 of them inline drops frames visibly. `compute` isolates it on
  /// mobile. On web `compute` runs inline (no isolates), so the jank remains
  /// there — acceptable, because web users pick files rather than shooting a
  /// 30-page document, and the alternative is a web worker for one function.
  static _PrepResult _prepareSync(Uint8List raw) => _PrepResult(
        ImagePrep.prepareForOcr(raw),
        ImagePrep.thumbnail(raw),
      );

  Future<_Page> _prepare(Uint8List raw) async {
    try {
      final r = kIsWeb ? _prepareSync(raw) : await compute(_prepareSync, raw);
      return _Page(ocrBytes: r.ocr, thumb: r.thumb);
    } catch (e) {
      // A decode failure must not lose the page — hand the original bytes to the
      // readers and let them try. Worst case the quality gate rejects it and the
      // user retakes.
      print('SopScan: image prep failed, using original — $e');
      return _Page(ocrBytes: raw, thumb: raw);
    }
  }

  Future<void> _retake(int index) async {
    final picker = ImagePicker();
    try {
      final one = await picker.pickImage(source: ImageSource.camera);
      if (one == null) return;
      final prepared = await _prepare(await one.readAsBytes());
      if (!mounted) return;
      setState(() => _pages[index] = prepared);
    } catch (e) {
      print('SopScan: retake failed — $e');
    }
  }

  void _removePage(int index) {
    setState(() {
      _pages.removeAt(index);
      // Emptying the list ends the import, so the next pick is not refused by
      // the "start over first" guard in _addDocument.
      if (_pages.isEmpty) _imported = false;
    });
    _syncUnsavedFlag();
  }

  void _movePage(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= _pages.length) return;
    setState(() {
      final p = _pages.removeAt(index);
      _pages.insert(to, p);
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  PROGRESS CLOCK
  // ═══════════════════════════════════════════════════════════════════════

  /// Starts (or restarts) the elapsed clock. Safe to call twice: an import that
  /// rasterises pages and then reads them passes through here once per stage, and
  /// restarting would reset a timer the user has been watching. The second call
  /// is therefore a no-op while one is already running.
  void _startClock({bool restart = false}) {
    if (_elapsedTicker != null && !restart) return;
    _elapsedTicker?.cancel();
    _readStartedAt = DateTime.now();
    _elapsed = Duration.zero;
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _readStartedAt;
      // Guard on mounted, not just on non-null: a periodic timer outlives a
      // setState on a disposed State and throws where nobody sees it.
      if (!mounted || started == null) return;
      setState(() => _elapsed = DateTime.now().difference(started));
    });
  }

  void _stopClock() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  /// Overall fraction of the read, or null for indeterminate.
  ///
  /// Null is returned honestly rather than faked with a crawling animation: while
  /// the OCR service holds a whole document there is no page count to report, and
  /// a bar that advances on a guess teaches the user not to trust the bar.
  double? get _readFraction {
    if (_readTotal <= 0) return null;
    final done = _readDone + _phaseDone;
    final total = _readTotal + 2; // + structure + safety
    return (done / total).clamp(0.0, 1.0);
  }

  /// Seconds per page — measured once there is something to measure, guessed
  /// before that. The measured figure is slightly pessimistic because [_elapsed]
  /// also covers the PDF rasterise that ran before the first page was read; that
  /// error is in the direction of over-estimating the wait, which is the only
  /// direction that does not annoy anyone.
  double get _secondsPerPage {
    if (_readDone > 0 && _elapsed.inMilliseconds > 0) {
      return _elapsed.inMilliseconds / 1000 / _readDone;
    }
    if (_fastRead) return 0.5;
    // The on-device recogniser is roughly an order of magnitude quicker than a
    // queued free vision model, which is the whole reason the phone build feels
    // different from the browser one.
    return SopOcrDevice.isAvailable ? 4 : 22;
  }

  /// "about 2 min left", or '' when there is nothing honest to say.
  String get _remainingLabel {
    if (_readTotal <= 0) return '';
    final unitsLeft = (_readTotal - _readDone) + (2 - _phaseDone);
    if (unitsLeft <= 0) return 'finishing up';
    final secs = (unitsLeft * _secondsPerPage).round();
    if (secs <= 10) return 'a few seconds left';
    if (secs < 90) return 'about $secs sec left';
    return 'about ${(secs / 60).round()} min left';
  }

  static String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  READING
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _readAll() async {
    if (_pages.isEmpty) return;
    setState(() {
      _stage = _Stage.reading;
      _readDone = 0;
      _readTotal = _pages.length;
      _phaseDone = 0;
      _fastRead = _pages.every((p) => p.isText);
      _error = null;
      _progressNote = '';
      for (final p in _pages) {
        p.result = null;
      }
    });
    _startClock();

    final online = await NetworkChecker.hasInternet();
    // Only IMAGE pages need a reader. Guarded on that rather than on
    // _pages.isNotEmpty because an imported Word document already holds its
    // text, and the old test would have refused to file it offline — telling the
    // user to connect in order to read a file that needs no reading.
    final needsReader = _pages.any((p) => !p.isText);
    if (needsReader && !online && !SopOcrDevice.isAvailable) {
      if (!mounted) return;
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        _error = 'Reading needs either the app on a phone (offline reader) or '
            'an internet connection. ${SopOcrDevice.unavailableReason}.';
      });
      return;
    }

    // Sequential, not Future.wait. Parallel pages would fire 30 simultaneous
    // requests at a free tier that rate-limits per minute, turning a slow scan
    // into a failed one — the same reasoning that gave the hazard chain its
    // latency budgets.
    for (int i = 0; i < _pages.length; i++) {
      if (!mounted) return;
      final page = _pages[i];
      final PageOcr r;
      if (page.isText) {
        // No OCR call at all. engine 'document' rather than 'device' so the raw
        // KB row records honestly where this text came from — an exact copy out
        // of the file, which is the most trustworthy tier there is and should
        // not be filed under the name of a recogniser that never ran.
        r = PageOcr(
          pageNo: i + 1,
          text: page.importedText,
          engine: page.sourceEngine,
        );
      } else {
        setState(() =>
            _progressNote = 'Reading page ${i + 1} of ${_pages.length}…');
        r = await SopOcrService.readPage(
          page.ocrBytes,
          pageNo: i + 1,
          allowAi: online,
        );
      }
      if (!mounted) return;
      setState(() {
        _pages[i].result = r;
        _readDone = i + 1;
      });
    }

    final good = _pages.where((p) => p.result?.ok == true).toList();
    if (good.isEmpty) {
      if (!mounted) return;
      _stopClock();
      setState(() {
        _stage = _Stage.capture;
        // Two different messages, because the advice that fits a photograph is
        // useless for a PDF. Telling someone to hold the phone squarer when the
        // pages came out of a file they uploaded sent the last person hunting
        // for a photography problem while the real fault was at the provider.
        _error = _pages.any((p) => p.result?.error.isNotEmpty == true &&
                p.result!.error.contains('connection'))
            ? 'None of the pages could be read — the AI reader could not be '
                'reached. Check the connection and try again.'
            : _imported
                ? 'None of the pages could be read. If this PDF is a scan, the '
                    'pages may be too faint or too small; try a higher-quality '
                    'scan, or photograph the printed copy.'
                : 'None of the pages could be read. Retake them in better '
                    'light, square to the page, with the text filling the frame.';
      });
      return;
    }

    setState(() => _progressNote = 'Working out the clause structure…');
    final extract = await SopOcrService.structure(
      good.map((p) => p.result!).toList(),
      fallbackTitle: _titleCtl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _phaseDone = 1);

    _titleCtl.text = extract.title.isNotEmpty ? extract.title : _titleCtl.text;
    _sopNoCtl.text = extract.sopNumber;
    if (extract.department.isNotEmpty) _deptCtl.text = extract.department;

    // ── The safety pass ─────────────────────────────────────────────────────
    //
    // A SECOND model call, deliberately not folded into structure(). Two reasons:
    // the clause split and the safety read want different prompts and different
    // failure handling, and merging them would mean one bad JSON response loses
    // both. This one is also allowed to fail without consequence — analyse()
    // returns ok:false rather than throwing, the review screen simply shows no
    // safety section, and the document still saves.
    setState(() => _progressNote = 'Checking safety requirements…');
    final pageTexts = <int, String>{};
    for (final p in good) {
      final r = p.result!;
      // Later pages win a key collision, but pageNo is assigned per page by the
      // reader so a collision would be a bug upstream, not something to paper
      // over here.
      pageTexts[r.pageNo] = r.text;
    }
    final safety = await SopSafetyService.analyse(
      pageTexts,
      title: _titleCtl.text.trim(),
    );
    if (!mounted) return;
    _stopClock();

    setState(() {
      _phaseDone = 2;
      _extract = extract;
      _safety = safety.ok ? safety : null;
      _stage = _Stage.review;
      // Clear the reading note on the way out of this stage. The Save button
      // falls back to _progressNote while _saving is true, so a note left over
      // from the read shows up as the button's label for the moment before the
      // upload sets its own — "Checking safety requirements…" on a button the
      // user just pressed to save.
      _progressNote = '';
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SAVE
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _save() async {
    final extract = _extract;
    if (extract == null || _saving) return;
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      _snack('Give the document a title first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final user = await LocalDB.getCurrentUser();
      final who = (user?['name'] ?? '').toString();
      final sopNo = _sopNoCtl.text.trim();
      final dept = _deptCtl.text.trim();
      final read = _pages.where((p) => p.result?.ok == true).toList();

      // One group id ties every row of this document together, so the admin can
      // verify or delete it as a unit instead of hunting 20 loose entries.
      final group = 'sop-${DateTime.now().millisecondsSinceEpoch}';

      final rows = <Map<String, dynamic>>[];

      // ── Row 1: the raw transcription, deliberately NOT indexed ──────────
      //
      // indexed:false keeps it out of retrieval while still storing it. This is
      // not tidiness. Retrieval scores by keyword hit count, so a single blob
      // containing the entire document outscores every one of its own clause
      // rows on every query — the chat would answer with 20 pages of OCR text
      // and no citation, every time. The raw text stays for audit and for
      // re-structuring later when a better model is available.
      rows.add({
        'title': '$title — full scanned text'
            '${sopNo.isNotEmpty ? ' ($sopNo)' : ''}',
        'content': read
            .map((p) => '--- Page ${p.result!.pageNo} '
                '[${p.result!.engine}] ---\n${p.result!.text.trim()}')
            .join('\n\n'),
        'source': 'sop_scan_raw',
        'docGroup': group,
        'sopNumber': sopNo,
        'plant': _plant,
        'uploadedBy': who,
        'pageFrom': 1,
        'pageTo': read.length,
        'indexed': false,
        'verified': false,
      });

      // ── Header row: the summary the chat should reach first ─────────────
      //
      // Built as a list of optional lines and joined, so an absent field leaves
      // no blank line behind. Blank lines are not cosmetic here: this text goes
      // verbatim into the model's prompt, and a run of empty lines reads as a
      // section break the document does not have.
      final header = <String>[
        'Document: $title',
        if (sopNo.isNotEmpty) 'SOP/SMP number: $sopNo',
        if (extract.revision.isNotEmpty) 'Revision: ${extract.revision}',
        if (extract.issueDate.isNotEmpty) 'Issued: ${extract.issueDate}',
        if (dept.isNotEmpty) 'Department: $dept',
        if (_plant.isNotEmpty) 'Plant: $_plant',
        if (extract.scope.isNotEmpty) '\nScope / purpose:\n${extract.scope}',
        if (extract.ppe.isNotEmpty) '\nPPE required: ${extract.ppe.join(', ')}',
        if (extract.keyLimits.isNotEmpty) ...[
          '\nKey limits and set points:',
          ...extract.keyLimits.map((l) => '- $l'),
        ],
      ].join('\n');

      rows.add({
        'title': '$title — summary',
        'content': header.trim(),
        'source': 'sop_scan',
        'docGroup': group,
        'sopNumber': sopNo,
        'plant': _plant,
        'uploadedBy': who,
        'indexed': true,
        'verified': false,
      });

      // ── One row per clause: the retrievable, citable units ──────────────
      for (final c in extract.clauses) {
        final text = (c['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        final clauseNo = (c['clauseNo'] ?? '').toString().trim();
        final heading = (c['heading'] ?? '').toString().trim();
        final page = int.tryParse(c['page']?.toString() ?? '') ?? 0;
        final label = [
          if (clauseNo.isNotEmpty) 'Clause $clauseNo',
          if (heading.isNotEmpty) heading,
        ].join(' — ');
        rows.add({
          'title': label.isEmpty ? title : '$title · $label',
          // The document title is repeated inside the content on purpose: a
          // clause retrieved on its own must still say which SOP it came from,
          // because the chat sees the content, not the row's neighbours.
          'content': [
            'From: $title${sopNo.isNotEmpty ? ' ($sopNo)' : ''}',
            if (label.isNotEmpty) label,
            '',
            text,
          ].join('\n'),
          'source': 'sop_scan',
          'docGroup': group,
          'sopNumber': sopNo,
          'clauseNo': clauseNo,
          'plant': _plant,
          'uploadedBy': who,
          if (page > 0) 'pageFrom': page,
          if (page > 0) 'pageTo': page,
          'indexed': true,
          'verified': false,
        });
      }

      // One bulk local write, then push. Writing locally first means the
      // document survives a failed upload — the sync layer will retry it — and
      // the single write bumps kbRevision exactly once, which is what clears
      // GeminiVision's KB context cache (wired in main.dart) so the very next
      // chat question sees this document.
      final ids = await LocalDB.addKnowledgeDocs(rows);

      int pushed = 0;
      try {
        pushed = await SyncService.pushNewKbDocs(
          ids,
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() => _progressNote = 'Uploading $done of $total…');
          },
        );
      } catch (e) {
        print('SopScan: cloud push failed — $e');
      }

      if (!mounted) return;
      final cloudNote = pushed == ids.length
          ? 'synced'
          : 'saved on this device — will sync later';
      final note = SnackBar(
        content: Text('Added "$title" to the Knowledge Base '
            '(${extract.clauses.length} clause(s), $cloudNote). '
            'An admin should verify it.'),
        duration: const Duration(seconds: 5),
      );

      // The document is in the KB now, so nothing is at risk any more — release
      // the navigation guard BEFORE anything else, or a save followed by a tab
      // tap prompts about work that is already filed.
      SopScanScreen.hasUnsavedWork.value = false;

      // Grab the messenger BEFORE popping. Reading it from `context` afterwards
      // looks up a deactivated element and the confirmation is silently lost —
      // exactly the case where the user needs to be told the work was saved.
      final messenger = ScaffoldMessenger.of(context);

      if (widget.isTab) {
        // As a tab there is no route to pop — popping would tear down the whole
        // HomeScreen. Reset to a clean capture stage instead, which is also the
        // right end state: an admin scanning a stack of SOPs starts the next one
        // immediately rather than re-entering the tab.
        setState(() {
          _pages.clear();
          _imported = false;
          _extract = null;
          _safety = null;
          _showOcr = false;
          _stage = _Stage.capture;
          _readDone = 0;
          _readTotal = 0;
          _phaseDone = 0;
          _fastRead = false;
          _elapsed = Duration.zero;
          _progressNote = '';
          _skippedPagesNote = '';
          _saving = false;
          _error = null;
          _titleCtl.clear();
          _sopNoCtl.clear();
          _deptCtl.clear();
          // _plant deliberately kept — the next document is almost always from
          // the same plant, and for a locked user it is not editable anyway.
        });
      } else {
        Navigator.of(context).pop(true);
      }
      messenger.showSnackBar(note);
    } catch (e) {
      print('SopScan: save failed — $e');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the document. $e';
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      // Transparent as a tab, matching AIScanTab and NearMissTab: HomeScreen
      // paints the gradient behind the whole body, and an opaque colour here
      // would cover it and make this one tab look flat next to the other five.
      backgroundColor: widget.isTab ? Colors.transparent : sl.bg,
      appBar: UniversalAppBar(
        title: 'Scan SOP / SMP',
        subtitle: _stageLabel,
        user: widget.user,
        toggleTheme: widget.toggleTheme,
        onSignOut: widget.onSignOut,
        isDark: widget.isDark,
        showExport: false,
      ),
      body: SafeArea(
        // As a tab, SafeArea must NOT reserve the bottom inset: HomeScreen sets
        // extendBody: true so the blurred nav bar sits over the content, and
        // taking the inset here would stack that gap on top of the scroll
        // padding below and leave a visible dead band above the bar.
        bottom: !widget.isTab,
        child: Container(
          // Only paint a gradient in pushed mode. As a tab, HomeScreen has
          // already painted this exact gradient behind the body, so a second one
          // is wasted raster work on every rebuild.
          // sl.bgGradient is a List<Color>, not a Gradient — it feeds the
          // `colors:` slot. Same begin/end as every other screen so this one
          // doesn't run its gradient at a different angle.
          decoration: widget.isTab
              ? null
              : BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: sl.bgGradient,
                  ),
                ),
          // Written as an if-chain, not a `switch` expression: STATUS.md records
          // that the CI toolchain (Flutter 3.19.6) has tripped on Dart 3
          // record/pattern switch expressions, and a build failure is a poor
          // trade for three saved lines. The enum still guarantees the states
          // are exhaustive — _reviewView is the last branch rather than a
          // default, so adding a fourth stage shows up as a blank screen here
          // instead of compiling into the wrong view.
          child: _stage == _Stage.capture
              ? _captureView(sl)
              : _stage == _Stage.reading
                  ? _readingView(sl)
                  : _reviewView(sl),
        ),
      ),
    );
  }

  String get _stageLabel {
    // See the note in build() — no switch expressions, for CI's sake.
    if (_stage == _Stage.capture) {
      return _pages.isEmpty
          ? 'Photograph each page'
          : '${_pages.length} page(s) ready';
    }
    if (_stage == _Stage.reading) {
      // _pages is still empty while a PDF is being opened — this stage is
      // entered before the pages exist — and "Reading 0 of 0" reads as a bug.
      if (_pages.isEmpty) return 'Opening the document';
      // _readTotal, not _pages.length: on the service route the pages exist
      // before the total is known, and the two would disagree.
      final total = _readTotal > 0 ? _readTotal : _pages.length;
      if (_readDone >= total) return 'Almost done';
      return 'Reading ${_readDone + 1} of $total';
    }
    return 'Check before saving';
  }

  // ── Stage 1: capture ──────────────────────────────────────────────────

  /// Scroll padding for the two list views.
  ///
  /// The extra bottom space is not cosmetic: as a tab, the translucent nav bar
  /// is drawn OVER the body (extendBody), so without it the "Read N page(s)" and
  /// "Save to Knowledge Base" buttons — the only way forward in each stage — sit
  /// underneath the bar and cannot be tapped at all. 100 matches the value the
  /// other tabs use for the same reason.
  EdgeInsets get _listPadding =>
      EdgeInsets.fromLTRB(16, 16, 16, widget.isTab ? 100 : 16);

  Widget _captureView(SL sl) {
    return ListView(
      padding: _listPadding,
      children: [
        if (_error != null) _errorBanner(sl, _error!),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.document_scanner_outlined,
                    size: 20, color: sl.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Photograph the document',
                      style: TextStyle(
                          color: sl.text1,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 10),
              Text(
                'One photo per page, in order. Hold the phone square to the '
                'page, fill the frame with the text, and avoid shadow across '
                'the middle. Up to ${SopOcrService.maxPages} pages.\n\n'
                'Already have the file? Import a PDF, a Word .docx or a .txt '
                'instead — it starts reading on its own.',
                style: SLText.bodySmall(sl),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _addPages(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    label: Text('Camera', style: SLText.button(sl)
                        .copyWith(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _addPages(ImageSource.gallery),
                    icon: Icon(Icons.photo_library_outlined,
                        size: 18, color: sl.accentText),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: sl.border),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    label: Text('Photos',
                        style: SLText.button(sl).copyWith(color: sl.accentText)),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              // Full width and on its own row. Three buttons across cannot hold
              // readable labels on a 320px screen, and this is the fastest route
              // for anyone who already has the SOP as a file — which, for a
              // document that was issued electronically, is most people.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _addDocument,
                  icon: Icon(Icons.upload_file_outlined,
                      size: 18, color: sl.accentText),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: sl.border),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  label: Text('Import PDF or Word',
                      style: SLText.button(sl).copyWith(color: sl.accentText)),
                ),
              ),
              if (!SopOcrDevice.isAvailable) ...[
                const SizedBox(height: 12),
                Text(
                  'On this platform the pages are read by the AI reader, which '
                  'needs a connection. The phone app reads them offline.',
                  style: SLText.hint(sl),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_pages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(children: [
              Icon(Icons.description_outlined, size: 48, color: sl.text4),
              const SizedBox(height: 12),
              Text('No pages yet', style: SLText.body(sl)),
            ]),
          )
        else ...[
          Text('Pages (${_pages.length})',
              style: TextStyle(
                  color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          for (int i = 0; i < _pages.length; i++) _pageTile(sl, i),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _readAll,
              icon: const Icon(Icons.auto_awesome, size: 18),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              label: Text('Read ${_pages.length} page(s)',
                  style: SLText.button(sl).copyWith(color: Colors.white)),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _pageTile(SL sl, int i) {
    final p = _pages[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: sl.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sl.border),
      ),
      child: Row(children: [
        // A text page has no thumbnail to show. Image.memory on an empty list
        // throws inside the paint phase, which is the worst place for it: the
        // error is a red box every frame rather than a message anyone can act on.
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: p.isText
              ? Container(
                  width: 46,
                  height: 60,
                  color: sl.card3,
                  child: Icon(Icons.article_outlined,
                      size: 20, color: sl.accentText),
                )
              : Image.memory(p.thumb,
                  width: 46, height: 60, fit: BoxFit.cover,
                  gaplessPlayback: true),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.label.isEmpty ? 'Page ${i + 1}' : p.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                  p.isText
                      ? 'Text read from the file · '
                          '${p.importedText.length} characters'
                      : _sizeLabel(p.ocrBytes.length),
                  style: SLText.hint(sl)),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Move up',
          onPressed: i == 0 ? null : () => _movePage(i, -1),
          icon: Icon(Icons.arrow_upward, size: 18, color: sl.text3),
        ),
        IconButton(
          tooltip: 'Move down',
          onPressed: i == _pages.length - 1 ? null : () => _movePage(i, 1),
          icon: Icon(Icons.arrow_downward, size: 18, color: sl.text3),
        ),
        // No Retake for an imported page: there is no photograph to retake, and
        // the camera shot it would substitute would sit in the middle of a
        // rasterised PDF at a different scale and page numbering.
        if (!_imported)
          IconButton(
            tooltip: 'Retake',
            onPressed: () => _retake(i),
            icon: Icon(Icons.refresh, size: 18, color: sl.accentText),
          ),
        IconButton(
          tooltip: 'Remove',
          onPressed: () => _removePage(i),
          icon: Icon(Icons.delete_outline, size: 18, color: sl.redText),
        ),
      ]),
    );
  }

  static String _sizeLabel(int bytes) =>
      '${(bytes / 1024).round()} KB';

  // ── Stage 2: reading ──────────────────────────────────────────────────

  /// The waiting screen — rebuilt because a bare spinner was the single thing the
  /// user named as broken about this feature ("no idea how long is left or which
  /// page it is on, so it feels hung").
  ///
  /// Four things are on it, in the order a waiting person wants them: a
  /// percentage and a bar, the counters (page N of M, elapsed, remaining), the
  /// three phases of the job with the current one marked, and last the
  /// explanation of why this particular document is quick or slow. Nothing here
  /// is decorative; every line answers a question that the spinner refused to.
  Widget _readingView(SL sl) {
    final f = _readFraction;
    final pct = f == null ? null : (f * 100).round();
    final remaining = _remainingLabel;

    return ListView(
      padding: _listPadding,
      children: [
        const SizedBox(height: 8),
        GlassCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // The spinner stays, small, beside the number. It is the only
                  // thing on screen that moves when a single page takes 40
                  // seconds and neither the percentage nor the counter changes.
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(sl.accentText),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _progressNote.isEmpty ? 'Reading…' : _progressNote,
                      style: TextStyle(
                        color: sl.text1,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (pct != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$pct%',
                      style: TextStyle(
                        color: sl.accentText,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        // Tabular figures so the number does not jitter
                        // sideways as it climbs through 9→10→11%.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  // Null while the page count is unknown. Deliberately not
                  // faked — see [_readFraction].
                  value: f,
                  minHeight: 8,
                  backgroundColor: sl.card3,
                  valueColor: AlwaysStoppedAnimation<Color>(sl.accentText),
                ),
              ),
              const SizedBox(height: 12),
              // Wrap, not Row: three chips at a large accessibility text scale
              // overflow a 320px phone, and an overflowing progress card is a
              // worse look than a wrapped one.
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  if (_readTotal > 0)
                    _progressStat(
                      sl,
                      Icons.description_outlined,
                      _readDone >= _readTotal
                          ? 'All $_readTotal page(s) read'
                          : 'Page ${_readDone + 1} of $_readTotal',
                    ),
                  _progressStat(
                      sl, Icons.timer_outlined, '${_clock(_elapsed)} elapsed'),
                  if (remaining.isNotEmpty)
                    _progressStat(sl, Icons.hourglass_bottom, remaining),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // The three phases. Shown as a list rather than folded into the note
        // because two model calls happen AFTER the last page, and a user who has
        // watched "Page 12 of 12" sit still for a minute needs to see that two
        // more steps were always part of the job.
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              _phaseRow(sl, 0, 'Read the pages',
                  _readTotal > 0 && _readDone >= _readTotal),
              _phaseRow(sl, 1, 'Work out the clauses', _phaseDone >= 1),
              _phaseRow(sl, 2, 'Check safety requirements', _phaseDone >= 2),
            ],
          ),
        ),
        const SizedBox(height: 12),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _readingHint,
            style: SLText.hint(sl),
          ),
        ),
      ],
    );
  }

  /// Why this document is quick or slow, in the user's terms.
  ///
  /// An honest up-front expectation is what turns a long wait from a fault into
  /// a fact. The three cases are genuinely two orders of magnitude apart, so one
  /// generic sentence would be wrong for all of them.
  String get _readingHint {
    if (_pages.isEmpty) {
      return 'Opening the document. If it is a PDF with real text in it, this is '
          'the whole job and it takes seconds. If it is a scan, each page has to '
          'be recognised one at a time.';
    }
    if (_fastRead) {
      return 'The text came straight out of the file, so there is nothing to '
          'recognise — only the clause structure and the safety check left, '
          'which is a few seconds each.';
    }
    if (SopOcrDevice.isAvailable) {
      return 'Reading on this phone first and asking the AI only for pages it '
          'cannot handle, which is why most pages come back in a couple of '
          'seconds. You can leave this screen open; it will not stop.';
    }
    return 'Each page is being read by a free AI reader, one at a time, and a '
        'page can take up to half a minute when the service is busy. This is '
        'expected — nothing has stalled. Photographs of clean, well-lit pages '
        'read fastest.';
  }

  Widget _progressStat(SL sl, IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: sl.text4),
          const SizedBox(width: 5),
          Text(text, style: SLText.hint(sl)),
        ],
      );

  /// One line of the phase list: done, running, or not started.
  Widget _phaseRow(SL sl, int index, String label, bool done) {
    // "Running" is the first phase that is not done — not a stored field, so the
    // list cannot contradict the bar.
    final firstUnfinished = (_readTotal > 0 && _readDone >= _readTotal)
        ? (_phaseDone >= 2 ? 3 : _phaseDone + 1)
        : 0;
    final running = !done && index == firstUnfinished;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: done
                ? Icon(Icons.check_circle, size: 18, color: sl.greenText)
                : running
                    ? CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(sl.accentText),
                      )
                    : Icon(Icons.radio_button_unchecked,
                        size: 16, color: sl.text4.withOpacity(0.6)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: done || running ? sl.text2 : sl.text4,
                fontSize: 13,
                fontWeight: running ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stage 3: review ───────────────────────────────────────────────────

  Widget _reviewView(SL sl) {
    final extract = _extract!;
    final failed = _pages.where((p) => p.failed).length;
    final readOk = _pages.length - failed;

    return ListView(
      padding: _listPadding,
      children: [
        if (_error != null) _errorBanner(sl, _error!),

        // The honest state of the read, before anything else. A user who scrolls
        // straight to Save should already have seen how many pages were lost.
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(failed == 0 ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                    size: 18,
                    color: failed == 0 ? sl.greenText : sl.amberText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    failed == 0
                        ? 'All $readOk page(s) read'
                        : '$readOk of ${_pages.length} page(s) read — '
                            '$failed could not be read',
                    style: TextStyle(
                        color: sl.text1,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
              if (failed > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Unreadable pages are NOT included. Saving now files an '
                  'incomplete document. Start over to retake them.',
                  style: SLText.bodySmall(sl),
                ),
              ],
              if (!extract.aiStructured) ...[
                const SizedBox(height: 8),
                Text(
                  'The AI could not be reached to split this into clauses, so '
                  'it is being filed one entry per page without clause '
                  'numbers. The chat can still find it, but cannot cite a '
                  'clause.',
                  style: SLText.bodySmall(sl).copyWith(color: sl.amberText),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Editable metadata.
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Document details',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Correct anything the reader got wrong — these are what the '
                  'chat will quote back.', style: SLText.hint(sl)),
              const SizedBox(height: 12),
              VoiceTextField(controller: _titleCtl, label: 'Title'),
              const SizedBox(height: 10),
              VoiceTextField(
                  controller: _sopNoCtl, label: 'SOP / SMP number'),
              const SizedBox(height: 10),
              VoiceTextField(controller: _deptCtl, label: 'Department / shop'),
              const SizedBox(height: 10),
              _plantField(sl),
              if (extract.revision.isNotEmpty ||
                  extract.issueDate.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  [
                    if (extract.revision.isNotEmpty)
                      'Revision ${extract.revision}',
                    if (extract.issueDate.isNotEmpty)
                      'Issued ${extract.issueDate}',
                  ].join(' · '),
                  style: SLText.hint(sl),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        if (extract.ppe.isNotEmpty)
          _chipsCard(sl, 'PPE required', extract.ppe, Icons.health_and_safety_outlined),
        if (extract.keyLimits.isNotEmpty)
          _chipsCard(sl, 'Key limits', extract.keyLimits, Icons.speed_outlined),

        // ── The safety read ──────────────────────────────────────────────────
        //
        // Placed ABOVE the clause list. The clauses are the archival record; these
        // are the things that decide whether the job is safe to start, and a user
        // who reads only the first screenful should get those.
        ..._safetySections(sl),

        // Clauses.
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  extract.clauses.isEmpty
                      ? 'No clauses found'
                      : '${extract.clauses.length} clause(s)',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              for (final c in extract.clauses) _clauseRow(sl, c),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Raw OCR text. OUTSIDE _safetySections on purpose: when the safety pass
        // fails this is the one thing still worth showing, because it is how the
        // user checks whether the reader saw the page at all.
        _ocrTextCard(sl),
        const SizedBox(height: 14),

        // The trust statement. This screen is open to any user by design, so the
        // person saving is told plainly that the document enters unverified.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.amber.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.amber.withOpacity(0.35)),
          ),
          child: Row(children: [
            Icon(Icons.info_outline, size: 18, color: sl.amberText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This will be saved as an UNVERIFIED scan. The AI will use it '
                'but will say it is unverified, and an official document '
                'uploaded by an admin takes priority over it.',
                style: SLText.bodySmall(sl),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),

        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _stage = _Stage.capture;
                        _extract = null;
                        _safety = null;
                        _showOcr = false;
                        _error = null;
                      }),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: sl.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text('Back to pages',
                  style: SLText.button(sl).copyWith(color: sl.text2)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white)))
                  : const Icon(Icons.library_add_outlined, size: 18),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              label: Text(
                  _saving
                      ? (_progressNote.isEmpty ? 'Saving…' : _progressNote)
                      : 'Add to Knowledge Base',
                  style: SLText.button(sl).copyWith(color: Colors.white)),
            ),
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _plantField(SL sl) {
    final scope = _scope;
    if (scope == null) return const SizedBox.shrink();
    if (scope.isLocked) {
      return Row(children: [
        Icon(Icons.factory_outlined, size: 16, color: sl.text3),
        const SizedBox(width: 8),
        Text('Plant: ${scope.plant}', style: SLText.bodySmall(sl)),
      ]);
    }
    // Org-level users pick, from the list _loadScope already resolved.
    final options = _plantOptions;
    if (options.isEmpty) return const SizedBox.shrink();
    return DropdownButtonFormField<String>(
      value: options.contains(_plant) ? _plant : null,
      isExpanded: true,
      dropdownColor: sl.card2,
      decoration: InputDecoration(
        labelText: 'Plant',
        labelStyle: SLText.label(sl),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: sl.border)),
      ),
      style: TextStyle(color: sl.text1, fontSize: 13),
      items: [
        for (final p in options) DropdownMenuItem(value: p, child: Text(p))
      ],
      onChanged: (v) => setState(() => _plant = v ?? ''),
    );
  }

  Widget _chipsCard(SL sl, String title, List<String> items, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 16, color: sl.accentText),
              const SizedBox(width: 8),
              Text(title,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final it in items)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: sl.card3,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: sl.border),
                    ),
                    child: Text(it,
                        style: TextStyle(color: sl.text2, fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _clauseRow(SL sl, Map<String, dynamic> c) {
    final no = (c['clauseNo'] ?? '').toString();
    final heading = (c['heading'] ?? '').toString();
    final text = (c['text'] ?? '').toString();
    final page = c['page'];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: sl.card2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: sl.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (no.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(no,
                    style: TextStyle(
                        color: sl.accentText,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            Expanded(
              child: Text(heading.isEmpty ? 'Clause' : heading,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            if (page != null && page != 0)
              Text('p.$page', style: SLText.hint(sl)),
          ]),
          const SizedBox(height: 6),
          Text(
            text.length > 400 ? '${text.substring(0, 400)}…' : text,
            style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SAFETY READ — critical requirements, checklist, issues, disclaimer
  //
  //  Returns a LIST so the whole block can be absent. An empty list is the
  //  correct rendering when the analysis model could not be reached: no empty
  //  card, no "0 requirements found" heading, nothing that could be mistaken for
  //  "this document places no safety requirements on the job".
  // ═══════════════════════════════════════════════════════════════════════

  List<Widget> _safetySections(SL sl) {
    final s = _safety;
    if (s == null) {
      // Say so, once, quietly. Silence here would leave a user who scanned a
      // permit-to-work wondering whether the AI found nothing or never ran.
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            Icon(Icons.cloud_off_outlined, size: 15, color: sl.text3),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'The safety analysis could not be produced for this document. '
                'The scan and the clauses above are unaffected and can still be '
                'saved.',
                style: SLText.hint(sl),
              ),
            ),
          ]),
        ),
      ];
    }

    return [
      _safetyHeaderCard(sl, s),
      const SizedBox(height: 14),
      if (s.criticalRequirements.isNotEmpty) ...[
        _criticalCard(sl, s),
        const SizedBox(height: 14),
      ],
      if (s.hazards.isNotEmpty) ...[
        _hazardsCard(sl, s),
        const SizedBox(height: 14),
      ],
      if (s.checklist.isNotEmpty) ...[
        _checklistCard(sl, s),
        const SizedBox(height: 14),
      ],
      if (s.populatedCategories.isNotEmpty) ...[
        _categoriesCard(sl, s),
        const SizedBox(height: 14),
      ],
      if (s.issues.isNotEmpty) ...[
        _issuesCard(sl, s),
        const SizedBox(height: 14),
      ],
      // The AI disclaimer sits at the END of the safety block, immediately after
      // the last AI-generated claim and before the archival clause list. Putting
      // it at the top would have it scrolled away by the time the user reaches
      // the requirements it qualifies.
      _disclaimerCard(sl, s),
      const SizedBox(height: 14),
    ];
  }

  /// Document type, activity, equipment and the overall risk level.
  Widget _safetyHeaderCard(SL sl, SopSafetyAnalysis s) {
    final facts = <String>[
      if (s.docType.isNotEmpty) s.docType,
      if (s.activity.isNotEmpty) s.activity,
      if (s.equipment.isNotEmpty) s.equipment,
    ];
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined, size: 16, color: sl.accentText),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Safety analysis',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
            if (s.riskLevel.isNotEmpty) _riskPill(sl, s.riskLevel),
          ]),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(facts.join(' · '), style: SLText.bodySmall(sl)),
          ],
          if (s.truncated) ...[
            const SizedBox(height: 8),
            Text(
              'This document was too long to analyse in full — only the earlier '
              'pages were assessed. Requirements printed later in the document '
              'may be missing from the lists below.',
              style: SLText.bodySmall(sl).copyWith(color: sl.amberText),
            ),
          ],
        ],
      ),
    );
  }

  /// HIGH / MEDIUM / LOW badge.
  ///
  /// Uses the plant signage convention already in AppColors, and the *Text/
  /// *Beacon getters via SL rather than the raw hex, because red at 4.40:1 on a
  /// dark card misses AA — the same reason every other status label in this app
  /// goes through sl.
  Widget _riskPill(SL sl, String level) {
    final up = level.toUpperCase();
    final Color fg = up == 'HIGH'
        ? sl.redText
        : up == 'MEDIUM'
            ? sl.amberText
            : sl.greenText;
    final Color base =
        up == 'HIGH' ? AppColors.red : up == 'MEDIUM' ? AppColors.amber : AppColors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withOpacity(0.15),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: base.withOpacity(0.40)),
      ),
      child: Text('$up RISK',
          style:
              TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }

  Widget _criticalCard(SL sl, SopSafetyAnalysis s) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.report_problem_outlined, size: 16, color: sl.redText),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'Critical safety requirements '
                  '(${s.criticalRequirements.length})',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            s.unverifiedCount == 0
                ? 'Every requirement below was matched to text found in the '
                    'document. Tap one to see the page and the exact wording.'
                : '${s.unverifiedCount} of ${s.criticalRequirements.length} '
                    'could NOT be matched to the scanned text and are marked '
                    'unverified — check those against the paper document.',
            style: SLText.hint(sl),
          ),
          const SizedBox(height: 10),
          for (final r in s.criticalRequirements) _requirementRow(sl, r),
        ],
      ),
    );
  }

  Widget _hazardsCard(SL sl, SopSafetyAnalysis s) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.dangerous_outlined, size: 16, color: sl.amberText),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Hazards identified (${s.hazards.length})',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 10),
          for (final h in s.hazards) _requirementRow(sl, h),
        ],
      ),
    );
  }

  /// One requirement or hazard, colour-led by criticality and tappable.
  ///
  /// The colour is on a left BAR rather than on the text: criticality is a
  /// property of the requirement, not of its legibility, and colouring 60
  /// characters of body copy amber costs contrast on the thing the user has to
  /// actually read. The bar carries the signal, the text stays at full contrast,
  /// and the word HIGH/MEDIUM/LOW is printed as well so the meaning does not
  /// depend on colour vision.
  Widget _requirementRow(SL sl, SopRequirement r) {
    final label = criticalityLabel(r.criticality);
    final Color base = r.criticality == SopCriticality.high
        ? AppColors.red
        : r.criticality == SopCriticality.medium
            ? AppColors.amber
            : AppColors.green;
    final Color fg = r.criticality == SopCriticality.high
        ? sl.redText
        : r.criticality == SopCriticality.medium
            ? sl.amberText
            : sl.greenText;

    final hasSource = r.sourceText.trim().isNotEmpty || r.sourcePage != 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: sl.card2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: sl.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 3, color: base),
          Expanded(
            child: InkWell(
              // Not tappable when there is nothing to show. A tap that opens an
              // empty sheet reads as a broken screen.
              onTap: hasSource ? () => _showSource(sl, r) : null,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: base.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        // 10px, not 9. The 9px waiver granted for the bottom-nav
                        // labels does not extend here: a nav label is a fixed,
                        // learned word next to an icon, whereas HIGH/MEDIUM/LOW
                        // is the safety signal itself and is read on a phone at
                        // arm's length on a shop floor.
                        child: Text(label,
                            style: TextStyle(
                                color: fg,
                                fontSize: 10,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 6),
                      if (!r.verified)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: sl.card3,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: sl.border),
                          ),
                          child: Text('UNVERIFIED',
                              style: TextStyle(
                                  color: sl.text3,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700)),
                        ),
                      const Spacer(),
                      if (r.sourcePage != 0)
                        Text('p.${r.sourcePage}', style: SLText.hint(sl)),
                      if (hasSource) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 14, color: sl.text3),
                      ],
                    ]),
                    const SizedBox(height: 6),
                    Text(r.requirement,
                        style: TextStyle(
                            color: sl.text1, fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The source sheet: where this came from, verbatim.
  ///
  /// This is the whole traceability story in one screen. The user is standing in
  /// front of the paper document, so the useful thing is the page number plus the
  /// exact printed wording to find with their eye — not a paraphrase.
  void _showSource(SL sl, SopRequirement r) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: sl.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Where this came from',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(r.requirement,
                  style:
                      TextStyle(color: sl.text1, fontSize: 13, height: 1.45)),
              const SizedBox(height: 14),
              Text(
                  r.sourcePage != 0
                      ? 'Quoted from page ${r.sourcePage}'
                      : 'Page not identified',
                  style: SLText.label(sl)),
              const SizedBox(height: 6),
              if (r.sourceText.trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: sl.card2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: sl.border),
                  ),
                  // Monospace: this is a quotation from a document, and the
                  // change of face is what tells the user they are looking at
                  // the document's words rather than the app's.
                  child: Text(r.sourceText,
                      style: TextStyle(
                          color: sl.text2,
                          fontSize: 12,
                          height: 1.5,
                          fontFamily: 'monospace')),
                )
              else
                Text(
                  'The AI did not quote a source line for this one. Treat it as '
                  'unconfirmed and check the document.',
                  style: SLText.bodySmall(sl).copyWith(color: sl.amberText),
                ),
              if (!r.verified) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Icon(Icons.help_outline, size: 15, color: sl.amberText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This quotation could not be found in the scanned text. '
                      'Either the page was misread, or the requirement was not '
                      'taken from the document.',
                      style: SLText.bodySmall(sl),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// The checklist, in two structurally separate groups.
  ///
  /// THE SPLIT IS THE POINT. "In the document" and "the AI thinks you should
  /// also" carry completely different authority on a shop floor, and a single
  /// merged list of ticks silently promotes the second to the first. The
  /// fromDocument flag is set once, in the service, from which JSON array the
  /// item arrived in — it is never re-derived here.
  Widget _checklistCard(SL sl, SopSafetyAnalysis s) {
    final fromDoc = s.documentChecks;
    final suggested = s.suggestedChecks;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.checklist_rtl_outlined, size: 16, color: sl.accentText),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Pre-job safety checklist',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'A reading aid, not a permit. Ticks are not saved and this does not '
            'replace the signed checklist for the job.',
            style: SLText.hint(sl),
          ),
          if (fromDoc.isNotEmpty) ...[
            const SizedBox(height: 12),
            _checkGroupHeader(
                sl, 'From the document', '${fromDoc.length}', sl.greenText),
            const SizedBox(height: 8),
            for (final c in fromDoc) _checkRow(sl, c),
          ],
          if (suggested.isNotEmpty) ...[
            const SizedBox(height: 14),
            _checkGroupHeader(sl, 'AI suggested additional checks',
                '${suggested.length}', sl.amberText),
            const SizedBox(height: 4),
            Text(
              'NOT found in this document. Generally good practice for this kind '
              'of job — confirm with your area before relying on any of them.',
              style: SLText.hint(sl),
            ),
            const SizedBox(height: 8),
            for (final c in suggested) _checkRow(sl, c),
          ],
        ],
      ),
    );
  }

  Widget _checkGroupHeader(SL sl, String title, String count, Color tint) {
    return Row(children: [
      Container(width: 6, height: 6,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(title,
          style: TextStyle(
              color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(width: 6),
      Text('($count)', style: SLText.hint(sl)),
    ]);
  }

  /// A single check line.
  ///
  /// Rendered as a static square, NOT a Checkbox. Nothing on this screen persists
  /// a tick, and an interactive checkbox on a safety checklist implies a record
  /// that someone could later be asked to produce. If ticking is ever wanted it
  /// needs a saved, attributed, timestamped row behind it — not local state.
  Widget _checkRow(SL sl, SopCheckItem c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
                c.fromDocument
                    ? Icons.check_box_outline_blank
                    : Icons.add_box_outlined,
                size: 15,
                color: c.fromDocument ? sl.text3 : sl.amberText),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(c.text,
                style:
                    TextStyle(color: sl.text2, fontSize: 12, height: 1.45)),
          ),
          if (c.sourcePage != 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('p.${c.sourcePage}', style: SLText.hint(sl)),
            ),
        ],
      ),
    );
  }

  /// Requirements grouped by the fixed 15 categories, for the ones that are
  /// populated. Collapsed presentation — chips, not paragraphs — because this is
  /// the "what kind of controls does this job need" overview, and the detail is
  /// in the critical list above.
  Widget _categoriesCard(SL sl, SopSafetyAnalysis s) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.rule_outlined, size: 16, color: sl.accentText),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Requirements by type',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          for (final cat in s.populatedCategories) ...[
            const SizedBox(height: 8),
            Text(SopSafetyAnalysis.categoryLabels[cat] ?? cat,
                style: TextStyle(
                    color: sl.accentText,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            for (final item in s.of(cat))
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 7),
                      child: Container(width: 4, height: 4,
                          decoration: BoxDecoration(
                              color: sl.text3, shape: BoxShape.circle)),
                    ),
                    Expanded(
                      child: Text(item,
                          style: TextStyle(
                              color: sl.text2, fontSize: 12, height: 1.4)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Gaps and contradictions the AI thinks it found in the document.
  ///
  /// Worded throughout as a QUESTION about the document, never as a finding
  /// against it. This screen has no authority to declare a plant SOP deficient,
  /// and a scan that confidently reports a real, approved procedure as unsafe
  /// would be the fastest way to get the whole feature switched off.
  Widget _issuesCard(SL sl, SopSafetyAnalysis s) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.help_outline, size: 16, color: sl.amberText),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Points to check (${s.issues.length})',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'Possible gaps the AI noticed. It may simply have misread the page, '
            'or the requirement may live in a different document — these are '
            'questions to raise, not defects.',
            style: SLText.hint(sl),
          ),
          const SizedBox(height: 10),
          for (final i in s.issues)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: sl.card2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: sl.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(i.issue,
                          style: TextStyle(
                              color: sl.text1,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.4)),
                    ),
                    if (i.sourcePage != 0)
                      Text('p.${i.sourcePage}', style: SLText.hint(sl)),
                  ]),
                  if (i.reason.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(i.reason,
                        style: TextStyle(
                            color: sl.text2, fontSize: 12, height: 1.4)),
                  ],
                  if (i.sourceText.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('“${i.sourceText}”',
                        style: TextStyle(
                            color: sl.text3,
                            fontSize: 11,
                            height: 1.4,
                            fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _disclaimerCard(SL sl, SopSafetyAnalysis s) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.red.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: sl.redText),
            const SizedBox(width: 10),
            Expanded(
              // The single source of this wording is the service constant, so the
              // disclaimer shown on screen cannot drift from the one the rest of
              // the feature refers to.
              child: Text(SopSafetyService.disclaimer,
                  style: SLText.bodySmall(sl)),
            ),
          ]),
          if (s.aiRecommendations.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('AI notes',
                style: TextStyle(
                    color: sl.text1,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            for (final rec in s.aiRecommendations)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('• $rec', style: SLText.bodySmall(sl)),
              ),
          ],
        ],
      ),
    );
  }

  /// The raw transcription, collapsed.
  ///
  /// Read-only. Editing it was in the original spec and is deliberately NOT here:
  /// the text has already been used to produce the clauses and the analysis above,
  /// so an edit at this point would leave the two disagreeing with no indication
  /// which the user was shown. Correcting OCR properly means re-running both
  /// passes, which is a bigger change than this screen.
  Widget _ocrTextCard(SL sl) {
    final read = _pages.where((p) => p.result?.ok == true).toList();
    if (read.isEmpty) return const SizedBox.shrink();

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _showOcr = !_showOcr),
            child: Row(children: [
              Icon(Icons.text_snippet_outlined, size: 16, color: sl.text3),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Text the reader saw (${read.length} page(s))',
                    style: TextStyle(
                        color: sl.text1,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              Icon(_showOcr ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: sl.text3),
            ]),
          ),
          if (!_showOcr) ...[
            const SizedBox(height: 4),
            Text(
                'Open this to check a requirement that looks wrong — it is '
                'usually a misread page rather than a mistaken conclusion.',
                style: SLText.hint(sl)),
          ],
          if (_showOcr)
            for (final p in read) ...[
              const SizedBox(height: 12),
              Text(
                  'Page ${p.result!.pageNo} · read by ${p.result!.engine}',
                  style: SLText.label(sl)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: sl.card2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sl.border),
                ),
                child: SelectableText(
                  p.result!.text.trim(),
                  style: TextStyle(
                      color: sl.text2,
                      fontSize: 11,
                      height: 1.5,
                      fontFamily: 'monospace'),
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _errorBanner(SL sl, String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.red.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.red.withOpacity(0.35)),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, size: 18, color: sl.redText),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: SLText.bodySmall(sl))),
      ]),
    );
  }
}

/// Return type for the isolate-side image prep. A plain class rather than a
/// record so it survives `compute`'s send-port serialisation on every SDK the
/// project supports.
class _PrepResult {
  final Uint8List ocr;
  final Uint8List thumb;
  const _PrepResult(this.ocr, this.thumb);
}
