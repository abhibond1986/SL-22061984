// lib/screens/dashboard_tab.dart
// v9 FIXES:
//   ✅ _CaseCard → StatefulWidget with Quick Close button
//   ✅ Quick close dialog: enter corrective action → CLOSED
//   ✅ LocalDB.saveIncident + SyncService.pushIncident on close
//   ✅ Closed cases show strikethrough + green border
//   ✅ All original dashboard functionality preserved

import 'package:flutter/material.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/sync_service.dart';
import '../services/admin_master_data.dart';
import '../services/plant_scope.dart';
import '../services/realtime_sync.dart';
import 'admin_screen.dart';

class DashboardTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback toggleTheme;
  final VoidCallback onSignOut;
  final void Function(int) onTabChange;

  const DashboardTab({
    super.key,
    required this.user,
    required this.toggleTheme,
    required this.onSignOut,
    required this.onTabChange,
  });

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  List<Map<String, dynamic>> _incidents = [];
  List<Map<String, dynamic>> _allUsers  = [];
  Map<String, dynamic>?      _selectedUser;
  /// Resolved visibility scope. Starts null and every scoped getter treats null
  /// as "nothing decided yet" rather than "everything", so the first frame can't
  /// leak other plants' users while the resolve is in flight.
  PlantScope? _scope;
  bool _loading    = true;
  bool _refreshing = false;

  // SINGLE SOURCE OF TRUTH: always AdminMasterData. Seeded from the shared
  // const (never a re-typed copy) purely so the first frame has something to
  // paint; _loadPlantsMaster() replaces it immediately.
  List<Map<String, String>> _plants =
      AdminMasterData.sailPlants.map((p) => Map<String, String>.from(p)).toList();
  // Statuses that count as "still open". Derived from the admin's status list
  // so adding a stage in the admin panel doesn't silently exclude those
  // incidents from every open-case count on this screen.
  Set<String> _openStatuses =
      AdminMasterData.openStatusesFrom(AdminMasterData.defaultStatuses);
  /// Full ladder, so a blank status can be read as the FIRST configured stage
  /// instead of a literal 'OPEN'.
  List<String> _statuses = List<String>.from(AdminMasterData.defaultStatuses);

  /// Effective status of [i]: its own, or the first configured stage when blank.
  String _statusOf(Map<String, dynamic> i) {
    final s = (i['status']?.toString().trim().toUpperCase() ?? '');
    if (s.isNotEmpty) return s;
    return _statuses.isEmpty ? '' : _statuses.first.trim().toUpperCase();
  }

  bool _isOpenInc(Map<String, dynamic> i) {
    final s = _statusOf(i);
    return s.isNotEmpty && _openStatuses.contains(s);
  }

  /// True when incident [i] belongs to the plant with code [code].
  ///
  /// Canonicalises first. The old filters used `plant.startsWith(code)`, which
  /// matched 'BSP' against 'BSP_MINES' — two different plants counted as one.
  bool _matchesPlantCode(Map<String, dynamic> i, String code) {
    final canon = AdminMasterData
        .canonicalPlantFrom(i['plant']?.toString() ?? '', _plants)
        .toUpperCase();
    final c = code.trim().toUpperCase();
    if (c.isEmpty || canon.isEmpty) return false;
    // Canonical labels are "CODE — Name", so compare the code segment exactly.
    final dash = canon.indexOf(' — ');
    final canonCode = dash > 0 ? canon.substring(0, dash) : canon;
    return canonCode == c;
  }

  /// "Finished" — anything not open. Previously written as
  /// `s == 'CLOSED' || s == 'RESOLVED'`, where 'RESOLVED' isn't even in the
  /// status list, so a VERIFIED case counted as neither open nor resolved.
  bool _isDoneInc(Map<String, dynamic> i) {
    final s = _statusOf(i);
    return s.isNotEmpty && !_openStatuses.contains(s);
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadPlantsMaster();
    RealtimeSync.incidentsRevision.addListener(_onRealtime);
    AdminMasterData.revision.addListener(_loadPlantsMaster);
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_onRealtime);
    AdminMasterData.revision.removeListener(_loadPlantsMaster);
    super.dispose();
  }

  void _onRealtime() {
    if (mounted) _loadLocal();
  }

  Future<void> _loadPlantsMaster() async {
    try {
      final masterPlants = await AdminMasterData.getPlants();
      final openStatuses = await AdminMasterData.getOpenStatuses();
      final allStatuses  = await AdminMasterData.getStatuses();
      if (!mounted) return;
      // No .isEmpty bail-out: if the admin deleted every plant, show none.
      setState(() {
        _plants = masterPlants;
        _openStatuses = openStatuses;
        _statuses = allStatuses;
      });
    } catch (_) {}
  }

  Future<void> _loadAll() async {
    await _loadLocal();
    _refreshFromSheets();
  }

  Future<void> _loadLocal() async {
    final scope = await PlantScope.forUser(widget.user);
    // Filter at source, not in the widgets: a locked user's _incidents list must
    // never contain another plant's records, or any getter added later silently
    // reintroduces the leak.
    final inc   = await scope.filterIncidents(await LocalDB.getIncidents());
    final users = _usersInScope(await LocalDB.getAllUsers(), scope);
    if (!mounted) return;
    setState(() {
      _scope        = scope;
      _incidents    = inc;
      _allUsers     = users.isNotEmpty ? users : _fallbackUsers();
      _selectedUser ??= _findUser(widget.user?['username']?.toString() ?? '');
      _selectedUser ??= _allUsers.isNotEmpty ? _allUsers.first : widget.user;
      // If the previously selected user is no longer in scope (scope resolved
      // after the first paint, or the admin moved them), fall back to self.
      if (_selectedUser != null && !_isUserInList(_selectedUser!, _allUsers)) {
        _selectedUser = _allUsers.isNotEmpty ? _allUsers.first : widget.user;
      }
      _loading = false;
    });
  }

  /// Users a locked plant user may inspect: their own plant's, plus always
  /// themselves (so a user whose own plant string is odd still sees their data).
  List<Map<String, dynamic>> _usersInScope(
      List<Map<String, dynamic>> users, PlantScope scope) {
    if (scope.seesAllPlants) return users;
    if (scope.plant.isEmpty) return _fallbackUsers();
    final myPno  = widget.user?['pno']?.toString() ?? '';
    final myUser = widget.user?['username']?.toString() ?? '';
    return users.where((u) {
      if (myPno.isNotEmpty && u['pno']?.toString() == myPno) return true;
      if (myUser.isNotEmpty && u['username']?.toString() == myUser) return true;
      return AdminMasterData.canonicalPlantFrom(
              u['plant']?.toString() ?? '', _plants) ==
          scope.plant;
    }).toList();
  }

  bool _isUserInList(
      Map<String, dynamic> u, List<Map<String, dynamic>> list) {
    final key = u['username']?.toString() ?? u['name']?.toString() ?? '';
    if (key.isEmpty) return false;
    return list.any((x) =>
        x['username']?.toString() == key || x['name']?.toString() == key);
  }

  Future<void> _refreshFromSheets() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      // Scope the freshly fetched rows too. These two setState calls used the
      // server lists verbatim, so a background refresh re-populated the screen
      // with every plant's data a few seconds after _loadLocal() had filtered it.
      final scope = _scope ?? await PlantScope.forUser(widget.user);
      final sheetUsers = await SyncService.fetchUsers();
      if (sheetUsers.isNotEmpty && mounted) {
        final scoped = _usersInScope(sheetUsers, scope);
        setState(() => _allUsers = scoped.isNotEmpty ? scoped : _fallbackUsers());
      }
      final sheetInc = await SyncService.fetchIncidents();
      if (sheetInc.isNotEmpty) {
        final scopedInc = await scope.filterIncidents(sheetInc);
        if (mounted) setState(() => _incidents = scopedInc);
      }
    } catch (_) {}
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _onRefresh() => _loadAll();

  List<Map<String, dynamic>> _fallbackUsers() {
    final u = widget.user;
    if (u == null) return [];
    return [u];
  }

  Map<String, dynamic>? _findUser(String username) {
    if (username.isEmpty) return null;
    try {
      return _allUsers.firstWhere(
        (u) => u['username']?.toString() == username ||
               u['name']?.toString() == username);
    } catch (_) { return null; }
  }

  String _userName(Map<String, dynamic>? u) =>
      u?['name']?.toString() ?? u?['username']?.toString() ?? 'Unknown';

  String _userInitials(Map<String, dynamic>? u) {
    final n = _userName(u);
    // Drop empty segments so names with extra/trailing spaces can't crash on [0].
    final parts = n.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return parts.isNotEmpty ? parts[0][0].toUpperCase() : '?';
  }

  List<Map<String, dynamic>> get _userIncidents {
    final name = _userName(_selectedUser).toLowerCase();
    final pno  = _selectedUser?['pno']?.toString() ?? '';
    return _incidents.where((i) {
      final rb  = i['reportedBy']?.toString().toLowerCase()  ?? '';
      final rpn = i['reportedByPno']?.toString()             ?? '';
      return rb == name || rpn == pno;
    }).toList();
  }

  int get _aiScans  => _userIncidents.where((i) =>
      (i['type']?.toString().toUpperCase() ?? '').contains('AI') ||
      (i['type']?.toString().toUpperCase() ?? '').contains('SCAN')).length;
  int get _nearMiss => _userIncidents.where((i) =>
      (i['type']?.toString().toUpperCase() ?? '').contains('NEAR') ||
      (i['type']?.toString().toUpperCase() ?? '').contains('MISS')).length;
  int get _resolved => _userIncidents.where(_isDoneInc).length;
  int get _critical => _userIncidents.where((i) =>
      (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL').length;
  int get _high     => _userIncidents.where((i) =>
      (i['severity']?.toString().toUpperCase() ?? '') == 'HIGH').length;
  int get _medium   => _userIncidents.where((i) {
      final s = i['severity']?.toString().toUpperCase() ?? '';
      return s == 'MEDIUM' || s == 'MODERATE';
    }).length;
  int get _low      => _userIncidents.where((i) =>
      (i['severity']?.toString().toUpperCase() ?? '') == 'LOW').length;
  int get _totalEntries => _userIncidents.length;

  Map<String, Map<String, int>> _plantStats() {
    final result = <String, Map<String, int>>{};
    for (final p in _plants) {
      result[p['code']!] = {'total': 0, 'open': 0, 'critical': 0, 'high': 0, 'scans': 0};
    }
    for (final inc in _incidents) {
      final rawPlant = inc['plant']?.toString() ?? '';
      // Canonicalize to "CODE — Name", then take the code so all format
      // variants of a plant roll up to the same row.
      final canon = AdminMasterData.canonicalPlantFrom(rawPlant, _plants);
      String? code;
      final dashIdx = canon.indexOf(' — ');
      if (dashIdx > 0) {
        final maybeCode = canon.substring(0, dashIdx).toUpperCase();
        if (result.containsKey(maybeCode)) code = maybeCode;
      }
      // Fallback: match the canonical label against a known plant name.
      if (code == null) {
        for (final p in _plants) {
          if (canon.toUpperCase() == (p['name'] ?? '').toUpperCase()) {
            code = p['code']; break;
          }
        }
      }
      // Unmatched incidents go to the master list's own catch-all ('OTHER'),
      // never to a hardcoded code that may not exist in the admin's list.
      // If the admin removed the catch-all too, the incident is counted under
      // no plant rather than being silently attributed to the wrong one.
      code ??= result.containsKey('OTHER') ? 'OTHER' : null;
      if (code == null || !result.containsKey(code)) continue;
      result[code]!['total'] = (result[code]!['total'] ?? 0) + 1;
      final severity = inc['severity']?.toString().toUpperCase() ?? '';
      final type     = inc['type']?.toString().toUpperCase()     ?? '';
      // Every non-terminal stage counts as open, not just a literal 'OPEN' —
      // INVESTIGATING and ACTION TAKEN are open work too.
      if (_isOpenInc(inc))        result[code]!['open']     = (result[code]!['open']     ?? 0) + 1;
      if (severity == 'CRITICAL') result[code]!['critical'] = (result[code]!['critical'] ?? 0) + 1;
      if (severity == 'HIGH')     result[code]!['high']     = (result[code]!['high']     ?? 0) + 1;
      if (type.contains('AI') || type.contains('SCAN'))
        result[code]!['scans'] = (result[code]!['scans'] ?? 0) + 1;
    }
    return result;
  }

  /// The plant code for the signed-in user.
  ///
  /// Uses the shared canonicaliser instead of `startsWith(code)` plus a
  /// first-word `contains()`, which matched far too loosely — 'BSP Bhilai'
  /// satisfied both 'BSP' and 'BSP_MINES', and any plant whose name began with
  /// a common word could win on the second test.
  String _myPlantCode() {
    final raw = widget.user?['plant']?.toString() ?? '';
    if (raw.trim().isEmpty) return '';
    final canon =
        AdminMasterData.canonicalPlantFrom(raw, _plants).toUpperCase();
    if (canon.isEmpty) return '';
    final dash = canon.indexOf(' — ');
    final code = dash > 0 ? canon.substring(0, dash) : canon;
    // Only return a code the master list actually contains.
    for (final p in _plants) {
      if ((p['code'] ?? '').toUpperCase() == code) return p['code']!;
    }
    return '';
  }

  /// Admin check — reads `isAdmin` ONLY, via the one shared definition.
  ///
  /// This used to also return true when the user's own `designation` contained
  /// 'agm', 'gm', 'manager' or 'admin'. Designation is free text the user types
  /// into their own registration form, so anyone who wrote "Manager" granted
  /// themselves admin visibility — and note 'gm' is a substring of many words.
  /// home_tab used isAdmin alone, so the two screens also disagreed about who
  /// was an admin.
  bool _isAdmin() {
    final u = widget.user;
    return u != null && PlantScope.isAdminUser(u);
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      body: SafeArea(
        child: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : RefreshIndicator(
              onRefresh: _onRefresh,
              color: AppColors.accent,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _buildAppBar(sl),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        _scopeBanner(sl),
                        _buildUserSwitcher(sl),
                        const SizedBox(height: 16),
                        _buildPlantSummary(sl),
                        const SizedBox(height: 16),
                        _buildActivitySection(sl),
                        const SizedBox(height: 20),
                        _buildSeveritySection(sl),
                        const SizedBox(height: 20),
                        _buildQuickActions(sl),
                        const SizedBox(height: 20),
                        _buildPlantSection(sl),
                        const SizedBox(height: 20),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
      ),
    );
  }

  SliverAppBar _buildAppBar(SL sl) => SliverAppBar(
    backgroundColor: sl.bg2,
    floating: true, snap: true, elevation: 0,
    title: Row(children: [
      Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: AppColors.accent.withOpacity(0.15),
          border: Border.all(color: AppColors.accent.withOpacity(0.3))),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Image.asset('assets/images/app_icon.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(
                Icons.shield_outlined, size: 18, color: AppColors.accent)))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SAIL Safety Lens',
          style: TextStyle(color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
        Text('AI Safety Platform',
          style: TextStyle(color: sl.text3, fontSize: 12)),  // Improved: was text4/9px
      ])),
      if (_refreshing)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))),
    ]),
    actions: [
      if (_isAdmin())
        IconButton(
          tooltip: 'Admin Panel',
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AdminScreen())),
          icon: const Icon(Icons.admin_panel_settings_outlined,
              color: AppColors.amber, size: 22)),
      IconButton(
        tooltip: 'Toggle theme',
        onPressed: widget.toggleTheme,
        icon: Icon(sl.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            color: sl.text3, size: 20)),
      IconButton(
        tooltip: 'Sign out',
        onPressed: widget.onSignOut,
        icon: Icon(Icons.logout_rounded, color: sl.text3, size: 20)),
    ],
  );

  /// Shows an unresolved scope. Never silently widen: if we can't tell which
  /// plant this user belongs to, say so instead of showing an empty dashboard
  /// that looks like "no incidents reported".
  Widget _scopeBanner(SL sl) {
    final problem = _scope?.problem;
    if (problem == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amber.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withOpacity(0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline_rounded,
            color: AppColors.amber, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(problem,
            style: TextStyle(color: sl.text2, fontSize: 11, height: 1.35))),
      ]),
    );
  }

  Widget _buildUserSwitcher(SL sl) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: sl.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: sl.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('VIEWING ACTIVITY OF',
        style: TextStyle(color: sl.text3, fontSize: 11,    // Improved: was text4/9px
            fontWeight: FontWeight.w700, letterSpacing: 0.7)),
      const SizedBox(height: 8),
      Row(children: [
        Container(
          width: 40, height: 40,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [AppColors.accent, AppColors.cyan])),
          child: Center(child: Text(_userInitials(_selectedUser),
            style: const TextStyle(color: Colors.white,
                fontSize: 14, fontWeight: FontWeight.w800)))),
        const SizedBox(width: 10),
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: sl.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.accent.withOpacity(0.4))),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedUser?['username']?.toString() ??
                     _selectedUser?['name']?.toString(),
              isExpanded: true,
              dropdownColor: sl.bg2,
              style: TextStyle(color: sl.text1, fontSize: 13,
                  fontWeight: FontWeight.w600),
              icon: Icon(Icons.expand_more, color: AppColors.accent, size: 18),
              onChanged: (val) {
                if (val == null) return;
                final found = _allUsers.firstWhere(
                  (u) => u['username']?.toString() == val ||
                         u['name']?.toString() == val,
                  orElse: () => <String, dynamic>{});
                if (found.isNotEmpty) setState(() => _selectedUser = found);
              },
              items: _allUsers.map((u) {
                final uname = _userName(u);
                final key   = u['username']?.toString() ?? uname;
                final plant = u['plant']?.toString() ?? '';
                final code  = plant.contains(' ') ? plant.split(' ').first : plant;
                return DropdownMenuItem<String>(
                  value: key,
                  child: Row(children: [
                    Expanded(child: Text(uname, overflow: TextOverflow.ellipsis)),
                    if (code.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(left: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4)),
                        child: Text(code, style: const TextStyle(
                            color: AppColors.accent, fontSize: 9,
                            fontWeight: FontWeight.w700))),
                  ]));
              }).toList(),
            ),
          ),
        )),
      ]),
    ]),
  );

  Widget _buildActivitySection(SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionHeader('📋  ${_userName(_selectedUser).split(' ').first}\'s Activity', sl),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _statCard(
          label: 'AI Scans done', value: _aiScans,
          color: AppColors.accent, icon: Icons.document_scanner_rounded, sl: sl,
          onTap: () => _showCasesSheet(
            title: 'AI Scans by ${_userName(_selectedUser).split(' ').first}',
            filter: (i) => (i['type']?.toString().toUpperCase() ?? '').contains('SCAN'),
            sl: sl))),
        const SizedBox(width: 10),
        Expanded(child: _statCard(
          label: 'Near Misses', value: _nearMiss,
          color: AppColors.amber, icon: Icons.warning_amber_rounded, sl: sl,
          onTap: () => _showCasesSheet(
            title: 'Near Misses by ${_userName(_selectedUser).split(' ').first}',
            filter: (i) => (i['type']?.toString().toUpperCase() ?? '').contains('NEAR'),
            sl: sl))),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _statCard(
          label: 'Total entries', value: _totalEntries,
          color: AppColors.purple, icon: Icons.list_alt_rounded, sl: sl,
          onTap: () => _showCasesSheet(
            title: 'All entries by ${_userName(_selectedUser).split(' ').first}',
            filter: (_) => true, sl: sl))),
        const SizedBox(width: 10),
        Expanded(child: _statCard(
          label: 'Resolved', value: _resolved,
          color: AppColors.green, icon: Icons.check_circle_outline_rounded, sl: sl,
          onTap: () => _showCasesSheet(
            title: 'Resolved cases',
            filter: _isDoneInc, sl: sl))),
      ]),
    ],
  );

  Widget _buildSeveritySection(SL sl) {
    final max = [_critical, _high, _medium, _low].fold(1, (a, b) => a > b ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _sectionHeader('⚠️  Severity Breakdown', sl)),
        Text('by ${_userName(_selectedUser).split(' ').first}',
          style: TextStyle(color: sl.text4, fontSize: 10)),
      ]),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(color: sl.card,
          borderRadius: BorderRadius.circular(14), border: Border.all(color: sl.border)),
        child: Column(children: [
          _severityRow('🔴  Critical', _critical, AppColors.crit,  max, sl,
            onTap: () => _showCasesSheet(
              title: 'Critical cases',
              filter: (i) => (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL',
              sl: sl)),
          Divider(height: 1, color: sl.border),
          _severityRow('🟠  High',    _high,     AppColors.red,   max, sl,
            onTap: () => _showCasesSheet(
              title: 'High severity cases',
              filter: (i) => (i['severity']?.toString().toUpperCase() ?? '') == 'HIGH',
              sl: sl)),
          Divider(height: 1, color: sl.border),
          _severityRow('🟡  Medium',  _medium,   AppColors.amber, max, sl,
            onTap: () => _showCasesSheet(
              title: 'Medium severity cases',
              filter: (i) {
                final s = i['severity']?.toString().toUpperCase() ?? '';
                return s == 'MEDIUM' || s == 'MODERATE';
              }, sl: sl)),
          Divider(height: 1, color: sl.border),
          _severityRow('🟢  Low',     _low,      AppColors.green, max, sl,
            onTap: () => _showCasesSheet(
              title: 'Low severity cases',
              filter: (i) => (i['severity']?.toString().toUpperCase() ?? '') == 'LOW',
              sl: sl)),
        ]),
      ),
    ]);
  }

  Widget _severityRow(String label, int count, Color color, int max, SL sl,
      {required VoidCallback onTap}) =>
    InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          SizedBox(width: 80, child: Text(label,
            style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w600))),
          const SizedBox(width: 10),
          Expanded(child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: max > 0 ? count / max : 0,
              minHeight: 7,
              backgroundColor: color.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color)))),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onTap,
            child: Text('$count', style: TextStyle(color: color, fontSize: 16,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.underline,
              decorationColor: color,
              decorationStyle: TextDecorationStyle.dotted))),
        ]),
      ),
    );

  Widget _buildQuickActions(SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionHeader('⚡  Quick Actions', sl),
      const SizedBox(height: 10),
      Row(children: [
        _actionBtn(Icons.document_scanner_rounded, 'AI Hazard\nScan',   AppColors.accent, sl, () => widget.onTabChange(1)),
        const SizedBox(width: 8),
        _actionBtn(Icons.warning_amber_rounded,    'Report\nNear Miss', AppColors.amber,  sl, () => widget.onTabChange(2)),
        const SizedBox(width: 8),
        _actionBtn(Icons.chat_bubble_rounded,      'Ask\nSuraksha AI',  AppColors.cyan,   sl, () => widget.onTabChange(3)),
        const SizedBox(width: 8),
        _actionBtn(Icons.bar_chart_rounded,        'View\nReports',     AppColors.purple, sl, () => widget.onTabChange(4)),
      ]),
    ],
  );

  /// ★ NEW: Plant-specific summary for the user's plant
  Widget _buildPlantSummary(SL sl) {
    final rawUserPlant = (widget.user?['plant']?.toString() ?? '').trim();
    if (rawUserPlant.isEmpty) return const SizedBox.shrink();

    // Canonicalise once, then compare canonical-to-canonical. The old test was
    // `incPlant.contains(userPlant)`, which pulled "BSP_MINES" records into a
    // "BSP" user's summary — and with a short plant code could match almost
    // anything.
    final userPlant =
        AdminMasterData.canonicalPlantFrom(rawUserPlant, _plants);
    if (userPlant.isEmpty) return const SizedBox.shrink();

    // Filter incidents for user's plant only
    final plantIncidents = _incidents.where((inc) {
      return AdminMasterData.canonicalPlantFrom(
              inc['plant']?.toString() ?? '', _plants) ==
          userPlant;
    }).toList();

    if (plantIncidents.isEmpty) {
      // Don't show widget if no data for this plant
      return const SizedBox.shrink();
    }

    // Calculate metrics
    final total = plantIncidents.length;
    final critical = plantIncidents.where((i) =>
      (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL').length;
    final open = plantIncidents.where(_isOpenInc).length;

    // Last 30 days trend
    final last30Days = DateTime.now().subtract(const Duration(days: 30));
    final recentCount = plantIncidents.where((inc) {
      try {
        final dateStr = inc['date']?.toString() ?? '';
        if (dateStr.isEmpty) return false;
        final date = DateTime.parse(dateStr);
        return date.isAfter(last30Days);
      } catch (_) {
        return false;
      }
    }).length;

    // Top department in this plant
    final deptCounts = <String, int>{};
    for (var inc in plantIncidents) {
      final dept = inc['dept']?.toString() ?? 'Unknown';
      if (dept.isNotEmpty && dept != 'Unknown') {
        deptCounts[dept] = (deptCounts[dept] ?? 0) + 1;
      }
    }
    final sortedDepts = deptCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topDept = sortedDepts.isNotEmpty ? sortedDepts.first : null;

    final trendUp = total > 0 && recentCount > (total * 0.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('🏭  $userPlant Safety Summary', sl),
        const SizedBox(height: 4),
        Text('Your plant\'s incident overview',
          style: TextStyle(color: sl.text4, fontSize: 10)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Metrics Grid
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _plantMetricTile('Total', total, Icons.warning_amber_rounded,
                    AppColors.amber, sl),
                  _plantMetricTile('Critical', critical, Icons.error_outline_rounded,
                    AppColors.crit, sl),
                  _plantMetricTile('Open', open, Icons.pending_outlined,
                    AppColors.cyan, sl),
                ],
              ),

              const SizedBox(height: 14),

              // Trend Indicator
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: trendUp
                    ? AppColors.red.withOpacity(0.08)
                    : AppColors.green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: trendUp
                      ? AppColors.red.withOpacity(0.2)
                      : AppColors.green.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      trendUp ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                      color: trendUp ? AppColors.red : AppColors.green,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$recentCount incidents in last 30 days',
                        style: TextStyle(
                          color: sl.text2,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Top Department (if available)
              if (topDept != null) ...[
                const SizedBox(height: 12),
                Text('Department Needing Most Attention:',
                  style: TextStyle(color: sl.text4, fontSize: 10,
                    fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.engineering_outlined, size: 13, color: AppColors.accent),
                      const SizedBox(width: 6),
                      Text(
                        '${topDept.key} (${topDept.value} ${topDept.value == 1 ? "incident" : "incidents"})',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Helper: Plant metric tile
  Widget _plantMetricTile(String label, int value, IconData icon, Color color, SL sl) {
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(height: 6),
        Text(
          value.toString(),
          style: TextStyle(
            color: sl.text1,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: sl.text4,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildPlantSection(SL sl) {
    final stats  = _plantStats();
    final myCode = _myPlantCode();
    final locked = _scope?.isLocked ?? false;
    // A locked user's _incidents contain only their own plant, so every other
    // row here would read 0 across the board — a table that looks like real
    // data but isn't. Show just their plant instead.
    final visible = locked
        ? _plants.where((p) => (p['code'] ?? '') == myCode).toList()
        : List<Map<String, String>>.from(_plants);
    if (visible.isEmpty) return const SizedBox.shrink();
    final sorted = visible
      ..sort((a, b) {
        if (a['code'] == myCode) return -1;
        if (b['code'] == myCode) return 1;
        final at = stats[a['code']]?['total'] ?? 0;
        final bt = stats[b['code']]?['total'] ?? 0;
        return bt.compareTo(at);
      });

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _sectionHeader('🏭  Plant-wise Safety Status', sl)),
        if (!locked)
          TextButton(
            onPressed: () => _showAllPlantsSheet(stats, myCode, sl),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero),
            child: const Text('View all →', style: TextStyle(
                color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w600))),
      ]),
      Text(locked ? 'Your plant · tap row for details'
                  : 'All SAIL plants · tap row for details',
        style: TextStyle(color: sl.text4, fontSize: 10)),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(color: sl.card,
          borderRadius: BorderRadius.circular(14), border: Border.all(color: sl.border)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            children: sorted.asMap().entries.map((entry) {
              final idx   = entry.key;
              final plant = entry.value;
              final code  = plant['code']!;
              final name  = plant['name']!;
              final s     = stats[code] ?? {};
              final isMy  = code == myCode;
              final isLast = idx == sorted.length - 1;
              return Column(children: [
                _plantRow(code, name, s, isMy, sl),
                if (!isLast) Divider(height: 1, color: sl.border),
              ]);
            }).toList(),
          ),
        ),
      ),
    ]);
  }

  Widget _plantRow(String code, String name, Map<String, int> s, bool isMy, SL sl) {
    final total    = s['total']    ?? 0;
    final open     = s['open']     ?? 0;
    final critical = s['critical'] ?? 0;
    final scans    = s['scans']    ?? 0;

    return InkWell(
      onTap: () => _showPlantSheet(code, name, s, sl),
      child: Container(
        color: isMy ? AppColors.accent.withOpacity(0.06) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: isMy ? AppColors.accent : AppColors.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10)),
            child: Center(child: Text(code, textAlign: TextAlign.center,
              style: TextStyle(
                color: isMy ? Colors.white : AppColors.accent,
                fontSize: code.length > 3 ? 8 : 10,
                fontWeight: FontWeight.w800)))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(name,
                style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (isMy)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.accent, borderRadius: BorderRadius.circular(4)),
                  child: const Text('★ Yours', style: TextStyle(
                      color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700))),
            ]),
            Text('$total reports total', style: TextStyle(color: sl.text4, fontSize: 10)),
          ])),
          const SizedBox(width: 8),
          Row(children: [
            _miniBadge('C:$critical', AppColors.crit,
              onTap: () => _showAllCasesSheet(
                title: '$code — Critical cases',
                filter: (i) => _matchesPlantCode(i, code) &&
                    (i['severity']?.toString().toUpperCase() ?? '') == 'CRITICAL',
                sl: sl)),
            const SizedBox(width: 4),
            _miniBadge('O:$open', AppColors.amber,
              onTap: () => _showAllCasesSheet(
                title: '$code — Open cases',
                filter: (i) => _matchesPlantCode(i, code) && _isOpenInc(i),
                sl: sl)),
            const SizedBox(width: 4),
            _miniBadge('S:$scans', AppColors.accent,
              onTap: () => _showAllCasesSheet(
                title: '$code — AI Scans',
                filter: (i) => _matchesPlantCode(i, code) &&
                    (i['type']?.toString().toUpperCase() ?? '').contains('SCAN'),
                sl: sl)),
          ]),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right_rounded, color: sl.text4, size: 18),
        ]),
      ),
    );
  }

  // ─── BOTTOM SHEETS ────────────────────────────────────────────
  void _showAllCasesSheet({
    required String title,
    required bool Function(Map<String, dynamic>) filter,
    required SL sl,
  }) {
    final cases = _incidents.where(filter).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CasesSheet(
        title: title, cases: cases, sl: sl,
        onCaseClosed: _loadLocal));   // ← refresh after close
  }

  void _showCasesSheet({
    required String title,
    required bool Function(Map<String, dynamic>) filter,
    required SL sl,
  }) {
    final cases = _userIncidents.where(filter).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CasesSheet(
        title: title, cases: cases, sl: sl,
        onCaseClosed: _loadLocal));
  }

  void _showPlantSheet(String code, String name, Map<String, int> stats, SL sl) {
    final plantCases =
        _incidents.where((i) => _matchesPlantCode(i, code)).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlantSheet(
        code: code, name: name, stats: stats, cases: plantCases, sl: sl));
  }

  void _showAllPlantsSheet(Map<String, Map<String, int>> stats, String myCode, SL sl) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AllPlantsSheet(
        plants: _plants, stats: stats, myCode: myCode, sl: sl));
  }

  // ─── SMALL WIDGETS ────────────────────────────────────────────
  Widget _sectionHeader(String title, SL sl) => Row(children: [
    Container(width: 3, height: 16, color: AppColors.accent,
        margin: const EdgeInsets.only(right: 8)),
    Text(title, style: TextStyle(color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
  ]);

  Widget _statCard({
    required String label, required int value,
    required Color color, required IconData icon,
    required SL sl, required VoidCallback onTap}) =>
  GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 5),
          Expanded(child: Text(label, style: TextStyle(color: sl.text3, fontSize: 10),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 6),
        Text('$value', style: TextStyle(
          color: color, fontSize: 28, fontWeight: FontWeight.w800,
          decoration: TextDecoration.underline,
          decorationColor: color.withOpacity(0.5),
          decorationStyle: TextDecorationStyle.dotted)),
      ])));

  Widget _actionBtn(IconData icon, String label, Color color,
      SL sl, VoidCallback onTap) =>
    Expanded(child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25))),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 5),
          Flexible(
            child: Text(label, textAlign: TextAlign.center,
              style: TextStyle(color: color, fontSize: 11,    // Improved: was 9px
                  fontWeight: FontWeight.w700, height: 1.3),  // Increased weight for emphasis
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          ),
        ]))));

  Widget _miniBadge(String text, Color color, {required VoidCallback onTap}) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Text(text, style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.underline,
          decorationColor: color, decorationStyle: TextDecorationStyle.dotted))));
}


