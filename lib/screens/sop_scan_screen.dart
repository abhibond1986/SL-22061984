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

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart' show AppColors, SL, SLText;
import '../services/local_db.dart';
import '../services/network_checker.dart';
import '../services/plant_scope.dart';
import '../services/sop_ocr_device.dart';
import '../services/sop_ocr_service.dart';
import '../services/sync_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/universal_app_bar.dart';
import '../widgets/voice_text_field.dart';
import '../utils/image_prep.dart';

enum _Stage { capture, reading, review }

/// One captured page and whatever we know about it so far.
class _Page {
  /// OCR-prepared bytes (grayscale, contrast-lifted, long edge 1800).
  Uint8List ocrBytes;

  /// Small preview. Kept separately so the grid is not decoding a 1800px image
  /// per thumbnail on every rebuild — with 30 pages that is what makes the
  /// review list stutter.
  Uint8List thumb;

  PageOcr? result;

  _Page({required this.ocrBytes, required this.thumb});

  bool get failed => result != null && !result!.ok;
}

class SopScanScreen extends StatefulWidget {
  final VoidCallback? toggleTheme;
  const SopScanScreen({super.key, this.toggleTheme});

  @override
  State<SopScanScreen> createState() => _SopScanScreenState();
}

class _SopScanScreenState extends State<SopScanScreen> {
  _Stage _stage = _Stage.capture;

  final List<_Page> _pages = [];
  SopExtract? _extract;

  // Reading progress.
  int _readDone = 0;
  String _progressNote = '';

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
    _titleCtl.dispose();
    _sopNoCtl.dispose();
    _deptCtl.dispose();
    // Release the native ML Kit recogniser. Harmless on web (no-op stub) and
    // harmless if it was never created.
    SopOcrDevice.dispose();
    super.dispose();
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
      }
    } catch (e) {
      print('SopScan: capture failed — $e');
      _snack('Could not open the camera or gallery.');
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

  void _removePage(int index) => setState(() => _pages.removeAt(index));

  void _movePage(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= _pages.length) return;
    setState(() {
      final p = _pages.removeAt(index);
      _pages.insert(to, p);
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  READING
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _readAll() async {
    if (_pages.isEmpty) return;
    setState(() {
      _stage = _Stage.reading;
      _readDone = 0;
      _error = null;
      _progressNote = '';
      for (final p in _pages) {
        p.result = null;
      }
    });

    final online = await NetworkChecker.hasInternet();
    if (!online && !SopOcrDevice.isAvailable) {
      if (!mounted) return;
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
      setState(() =>
          _progressNote = 'Reading page ${i + 1} of ${_pages.length}…');
      final r = await SopOcrService.readPage(
        _pages[i].ocrBytes,
        pageNo: i + 1,
        allowAi: online,
      );
      if (!mounted) return;
      setState(() {
        _pages[i].result = r;
        _readDone = i + 1;
      });
    }

    final good = _pages.where((p) => p.result?.ok == true).toList();
    if (good.isEmpty) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.capture;
        _error = 'None of the pages could be read. Retake them in better light, '
            'square to the page, with the text filling the frame.';
      });
      return;
    }

    setState(() => _progressNote = 'Understanding the document…');
    final extract = await SopOcrService.structure(
      good.map((p) => p.result!).toList(),
      fallbackTitle: _titleCtl.text.trim(),
    );
    if (!mounted) return;

    _titleCtl.text = extract.title.isNotEmpty ? extract.title : _titleCtl.text;
    _sopNoCtl.text = extract.sopNumber;
    if (extract.department.isNotEmpty) _deptCtl.text = extract.department;

    setState(() {
      _extract = extract;
      _stage = _Stage.review;
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
      // Grab the messenger BEFORE popping. Reading it from `context` afterwards
      // looks up a deactivated element and the confirmation is silently lost —
      // exactly the case where the user needs to be told the work was saved.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(
        content: Text('Added "$title" to the Knowledge Base '
            '(${extract.clauses.length} clause(s), $cloudNote). '
            'An admin should verify it.'),
        duration: const Duration(seconds: 5),
      ));
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
      backgroundColor: sl.bg,
      appBar: UniversalAppBar(
        title: 'Scan SOP / SMP',
        subtitle: _stageLabel,
        toggleTheme: widget.toggleTheme,
        showExport: false,
      ),
      body: SafeArea(
        child: Container(
          // sl.bgGradient is a List<Color>, not a Gradient — it feeds the
          // `colors:` slot. Same begin/end as every other screen so this one
          // doesn't run its gradient at a different angle.
          decoration: BoxDecoration(
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
      return 'Reading $_readDone of ${_pages.length}';
    }
    return 'Check before saving';
  }

  // ── Stage 1: capture ──────────────────────────────────────────────────

  Widget _captureView(SL sl) {
    return ListView(
      padding: const EdgeInsets.all(16),
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
                'the middle. Up to ${SopOcrService.maxPages} pages.',
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
                    label: Text('Files',
                        style: SLText.button(sl).copyWith(color: sl.accentText)),
                  ),
                ),
              ]),
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
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(p.thumb,
              width: 46, height: 60, fit: BoxFit.cover,
              gaplessPlayback: true),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Page ${i + 1}',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_sizeLabel(p.ocrBytes.length), style: SLText.hint(sl)),
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

  Widget _readingView(SL sl) {
    final total = _pages.isEmpty ? 1 : _pages.length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                value: _readDone == 0 ? null : _readDone / total,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.accent),
                backgroundColor: sl.card3,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _progressNote.isEmpty ? 'Reading…' : _progressNote,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: sl.text1, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              SopOcrDevice.isAvailable
                  ? 'Reading on the phone first, and asking the AI only for '
                      'pages it cannot handle.'
                  : 'Each page is being read by the AI. This takes a few '
                      'seconds per page.',
              textAlign: TextAlign.center,
              style: SLText.hint(sl),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage 3: review ───────────────────────────────────────────────────

  Widget _reviewView(SL sl) {
    final extract = _extract!;
    final failed = _pages.where((p) => p.failed).length;
    final readOk = _pages.length - failed;

    return ListView(
      padding: const EdgeInsets.all(16),
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
