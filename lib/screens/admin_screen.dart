// lib/screens/admin_screen.dart
// SAIL Safety Lens — ENTERPRISE ADMIN COMMAND CENTRE v5
//
// 12 modules accessible from a drawer navigator:
//   ✓ 0  Overview       — live KPI dashboard
//   ✓ 1  Analytics      — Pareto, trends, MTTR, plant comparison
//   ✓ 2  Bulk Ops       — multi-select close / delete / export
//   ✓ 5  Audit Log      — every admin action, filterable, exportable
//   ✓ 6  System Health  — Apps Script status, sync queue, API keys
//   ✓ 9  Export Centre  — incidents/users/KB/audit → CSV
//
//   ⏳ 3  Workflow Engine    — batch 2
//   ⏳ 4  User Mgmt Advanced — batch 2
//   ⏳ 7  Plant Master       — batch 2
//   ⏳ 8  Custom Lists       — batch 2
//   ⏳ 10 Alerts/Notif       — batch 2
//   ⏳ 11 Backup/Restore     — batch 2
//   ⏳ 12 Compliance         — batch 2
//
// Login: admin / admin

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/sync_service.dart';
import '../services/admin_audit.dart';
import '../services/admin_master_data.dart';
import '../services/admin_alerts.dart';
import '../services/kb_seed_data.dart';
import '../services/knowledge_service.dart';
import '../services/groq_service.dart';
import '../services/gemini_vision.dart';
import '../services/gemini_direct_vision.dart';
import '../services/pdf_kb_extractor.dart';
import '../services/ai_correction_service.dart';
import '../services/image_storage.dart';
// Reuse the same web/mobile download shim that pdf_export.dart uses
import '../services/pdf_export_stub.dart'
    if (dart.library.html) '../services/pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

// ── MODULE LIST ──────────────────────────────────────────────────────
class _AdminModule {
  final int id;
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color   color;
  final bool    ready;
  const _AdminModule(this.id, this.key, this.title, this.subtitle,
      this.icon, this.color, this.ready);
}