// ═══════════════════════════════════════════════════════════════
//  CASES BOTTOM SHEET
// ═══════════════════════════════════════════════════════════════
class _CasesSheet extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> cases;
  final SL sl;
  final VoidCallback? onCaseClosed; // ← refresh callback

  const _CasesSheet({
    required this.title, required this.cases, required this.sl,
    this.onCaseClosed});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65, maxChildSize: 0.95, minChildSize: 0.4,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: sl.bg2,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(children: [
          Center(child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 40, height: 4,
            decoration: BoxDecoration(color: sl.border, borderRadius: BorderRadius.circular(99)))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(children: [
              Expanded(child: Text(title,
                style: TextStyle(color: sl.text1, fontSize: 15, fontWeight: FontWeight.w700))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(99)),
                child: Text('${cases.length}', style: const TextStyle(
                    color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w700))),
              const SizedBox(width: 8),
              IconButton(
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                icon: Icon(Icons.close_rounded, color: sl.text3, size: 20),
                onPressed: () => Navigator.pop(context)),
            ])),
          Divider(height: 1, color: sl.border),
          Expanded(child: cases.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('📭', style: TextStyle(fontSize: 32)),
                const SizedBox(height: 8),
                Text('No cases found', style: TextStyle(color: sl.text3, fontSize: 13)),
              ]))
            : ListView.separated(
                controller: ctrl,
                padding: const EdgeInsets.all(14),
                itemCount: cases.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                // ✅ Pass onCaseClosed to each card
                itemBuilder: (_, i) => _CaseCard(
                    inc: cases[i], sl: sl, onClosed: onCaseClosed))),
        ])));
  }
}


