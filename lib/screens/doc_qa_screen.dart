// lib/screens/doc_qa_screen.dart
//
// Ask questions about a document. Upload a PDF, a Word .docx or a photograph of
// a printed page; the PaddleOCR service reads it, the text is split into clauses,
// and Gemini answers questions using ONLY those clauses — always with a citation.
//
// HOW THIS DIFFERS FROM SopScanScreen, AND WHY BOTH EXIST
// SopScanScreen photographs a printed SOP and FILES IT in the plant-wide
// Knowledge Base, where it then shapes every future hazard analysis. That is a
// curation act, and it is gated behind a permission for exactly that reason.
// This screen is the opposite: a throwaway reading tool. A contractor hands you a
// 60-page method statement at the gate and you need to know what it says about
// harnesses in the next two minutes. Nothing here touches knowledge_docs, so
// nobody can accidentally promote an unreviewed document into plant doctrine —
// see the note at the top of migration_doc_qa.sql.
//
// NOT A BOTTOM-NAV TAB, on purpose. The nav bar in home_screen.dart is already
// at six tabs with 9px labels (below the floor tools/audit_contrast.py enforces)
// and roughly 3px of clearance around the selected pill at 320px. A seventh entry
// would overflow it. This screen is pushed from the Home tab's quick actions
// instead, which costs the user one tap and costs the nav bar nothing.
//
// WHAT THIS SCREEN MUST NEVER DO: present an unsourced answer as fact. Every
// answer carries the extracts it came from, and OCR-derived text is labelled as
// unverified. A confident invented sentence about an isolation procedure is far
// more dangerous than "the document does not say" — which is why the model is
// instructed to refuse (DocQaProxy.gs) and why _AnswerCard always renders its
// sources.
//
// ignore_for_file: avoid_print

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../main.dart' show AppColors, SL, SLText;
import '../services/doc_ocr_service.dart';
import '../services/doc_qa_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/universal_app_bar.dart';

/// Which of the three views is showing.
///
/// An enum rather than a pair of bools, matching _Stage in sop_scan_screen.dart.
/// The bool-pair pattern used elsewhere in this app permits impossible states
/// (reading AND showing a transcript), and here that would mean a question typed
/// against a document that is still being read.
enum _Stage { pick, reading, chat }

/// One entry in the transcript. A question and its answer are separate entries so
/// the question can be painted the instant it is sent, with the answer arriving
/// under it — otherwise the user taps send and nothing visibly happens for the
/// several seconds the model takes.
class _Msg {
  final bool isUser;
  final String text;
  final DocAnswer? answer;

  /// Set on the placeholder entry that holds the spinner.
  final bool pending;

  _Msg.user(this.text)
      : isUser = true,
        answer = null,
        pending = false;

  _Msg.pending()
      : isUser = false,
        text = '',
        answer = null,
        pending = true;

  _Msg.answer(DocAnswer a)
      : isUser = false,
        text = a.answer,
        answer = a,
        pending = false;
}

class DocQaScreen extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;

  const DocQaScreen({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
  });

  @override
  State<DocQaScreen> createState() => _DocQaScreenState();
}

class _DocQaScreenState extends State<DocQaScreen> {
  _Stage _stage = _Stage.pick;

  /// The document being questioned. Null in [_Stage.pick].
  DocLibraryItem? _doc;

  final List<_Msg> _messages = [];
  final _questionCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// Previously uploaded documents, so a document is read once and questioned
  /// on many days. Empty when Supabase is off — the session still works, it just
  /// forgets on reload.
  List<DocLibraryItem> _library = [];
  bool _loadingLibrary = false;

  /// Suggested questions, drawn from what colleagues already asked about THIS
  /// document. Far more useful than invented examples: the first thing a user
  /// wants to know is usually what everyone else wanted to know.
  List<String> _suggestions = [];

  String _progress = '';
  String? _serviceProblem;
  bool _asking = false;

