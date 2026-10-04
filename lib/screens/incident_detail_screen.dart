// lib/screens/incident_detail_screen.dart
// REDESIGNED: compact cards, light/neutral theme aware, no blank space
// ★ v31: Added WhatsApp share, PDF with sub-options (email/whatsapp/download),
//         image included in PDF/WhatsApp from thumbnailBase64 fallback

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../widgets/content_width.dart';
import '../services/local_db.dart';
import '../services/admin_master_data.dart';
import '../services/plant_scope.dart';
import '../services/sync_service.dart';
import '../services/pdf_export.dart';
import '../services/image_storage.dart';
import '../services/incident_assign.dart';
import 'employee_profile_screen.dart';
import '../services/branding.dart';

class IncidentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> incident;
  final VoidCallback? onStatusChanged;
  const IncidentDetailScreen({
    super.key, required this.incident, this.onStatusChanged,
  });
  @override
  State<IncidentDetailScreen> createState() => _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends State<IncidentDetailScreen> {
  late Map<String, dynamic> _inc;
  final _actionCtrl   = TextEditingController();
  final _closedByCtrl = TextEditingController();
  final _remarksCtrl  = TextEditingController();
  bool _saving = false;
  // Evidence image resolved once (file ref → inline base64 → Supabase URL) and
  // cached, so the detail view shows the same photo the analysis was made on.
  Future<Uint8List?>? _evidenceImageFuture;

  // The workflow ladder shown here, straight from the admin's status list.
  // This was hardcoded to four stages and omitted VERIFIED entirely, so the
  // "advance to next stage" button skipped it and a verified incident showed
  // as off-ladder.
  List<String> _statusOrder =
      List<String>.from(AdminMasterData.defaultStatuses);

  /// Whether this user is allowed to advance/close THIS incident.
  ///
  /// There was previously no authorisation check anywhere on this screen: any
  /// signed-in user who could open a record could drive it to CLOSED, including
  /// another plant's record. Starts false and is set once the check resolves, so
  /// the action bar can't be tapped during the async gap.
  bool _canAct = false;
  bool _permChecked = false;

  /// Target date for completing the corrective action. Stored as an ISO date
  /// string ('yyyy-MM-dd') in the `targetDate` field.
  DateTime? _targetDate;

  @override
  void initState() {
    super.initState();
    _inc = Map<String, dynamic>.from(widget.incident);
    _targetDate = DateTime.tryParse(_inc['targetDate']?.toString() ?? '');
    _loadStatuses();
    _checkPermission();
    AdminMasterData.revision.addListener(_loadStatuses);
    _actionCtrl.text   = _inc['correctiveAction']?.toString() ?? '';
    _closedByCtrl.text = _inc['closedBy']?.toString()         ?? '';
    _remarksCtrl.text  = _inc['closingRemarks']?.toString()   ?? '';
    // Kick off image resolution once (handles mobile file storage where the
    // inline base64 is stripped, plus Supabase-URL images synced from cloud).
    _evidenceImageFuture = _resolveImageBytes();
  }

  Future<void> _checkPermission() async {
    final scope = await PlantScope.forUser();
    final ok = await scope.canActOn(_inc);
    if (!mounted) return;
    setState(() {
      _canAct = ok;
      _permChecked = true;
    });
  }

  Future<void> _loadStatuses() async {
    try {
      final s = await AdminMasterData.getStatuses();
      if (!mounted) return;
      setState(() => _statusOrder = s.map((e) => e.toUpperCase()).toList());
    } catch (_) {}
  }

  @override
  void dispose() {
    AdminMasterData.revision.removeListener(_loadStatuses);
    _actionCtrl.dispose(); _closedByCtrl.dispose(); _remarksCtrl.dispose();
    super.dispose();
  }

  /// Effective status. A blank status resolves to the FIRST configured stage,
  /// not a literal 'OPEN' — which, once the admin renamed that stage, matched
  /// nothing in [_statusOrder], so `indexOf` returned -1 and the pipeline
  /// showed the case as off-ladder with no next stage to advance to.
  String get _status {
    final s = (_inc['status']?.toString().trim() ?? '').toUpperCase();
    if (s.isNotEmpty) return s;
    return _statusOrder.isEmpty ? '' : _statusOrder.first;
  }
  /// True once the incident has reached the FINAL workflow stage, whatever the
  /// admin named it — comparing to the literal 'CLOSED' meant renaming the last
  /// stage left every closed incident permanently editable.
  bool   get _isClosed =>
      _statusOrder.isNotEmpty && _status == _statusOrder.last;

  Color _statusColor(String s) {
    switch (s.toUpperCase()) {
      case 'CLOSED':        return const Color(0xFF16A34A);
      case 'VERIFIED':      return const Color(0xFF1E88E5);
      case 'ACTION TAKEN':  return const Color(0xFF0891B2);
      case 'INVESTIGATING': return const Color(0xFFD97706);
      default:              return const Color(0xFFDC2626);
    }
  }
  Color _sevColor(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.amber;
      default:         return const Color(0xFF16A34A);
    }
  }
  String _fmt(String? r) {
    if (r == null || r.isEmpty) return '—';
    try { return DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.parse(r)); }
    catch (_) { return r; }
  }
  List _parseHazards() {
    final raw = _inc['hazards'];
    if (raw == null) return [];
    if (raw is List) return raw;
    if (raw is String && raw.isNotEmpty) {
      try { final d = jsonDecode(raw); if (d is List) return d; } catch (_) {}
    }
    return [];
  }

  /// Copy the form fields onto [_inc]. Shared by "Save progress" and by
  /// advancing the status, so the two can never disagree about what is stored.
  void _applyFormFields() {
    _inc['correctiveAction'] = _actionCtrl.text.trim();
    _inc['closedBy']         = _closedByCtrl.text.trim();
    _inc['closingRemarks']   = _remarksCtrl.text.trim();
    // Date only — the time of day is meaningless for a completion target, and a
    // bare 'yyyy-MM-dd' sorts and compares correctly as a string.
    // Written unconditionally: writing only when non-null meant clearing the
    // date left the old value on the record and it reappeared on reload.
    _inc['targetDate'] = _targetDate == null
        ? '' : DateFormat('yyyy-MM-dd').format(_targetDate!);
  }

  /// Re-resolve authorisation at the point of WRITE, not only when building the
  /// buttons. Hiding a button is presentation; this is the actual gate, and it
  /// re-checks in case the admin changed this user's plant mid-session.
  Future<bool> _assertCanAct() async {
    final scope = await PlantScope.forUser();
    if (await scope.canActOn(_inc)) return true;
    if (!mounted) return false;
    setState(() { _canAct = false; _permChecked = true; });
    _snack('You can only update incidents of your own plant.', AppColors.red);
    return false;
  }

  /// Persist the corrective action, target date and remarks WITHOUT advancing
  /// the status. Without this, a target date could only be saved as a
  /// side-effect of moving the case to the next stage — so anyone who set a date
  /// and left the screen lost it silently.
  Future<void> _saveProgress() async {
    if (_saving) return;
    if (!await _assertCanAct()) return;
    setState(() => _saving = true);
    _applyFormFields();
    await LocalDB.saveIncident(_inc);
    SyncService.pushIncident(_inc).catchError((_) => false);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onStatusChanged?.call();
    _snack('✅ Progress saved', AppColors.accent);
  }

  Future<void> _advanceStatus(String newStatus) async {
    if (_saving) return;
    if (!await _assertCanAct()) return;
    // Require a corrective action before entering the FINAL stage, whatever
    // the admin renamed it to — hardcoding 'CLOSED' meant a renamed final
    // stage could be reached with the action field left blank.
    final isFinal = _statusOrder.isNotEmpty && newStatus == _statusOrder.last;
    if (isFinal && _actionCtrl.text.trim().isEmpty) {
      _snack('Enter corrective action first', AppColors.red); return;
    }
    // ★ 2026-10-04. A case cannot move into investigation / corrective action
    // with nobody responsible for it. Any stage after the first needs an
    // assignee; if there is none, the picker opens here and cancelling it
    // cancels the status change.
    final isFirst = _statusOrder.isNotEmpty && newStatus == _statusOrder.first;
    if (!isFirst && !IncidentAssign.hasAssignee(_inc)) {
      _snack('Assign a person for the corrective action first',
          AppColors.amber);
      await _assignInvestigator(required: true);
      if (!mounted || !IncidentAssign.hasAssignee(_inc)) return;
    }
    setState(() => _saving = true);
    final now = DateTime.now().toIso8601String();
    _inc['status'] = newStatus;
    _applyFormFields();
    // Stage timestamps. The final-stage stamp follows _statusOrder; the two
    // named stamps only apply if the admin still has those stages.
    if (isFinal)                      _inc['closedAt']               = now;
    if (newStatus == 'INVESTIGATING') _inc['investigationStartedAt'] = now;
    if (newStatus == 'ACTION TAKEN')  _inc['actionTakenAt']          = now;
    await LocalDB.saveIncident(_inc);
    SyncService.pushIncident(_inc).catchError((_) => false);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onStatusChanged?.call();
    _snack(
      isFinal ? '✅ Case closed & synced' : '✅ Status → $newStatus',
      isFinal ? const Color(0xFF16A34A) : AppColors.accent,
    );
  }

  // Resolve the evidence image for PDF/share.
  // IMPORTANT: on mobile the full image is stored as a FILE (imageRef) and
  // imageBase64 is stripped from the record — so we MUST ask ImageStorage
  // first (it handles imageRef files AND legacy inline base64). Only if that
  // yields nothing do we fall back to any inline base64 still on the record.
  Future<Uint8List?> _resolveImageBytes() async {
    try {
      final fromStore = await ImageStorage.getImageForIncident(_inc);
      if (fromStore != null && fromStore.isNotEmpty) return fromStore;
    } catch (_) {}
    // Fallback: any inline base64 fields (medium-res or thumbnail).
    final shareB64 = _inc['shareImageBase64']?.toString() ?? '';
    final thumbB64 = _inc['thumbnailBase64']?.toString() ?? '';
    final b64 = shareB64.isNotEmpty ? shareB64 : thumbB64;
    if (b64.isEmpty) return null;
    try { return base64Decode(b64); } catch (_) { return null; }
  }

  // ★ v31: Show PDF options bottom sheet (Download / WhatsApp / Email)
  void _showPdfOptions() {
    final sl = SL.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4,
              decoration: BoxDecoration(
                color: sl.text4.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text('PDF Report', style: TextStyle(
              color: sl.text1, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Choose how to share the PDF', style: TextStyle(
              color: sl.text3, fontSize: 12)),
            const SizedBox(height: 20),
            _pdfOptionTile(
              icon: Icons.download_rounded,
              color: AppColors.accent,
              label: 'Download / Save Locally',
              subtitle: 'Save PDF to device',
              onTap: () { Navigator.pop(ctx); _exportPdfLocal(); },
              sl: sl,
            ),
            const SizedBox(height: 10),
            _pdfOptionTile(
              icon: Icons.phone,
              color: const Color(0xFF25D366),
              label: 'Share via WhatsApp',
              subtitle: 'Send PDF + image on WhatsApp',
              onTap: () { Navigator.pop(ctx); _shareWhatsAppWithPdf(); },
              sl: sl,
            ),
            const SizedBox(height: 10),
            _pdfOptionTile(
              icon: Icons.email_outlined,
              color: const Color(0xFF1976D2),
              label: 'Share via Email',
              subtitle: 'Attach PDF to email',
              onTap: () { Navigator.pop(ctx); _shareEmailWithPdf(); },
              sl: sl,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _pdfOptionTile({
    required IconData icon, required Color color, required String label,
    required String subtitle, required VoidCallback onTap, required SL sl,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25))),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(
                color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
              Text(subtitle, style: TextStyle(
                color: sl.text3, fontSize: 11)),
            ])),
          Icon(Icons.chevron_right_rounded, color: sl.text4, size: 20),
        ]),
      ),
    );
  }

  // ★ v31: Download/save PDF locally (original behavior + image)
  Future<void> _exportPdfLocal() async {
    try {
      _snack('Generating PDF…', AppColors.accent);
      final user = await LocalDB.getCurrentUser() ?? {};
      final imageBytes = await _resolveImageBytes();
      await PdfExport.downloadOrShareIncident(
        incident: _inc,
        reporterName: user['name']?.toString() ?? Branding.defaultReporter,
        reporterPno:  user['pno']?.toString()  ?? '',
        imageBytes: imageBytes,
      );
    } catch (e) { _snack('PDF failed: $e', AppColors.red); }
  }

  // ★ 2026-10-03: every share here sends the PDF REPORT FILE through the one
  // PdfExport.shareIncidentPdf path. Before, a web user, a failed PDF, or the
  // header WhatsApp button got a text summary (or the bare photo) instead.
  // WhatsApp gets the file with no caption: WhatsApp on Android drops the
  // attachment when the intent also carries text (the note that used to live
  // here). Email keeps the text summary as the message body.
  Future<void> _sharePdf({required String channel}) async {
    _snack('Generating PDF report...', AppColors.accent);
    try {
      final user = await LocalDB.getCurrentUser() ?? {};
      final imageBytes = await _resolveImageBytes();
      final outcome = await PdfExport.shareIncidentPdf(
        incident: _inc,
        reporterName: user['name']?.toString() ?? Branding.defaultReporter,
        reporterPno:  user['pno']?.toString()  ?? '',
        imageBytes: imageBytes,
        text: channel == 'whatsapp' ? '' : _buildShareText(),
        subject: '${Branding.appTitle}: ${_inc['title'] ?? 'Safety Report'}',
      );
      if (outcome == 'downloaded') {
        _snack('PDF downloaded - attach it in '
            '${channel == 'whatsapp' ? 'WhatsApp' : 'your email'}',
            AppColors.accent);
      }
    } catch (e) {
      _snack('Share failed: $e', AppColors.red);
    }
  }

  Future<void> _shareWhatsAppWithPdf() => _sharePdf(channel: 'whatsapp');

  Future<void> _shareEmailWithPdf() => _sharePdf(channel: 'email');

  Future<void> _shareWhatsAppDirect() => _sharePdf(channel: 'whatsapp');

  String _buildShareText() {
    final title    = _inc['title']?.toString() ?? 'Near Miss Report';
    final severity = _inc['severity']?.toString() ?? 'MEDIUM';
    final plant    = _inc['plant']?.toString() ?? '';
    final dept     = _inc['dept']?.toString() ?? '';
    final location = _inc['location']?.toString() ?? '';
    final desc     = _inc['desc']?.toString() ?? '';
    final date     = _inc['date']?.toString().split('T').first ?? '';
    final action   = _inc['immediateAction']?.toString() ?? _inc['correctiveAction']?.toString() ?? '';
    final category = _inc['wsaCategory']?.toString() ?? '';

    final buf = StringBuffer();
    buf.writeln('⚠️ *${Branding.appTitle} — Near Miss Report*');
    buf.writeln();
    buf.writeln('📋 *Title:* $title');
    buf.writeln('🔴 *Severity:* $severity');
    buf.writeln('🏭 *Plant:* $plant');
    if (dept.isNotEmpty) buf.writeln('🏢 *Department:* $dept');
    buf.writeln('📍 *Location:* $location');
    buf.writeln('📅 *Date:* $date');
    if (category.isNotEmpty) buf.writeln('⚠️ *Category:* $category');
    buf.writeln();
    if (desc.isNotEmpty) {
      buf.writeln('📝 *Description:*');
      buf.writeln(desc);
      buf.writeln();
    }
    if (action.isNotEmpty) {
      buf.writeln('🔧 *Corrective Action:*');
      buf.writeln(action);
      buf.writeln();
    }
    buf.writeln('—');
    buf.write('_Generated by ${Branding.appTitle}_');
    return buf.toString();
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sl  = SL.of(context);
    final sev = _inc['severity']?.toString() ?? 'MEDIUM';
    final sc  = _sevColor(sev);

    // ── Light neutral background regardless of dark/light mode ──
    final bgColor = sl.isDark
        ? const Color(0xFF1C1F2E)   // dark: deep blue-grey, not black
        : const Color(0xFFF5F6FA);  // light: soft grey-white

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: sl.isDark
            ? const Color(0xFF252840) : Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded,
              color: sl.text1, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Incident report',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w700),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('ID: ${_inc['id']?.toString() ?? '—'}',
            style: TextStyle(color: sl.text4, fontSize: 10)),
        ]),
        actions: [
          // ★ v31: WhatsApp share button
          IconButton(
            tooltip: 'Share on WhatsApp',
            onPressed: _shareWhatsAppDirect,
            icon: Container(
              width: 24, height: 24,
              decoration: const BoxDecoration(
                color: Color(0xFF25D366), shape: BoxShape.circle),
              child: const Icon(Icons.phone, color: Colors.white, size: 14)),
          ),
          // ★ v31: PDF button with sub-options
          IconButton(
            tooltip: 'PDF Report',
            onPressed: _showPdfOptions,
            icon: const Icon(Icons.picture_as_pdf,
                color: AppColors.accent, size: 22)),
        ],
      ),
      // No action bar when the case is at its final stage, or while the
      // permission check is still resolving, or when this user may not act on
      // this plant's records.
      bottomNavigationBar: (_isClosed || !_permChecked || !_canAct)
          ? null : _buildBottomBar(sl, bgColor),
      // ★ 2026-10-04. Desktop/laptop: the report on the left, the work on it
      // (owner, share, mitigation, timeline) on the right, so both are on
      // screen at once instead of one 720px column with a page of scrolling.
      // Phones keep the single column, with Quick actions right after the
      // details.
      body: LayoutBuilder(builder: (context, box) {
        final twoCol = box.maxWidth >= _kTwoColMin;
        final details = _detailsColumn(sl, sev, sc, bgColor,
            quickActionsInline: !twoCol);
        final work = _workColumn(sl, bgColor, withQuickActions: twoCol);
        return SingleChildScrollView(
          padding: slGutter(context,
              maxWidth: twoCol ? SLLayout.wide : SLLayout.content,
              base: const EdgeInsets.fromLTRB(14, 14, 14, 20)),
          child: twoCol
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildStatusPipeline(sl, bgColor),
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 6, child: details),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: work),
                  ]),
                  const SizedBox(height: 24),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildStatusPipeline(sl, bgColor),
                  const SizedBox(height: 12),
                  details,
                  work,
                  const SizedBox(height: 24),
                ]),
        );
      }),
    );
  }

  /// Content width at which the page splits into two columns.
  static const double _kTwoColMin = 980;

  /// The report itself: what was found, where, by whom.
  Widget _detailsColumn(SL sl, String sev, Color sc, Color bgColor,
          {bool quickActionsInline = false}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── HEADER ROW ───────────────────────────────────────
          Text(_inc['title']?.toString() ?? 'Incident',
              style: TextStyle(color: sl.text1, fontSize: 17,
                  fontWeight: FontWeight.w800, height: 1.3)),
          const SizedBox(height: 8),
          Row(children: [
            _pill(sev, sc),
            const SizedBox(width: 6),
            _pill(
              _inc['type']?.toString() == 'AI_SCAN'
                  ? '🔍 AI Scan' : '⚠️ Near Miss',
              AppColors.accent),
            const Spacer(),
            if (_inc['riskScore'] != null)
              _scoreCircle(_inc['riskScore'], sc),
          ]),
          const SizedBox(height: 12),

          // ── EVIDENCE PHOTO (if available) ────────────────────
          _buildEvidencePhoto(sl, bgColor),

          // ── COMPACT INFO ROWS (not giant grid) ───────────────
          _buildCompactInfo(sl, bgColor),
          const SizedBox(height: 12),
          // Phones: actions straight after the facts, not below the hazards.
          if (quickActionsInline) ...[
            _buildQuickActions(sl, bgColor),
            const SizedBox(height: 12),
          ],

          // ── DESCRIPTION ──────────────────────────────────────
          if ((_inc['desc']?.toString() ?? '').isNotEmpty) ...[
            _textSection(sl, bgColor, 'Description', Icons.notes_rounded,
                _SecColors.description, _inc['desc']?.toString() ?? ''),
            const SizedBox(height: 12),
          ],

          // ── IMMEDIATE ACTION ─────────────────────────────────
          if ((_inc['immediateAction']?.toString() ?? '').isNotEmpty) ...[
            _textSection(sl, bgColor, 'Immediate action at site',
                Icons.health_and_safety_outlined, _SecColors.immediate,
                _inc['immediateAction']?.toString() ?? ''),
            const SizedBox(height: 10),
          ],

          // ── HAZARDS LIST ─────────────────────────────────────
          _buildHazardsList(sl, bgColor),
      ]);

  /// The work on the report: quick actions, mitigation form, timeline.
  Widget _workColumn(SL sl, Color bgColor, {bool withQuickActions = true}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (withQuickActions) ...[
            _buildQuickActions(sl, bgColor),
            const SizedBox(height: 12),
          ],

          // ── MITIGATION / CLOSED ──────────────────────────────
          // A user who may not act on this record gets the read-only summary,
          // not an editable form whose Save button would be rejected.
          if (_isClosed)
            _buildClosedSummary(sl, bgColor)
          else if (_permChecked && !_canAct)
            _buildReadOnlyNotice(sl, bgColor)
          else
            _buildMitigationForm(sl, bgColor),
          const SizedBox(height: 10),

          // ── TIMELINE ─────────────────────────────────────────
          _buildTimeline(sl, bgColor),
      ]);

  // ─── QUICK ACTIONS ───────────────────────────────────────────
  /// Everything a reviewer does with a case, in one place: who owns it, move
  /// it on, share the PDF report, copy a text summary, open the reporter's or
  /// owner's profile. Each button calls the same code path as the app bar /
  /// bottom bar / Log row, so there is one behaviour per action.
  Widget _buildQuickActions(SL sl, Color bg) {
    final owner = IncidentAssign.assigneeName(_inc);
    final ownerId = _inc['assignedTo']?.toString().trim() ?? '';
    final reporterPno = (_inc['reportedByPno']?.toString() ??
            _inc['reporterPno']?.toString() ?? '').trim();
    final canEdit = _permChecked && _canAct && !_isClosed;

    final curIdx = _statusOrder.indexOf(_status);
    final nextSt = (curIdx >= 0 && curIdx + 1 < _statusOrder.length)
        ? _statusOrder[curIdx + 1] : null;

    final target = _targetDate == null
        ? '' : DateFormat('dd MMM yyyy').format(_targetDate!);
    final overdue = _targetDate != null &&
        _targetDate!.isBefore(DateTime.now()) && !_isClosed;
    final stColor = _statusColor(_status);

    Widget fact(IconData icon, String label, String value,
        {Color? valueColor}) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(children: [
        Icon(icon, size: 15, color: sl.text4),
        const SizedBox(width: 8),
        SizedBox(width: 92, child: Text(label,
            style: TextStyle(color: sl.text4, fontSize: 11.5))),
        Expanded(child: Text(value,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: valueColor ?? sl.text1, fontSize: 12.5,
                fontWeight: FontWeight.w700))),
      ]),
    );

    return _section(sl, bg,
      title: 'Quick actions', icon: Icons.bolt_rounded,
      color: _SecColors.actions,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        fact(Icons.flag_outlined, 'Status',
            _status.isEmpty ? '—' : _status,
            valueColor: _inkOn(sl, stColor)),
        fact(owner.isEmpty ? Icons.person_off_outlined : Icons.person_rounded,
            'Action owner', owner.isEmpty ? 'Unassigned' : owner,
            valueColor: owner.isEmpty ? sl.amberText : null),
        fact(Icons.event_rounded, 'Target date',
            target.isEmpty ? 'Not set' : (overdue ? '$target · OVERDUE' : target),
            valueColor: overdue ? sl.redText
                : (target.isEmpty ? sl.text4 : null)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (canEdit)
            _qaButton(
              icon: owner.isEmpty
                  ? Icons.person_add_alt_1_rounded
                  : Icons.swap_horiz_rounded,
              label: owner.isEmpty ? 'Assign owner' : 'Transfer',
              color: AppColors.accent,
              onTap: _saving ? null : () => _assignInvestigator()),
          if (canEdit && nextSt != null)
            _qaButton(
              icon: nextSt == _statusOrder.last
                  ? Icons.lock_rounded : Icons.manage_search_rounded,
              label: nextSt == _statusOrder.last
                  ? 'Close case' : _titleCase(nextSt),
              color: nextSt == _statusOrder.last
                  ? const Color(0xFF16A34A) : _statusColor(nextSt),
              onTap: _saving ? null : () => _advanceStatus(nextSt)),
          _qaButton(
            icon: Icons.chat_rounded, label: 'WhatsApp',
            color: const Color(0xFF25D366),
            onTap: _shareWhatsAppWithPdf),
          _qaButton(
            icon: Icons.email_outlined, label: 'Email',
            color: const Color(0xFF1976D2),
            onTap: _shareEmailWithPdf),
          _qaButton(
            icon: Icons.picture_as_pdf_rounded, label: 'Download PDF',
            color: AppColors.red,
            onTap: _exportPdfLocal),
          _qaButton(
            icon: Icons.copy_rounded, label: 'Copy summary',
            color: Colors.blueGrey,
            onTap: _copySummary),
          if (reporterPno.isNotEmpty)
            _qaButton(
              icon: Icons.badge_outlined, label: 'Reporter',
              color: Colors.blueGrey,
              onTap: () => _openProfile(reporterPno.toLowerCase())),
          if (ownerId.isNotEmpty)
            _qaButton(
              icon: Icons.contact_page_outlined, label: 'Owner profile',
              color: Colors.blueGrey,
              onTap: () => _openProfile(ownerId)),
        ]),
      ]),
    );
  }

  Widget _qaButton({
    required IconData icon, required String label,
    required Color color, required VoidCallback? onTap,
  }) {
    final sl = SL.of(context);
    final ink = _inkOn(sl, color);
    return Material(
      color: color.withOpacity(sl.isDark ? 0.16 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: color.withOpacity(0.35))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: ink),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: ink, fontSize: 12,
                fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  /// Readable text colour on a light tint of [c]. SL.textOn() only knows the
  /// palette colours and throws on the rest (WhatsApp green, blueGrey, the
  /// status colours), so map those here.
  Color _inkOn(SL sl, Color c) {
    if (sl.isDark) return Color.lerp(c, Colors.white, 0.35)!;
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness * 0.62).clamp(0.0, 1.0)).toColor();
  }

  String _titleCase(String s) => s.split(' ').map((w) => w.isEmpty
      ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}').join(' ');

  void _openProfile(String username) => Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => EmployeeProfileScreen(username: username)));

  Future<void> _copySummary() async {
    await Clipboard.setData(ClipboardData(text: _buildShareText()));
    _snack('Summary copied to clipboard', AppColors.accent);
  }

  // ─── STATUS PIPELINE ─────────────────────────────────────────
  Widget _buildStatusPipeline(SL sl, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: _card(sl, bg),
    child: Row(
      children: _statusOrder.asMap().entries.map((e) {
        final idx    = e.key;
        final label  = e.value;
        final curIdx = _statusOrder.indexOf(_status);
        final done   = idx < curIdx;
        final active = idx == curIdx;
        final color  = _statusColor(label);
        final isLast = idx == _statusOrder.length - 1;
        return Expanded(child: Row(children: [
          Expanded(child: Column(children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done  ? const Color(0xFF16A34A).withOpacity(0.12)
                    : active ? color.withOpacity(0.12) : Colors.transparent,
                border: Border.all(
                  color: done  ? const Color(0xFF16A34A)
                      : active ? color
                      : sl.border.withOpacity(0.5),
                  width: active ? 2 : 1)),
              child: Center(child: done
                ? const Icon(Icons.check_rounded,
                    color: Color(0xFF16A34A), size: 12)
                : Text('${idx+1}', style: TextStyle(
                    color: active ? color : sl.text4,
                    fontSize: 9, fontWeight: FontWeight.w700)))),
            const SizedBox(height: 3),
            Text(label, textAlign: TextAlign.center,
              style: TextStyle(
                color: done  ? const Color(0xFF16A34A)
                    : active ? color : sl.text4,
                fontSize: 10,
                fontWeight: active ? FontWeight.w800 : FontWeight.w500),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          if (!isLast) Expanded(child: Container(
            height: 1.5,
            margin: const EdgeInsets.only(bottom: 16),
            color: done
                ? const Color(0xFF16A34A).withOpacity(0.4)
                : sl.border.withOpacity(0.4))),
        ]));
      }).toList()));

  // ─── EVIDENCE PHOTO ──────────────────────────────────────────
  // Shows the image the analysis was performed on. Uses the resolved-bytes
  // future (file ref → inline base64 → Supabase URL) rather than reading only
  // the inline base64 fields, because on mobile the full base64 is stripped
  // from the record after the image is saved to a file (imageRef).
  Widget _buildEvidencePhoto(SL sl, Color bg) {
    // Quick check: if there's no image reference of ANY kind on the record,
    // don't reserve space or show a loader.
    final hasAnyImageRef = ((_inc['imageRef']?.toString() ?? '').isNotEmpty) ||
        ((_inc['imageBase64']?.toString() ?? '').isNotEmpty) ||
        ((_inc['shareImageBase64']?.toString() ?? '').isNotEmpty) ||
        ((_inc['thumbnailBase64']?.toString() ?? '').isNotEmpty) ||
        ((_inc['imageUrl']?.toString() ?? '').startsWith('http'));
    if (!hasAnyImageRef) return const SizedBox.shrink();

    return FutureBuilder<Uint8List?>(
      future: _evidenceImageFuture,
      builder: (context, snap) {
        // While loading, show a compact placeholder so the layout doesn't jump.
        if (snap.connectionState == ConnectionState.waiting) {
          return Column(children: [
            Container(
              width: double.infinity,
              height: 140,
              decoration: BoxDecoration(
                color: sl.isDark ? const Color(0xFF252840) : Colors.white,
                border: Border.all(color: sl.isDark ? Colors.white10 : Colors.black12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: sl.text4))),
            ),
            const SizedBox(height: 12),
          ]);
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();

        return Column(children: [
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: sl.isDark ? const Color(0xFF252840) : Colors.white,
                  border: Border.all(color: sl.isDark
                      ? Colors.white10 : Colors.black12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            // Tap anywhere on the image to view it full-screen.
            Positioned.fill(child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _openFullImage(bytes),
              ),
            )),
            Positioned(
              top: 8, right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.zoom_in_rounded, color: Colors.white, size: 13),
                  SizedBox(width: 3),
                  Text('Analysed image', style: TextStyle(
                      color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 12),
        ]);
      },
    );
  }

  // Full-screen, pinch-to-zoom viewer for the evidence image.
  void _openFullImage(Uint8List bytes) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(children: [
          InteractiveViewer(
            minScale: 0.8, maxScale: 5,
            child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
          ),
          Positioned(
            top: 4, right: 4,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ]),
      ),
    );
  }

  // ─── COMPACT INFO (replaces giant GridView) ──────────────────
  Widget _buildCompactInfo(SL sl, Color bg) {
    final rows = [
      ['📅 Date',         _fmt(_inc['date']?.toString())],
      ['🏭 Plant',        _inc['plant']?.toString() ?? '—'],
      ['🏢 Department',   _inc['dept']?.toString() ?? '—'],
      ['📍 Location',     _inc['location']?.toString() ?? '—'],
      ['👤 Reported by',  _inc['reportedBy']?.toString() ?? '—'],
      ['🔖 P.No',         _inc['reportedByPno']?.toString() ?? '—'],
      ['⚠️ WSA Cause',    _inc['wsaCategory']?.toString() ?? '—'],
      ['👥 People',       _inc['people']?.toString() ?? '—'],
    ].where((r) => r[1] != '—' && r[1].isNotEmpty).toList();

    return _section(sl, bg,
      title: 'Case details', icon: Icons.assignment_outlined,
      color: _SecColors.details, padding: EdgeInsets.zero,
      child: Column(
        children: rows.asMap().entries.map((e) {
          final isLast = e.key == rows.length - 1;
          final r = e.value;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 9),
              child: Row(children: [
                Text(r[0], style: TextStyle(
                    color: sl.text4, fontSize: 11)),
                const SizedBox(width: 10),
                Expanded(child: Text(r[1],
                  textAlign: TextAlign.right,
                  style: TextStyle(color: sl.text1, fontSize: 12,
                      fontWeight: FontWeight.w600),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
              ])),
            if (!isLast) Divider(height: 1,
                color: sl.border.withOpacity(0.35),
                indent: 14, endIndent: 14),
          ]);
        }).toList()));
  }

  // ─── HAZARD LIST ─────────────────────────────────────────────
  Widget _buildHazardsList(SL sl, Color bg) {
    final hazards = _parseHazards();
    if (hazards.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(sl, bg,
        title: 'Hazards identified (${hazards.length})',
        icon: Icons.warning_amber_rounded,
        color: _SecColors.hazards, padding: EdgeInsets.zero,
        child: Column(children: hazards.asMap().entries.map((e) {
          final idx  = e.key;
          final h    = Map<String, dynamic>.from(e.value as Map);
          final sev  = h['severity']?.toString() ?? 'MEDIUM';
          final sc   = _sevColor(sev);
          final isLast = idx == hazards.length - 1;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                        color: sc, shape: BoxShape.circle),
                    child: Center(child: Text('${idx+1}',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 9, fontWeight: FontWeight.w800)))),
                  const SizedBox(width: 8),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text(h['name']?.toString() ?? '—',
                          style: TextStyle(color: sl.text1, fontSize: 12,
                              fontWeight: FontWeight.w700))),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: sc.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: sc)),
                          child: Text(
                            sev.toUpperCase(),
                            style: TextStyle(color: sc, fontSize: 8,
                                fontWeight: FontWeight.w800))),
                      ]),
                      if ((h['description']?.toString() ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(h['description']?.toString() ?? '',
                          style: TextStyle(color: sl.text2, fontSize: 11,
                              height: 1.4)),
                      ],
                      if ((h['regulation']?.toString() ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(children: [
                          const Text('⚖️ ', style: TextStyle(fontSize: 9)),
                          Expanded(child: Text(
                            h['regulation']?.toString() ?? '',
                            style: TextStyle(color: sl.text4, fontSize: 9,
                                fontStyle: FontStyle.italic))),
                        ]),
                      ],
                      if ((h['correctiveAction']?.toString() ?? '').isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                                color: AppColors.accent.withOpacity(0.25))),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('🔧 ',
                                  style: TextStyle(fontSize: 10)),
                              Expanded(child: Text(
                                h['correctiveAction']?.toString() ?? '',
                                style: const TextStyle(
                                    color: AppColors.accent,
                                    fontSize: 10, height: 1.4))),
                            ])),
                      ],
                    ])),
                ])),
            if (!isLast) Divider(height: 1,
                color: sl.border.withOpacity(0.35),
                indent: 12, endIndent: 12),
          ]);
        }).toList())),
      const SizedBox(height: 10),
    ]);
  }

  // ─── MITIGATION FORM ─────────────────────────────────────────
  Widget _buildMitigationForm(SL sl, Color bg) => _section(sl, bg,
    title: 'Mitigation & closure', icon: Icons.engineering_rounded,
    color: _SecColors.mitigation,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _formLabel('Corrective action assigned to *', sl),
      _investigatorField(sl, bg),
      const SizedBox(height: 10),
      _formLabel('Corrective Action Taken *', sl),
      _formField(_actionCtrl,
          'Describe what was done to mitigate…', 3, sl, bg),
      const SizedBox(height: 10),
      _formLabel('Closed / Verified by', sl),
      _formField(_closedByCtrl, 'Name and designation', 1, sl, bg),
      const SizedBox(height: 10),
      _formLabel('Target date for completion', sl),
      _targetDatePicker(sl, bg),
      const SizedBox(height: 10),
      _formLabel('Additional remarks', sl),
      _formField(_remarksCtrl, 'Any other notes…', 2, sl, bg),
    ]));

  /// Who is investigating this incident, and the handover control.
  ///
  /// A tappable field backed by [showUserPicker] rather than a dropdown of every
  /// user: the roster is ~10,000 people after the quarterly import, which is
  /// neither scrollable nor safe to hold in memory. The picker searches Postgres
  /// by name AND SAIL P.no, which is how people actually identify each other
  /// here — two colleagues share a name far more often than a P.no.
  Widget _investigatorField(SL sl, Color bg) {
    final fieldBg = sl.isDark
        ? const Color(0xFF2A2D42) : const Color(0xFFF0F1F5);
    final assignee = _inc['assignedTo']?.toString().trim() ?? '';
    final assignedName = _inc['assignedToName']?.toString().trim() ?? '';
    final assignedAt = _inc['assignedAt']?.toString().trim() ?? '';

    String when = '';
    if (assignedAt.isNotEmpty) {
      final d = DateTime.tryParse(assignedAt);
      if (d != null) when = DateFormat('dd MMM yyyy').format(d);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: _saving ? null : _assignInvestigator,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
        decoration: BoxDecoration(
          color: fieldBg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: sl.border.withOpacity(0.6)),
        ),
        child: Row(children: [
          Icon(assignee.isEmpty
                  ? Icons.person_search_rounded
                  : Icons.person_rounded,
              size: 16, color: assignee.isEmpty ? sl.text4 : AppColors.accent),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  assignee.isEmpty
                      ? 'Nobody assigned — tap to choose who implements the action'
                      : (assignedName.isEmpty ? assignee : assignedName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: assignee.isEmpty ? sl.text4 : sl.text1,
                      fontSize: 12.5,
                      fontWeight: assignee.isEmpty
                          ? FontWeight.w400
                          : FontWeight.w600),
                ),
                if (assignee.isNotEmpty)
                  Text(
                    when.isEmpty
                        ? '@$assignee'
                        : '@$assignee • assigned $when',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: sl.text4, fontSize: 10.5),
                  ),
              ],
            ),
          ),
          // "Who is this?" is a separate question from "hand it to someone
          // else", and the answer (unit, department, mobile, retirement date)
          // is what a supervisor needs before chasing a stalled case.
          if (assignee.isNotEmpty)
            IconButton(
              tooltip: 'View profile',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              icon: Icon(Icons.badge_outlined, size: 16, color: sl.text3),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => EmployeeProfileScreen(username: assignee))),
            ),
          Text(assignee.isEmpty ? 'Assign' : 'Transfer',
              style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }

  /// Assign or hand over the investigation, saved immediately.
  ///
  /// Not folded into "Save progress": a handover is a fact about who is
  /// responsible right now, and leaving it staged behind another button meant a
  /// reassignment could be silently lost when the screen was closed.
  Future<void> _assignInvestigator({bool required = false}) async {
    if (_saving) return;
    if (!await _assertCanAct()) return;
    if (!mounted) return;
    setState(() => _saving = true);
    // Shared with the Log row's "Assign" button — see IncidentAssign.
    final res = await IncidentAssign.pickAndSave(
      context, _inc,
      title: required ? 'Assign who will implement the corrective action' : null,
      allowClear: !required,
      // Keep whatever is typed in the form: saving the assignment must not
      // discard a corrective action the user has half written.
      beforeSave: _applyFormFields,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.changed) widget.onStatusChanged?.call();
    if (res.message.isNotEmpty) {
      _snack(res.message,
          res.changed ? AppColors.accent : AppColors.red);
    }
  }

  /// Target completion date. A tappable field rather than a text box so the
  /// stored value is always a valid, uniformly formatted date.
  Widget _targetDatePicker(SL sl, Color bg) {
    final fieldBg = sl.isDark
        ? const Color(0xFF2A2D42) : const Color(0xFFF0F1F5);
    final overdue = _targetDate != null &&
        _targetDate!.isBefore(DateTime.now()) && !_isClosed;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: _targetDate ?? now.add(const Duration(days: 7)),
          // Allow a past date: a target may legitimately have already lapsed
          // when it is being recorded after the fact.
          firstDate: DateTime(now.year - 2),
          lastDate: DateTime(now.year + 5),
        );
        if (picked != null && mounted) setState(() => _targetDate = picked);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: fieldBg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: overdue
              ? AppColors.red.withOpacity(0.7)
              : sl.border.withOpacity(0.5))),
        child: Row(children: [
          Icon(Icons.event_rounded,
              size: 15, color: overdue ? sl.redText : sl.text4),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _targetDate == null
                ? 'Tap to set a target date'
                : DateFormat('dd MMM yyyy').format(_targetDate!),
            style: TextStyle(
                color: _targetDate == null ? sl.text4 : sl.text1,
                fontSize: 12.5,
                fontWeight: _targetDate == null
                    ? FontWeight.w400 : FontWeight.w600))),
          if (overdue)
            Text('OVERDUE', style: TextStyle(
                color: sl.redText, fontSize: 9.5,
                fontWeight: FontWeight.w800)),
          if (_targetDate != null && !overdue)
            IconButton(
              tooltip: 'Clear',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => setState(() => _targetDate = null),
              icon: Icon(Icons.close_rounded, size: 15, color: sl.text4)),
        ]),
      ),
    );
  }

  /// Shown instead of the mitigation form when this user may not act on the
  /// record. Says why, and still surfaces whatever progress has been recorded,
  /// so viewing another plant's case is informative rather than just blocked.
  Widget _buildReadOnlyNotice(SL sl, Color bg) {
    final rows = <List<String>>[
      ['Corrective Action', _inc['correctiveAction']?.toString() ?? ''],
      ['Target Date',       _inc['targetDate']?.toString() ?? ''],
      ['Assigned To',       _inc['assignedToName']?.toString().trim().isNotEmpty
                               == true
                               ? '${_inc['assignedToName']} '
                                   '(@${_inc['assignedTo'] ?? ''})'
                               : _inc['assignedTo']?.toString() ?? ''],
    ].where((r) => r[1].isNotEmpty).toList();

    return _section(sl, bg,
      title: 'View only', icon: Icons.visibility_outlined,
      color: _SecColors.readOnly,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('This incident belongs to another plant, so it can be reviewed '
             'here but only updated by that plant or an admin.',
          style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.4)),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...rows.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 110, child: Text(r[0],
                style: TextStyle(color: sl.text4, fontSize: 10,
                    fontWeight: FontWeight.w600))),
              Expanded(child: Text(r[1],
                style: TextStyle(color: sl.text1, fontSize: 12, height: 1.4))),
            ]))),
        ],
      ]));
  }

  Widget _formLabel(String lbl, SL sl) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(lbl, style: TextStyle(color: sl.text3, fontSize: 11,
        fontWeight: FontWeight.w600)));

  Widget _formField(TextEditingController c, String hint,
      int lines, SL sl, Color bg) {
    final fieldBg = sl.isDark
        ? const Color(0xFF2A2D42) : const Color(0xFFF0F1F5);
    return TextField(
      controller: c, maxLines: lines,
      style: TextStyle(color: sl.text1, fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: sl.text4, fontSize: 11),
        filled: true, fillColor: fieldBg,
        contentPadding: const EdgeInsets.all(11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(
              color: AppColors.accent, width: 2))));
  }

  // ─── CLOSED SUMMARY ──────────────────────────────────────────
  Widget _buildClosedSummary(SL sl, Color bg) => _section(sl, bg,
    title: 'Case closed', icon: Icons.check_circle_rounded,
    color: _SecColors.closed,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ...([
        ['Corrective Action', _inc['correctiveAction']],
        ['Target Date',       _inc['targetDate']],
        ['Closed By',         _inc['closedBy']],
        ['Remarks',           _inc['closingRemarks']],
        ['Closed At',         _inc['closedAt'] != null
            ? _fmt(_inc['closedAt']?.toString()) : null],
      ].where((r) => r[1] != null && r[1].toString().isNotEmpty)
        .map((r) => Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110,
                child: Text(r[0].toString(),
                  style: TextStyle(color: sl.text4, fontSize: 10,
                      fontWeight: FontWeight.w600))),
              Expanded(child: Text(r[1].toString(),
                style: TextStyle(color: sl.text1, fontSize: 12,
                    height: 1.4))),
            ])))
        .toList()),
    ]));

  // ─── TIMELINE ────────────────────────────────────────────────
  Widget _buildTimeline(SL sl, Color bg) {
    final events = <Map<String, String>>[];
    void add(String? ts, String label, String icon) {
      if (ts == null || ts.isEmpty) return;
      events.add({'label': label, 'time': _fmt(ts), 'icon': icon});
    }
    add(_inc['date']?.toString(),                  'Reported',               '📝');
    add(_inc['investigationStartedAt']?.toString(), 'Investigation started',  '🔍');
    add(_inc['actionTakenAt']?.toString(),           'Action taken',           '🔧');
    add(_inc['closedAt']?.toString(),               'Closed',                 '✅');
    if (events.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(sl, bg,
        title: 'Timeline', icon: Icons.timeline_rounded,
        color: _SecColors.timeline,
        child: Column(children: events.asMap().entries.map((e) {
          final isLast = e.key == events.length - 1;
          final ev = e.value;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(
                  color: sl.isDark
                      ? const Color(0xFF2A2D42)
                      : const Color(0xFFF0F1F5),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: sl.border.withOpacity(0.5))),
                child: Center(child: Text(ev['icon']!,
                    style: const TextStyle(fontSize: 12)))),
              if (!isLast) Container(
                  width: 2, height: 24,
                  color: sl.border.withOpacity(0.4)),
            ]),
            const SizedBox(width: 10),
            Expanded(child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ev['label']!, style: TextStyle(
                      color: sl.text1, fontSize: 12,
                      fontWeight: FontWeight.w600)),
                  Text(ev['time']!, style: TextStyle(
                      color: sl.text4, fontSize: 10)),
                ]))),
          ]);
        }).toList())),
    ]);
  }

  // ─── BOTTOM ACTION BAR ───────────────────────────────────────
  Widget _buildBottomBar(SL sl, Color bg) {
    final curIdx  = _statusOrder.indexOf(_status);
    final nextIdx = curIdx + 1;
    final hasNext = nextIdx < _statusOrder.length;
    final nextSt  = hasNext ? _statusOrder[nextIdx] : null;
    // "Closing" = advancing into the FINAL stage, whatever the admin named it.
    // Checking `== 'CLOSED'` meant renaming the last stage silently dropped the
    // closure-remarks requirement. (Deliberately the last stage only, not every
    // terminal status — reaching VERIFIED shouldn't demand closure remarks.)
    final isClose = hasNext && nextIdx == _statusOrder.length - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 26),
      decoration: BoxDecoration(
        color: sl.isDark ? const Color(0xFF252840) : Colors.white,
        border: Border(top: BorderSide(
            color: sl.border.withOpacity(0.4)))),
      // The bar keeps its full-width top border; the action buttons are capped
      // to the same column as the body above, so "Close Case" doesn't end up
      // half a browser away from the case it closes.
      // fillHeight: false — without it the Center inside ContentWidth took the
      // whole screen and this bar hid the app bar and every detail above it.
      child: ContentWidth(maxWidth: SLLayout.wide, fillHeight: false,
          child: Row(children: [
        // Save without advancing. Replaces the old hardcoded "Investigate"
        // shortcut, which named a stage the admin may have renamed or removed
        // and duplicated the advance button's job — while the far more useful
        // action, saving a target date and corrective action in place, had no
        // button at all.
        Expanded(child: OutlinedButton.icon(
          onPressed: _saving ? null : _saveProgress,
          icon: Icon(Icons.save_outlined, color: sl.text2, size: 15),
          label: Text('Save',
            style: TextStyle(color: sl.text2,
                fontWeight: FontWeight.w700, fontSize: 12)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: sl.border, width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
        const SizedBox(width: 8),
        if (hasNext)
          Expanded(flex: 2, child: ElevatedButton.icon(
            onPressed: _saving ? null : () => _advanceStatus(nextSt!),
            icon: _saving
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Icon(isClose ? Icons.lock_rounded
                    : Icons.arrow_forward_rounded,
                  size: 15, color: Colors.white),
            label: Text(
              _saving ? 'Saving…'
                  : isClose ? 'Close Case'
                  : 'Mark as $nextSt',
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w700, fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isClose
                  ? const Color(0xFF16A34A) : AppColors.accent,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          )),
      ])));
  }

  // ─── HELPERS ────────────────────────────────────────────────
  /// One section card: a tinted header band (icon + title) in the section's
  /// colour over a plain body. Every card on this page goes through here, so
  /// the colour coding stays consistent (see [_SecColors]).
  Widget _section(SL sl, Color bg, {
    required String title, required IconData icon, required Color color,
    required Widget child, Widget? trailing,
    EdgeInsets padding = const EdgeInsets.all(14),
  }) {
    final ink = sl.isDark ? Color.lerp(color, Colors.white, 0.5)! : color;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _card(sl, bg,
          borderColor: color.withOpacity(sl.isDark ? 0.45 : 0.22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          decoration: BoxDecoration(
            color: color.withOpacity(sl.isDark ? 0.20 : 0.07),
            border: Border(bottom: BorderSide(
                color: color.withOpacity(sl.isDark ? 0.35 : 0.16)))),
          child: Row(children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: color.withOpacity(sl.isDark ? 0.30 : 0.12),
                borderRadius: BorderRadius.circular(6)),
              child: Icon(icon, size: 14, color: ink)),
            const SizedBox(width: 9),
            Expanded(child: Text(title.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: ink, fontSize: 11.5,
                    fontWeight: FontWeight.w800, letterSpacing: 0.6))),
            if (trailing != null) trailing,
          ]),
        ),
        Padding(padding: padding, child: child),
      ]),
    );
  }

  /// A section whose body is a single block of text.
  Widget _textSection(SL sl, Color bg, String title, IconData icon,
      Color color, String text) => _section(sl, bg,
    title: title, icon: icon, color: color,
    padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
    child: Text(text, style: TextStyle(color: sl.text2,
        fontSize: 12.5, height: 1.5)));

  BoxDecoration _card(SL sl, Color bg, {Color? borderColor}) =>
    BoxDecoration(
      color: sl.isDark ? const Color(0xFF252840) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
          color: borderColor ?? sl.border.withOpacity(0.4)),
      boxShadow: [BoxShadow(
        color: Colors.black.withOpacity(sl.isDark ? 0.15 : 0.04),
        blurRadius: 8, offset: const Offset(0, 2))]);

  Widget _pill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: color.withOpacity(0.5))),
    child: Text(text, style: TextStyle(color: SL.of(context).textOn(color),
        fontSize: 11, fontWeight: FontWeight.w700)));

  Widget _scoreCircle(dynamic score, Color color) => Container(
    width: 40, height: 40,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 2),
      color: color.withOpacity(0.08)),
    child: Center(child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$score', style: TextStyle(color: SL.of(context).textOn(color),
            fontSize: 12, fontWeight: FontWeight.w800)),
        Text('/100', style: TextStyle(color: SL.of(context).textOn(color), fontSize: 10)),
      ])));
}

/// Section colours for the incident detail page. Deliberately muted 700-weight
/// tones (Tailwind/Material scale) so the page reads as a professional report:
/// each section is identifiable at a glance without competing with the
/// severity and status colours, which stay the loudest things on screen.
class _SecColors {
  static const details     = Color(0xFF1E3A8A); // navy      — the facts
  static const description = Color(0xFF475569); // slate     — narrative
  static const immediate   = Color(0xFFB45309); // amber     — on-site action
  static const hazards     = Color(0xFFB91C1C); // deep red  — what is wrong
  static const actions     = Color(0xFF4338CA); // indigo    — things to do
  static const mitigation  = Color(0xFF0F766E); // teal      — the fix
  static const closed      = Color(0xFF15803D); // green     — done
  static const readOnly    = Color(0xFF64748B); // grey      — view only
  static const timeline    = Color(0xFF334155); // blue-grey — history
}