class _AdminScreenState extends State<AdminScreen>
    with TickerProviderStateMixin {

  // ── Module catalogue (12 + Overview) ───────────────────────────
  static const _modules = <_AdminModule>[
    _AdminModule(0, 'overview',   'Overview',           'Live KPIs & today',
        Icons.space_dashboard_rounded, Color(0xFF1E88E5), true),
    _AdminModule(1, 'analytics',  'Analytics',          'Trends, Pareto, MTTR',
        Icons.insights_rounded,        Color(0xFF8E24AA), true),
    _AdminModule(2, 'bulkops',    'Bulk Operations',    'Multi-select actions',
        Icons.checklist_rounded,       Color(0xFFF57C00), true),
    _AdminModule(3, 'workflow',   'Workflow Engine',    'Pipeline & SLA',
        Icons.account_tree_rounded,    Color(0xFF00897B), true),
    _AdminModule(4, 'users',      'User Management',    'Roles & permissions',
        Icons.manage_accounts_rounded, Color(0xFF3949AB), true),
    _AdminModule(5, 'audit',      'Audit Log',          'All admin actions',
        Icons.history_rounded,         Color(0xFF6D4C41), true),
    _AdminModule(6, 'health',     'System Health',      'Backend & sync',
        Icons.monitor_heart_rounded,   Color(0xFF43A047), true),
    _AdminModule(7, 'masters',    'Plant Master',       '14 SAIL units',
        Icons.factory_rounded,         Color(0xFF7E57C2), true),
    _AdminModule(8, 'lists',      'Custom Lists',       'WSA, sev, status',
        Icons.tune_rounded,            Color(0xFF00ACC1), true),
    _AdminModule(9, 'export',     'Export Centre',      'CSV downloads',
        Icons.download_rounded,        Color(0xFF039BE5), true),
    _AdminModule(10,'alerts',     'Alerts & Notif',     'Rules & subscribers',
        Icons.notifications_active_rounded, Color(0xFFE53935), true),
    _AdminModule(11,'backup',     'Backup & Restore',   'Snapshots & rollback',
        Icons.backup_rounded,          Color(0xFF5E35B1), true),
    _AdminModule(12,'compliance', 'Compliance',         'FA 1948 scorecard',
        Icons.verified_rounded,        Color(0xFF2E7D32), true),
    _AdminModule(13,'knowledge', 'Knowledge Base',     'Upload PDF/DOCX',
        Icons.auto_stories_rounded,    Color(0xFF1565C0), true),
    _AdminModule(14,'ai_audit',  'AI Audit',           'Model comparison',
        Icons.compare_arrows_rounded,  Color(0xFFD32F2F), true),
    _AdminModule(15,'ai_corrections','AI Corrections',  'User edits & training',
        Icons.model_training_rounded,  Color(0xFF00838F), true),
  ];

  // ── Login state ─────────────────────────────────────────────────
  bool _loggedIn = false;
  bool _loginLoading = false;
  String _loginError = '';
  final _unameCtrl = TextEditingController(text: 'admin');
  final _pwCtrl    = TextEditingController();
  bool  _pwVisible = false;
  String _adminPassword = 'admin';
  String _currentActor = 'admin';

  // ── Navigation state ────────────────────────────────────────────
  int _activeId = 0;

  // ── Data caches ─────────────────────────────────────────────────
  bool _loading = true;
  List<Map<String, dynamic>> _users     = [];
  List<Map<String, dynamic>> _incidents = [];
  List<Map<String, dynamic>> _kbDocs    = [];
  List<Map<String, dynamic>> _auditLog  = [];

  // ── AI Corrections state (feedback loop review queue) ─────────────
  List<Map<String, dynamic>> _corrections = [];
  bool _correctionsLoading = false;
  bool _correctionsLoadedOnce = false; // prevents infinite lazy-reload when empty
  String _corrFilter = 'pending'; // 'pending' | 'ai_mistake' | 'user_preference' | 'all'

  // ── Knowledge Base state ─────────────────────────────────────────
  bool _kbUploading = false;
  String _kbUploadStatus = '';
  int _kbUploadProgress = 0;
  int _kbUploadTotal = 0;

  // ── Bulk-ops state ──────────────────────────────────────────────
  final Set<String> _bulkSelected = {};
  String _bulkFilter = 'ALL';

  // ── Audit filter state ──────────────────────────────────────────
  String _auditActionFilter = '';
  String _auditSearch       = '';

  // ── Analytics — derived live ────────────────────────────────────
  // (computed in build methods)

  // ── System health state ─────────────────────────────────────────
  String? _scriptVersion;
  String? _scriptLastChecked;
  bool _checkingHealth = false;

  // ── Workflow state ──────────────────────────────────────────────
  String? _workflowSelectedId;   // currently expanded incident
  String  _workflowStatusFilter = 'ALL';

  // ── User mgmt state ─────────────────────────────────────────────
  String _userSearch = '';
  String? _userExpandedUname;

  // ── Plant master state ──────────────────────────────────────────
  List<Map<String, String>> _plantsEditable = [];
  List<String> _deptsEditable = [];
  bool _mastersLoaded = false;

  // ── Custom lists state ──────────────────────────────────────────
  String _customListTab = 'wsa';     // wsa | severity | status | obstype | scoring
  Map<String, List<String>> _customLists = {};

  // ── Severity scoring state ─────────────────────────────────────
  Map<String, int> _severityScores = {};
  bool _scoresLoaded = false;

  // ── Alerts state ────────────────────────────────────────────────
  List<Map<String, dynamic>> _alertRules = [];
  bool _alertsLoaded = false;
  bool _isSendingAlerts = false;

  // ── Compliance state ────────────────────────────────────────────
  String _compliancePlantFilter = 'ALL';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _unameCtrl.dispose(); _pwCtrl.dispose();
    _groqKeyCtrl.dispose(); _geminiVisionKeyCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════
  //  LOGIN
  // ══════════════════════════════════════════════════════════════════
  Future<void> _doLogin() async {
    setState(() { _loginLoading = true; _loginError = ''; });
    await Future.delayed(const Duration(milliseconds: 250));
    final u = _unameCtrl.text.trim().toLowerCase();
    final p = _pwCtrl.text;

    bool ok = (u == 'admin' && p == _adminPassword);
    String resolvedActor = u;

    if (!ok) {
      try {
        final localUser = await LocalDB.signIn(u, p);
        if (localUser != null) {
          final isAdm = localUser['isAdmin'] == true ||
              localUser['isAdmin']?.toString().toLowerCase() == 'true';
          if (isAdm) {
            ok = true;
            resolvedActor = localUser['username']?.toString() ?? u;
          }
        }
      } catch (_) {}
    }

    if (ok) {
      _currentActor = resolvedActor;
      await AdminAudit.log(action: AdminAudit.actLoginOk, actor: _currentActor);
      _loadAll();
      setState(() { _loggedIn = true; _loginLoading = false; });
    } else {
      await AdminAudit.log(
          action: AdminAudit.actLoginFail,
          actor: u.isEmpty ? '(unknown)' : u,
          meta: {'reason': 'invalid_credentials'});
      setState(() {
        _loginError  = 'Incorrect credentials or insufficient privileges.';
        _loginLoading = false;
      });
    }
  }

  Future<void> _logout() async {
    await AdminAudit.log(action: AdminAudit.actLogout, actor: _currentActor);
    setState(() {
      _loggedIn = false; _pwCtrl.clear(); _loginError = '';
      _bulkSelected.clear();
    });
  }

  // ══════════════════════════════════════════════════════════════════
  //  DATA LOADING
  // ══════════════════════════════════════════════════════════════════
  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      List<Map<String, dynamic>> sheetsUsers = [];
      try { sheetsUsers = await SyncService.fetchUsers(); } catch (_) {}

      final localUsers  = await LocalDB.getUsers();
      final cachedUsers = await LocalDB.getCachedUsers();

      // Locally-deleted usernames must stay hidden even if the sheet still
      // returns them. Prune tombstones the backend no longer knows about.
      final deletedUnames = LocalDB.deletedUsernames();
      await LocalDB.pruneUsernameTombstones(
          sheetsUsers.map((u) => (u['username']?.toString() ?? '').trim()).toSet());

      final byUname = <String, Map<String, dynamic>>{};
      // Sheets data takes priority, then cached, then local
      for (final u in [...localUsers, ...cachedUsers, ...sheetsUsers]) {
        final uname = (u['username']?.toString() ?? '').trim();
        if (uname.isEmpty) continue;
        if (deletedUnames.contains(uname)) continue; // tombstoned — skip
        if (!byUname.containsKey(uname)) {
          byUname[uname] = Map<String, dynamic>.from(u);
        } else {
          final existing = byUname[uname]!;
          u.forEach((k, v) {
            if (v != null && v.toString().isNotEmpty) {
              existing[k] = v;
            }
          });
        }
      }
      if (!byUname.containsKey('admin')) {
        byUname['admin'] = {
          'username': 'admin', 'name': 'System Admin',
          'designation': 'Administrator', 'plant': 'Corporate – Ranchi',
          'pno': 'ADMIN001', 'isAdmin': true, 'status': 'active',
        };
      }

      // Pull incidents from backend + merge with local
      List<Map<String, dynamic>> sheetsIncs = [];
      try { sheetsIncs = await SyncService.fetchIncidents(); } catch (_) {}
      final localIncs = await LocalDB.getIncidents();

      // Locally-deleted incident ids must stay hidden even if the sheet still
      // returns them. Prune tombstones the backend no longer knows about.
      final deletedIds = LocalDB.deletedIncidentIds();
      await LocalDB.pruneIncidentTombstones(
          sheetsIncs.map((i) => (i['id']?.toString() ?? '').trim()).toSet());

      // Merge: backend overrides, local adds missing
      final byId = <String, Map<String, dynamic>>{};
      for (final inc in [...localIncs, ...sheetsIncs]) {
        final id = (inc['id']?.toString() ?? '').trim();
        if (id.isEmpty) continue;
        if (deletedIds.contains(id)) continue; // tombstoned — skip
        if (!byId.containsKey(id)) {
          byId[id] = Map<String, dynamic>.from(inc);
        } else {
          final existing = byId[id]!;
          inc.forEach((k, v) {
            if (v != null && v.toString().isNotEmpty) existing[k] = v;
          });
        }
      }
      final incs = byId.values.toList();

      final kb    = await LocalDB.getKnowledgeDocs();
      final audit = await AdminAudit.getLog(limit: 500);

      // Masters + alerts
      final plants  = await AdminMasterData.getPlants();
      final depts   = await AdminMasterData.getDepartments();
      final rules   = await AdminAlerts.getRules();
      final wsa     = await AdminMasterData.getWsaCauses();
      final sevs    = await AdminMasterData.getSeverities();
      final stats   = await AdminMasterData.getStatuses();
      final obs     = await AdminMasterData.getObsTypes();
      final scores  = await AdminMasterData.getSeverityScores();

      if (!mounted) return;
      setState(() {
        _users     = byUname.values.toList();
        _incidents = incs;
        _kbDocs    = kb;
        _auditLog  = audit;
        _plantsEditable = plants;
        _deptsEditable  = depts;
        _alertRules     = rules;
        _customLists = {
          'wsa'     : wsa,
          'severity': sevs,
          'status'  : stats,
          'obstype' : obs,
        };
        _severityScores = scores;
        _scoresLoaded   = true;
        _mastersLoaded  = true;
        _alertsLoaded   = true;
        _loading   = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refreshAudit() async {
    final audit = await AdminAudit.getLog(limit: 500);
    if (!mounted) return;
    setState(() => _auditLog = audit);
  }

  // ══════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    if (!_loggedIn) return _buildLoginPage();
    return _buildShell();
  }

  // ── LOGIN PAGE ─────────────────────────────────────────────────
  Widget _buildLoginPage() {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 360),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: sl.card,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: sl.border)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [Color(0xFFD97706), Color(0xFFB45309)]),
                    borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Icons.shield_moon_rounded,
                      color: Colors.white, size: 32)),
                const SizedBox(height: 20),
                Text('Command Centre',
                  style: TextStyle(color: sl.text1, fontSize: 22,
                      fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text('SAIL Safety Lens — Admin v5',
                  style: TextStyle(color: sl.text3, fontSize: 12)),
                const SizedBox(height: 26),
                _loginField('Username', _unameCtrl, sl,
                    icon: Icons.person_outline_rounded),
                const SizedBox(height: 12),
                TextField(
                  controller: _pwCtrl,
                  obscureText: !_pwVisible,
                  onSubmitted: (_) => _doLogin(),
                  style: TextStyle(color: sl.text1, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: sl.text4, fontSize: 12),
                    prefixIcon: Icon(Icons.lock_outline_rounded,
                        color: sl.text4, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_pwVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                          color: sl.text4, size: 18),
                      onPressed: () => setState(() => _pwVisible = !_pwVisible)),
                    filled: true, fillColor: sl.bg2,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 14),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: sl.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: sl.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.amber, width: 2)))),
                const SizedBox(height: 18),
                SizedBox(width: double.infinity, height: 48,
                  child: ElevatedButton(
                    onPressed: _loginLoading ? null : _doLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.amber,
                      disabledBackgroundColor: AppColors.amber.withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                    child: _loginLoading
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Enter Command Centre',
                          style: TextStyle(color: Colors.white, fontSize: 14,
                              fontWeight: FontWeight.w700, letterSpacing: 0.3)))),
                if (_loginError.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 12),
                    child: Text(_loginError,
                      style: const TextStyle(
                          color: AppColors.red, fontSize: 11.5),
                      textAlign: TextAlign.center)),
                const SizedBox(height: 14),
                Text('Default: admin / admin',
                  style: TextStyle(color: sl.text4, fontSize: 10.5)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loginField(String label, TextEditingController c, SL sl,
      {IconData? icon}) =>
    TextField(
      controller: c,
      style: TextStyle(color: sl.text1, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: sl.text4, fontSize: 12),
        prefixIcon: icon != null ? Icon(icon, color: sl.text4, size: 18) : null,
        filled: true, fillColor: sl.bg2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.amber, width: 2))));

  // ══════════════════════════════════════════════════════════════════
  //  SHELL — Drawer + body
  // ══════════════════════════════════════════════════════════════════
  Widget _buildShell() {
    final sl = SL.of(context);
    final width = MediaQuery.of(context).size.width;
    final wideScreen = width >= 900;

    final active = _modules.firstWhere((m) => m.id == _activeId);

    return Scaffold(
      backgroundColor: sl.bg,
      drawer: wideScreen ? null : _navDrawer(sl),
      appBar: AppBar(
        backgroundColor: sl.bg2,
        elevation: 0,
        leading: wideScreen
          ? IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded, color: sl.text1, size: 18),
              onPressed: () => Navigator.pop(context))
          : Builder(builder: (ctx) => IconButton(
              icon: Icon(Icons.menu_rounded, color: sl.text1, size: 22),
              onPressed: () => Scaffold.of(ctx).openDrawer())),
        title: Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFFD97706), Color(0xFFB45309)]),
              borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.shield_moon_rounded,
                color: Colors.white, size: 18)),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(active.title,
              style: TextStyle(color: sl.text1, fontSize: 14,
                  fontWeight: FontWeight.w800)),
            Text(active.subtitle,
              style: TextStyle(color: sl.text4, fontSize: 9)),
          ]),
        ]),
        actions: [
          // Live mini-status badges in top bar
          _topBarBadge('${_incidents.length}',
              Icons.list_alt_rounded, AppColors.accent, sl),
          const SizedBox(width: 4),
          _topBarBadge('${_users.length}',
              Icons.people_rounded, AppColors.green, sl),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: sl.text3, size: 20),
            onPressed: _loadAll),
          IconButton(
            tooltip: 'Sign out',
            icon: Icon(Icons.logout_rounded, color: sl.text3, size: 20),
            onPressed: _logout),
          const SizedBox(width: 4),
        ]),
      body: _loading
        ? Center(child: CircularProgressIndicator(color: AppColors.amber))
        : Row(children: [
            if (wideScreen)
              SizedBox(width: 240, child: _navDrawer(sl, pinned: true)),
            Expanded(child: _moduleBody(active, sl)),
          ]),
    );
  }

  Widget _topBarBadge(String text, IconData icon, Color color, SL sl) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.25))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(
            color: color, fontSize: 10.5, fontWeight: FontWeight.w800)),
      ]));

  // ── DRAWER ─────────────────────────────────────────────────────
  Widget _navDrawer(SL sl, {bool pinned = false}) {
    return Container(
      decoration: BoxDecoration(
        color: sl.bg2,
        border: pinned
          ? Border(right: BorderSide(color: sl.border, width: 0.5))
          : null,
      ),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(
                    color: sl.border, width: 0.5))),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFD97706), Color(0xFFB45309)]),
                    borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.shield_moon_rounded,
                      color: Colors.white, size: 20)),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Command Centre',
                      style: TextStyle(color: sl.text1, fontSize: 13,
                          fontWeight: FontWeight.w800)),
                    Text('@$_currentActor',
                      style: TextStyle(color: sl.text4, fontSize: 10)),
                  ])),
              ])),
            Expanded(child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _modules.length,
              itemBuilder: (_, i) => _navItem(_modules[i], sl, pinned),
            )),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: sl.border, width: 0.5))),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded,
                    color: AppColors.amber, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  '${_modules.where((m) => m.ready).length}/${_modules.length} modules live',
                  style: TextStyle(color: sl.text3, fontSize: 10))),
              ])),
          ]),
      ),
    );
  }

  Widget _navItem(_AdminModule m, SL sl, bool pinned) {
    final active = m.id == _activeId;
    final color  = active ? m.color : sl.text3;
    return Material(
      color: active ? m.color.withOpacity(0.12) : Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _activeId = m.id;
            _bulkSelected.clear();
          });
          if (!pinned) Navigator.of(context).maybePop();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            border: active
              ? Border(left: BorderSide(color: m.color, width: 3))
              : Border(left: BorderSide(color: Colors.transparent, width: 3)),
          ),
          child: Row(children: [
            Icon(m.icon, color: color, size: 18),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(m.title,
                      style: TextStyle(
                        color: active ? sl.text1 : sl.text2,
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600))),
                  if (!m.ready)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: sl.border.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(3)),
                      child: Text('soon',
                          style: TextStyle(color: sl.text4, fontSize: 8,
                              fontWeight: FontWeight.w700))),
                ]),
                Text(m.subtitle, style: TextStyle(
                    color: sl.text4, fontSize: 9.5)),
              ])),
          ]),
        ),
      ),
    );
  }

  // ── ROUTE TO MODULE BODY ───────────────────────────────────────
  Widget _moduleBody(_AdminModule m, SL sl) {
    switch (m.id) {
      case 0:  return _moduleOverview(sl);
      case 1:  return _moduleAnalytics(sl);
      case 2:  return _moduleBulkOps(sl);
      case 3:  return _moduleWorkflow(sl);
      case 4:  return _moduleUsersAdvanced(sl);
      case 5:  return _moduleAuditLog(sl);
      case 6:  return _moduleSystemHealth(sl);
      case 7:  return _modulePlantMaster(sl);
      case 8:  return _moduleCustomLists(sl);
      case 9:  return _moduleExport(sl);
      case 10: return _moduleAlerts(sl);
      case 11: return _moduleBackupRestore(sl);
      case 12: return _moduleCompliance(sl);
      case 13: return _moduleKnowledgeBase(sl);
      case 14: return _moduleAiAudit(sl);
      case 15: return _moduleAiCorrections(sl);
      default: return _modulePlaceholder(m, sl);
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  PLACEHOLDER for modules pending in batch 2
  // ══════════════════════════════════════════════════════════════════
  Widget _modulePlaceholder(_AdminModule m, SL sl) => Center(
    child: Padding(padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: m.color.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: m.color.withOpacity(0.3), width: 2)),
            child: Icon(m.icon, color: m.color, size: 40)),
          const SizedBox(height: 18),
          Text(m.title, style: TextStyle(
              color: sl.text1, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(m.subtitle, style: TextStyle(color: sl.text3, fontSize: 12)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.amber.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.amber.withOpacity(0.4))),
            child: const Text('Coming in Batch 2',
                style: TextStyle(
                    color: AppColors.amber, fontSize: 11,
                    fontWeight: FontWeight.w700))),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              'Reply "next" in your conversation to request this module.',
              textAlign: TextAlign.center,
              style: TextStyle(color: sl.text4, fontSize: 11, height: 1.5)),
          ),
        ])));

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 0 — OVERVIEW (live KPIs)
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleOverview(SL sl) {
    final critical = _incidents.where((i) =>
        (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL').length;
    final open = _incidents.where((i) =>
        (i['status']?.toString().toUpperCase() ?? '') == 'OPEN').length;
    final closed = _incidents.where((i) =>
        (i['status']?.toString().toUpperCase() ?? '') == 'CLOSED').length;
    final activeUsers = _users.where((u) =>
        (u['status']?.toString().toLowerCase() ?? 'active') == 'active').length;
    final adminUsers = _users.where((u) =>
        u['isAdmin']?.toString().toLowerCase() == 'true').length;

    final today = _todayIso();
    final todayCount = _incidents.where((i) =>
        (i['date']?.toString() ?? '').startsWith(today)).length;

    return ListView(padding: const EdgeInsets.all(16), children: [
      // ── Greeting card ────────────────────────────────────────
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF1E40AF)]),
          borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          const Icon(Icons.security_rounded,
              color: Colors.white70, size: 32),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome, $_currentActor',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('SAIL Safety Lens — Enterprise Admin',
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
            ])),
        ])),
      const SizedBox(height: 16),

      // ── KPI grid ─────────────────────────────────────────────
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10, mainAxisSpacing: 10,
        childAspectRatio: 1.55,
        children: [
          _kpi('Total Incidents', '${_incidents.length}',
              Icons.list_alt_rounded, AppColors.accent, sl,
              sub: 'all-time'),
          _kpi('Critical', '$critical',
              Icons.error_rounded, AppColors.crit, sl,
              sub: 'severity level'),
          _kpi('Open', '$open',
              Icons.lock_open_rounded, AppColors.amber, sl,
              sub: 'pending action'),
          _kpi('Closed', '$closed',
              Icons.check_circle_rounded, AppColors.green, sl,
              sub: 'verified'),
          _kpi('Active Users', '$activeUsers',
              Icons.person_pin_rounded, const Color(0xFF3949AB), sl,
              sub: '$adminUsers admin'),
          _kpi('Today', '$todayCount',
              Icons.today_rounded, const Color(0xFF8E24AA), sl,
              sub: today),
        ]),

      const SizedBox(height: 16),

      // ── Quick actions ─────────────────────────────────────────
      _sectionHeader('Quick Actions', sl),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _quickAction('Analytics', Icons.insights_rounded,
            const Color(0xFF8E24AA), () => setState(() => _activeId = 1)),
        _quickAction('Bulk Ops', Icons.checklist_rounded,
            const Color(0xFFF57C00), () => setState(() => _activeId = 2)),
        _quickAction('Audit Log', Icons.history_rounded,
            const Color(0xFF6D4C41), () => setState(() => _activeId = 5)),
        _quickAction('Export', Icons.download_rounded,
            const Color(0xFF039BE5), () => setState(() => _activeId = 9)),
        _quickAction('Health', Icons.monitor_heart_rounded,
            const Color(0xFF43A047), () => setState(() => _activeId = 6)),
      ]),

      const SizedBox(height: 18),

      // ── Recent activity ────────────────────────────────────────
      _sectionHeader('Recent Admin Activity', sl,
        trailing: TextButton(
          onPressed: () => setState(() => _activeId = 5),
          style: TextButton.styleFrom(padding: const EdgeInsets.all(4)),
          child: const Text('View all →',
              style: TextStyle(color: AppColors.amber, fontSize: 11)),
        )),
      const SizedBox(height: 6),
      if (_auditLog.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: sl.card, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sl.border)),
          child: Center(child: Text('No audit events yet',
              style: TextStyle(color: sl.text4, fontSize: 11))))
      else
        ..._auditLog.take(5).map((e) => _auditLogRow(e, sl, compact: true)),
    ]);
  }

  Widget _kpi(String label, String value, IconData icon, Color color, SL sl,
      {String? sub}) =>
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6)),
            child: Icon(icon, color: color, size: 14)),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: TextStyle(
              color: sl.text3, fontSize: 10), overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(
            color: color, fontSize: 26, fontWeight: FontWeight.w800,
            height: 1.0)),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(color: sl.text4, fontSize: 9.5)),
        ],
      ]));

  Widget _quickAction(String label, IconData icon, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ])));

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 1 — ANALYTICS
  // ══════════════════════════════════════════════════════════════════
  /// Open the standalone live analytics dashboard (analytics_dashboard.html).
  /// On web it's deployed alongside the app, so we open it at a same-origin
  /// relative path in a new tab. On mobile/desktop there's no bundled HTML to
  /// serve, so we inform the admin it's a web-only tool.
  Future<void> _openLiveDashboard() async {
    if (!kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'The live dashboard opens in a browser. Use the web version of the app, '
            'or open analytics_dashboard.html directly.'),
        duration: Duration(seconds: 4),
      ));
      return;
    }
    try {
      final base = Uri.base; // current app URL
      // Resolve analytics_dashboard.html relative to the app's directory.
      final target = base.resolve('analytics_dashboard.html');
      await launchUrl(target, mode: LaunchMode.externalApplication,
          webOnlyWindowName: '_blank');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not open dashboard: $e'),
      ));
    }
  }

  Widget _moduleAnalytics(SL sl) {
    // Compute aggregates
    final byPlant   = <String, int>{};
    final bySev     = <String, int>{};
    final byMonth   = <String, int>{};
    final mttrSums  = <String, List<int>>{}; // plant → list of days
    int totalRisk = 0; int riskCount = 0;
    for (final inc in _incidents) {
      final plant = (inc['plant']?.toString() ?? '—').trim();
      final sev   = (inc['severity']?.toString().toUpperCase() ?? 'MEDIUM');
      byPlant[plant] = (byPlant[plant] ?? 0) + 1;
      bySev[sev]     = (bySev[sev]     ?? 0) + 1;

      final dateStr = inc['date']?.toString() ?? '';
      if (dateStr.length >= 7) {
        final m = dateStr.substring(0, 7);
        byMonth[m] = (byMonth[m] ?? 0) + 1;
      }

      // MTTR (only for closed)
      if ((inc['status']?.toString().toUpperCase() ?? '') == 'CLOSED') {
        final closedAt = inc['closedAt']?.toString();
        if (dateStr.isNotEmpty && closedAt != null && closedAt.isNotEmpty) {
          try {
            final t1 = DateTime.parse(dateStr);
            final t2 = DateTime.parse(closedAt);
            final days = t2.difference(t1).inHours / 24;
            if (days >= 0 && days < 365) {
              mttrSums.putIfAbsent(plant, () => []).add(days.round());
            }
          } catch (_) {}
        }
      }

      final rs = inc['riskScore'];
      final rsv = rs is int ? rs : int.tryParse('$rs') ?? -1;
      if (rsv >= 0) { totalRisk += rsv; riskCount += 1; }
    }

    final avgRisk = riskCount == 0 ? 0 : (totalRisk / riskCount).round();
    // ── WSA Pareto: map incident wsaCategory → custom list using fuzzy match ──
    final wsaCustomList = _customLists['wsa'] ?? [];
    final paretoMap = <String, int>{};
    for (final cat in wsaCustomList) {
      paretoMap[cat] = 0;
    }
    // Re-count incidents matching each custom list category
    for (final inc in _incidents) {
      final rawWsa = (inc['wsaCategory']?.toString() ?? '').trim();
      if (rawWsa.isEmpty || rawWsa == '—') continue;
      final matched = _matchWsaCategory(rawWsa, wsaCustomList);
      if (matched != null) {
        paretoMap[matched] = (paretoMap[matched] ?? 0) + 1;
      }
    }
    final paretoWsa = paretoMap.entries
        .where((e) => e.value > 0)
        .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
    final topPlants = byPlant.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
    final months = byMonth.keys.toList()..sort();
    final last6m = months.length > 6 ? months.sublist(months.length - 6) : months;

    return ListView(padding: const EdgeInsets.all(16), children: [
      // Top stats strip
      Row(children: [
        Expanded(child: _statCard('Total', '${_incidents.length}',
            const Color(0xFF8E24AA), sl)),
        const SizedBox(width: 8),
        Expanded(child: _statCard('Avg Risk', '$avgRisk',
            AppColors.amber, sl, suffix: '/100')),
        const SizedBox(width: 8),
        Expanded(child: _statCard('Plants', '${byPlant.length}',
            AppColors.accent, sl)),
      ]),
      const SizedBox(height: 12),

      // ── Live interactive dashboard launcher ────────────────────
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _openLiveDashboard,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Open Live Analytics Dashboard'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      const SizedBox(height: 16),

      // ── Severity distribution ─────────────────────────────────
      _sectionHeader('Severity Distribution', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: Column(children: [
          _sevBar('CRITICAL', bySev['CRITICAL'] ?? 0, _incidents.length,
              AppColors.crit, sl),
          const SizedBox(height: 8),
          _sevBar('HIGH', bySev['HIGH'] ?? 0, _incidents.length,
              AppColors.red, sl),
          const SizedBox(height: 8),
          _sevBar('MEDIUM', bySev['MEDIUM'] ?? 0, _incidents.length,
              AppColors.amber, sl),
          const SizedBox(height: 8),
          _sevBar('LOW', bySev['LOW'] ?? 0, _incidents.length,
              AppColors.green, sl),
        ])),
      const SizedBox(height: 16),

      // ── WSA Pareto (uses custom list categories) ────────────────
      _sectionHeader('WSA-13 Pareto — Root Causes', sl,
          trailing: Text('${paretoWsa.length} causes',
              style: TextStyle(color: sl.text4, fontSize: 10))),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: paretoWsa.isEmpty
          ? Text('No data',
              style: TextStyle(color: sl.text4, fontSize: 11))
          : Column(children: [
              for (var i = 0; i < math.min(13, paretoWsa.length); i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _paretoRow(
                    paretoWsa[i].key,
                    paretoWsa[i].value,
                    paretoWsa.first.value,
                    _paretoColors[i % _paretoColors.length],
                    sl),
              ],
            ])),
      const SizedBox(height: 16),

      // ── Plant-wise breakdown ──────────────────────────────────
      _sectionHeader('Plant-wise Incidents', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: topPlants.isEmpty
          ? Text('No data',
              style: TextStyle(color: sl.text4, fontSize: 11))
          : Column(children: [
              for (var i = 0; i < math.min(10, topPlants.length); i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _plantRow(topPlants[i].key, topPlants[i].value,
                    topPlants.first.value, sl, mttrSums[topPlants[i].key]),
              ],
            ])),
      const SizedBox(height: 16),

      // ── Monthly trend (last 6) ─────────────────────────────────
      _sectionHeader('6-Month Trend', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: last6m.isEmpty
          ? Text('No data',
              style: TextStyle(color: sl.text4, fontSize: 11))
          : _trendChart(last6m, byMonth, sl)),
      const SizedBox(height: 14),

      // ── Closure rate ──────────────────────────────────────────
      _sectionHeader('Closure Rate', sl),
      const SizedBox(height: 8),
      _closureRateCard(sl),
    ]);
  }

  static const _paretoColors = [
    Color(0xFFE53935), Color(0xFFF57C00), Color(0xFFD97706),
    Color(0xFF8E24AA), Color(0xFF3949AB), Color(0xFF00897B),
    Color(0xFF43A047), Color(0xFF6D4C41),
  ];

  Widget _statCard(String label, String value, Color color, SL sl,
      {String? suffix}) =>
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: sl.text3, fontSize: 10)),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value, style: TextStyle(
                color: color, fontSize: 22, fontWeight: FontWeight.w800)),
            if (suffix != null)
              Padding(padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Text(suffix, style: TextStyle(
                    color: color.withOpacity(0.7), fontSize: 10))),
          ]),
        ]));

  Widget _sevBar(String label, int count, int total, Color color, SL sl) {
    final pct = total == 0 ? 0.0 : count / total;
    return Row(children: [
      SizedBox(width: 70, child: Text(label, style: TextStyle(
          color: color, fontSize: 11, fontWeight: FontWeight.w700))),
      Expanded(child: Stack(children: [
        Container(height: 12, decoration: BoxDecoration(
          color: sl.border.withOpacity(0.3),
          borderRadius: BorderRadius.circular(6))),
        FractionallySizedBox(widthFactor: pct.clamp(0, 1),
          child: Container(height: 12, decoration: BoxDecoration(
            gradient: LinearGradient(colors: [color, color.withOpacity(0.7)]),
            borderRadius: BorderRadius.circular(6)))),
      ])),
      const SizedBox(width: 8),
      SizedBox(width: 64, child: Text(
        '$count (${(pct * 100).round()}%)',
        textAlign: TextAlign.right,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700))),
    ]);
  }

  /// Fuzzy-match an incident's wsaCategory against the custom WSA list.
  /// Returns the matching custom list entry, or null if no match.
  String? _matchWsaCategory(String rawWsa, List<String> customList) {
    final rawLower = rawWsa.toLowerCase().trim();
    // Strip leading number prefix from raw value (e.g. "5. Equipment failure" → "equipment failure")
    final rawStripped = rawLower.replaceFirst(RegExp(r'^\d+\.\s*'), '');

    for (final cat in customList) {
      final catLower = cat.toLowerCase();
      final catStripped = catLower.replaceFirst(RegExp(r'^\d+\.\s*'), '');

      // Exact match
      if (rawLower == catLower || rawStripped == catStripped) return cat;
      // Contains match (either direction)
      if (rawStripped.contains(catStripped) || catStripped.contains(rawStripped)) return cat;
    }

    // Keyword match: split raw value into keywords and find best match
    final rawKeywords = rawStripped.split(RegExp(r'[\s/()]+'))
        .where((w) => w.length > 2).toList();

    String? bestMatch;
    int bestScore = 0;
    for (final cat in customList) {
      final catStripped = cat.toLowerCase().replaceFirst(RegExp(r'^\d+\.\s*'), '');
      final catKeywords = catStripped.split(RegExp(r'[\s/()]+'))
          .where((w) => w.length > 2).toList();

      int score = 0;
      for (final kw in rawKeywords) {
        if (catStripped.contains(kw)) score += 2;
        for (final ck in catKeywords) {
          if (kw == ck) score += 3;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestMatch = cat;
      }
    }
    // Require at least one meaningful keyword match
    if (bestScore >= 2) return bestMatch;
    return null;
  }

  Widget _paretoRow(String name, int count, int max, Color color, SL sl) {
    final pct = max == 0 ? 0.0 : count / max;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(name, style: TextStyle(
            color: sl.text2, fontSize: 11, fontWeight: FontWeight.w600),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Text('$count', style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 3),
      Stack(children: [
        Container(height: 6, decoration: BoxDecoration(
          color: sl.border.withOpacity(0.3),
          borderRadius: BorderRadius.circular(3))),
        FractionallySizedBox(widthFactor: pct.clamp(0, 1),
          child: Container(height: 6, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(3)))),
      ]),
    ]);
  }

  Widget _plantRow(String name, int count, int max, SL sl, List<int>? mttrList) {
    final pct = max == 0 ? 0.0 : count / max;
    int? avgMttr;
    if (mttrList != null && mttrList.isNotEmpty) {
      avgMttr = (mttrList.reduce((a, b) => a + b) / mttrList.length).round();
    }
    return Row(children: [
      SizedBox(width: 100, child: Text(name, style: TextStyle(
          color: sl.text2, fontSize: 11, fontWeight: FontWeight.w600),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
      Expanded(child: Stack(children: [
        Container(height: 14, decoration: BoxDecoration(
          color: sl.border.withOpacity(0.3),
          borderRadius: BorderRadius.circular(7))),
        FractionallySizedBox(widthFactor: pct.clamp(0, 1),
          child: Container(height: 14, decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF3B82F6), Color(0xFF1E40AF)]),
            borderRadius: BorderRadius.circular(7)))),
      ])),
      const SizedBox(width: 6),
      SizedBox(width: 30, child: Text('$count',
          textAlign: TextAlign.right,
          style: TextStyle(color: sl.text1, fontSize: 11,
              fontWeight: FontWeight.w700))),
      const SizedBox(width: 6),
      SizedBox(width: 48, child: Text(
          avgMttr == null ? '—' : '${avgMttr}d',
          textAlign: TextAlign.right,
          style: TextStyle(color: sl.text4, fontSize: 10))),
    ]);
  }

  Widget _trendChart(List<String> months, Map<String, int> counts, SL sl) {
    final max = counts.values.fold<int>(0,
        (m, v) => v > m ? v : m);
    final scale = max == 0 ? 1 : max;
    return SizedBox(
      height: 130,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end,
        children: months.map((m) {
          final v = counts[m] ?? 0;
          final h = (v / scale) * 90;
          final label = m.length >= 7 ? m.substring(5) : m;
          return Expanded(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Column(mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('$v', style: TextStyle(
                    color: sl.text2, fontSize: 10,
                    fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Container(
                  height: h.clamp(2, 90).toDouble(),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Color(0xFFD97706), Color(0xFFB45309)]),
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4)))),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(
                    color: sl.text4, fontSize: 9)),
                Text(m.length >= 4 ? m.substring(0, 4) : '',
                    style: TextStyle(color: sl.text4, fontSize: 8)),
              ])));
        }).toList()));
  }

  Widget _closureRateCard(SL sl) {
    final byPlant = <String, Map<String, int>>{};
    for (final inc in _incidents) {
      final p = (inc['plant']?.toString() ?? '—').trim();
      final s = (inc['status']?.toString().toUpperCase() ?? '');
      byPlant.putIfAbsent(p, () => {'total': 0, 'closed': 0});
      byPlant[p]!['total'] = byPlant[p]!['total']! + 1;
      if (s == 'CLOSED') {
        byPlant[p]!['closed'] = byPlant[p]!['closed']! + 1;
      }
    }
    final rows = byPlant.entries.toList()
      ..sort((a, b) => b.value['total']!.compareTo(a.value['total']!));

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sl.border)),
      child: rows.isEmpty
        ? Text('No data', style: TextStyle(color: sl.text4, fontSize: 11))
        : Column(children: [
            for (var i = 0; i < math.min(8, rows.length); i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _closureRow(rows[i].key,
                  rows[i].value['closed']!,
                  rows[i].value['total']!,
                  sl),
            ],
          ]));
  }

  Widget _closureRow(String plant, int closed, int total, SL sl) {
    final pct = total == 0 ? 0.0 : closed / total;
    final color = pct >= 0.8 ? AppColors.green
                : pct >= 0.5 ? AppColors.amber
                : AppColors.red;
    return Row(children: [
      SizedBox(width: 100, child: Text(plant, style: TextStyle(
          color: sl.text2, fontSize: 11, fontWeight: FontWeight.w600),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
      Expanded(child: Stack(children: [
        Container(height: 12, decoration: BoxDecoration(
          color: sl.border.withOpacity(0.3),
          borderRadius: BorderRadius.circular(6))),
        FractionallySizedBox(widthFactor: pct.clamp(0, 1),
          child: Container(height: 12, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(6)))),
      ])),
      const SizedBox(width: 8),
      SizedBox(width: 72, child: Text(
        '$closed/$total · ${(pct*100).round()}%',
        textAlign: TextAlign.right,
        style: TextStyle(color: color, fontSize: 10,
            fontWeight: FontWeight.w700))),
    ]);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 2 — BULK OPERATIONS
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleBulkOps(SL sl) {
    final filtered = _bulkFilter == 'ALL' ? _incidents
        : _incidents.where((i) =>
            (i['status']?.toString().toUpperCase() == _bulkFilter) ||
            (i['severity']?.toString().toUpperCase() == _bulkFilter)).toList();

    return Column(children: [
      // Filter + selection bar
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: sl.bg2,
        child: Column(children: [
          Row(children: [
            _filterChip('ALL', 'All', sl),
            const SizedBox(width: 5),
            _filterChip('OPEN', 'Open', sl),
            const SizedBox(width: 5),
            _filterChip('CLOSED', 'Closed', sl),
            const SizedBox(width: 5),
            _filterChip('CRITICAL', 'Crit', sl),
            const SizedBox(width: 5),
            _filterChip('HIGH', 'High', sl),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Text('${_bulkSelected.length} selected · ${filtered.length} shown',
                style: TextStyle(color: sl.text2, fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(
              onPressed: filtered.isEmpty ? null : () {
                setState(() {
                  final allIds = filtered.map((e) =>
                      e['id']?.toString() ?? '').toSet();
                  final allSelected = allIds.every(_bulkSelected.contains);
                  if (allSelected) {
                    _bulkSelected.removeAll(allIds);
                  } else {
                    _bulkSelected.addAll(allIds);
                  }
                });
              },
              child: Text(
                filtered.every((e) =>
                  _bulkSelected.contains(e['id']?.toString() ?? ''))
                  ? 'Deselect all' : 'Select all',
                style: const TextStyle(color: AppColors.amber, fontSize: 11,
                    fontWeight: FontWeight.w700)),
            ),
          ]),
        ])),

      // Action bar (visible when items selected)
      if (_bulkSelected.isNotEmpty)
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.amber.withOpacity(0.08),
            border: Border(bottom: BorderSide(
                color: AppColors.amber.withOpacity(0.3)))),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _bulkBtn('Close', Icons.check_circle_outline,
                AppColors.green, _bulkClose),
            _bulkBtn('Delete', Icons.delete_outline_rounded,
                AppColors.red, _bulkDelete),
            _bulkBtn('Export CSV', Icons.download_rounded,
                AppColors.accent, _bulkExportCsv),
            _bulkBtn('Clear sel.', Icons.deselect_rounded,
                sl.text3, () => setState(() => _bulkSelected.clear())),
          ])),

      // Incident list
      Expanded(child: filtered.isEmpty
        ? Center(child: Text('No incidents match this filter',
            style: TextStyle(color: sl.text4, fontSize: 12)))
        : ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _bulkRow(filtered[i], sl))),
    ]);
  }

  Widget _bulkBtn(String label, IconData icon, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.4))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ])));

  Widget _bulkRow(Map<String, dynamic> inc, SL sl) {
    final id     = inc['id']?.toString() ?? '';
    final title  = inc['title']?.toString() ?? 'Untitled';
    final sev    = inc['severity']?.toString().toUpperCase() ?? '—';
    final status = inc['status']?.toString().toUpperCase() ?? '—';
    final plant  = inc['plant']?.toString() ?? '—';
    final dt     = (inc['date']?.toString() ?? '');
    final date   = dt.length > 10 ? dt.substring(0, 10) : dt;
    final selected = _bulkSelected.contains(id);

    final sc = _sevColor(sev);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() {
          if (selected) {
            _bulkSelected.remove(id);
          } else {
            _bulkSelected.add(id);
          }
        }),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected
              ? AppColors.amber.withOpacity(0.1) : sl.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.amber : sc.withOpacity(0.25),
              width: selected ? 1.5 : 0.8)),
          child: Row(children: [
            Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: selected ? AppColors.amber : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                    color: selected ? AppColors.amber : sl.text4,
                    width: 1.5)),
              child: selected
                ? const Icon(Icons.check_rounded,
                    color: Colors.white, size: 14)
                : null),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(
                    color: sl.text1, fontSize: 11.5,
                    fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Wrap(spacing: 4, runSpacing: 3, children: [
                  _miniPill(sev, sc),
                  _miniPill(status,
                      status == 'CLOSED' ? AppColors.green : AppColors.amber),
                  _miniPill(plant, sl.text3),
                ]),
                const SizedBox(height: 2),
                Text(date, style: TextStyle(color: sl.text4, fontSize: 9)),
              ])),
          ]),
        ),
      ),
    );
  }

  Future<void> _bulkClose() async {
    final sl = SL.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Close ${_bulkSelected.length} incidents',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 3,
          style: TextStyle(color: sl.text1, fontSize: 12),
          decoration: InputDecoration(
            hintText: 'Corrective action applied to all selected…',
            hintStyle: TextStyle(color: sl.text4, fontSize: 10),
            filled: true, fillColor: sl.bg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: sl.border)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Close All', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;

    final ids = _bulkSelected.toList();
    int success = 0;
    for (final id in ids) {
      final inc = _incidents.firstWhere(
          (i) => i['id']?.toString() == id, orElse: () => {});
      if (inc.isEmpty) continue;
      inc['status']           = 'CLOSED';
      inc['correctiveAction'] = ctrl.text.trim();
      inc['closedAt']         = DateTime.now().toIso8601String();
      inc['closedBy']         = _currentActor;
      try {
        await LocalDB.saveIncident(inc);
        SyncService.pushIncident(inc).catchError((_) => false);
        success++;
      } catch (_) {}
    }
    await AdminAudit.log(
      action: AdminAudit.actBulkClose,
      actor: _currentActor,
      meta: {'count': success, 'note': ctrl.text.trim()});
    setState(() => _bulkSelected.clear());
    await _loadAll();
    _toast('Closed $success / ${ids.length} incidents ✓', AppColors.green);
  }

  Future<void> _bulkDelete() async {
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          const Icon(Icons.delete_forever_rounded,
              color: AppColors.red, size: 20),
          const SizedBox(width: 8),
          Text('Delete ${_bulkSelected.length}?',
              style: TextStyle(color: sl.text1, fontSize: 14,
                  fontWeight: FontWeight.w800)),
        ]),
        content: Text(
          'Permanently delete ${_bulkSelected.length} incidents from local and Google Sheets. This cannot be undone.',
          style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete All', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;

    final ids = _bulkSelected.toList();
    int success = 0;
    for (final id in ids) {
      try {
        // Local delete records a tombstone so the row can't be resurrected
        // by a sheet re-fetch. Remote delete is awaited; if it fails the
        // tombstone keeps it hidden and it retries via the pending queue.
        await LocalDB.deleteIncident(id);
        await SyncService.deleteIncident(id).catchError((_) => false);
        success++;
      } catch (_) {}
    }
    await AdminAudit.log(
      action: AdminAudit.actBulkDelete,
      actor: _currentActor,
      meta: {'count': success});
    setState(() => _bulkSelected.clear());
    await _loadAll();
    _toast('Deleted $success / ${ids.length}', AppColors.red);
  }

  Future<void> _bulkExportCsv() async {
    final ids = _bulkSelected.toList();
    final selected = _incidents.where((i) =>
        ids.contains(i['id']?.toString() ?? '')).toList();
    final csv = _incidentsToCsv(selected);
    final fn = 'SafetyLens_Bulk_${_todayIso()}.csv';
    _downloadString(csv, fn);
    await AdminAudit.log(
      action: AdminAudit.actBulkExport,
      actor: _currentActor,
      meta: {'count': selected.length});
    _toast('Exported ${selected.length} incidents', AppColors.accent);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 5 — AUDIT LOG
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleAuditLog(SL sl) {
    final filtered = _auditLog.where((e) {
      if (_auditActionFilter.isNotEmpty &&
          e['action'] != _auditActionFilter) return false;
      if (_auditSearch.trim().isNotEmpty) {
        final q = _auditSearch.toLowerCase();
        final hay = [e['action'], e['actor'], e['target'], e['targetName']]
            .whereType<String>().join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    // Unique action types
    final actionTypes = <String>{};
    for (final e in _auditLog) {
      final a = e['action']?.toString();
      if (a != null && a.isNotEmpty) actionTypes.add(a);
    }
    final actionList = actionTypes.toList()..sort();

    return Column(children: [
      // Filter bar
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: sl.bg2,
        child: Column(children: [
          // Search + refresh
          Row(children: [
            Expanded(child: TextField(
              onChanged: (v) => setState(() => _auditSearch = v),
              style: TextStyle(color: sl.text1, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Search actions, actors, targets…',
                hintStyle: TextStyle(color: sl.text4, fontSize: 11),
                prefixIcon: Icon(Icons.search_rounded,
                    color: sl.text4, size: 16),
                filled: true, fillColor: sl.card, isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: sl.border))))),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: sl.text3, size: 18),
              onPressed: _refreshAudit),
            IconButton(
              tooltip: 'Export CSV',
              icon: const Icon(Icons.download_rounded,
                  color: AppColors.accent, size: 18),
              onPressed: _exportAuditCsv),
            IconButton(
              tooltip: 'Clear log',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.red, size: 18),
              onPressed: _confirmClearAudit),
          ]),
          const SizedBox(height: 6),
          // Action type filter chips
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _auditChip('', 'All (${_auditLog.length})', sl),
                for (final a in actionList) ...[
                  const SizedBox(width: 5),
                  _auditChip(a, AdminAudit.label(a), sl),
                ],
              ])),
        ])),

      // Results
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
        child: Row(children: [
          Text('${filtered.length} events',
              style: TextStyle(color: sl.text3, fontSize: 11)),
          const Spacer(),
        ])),
      Expanded(child: filtered.isEmpty
        ? Center(child: Text('No matching audit events',
            style: TextStyle(color: sl.text4, fontSize: 12)))
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _auditLogRow(filtered[i], sl))),
    ]);
  }

  Widget _auditChip(String value, String label, SL sl) {
    final active = _auditActionFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _auditActionFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppColors.amber.withOpacity(0.12) : sl.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? AppColors.amber : sl.border,
            width: active ? 1.4 : 0.8)),
        child: Text(label, style: TextStyle(
            color: active ? AppColors.amber : sl.text3,
            fontSize: 10, fontWeight: active ? FontWeight.w800 : FontWeight.w500))));
  }

  Widget _auditLogRow(Map<String, dynamic> e, SL sl, {bool compact = false}) {
    final action = e['action']?.toString() ?? '?';
    final actor  = e['actor']?.toString()  ?? '?';
    final target = e['target']?.toString();
    final tname  = e['targetName']?.toString();
    final ts     = e['timestamp']?.toString() ?? '';
    final color  = _actionColor(action);

    String tsHuman = ts;
    try {
      final d = DateTime.parse(ts);
      tsHuman = '${d.year}-${_pad(d.month)}-${_pad(d.day)} '
                '${_pad(d.hour)}:${_pad(d.minute)}:${_pad(d.second)}';
    } catch (_) {}

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3),
          top: BorderSide(color: sl.border, width: 0.5),
          right: BorderSide(color: sl.border, width: 0.5),
          bottom: BorderSide(color: sl.border, width: 0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4)),
            child: Text(AdminAudit.label(action),
                style: TextStyle(
                    color: color, fontSize: 10.5,
                    fontWeight: FontWeight.w800))),
          const SizedBox(width: 6),
          Text('by $actor',
              style: TextStyle(color: sl.text2, fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(tsHuman, style: TextStyle(
              color: sl.text4, fontSize: 9.5,
              fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
        if (!compact && (target != null || tname != null)) ...[
          const SizedBox(height: 4),
          Text(tname ?? target ?? '',
              style: TextStyle(color: sl.text3, fontSize: 10.5),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        if (!compact && e['meta'] is Map) ...[
          const SizedBox(height: 3),
          Text(_metaSummary(e['meta'] as Map),
              style: TextStyle(color: sl.text4, fontSize: 9.5,
                  fontStyle: FontStyle.italic),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ]));
  }

  String _metaSummary(Map m) {
    final parts = <String>[];
    m.forEach((k, v) {
      final vs = v.toString();
      if (vs.length > 50) {
        parts.add('$k: ${vs.substring(0, 50)}…');
      } else {
        parts.add('$k: $vs');
      }
    });
    return parts.join('  ·  ');
  }

  Color _actionColor(String action) {
    if (action.contains('delete') || action.contains('reset')) {
      return AppColors.red;
    }
    if (action.contains('login_fail')) return AppColors.red;
    if (action.contains('add') || action.contains('close') ||
        action.contains('login_success')) {
      return AppColors.green;
    }
    if (action.contains('export') || action.contains('backup')) {
      return AppColors.accent;
    }
    if (action.contains('role') || action.contains('status') ||
        action.contains('password') || action.contains('settings')) {
      return AppColors.amber;
    }
    return const Color(0xFF6D4C41);
  }

  Future<void> _exportAuditCsv() async {
    final csv = await AdminAudit.exportCsv();
    _downloadString(csv, 'SafetyLens_AuditLog_${_todayIso()}.csv');
    _toast('Audit log exported', AppColors.accent);
  }

  Future<void> _confirmClearAudit() async {
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Clear Audit Log?',
            style: TextStyle(color: AppColors.red, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: Text(
          'Permanently erase all ${_auditLog.length} audit events. '
          'This itself will not be logged.',
          style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Clear', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    await AdminAudit.clear();
    await _refreshAudit();
    _toast('Audit log cleared', AppColors.red);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 6 — SYSTEM HEALTH
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleSystemHealth(SL sl) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      // Apps Script status
      _sectionHeader('Apps Script Backend', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: Column(children: [
          _healthRow('Endpoint',
              'script.google.com/...exec', AppColors.green, sl),
          const SizedBox(height: 8),
          _healthRow('Version',
              _scriptVersion ?? 'tap "Check now"',
              _scriptVersion == null ? sl.text4
                : (_scriptVersion == 'v10' ? AppColors.green : AppColors.amber),
              sl),
          if (_scriptLastChecked != null) ...[
            const SizedBox(height: 8),
            _healthRow('Last checked', _scriptLastChecked!, sl.text3, sl),
          ],
          const SizedBox(height: 12),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _checkingHealth ? null : _checkScriptHealth,
              icon: _checkingHealth
                ? const SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('Check now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))))),
        ])),

      const SizedBox(height: 16),
      _sectionHeader('Local Storage', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: Column(children: [
          _healthRow('Incidents (local)', '${_incidents.length}',
              AppColors.accent, sl),
          const SizedBox(height: 6),
          _healthRow('KB documents', '${_kbDocs.length}',
              const Color(0xFF00897B), sl),
          const SizedBox(height: 6),
          _healthRow('Cached users', '${_users.length}',
              const Color(0xFF3949AB), sl),
          const SizedBox(height: 6),
          _healthRow('Audit events', '${_auditLog.length}',
              const Color(0xFF6D4C41), sl),
        ])),

      const SizedBox(height: 16),
      _sectionHeader('Data Integrity', sl),
      const SizedBox(height: 8),
      _integrityCard(sl),

      const SizedBox(height: 16),
      _sectionHeader('Groq AI (Text Correction)', sl),
      const SizedBox(height: 8),
      _groqConfigCard(sl),

      const SizedBox(height: 16),
      _sectionHeader('Gemini Vision (Hazard Analysis)', sl),
      const SizedBox(height: 8),
      _geminiVisionConfigCard(sl),

      const SizedBox(height: 16),
      _sectionHeader('Integrations', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: Column(children: [
          _intRow('Google Sheets backend', 'connected via Apps Script',
              AppColors.green, Icons.cloud_done_rounded, sl),
          const SizedBox(height: 8),
          _intRow('Cloudinary image CDN', 'dzt1vxsdg',
              AppColors.green, Icons.image_rounded, sl),
          const SizedBox(height: 8),
          _intRow('Gemini Vision (Hazard AI)', _geminiVisionConfigured ? 'active (direct API)' : 'not configured',
              _geminiVisionConfigured ? AppColors.green : AppColors.amber, Icons.remove_red_eye_rounded, sl),
          const SizedBox(height: 8),
          _intRow('Groq AI (Near Miss correction)', _groqConfigured ? 'active' : 'not configured',
              _groqConfigured ? AppColors.green : AppColors.red, Icons.auto_fix_high_rounded, sl),
          const SizedBox(height: 8),
          _intRow('Apps Script (Fallback AI)', 'connected',
              AppColors.green, Icons.cloud_done_rounded, sl),
          const SizedBox(height: 8),
          _intRow('Google Drive (PDF storage)', 'SAIL Safety Lens Reports/',
              AppColors.green, Icons.folder_rounded, sl),
        ])),
    ]);
  }

  bool _groqConfigured = false;
  final _groqKeyCtrl = TextEditingController();
  String _groqSelectedModel = GroqService.defaultModel;
  String _groqVisionModel = 'auto'; // vision model used for AI hazard scans

  bool _geminiVisionConfigured = false;
  final _geminiVisionKeyCtrl = TextEditingController();
  String _geminiVisionSelectedModel = GeminiDirectVision.defaultModel;

  Future<void> _loadGroqConfig() async {
    final key = await GroqService.getApiKey();
    final model = await GroqService.getModel();
    final visionModel = await GeminiVision.getGroqVisionModel();
    final gemKey = await GeminiDirectVision.getApiKey();
    final gemModel = await GeminiDirectVision.getModel();
    if (mounted) {
      setState(() {
        _groqConfigured = key.isNotEmpty && key.startsWith('gsk_');
        _groqKeyCtrl.text = key;
        _groqSelectedModel = model;
        _groqVisionModel = visionModel;
        _geminiVisionConfigured = gemKey.isNotEmpty && gemKey.length > 20;
        _geminiVisionKeyCtrl.text = gemKey;
        _geminiVisionSelectedModel = gemModel;
      });
    }
  }

  Widget _groqConfigCard(SL sl) {
    // Load config on first build
    if (_groqKeyCtrl.text.isEmpty && !_groqConfigured) {
      _loadGroqConfig();
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _groqConfigured ? AppColors.green.withOpacity(0.5) : sl.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_groqConfigured ? Icons.check_circle : Icons.warning_amber_rounded,
            color: _groqConfigured ? AppColors.green : AppColors.amber, size: 16),
          const SizedBox(width: 8),
          Text(_groqConfigured ? 'Groq AI Connected' : 'Groq API Key Required',
            style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text('Free AI for near-miss text correction. Get key at console.groq.com',
          style: TextStyle(color: sl.text4, fontSize: 10)),
        const SizedBox(height: 12),
        _apiKeyInputField(_groqKeyCtrl, 'Groq API Key (starts with gsk_)', sl),
        const SizedBox(height: 10),
        // Model selector
        DropdownButtonFormField<String>(
          value: _groqSelectedModel,
          items: GroqService.availableModels.map((m) => DropdownMenuItem(
            value: m['id'], child: Text(m['name']!, style: TextStyle(fontSize: 11, color: sl.text1)),
          )).toList(),
          onChanged: (v) { if (v != null) setState(() => _groqSelectedModel = v); },
          dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
          style: TextStyle(color: sl.text1, fontSize: 11),
          decoration: InputDecoration(
            labelText: 'Model',
            labelStyle: TextStyle(color: sl.text3, fontSize: 10),
            filled: true,
            fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: sl.border)),
          ),
        ),
        const SizedBox(height: 10),
        // Vision model — AI hazard image scans run on OpenRouter.
        DropdownButtonFormField<String>(
          value: _groqVisionModel,
          isExpanded: true,
          items: GeminiVision.groqVisionModels.map((m) => DropdownMenuItem(
            value: m['id'],
            child: Text(m['name']!, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: sl.text1)),
          )).toList(),
          onChanged: (v) { if (v != null) setState(() => _groqVisionModel = v); },
          dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
          style: TextStyle(color: sl.text1, fontSize: 11),
          decoration: InputDecoration(
            labelText: 'Vision Model — image scans (OpenRouter)',
            labelStyle: TextStyle(color: sl.text3, fontSize: 10),
            filled: true,
            fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: sl.border)),
          ),
        ),
        const SizedBox(height: 6),
        Text('Image hazard scans run on OpenRouter. “Auto” tries the fast '
             'Nano 12B VL first, then 30B Omni. Free models can queue when '
             'busy; use a paid model for consistent speed. '
             '(Groq key above is for near-miss text, not image scans.)',
          style: TextStyle(color: sl.text4, fontSize: 9)),
        const SizedBox(height: 12),
        // ★ v26: Key is now auto-saved from the dialog. This button only updates model selection.
        if (_groqConfigured)
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await GroqService.setModel(_groqSelectedModel);
                await GeminiVision.setGroqVisionModel(_groqVisionModel);
                _toast('✓ Groq models updated', AppColors.green);
              },
              icon: Icon(Icons.tune, size: 14, color: sl.text2),
              label: Text('Update Model Selection', style: TextStyle(color: sl.text2, fontSize: 11)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: sl.border),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
          ),
      ]),
    );
  }

  Widget _geminiVisionConfigCard(SL sl) {
    if (_geminiVisionKeyCtrl.text.isEmpty && !_geminiVisionConfigured) {
      _loadGroqConfig(); // loads both Groq and Gemini config
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _geminiVisionConfigured ? AppColors.green.withOpacity(0.5) : sl.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_geminiVisionConfigured ? Icons.check_circle : Icons.warning_amber_rounded,
            color: _geminiVisionConfigured ? AppColors.green : AppColors.amber, size: 16),
          const SizedBox(width: 8),
          Text(_geminiVisionConfigured ? 'Gemini Vision Connected' : 'Gemini API Key Required',
            style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text('Free AI for image hazard detection. Get key at aistudio.google.com/apikey',
          style: TextStyle(color: sl.text4, fontSize: 10)),
        const SizedBox(height: 12),
        _apiKeyInputField(_geminiVisionKeyCtrl, 'Gemini API Key (from AI Studio)', sl, isGemini: true),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _geminiVisionSelectedModel,
          items: GeminiDirectVision.availableModels.map((m) => DropdownMenuItem(
            value: m['id'], child: Text(m['name']!, style: TextStyle(fontSize: 11, color: sl.text1)),
          )).toList(),
          onChanged: (v) { if (v != null) setState(() => _geminiVisionSelectedModel = v); },
          dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
          style: TextStyle(color: sl.text1, fontSize: 11),
          decoration: InputDecoration(
            labelText: 'Vision Model',
            labelStyle: TextStyle(color: sl.text3, fontSize: 10),
            filled: true,
            fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: sl.border)),
          ),
        ),
        const SizedBox(height: 12),
        // ★ v26: Key is now auto-saved from the dialog. This button only updates model selection.
        if (_geminiVisionConfigured)
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await GeminiDirectVision.setModel(_geminiVisionSelectedModel);
                _toast('✓ Gemini model updated to $_geminiVisionSelectedModel', AppColors.green);
              },
              icon: Icon(Icons.tune, size: 14, color: sl.text2),
              label: Text('Update Model Selection', style: TextStyle(color: sl.text2, fontSize: 11)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: sl.border),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
          ),
      ]),
    );
  }

  Widget _healthRow(String label, String value, Color color, SL sl) =>
    Row(children: [
      Expanded(child: Text(label, style: TextStyle(
          color: sl.text3, fontSize: 11))),
      Text(value, style: TextStyle(
          color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
    ]);

  Widget _intRow(String name, String detail, Color color,
      IconData icon, SL sl) =>
    Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6)),
        child: Icon(icon, color: color, size: 14)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: TextStyle(
              color: sl.text1, fontSize: 11, fontWeight: FontWeight.w700)),
          Text(detail, style: TextStyle(color: sl.text4, fontSize: 10)),
        ])),
      Container(width: 8, height: 8, decoration: BoxDecoration(
          color: color, shape: BoxShape.circle)),
    ]);

  Widget _integrityCard(SL sl) {
    int orphaned = 0;
    int missingId = 0;
    int missingDate = 0;
    int missingPlant = 0;
    for (final inc in _incidents) {
      if (inc['id'] == null || inc['id'].toString().isEmpty) missingId++;
      if (inc['date'] == null || inc['date'].toString().isEmpty) missingDate++;
      if (inc['plant'] == null || inc['plant'].toString().isEmpty) missingPlant++;
      if (inc['reportedBy'] == null) orphaned++;
    }
    final clean = missingId == 0 && missingDate == 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: clean
          ? AppColors.green.withOpacity(0.06)
          : AppColors.amber.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: clean
          ? AppColors.green.withOpacity(0.3)
          : AppColors.amber.withOpacity(0.3))),
      child: Column(children: [
        Row(children: [
          Icon(clean ? Icons.verified_rounded : Icons.warning_amber_rounded,
              color: clean ? AppColors.green : AppColors.amber, size: 18),
          const SizedBox(width: 8),
          Text(clean ? 'All checks pass' : 'Issues found',
              style: TextStyle(color: sl.text1, fontSize: 12,
                  fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        _intCheck('Missing IDs', missingId, sl),
        _intCheck('Missing dates', missingDate, sl),
        _intCheck('Missing plant', missingPlant, sl),
        _intCheck('No reporter', orphaned, sl),
      ]));
  }

  Widget _intCheck(String label, int count, SL sl) {
    final ok = count == 0;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(ok ? Icons.check_circle_outline : Icons.error_outline_rounded,
            color: ok ? AppColors.green : AppColors.red, size: 12),
        const SizedBox(width: 6),
        Expanded(child: Text(label,
            style: TextStyle(color: sl.text3, fontSize: 10.5))),
        Text('$count',
            style: TextStyle(
                color: ok ? AppColors.green : AppColors.red,
                fontSize: 11, fontWeight: FontWeight.w800)),
      ]));
  }

  Future<void> _checkScriptHealth() async {
    setState(() => _checkingHealth = true);
    try {
      const url = 'https://script.google.com/macros/s/'
          'AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec';
      final resp = await http.get(Uri.parse('$url?action=health'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        try {
          final data = jsonDecode(resp.body);
          if (data is Map) {
            _scriptVersion = data['version']?.toString() ?? 'unknown';
          }
        } catch (_) {
          _scriptVersion = 'unparseable';
        }
      } else {
        _scriptVersion = 'HTTP ${resp.statusCode}';
      }
    } catch (e) {
      _scriptVersion = 'error: $e';
    }
    final n = DateTime.now();
    _scriptLastChecked = '${n.year}-${_pad(n.month)}-${_pad(n.day)} '
                         '${_pad(n.hour)}:${_pad(n.minute)}';
    await AdminAudit.log(
      action: AdminAudit.actSysCheck,
      actor: _currentActor,
      meta: {'version': _scriptVersion});
    if (mounted) setState(() => _checkingHealth = false);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 9 — EXPORT CENTRE
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleExport(SL sl) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      _sectionHeader('Quick Exports', sl),
      const SizedBox(height: 4),
      Text('All exports are CSV files downloaded to your device.',
          style: TextStyle(color: sl.text4, fontSize: 11)),
      const SizedBox(height: 14),

      _exportCard(
        'Incidents — All',
        '${_incidents.length} rows · all fields',
        Icons.list_alt_rounded, AppColors.accent, sl,
        () {
          final csv = _incidentsToCsv(_incidents);
          _downloadString(csv, 'SafetyLens_Incidents_${_todayIso()}.csv');
          _logExport('incidents_all', _incidents.length);
        }),
      const SizedBox(height: 10),

      _exportCard(
        'Incidents — Open only',
        '${_incidents.where((i) => (i['status']?.toString().toUpperCase() ?? '') == 'OPEN').length} rows',
        Icons.lock_open_rounded, AppColors.amber, sl,
        () {
          final list = _incidents.where((i) =>
              (i['status']?.toString().toUpperCase() ?? '') == 'OPEN').toList();
          final csv = _incidentsToCsv(list);
          _downloadString(csv, 'SafetyLens_OpenIncidents_${_todayIso()}.csv');
          _logExport('incidents_open', list.length);
        }),
      const SizedBox(height: 10),

      _exportCard(
        'Incidents — Critical only',
        '${_incidents.where((i) => (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL').length} rows',
        Icons.error_rounded, AppColors.crit, sl,
        () {
          final list = _incidents.where((i) =>
              (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL').toList();
          final csv = _incidentsToCsv(list);
          _downloadString(csv, 'SafetyLens_Critical_${_todayIso()}.csv');
          _logExport('incidents_critical', list.length);
        }),
      const SizedBox(height: 10),

      _exportCard(
        'Users',
        '${_users.length} rows · roles & plants',
        Icons.people_rounded, const Color(0xFF3949AB), sl,
        () {
          final csv = _usersToCsv(_users);
          _downloadString(csv, 'SafetyLens_Users_${_todayIso()}.csv');
          _logExport('users', _users.length);
        }),
      const SizedBox(height: 10),

      _exportCard(
        'Knowledge Base',
        '${_kbDocs.length} entries · regulatory + uploads',
        Icons.menu_book_rounded, const Color(0xFF0F6E56), sl,
        () {
          final csv = _kbToCsv(_kbDocs);
          _downloadString(csv, 'SafetyLens_KB_${_todayIso()}.csv');
          _logExport('kb', _kbDocs.length);
        }),
      const SizedBox(height: 10),

      _exportCard(
        'Audit Log',
        '${_auditLog.length} events · all admin actions',
        Icons.history_rounded, const Color(0xFF6D4C41), sl,
        _exportAuditCsv),
      const SizedBox(height: 18),

      // JSON full backup teaser
      _sectionHeader('Full Backup', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.cloud_download_rounded,
                  color: Color(0xFF5E35B1), size: 18),
              const SizedBox(width: 8),
              Text('JSON Backup — Coming in Batch 2',
                  style: TextStyle(color: sl.text2, fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 6),
            Text(
              'Full system backup (incidents + users + KB + audit + settings + custom lists) in a single restorable JSON file will be added with Module 11.',
              style: TextStyle(color: sl.text4, fontSize: 10.5, height: 1.5)),
          ])),
    ]);
  }

  Widget _exportCard(String title, String subtitle, IconData icon,
      Color color, SL sl, VoidCallback onTap) =>
    Material(color: Colors.transparent, child: InkWell(
      onTap: onTap, borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(
                  color: sl.text1, fontSize: 12.5, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: sl.text3, fontSize: 10.5)),
            ])),
          Icon(Icons.download_rounded, color: color, size: 20),
        ]),
      )));

  Future<void> _logExport(String kind, int count) async {
    await AdminAudit.log(
      action: AdminAudit.actExport,
      actor: _currentActor,
      meta: {'kind': kind, 'count': count});
    _toast('Exported $count rows', AppColors.accent);
  }

  // ══════════════════════════════════════════════════════════════════
  //  COMMON HELPERS
  // ══════════════════════════════════════════════════════════════════
  Widget _sectionHeader(String title, SL sl, {Widget? trailing}) =>
    Row(children: [
      Container(width: 3, height: 14, color: AppColors.amber,
          margin: const EdgeInsets.only(right: 8)),
      Text(title, style: TextStyle(
          color: sl.text1, fontSize: 13, fontWeight: FontWeight.w800)),
      if (trailing != null) ...[
        const Spacer(),
        trailing,
      ],
    ]);

  Widget _filterChip(String value, String label, SL sl) {
    final active = _bulkFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _bulkFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppColors.amber.withOpacity(0.12) : sl.card,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
              color: active ? AppColors.amber : sl.border,
              width: active ? 1.5 : 0.8)),
        child: Text(label, style: TextStyle(
            color: active ? AppColors.amber : sl.text2,
            fontSize: 11, fontWeight: active ? FontWeight.w800 : FontWeight.w500))));
  }

  Widget _miniPill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(3)),
    child: Text(text, style: TextStyle(
        color: color, fontSize: 8.5, fontWeight: FontWeight.w800)));

  Color _sevColor(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.amber;
      default:         return AppColors.green;
    }
  }

  String _todayIso() {
    final n = DateTime.now();
    return '${n.year}-${_pad(n.month)}-${_pad(n.day)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  void _toast(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12)));
  }

  // ── CSV builders ────────────────────────────────────────────────
  String _csvEsc(dynamic v) {
    if (v == null) return '';
    var s = v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      s = '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  String _incidentsToCsv(List<Map<String, dynamic>> rows) {
    final cols = ['id','date','title','plant','dept','location','severity',
        'wsaCategory','obsType','type','status','people','riskScore',
        'confidence','reportedBy','reportedByPno','correctiveAction',
        'closedBy','closedAt','summary','desc'];
    final buf = StringBuffer()..writeln(cols.join(','));
    for (final r in rows) {
      buf.writeln(cols.map((c) => _csvEsc(r[c])).join(','));
    }
    return buf.toString();
  }

  String _usersToCsv(List<Map<String, dynamic>> rows) {
    final cols = ['username','name','designation','plant','department',
        'pno','mobile','email','isAdmin','status','createdAt','lastLogin'];
    final buf = StringBuffer()..writeln(cols.join(','));
    for (final r in rows) {
      buf.writeln(cols.map((c) => _csvEsc(r[c])).join(','));
    }
    return buf.toString();
  }

  String _kbToCsv(List<Map<String, dynamic>> rows) {
    final cols = ['id','title','source','content','uploadedAt','uploadedBy'];
    final buf = StringBuffer()..writeln(cols.join(','));
    for (final r in rows) {
      buf.writeln(cols.map((c) => _csvEsc(r[c])).join(','));
    }
    return buf.toString();
  }

  // ── Web download (Clipboard fallback if not web) ────────────────
  void _downloadString(String content, String filename) {
    try {
      final blob = html.Blob([content], 'text/csv;charset=utf-8');
      final url  = html.Url.createObjectUrlFromBlob(blob);
      // ignore: unused_local_variable
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();
      html.Url.revokeObjectUrl(url);
      return;
    } catch (_) {}
    // Fallback: copy to clipboard (mobile builds, or web blob failure)
    Clipboard.setData(ClipboardData(text: content));
    _toast('Download not supported here — copied to clipboard instead',
        AppColors.amber);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 3 — WORKFLOW ENGINE
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleWorkflow(SL sl) {
    final filtered = _workflowStatusFilter == 'ALL'
        ? _incidents
        : _incidents.where((i) =>
            (i['status']?.toString().toUpperCase() ?? 'OPEN')
                == _workflowStatusFilter).toList();
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: sl.bg2,
        child: Row(children: [
          for (final s in const [
            ['ALL','All'], ['OPEN','Open'], ['INVESTIGATING','Investig.'],
            ['ACTION TAKEN','Action'], ['VERIFIED','Verified'], ['CLOSED','Closed'],
          ]) ...[
            _wfChip(s[0], s[1], sl), const SizedBox(width: 5),
          ],
        ])),
      Expanded(child: filtered.isEmpty
        ? Center(child: Text('No incidents in this stage',
            style: TextStyle(color: sl.text4, fontSize: 12)))
        : ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _wfCard(filtered[i], sl))),
    ]);
  }

  Widget _wfChip(String value, String label, SL sl) {
    final active = _workflowStatusFilter == value;
    return GestureDetector(
      onTap: () => setState(() {
        _workflowStatusFilter = value;
        _workflowSelectedId = null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00897B).withOpacity(0.14) : sl.card,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
              color: active ? const Color(0xFF00897B) : sl.border,
              width: active ? 1.5 : 0.8)),
        child: Text(label, style: TextStyle(
            color: active ? const Color(0xFF00897B) : sl.text2,
            fontSize: 10.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w500))));
  }

  Widget _wfCard(Map<String, dynamic> inc, SL sl) {
    final id     = inc['id']?.toString() ?? '';
    final title  = inc['title']?.toString() ?? 'Untitled';
    final sev    = inc['severity']?.toString().toUpperCase() ?? '—';
    final status = inc['status']?.toString().toUpperCase() ?? 'OPEN';
    final plant  = inc['plant']?.toString() ?? '—';
    final dt     = inc['date']?.toString() ?? '';
    final assignee = inc['assignedTo']?.toString();
    final expanded = _workflowSelectedId == id;
    final sc = _sevColor(sev);

    // SLA — days since date for non-closed
    int days = 0;
    Color slaColor = AppColors.green;
    String slaText = '';
    if (status != 'CLOSED' && dt.isNotEmpty) {
      try {
        days = DateTime.now().difference(DateTime.parse(dt)).inDays;
        if (days >= 14) { slaColor = AppColors.red;   slaText = '$days d ⚠'; }
        else if (days >= 7)  { slaColor = AppColors.amber; slaText = '$days d'; }
        else                 { slaColor = AppColors.green; slaText = '$days d'; }
      } catch (_) {}
    } else if (status == 'CLOSED') {
      slaText = 'closed'; slaColor = AppColors.green;
    }

    final comments = (inc['comments'] is List)
        ? List<Map>.from(inc['comments']) : <Map>[];

    return Container(
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sc.withOpacity(0.3))),
      child: Column(children: [
        InkWell(
          onTap: () => setState(() {
            _workflowSelectedId = expanded ? null : id;
          }),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(
                      color: sl.text1, fontSize: 12,
                      fontWeight: FontWeight.w800),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 3, children: [
                    _miniPill(sev, sc),
                    _miniPill(status, _statusColor(status)),
                    _miniPill(plant, sl.text3),
                    if (slaText.isNotEmpty) _miniPill(slaText, slaColor),
                    if (assignee != null && assignee.isNotEmpty)
                      _miniPill('@$assignee', const Color(0xFF3949AB)),
                    if (comments.isNotEmpty)
                      _miniPill('${comments.length} 💬', sl.text3),
                  ]),
                ])),
              Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: sl.text3, size: 18),
            ]),
          )),
        if (expanded) ...[
          Container(height: 0.5, color: sl.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status pipeline
                Text('Status Pipeline',
                    style: TextStyle(color: sl.text3, fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Wrap(spacing: 5, runSpacing: 5, children: [
                  for (final st in const ['OPEN','INVESTIGATING','ACTION TAKEN','VERIFIED','CLOSED'])
                    _wfStatusBtn(st, status, () => _wfChangeStatus(inc, st)),
                ]),
                const SizedBox(height: 12),
                // Assignee
                Row(children: [
                  Text('Investigator',
                      style: TextStyle(color: sl.text3, fontSize: 10,
                          fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _wfAssign(inc),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 0),
                        minimumSize: const Size(0, 26)),
                    icon: const Icon(Icons.person_add_rounded,
                        size: 14, color: Color(0xFF3949AB)),
                    label: Text(
                      assignee == null || assignee.isEmpty
                        ? 'Assign' : 'Reassign',
                      style: const TextStyle(
                          color: Color(0xFF3949AB), fontSize: 10.5,
                          fontWeight: FontWeight.w700))),
                ]),
                if (assignee != null && assignee.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 2),
                    child: Text(assignee,
                        style: TextStyle(color: sl.text2, fontSize: 11)))
                else
                  Text('— unassigned —',
                      style: TextStyle(color: sl.text4, fontSize: 10.5,
                          fontStyle: FontStyle.italic)),
                const SizedBox(height: 12),
                // Comments
                Row(children: [
                  Text('Discussion (${comments.length})',
                      style: TextStyle(color: sl.text3, fontSize: 10,
                          fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _wfAddComment(inc),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 0),
                        minimumSize: const Size(0, 26)),
                    icon: const Icon(Icons.add_comment_outlined,
                        size: 14, color: Color(0xFF00897B)),
                    label: const Text('Add note',
                      style: TextStyle(
                          color: Color(0xFF00897B), fontSize: 10.5,
                          fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 4),
                if (comments.isEmpty)
                  Text('— no notes yet —',
                      style: TextStyle(color: sl.text4, fontSize: 10.5,
                          fontStyle: FontStyle.italic))
                else
                  ...comments.reversed.map((c) => _wfCommentRow(
                      Map<String, dynamic>.from(c), sl)),
              ]),
          ),
        ],
      ]));
  }

  Widget _wfStatusBtn(String st, String current, VoidCallback onTap) {
    final active = current == st;
    final color = _statusColor(st);
    return GestureDetector(
      onTap: active ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color : color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color, width: active ? 1.5 : 0.8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (active) ...[
            const Icon(Icons.check_rounded, size: 11, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(st, style: TextStyle(
              color: active ? Colors.white : color,
              fontSize: 9.5, fontWeight: FontWeight.w700)),
        ])));
  }

  Widget _wfCommentRow(Map<String, dynamic> c, SL sl) {
    final by = c['by']?.toString() ?? '?';
    final at = c['at']?.toString() ?? '';
    final text = c['text']?.toString() ?? '';
    String ago = at;
    try {
      final d = DateTime.parse(at);
      ago = '${d.year}-${_pad(d.month)}-${_pad(d.day)} ${_pad(d.hour)}:${_pad(d.minute)}';
    } catch (_) {}
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: sl.bg, borderRadius: BorderRadius.circular(6),
        border: Border.all(color: sl.border, width: 0.5)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(by, style: TextStyle(
              color: sl.text2, fontSize: 10.5,
              fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(ago, style: TextStyle(color: sl.text4, fontSize: 9)),
        ]),
        const SizedBox(height: 3),
        Text(text, style: TextStyle(color: sl.text1, fontSize: 11,
            height: 1.4)),
      ]));
  }

  Color _statusColor(String s) {
    switch (s.toUpperCase()) {
      case 'OPEN'         : return AppColors.amber;
      case 'INVESTIGATING': return const Color(0xFF8E24AA);
      case 'ACTION TAKEN' : return const Color(0xFF1E88E5);
      case 'VERIFIED'     : return const Color(0xFF00897B);
      case 'CLOSED'       : return AppColors.green;
      default             : return AppColors.amber;
    }
  }

  Future<void> _wfChangeStatus(Map<String, dynamic> inc, String newStatus) async {
    final old = inc['status']?.toString();
    inc['status'] = newStatus;
    if (newStatus == 'CLOSED') {
      inc['closedAt'] = DateTime.now().toIso8601String();
      inc['closedBy'] = _currentActor;
    }
    try {
      await LocalDB.saveIncident(inc);
      SyncService.pushIncident(inc).catchError((_) => false);
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actIncStatus,
      actor: _currentActor,
      target: inc['id']?.toString(),
      targetName: inc['title']?.toString(),
      meta: {'from': old, 'to': newStatus});
    await _loadAll();
    _toast('Status → $newStatus', _statusColor(newStatus));
  }

  Future<void> _wfAssign(Map<String, dynamic> inc) async {
    final sl = SL.of(context);
    String? picked = inc['assignedTo']?.toString();
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Assign investigator',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: SizedBox(width: 320,
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  color: sl.bg, borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sl.border)),
                child: ListView(shrinkWrap: true, children: [
                  _wfPickRow('— Unassigned —', null, picked,
                      (v) => setSt(() => picked = v), sl),
                  for (final u in _users)
                    _wfPickRow(
                      '${u['name'] ?? u['username']} (@${u['username']})',
                      u['username']?.toString(),
                      picked,
                      (v) => setSt(() => picked = v), sl),
                ])),
            ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3949AB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Assign', style: TextStyle(color: Colors.white))),
        ]),
      ));
    if (ok != true) return;

    if (picked == null || picked!.isEmpty) {
      inc.remove('assignedTo');
      inc.remove('assignedAt');
    } else {
      inc['assignedTo'] = picked;
      inc['assignedAt'] = DateTime.now().toIso8601String();
    }
    try {
      await LocalDB.saveIncident(inc);
      SyncService.pushIncident(inc).catchError((_) => false);
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actIncAssign,
      actor: _currentActor,
      target: inc['id']?.toString(),
      targetName: inc['title']?.toString(),
      meta: {'assignedTo': picked ?? '(unassigned)'});
    await _loadAll();
    _toast(picked == null ? 'Unassigned' : 'Assigned to $picked',
        const Color(0xFF3949AB));
  }

  Widget _wfPickRow(String label, String? value, String? current,
      ValueChanged<String?> onPick, SL sl) {
    final selected = current == value;
    return Material(color: Colors.transparent, child: InkWell(
      onTap: () => onPick(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
            ? const Color(0xFF3949AB).withOpacity(0.1)
            : Colors.transparent),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
              color: selected ? const Color(0xFF3949AB) : sl.text4, size: 14),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(
              color: selected ? sl.text1 : sl.text2,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500),
              overflow: TextOverflow.ellipsis)),
        ]))));
  }

  Future<void> _wfAddComment(Map<String, dynamic> inc) async {
    final sl = SL.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Add note',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 4,
          style: TextStyle(color: sl.text1, fontSize: 12),
          decoration: InputDecoration(
            hintText: 'Investigation update, root cause, action…',
            hintStyle: TextStyle(color: sl.text4, fontSize: 10.5),
            filled: true, fillColor: sl.bg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: sl.border)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00897B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Add', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;

    final list = (inc['comments'] is List)
        ? List<Map<String, dynamic>>.from(inc['comments'])
        : <Map<String, dynamic>>[];
    list.add({
      'by'   : _currentActor,
      'at'   : DateTime.now().toIso8601String(),
      'text' : ctrl.text.trim(),
    });
    inc['comments'] = list;
    try {
      await LocalDB.saveIncident(inc);
      SyncService.pushIncident(inc).catchError((_) => false);
    } catch (_) {}
    await _loadAll();
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 4 — ADVANCED USER MANAGEMENT
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleUsersAdvanced(SL sl) {
    final filtered = _userSearch.trim().isEmpty
        ? _users
        : _users.where((u) {
            final q = _userSearch.toLowerCase();
            return [u['username'], u['name'], u['designation'],
                    u['plant'], u['department'], u['pno']]
                .whereType<String>().join(' ').toLowerCase().contains(q);
          }).toList();
    final admins = _users.where((u) =>
        u['isAdmin']?.toString().toLowerCase() == 'true').length;

    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: sl.bg2,
        child: Column(children: [
          TextField(
            onChanged: (v) => setState(() => _userSearch = v),
            style: TextStyle(color: sl.text1, fontSize: 12),
            decoration: InputDecoration(
              hintText: 'Search users by name, plant, PNO…',
              hintStyle: TextStyle(color: sl.text4, fontSize: 11),
              prefixIcon: Icon(Icons.search_rounded,
                  color: sl.text4, size: 16),
              filled: true, fillColor: sl.card, isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: sl.border)))),
          const SizedBox(height: 8),
          Row(children: [
            _miniBadge('${_users.length} total',
                const Color(0xFF3949AB), sl),
            const SizedBox(width: 6),
            _miniBadge('$admins admins', AppColors.amber, sl),
            const Spacer(),
            GestureDetector(
              onTap: _addNewUser,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF3949AB).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFF3949AB).withOpacity(0.4))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.person_add_rounded, size: 13, color: Color(0xFF3949AB)),
                  SizedBox(width: 5),
                  Text('Add User', style: TextStyle(
                      color: Color(0xFF3949AB), fontSize: 11,
                      fontWeight: FontWeight.w700)),
                ]))),
          ]),
        ])),
      Expanded(child: filtered.isEmpty
        ? Center(child: Text('No users found',
            style: TextStyle(color: sl.text4, fontSize: 12)))
        : ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _userCard(filtered[i], sl))),
    ]);
  }

  Widget _miniBadge(String label, Color color, SL sl) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withOpacity(0.3))),
    child: Text(label, style: TextStyle(
        color: color, fontSize: 10, fontWeight: FontWeight.w800)));

  Widget _userCard(Map<String, dynamic> u, SL sl) {
    final uname = u['username']?.toString() ?? '?';
    final name  = u['name']?.toString() ?? uname;
    final desig = u['designation']?.toString() ?? '';
    final plant = u['plant']?.toString() ?? '';
    final dept  = u['department']?.toString() ?? '';
    final isAdm = u['isAdmin']?.toString().toLowerCase() == 'true';
    final status = u['status']?.toString().toLowerCase() ?? 'active';
    final pno   = u['pno']?.toString() ?? '';
    final mob   = u['mobile']?.toString() ?? '';
    final expanded = _userExpandedUname == uname;

    final activity = _auditLog.where(
        (e) => e['actor']?.toString() == uname).toList();

    return Container(
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isAdm
            ? AppColors.amber.withOpacity(0.4)
            : sl.border)),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            _userExpandedUname = expanded ? null : uname;
          }),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: isAdm
                    ? AppColors.amber.withOpacity(0.15)
                    : const Color(0xFF3949AB).withOpacity(0.15),
                  shape: BoxShape.circle),
                child: Center(child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: TextStyle(
                        color: isAdm ? AppColors.amber : const Color(0xFF3949AB),
                        fontSize: 16, fontWeight: FontWeight.w800)))),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(name, style: TextStyle(
                        color: sl.text1, fontSize: 12.5,
                        fontWeight: FontWeight.w800),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (isAdm) Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.amber,
                        borderRadius: BorderRadius.circular(3)),
                      child: const Text('ADMIN',
                          style: TextStyle(
                              color: Colors.white, fontSize: 8,
                              fontWeight: FontWeight.w800))),
                  ]),
                  const SizedBox(height: 2),
                  Text('@$uname · $desig',
                      style: TextStyle(color: sl.text3, fontSize: 10.5),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (plant.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(dept.isEmpty ? plant : '$plant · $dept',
                        style: TextStyle(color: sl.text4, fontSize: 10),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ])),
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  color: status == 'active'
                    ? AppColors.green : AppColors.red,
                  shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: sl.text3, size: 18),
            ]),
          )),
        if (expanded) ...[
          Container(height: 0.5, color: sl.border),
          Padding(
            padding: const EdgeInsets.all(11),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _userDetail('PNO', pno.isEmpty ? '—' : pno, sl),
                _userDetail('Mobile', mob.isEmpty ? '—' : mob, sl),
                _userDetail('Status', status.toUpperCase(),
                    sl, color: status == 'active' ? AppColors.green : AppColors.red),
                const SizedBox(height: 10),
                Text('Actions', style: TextStyle(
                    color: sl.text3, fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (uname != 'admin')
                    _userBtn(isAdm ? 'Revoke admin' : 'Grant admin',
                        Icons.shield_outlined,
                        isAdm ? AppColors.red : AppColors.amber,
                        () => _userToggleAdmin(u)),
                  _userBtn(status == 'active' ? 'Disable' : 'Enable',
                      status == 'active'
                        ? Icons.block_rounded : Icons.check_circle_rounded,
                      status == 'active' ? AppColors.red : AppColors.green,
                      () => _userToggleStatus(u)),
                  _userBtn('Reset PW', Icons.key_rounded,
                      const Color(0xFF8E24AA), () => _userResetPw(u)),
                  _userBtn('Change plant', Icons.factory_outlined,
                      const Color(0xFF1E88E5), () => _userChangePlant(u)),
                  if (uname != 'admin' && uname != _currentActor)
                    _userBtn('Delete', Icons.delete_outline_rounded,
                        AppColors.red, () => _userDelete(u)),
                ]),
                const SizedBox(height: 12),
                Text('Activity (${activity.length})',
                    style: TextStyle(color: sl.text3, fontSize: 10,
                        fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                if (activity.isEmpty)
                  Text('— no recorded activity —',
                      style: TextStyle(color: sl.text4, fontSize: 10.5,
                          fontStyle: FontStyle.italic))
                else
                  ...activity.take(6).map((e) =>
                      _auditLogRow(e, sl, compact: true)),
              ]),
          ),
        ],
      ]));
  }

  Widget _userDetail(String label, String value, SL sl, {Color? color}) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 70, child: Text(label,
            style: TextStyle(color: sl.text4, fontSize: 10.5))),
        Expanded(child: Text(value,
            style: TextStyle(
                color: color ?? sl.text2,
                fontSize: 11, fontWeight: FontWeight.w700))),
      ]));

  Widget _userBtn(String label, IconData icon, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
              color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
        ])));

  Future<void> _userToggleAdmin(Map<String, dynamic> u) async {
    final wasAdm = u['isAdmin']?.toString().toLowerCase() == 'true';
    u['isAdmin'] = (!wasAdm).toString();
    try {
      await LocalDB.upsertUser(u);
      try { await SyncService.pushUser(u); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserRoleChange,
      actor: _currentActor,
      target: u['username']?.toString(),
      targetName: u['name']?.toString(),
      meta: {'isAdmin': (!wasAdm).toString()});
    await _loadAll();
    _toast(wasAdm ? 'Admin revoked' : 'Admin granted', AppColors.amber);
  }

  Future<void> _userToggleStatus(Map<String, dynamic> u) async {
    final wasActive = (u['status']?.toString().toLowerCase() ?? 'active') == 'active';
    u['status'] = wasActive ? 'disabled' : 'active';
    try {
      await LocalDB.upsertUser(u);
      try { await SyncService.pushUser(u); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserStatus,
      actor: _currentActor,
      target: u['username']?.toString(),
      targetName: u['name']?.toString(),
      meta: {'status': u['status']});
    await _loadAll();
    _toast(u['status'].toString().toUpperCase(),
        wasActive ? AppColors.red : AppColors.green);
  }

  Future<void> _userResetPw(Map<String, dynamic> u) async {
    final sl = SL.of(context);
    final ctrl = TextEditingController(
        text: 'temp@${DateTime.now().millisecondsSinceEpoch % 10000}');
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Reset password — ${u['username']}',
            style: TextStyle(color: sl.text1, fontSize: 13,
                fontWeight: FontWeight.w800)),
        content: TextField(controller: ctrl, autofocus: true,
          style: TextStyle(color: sl.text1, fontSize: 12),
          decoration: InputDecoration(
            labelText: 'New temporary password',
            labelStyle: TextStyle(color: sl.text4, fontSize: 11),
            filled: true, fillColor: sl.bg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: sl.border)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8E24AA),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Reset', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    u['password'] = ctrl.text.trim();
    try {
      await LocalDB.upsertUser(u);
      try { await SyncService.pushUser(u); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserPwReset,
      actor: _currentActor,
      target: u['username']?.toString(),
      targetName: u['name']?.toString());
    _toast('Password reset to: ${ctrl.text}', const Color(0xFF8E24AA));
  }

  Future<void> _userChangePlant(Map<String, dynamic> u) async {
    final sl = SL.of(context);
    String? picked = u['plant']?.toString();
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Change plant — ${u['username']}',
            style: TextStyle(color: sl.text1, fontSize: 13,
                fontWeight: FontWeight.w800)),
        content: SizedBox(width: 320,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: sl.bg, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sl.border)),
            child: ListView(shrinkWrap: true, children: [
              for (final p in _plantsEditable)
                _wfPickRow('${p['name']} (${p['code']})',
                    p['name'], picked,
                    (v) => setSt(() => picked = v), sl),
            ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Update', style: TextStyle(color: Colors.white))),
        ])));
    if (ok != true || picked == null) return;
    u['plant'] = picked;
    try {
      await LocalDB.upsertUser(u);
      try { await SyncService.pushUser(u); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserEdit,
      actor: _currentActor,
      target: u['username']?.toString(),
      targetName: u['name']?.toString(),
      meta: {'plant': picked});
    await _loadAll();
    _toast('Plant updated', const Color(0xFF1E88E5));
  }

  Future<void> _userDelete(Map<String, dynamic> u) async {
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete user ${u['username']}?',
            style: const TextStyle(color: AppColors.red, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: Text('This will remove ${u['name']} from local and Google Sheets. Cannot be undone.',
            style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    final uname = u['username']?.toString() ?? '';
    try {
      await LocalDB.deleteUser(uname);
      try { await SyncService.deleteUser(uname); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserDelete,
      actor: _currentActor,
      target: uname,
      targetName: u['name']?.toString());
    setState(() => _userExpandedUname = null);
    await _loadAll();
    _toast('User deleted', AppColors.red);
  }

  Future<void> _addNewUser() async {
    final sl = SL.of(context);
    final nameCtrl  = TextEditingController();
    final unameCtrl = TextEditingController();
    final passCtrl  = TextEditingController(text: 'sail@123');
    final desigCtrl = TextEditingController();
    final pnoCtrl   = TextEditingController();
    final deptOtherCtrl = TextEditingController();
    String? selectedPlant;
    String? selectedDept;
    bool showOtherDept = false;
    bool makeAdmin = false;

    final ok = await showDialog<bool>(context: context, builder: (_) =>
      StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Add New User',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: SingleChildScrollView(child: SizedBox(width: 320,
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              _addUserField('Full Name *', nameCtrl, sl),
              const SizedBox(height: 10),
              _addUserField('Username *', unameCtrl, sl),
              const SizedBox(height: 10),
              _addUserField('Password *', passCtrl, sl),
              const SizedBox(height: 10),
              _addUserField('Designation', desigCtrl, sl),
              const SizedBox(height: 10),
              _addUserField('PNO', pnoCtrl, sl),
              const SizedBox(height: 10),
              Text('Plant', style: TextStyle(color: sl.text3, fontSize: 10)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: sl.bg, borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sl.border)),
                child: DropdownButton<String>(
                  value: selectedPlant,
                  isExpanded: true,
                  underline: const SizedBox(),
                  hint: Text('Select plant', style: TextStyle(
                      color: sl.text4, fontSize: 11)),
                  dropdownColor: sl.card,
                  style: TextStyle(color: sl.text1, fontSize: 11),
                  items: _plantsEditable.map((p) => DropdownMenuItem(
                    value: p['name'],
                    child: Text(p['name'] ?? '?',
                        style: TextStyle(color: sl.text1, fontSize: 11)),
                  )).toList(),
                  onChanged: (v) => setSt(() => selectedPlant = v))),
              const SizedBox(height: 10),
              Text('Department', style: TextStyle(color: sl.text3, fontSize: 10)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: sl.bg, borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sl.border)),
                child: DropdownButton<String>(
                  value: selectedDept,
                  isExpanded: true,
                  underline: const SizedBox(),
                  hint: Text('Select department', style: TextStyle(
                      color: sl.text4, fontSize: 11)),
                  dropdownColor: sl.card,
                  style: TextStyle(color: sl.text1, fontSize: 11),
                  items: [..._deptsEditable, 'Other'].map((d) => DropdownMenuItem(
                    value: d,
                    child: Text(d,
                        style: TextStyle(
                          color: d == 'Other' ? AppColors.accent : sl.text1,
                          fontSize: 11,
                          fontStyle: d == 'Other' ? FontStyle.italic : FontStyle.normal)),
                  )).toList(),
                  onChanged: (v) => setSt(() {
                    selectedDept = v;
                    showOtherDept = v == 'Other';
                    if (v != 'Other') deptOtherCtrl.clear();
                  }))),
              if (showOtherDept) ...[
                const SizedBox(height: 8),
                _addUserField('Enter Department Name', deptOtherCtrl, sl),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Checkbox(
                  value: makeAdmin,
                  onChanged: (v) => setSt(() => makeAdmin = v ?? false),
                  activeColor: AppColors.amber,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                Text('Grant Admin access',
                    style: TextStyle(color: sl.text2, fontSize: 11)),
              ]),
            ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || unameCtrl.text.trim().isEmpty
                  || passCtrl.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3949AB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Create User', style: TextStyle(color: Colors.white))),
        ])));
    if (ok != true) return;

    final effectiveDept = showOtherDept
        ? deptOtherCtrl.text.trim()
        : (selectedDept ?? '');
    final userData = <String, dynamic>{
      'name':        nameCtrl.text.trim(),
      'username':    unameCtrl.text.trim().toLowerCase(),
      'password':    passCtrl.text.trim(),
      'designation': desigCtrl.text.trim(),
      'pno':         pnoCtrl.text.trim(),
      'plant':       selectedPlant ?? '',
      'department':  effectiveDept,
      'isAdmin':     makeAdmin.toString(),
      'status':      'active',
    };

    try {
      await LocalDB.upsertUser(userData);
      try { await SyncService.pushUser(userData); } catch (_) {}
    } catch (_) {}
    await AdminAudit.log(
      action: AdminAudit.actUserEdit,
      actor: _currentActor,
      target: userData['username'],
      targetName: userData['name'],
      meta: {'action': 'created'});
    await _loadAll();
    _toast('User ${userData['username']} created', const Color(0xFF3949AB));
  }

  Widget _addUserField(String label, TextEditingController ctrl, SL sl) =>
    TextField(
      controller: ctrl,
      style: TextStyle(color: sl.text1, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: sl.text4, fontSize: 10),
        filled: true, fillColor: sl.bg, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: sl.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: sl.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF3949AB), width: 1.5))));

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 7 — PLANT & DEPARTMENT MASTER
  // ══════════════════════════════════════════════════════════════════
  Widget _modulePlantMaster(SL sl) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      _sectionHeader('SAIL Plants & Units', sl,
        trailing: TextButton.icon(
          onPressed: _addPlant,
          icon: const Icon(Icons.add_rounded, size: 14, color: Color(0xFF7E57C2)),
          label: const Text('Add', style: TextStyle(
              color: Color(0xFF7E57C2), fontSize: 11, fontWeight: FontWeight.w800)))),
      const SizedBox(height: 6),
      Text('${_plantsEditable.length} units · these populate dropdowns across the app',
          style: TextStyle(color: sl.text4, fontSize: 10.5)),
      const SizedBox(height: 10),
      ..._plantsEditable.asMap().entries.map((e) =>
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: _plantRowCard(e.value, e.key, sl))),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.amber.withOpacity(0.3))),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded,
              color: AppColors.amber, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(
            'Plant → state mapping drives which Factory Rules apply (CG/Odisha/TN/Bihar).',
            style: TextStyle(color: sl.text3, fontSize: 10.5, height: 1.4))),
        ])),

      const SizedBox(height: 18),

      _sectionHeader('Departments', sl,
        trailing: TextButton.icon(
          onPressed: _addDepartment,
          icon: const Icon(Icons.add_rounded, size: 14, color: Color(0xFF7E57C2)),
          label: const Text('Add', style: TextStyle(
              color: Color(0xFF7E57C2), fontSize: 11, fontWeight: FontWeight.w800)))),
      const SizedBox(height: 6),
      Text('${_deptsEditable.length} departments',
          style: TextStyle(color: sl.text4, fontSize: 10.5)),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6,
        children: [
          for (var i = 0; i < _deptsEditable.length; i++)
            _deptChip(_deptsEditable[i], i, sl),
        ]),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: _resetMasters,
        icon: const Icon(Icons.refresh_rounded, size: 14, color: AppColors.red),
        label: const Text('Reset all masters to defaults',
            style: TextStyle(color: AppColors.red, fontSize: 11,
                fontWeight: FontWeight.w700)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: AppColors.red.withOpacity(0.4)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
    ]);
  }

  Widget _plantRowCard(Map<String, String> p, int idx, SL sl) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: sl.border)),
      child: Row(children: [
        Container(
          width: 44, height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF7E57C2).withOpacity(0.12),
            borderRadius: BorderRadius.circular(6)),
          child: Center(child: Text(p['code'] ?? '?',
              style: const TextStyle(color: Color(0xFF7E57C2),
                  fontSize: 11, fontWeight: FontWeight.w800)))),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p['name'] ?? '?', style: TextStyle(
                color: sl.text1, fontSize: 12, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('${p['kind'] ?? '—'} · ${p['state'] ?? '—'}',
                style: TextStyle(color: sl.text3, fontSize: 10)),
          ])),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          icon: Icon(Icons.edit_outlined,
              color: sl.text3, size: 16),
          onPressed: () => _editPlant(idx)),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          icon: const Icon(Icons.delete_outline_rounded,
              color: AppColors.red, size: 16),
          onPressed: () => _deletePlant(idx)),
      ]));
  }

  Widget _deptChip(String name, int idx, SL sl) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: sl.card,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: sl.border)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(name, style: TextStyle(
          color: sl.text2, fontSize: 10.5, fontWeight: FontWeight.w600)),
      const SizedBox(width: 6),
      GestureDetector(
        onTap: () => _editDept(idx),
        child: Icon(Icons.edit_outlined, color: sl.text4, size: 11)),
      const SizedBox(width: 4),
      GestureDetector(
        onTap: () => _deleteDept(idx),
        child: const Icon(Icons.close_rounded, color: AppColors.red, size: 12)),
    ]));

  Future<void> _addPlant() async {
    final p = await _plantDialog(null);
    if (p == null) return;
    setState(() => _plantsEditable.add(p));
    await AdminMasterData.savePlants(_plantsEditable);
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'masters': 'plant_added', 'code': p['code']});
    _toast('Plant added', const Color(0xFF7E57C2));
  }

  Future<void> _editPlant(int idx) async {
    final p = await _plantDialog(_plantsEditable[idx]);
    if (p == null) return;
    setState(() => _plantsEditable[idx] = p);
    await AdminMasterData.savePlants(_plantsEditable);
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'masters': 'plant_edited', 'code': p['code']});
    _toast('Plant updated', const Color(0xFF7E57C2));
  }

  Future<void> _deletePlant(int idx) async {
    final p = _plantsEditable[idx];
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete ${p['name']}?',
            style: const TextStyle(color: AppColors.red, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: Text(
            'This removes the plant from dropdowns. Existing incidents tagged with this plant will keep the label.',
            style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    setState(() => _plantsEditable.removeAt(idx));
    await AdminMasterData.savePlants(_plantsEditable);
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'masters': 'plant_deleted', 'code': p['code']});
    _toast('Plant deleted', AppColors.red);
  }

  Future<Map<String, String>?> _plantDialog(Map<String, String>? p) async {
    final sl = SL.of(context);
    final code  = TextEditingController(text: p?['code']  ?? '');
    final name  = TextEditingController(text: p?['name']  ?? '');
    final state = TextEditingController(text: p?['state'] ?? '');
    final kind  = TextEditingController(text: p?['kind']  ?? 'Plant');
    return showDialog<Map<String, String>?>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(p == null ? 'Add plant' : 'Edit plant',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: SizedBox(width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _dlgField('Code (e.g. BSP)', code, sl),
            const SizedBox(height: 8),
            _dlgField('Name', name, sl),
            const SizedBox(height: 8),
            _dlgField('State', state, sl),
            const SizedBox(height: 8),
            _dlgField('Kind (Plant/Mines/HQ)', kind, sl),
          ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (code.text.trim().isEmpty || name.text.trim().isEmpty) return;
              Navigator.pop(context, {
                'code'  : code.text.trim().toUpperCase(),
                'name'  : name.text.trim(),
                'state' : state.text.trim(),
                'kind'  : kind.text.trim().isEmpty ? 'Plant' : kind.text.trim(),
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7E57C2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Save', style: TextStyle(color: Colors.white))),
        ]));
  }

  Widget _dlgField(String label, TextEditingController c, SL sl) =>
    TextField(controller: c,
      style: TextStyle(color: sl.text1, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: sl.text4, fontSize: 11),
        filled: true, fillColor: sl.bg, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: sl.border))));

  // ★ v25: API Key input field — uses dialog on web for reliable paste
  // isGemini = true for Gemini key, false for Groq key
  Widget _apiKeyInputField(TextEditingController ctrl, String label, SL sl, {bool isGemini = false}) {
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final dialogCtrl = TextEditingController(text: ctrl.text);
            return AlertDialog(
              backgroundColor: sl.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: Text('Enter API Key', style: TextStyle(color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
              content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Paste or type your key below:', style: TextStyle(color: sl.text3, fontSize: 11)),
                const SizedBox(height: 12),
                TextField(
                  controller: dialogCtrl,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 1,
                  style: TextStyle(color: sl.text1, fontSize: 12, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: 'Ctrl+V / Cmd+V to paste...',
                    hintStyle: TextStyle(color: sl.text4, fontSize: 11),
                    filled: true,
                    fillColor: sl.isDark ? const Color(0xFF1A1D2E) : const Color(0xFFF5F5F5),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent, width: 2)),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Key will be saved & synced to all devices automatically.',
                  style: TextStyle(color: AppColors.green, fontSize: 9, fontWeight: FontWeight.w600)),
              ]),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: TextStyle(color: sl.text3))),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx, dialogCtrl.text.trim()),
                  icon: const Icon(Icons.save_rounded, size: 14),
                  label: const Text('Save & Sync'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isGemini ? const Color(0xFF1A73E8) : AppColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
              ],
            );
          },
        );
        if (result != null && result.isNotEmpty) {
          setState(() => ctrl.text = result);
          // ★ Auto-save immediately after dialog — no extra button needed
          if (isGemini) {
            if (result.length < 20) {
              _toast('Invalid key — too short', AppColors.red);
              return;
            }
            await GeminiDirectVision.setApiKey(result);
            await GeminiDirectVision.setModel(_geminiVisionSelectedModel);
            _pushApiKeysToBackend(result, _geminiVisionSelectedModel);
            setState(() => _geminiVisionConfigured = true);
            _toast('✓ Gemini Vision key saved & synced to all devices!', AppColors.green);
          } else {
            if (!result.startsWith('gsk_')) {
              _toast('Invalid key — must start with gsk_', AppColors.red);
              return;
            }
            await GroqService.setApiKey(result);
            await GroqService.setModel(_groqSelectedModel);
            _pushGroqKeyToBackend(result);
            setState(() => _groqConfigured = true);
            _toast('✓ Groq AI key saved & synced to all devices!', AppColors.green);
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ctrl.text.isNotEmpty ? AppColors.green.withOpacity(0.5) : sl.border),
        ),
        child: Row(children: [
          Icon(ctrl.text.isNotEmpty ? Icons.key_rounded : Icons.add_circle_outline,
            color: ctrl.text.isNotEmpty ? AppColors.green : AppColors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ctrl.text.isEmpty
                ? 'Tap to paste $label'
                : '${ctrl.text.substring(0, ctrl.text.length.clamp(0, 10))}${'•' * 20}${ctrl.text.substring((ctrl.text.length - 4).clamp(0, ctrl.text.length))}',
              style: TextStyle(
                color: ctrl.text.isEmpty ? sl.text3 : sl.text1,
                fontSize: 11,
                fontFamily: ctrl.text.isEmpty ? null : 'monospace',
              ),
            ),
          ),
          Icon(Icons.edit_outlined, color: sl.text3, size: 16),
        ]),
      ),
    );
  }

  // ★ v25: Push API keys to backend for cross-device sync
  Future<void> _pushApiKeysToBackend(String geminiKey, String model) async {
    try {
      final url = await SyncService.getBackendUrl();
      final body = {
        'action': 'saveMasterData',
        'geminiApiKey': geminiKey,
        'geminiModel': model,
        'updatedBy': _currentActor,
      };
      await http.post(Uri.parse(url),
        body: jsonEncode(body),
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  Future<void> _pushGroqKeyToBackend(String groqKey) async {
    try {
      final url = await SyncService.getBackendUrl();
      final body = {
        'action': 'saveMasterData',
        'groqApiKey': groqKey,
        'updatedBy': _currentActor,
      };
      await http.post(Uri.parse(url),
        body: jsonEncode(body),
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  Future<void> _addDepartment() async {
    final d = await _stringDialog('Add department', '');
    if (d == null || d.trim().isEmpty) return;
    setState(() => _deptsEditable.add(d.trim()));
    await AdminMasterData.saveDepartments(_deptsEditable);
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'masters': 'dept_added', 'value': d.trim()});
  }

  Future<void> _editDept(int idx) async {
    final d = await _stringDialog('Edit department', _deptsEditable[idx]);
    if (d == null || d.trim().isEmpty) return;
    setState(() => _deptsEditable[idx] = d.trim());
    await AdminMasterData.saveDepartments(_deptsEditable);
  }

  Future<void> _deleteDept(int idx) async {
    setState(() => _deptsEditable.removeAt(idx));
    await AdminMasterData.saveDepartments(_deptsEditable);
  }

  Future<String?> _stringDialog(String title, String initial) async {
    final sl = SL.of(context);
    final ctrl = TextEditingController(text: initial);
    return showDialog<String?>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title,
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: SizedBox(width: 300,
          child: TextField(controller: ctrl, autofocus: true,
            style: TextStyle(color: sl.text1, fontSize: 12),
            decoration: InputDecoration(
              filled: true, fillColor: sl.bg, isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: sl.border))))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7E57C2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('OK', style: TextStyle(color: Colors.white))),
        ]));
  }

  Future<void> _resetMasters() async {
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Reset all masters?',
            style: TextStyle(color: AppColors.red, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: Text(
            'Plants, departments, WSA causes, severities, statuses, and observation types will be reset to factory defaults.',
            style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Reset', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    await AdminMasterData.resetAllToDefaults();
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'masters': 'reset_all'});
    await _loadAll();
    _toast('Masters reset to defaults', AppColors.amber);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 8 — CUSTOM LISTS EDITOR
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleCustomLists(SL sl) {
    final active = _customLists[_customListTab] ?? <String>[];
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: sl.bg2,
        child: Wrap(spacing: 5, runSpacing: 5, children: [
          _clTabChip('wsa',      'WSA-13', sl),
          _clTabChip('severity', 'Severity', sl),
          _clTabChip('status',   'Status', sl),
          _clTabChip('obstype',  'Obs Type', sl),
          _clTabChip('scoring',  'Scoring', sl),
        ])),
      if (_customListTab == 'scoring') ...[
        Expanded(child: _buildScoringEditor(sl)),
      ] else ...[
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Row(children: [
          Expanded(child: Text(
              '${active.length} items in "$_customListTab"',
              style: TextStyle(color: sl.text2, fontSize: 11,
                  fontWeight: FontWeight.w700))),
          TextButton.icon(
            onPressed: _addCustomItem,
            icon: const Icon(Icons.add_rounded,
                size: 14, color: Color(0xFF00ACC1)),
            label: const Text('Add item', style: TextStyle(
                color: Color(0xFF00ACC1), fontSize: 11,
                fontWeight: FontWeight.w800))),
        ])),
      Expanded(child: active.isEmpty
        ? Center(child: Text('No items',
            style: TextStyle(color: sl.text4, fontSize: 12)))
        : ReorderableListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            onReorder: _reorderCustomItem,
            children: [
              for (var i = 0; i < active.length; i++)
                Container(
                  key: ValueKey('${_customListTab}_$i'),
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(11, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: sl.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: sl.border)),
                  child: Row(children: [
                    Icon(Icons.drag_indicator_rounded,
                        color: sl.text4, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text(active[i],
                        style: TextStyle(color: sl.text1, fontSize: 11.5,
                            fontWeight: FontWeight.w600))),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
                      icon: Icon(Icons.edit_outlined,
                          color: sl.text3, size: 14),
                      onPressed: () => _editCustomItem(i)),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
                      icon: const Icon(Icons.delete_outline_rounded,
                          color: AppColors.red, size: 14),
                      onPressed: () => _deleteCustomItem(i)),
                  ])),
            ])),
      ],
    ]);
  }

  // ── Scoring Editor UI ───────────────────────────────────────────
  Widget _buildScoringEditor(SL sl) {
    final levels = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'];
    final colors = {
      'CRITICAL': AppColors.crit,
      'HIGH': AppColors.red,
      'MEDIUM': AppColors.amber,
      'LOW': AppColors.green,
    };

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.accent.withOpacity(0.3))),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded,
                size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(
              'Set the score value for each severity level. '
              'These scores are used to calculate the overall risk score of each scan.',
              style: TextStyle(color: sl.text2, fontSize: 10.5, height: 1.4))),
          ]),
        ),
        for (final level in levels) ...[
          _scoreTile(level, colors[level]!, sl),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _resetScoresToDefault,
            icon: const Icon(Icons.restore_rounded, size: 14, color: Colors.white),
            label: const Text('Reset to Defaults',
                style: TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.amber,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          ),
        ),
      ],
    );
  }

  Widget _scoreTile(String level, Color color, SL sl) {
    final score = _severityScores[level] ??
        AdminMasterData.defaultSeverityScores[level] ?? 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4))),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text(level, style: TextStyle(
            color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700))),
        IconButton(
          onPressed: () => _adjustScore(level, -5),
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
          color: AppColors.red,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
        Container(
          width: 48,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6)),
          child: Text('$score', style: TextStyle(
              color: color, fontSize: 16, fontWeight: FontWeight.w800)),
        ),
        IconButton(
          onPressed: () => _adjustScore(level, 5),
          icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
          color: AppColors.green,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
      ]),
    );
  }

  void _adjustScore(String level, int delta) {
    setState(() {
      final current = _severityScores[level] ??
          AdminMasterData.defaultSeverityScores[level] ?? 10;
      _severityScores[level] = (current + delta).clamp(0, 100);
    });
    AdminMasterData.saveSeverityScores(_severityScores);
    AdminAudit.log(
      action: 'scoring_updated',
      actor: _currentActor,
      meta: {'level': level, 'newScore': _severityScores[level]});
  }

  void _resetScoresToDefault() {
    setState(() {
      _severityScores = Map<String, int>.from(
          AdminMasterData.defaultSeverityScores);
    });
    AdminMasterData.saveSeverityScores(_severityScores);
    _toast('Scores reset to defaults', AppColors.amber);
  }

  Widget _clTabChip(String value, String label, SL sl) {
    final active = _customListTab == value;
    return GestureDetector(
      onTap: () => setState(() => _customListTab = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00ACC1).withOpacity(0.14) : sl.card,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
              color: active ? const Color(0xFF00ACC1) : sl.border,
              width: active ? 1.5 : 0.8)),
        child: Text(label, style: TextStyle(
            color: active ? const Color(0xFF00ACC1) : sl.text2,
            fontSize: 11,
            fontWeight: active ? FontWeight.w800 : FontWeight.w500))));
  }

  Future<void> _saveCustomList() async {
    final list = _customLists[_customListTab] ?? <String>[];
    switch (_customListTab) {
      case 'wsa'     : await AdminMasterData.saveWsaCauses(list);  break;
      case 'severity': await AdminMasterData.saveSeverities(list); break;
      case 'status'  : await AdminMasterData.saveStatuses(list);   break;
      case 'obstype' : await AdminMasterData.saveObsTypes(list);   break;
    }
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _currentActor,
      meta: {'list': _customListTab, 'count': list.length});
  }

  Future<void> _addCustomItem() async {
    final v = await _stringDialog('Add to $_customListTab', '');
    if (v == null || v.trim().isEmpty) return;
    setState(() {
      _customLists[_customListTab] = [
        ...(_customLists[_customListTab] ?? <String>[]),
        v.trim(),
      ];
    });
    await _saveCustomList();
  }

  Future<void> _editCustomItem(int idx) async {
    final current = _customLists[_customListTab]![idx];
    final v = await _stringDialog('Edit', current);
    if (v == null || v.trim().isEmpty) return;
    setState(() {
      _customLists[_customListTab]![idx] = v.trim();
    });
    await _saveCustomList();
  }

  Future<void> _deleteCustomItem(int idx) async {
    setState(() => _customLists[_customListTab]!.removeAt(idx));
    await _saveCustomList();
  }

  void _reorderCustomItem(int oldIdx, int newIdx) async {
    setState(() {
      final list = _customLists[_customListTab]!;
      if (newIdx > oldIdx) newIdx -= 1;
      final item = list.removeAt(oldIdx);
      list.insert(newIdx, item);
    });
    await _saveCustomList();
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 10 — ALERTS & NOTIFICATIONS
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleAlerts(SL sl) {
    final firing = AdminAlerts.evaluate(_alertRules, _incidents);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.green.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.green.withOpacity(0.3))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.notifications_active_rounded,
              color: AppColors.green, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(
            'Real-time SMS + Email alerts via Apps Script backend. '
            'Alerts fire automatically when AI Scan, Near Miss, or Incidents are synced. '
            'Configure department-specific rules below.',
            style: TextStyle(color: sl.text3, fontSize: 10.5, height: 1.4))),
        ])),

      const SizedBox(height: 16),

      _sectionHeader('Currently firing', sl,
        trailing: Text('${firing.length} rules',
            style: TextStyle(color: sl.text4, fontSize: 10))),
      const SizedBox(height: 8),
      if (firing.isEmpty)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.card, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.border)),
          child: Row(children: [
            const Icon(Icons.check_circle_outline,
                color: AppColors.green, size: 18),
            const SizedBox(width: 8),
            Text('No alert rules would fire right now',
                style: TextStyle(color: sl.text2, fontSize: 11.5)),
          ]))
      else
        ...firing.map((f) => Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: AppColors.red.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.red.withOpacity(0.3))),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.red, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f['name']?.toString() ?? '?',
                    style: TextStyle(color: sl.text1, fontSize: 12,
                        fontWeight: FontWeight.w800)),
                Text(f['reason']?.toString() ?? '',
                    style: TextStyle(color: sl.text3, fontSize: 10.5)),
              ])),
          ]))),

      // ★ v35: Send alerts NOW + Sync rules to backend
      if (firing.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: _isSendingAlerts ? null : () => _fireAlertsNow(firing),
              icon: _isSendingAlerts
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 16),
              label: Text(_isSendingAlerts ? 'Sending...' : 'Send Alerts Now',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE53935),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            )),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await AdminAlerts.syncToBackend();
                if (mounted) _toast(ok ? 'Rules synced to backend' : 'Sync failed',
                    ok ? AppColors.green : AppColors.red);
              },
              icon: const Icon(Icons.cloud_upload_rounded, size: 14),
              label: const Text('Sync Rules',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE53935),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                side: const BorderSide(color: Color(0xFFE53935)),
              ),
            ),
          ]),
        ),

      const SizedBox(height: 18),

      _sectionHeader('Configured rules', sl,
        trailing: TextButton.icon(
          onPressed: _addAlertRule,
          icon: const Icon(Icons.add_rounded, size: 14, color: Color(0xFFE53935)),
          label: const Text('New rule', style: TextStyle(
              color: Color(0xFFE53935), fontSize: 11, fontWeight: FontWeight.w800)))),
      const SizedBox(height: 8),
      if (_alertRules.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: sl.card, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.border)),
          child: Center(child: Column(children: [
            Icon(Icons.notifications_off_outlined,
                color: sl.text4, size: 28),
            const SizedBox(height: 6),
            Text('No rules configured',
                style: TextStyle(color: sl.text3, fontSize: 11.5)),
            const SizedBox(height: 2),
            Text('Tap "New rule" above to add one',
                style: TextStyle(color: sl.text4, fontSize: 10)),
          ])))
      else
        ..._alertRules.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _alertRuleCard(r, sl))),

      // ★ v35: Alert History section
      const SizedBox(height: 20),
      _sectionHeader('Alert History (recent)', sl),
      const SizedBox(height: 8),
      FutureBuilder<List<Map<String, dynamic>>>(
        future: AdminAlerts.getAlertHistory(),
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: sl.card, borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sl.border)),
              child: Row(children: [
                Icon(Icons.history_rounded, color: sl.text4, size: 18),
                const SizedBox(width: 8),
                Text('No alerts sent yet',
                    style: TextStyle(color: sl.text3, fontSize: 11.5)),
              ]));
          }
          final history = snap.data!.take(20).toList();
          return Column(children: history.map((h) {
            final success = h['success'] == true;
            final ts = h['timestamp']?.toString() ?? '';
            final timeStr = ts.length >= 16 ? ts.substring(0, 16).replaceAll('T', ' ') : ts;
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: success ? AppColors.green.withOpacity(0.04) : AppColors.red.withOpacity(0.04),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: success ? AppColors.green.withOpacity(0.2) : AppColors.red.withOpacity(0.2))),
              child: Row(children: [
                Icon(success ? Icons.check_circle_outline : Icons.error_outline,
                    size: 12, color: success ? AppColors.green : AppColors.red),
                const SizedBox(width: 6),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h['ruleName']?.toString() ?? h['trigger']?.toString() ?? '',
                      style: TextStyle(color: sl.text1, fontSize: 10, fontWeight: FontWeight.w700)),
                  Text('${h['reason'] ?? ''} ${h['department']?.toString().isNotEmpty == true ? "• ${h['department']}" : ""}',
                      style: TextStyle(color: sl.text3, fontSize: 9),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ])),
                Text(timeStr, style: TextStyle(color: sl.text4, fontSize: 8.5)),
              ]));
          }).toList());
        }),

      // ★ v35: Quick setup for default rules
      const SizedBox(height: 16),
      if (_alertRules.isEmpty)
        OutlinedButton.icon(
          onPressed: () async {
            final defaults = AdminAlerts.getDefaultRules(_currentActor);
            for (final r in defaults) {
              await AdminAlerts.save(r);
            }
            await _loadAll();
            _toast('5 default rules added (disabled) — configure recipients & enable', AppColors.green);
          },
          icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
          label: const Text('Load Default Rules (recommended starting templates)',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFE53935),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            side: const BorderSide(color: Color(0xFFE53935))),
        ),
    ]);
  }

  Widget _alertRuleCard(Map<String, dynamic> r, SL sl) {
    final enabled = r['enabled'] == true;
    final trigger = r['trigger']?.toString() ?? '';
    final triggerLabel = AdminAlerts.triggerLabels[trigger] ?? trigger;
    final recipients = (r['recipients'] is List)
        ? (r['recipients'] as List).join(', ') : '';
    final dept = r['department']?.toString() ?? '';
    final channel = r['channel']?.toString().toUpperCase() ?? 'EMAIL';
    final fireCount = r['fireCount'] ?? 0;
    final lastFired = r['lastFired']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: enabled
            ? const Color(0xFFE53935).withOpacity(0.3) : sl.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(
            color: enabled ? AppColors.green : sl.text4,
            shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Expanded(child: Text(r['name']?.toString() ?? '?',
              style: TextStyle(color: sl.text1, fontSize: 12,
                  fontWeight: FontWeight.w800))),
          Switch(
            value: enabled,
            activeColor: const Color(0xFFE53935),
            onChanged: (v) => _toggleAlertRule(r, v)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          const Icon(Icons.flash_on_rounded,
              size: 11, color: Color(0xFFE53935)),
          const SizedBox(width: 4),
          Expanded(child: Text(triggerLabel,
              style: TextStyle(color: sl.text2, fontSize: 10.5,
                  fontWeight: FontWeight.w600))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: channel == 'BOTH' ? const Color(0xFFE53935).withOpacity(0.1)
                   : channel == 'SMS' ? Colors.orange.withOpacity(0.1)
                   : Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4)),
            child: Text(channel,
                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800,
                    color: channel == 'BOTH' ? const Color(0xFFE53935)
                         : channel == 'SMS' ? Colors.orange : Colors.blue))),
        ]),
        if (r['plant']?.toString().isNotEmpty == true) ...[
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.factory_rounded, size: 11, color: sl.text4),
            const SizedBox(width: 4),
            Text('Plant: ${r['plant']}',
                style: TextStyle(color: sl.text3, fontSize: 10)),
          ]),
        ],
        if (dept.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.domain_rounded, size: 11, color: sl.text4),
            const SizedBox(width: 4),
            Text('Dept: $dept',
                style: TextStyle(color: sl.text3, fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ]),
        ],
        if (recipients.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.send_rounded, size: 11, color: sl.text4),
            const SizedBox(width: 4),
            Expanded(child: Text(recipients,
                style: TextStyle(color: sl.text3, fontSize: 10),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ],
        if (fireCount > 0 || lastFired.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.history_rounded, size: 10, color: sl.text4),
            const SizedBox(width: 4),
            Text('Fired $fireCount time(s)${lastFired.isNotEmpty ? " • Last: ${lastFired.substring(0, lastFired.length.clamp(0, 16))}" : ""}',
                style: TextStyle(color: sl.text4, fontSize: 9)),
          ]),
        ],
        const SizedBox(height: 8),
        Row(children: [
          const Spacer(),
          TextButton.icon(
            onPressed: () => _editAlertRule(r),
            icon: Icon(Icons.edit_outlined, color: sl.text3, size: 12),
            label: Text('Edit', style: TextStyle(color: sl.text3, fontSize: 10))),
          TextButton.icon(
            onPressed: () => _deleteAlertRule(r),
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.red, size: 12),
            label: const Text('Delete',
                style: TextStyle(color: AppColors.red, fontSize: 10))),
        ]),
      ]));
  }

  Future<void> _addAlertRule()    => _alertRuleDialog(null);
  Future<void> _editAlertRule(Map<String, dynamic> r) => _alertRuleDialog(r);

  // ★ v25: Actually fire alerts via backend
  Future<void> _fireAlertsNow(List<Map<String, dynamic>> firingRules) async {
    setState(() => _isSendingAlerts = true);
    try {
      final results = await AdminAlerts.deliver(firingRules, _incidents);
      final successCount = results.where((r) => r['ok'] == true).length;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ Sent $successCount/${results.length} alert(s) — '
              'Email + Push notifications delivered'),
          backgroundColor: const Color(0xFF43A047),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Alert delivery failed: $e'),
          backgroundColor: const Color(0xFFE53935),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSendingAlerts = false);
    }
  }

  Future<void> _alertRuleDialog(Map<String, dynamic>? existing) async {
    final sl = SL.of(context);
    final name = TextEditingController(text: existing?['name']?.toString() ?? '');
    final recips = TextEditingController(
        text: (existing?['recipients'] is List)
          ? (existing!['recipients'] as List).join(', ') : '');
    final threshold = TextEditingController(
        text: existing?['threshold']?.toString() ?? '3');
    String trigger = existing?['trigger']?.toString() ?? AdminAlerts.trigCriticalIncident;
    String plant   = existing?['plant']?.toString() ?? '';
    String department = existing?['department']?.toString() ?? '';
    String channel = existing?['channel']?.toString() ?? 'email';

    final ok = await showDialog<bool>(context: context, builder: (_) =>
      StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(existing == null ? 'New alert rule' : 'Edit rule',
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: SizedBox(width: 360,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                _dlgField('Rule name', name, sl),
                const SizedBox(height: 10),
                Text('Trigger', style: TextStyle(
                    color: sl.text3, fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                ...AdminAlerts.triggerLabels.entries.map((e) {
                  final sel = trigger == e.key;
                  return InkWell(
                    onTap: () => setSt(() => trigger = e.key),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Icon(sel ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                            color: sel ? const Color(0xFFE53935) : sl.text4,
                            size: 14),
                        const SizedBox(width: 6),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.value, style: TextStyle(
                                color: sl.text1, fontSize: 11.5,
                                fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
                            Text(AdminAlerts.triggerDescriptions[e.key] ?? '',
                                style: TextStyle(color: sl.text4, fontSize: 9.5)),
                          ])),
                      ])));
                }),
                if (trigger == AdminAlerts.trigThresholdDaily) ...[
                  const SizedBox(height: 8),
                  _dlgField('Threshold (count)', threshold, sl),
                ],
                const SizedBox(height: 10),
                Text('Plant filter (optional)',
                    style: TextStyle(color: sl.text3, fontSize: 10,
                        fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: plant,
                  dropdownColor: sl.card,
                  style: TextStyle(color: sl.text1, fontSize: 11.5),
                  decoration: InputDecoration(
                    filled: true, fillColor: sl.bg, isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: sl.border))),
                  items: [
                    const DropdownMenuItem(value: '',
                        child: Text('All plants',
                            style: TextStyle(fontSize: 11.5))),
                    ..._plantsEditable.map((p) => DropdownMenuItem(
                      value: p['name'],
                      child: Text(p['name'] ?? '',
                          style: const TextStyle(fontSize: 11.5),
                          overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setSt(() => plant = v ?? '')),
                const SizedBox(height: 10),
                Text('Department / Section filter (optional)',
                    style: TextStyle(color: sl.text3, fontSize: 10,
                        fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text('Alerts fire only for this department (AI-detected section)',
                    style: TextStyle(color: sl.text4, fontSize: 9)),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: department,
                  dropdownColor: sl.card,
                  style: TextStyle(color: sl.text1, fontSize: 11.5),
                  decoration: InputDecoration(
                    filled: true, fillColor: sl.bg, isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: sl.border))),
                  items: [
                    const DropdownMenuItem(value: '',
                        child: Text('All departments',
                            style: TextStyle(fontSize: 11.5))),
                    ...AdminAlerts.departments.map((d) => DropdownMenuItem(
                      value: d,
                      child: Text(d,
                          style: const TextStyle(fontSize: 11.5),
                          overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setSt(() => department = v ?? '')),
                const SizedBox(height: 10),
                _dlgField('Recipients (email/mobile, comma-separated)',
                    recips, sl),
                const SizedBox(height: 4),
                Text('Email: name@sail.in  |  SMS: +919876543210',
                    style: TextStyle(color: sl.text4, fontSize: 9)),
                const SizedBox(height: 10),
                Text('Channel', style: TextStyle(
                    color: sl.text3, fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, children: [
                  for (final c in const ['email', 'sms', 'both'])
                    ChoiceChip(
                      label: Text(c.toUpperCase(),
                          style: TextStyle(fontSize: 10,
                              color: channel == c ? Colors.white : sl.text2,
                              fontWeight: FontWeight.w700)),
                      selected: channel == c,
                      selectedColor: const Color(0xFFE53935),
                      backgroundColor: sl.bg,
                      onSelected: (_) => setSt(() => channel = c),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(color: sl.border))),
                ]),
              ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Save', style: TextStyle(color: Colors.white))),
        ])));
    if (ok != true) return;

    final rule = <String, dynamic>{
      if (existing != null) 'id': existing['id'],
      'name'       : name.text.trim(),
      'trigger'    : trigger,
      if (trigger == AdminAlerts.trigThresholdDaily)
        'threshold' : int.tryParse(threshold.text.trim()) ?? 3,
      'plant'      : plant,
      'department' : department,
      'recipients' : recips.text.split(',')
                    .map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      'channel'    : channel,
      'enabled'    : existing?['enabled'] ?? true,
    };
    await AdminAlerts.save(rule);
    // Sync rules to backend so backend can evaluate on data arrival
    AdminAlerts.syncToBackend();
    await AdminAudit.log(
      action: existing == null
          ? AdminAudit.actAlertRuleAdd
          : AdminAudit.actSettingsChange,
      actor: _currentActor,
      targetName: rule['name'] as String,
      meta: {'trigger': trigger, 'plant': plant, 'department': department});
    await _loadAll();
    _toast(existing == null ? 'Rule added & synced to backend' : 'Rule updated & synced',
        const Color(0xFFE53935));
  }

  Future<void> _toggleAlertRule(Map<String, dynamic> r, bool enabled) async {
    final id = r['id']?.toString();
    if (id == null) return;
    await AdminAlerts.toggle(id, enabled);
    await _loadAll();
  }

  Future<void> _deleteAlertRule(Map<String, dynamic> r) async {
    final id = r['id']?.toString();
    if (id == null) return;
    final sl = SL.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete rule "${r['name']}"?',
            style: const TextStyle(color: AppColors.red, fontSize: 14,
                fontWeight: FontWeight.w800)),
        content: Text('This rule will no longer fire.',
            style: TextStyle(color: sl.text2, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete', style: TextStyle(color: Colors.white))),
        ]));
    if (ok != true) return;
    await AdminAlerts.delete(id);
    await AdminAudit.log(
      action: AdminAudit.actAlertRuleDel,
      actor: _currentActor,
      targetName: r['name']?.toString());
    await _loadAll();
    _toast('Rule deleted', AppColors.red);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 11 — BACKUP & RESTORE
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleBackupRestore(SL sl) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF5E35B1), Color(0xFF4527A0)]),
          borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.backup_rounded, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Text('Create Full Backup',
                style: TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Downloads a single JSON file containing incidents, users, KB, audit log, alert rules, and all custom lists. Save it somewhere safe.',
            style: TextStyle(color: Color(0xFFE9E5F5),
                fontSize: 11, height: 1.5)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _createBackup,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Download backup JSON'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF5E35B1),
                padding: const EdgeInsets.symmetric(vertical: 12),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))))),
        ])),

      const SizedBox(height: 14),

      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sl.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Backup will include:',
                style: TextStyle(color: sl.text2, fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _backupItem('${_incidents.length} incidents (with comments & assignments)',
                Icons.list_alt_rounded, AppColors.accent, sl),
            _backupItem('${_users.length} users',
                Icons.people_rounded, const Color(0xFF3949AB), sl),
            _backupItem('${_kbDocs.length} KB entries',
                Icons.menu_book_rounded, const Color(0xFF00897B), sl),
            _backupItem('${_auditLog.length} audit events',
                Icons.history_rounded, const Color(0xFF6D4C41), sl),
            _backupItem('${_alertRules.length} alert rules',
                Icons.notifications_active_rounded, const Color(0xFFE53935), sl),
            _backupItem('${_plantsEditable.length} plants · ${_deptsEditable.length} departments',
                Icons.factory_rounded, const Color(0xFF7E57C2), sl),
            _backupItem('Custom lists (WSA, severity, status, obs type)',
                Icons.tune_rounded, const Color(0xFF00ACC1), sl),
          ])),

      const SizedBox(height: 22),

      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.red.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.red.withOpacity(0.3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.restore_rounded, color: AppColors.red, size: 22),
            const SizedBox(width: 10),
            Text('Restore from Backup',
                style: TextStyle(color: sl.text1, fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          Text(
            '⚠ Restoring OVERWRITES current data. Always take a backup first.',
            style: TextStyle(color: sl.text2, fontSize: 11, height: 1.5)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _restoreBackup,
              icon: const Icon(Icons.upload_file_rounded, size: 16),
              label: const Text('Choose backup file'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))))),
        ])),
    ]);
  }

  Widget _backupItem(String text, IconData icon, Color color, SL sl) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 8),
        Expanded(child: Text(text,
            style: TextStyle(color: sl.text2, fontSize: 11))),
      ]));

  Future<void> _createBackup() async {
    final wsa  = await AdminMasterData.getWsaCauses();
    final sevs = await AdminMasterData.getSeverities();
    final sts  = await AdminMasterData.getStatuses();
    final obs  = await AdminMasterData.getObsTypes();
    final fullAudit = await AdminAudit.getLog();

    final payload = {
      'version'   : 1,
      'createdAt' : DateTime.now().toIso8601String(),
      'createdBy' : _currentActor,
      'app'       : 'SAIL Safety Lens V2',
      'incidents' : _incidents,
      'users'     : _users,
      'kb'        : _kbDocs,
      'audit'     : fullAudit,
      'alertRules': _alertRules,
      'plants'    : _plantsEditable,
      'depts'     : _deptsEditable,
      'wsa'       : wsa,
      'severities': sevs,
      'statuses'  : sts,
      'obsTypes'  : obs,
    };
    final s = const JsonEncoder.withIndent('  ').convert(payload);
    _downloadString(s, 'SafetyLens_Backup_${_todayIso()}.json');
    await AdminAudit.log(
      action: AdminAudit.actBackup,
      actor: _currentActor,
      meta: {
        'incidents': _incidents.length,
        'users': _users.length,
        'kb': _kbDocs.length,
      });
    _toast('Backup created', const Color(0xFF5E35B1));
  }

  Future<void> _restoreBackup() async {
    final sl = SL.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true);
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        _toast('Cannot read file contents', AppColors.red);
        return;
      }
      final text = utf8.decode(bytes);
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(text) as Map<String, dynamic>;
      } catch (e) {
        _toast('Invalid JSON: $e', AppColors.red);
        return;
      }
      if (payload['app'] != 'SAIL Safety Lens V2') {
        final cont = await showDialog<bool>(context: context, builder: (_) =>
          AlertDialog(
            backgroundColor: sl.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Text('Unrecognised format',
                style: TextStyle(color: AppColors.amber, fontSize: 14,
                    fontWeight: FontWeight.w800)),
            content: Text(
                'This file is not a Safety Lens backup (missing app marker). '
                'Continue anyway?',
                style: TextStyle(color: sl.text2, fontSize: 12)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue')),
            ]));
        if (cont != true) return;
      }

      int nInc = (payload['incidents'] is List)
          ? (payload['incidents'] as List).length : 0;
      int nUsr = (payload['users'] is List)
          ? (payload['users'] as List).length : 0;
      int nKb  = (payload['kb'] is List)
          ? (payload['kb'] as List).length : 0;
      final createdAt = payload['createdAt']?.toString() ?? '?';

      final ok = await showDialog<bool>(context: context, builder: (_) =>
        AlertDialog(
          backgroundColor: sl.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Restore from backup?',
              style: TextStyle(color: AppColors.red, fontSize: 14,
                  fontWeight: FontWeight.w800)),
          content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Created: $createdAt',
                  style: TextStyle(color: sl.text3, fontSize: 11)),
              const SizedBox(height: 6),
              Text('Will restore:',
                  style: TextStyle(color: sl.text2, fontSize: 11,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('• $nInc incidents\n• $nUsr users\n• $nKb KB entries',
                  style: TextStyle(color: sl.text1, fontSize: 11.5)),
              const SizedBox(height: 8),
              const Text(
                'Current data will be REPLACED. This cannot be undone unless '
                'you have another backup.',
                style: TextStyle(color: AppColors.red, fontSize: 10.5,
                    fontWeight: FontWeight.w700)),
            ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.red,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: const Text('Restore', style: TextStyle(color: Colors.white))),
          ]));
      if (ok != true) return;

      await _applyRestore(payload);
      await AdminAudit.log(
        action: AdminAudit.actRestore,
        actor: _currentActor,
        meta: {'incidents': nInc, 'users': nUsr, 'kb': nKb,
            'fromBackup': createdAt});
      await _loadAll();
      _toast('Restore complete: $nInc inc · $nUsr usr · $nKb kb',
          const Color(0xFF5E35B1));
    } catch (e) {
      _toast('Restore failed: $e', AppColors.red);
    }
  }

  Future<void> _applyRestore(Map<String, dynamic> p) async {
    if (p['incidents'] is List) {
      try {
        await LocalDB.replaceAllIncidents(
            (p['incidents'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList());
      } catch (_) {}
    }
    if (p['users'] is List) {
      try {
        await LocalDB.replaceAllUsers(
            (p['users'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList());
      } catch (_) {}
    }
    if (p['kb'] is List) {
      try {
        await LocalDB.replaceAllKnowledgeDocs(
            (p['kb'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList());
      } catch (_) {}
    }
    if (p['alertRules'] is List) {
      await AdminAlerts.clear();
      for (final r in (p['alertRules'] as List)) {
        await AdminAlerts.save(Map<String, dynamic>.from(r as Map));
      }
    }
    if (p['plants'] is List) {
      await AdminMasterData.savePlants(
          (p['plants'] as List)
              .map((e) => Map<String, String>.from(
                  (e as Map).map((k, v) =>
                      MapEntry(k.toString(), v.toString()))))
              .toList());
    }
    if (p['depts'] is List) {
      await AdminMasterData.saveDepartments(
          (p['depts'] as List).map((e) => e.toString()).toList());
    }
    if (p['wsa'] is List) {
      await AdminMasterData.saveWsaCauses(
          (p['wsa'] as List).map((e) => e.toString()).toList());
    }
    if (p['severities'] is List) {
      await AdminMasterData.saveSeverities(
          (p['severities'] as List).map((e) => e.toString()).toList());
    }
    if (p['statuses'] is List) {
      await AdminMasterData.saveStatuses(
          (p['statuses'] as List).map((e) => e.toString()).toList());
    }
    if (p['obsTypes'] is List) {
      await AdminMasterData.saveObsTypes(
          (p['obsTypes'] as List).map((e) => e.toString()).toList());
    }
    // NOTE: audit log NOT restored — preserves trail of who restored
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 12 — COMPLIANCE DASHBOARD
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleCompliance(SL sl) {
    final byPlant = <String, _PlantCompliance>{};
    for (final inc in _incidents) {
      final p = (inc['plant']?.toString() ?? '—').trim();
      byPlant.putIfAbsent(p, () => _PlantCompliance(p));
      final pc = byPlant[p]!;
      pc.total++;
      final sev = inc['severity']?.toString().toUpperCase() ?? '';
      final st  = inc['status']?.toString().toUpperCase() ?? '';
      if (sev == 'CRITICAL') pc.critical++;
      if (sev == 'HIGH')     pc.high++;
      if (st  == 'CLOSED')   pc.closed++;
      else                   pc.open++;
      if ((sev == 'CRITICAL' || sev == 'HIGH') && st != 'CLOSED') {
        final d = DateTime.tryParse(inc['date']?.toString() ?? '');
        if (d != null &&
            DateTime.now().difference(d).inDays > 7) {
          pc.staleHighCritical++;
        }
      }
      if (st == 'CLOSED') {
        final d1 = DateTime.tryParse(inc['date']?.toString() ?? '');
        final d2 = DateTime.tryParse(inc['closedAt']?.toString() ?? '');
        if (d1 != null && d2 != null) {
          final days = d2.difference(d1).inHours / 24;
          if (days >= 0 && days < 365) pc.mttrDays.add(days);
        }
      }
    }
    final rows = byPlant.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final filtered = _compliancePlantFilter == 'ALL' ? rows
        : rows.where((r) => r.plant == _compliancePlantFilter).toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      SizedBox(height: 28,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          _compChip('ALL', 'All', sl),
          for (final p in rows.map((r) => r.plant).take(15)) ...[
            const SizedBox(width: 5),
            _compChip(p, p, sl),
          ],
        ])),

      const SizedBox(height: 14),

      _sectionHeader('Plant Scorecards', sl),
      const SizedBox(height: 8),
      if (filtered.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: sl.card, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.border)),
          child: Center(child: Text('No data for this filter',
              style: TextStyle(color: sl.text4, fontSize: 11.5))))
      else
        ...filtered.map((pc) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _complianceCard(pc, sl))),

      const SizedBox(height: 16),

      _sectionHeader('Statutory Checklist — FA 1948 & IS 14489', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sl.border)),
        child: Column(children: [
          _complianceCheck('Section 21 — Fencing of machinery in place', true, sl),
          _complianceCheck('Section 28 — Hoists & lifts inspected (6-monthly)', null, sl),
          _complianceCheck('Section 29 — Lifting machines inspected (12-monthly)', null, sl),
          _complianceCheck('Section 31 — Pressure vessels certified', null, sl),
          _complianceCheck('Section 32(c) — Working at height controls', true, sl),
          _complianceCheck('Section 36 — Confined space PTW', null, sl),
          _complianceCheck('Section 38 — Fire-fighting capability', true, sl),
          _complianceCheck('Section 41B — On-Site Emergency Plan current', null, sl),
          _complianceCheck("Section 41H — Workers' right to warn", true, sl),
          _complianceCheck('IS 14489 — OHSAS gap analysis (annual)', null, sl),
        ])),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.amber.withOpacity(0.3))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline_rounded,
              color: AppColors.amber, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(
            'Checklist items are display-only for v5. Future versions will tie each item to inspection records and auto-update statuses.',
            style: TextStyle(color: sl.text3, fontSize: 10.5, height: 1.4))),
        ])),
    ]);
  }

  Widget _compChip(String value, String label, SL sl) {
    final active = _compliancePlantFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _compliancePlantFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2E7D32).withOpacity(0.14) : sl.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: active ? const Color(0xFF2E7D32) : sl.border,
              width: active ? 1.4 : 0.8)),
        child: Text(label, style: TextStyle(
            color: active ? const Color(0xFF2E7D32) : sl.text3,
            fontSize: 10, fontWeight: active ? FontWeight.w800 : FontWeight.w500))));
  }

  Widget _complianceCard(_PlantCompliance pc, SL sl) {
    final closureRate = pc.total == 0 ? 0.0 : pc.closed / pc.total;
    final score = (closureRate * 60) +
                  (pc.staleHighCritical == 0 ? 25 : math.max(0, 25 - pc.staleHighCritical * 5)) +
                  (pc.critical == 0 ? 15 : math.max(0, 15 - pc.critical));
    final scoreI = score.round().clamp(0, 100);
    final scoreColor = scoreI >= 80 ? AppColors.green
                     : scoreI >= 50 ? AppColors.amber
                     : AppColors.red;
    final avgMttr = pc.mttrDays.isEmpty ? 0
        : (pc.mttrDays.reduce((a, b) => a + b) / pc.mttrDays.length).round();

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scoreColor.withOpacity(0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(pc.plant,
              style: TextStyle(color: sl.text1, fontSize: 13,
                  fontWeight: FontWeight.w800))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: scoreColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scoreColor)),
            child: Text('Score $scoreI',
                style: TextStyle(color: scoreColor,
                    fontSize: 11, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 6, children: [
          _cmKpi('Total', '${pc.total}', sl.text2, sl),
          _cmKpi('Critical', '${pc.critical}', AppColors.crit, sl),
          _cmKpi('Open', '${pc.open}', AppColors.amber, sl),
          _cmKpi('Stale >7d', '${pc.staleHighCritical}',
              pc.staleHighCritical > 0 ? AppColors.red : AppColors.green, sl),
          _cmKpi('Closure', '${(closureRate * 100).round()}%',
              closureRate >= 0.8 ? AppColors.green
                : closureRate >= 0.5 ? AppColors.amber : AppColors.red, sl),
          _cmKpi('MTTR', avgMttr == 0 ? '—' : '${avgMttr}d',
              const Color(0xFF3949AB), sl),
        ]),
        if (pc.staleHighCritical > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(5)),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.red, size: 12),
              const SizedBox(width: 5),
              Expanded(child: Text(
                '${pc.staleHighCritical} HIGH/CRITICAL incident(s) open >7 days — escalate',
                style: const TextStyle(color: AppColors.red, fontSize: 10,
                    fontWeight: FontWeight.w700))),
            ])),
        ],
      ]));
  }

  Widget _cmKpi(String label, String value, Color color, SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(color: sl.text4, fontSize: 9.5)),
      Text(value, style: TextStyle(
          color: color, fontSize: 14, fontWeight: FontWeight.w800)),
    ]);

  Widget _complianceCheck(String label, bool? state, SL sl) {
    IconData icon;
    Color color;
    String status;
    if (state == true)  { icon = Icons.check_circle_rounded; color = AppColors.green;  status = 'OK'; }
    else if (state == false) { icon = Icons.cancel_rounded;  color = AppColors.red;    status = 'FAIL'; }
    else                { icon = Icons.help_outline_rounded; color = sl.text4;        status = 'TBD'; }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 8),
        Expanded(child: Text(label,
            style: TextStyle(color: sl.text2, fontSize: 11))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(3)),
          child: Text(status,
              style: TextStyle(color: color, fontSize: 9,
                  fontWeight: FontWeight.w800))),
      ]));
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 13: KNOWLEDGE BASE MANAGEMENT
  //  Upload PDF/DOCX, view entries, seed defaults, manage AI knowledge
  // ══════════════════════════════════════════════════════════════════

  Widget _moduleKnowledgeBase(SL sl) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      // Stats card
      FutureBuilder<Map<String, dynamic>>(
        future: KnowledgeService.getKbStats(),
        builder: (_, snap) {
          final stats = snap.data ?? {};
          return Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                const Color(0xFF1565C0).withOpacity(0.1),
                const Color(0xFF1565C0).withOpacity(0.03)]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF1565C0).withOpacity(0.3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.auto_stories_rounded, color: Color(0xFF1565C0), size: 20),
                const SizedBox(width: 8),
                Text('Knowledge Base Status', style: TextStyle(
                  color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _kbStatChip('Total Docs', '${stats['totalDocs'] ?? _kbDocs.length}', sl),
                const SizedBox(width: 10),
                _kbStatChip('Uploaded', '${stats['uploadedDocs'] ?? 0}', sl),
                const SizedBox(width: 10),
                _kbStatChip('Pre-loaded', '${stats['seededDocs'] ?? 0}', sl),
                const SizedBox(width: 10),
                _kbStatChip('~Tokens', '${stats['estimatedTokens'] ?? 0}', sl),
              ]),
              const SizedBox(height: 8),
              Text('Knowledge is shared across: AI Scan, Near Miss, Safety Chat',
                style: TextStyle(color: sl.text4, fontSize: 10)),
            ]),
          );
        },
      ),

      // Upload section
      _sectionHeader('Upload Knowledge Documents', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Upload PDF or Word documents containing safety knowledge. '
               'Text will be extracted and made available to AI across all sections.',
            style: TextStyle(color: sl.text3, fontSize: 11, height: 1.4)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _kbUploadBtn(
              'Upload PDF', Icons.picture_as_pdf_rounded,
              const Color(0xFFD32F2F), () => _uploadKbDocument('pdf'), sl)),
            const SizedBox(width: 10),
            Expanded(child: _kbUploadBtn(
              'Upload DOCX', Icons.description_rounded,
              const Color(0xFF1565C0), () => _uploadKbDocument('docx'), sl)),
          ]),
          const SizedBox(height: 10),
          _kbUploadBtn(
            'Add Text Entry Manually', Icons.edit_note_rounded,
            const Color(0xFF43A047), () => _addKbTextEntry(sl), sl),
          if (_kbUploading) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _kbUploadTotal > 0 ? _kbUploadProgress / _kbUploadTotal : null,
              backgroundColor: sl.border,
              color: const Color(0xFF1565C0)),
            const SizedBox(height: 6),
            Text(_kbUploadStatus,
              style: TextStyle(color: sl.text3, fontSize: 10, fontStyle: FontStyle.italic)),
          ],
        ]),
      ),
      const SizedBox(height: 16),

      // Seed defaults
      _sectionHeader('Pre-loaded Knowledge', sl),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Seed the default safety knowledge base (Factories Act 1948, '
               'State Rules, BIS standards). This creates ${KbSeedData.entries.length} entries.',
            style: TextStyle(color: sl.text3, fontSize: 11, height: 1.4)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: _seedKbDefaults,
              icon: const Icon(Icons.auto_fix_high_rounded, size: 15, color: Colors.white),
              label: const Text('Seed Default KB',
                style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7E57C2),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            )),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(
              onPressed: _clearAllKb,
              icon: Icon(Icons.delete_sweep_rounded, size: 15, color: AppColors.red),
              label: Text('Clear All KB',
                style: TextStyle(color: AppColors.red, fontSize: 11, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                side: BorderSide(color: AppColors.red.withOpacity(0.5)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            )),
          ]),
        ]),
      ),
      const SizedBox(height: 16),

      // KB entries list
      _sectionHeader('Knowledge Entries (${_kbDocs.length})', sl),
      const SizedBox(height: 8),
      if (_kbDocs.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: sl.card, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.border)),
          child: Center(child: Text('No knowledge entries yet. Upload a document or seed defaults.',
            style: TextStyle(color: sl.text4, fontSize: 11))),
        )
      else
        ...(_kbDocs.take(50).toList().asMap().entries.map((entry) {
          final doc = entry.value;
          final title = doc['title']?.toString() ?? 'Untitled';
          final source = doc['source']?.toString() ?? '';
          final content = doc['content']?.toString() ?? '';
          final uploadedAt = doc['uploadedAt']?.toString() ?? '';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: sl.card, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sl.border.withOpacity(0.5))),
            child: Row(children: [
              Icon(
                source.contains('pdf') ? Icons.picture_as_pdf_rounded
                  : source.contains('docx') ? Icons.description_rounded
                  : Icons.article_rounded,
                size: 16, color: const Color(0xFF1565C0).withOpacity(0.7)),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: sl.text1, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${content.length} chars • $source${uploadedAt.isNotEmpty ? ' • ${uploadedAt.split('T').first}' : ''}',
                    style: TextStyle(color: sl.text4, fontSize: 9.5)),
                ])),
              GestureDetector(
                onTap: () => _deleteKbEntry(doc['id']?.toString() ?? ''),
                child: Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.red.withOpacity(0.6))),
            ]),
          );
        })),
      if (_kbDocs.length > 50)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('+ ${_kbDocs.length - 50} more entries...',
            style: TextStyle(color: sl.text4, fontSize: 10))),
      const SizedBox(height: 20),
    ]);
  }

  Widget _kbStatChip(String label, String value, SL sl) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: sl.isDark ? Colors.white10 : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text(value, style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w800)),
        Text(label, style: TextStyle(color: sl.text4, fontSize: 9)),
      ]),
    ));
  }

  Widget _kbUploadBtn(String label, IconData icon, Color color, VoidCallback onTap, SL sl) {
    return GestureDetector(
      onTap: _kbUploading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _uploadKbDocument(String type) async {
    try {
      final allowedExt = type == 'pdf' ? ['pdf'] : ['docx', 'doc'];
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowedExt,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        _toast('Cannot read file', AppColors.red);
        return;
      }
      final fileName = file.name;

      setState(() {
        _kbUploading = true;
        _kbUploadStatus = 'Extracting text from $fileName...';
        _kbUploadProgress = 0;
        _kbUploadTotal = 1;
      });

      String extractedText = '';

      if (type == 'pdf') {
        // Extract text from PDF
        try {
          extractedText = await PdfKbExtractor.extractTextFromPdf(bytes);
        } catch (e) {
          setState(() { _kbUploading = false; });
          _toast('PDF extraction failed: $e', AppColors.red);
          return;
        }
      } else {
        // For DOCX — extract plain text (basic approach)
        try {
          // DOCX is a ZIP containing XML. Extract text from word/document.xml
          extractedText = _extractTextFromDocxBytes(bytes);
        } catch (e) {
          setState(() { _kbUploading = false; });
          _toast('DOCX extraction failed: $e', AppColors.red);
          return;
        }
      }

      if (extractedText.trim().isEmpty) {
        setState(() { _kbUploading = false; });
        _toast('No text found in document. It may be image-based.', AppColors.amber);
        return;
      }

      setState(() => _kbUploadStatus = 'Processing ${extractedText.length} chars...');

      // Split into manageable chunks and save as KB entries
      final chunks = _chunkTextForKb(extractedText, fileName);
      setState(() { _kbUploadTotal = chunks.length; });

      for (int i = 0; i < chunks.length; i++) {
        setState(() {
          _kbUploadProgress = i + 1;
          _kbUploadStatus = 'Saving section ${i + 1} of ${chunks.length}...';
        });
        await LocalDB.addKnowledgeDoc(
          title: '$fileName — Section ${i + 1}',
          content: chunks[i],
          source: '${type}_upload',
        );
      }

      // Refresh KB docs
      final updatedDocs = await LocalDB.getKnowledgeDocs();
      setState(() {
        _kbDocs = updatedDocs;
        _kbUploading = false;
        _kbUploadStatus = '';
      });
      _toast('Uploaded: $fileName (${chunks.length} sections, ${extractedText.length} chars)', const Color(0xFF43A047));
      AdminAudit.log(action: 'kb_upload', actor: _currentActor,
          meta: {'file': fileName, 'type': type, 'sections': chunks.length, 'chars': extractedText.length});
      // ★ v25: Push KB to cloud so all devices get it
      SyncService.pushKbDocs(updatedDocs).then((ok) {
        if (ok && mounted) _toast('KB synced to cloud ✓', const Color(0xFF1565C0));
      });
    } catch (e) {
      setState(() { _kbUploading = false; });
      _toast('Upload failed: $e', AppColors.red);
    }
  }

  /// Basic DOCX text extraction — reads paragraph text from the XML
  String _extractTextFromDocxBytes(dynamic bytes) {
    // DOCX is a ZIP. On web, we can use dart:convert and basic decompression.
    // For a simpler approach: try to find readable text content in the raw bytes.
    try {
      final text = String.fromCharCodes(bytes as List<int>);
      // Extract text between <w:t> tags (Word XML paragraphs)
      final regex = RegExp(r'<w:t[^>]*>([^<]+)</w:t>');
      final matches = regex.allMatches(text);
      if (matches.isNotEmpty) {
        return matches.map((m) => m.group(1) ?? '').join(' ');
      }
      // Fallback: extract any readable ASCII content
      final buffer = StringBuffer();
      for (final char in text.codeUnits) {
        if (char >= 32 && char <= 126) buffer.writeCharCode(char);
        else if (char == 10 || char == 13) buffer.write(' ');
      }
      return buffer.toString().replaceAll(RegExp(r'\s{3,}'), '\n');
    } catch (_) {
      return '';
    }
  }

  List<String> _chunkTextForKb(String text, String fileName) {
    const chunkSize = 2500; // ~625 tokens per chunk — manageable for context
    final chunks = <String>[];
    final cleanText = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    int start = 0;
    while (start < cleanText.length) {
      int end = (start + chunkSize).clamp(0, cleanText.length);
      // Try to break at sentence boundary
      if (end < cleanText.length) {
        final sentEnd = cleanText.lastIndexOf('.', end);
        if (sentEnd > start + 500) end = sentEnd + 1;
      }
      final chunk = cleanText.substring(start, end).trim();
      if (chunk.length > 50) chunks.add(chunk); // Skip tiny fragments
      start = end;
    }
    return chunks.isEmpty ? [cleanText] : chunks;
  }

  Future<void> _addKbTextEntry(SL sl) async {
    final titleCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final result = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Add Knowledge Entry', style: TextStyle(color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
        content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: titleCtrl,
            style: TextStyle(color: sl.text1, fontSize: 12),
            decoration: InputDecoration(
              labelText: 'Title (e.g. "Height Safety SOP")',
              labelStyle: TextStyle(color: sl.text3, fontSize: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: contentCtrl,
            maxLines: 8,
            style: TextStyle(color: sl.text1, fontSize: 12),
            decoration: InputDecoration(
              labelText: 'Content (paste safety knowledge text)',
              labelStyle: TextStyle(color: sl.text3, fontSize: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0)),
            child: const Text('Add', style: TextStyle(color: Colors.white))),
        ],
      ));
    if (result == true && titleCtrl.text.trim().isNotEmpty && contentCtrl.text.trim().isNotEmpty) {
      await LocalDB.addKnowledgeDoc(
        title: titleCtrl.text.trim(),
        content: contentCtrl.text.trim(),
        source: 'manual_entry',
      );
      final updatedDocs = await LocalDB.getKnowledgeDocs();
      setState(() => _kbDocs = updatedDocs);
      _toast('Knowledge entry added', const Color(0xFF43A047));
      AdminAudit.log(action: 'kb_add_manual', actor: _currentActor,
          meta: {'title': titleCtrl.text.trim()});
      // ★ v25: Push to cloud
      SyncService.pushKbDocs(updatedDocs);
    }
  }

  Future<void> _seedKbDefaults() async {
    final count = await LocalDB.seedKnowledgeBase(replace: false);
    final updatedDocs = await LocalDB.getKnowledgeDocs();
    setState(() => _kbDocs = updatedDocs);
    _toast('Seeded $count default entries', const Color(0xFF7E57C2));
    AdminAudit.log(action: 'kb_seed_defaults', actor: _currentActor,
        meta: {'count': count});
    // ★ v25: Push to cloud
    SyncService.pushKbDocs(updatedDocs);
  }

  Future<void> _clearAllKb() async {
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(
        title: const Text('Clear Knowledge Base?',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        content: const Text('This will delete ALL knowledge entries (uploaded + seeded). Cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red),
            child: const Text('Clear All', style: TextStyle(color: Colors.white))),
        ],
      ));
    if (ok == true) {
      await LocalDB.replaceAllKnowledgeDocs([]);
      setState(() => _kbDocs = []);
      _toast('Knowledge base cleared', AppColors.red);
      AdminAudit.log(action: 'kb_clear_all', actor: _currentActor);
    }
  }

  Future<void> _deleteKbEntry(String id) async {
    if (id.isEmpty) return;
    await LocalDB.deleteKnowledgeDoc(id);
    final updatedDocs = await LocalDB.getKnowledgeDocs();
    setState(() => _kbDocs = updatedDocs);
    _toast('Entry removed', AppColors.amber);
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 14: AI AUDIT — Cross-Model Comparison Dashboard
  // ══════════════════════════════════════════════════════════════════
  Widget _moduleAiAudit(SL sl) {
    // Filter incidents that have audit data
    final audited = _incidents
        .where((i) => i['auditStatus'] != null && i['auditStatus'].toString().isNotEmpty)
        .toList();
    final needsReview = audited.where((i) => i['auditStatus'] == 'NEEDS_REVIEW').toList();
    final verified = audited.where((i) => i['auditStatus'] == 'VERIFIED').toList();
    final avgScore = audited.isNotEmpty
        ? audited.map((i) => (i['auditScore'] as num?)?.toDouble() ?? 0).reduce((a, b) => a + b) / audited.length
        : 0.0;

    return ListView(padding: const EdgeInsets.all(16), children: [
      // ── Summary Stats ──
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: sl.glassColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.glassBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.compare_arrows_rounded, color: Color(0xFFD32F2F), size: 20),
            const SizedBox(width: 8),
            Text('AI Audit Overview', style: TextStyle(
                color: sl.text1, fontSize: 15, fontWeight: FontWeight.w800)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withOpacity(0.12),
                borderRadius: BorderRadius.circular(6)),
              child: Text('Primary: Groq Scout  |  Secondary: Nemotron 30B',
                  style: TextStyle(color: const Color(0xFF1565C0), fontSize: 9, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _auditStatCard(sl, 'Total Audited', '${audited.length}',
                Icons.fact_check_outlined, const Color(0xFF1E88E5)),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'Verified', '${verified.length}',
                Icons.verified_outlined, const Color(0xFF43A047)),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'Needs Review', '${needsReview.length}',
                Icons.rate_review_outlined, const Color(0xFFD32F2F)),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'Avg Match', '${avgScore.toStringAsFixed(0)}%',
                Icons.percent_rounded, const Color(0xFF7E57C2)),
          ]),
        ]),
      ),
      const SizedBox(height: 16),

      // ── Flagged Incidents (Needs Review) ──
      if (needsReview.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFD32F2F).withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD32F2F).withOpacity(0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFD32F2F), size: 16),
              const SizedBox(width: 6),
              Text('Discrepancies Found (${needsReview.length})',
                  style: const TextStyle(color: Color(0xFFD32F2F), fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            ...needsReview.map((inc) => _auditComparisonCard(sl, inc, isDiscrepancy: true)),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // ── All Audited Incidents ──
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.glassColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.glassBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.list_alt_rounded, color: sl.text2, size: 16),
            const SizedBox(width: 6),
            Text('All Audited Scans (${audited.length})',
                style: TextStyle(color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          if (audited.isEmpty)
            Center(child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(children: [
                Icon(Icons.pending_outlined, color: sl.text4, size: 40),
                const SizedBox(height: 10),
                Text('No audits yet', style: TextStyle(color: sl.text3, fontSize: 12)),
                const SizedBox(height: 4),
                Text('Audits run automatically after each AI scan save',
                    style: TextStyle(color: sl.text4, fontSize: 10)),
              ]),
            ))
          else
            ...audited.map((inc) => _auditComparisonCard(sl, inc)),
        ]),
      ),
    ]);
  }

  Widget _auditStatCard(SL sl, String label, String value, IconData icon, Color color) {
    return Expanded(child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(
            color: color, fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: sl.text3, fontSize: 9),
            textAlign: TextAlign.center),
      ]),
    ));
  }

  Widget _auditComparisonCard(SL sl, Map<String, dynamic> inc, {bool isDiscrepancy = false}) {
    final title = inc['title']?.toString() ?? 'Untitled';
    final score = (inc['auditScore'] as num?)?.toInt() ?? 0;
    final status = inc['auditStatus']?.toString() ?? '';
    final auditModel = inc['auditModel']?.toString() ?? 'Unknown';
    final timestamp = inc['auditTimestamp']?.toString() ?? '';
    final notes = inc['auditNotes']?.toString() ?? '';
    final origCount = (inc['originalHazardCount'] as num?)?.toInt() ?? 0;
    final auditCount = (inc['auditHazardCount'] as num?)?.toInt() ?? 0;

    // Parse hazard name lists for detailed comparison
    List<String> origNames = [];
    List<String> auditNames = [];
    try {
      final origJson = inc['originalHazardNames']?.toString() ?? '[]';
      final auditJson = inc['auditHazardNames']?.toString() ?? '[]';
      origNames = (jsonDecode(origJson) as List).map((e) => e.toString()).toList();
      auditNames = (jsonDecode(auditJson) as List).map((e) => e.toString()).toList();
    } catch (_) {}

    final Color scoreColor = score >= 95
        ? const Color(0xFF43A047)
        : score >= 70
            ? AppColors.amber
            : const Color(0xFFD32F2F);

    final dateStr = timestamp.length >= 16 ? timestamp.substring(0, 16).replaceAll('T', ' ') : timestamp;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDiscrepancy
            ? const Color(0xFFD32F2F).withOpacity(0.3)
            : sl.glassBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header: title + score
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(
              color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scoreColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scoreColor.withOpacity(0.4)),
            ),
            child: Text('$score% match', style: TextStyle(
                color: scoreColor, fontSize: 10, fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 8),

        // Comparison: Original vs Audit
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Original model column
          Expanded(child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E88E5).withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1E88E5).withOpacity(0.15)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.psychology_outlined, color: Color(0xFF1E88E5), size: 12),
                const SizedBox(width: 4),
                Text('Nemotron 30B (Primary)', style: TextStyle(
                    color: const Color(0xFF1E88E5), fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              Text('$origCount hazard${origCount != 1 ? 's' : ''} found',
                  style: TextStyle(color: sl.text2, fontSize: 10, fontWeight: FontWeight.w600)),
              if (origNames.isNotEmpty) ...[
                const SizedBox(height: 4),
                ...origNames.take(5).map((n) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(children: [
                    Container(width: 4, height: 4, decoration: const BoxDecoration(
                        color: Color(0xFF1E88E5), shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Expanded(child: Text(n, style: TextStyle(
                        color: sl.text3, fontSize: 9), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                )),
                if (origNames.length > 5)
                  Text('+${origNames.length - 5} more', style: TextStyle(
                      color: sl.text4, fontSize: 8, fontStyle: FontStyle.italic)),
              ],
            ]),
          )),
          const SizedBox(width: 8),
          // Audit model column
          Expanded(child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFD32F2F).withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD32F2F).withOpacity(0.15)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.compare_arrows_rounded, color: Color(0xFFD32F2F), size: 12),
                const SizedBox(width: 4),
                Text('Groq Scout (Audit)', style: TextStyle(
                    color: const Color(0xFFD32F2F), fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              Text('$auditCount hazard${auditCount != 1 ? 's' : ''} found',
                  style: TextStyle(color: sl.text2, fontSize: 10, fontWeight: FontWeight.w600)),
              if (auditNames.isNotEmpty) ...[
                const SizedBox(height: 4),
                ...auditNames.take(5).map((n) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(children: [
                    Container(width: 4, height: 4, decoration: const BoxDecoration(
                        color: Color(0xFFD32F2F), shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Expanded(child: Text(n, style: TextStyle(
                        color: sl.text3, fontSize: 9), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                )),
                if (auditNames.length > 5)
                  Text('+${auditNames.length - 5} more', style: TextStyle(
                      color: sl.text4, fontSize: 8, fontStyle: FontStyle.italic)),
              ],
            ]),
          )),
        ]),
        const SizedBox(height: 8),

        // Notes (if discrepancy)
        if (isDiscrepancy && notes.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.amber.withOpacity(0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 11),
                SizedBox(width: 4),
                Text('Discrepancy Notes', style: TextStyle(
                    color: AppColors.amber, fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 4),
              Text(notes, style: TextStyle(color: sl.text3, fontSize: 9, height: 1.4),
                  maxLines: 8, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(height: 6),
        ],

        // Footer: timestamp + model
        Row(children: [
          Icon(Icons.access_time_rounded, color: sl.text4, size: 10),
          const SizedBox(width: 3),
          Text(dateStr, style: TextStyle(color: sl.text4, fontSize: 9)),
          const Spacer(),
          Text(auditModel, style: TextStyle(color: sl.text4, fontSize: 9)),
        ]),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  MODULE 15 — AI CORRECTIONS (trust-building feedback loop)
  //  Shows every user edit to AI output. Admin classifies each as an
  //  "AI mistake" (→ fed into fine-tuning data so accuracy improves) or a
  //  "User preference" (no training impact). Pulls from Supabase + local.
  // ══════════════════════════════════════════════════════════════════
  Future<void> _loadCorrections() async {
    if (_correctionsLoading) return;
    setState(() => _correctionsLoading = true);
    try {
      final list = await AiCorrectionService.getAllCorrections();
      if (mounted) setState(() => _corrections = list);
    } catch (_) {
    } finally {
      if (mounted) setState(() {
        _correctionsLoading = false;
        _correctionsLoadedOnce = true;
      });
    }
  }

  Widget _moduleAiCorrections(SL sl) {
    // Lazy-load on first open only. Guarding on _correctionsLoadedOnce prevents
    // an infinite reload loop when the correction list is legitimately empty
    // (isEmpty would otherwise re-trigger the load on every rebuild).
    if (!_correctionsLoadedOnce && !_correctionsLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadCorrections());
    }

    final stats = AiCorrectionService.computeStats(_corrections);
    final filtered = _corrFilter == 'all'
        ? _corrections
        : _corrections
            .where((c) => (c['verdict']?.toString() ?? 'pending') == _corrFilter)
            .toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      // ── Header + stats ──
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: sl.glassColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.glassBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.model_training_rounded, color: Color(0xFF00838F), size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('AI Corrections & Training', style: TextStyle(
                color: sl.text1, fontSize: 15, fontWeight: FontWeight.w800))),
            IconButton(
              onPressed: _correctionsLoading ? null : _loadCorrections,
              icon: _correctionsLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.refresh_rounded, color: sl.text2, size: 20),
              tooltip: 'Refresh',
            ),
          ]),
          const SizedBox(height: 4),
          Text('When a user edits the AI\'s summary, severity or corrective action, '
              'it lands here. Mark real errors as "AI mistake" to feed them into the '
              'training set — the model keeps getting more accurate.',
              style: TextStyle(color: sl.text3, fontSize: 10, height: 1.4)),
          const SizedBox(height: 16),
          Row(children: [
            _auditStatCard(sl, 'Total Edits', '${stats['total']}',
                Icons.edit_note_rounded, const Color(0xFF1E88E5)),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'Pending', '${stats['pending']}',
                Icons.pending_actions_rounded, AppColors.amber),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'AI Mistakes', '${stats['aiMistake']}',
                Icons.error_outline_rounded, const Color(0xFFD32F2F)),
            const SizedBox(width: 10),
            _auditStatCard(sl, 'In Training', '${stats['addedToTraining']}',
                Icons.school_outlined, const Color(0xFF43A047)),
          ]),
          const SizedBox(height: 12),
          // AI mistake rate + most-wrong field.
          Row(children: [
            Expanded(child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.percent_rounded, color: Color(0xFFD32F2F), size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text('AI mistake rate (of reviewed): '
                    '${(stats['aiMistakeRate'] as double).toStringAsFixed(0)}%',
                    style: TextStyle(color: sl.text2, fontSize: 10, fontWeight: FontWeight.w600))),
              ]),
            )),
            const SizedBox(width: 8),
            Expanded(child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF7E57C2).withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.leaderboard_rounded, color: Color(0xFF7E57C2), size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text('Most-wrong field: ${_fieldLabel(stats['topMistakeField']?.toString() ?? '—')}',
                    style: TextStyle(color: sl.text2, fontSize: 10, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            )),
          ]),
        ]),
      ),
      const SizedBox(height: 12),

      // ── Filter chips ──
      Row(children: [
        _corrFilterChip(sl, 'pending', 'Pending', stats['pending'] as int),
        const SizedBox(width: 8),
        _corrFilterChip(sl, 'ai_mistake', 'AI Mistakes', stats['aiMistake'] as int),
        const SizedBox(width: 8),
        _corrFilterChip(sl, 'user_preference', 'Preferences', stats['userPreference'] as int),
        const SizedBox(width: 8),
        _corrFilterChip(sl, 'all', 'All', stats['total'] as int),
      ]),
      const SizedBox(height: 12),

      // ── Correction cards ──
      if (_correctionsLoading && _corrections.isEmpty)
        const Center(child: Padding(
          padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
      else if (filtered.isEmpty)
        Center(child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(children: [
            Icon(Icons.check_circle_outline_rounded, color: sl.text4, size: 44),
            const SizedBox(height: 10),
            Text(_corrFilter == 'pending' ? 'No edits waiting for review' : 'Nothing here',
                style: TextStyle(color: sl.text3, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Edits users make to AI output will appear here',
                style: TextStyle(color: sl.text4, fontSize: 10), textAlign: TextAlign.center),
          ]),
        ))
      else
        ...filtered.map((c) => _correctionCard(sl, c)),
    ]);
  }

  Widget _corrFilterChip(SL sl, String value, String label, int count) {
    final selected = _corrFilter == value;
    const accent = Color(0xFF00838F);
    return Expanded(child: GestureDetector(
      onTap: () => setState(() => _corrFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? accent.withOpacity(0.15) : sl.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? accent : sl.glassBorder,
              width: selected ? 1.5 : 1),
        ),
        child: Column(children: [
          Text('$count', style: TextStyle(
              color: selected ? accent : sl.text2,
              fontSize: 14, fontWeight: FontWeight.w900)),
          Text(label, style: TextStyle(
              color: selected ? accent : sl.text3,
              fontSize: 8, fontWeight: FontWeight.w700),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ));
  }

  String _fieldLabel(String field) {
    switch (field) {
      case 'summary':          return 'Summary';
      case 'overallRisk':      return 'Overall severity';
      case 'severity':         return 'Severity';
      case 'hazardSeverity':   return 'Hazard severity';
      case 'correctiveAction': return 'Corrective action';
      case 'hazardDeleted':    return 'Hazard removed (false positive)';
      case 'hazardAdded':      return 'Hazard added (AI missed)';
      default:                 return field.isEmpty ? '—' : field;
    }
  }

  Widget _correctionCard(SL sl, Map<String, dynamic> c) {
    final verdict = c['verdict']?.toString() ?? 'pending';
    final field = c['fieldChanged']?.toString() ?? '';
    final hazardName = c['hazardName']?.toString() ?? '';
    final original = c['originalValue']?.toString() ?? '';
    final edited = c['editedValue']?.toString() ?? '';
    final editedBy = c['editedBy']?.toString() ?? '';
    final aiSource = c['aiSource']?.toString() ?? '';
    final type = c['incidentType']?.toString() ?? '';
    final addedToTraining = c['addedToTraining'] == true;
    final createdAt = c['createdAt']?.toString() ?? '';
    final dateStr = createdAt.length >= 16
        ? createdAt.substring(0, 16).replaceAll('T', ' ') : createdAt;

    final Color vColor = verdict == 'ai_mistake'
        ? const Color(0xFFD32F2F)
        : verdict == 'user_preference'
            ? const Color(0xFF43A047)
            : AppColors.amber;
    final String vLabel = verdict == 'ai_mistake'
        ? 'AI Mistake'
        : verdict == 'user_preference' ? 'User Preference' : 'Pending';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: verdict == 'pending'
            ? AppColors.amber.withOpacity(0.3) : sl.glassBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header: field + verdict badge
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF00838F).withOpacity(0.1),
              borderRadius: BorderRadius.circular(6)),
            child: Text(_fieldLabel(field), style: const TextStyle(
                color: Color(0xFF00838F), fontSize: 10, fontWeight: FontWeight.w800)),
          ),
          if (type.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(type == 'NEAR_MISS' ? 'Near miss' : 'Hazard scan',
                style: TextStyle(color: sl.text4, fontSize: 9)),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: vColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: vColor.withOpacity(0.4))),
            child: Text(vLabel, style: TextStyle(
                color: vColor, fontSize: 9, fontWeight: FontWeight.w800)),
          ),
        ]),
        if (hazardName.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Hazard: $hazardName', style: TextStyle(
              color: sl.text2, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 8),

        // Original (AI) vs Edited (user). Hazard add/remove read differently
        // from a field edit, so give them plain-language boxes.
        if (field == 'hazardDeleted')
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _corrValueBox(sl, 'AI flagged', original,
                const Color(0xFFD32F2F))),
            const SizedBox(width: 8),
            Expanded(child: _corrValueBox(sl, 'User verdict',
                'Not present in image — removed', const Color(0xFF43A047))),
          ])
        else if (field == 'hazardAdded')
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _corrValueBox(sl, 'AI missed',
                'Not detected', const Color(0xFFD32F2F))),
            const SizedBox(width: 8),
            Expanded(child: _corrValueBox(sl, 'User added', edited,
                const Color(0xFF43A047))),
          ])
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _corrValueBox(sl, 'AI produced', original,
                const Color(0xFFD32F2F))),
            const SizedBox(width: 8),
            Expanded(child: _corrValueBox(sl, 'User changed to', edited,
                const Color(0xFF43A047))),
          ]),
        const SizedBox(height: 8),

        // Meta row
        Row(children: [
          Icon(Icons.person_outline_rounded, color: sl.text4, size: 11),
          const SizedBox(width: 3),
          Expanded(child: Text(
              editedBy.isEmpty ? 'Unknown user' : editedBy,
              style: TextStyle(color: sl.text4, fontSize: 9),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (aiSource.isNotEmpty) ...[
            Icon(Icons.smart_toy_outlined, color: sl.text4, size: 11),
            const SizedBox(width: 3),
            Text(aiSource, style: TextStyle(color: sl.text4, fontSize: 9)),
            const SizedBox(width: 8),
          ],
          Text(dateStr, style: TextStyle(color: sl.text4, fontSize: 9)),
        ]),

        // Actions / verdict result
        if (verdict == 'pending') ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: () => _classifyCorrection(c, aiMistake: true),
              icon: const Icon(Icons.error_outline_rounded, size: 14, color: Colors.white),
              label: const Text('AI mistake', style: TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: () => _classifyCorrection(c, aiMistake: false),
              icon: const Icon(Icons.thumb_up_alt_outlined, size: 13, color: Color(0xFF43A047)),
              label: const Text('User preference', style: TextStyle(
                  color: Color(0xFF43A047), fontSize: 11, fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF43A047), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
          ]),
        ] else if (verdict == 'ai_mistake') ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (addedToTraining ? const Color(0xFF43A047) : sl.text4).withOpacity(0.08),
              borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Icon(addedToTraining ? Icons.school_rounded : Icons.info_outline_rounded,
                  color: addedToTraining ? const Color(0xFF43A047) : sl.text3, size: 12),
              const SizedBox(width: 6),
              Expanded(child: Text(
                  addedToTraining
                      ? 'Added to fine-tuning dataset — will improve the next model export.'
                      : 'Marked as AI mistake. (No evidence image was available to add to training.)',
                  style: TextStyle(color: sl.text3, fontSize: 9, height: 1.3))),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _corrValueBox(SL sl, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(
            color: color, fontSize: 9, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(value.isEmpty ? '(empty)' : value, style: TextStyle(
            color: value.isEmpty ? sl.text4 : sl.text2, fontSize: 10, height: 1.35),
            maxLines: 8, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Future<void> _classifyCorrection(
      Map<String, dynamic> c, {required bool aiMistake}) async {
    if (!aiMistake) {
      await AiCorrectionService.markUserPreference(c, reviewedBy: _currentActor);
      await AdminAudit.log(
        action: 'ai_correction_user_pref', actor: _currentActor,
        target: c['id']?.toString() ?? '');
      _toast('Marked as user preference', const Color(0xFF43A047));
      await _loadCorrections();
      return;
    }

    // AI mistake → try to attach the evidence image so it becomes a useful
    // vision training example, then push into the fine-tuning collector.
    String imageBase64 = '';
    final incidentId = c['incidentId']?.toString() ?? '';
    if (incidentId.isNotEmpty) {
      final inc = _incidents.firstWhere(
        (i) => i['id']?.toString() == incidentId,
        orElse: () => <String, dynamic>{});
      if (inc.isNotEmpty) {
        try {
          final bytes = await ImageStorage.getImageForIncident(inc);
          if (bytes != null && bytes.isNotEmpty) {
            imageBase64 = base64Encode(bytes);
          }
        } catch (_) {}
      }
    }

    await AiCorrectionService.markAiMistake(c,
        reviewedBy: _currentActor, imageBase64: imageBase64);
    await AdminAudit.log(
      action: 'ai_correction_ai_mistake', actor: _currentActor,
      target: c['id']?.toString() ?? '');
    _toast(
      imageBase64.isEmpty
          ? 'Marked as AI mistake (no image to train on)'
          : 'AI mistake → added to training data ✓',
      const Color(0xFFD32F2F));
    await _loadCorrections();
  }
}

// ── Helper data class for compliance dashboard ──────────────────────
class _PlantCompliance {
  final String plant;
  int total = 0;
  int critical = 0;
  int high = 0;
  int closed = 0;
  int open = 0;
  int staleHighCritical = 0;
  final List<double> mttrDays = [];
  _PlantCompliance(this.plant);
}