  /// 'en' | 'hi'. Answers in Hindi keep PPE/LOTO/SOP in English because that is
  /// how they appear on plant signage and permits.
  String _language = 'en';

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: free hosting suspends the container when idle, so the
    // first extraction otherwise pays container boot plus model load while the
    // user watches a spinner. Starting it now means the model is usually warm by
    // the time they have chosen a file.
    DocOcrService.warmUp();
    _checkService();
    _loadLibrary();
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  //  LOADING
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _checkService() async {
    final problem = await DocOcrService.checkHealth();
    if (!mounted) return;
    setState(() => _serviceProblem = problem);
  }

  Future<void> _loadLibrary() async {
    setState(() => _loadingLibrary = true);
    // Scoped to the uploader on purpose. RLS here is `using (true)` like the
    // rest of the project, so without this filter every user would see — and
    // via the delete button, be able to remove — every file anyone had ever
    // uploaded. That is tolerable for curated plant doctrine in knowledge_docs;
    // it is not tolerable for a tool where people upload arbitrary documents,
    // which may be a contractor's commercial paperwork or a draft incident
    // report. This is a display filter, not a security boundary: anyone holding
    // the publishable key can still read the table. See the header comment in
    // migration_doc_qa.sql for the per-user RLS change if you need the real one.
    // listDocuments treats a null createdBy as "no filter", so passing
    // _userName straight through would show an anonymous user (the contractor
    // shell needs no login) the whole table — the exact thing the filter is
    // here to prevent. No identity, no library.
    final name = _userName;
    if (name == null) {
      setState(() {
        _library = const [];
        _loadingLibrary = false;
      });
      return;
    }
    final docs = await DocQaService.listDocuments(createdBy: name, limit: 30);
    if (!mounted) return;
    setState(() {
      _library = docs;
      _loadingLibrary = false;
    });
  }

  Future<void> _loadSuggestions() async {
    final id = _doc?.id;
    if (id == null) return;
    final qs = await DocQaService.recentQuestions(id);
    if (!mounted) return;
    setState(() => _suggestions = qs);
  }