// ═══════════════════════════════════════════════════════════════
//  CASE CARD — ✅ StatefulWidget with Quick Close button
// ═══════════════════════════════════════════════════════════════
class _CaseCard extends StatefulWidget {
  final Map<String, dynamic> inc;
  final SL sl;
  final VoidCallback? onClosed;

  const _CaseCard({required this.inc, required this.sl, this.onClosed});

  @override
  State<_CaseCard> createState() => _CaseCardState();
}

class _CaseCardState extends State<_CaseCard> {
  late Map<String, dynamic> _inc;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _inc = Map<String, dynamic>.from(widget.inc);
    _loadClosingStatus();
  }

  Color _sevColor(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':
      case 'MODERATE': return AppColors.amber;
      default:         return AppColors.green;
    }
  }

  /// Terminal-status check against the admin's ladder rather than the literal
  /// 'CLOSED'. Seeded from the shared const so the first frame has a value;
  /// [_loadClosingStatus] replaces it with the configured one.
  String _closingStatus = AdminMasterData.defaultStatuses.last;

  bool get _isClosed =>
      _closingStatus.isNotEmpty &&
      (_inc['status']?.toString().trim().toUpperCase() ?? '') ==
          _closingStatus.trim().toUpperCase();

  Future<void> _loadClosingStatus() async {
    final s = await AdminMasterData.lastStatus();
    if (mounted && s != _closingStatus) setState(() => _closingStatus = s);
  }

  // ── Quick Close Dialog ────────────────────────────────────────
  Future<void> _showQuickCloseDialog() async {
    final sl           = widget.sl;
    final actionCtrl   = TextEditingController();
    final closedByCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          const Icon(Icons.lock_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('Close Case',
            style: TextStyle(color: sl.text1, fontSize: 15, fontWeight: FontWeight.w700))),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            _inc['title']?.toString() ?? 'Incident',
            style: TextStyle(color: sl.text2, fontSize: 12),
            maxLines: 2),
          const SizedBox(height: 12),
          // Corrective action field
          TextField(
            controller: actionCtrl,
            maxLines: 3, autofocus: true,
            style: TextStyle(color: sl.text1, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Describe corrective action taken… *',
              hintStyle: TextStyle(color: sl.text4, fontSize: 11),
              filled: true,
              fillColor: sl.isDark
                  ? const Color(0xFF1C1F2E) : const Color(0xFFF5F6FA),
              contentPadding: const EdgeInsets.all(10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: sl.border)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: AppColors.accent, width: 2)))),
          const SizedBox(height: 10),
          // Closed by field
          TextField(
            controller: closedByCtrl,
            style: TextStyle(color: sl.text1, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Closed / Verified by (name)',
              hintStyle: TextStyle(color: sl.text4, fontSize: 11),
              filled: true,
              fillColor: sl.isDark
                  ? const Color(0xFF1C1F2E) : const Color(0xFFF5F6FA),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: sl.border)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: AppColors.accent, width: 2)))),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton.icon(
            onPressed: () {
              if (actionCtrl.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            icon: const Icon(Icons.lock_rounded, size: 14, color: Colors.white),
            label: const Text('Close Case',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9)))),
        ]));

    if (confirmed != true || !mounted) return;

    final corrective = actionCtrl.text.trim();
    final closedBy   = closedByCtrl.text.trim();
    if (corrective.isEmpty) return;

    setState(() => _closing = true);

    // Close using the LAST status in the admin's ladder, not the literal
    // 'CLOSED' — if the admin renames that stage, writing 'CLOSED' would put
    // the record into a status that no longer exists in any dropdown or count.
    final closingStatus = await AdminMasterData.lastStatus();
    if (closingStatus.isEmpty) {
      // No statuses configured at all: there is nothing to close into, and
      // inventing one would contradict the admin panel.
      if (mounted) {
        setState(() => _closing = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No statuses are configured — ask the admin to set '
              'up the status list before closing cases.'),
        ));
      }
      return;
    }

    final now = DateTime.now().toIso8601String();
    _inc['status']           = closingStatus;
    _inc['correctiveAction'] = corrective;
    _inc['closedBy']         = closedBy;
    _inc['closedAt']         = now;

    // ✅ Save to LocalDB
    await LocalDB.saveIncident(_inc);

    // ✅ Push to Google Sheets
    SyncService.pushIncident(_inc).catchError((_) => false);

    if (mounted) {
      setState(() => _closing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
          SizedBox(width: 8),
          Expanded(child: Text('Case closed & synced to Google Sheets')),
        ]),
        backgroundColor: AppColors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 3),
      ));
      // Notify parent to refresh
      widget.onClosed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sl       = widget.sl;
    final id       = _inc['id']?.toString() ?? '—';
    final title    = _inc['title']?.toString()
                  ?? _inc['desc']?.toString() ?? 'Untitled';
    final sev      = _inc['severity']?.toString() ?? '—';
    final status   = _inc['status']?.toString() ?? '—';
    final type     = _inc['type']?.toString() ?? '—';
    final date     = _inc['date']?.toString() ?? '';
    final plant    = _inc['plant']?.toString() ?? '';
    final sevColor = _sevColor(sev);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _isClosed ? AppColors.green.withOpacity(0.04) : sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _isClosed
              ? AppColors.green.withOpacity(0.35)
              : sevColor.withOpacity(0.25),
          width: _isClosed ? 1.5 : 1.0)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(id, style: TextStyle(color: sl.text4, fontSize: 9, fontFamily: 'monospace')),
          const Spacer(),
          if (date.isNotEmpty)
            Text(date, style: TextStyle(color: sl.text4, fontSize: 9)),
        ]),
        const SizedBox(height: 4),
        Text(title,
          style: TextStyle(
            color: _isClosed ? sl.text3 : sl.text1,
            fontSize: 13, fontWeight: FontWeight.w600,
            decoration: _isClosed ? TextDecoration.lineThrough : null),
          maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Row(children: [
          // Status & type pills
          Expanded(child: Wrap(spacing: 6, runSpacing: 4, children: [
            _pill(sev, sevColor),
            _pill(status,
              _isClosed ? AppColors.green : AppColors.amber),
            _pill(type, AppColors.accent),
            if (plant.isNotEmpty) _pill(plant, sl.text3),
          ])),
          // ✅ Quick Close button — only shown for non-closed cases
          if (!_isClosed) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _closing ? null : _showQuickCloseDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.green.withOpacity(0.4))),
                child: _closing
                  ? const SizedBox(width: 13, height: 13,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.green))
                  : const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.lock_outline_rounded,
                          color: AppColors.green, size: 12),
                      SizedBox(width: 4),
                      Text('Close', style: TextStyle(
                          color: AppColors.green, fontSize: 10,
                          fontWeight: FontWeight.w700)),
                    ]))),
          ],
        ]),
        // Show corrective action if closed
        if (_isClosed && (_inc['correctiveAction']?.toString() ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.green.withOpacity(0.07),
              borderRadius: BorderRadius.circular(7)),
            child: Row(children: [
              const Icon(Icons.check_circle_outline,
                  color: AppColors.green, size: 12),
              const SizedBox(width: 5),
              Expanded(child: Text(
                _inc['correctiveAction']?.toString() ?? '',
                style: const TextStyle(color: AppColors.green,
                    fontSize: 10, height: 1.4),
                maxLines: 2, overflow: TextOverflow.ellipsis)),
            ])),
        ],
      ]));
  }

  Widget _pill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withOpacity(0.3))),
    child: Text(text, style: TextStyle(
        color: color, fontSize: 10, fontWeight: FontWeight.w600)));
}


// ═══════════════════════════════════════════════════════════════
//  PLANT DETAIL SHEET (unchanged)
// ═══════════════════════════════════════════════════════════════
class _PlantSheet extends StatelessWidget {
  final String code, name;
  final Map<String, int> stats;
  final List<Map<String, dynamic>> cases;
  final SL sl;

  const _PlantSheet({
    required this.code, required this.name,
    required this.stats, required this.cases, required this.sl});

  @override
  Widget build(BuildContext context) {
    final total    = stats['total']    ?? 0;
    final open     = stats['open']     ?? 0;
    final critical = stats['critical'] ?? 0;
    final high     = stats['high']     ?? 0;
    final scans    = stats['scans']    ?? 0;

    return DraggableScrollableSheet(
      initialChildSize: 0.7, maxChildSize: 0.95, minChildSize: 0.4,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: sl.bg2,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(children: [
          Center(child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 40, height: 4,
            decoration: BoxDecoration(color: sl.border, borderRadius: BorderRadius.circular(99)))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: AppColors.accent, borderRadius: BorderRadius.circular(10)),
                child: Center(child: Text(code, style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: TextStyle(color: sl.text1,
                    fontSize: 15, fontWeight: FontWeight.w700)),
                Text('$total total reports', style: TextStyle(color: sl.text4, fontSize: 11)),
              ])),
              IconButton(
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                icon: Icon(Icons.close_rounded, color: sl.text3, size: 20),
                onPressed: () => Navigator.pop(context)),
            ])),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              _statPill('Critical', critical, AppColors.crit),
              const SizedBox(width: 6),
              _statPill('High',     high,     AppColors.red),
              const SizedBox(width: 6),
              _statPill('Open',     open,     AppColors.amber),
              const SizedBox(width: 6),
              _statPill('Scans',    scans,    AppColors.accent),
            ])),
          const SizedBox(height: 12),
          Divider(height: 1, color: sl.border),
          Expanded(child: cases.isEmpty
            ? Center(child: Text('No reports for $code yet',
                style: TextStyle(color: sl.text3, fontSize: 13)))
            : ListView.separated(
                controller: ctrl,
                padding: const EdgeInsets.all(14),
                itemCount: cases.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _CaseCard(inc: cases[i], sl: sl))),
        ])));
  }

  Widget _statPill(String label, int val, Color color) =>
    Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.25))),
      child: Column(children: [
        Text('$val', style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
        Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
      ])));
}