  // ══════════════════════════════════════════════════════════════════════
  //  UPLOAD
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _pickAndIngest() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: DocOcrService.pickerExtensions,
        withData: true, // Required on web, where there is no file path.
      );
    } catch (e) {
      print('DocQa: file picker failed — $e');
      _snack('Could not open the file picker.');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    // The picker is a long async gap. Checked once here because nothing between
    // this point and the end of the method can remount the State.
    if (!mounted) return;

    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      _snack('Could not read that file.');
      return;
    }
    if (bytes.length > DocOcrService.maxUploadBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      _snack('That file is $mb MB — the limit is '
          '${DocOcrService.maxUploadBytes ~/ (1024 * 1024)} MB.');
      return;
    }

    setState(() {
      _stage = _Stage.reading;
      _progress = 'Preparing…';
    });

    try {
      final doc = await DocQaService.ingest(
        fileName: file.name,
        bytes: bytes,
        // Deliberately NOT _language. That control says "Answer in", and it
        // steers Gemini. `lang` here picks the OCR *recognition model*, and
        // 'hi' loads the Devanagari one — so honouring the chip would OCR an
        // English SOP with a Devanagari model and return garbage, with nothing
        // on screen explaining why. Plant documents are English in practice,
        // and the Docker image only pre-bakes the English model, so 'hi' would
        // also trigger a cold model download on the free tier.
        lang: 'en',
        plant: _plant,
        createdBy: _userName,
        onProgress: (s) {
          if (mounted) setState(() => _progress = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _stage = _Stage.chat;
        _messages.clear();
        _suggestions = [];
      });
      _loadSuggestions();
      _loadLibrary(); // so the new document appears in the list next time
    } on DocOcrException catch (e) {
      if (!mounted) return;
      // Back to pick, not stuck on a dead progress screen. The message is
      // already written for a plant user by DocOcrService.
      setState(() => _stage = _Stage.pick);
      _showProblem('Could not read that document', e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _stage = _Stage.pick);
      _showProblem('Something went wrong', e.toString());
    }
  }

  void _openExisting(DocLibraryItem doc) {
    setState(() {
      _doc = doc;
      _stage = _Stage.chat;
      _messages.clear();
      _suggestions = [];
    });
    _loadSuggestions();
  }

  Future<void> _confirmDelete(DocLibraryItem doc) async {
    final sl = SL.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        title: Text('Remove this document?',
            style: TextStyle(color: sl.text1, fontSize: 16)),
        content: Text(
          '“${doc.title}” and every question asked about it will be deleted. '
          'This cannot be undone.',
          style: TextStyle(color: sl.text3, fontSize: SLText.minBody),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: sl.critText)),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await DocQaService.deleteDocument(doc);
    if (!mounted) return;
    if (ok) {
      _loadLibrary();
    } else {
      _snack('Could not remove it: ${DocQaService.lastError}');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ASK
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _ask([String? preset]) async {
    final doc = _doc;
    if (doc == null || _asking) return;

    final question = (preset ?? _questionCtrl.text).trim();
    if (question.isEmpty) return;

    setState(() {
      _asking = true;
      _questionCtrl.clear();
      _messages.add(_Msg.user(question));
      _messages.add(_Msg.pending());
    });
    _scrollToEnd();

    final answer = await DocQaService.ask(
      question: question,
      documentId: doc.id,
      documentTitle: doc.title,
      // Hand over the in-memory chunks as well as the id. When the database
      // write failed or Supabase is off, `id` is null and these are the ONLY
      // way to answer — without them retrieval scores an empty list and every
      // question comes back "I could not find anything".
      localChunks: doc.chunks,
      ocrDerived: doc.ocrDerived,
      language: _language,
      askedBy: _userName,
      plant: _plant,
    );

    if (!mounted) return;
    // Not just `mounted`. If the document changes underneath an in-flight
    // answer, the pending placeholder is gone and appending would drop an
    // answer about the PREVIOUS document into the new document's chat with no
    // question above it — the worst possible failure for a tool whose whole
    // promise is that answers are traceable to a source.
    //
    // As of today nothing can actually reach this: "Change" is disabled while
    // _asking, and the library tiles that call _openExisting only exist in the
    // pick view, which is not on screen mid-ask. It stays because that is an
    // invariant held by two unrelated widgets and enforced by nothing — the
    // day someone adds a third way to switch documents, this is what stops a
    // mis-sourced answer instead of shipping one.
    if (!identical(_doc, doc)) {
      setState(() => _asking = false);
      return;
    }
    setState(() {
      _asking = false;
      // Replace the pending placeholder rather than appending, so the spinner
      // does not linger above the answer.
      final i = _messages.lastIndexWhere((m) => m.pending);
      if (i >= 0) {
        _messages[i] = _Msg.answer(answer);
      } else {
        _messages.add(_Msg.answer(answer));
      }
    });
    _scrollToEnd();
  }

  Future<bool> _rate(String question, bool helpful) async {
    final id = _doc?.id;
    if (id == null) {
      // No row to update. Say so rather than showing a tick that saved nothing.
      _snack('Feedback needs the document saved to the server.');
      return false;
    }
    final saved = await DocQaService.rateAnswer(
        documentId: id, question: question, helpful: helpful);
    if (!mounted) return saved;
    if (!saved) {
      // The question log is written without awaiting, so a fast rating can
      // arrive before the row exists. Say so instead of claiming a save.
      _snack('Could not record that just yet — try again in a moment.');
      return false;
    }
    _snack(helpful
        ? 'Thanks — noted as helpful.'
        : 'Thanks — this answer will not be reused.');
    return true;
  }

  void _scrollToEnd() {
    // Deferred a frame: the new message is not laid out yet, so
    // maxScrollExtent is still the old value and the view would stop short.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════

  String? get _userName {
    final u = widget.user;
    if (u == null) return null;
    final v = (u['name'] ?? u['email'] ?? '').toString().trim();
    return v.isEmpty ? null : v;
  }

  String? get _plant {
    final v = (widget.user?['plant'] ?? '').toString().trim();
    return v.isEmpty ? null : v;
  }

  String get _stageLabel {
    if (_stage == _Stage.pick) return 'Choose a document';
    if (_stage == _Stage.reading) return 'Reading…';
    return _doc?.title ?? 'Ask about this document';
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      appBar: UniversalAppBar(
        title: 'Document Q&A',
        subtitle: _stageLabel,
        user: widget.user,
        toggleTheme: widget.toggleTheme,
        onSignOut: widget.onSignOut,
        isDark: widget.isDark,
        showExport: false,
        // Required: this screen is pushed, and UniversalAppBar draws no leading
        // button of its own. Without this there is no way off the screen on
        // Flutter Web, and the SAIL badge no-ops because the shell is already
        // sitting on the Home tab.
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: sl.bgGradient,
            ),
          ),
          // An if-chain, not a switch expression: STATUS.md records that the CI
          // toolchain (Flutter 3.19.6) has tripped on Dart 3 pattern switch
          // expressions, and a build failure is a poor trade for two saved
          // lines. The enum still keeps the states exhaustive.
          child: _stage == _Stage.pick
              ? _pickView(sl)
              : _stage == _Stage.reading
                  ? _readingView(sl)
                  : _chatView(sl),
        ),
      ),
    );
  }

  // ── PICK ────────────────────────────────────────────────────────────────

  Widget _pickView(SL sl) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_serviceProblem != null) _banner(sl, _serviceProblem!, warn: true),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_stories_rounded,
                      color: sl.accentText, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ask a document',
                      style: TextStyle(
                        color: sl.text1,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Upload a PDF, a Word file or a photo of a printed page. '
                'Answers quote the document and give you the clause and page, '
                'so you can check them yourself.',
                style: TextStyle(
                    color: sl.text3, fontSize: SLText.minBody, height: 1.45),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _pickAndIngest,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('Choose a file'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _languageRow(sl),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              'RECENT DOCUMENTS',
              style: TextStyle(
                color: sl.text4,
                fontSize: SLText.minLabel,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            const Spacer(),
            if (_loadingLibrary)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: sl.text4),
              )
            else
              IconButton(
                onPressed: _loadLibrary,
                icon: Icon(Icons.refresh_rounded, size: 18, color: sl.text4),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_library.isEmpty && !_loadingLibrary)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'Nothing yet. A document you upload stays here so you can come '
              'back to it without reading it again.',
              style: TextStyle(color: sl.text4, fontSize: SLText.minBody),
            ),
          )
        else
          ..._library.map((d) => _libraryTile(sl, d)),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _languageRow(SL sl) {
    // Wrap, not Row. Icon + label + two chips is about 233px against roughly
    // 256px of usable width on a 320px screen, so it fits at text scale 1.0 and
    // overflows the moment the user bumps their font size — which safety staff
    // reading on a phone in a plant routinely do.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0,
      runSpacing: 6,
      children: [
        Icon(Icons.translate_rounded, size: 16, color: sl.text4),
        const SizedBox(width: 8),
        Text('Answer in',
            style: TextStyle(color: sl.text4, fontSize: SLText.minLabel)),
        const SizedBox(width: 10),
        for (final entry in const [['en', 'English'], ['hi', 'हिंदी']])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _language = entry[0]),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _language == entry[0]
                      ? AppColors.accent.withOpacity(0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _language == entry[0]
                        ? AppColors.accent.withOpacity(0.5)
                        : sl.border,
                  ),
                ),
                child: Text(
                  entry[1],
                  style: TextStyle(
                    color: _language == entry[0] ? sl.accentText : sl.text3,
                    fontSize: SLText.minLabel,
                    fontWeight: _language == entry[0]
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _libraryTile(SL sl, DocLibraryItem d) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.border),
      ),
      child: ListTile(
        onTap: () => _openExisting(d),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Icon(_iconFor(d.fileKind), color: sl.accentText, size: 24),
        title: Text(
          d.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: sl.text1,
              fontSize: SLText.minBody + 1,
              fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Text(
                '${d.pageCount} page${d.pageCount == 1 ? '' : 's'} · '
                '${d.chunkCount} sections',
                style: TextStyle(color: sl.text4, fontSize: SLText.minHint),
              ),
              if (d.needsHumanCheck) ...[
                const SizedBox(width: 8),
                Icon(Icons.visibility_outlined, size: 13, color: sl.amberText),
                const SizedBox(width: 3),
                Text('scanned',
                    style: TextStyle(
                        color: sl.amberText, fontSize: SLText.minHint)),
              ],
            ],
          ),
        ),
        trailing: IconButton(
          onPressed: () => _confirmDelete(d),
          icon: Icon(Icons.delete_outline_rounded, size: 19, color: sl.text4),
          tooltip: 'Remove',
        ),
      ),
    );
  }

  IconData _iconFor(String kind) {
    if (kind == 'pdf') return Icons.picture_as_pdf_outlined;
    if (kind == 'docx') return Icons.description_outlined;
    if (kind == 'image') return Icons.image_outlined;
    return Icons.article_outlined;
  }

  // ── READING ─────────────────────────────────────────────────────────────

  Widget _readingView(SL sl) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: sl.accentText),
            ),
            const SizedBox(height: 22),
            Text(
              _progress.isEmpty ? 'Reading the document…' : _progress,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: sl.text2,
                  fontSize: SLText.minBody + 1,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              // Setting the expectation matters: on a free CPU tier a scanned
              // 40-page SOP genuinely takes minutes, and a user who thinks it
              // has hung will kill the tab and start again — paying the cost
              // twice and still getting nothing.
              'Scanned pages and photos are read one at a time, so a long '
              'document can take a few minutes. You can leave this open.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: sl.text4, fontSize: SLText.minHint, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  // ── CHAT ────────────────────────────────────────────────────────────────

  Widget _chatView(SL sl) {
    final doc = _doc!;
    return Column(
      children: [
        _docHeader(sl, doc),
        Expanded(
          child: _messages.isEmpty
              ? _emptyChat(sl, doc)
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _bubble(sl, _messages[i], i),
                ),
        ),
        _composer(sl),
      ],
    );
  }

  Widget _docHeader(SL sl, DocLibraryItem doc) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: sl.card.withOpacity(0.6),
        border: Border(bottom: BorderSide(color: sl.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(_iconFor(doc.fileKind), size: 18, color: sl.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  doc.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: SLText.minBody,
                      fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                // Disabled mid-answer. _ask already discards a reply whose
                // document changed under it, but greying the button out is the
                // honest signal: swapping now silently throws away the answer
                // the user is waiting on.
                onPressed: _asking
                    ? null
                    : () => setState(() {
                          _stage = _Stage.pick;
                          _doc = null;
                          _messages.clear();
                        }),
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: const Text('Change'),
                style: TextButton.styleFrom(
                  foregroundColor: sl.text3,
                  textStyle: TextStyle(fontSize: SLText.minLabel),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (doc.needsHumanCheck)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _banner(
                sl,
                // Named plainly. A misread digit in "isolate breaker 4" is
                // exactly the error that gets somebody hurt, and the user is the
                // only one who can catch it.
                'This document was read by OCR from a scan or photo, so a '
                'number or clause reference may be misread. Check anything you '
                'act on against the paper copy.',
                warn: true,
                dense: true,
              ),
            ),
          // Gated on a missing id, not on errorMessage. A row loaded back from
          // doc_library can carry a stale error_message from an earlier failed
          // attempt while being perfectly saved, and this banner would then lie
          // about it. A null id is precisely what "not on the server" means.
          if (doc.id == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _banner(
                sl,
                'Not saved to the server — this document is available for this '
                'session only.',
                warn: true,
                dense: true,
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyChat(SL sl, DocLibraryItem doc) {
    final examples = _suggestions.isNotEmpty
        ? _suggestions.take(4).toList()
        : const [
            'What PPE is required?',
            'What are the emergency steps?',
            'Who is responsible for isolation?',
            'What are the main hazards?',
          ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 12),
        Icon(Icons.question_answer_outlined, size: 40, color: sl.text4),
        const SizedBox(height: 14),
        Text(
          'Ask anything about this document',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: sl.text2,
              fontSize: SLText.minBody + 2,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '${doc.chunkCount} sections read. Answers come only from this '
          'document — nothing is filled in from general knowledge.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: sl.text4, fontSize: SLText.minHint, height: 1.5),
        ),
        const SizedBox(height: 22),
        Text(
          _suggestions.isNotEmpty ? 'ASKED BEFORE' : 'TRY',
          style: TextStyle(
              color: sl.text4,
              fontSize: SLText.minLabel,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: examples
              .map((q) => GestureDetector(
                    onTap: () => _ask(q),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: sl.card,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: sl.border),
                      ),
                      child: Text(
                        q,
                        style: TextStyle(
                            color: sl.text2, fontSize: SLText.minLabel),
                      ),
                    ),
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _bubble(SL sl, _Msg m, int i) {
    if (m.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(sl.isDark ? 0.22 : 0.12),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(color: AppColors.accent.withOpacity(0.35)),
          ),
          child: Text(
            m.text,
            style: TextStyle(
                color: sl.text1, fontSize: SLText.minBody, height: 1.4),
          ),
        ),
      );
    }

    if (m.pending) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: sl.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: sl.accentText),
              ),
              const SizedBox(width: 10),
              Text('Reading the relevant sections…',
                  style:
                      TextStyle(color: sl.text3, fontSize: SLText.minLabel)),
            ],
          ),
        ),
      );
    }

    // The question this answer belongs to, needed for the rating call — which
    // keys on question_key, not on a row id we do not have here.
    final question = i > 0 && _messages[i - 1].isUser ? _messages[i - 1].text : '';
    return _AnswerCard(
      answer: m.answer!,
      onRate: (helpful) => _rate(question, helpful),
      onCopy: () {
        Clipboard.setData(ClipboardData(text: m.text));
        _snack('Answer copied.');
      },
    );
  }

  Widget _composer(SL sl) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: sl.card.withOpacity(0.85),
        border: Border(top: BorderSide(color: sl.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _questionCtrl,
              enabled: !_asking,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _ask(),
              style: TextStyle(color: sl.text1, fontSize: SLText.minBody),
              decoration: InputDecoration(
                hintText: 'Ask about this document…',
                hintStyle:
                    TextStyle(color: sl.text4, fontSize: SLText.minHint),
                filled: true,
                fillColor: sl.card2,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: sl.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: sl.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: AppColors.accent, width: 1.4),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: _asking ? sl.card2 : AppColors.accent,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: _asking ? null : () => _ask(),
              icon: Icon(Icons.arrow_upward_rounded,
                  size: 20, color: _asking ? sl.text4 : Colors.white),
              tooltip: 'Ask',
            ),
          ),
        ],
      ),
    );
  }

  // ── SHARED BITS ─────────────────────────────────────────────────────────

  Widget _banner(SL sl, String text,
      {bool warn = false, bool dense = false}) {
    final colour = warn ? sl.amberText : sl.accentText;
    return Container(
      margin: EdgeInsets.only(bottom: dense ? 0 : 14),
      padding: EdgeInsets.all(dense ? 10 : 12),
      decoration: BoxDecoration(
        color: colour.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(warn ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 16, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  color: sl.text2,
                  fontSize: dense ? SLText.minHint : SLText.minLabel,
                  height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// A dialog, not a snackbar, for extraction failures: the messages explain
  /// what to DO ("open it in Word and Save As .docx") and a snackbar that
  /// vanishes in four seconds is the wrong place for an instruction.
  void _showProblem(String title, String detail) {
    final sl = SL.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        title: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: sl.amberText, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(color: sl.text1, fontSize: 16)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(detail,
              style: TextStyle(
                  color: sl.text3, fontSize: SLText.minBody, height: 1.5)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// An answer plus the extracts it was built from.
///
/// Sources are ALWAYS rendered, never hidden behind a tap-to-reveal that most
/// users would not tap. The citation is the part a safety officer has to act on;
/// an answer without it is just a claim.
class _AnswerCard extends StatefulWidget {
  final DocAnswer answer;
  /// Returns whether the rating was actually persisted. The card marks itself
  /// rated optimistically so the tap feels instant, then rolls that back if
  /// this comes back false — otherwise a failed save leaves both thumbs
  /// permanently disabled and the user cannot retry.
  final Future<bool> Function(bool helpful) onRate;
  final VoidCallback onCopy;

  const _AnswerCard({
    required this.answer,
    required this.onRate,
    required this.onCopy,
  });

  @override
  State<_AnswerCard> createState() => _AnswerCardState();
}

class _AnswerCardState extends State<_AnswerCard> {
  bool _showSources = false;
  bool? _rated;

  Future<void> _sendRating(bool helpful) async {
    setState(() => _rated = helpful);
    final ok = await widget.onRate(helpful);
    if (!mounted || ok) return;
    setState(() => _rated = null); // let them try again
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final a = widget.answer;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14, right: 24),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
          border: Border.all(
            color: a.isWeak ? sl.amberText.withOpacity(0.4) : sl.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a.isWeak) ...[
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 15, color: sl.amberText),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      a.extractive
                          ? 'The AI was unavailable — this is raw document '
                              'text, not an answer.'
                          : 'The document only partly covers this. Read the '
                              'sources before acting.',
                      style: TextStyle(
                          color: sl.amberText,
                          fontSize: SLText.minHint,
                          fontWeight: FontWeight.w600,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Text(
              a.answer,
              style: TextStyle(
                  color: sl.text1, fontSize: SLText.minBody, height: 1.55),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (a.sources.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _showSources = !_showSources),
                    child: Row(
                      children: [
                        Icon(
                          _showSources
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: sl.accentText,
                        ),
                        Text(
                          '${a.sources.length} source'
                          '${a.sources.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              color: sl.accentText,
                              fontSize: SLText.minLabel,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                if (a.fromCache)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('saved answer',
                        style: TextStyle(
                            color: sl.text4, fontSize: SLText.minHint)),
                  ),
                IconButton(
                  onPressed: widget.onCopy,
                  icon: Icon(Icons.copy_rounded, size: 15, color: sl.text4),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy',
                ),
                IconButton(
                  onPressed: _rated == null ? () => _sendRating(true) : null,
                  icon: Icon(Icons.thumb_up_outlined,
                      size: 15,
                      color: _rated == true ? sl.greenText : sl.text4),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Helpful',
                ),
                IconButton(
                  onPressed: _rated == null ? () => _sendRating(false) : null,
                  icon: Icon(Icons.thumb_down_outlined,
                      size: 15,
                      color: _rated == false ? sl.critText : sl.text4),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Not helpful',
                ),
              ],
            ),
            if (_showSources) ...[
              const SizedBox(height: 6),
              for (final s in widget.answer.sources)
                // The rounding lives on a ClipRRect, not on the decoration.
                // BoxDecoration asserts if you combine a borderRadius with a
                // Border that is not uniform in colour and width, and this one
                // is a single 3px accent bar on the left. In a debug build that
                // assert throws on every paint of an expanded source; in
                // release it silently drops the radius. Clipping gives the same
                // look and is legal in both.
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: sl.card2,
                        border: Border(
                          left:
                              BorderSide(color: AppColors.accent, width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.citation,
                            style: TextStyle(
                                color: sl.accentText,
                                fontSize: SLText.minHint,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            s.content.trim(),
                            style: TextStyle(
                                color: sl.text3,
                                fontSize: SLText.minHint,
                                height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