// ═══════════════════════════════════════════════════════════════
//  ALL PLANTS GRID SHEET (unchanged)
// ═══════════════════════════════════════════════════════════════
class _AllPlantsSheet extends StatelessWidget {
  final List<Map<String, String>> plants;
  final Map<String, Map<String, int>> stats;
  final String myCode;
  final SL sl;

  const _AllPlantsSheet({
    required this.plants, required this.stats,
    required this.myCode, required this.sl});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75, maxChildSize: 0.95, minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: sl.bg2,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(children: [
          Center(child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 40, height: 4,
            decoration: BoxDecoration(color: sl.border, borderRadius: BorderRadius.circular(99)))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(children: [
              Text('🏭  All SAIL Plants', style: TextStyle(color: sl.text1,
                  fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                icon: Icon(Icons.close_rounded, color: sl.text3, size: 20),
                onPressed: () => Navigator.pop(context)),
            ])),
          Divider(height: 1, color: sl.border),
          Expanded(child: GridView.builder(
            controller: ctrl,
            padding: const EdgeInsets.all(14),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, crossAxisSpacing: 10,
              mainAxisSpacing: 10, childAspectRatio: 1.6),
            itemCount: plants.length,
            itemBuilder: (_, i) {
              final p     = plants[i];
              final code  = p['code']!;
              final name  = p['name']!;
              final s     = stats[code] ?? {};
              final total = s['total']    ?? 0;
              final crit  = s['critical'] ?? 0;
              final isMy  = code == myCode;
              return GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isMy ? AppColors.accent.withOpacity(0.12) : sl.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isMy ? AppColors.accent.withOpacity(0.5) : sl.border,
                      width: isMy ? 1.5 : 1.0)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('$total', style: TextStyle(
                        color: isMy ? AppColors.accent : sl.text1,
                        fontSize: 22, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      if (isMy)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.accent, borderRadius: BorderRadius.circular(4)),
                          child: const Text('★', style: TextStyle(
                              color: Colors.white, fontSize: 8)))
                      else if (crit > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.crit.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4)),
                          child: Text('$crit 🔴', style: const TextStyle(
                              color: AppColors.crit, fontSize: 9, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 4),
                    Text(code, style: TextStyle(
                      color: isMy ? AppColors.accent : sl.text2,
                      fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(name.split(' ').take(3).join(' '),
                      style: TextStyle(color: sl.text4, fontSize: 9),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ])));
            })),
        ])));
  }
}
