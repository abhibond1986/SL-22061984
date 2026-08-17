// lib/screens/home_tab.dart
// Glass-morphism Home screen with infographics, charts, quick actions, and
// safety statistics. Uses I18n for full Hindi/English support.
//
// ✅ Daily safety-quote bar is an opaque amber → orange → red sunset gradient
//    (SAIL theme) with a soft red glow + subtle text shadow for legibility.
// ✅ Admin shield pill in the hero top-right opens the Command Centre.
//    Visible only when widget.user?['isAdmin'] is true.
// ✅ WSA-13 Bar Chart added to dashboard

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import '../services/local_db.dart';
import '../services/admin_master_data.dart';
import '../services/plant_scope.dart';
import '../services/sync_service.dart';
import '../services/i18n.dart';
import '../services/realtime_sync.dart';
import 'reports_tab.dart';
import 'admin_screen.dart';
import '../widgets/universal_app_bar.dart';
import '../widgets/wsa_bar_chart.dart';

class HomeTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback toggleTheme;
  final VoidCallback onSignOut;
  final bool isDark;
  final void Function(int tabIndex) onTabChange;

  const HomeTab({
    super.key,
    required this.user,
    required this.toggleTheme,
    required this.onSignOut,
    required this.isDark,
    required this.onTabChange,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  List<Map<String, dynamic>> _incidents = [];
  bool _loading = true;
  // Active canonical plant list (admin-editable) for name normalization.
  List<Map<String, String>> _plantDefs = AdminMasterData.sailPlants;
  // Statuses counted as "still open", derived from the admin's status list so
  // adding a workflow stage doesn't silently exclude those incidents.
  Set<String> _openStatuses =
      AdminMasterData.openStatusesFrom(AdminMasterData.defaultStatuses);
  // Full status ladder, used to attribute a blank status to the admin's FIRST
  // stage instead of a literal 'OPEN'.
  List<String> _statuses = List<String>.from(AdminMasterData.defaultStatuses);
  // The closing status — the last rung of the admin's ladder, not 'CLOSED'.
  String _closedStatus = 'CLOSED';
  /// Which plant's data this landing screen may show. Every stat below used to
  /// be computed over ALL incidents with no plant filter, so a plant user's
  /// "home" numbers were really SAIL-wide.
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);

  @override
  void initState() {
    super.initState();
    I18n.instance.addListener(_rebuild);
    _load();
    RealtimeSync.incidentsRevision.addListener(_onRealtime);
    AdminMasterData.revision.addListener(_onRealtime);
  }

  @override
  void dispose() {
    I18n.instance.removeListener(_rebuild);
    RealtimeSync.incidentsRevision.removeListener(_onRealtime);
    AdminMasterData.revision.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    if (mounted) _loadLocalOnly();
  }

  /// Refresh from the local cache only (realtime already updated LocalDB) —
  /// avoids a redundant fullSync round-trip on every live change.
  Future<void> _loadLocalOnly() async {
    // Guards against out-of-order completion. One sync bumps AdminMasterData
    // .revision once per master-data list it writes (six) plus incidentsRevision
    // once, and _onRealtime answers each, so seven of these can be in flight
    // together. Whichever finishes last used to win regardless of which started
    // last; now a superseded load discards its result.
    final gen = ++_loadGen;
    // Re-resolve the scope on every reload: the admin can change a user's plant
    // (or admin flag) live, and a stale scope would keep the old visibility.
    final scope = await PlantScope.forUser();
    // Scope at the source so no stat, chart or activity row below can reach
    // another plant's records.
    final inc = await scope.filterIncidents(await LocalDB.getIncidents());
    final plants = await AdminMasterData.getPlants();
    final openStatuses = await AdminMasterData.getOpenStatuses();
    final statuses = await AdminMasterData.getStatuses();
    final closed = await AdminMasterData.lastStatus();
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _scope = scope;
      _incidents = inc;
      _plantDefs = plants;
      _openStatuses = openStatuses;
      _statuses = statuses;
      _closedStatus = closed.toUpperCase();
      _loading = false;
    });
  }

  /// See [_loadLocalOnly] — sequence number for in-flight local reloads.
  int _loadGen = 0;

  void _rebuild() { if (mounted) setState(() {}); }

  /// Refresh this screen.
  ///
  /// CACHE FIRST, NETWORK SECOND. This used to await fullSync() before its first
  /// setState, so `_loading` stayed true — a spinner, or a wall of zeros — for as
  /// long as the backend took, up to the full 12s timeout, on every single visit
  /// to the Home tab. The cached numbers were sitting in LocalDB the whole time.
  /// Now they are painted immediately and the sync result lands on top when it
  /// arrives.
  ///
  /// [force] is passed through to [SyncService.fullSync]: false for the
  /// initState call (which happens on every tab switch and should reuse a recent
  /// sync), true for pull-to-refresh, where the user is explicitly asking the
  /// network to be consulted.
  Future<void> _load({bool force = false}) async {
    // Paint what we already have. Cheap — all local reads.
    await _loadLocalOnly();

    // Then reconcile with the backend. Bounded so a slow network can't hang the
    // refresh; the screen is already usable either way.
    try {
      await SyncService.fullSync(force: force)
          .timeout(const Duration(seconds: 12), onTimeout: () => <String, dynamic>{});
    } catch (_) {}
    if (!mounted) return;
    // Re-read from LocalDB, which the sync has just rewritten. This was a
    // duplicated copy of _loadLocalOnly's six reads and setState; collapsed so
    // the two paths cannot drift (and so the generation guard covers both).
    await _loadLocalOnly();
  }

  /// True for admin users. Accepts boolean, 'true', or 'TRUE' string forms.
  bool _isAdmin() {
    final v = widget.user?['isAdmin'];
    if (v is bool) return v;
    return v?.toString().toLowerCase() == 'true';
  }

  void _openAdminPanel() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const AdminScreen()));
  }

  // ── COMPUTED STATS ─────────────────────────────────────────────
  /// A blank status counts as the FIRST status in the admin's ladder, not a
  /// literal 'OPEN' — renaming that stage otherwise leaves those records
  /// uncounted in every bucket.
  String _statusOf(Map<String, dynamic> i) {
    final s = i['status']?.toString().trim().toUpperCase() ?? '';
    if (s.isNotEmpty) return s;
    return _statuses.isEmpty ? '' : _statuses.first.trim().toUpperCase();
  }

  int get _total    => _incidents.length;
  int get _open     => _incidents.where((i) {
    final s = _statusOf(i);
    if (s.isEmpty) return _openStatuses.isNotEmpty;
    return _openStatuses.contains(s);
  }).length;
  // Closed-ness comes from the admin's closing status, not a literal 'CLOSED',
  // so renaming the final stage doesn't zero this card.
  int get _closed   => _incidents.where((i) =>
      _closedStatus.isNotEmpty && _statusOf(i) == _closedStatus).length;
  int get _critical => _incidents.where((i) =>
      i['severity']?.toString().toUpperCase() == 'CRITICAL').length;

  int get _thisWeek {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    return _incidents.where((i) {
      final d = DateTime.tryParse(i['date']?.toString() ?? '');
      return d != null && d.isAfter(cutoff);
    }).length;
  }

  /// Days since the most recent critical case (LTI proxy)
  int get _daysSinceLTI {
    final crits = _incidents.where((i) =>
        i['severity']?.toString().toUpperCase() == 'CRITICAL').toList();
    if (crits.isEmpty) return 365;
    crits.sort((a, b) =>
        (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    final last = DateTime.tryParse(crits.first['date']?.toString() ?? '');
    if (last == null) return 365;
    return DateTime.now().difference(last).inDays;
  }

  /// 0-100 safety score (higher = better)
  int get _safetyScore {
    if (_total == 0) return 100;
    final critPenalty = (_critical / _total) * 60;
    final openPenalty = (_open / _total) * 25;
    return (100 - critPenalty - openPenalty).clamp(0, 100).round();
  }

  /// 10 motivational safety quotes — rotate by day of year
  static const List<String> _safetyQuotes = [
    'Safety isn\'t expensive, it\'s priceless.',
    'सुरक्षा सबकी ज़िम्मेदारी, लापरवाही सबकी हानि।',
    'A safe worker is a smart worker. Take a moment, save a life.',
    'जो जागे, सो सुरक्षित। चूके, तो दुर्घटना।',
    'Zero harm is not a goal — it is the only acceptable result.',
    'Stop. Think. Act. Every shift, every task, every time.',
    'सुरक्षा पहले — कार्य बाद में।',
    'The best safety device is a careful worker who follows the procedure.',
    'सावधानी हटी, दुर्घटना घटी।',
    'Your family is waiting at home. Come back safe.',
  ];

  String get _todaysQuote {
    final dayOfYear = DateTime.now().difference(
        DateTime(DateTime.now().year, 1, 1)).inDays;
    return _safetyQuotes[dayOfYear % _safetyQuotes.length];
  }

  /// Helper — match incidents to the current user via name or pno
  bool _isMyIncident(Map<String, dynamic> i) {
    final myName = (widget.user?['name']?.toString() ?? '').trim().toLowerCase();
    final myPno  = (widget.user?['pno']?.toString()  ?? '').trim().toLowerCase();
    final reportedBy = (i['reportedBy']?.toString()    ?? '').trim().toLowerCase();
    final reportedPno = (i['reportedByPno']?.toString() ?? '').trim().toLowerCase();
    if (myName.isEmpty && myPno.isEmpty) return false;
    if (myPno.isNotEmpty && reportedPno == myPno) return true;
    if (myName.isNotEmpty && reportedBy == myName) return true;
    return false;
  }

  /// My own AI scans count
  int get _myAiScans => _incidents.where((i) =>
      _isMyIncident(i) &&
      (i['type']?.toString().toUpperCase() ?? '') == 'AI_SCAN').length;

  /// My own Near Miss reports count
  int get _myNearMiss => _incidents.where((i) =>
      _isMyIncident(i) &&
      (i['type']?.toString().toUpperCase() ?? '') == 'NEAR_MISS').length;

  /// Hazard counts per plant (top 5), grouped by canonical plant name.
  List<MapEntry<String, int>> get _byPlant {
    final m = <String, int>{};
    for (final i in _incidents) {
      final p = AdminMasterData.canonicalPlantFrom(
          i['plant']?.toString() ?? '', _plantDefs);
      if (p.isEmpty) continue;
      m[p] = (m[p] ?? 0) + 1;
    }
    final list = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list.take(5).toList();
  }

  /// Last 7 days incident counts
  List<int> get _weeklyTrend {
    final result = List<int>.filled(7, 0);
    final now = DateTime.now();
    for (final i in _incidents) {
      final d = DateTime.tryParse(i['date']?.toString() ?? '');
      if (d == null) continue;
      final diff = now.difference(d).inDays;
      if (diff >= 0 && diff < 7) result[6 - diff]++;
    }
    return result;
  }

  String get _greetingKey {
    final h = DateTime.now().hour;
    if (h < 12) return 'home.greeting.morning';
    if (h < 18) return 'home.greeting.afternoon';
    return 'home.greeting.evening';
  }

  // ── BUILD ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final firstName = (widget.user?['name']?.toString() ?? 'User').split(' ').first;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: UniversalAppBar(
        title: I18n.t('app.name'),
        subtitle: I18n.t('app.tagline'),
        user: widget.user,
        toggleTheme: widget.toggleTheme,
        onSignOut: widget.onSignOut,
        isDark: widget.isDark,
      ),
      body: _loading
        ? Center(child: CircularProgressIndicator(color: AppColors.accent))
        // An unresolved scope is reported, not silently widened to all plants.
        : _scope.problem != null
        ? Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(_scope.problem!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: sl.text3, fontSize: 13, height: 1.5)),
            ),
          )
        : RefreshIndicator(
            // A deliberate user gesture, so it bypasses the sync throttle.
            onRefresh: () => _load(force: true),
            color: AppColors.accent,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              child: Column(children: [
                _heroSection(sl, firstName),
                const SizedBox(height: 16),
                _statsGrid(sl),
                const SizedBox(height: 18),
                _safetyScoreCard(sl),
                const SizedBox(height: 18),
                // ✅ WSA-13 Bar Chart with plant filter
                const WsaBarChart(),
                const SizedBox(height: 18),
                _quickActionsGrid(sl),
                const SizedBox(height: 18),
                _weeklyTrendCard(sl),
                const SizedBox(height: 18),
                // "Top 5 plants" compares plants against each other, which is
                // meaningless once the data is scoped to one plant — it would
                // render a single full-width bar. Admins keep the comparison.
                if (!_scope.isLocked) ...[
                  _topPlantsCard(sl),
                  const SizedBox(height: 18),
                ],
                _recentActivity(sl),
                const SizedBox(height: 24),
              ]),
            )),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HERO — gradient + greeting + days since LTI
  // ═══════════════════════════════════════════════════════════════
  Widget _heroSection(SL sl, String firstName) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [
            Color(0xFF2C3A66),  // deep steel indigo
            Color(0xFF4F5BD5),  // steel indigo (primary)
            Color(0xFF0EA5B5),  // industrial teal
          ],
          stops: [0.0, 0.6, 1.0],
        )),
      child: Stack(children: [
        // Decorative blurred circles
        Positioned(top: -30, right: -20,
          child: _glow(80, Colors.white.withOpacity(0.18))),
        Positioned(bottom: -40, left: -30,
          child: _glow(120, Colors.white.withOpacity(0.12))),

        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Greeting row — with ADMIN shield pill on the right for admins only
          Row(children: [
            const Icon(Icons.waving_hand_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(I18n.t(_greetingKey),
                style: const TextStyle(color: Colors.white70, fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const Spacer(),
            if (_isAdmin())
              GestureDetector(
                onTap: _openAdminPanel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [Color(0xFFD97706), Color(0xFFB45309)]),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.white.withOpacity(0.4), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFB45309).withOpacity(0.45),
                        blurRadius: 10,
                        offset: const Offset(0, 2)),
                    ],
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.shield_moon_rounded,
                        color: Colors.white, size: 14),
                    SizedBox(width: 5),
                    Text('ADMIN',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          // Full name (use first name from name field)
          Text(widget.user?['name']?.toString() ?? firstName,
              style: const TextStyle(color: Colors.white, fontSize: 24,
                  fontWeight: FontWeight.w800, height: 1.1)),
          const SizedBox(height: 4),
          // Designation + Plant
          Row(children: [
            if ((widget.user?['designation']?.toString() ?? '').isNotEmpty) ...[
              Icon(Icons.work_outline_rounded,
                  color: Colors.white.withOpacity(0.85), size: 12),
              const SizedBox(width: 4),
              Text(widget.user!['designation'].toString(),
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
            ],
            if ((widget.user?['plant']?.toString() ?? '').isNotEmpty) ...[
              Icon(Icons.factory_outlined,
                  color: Colors.white.withOpacity(0.85), size: 12),
              const SizedBox(width: 4),
              Flexible(child: Text(widget.user!['plant'].toString(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 12, fontWeight: FontWeight.w600))),
            ],
          ]),
          const SizedBox(height: 12),
          // ── DAILY SAFETY QUOTE — amber → orange → red sunset (SAIL theme)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end:   Alignment.centerRight,
                colors: [
                  Color(0xFFF59E0B),   // amber-500
                  Color(0xFFEA580C),   // orange-600
                  Color(0xFFDC2626),   // red-600
                ],
                stops: [0.0, 0.55, 1.0],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: Colors.white.withOpacity(0.25), width: 1),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFDC2626).withOpacity(0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(children: [
              const Icon(Icons.format_quote_rounded,
                  color: Colors.white, size: 15),
              const SizedBox(width: 6),
              Expanded(child: Text(_todaysQuote,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11.5,
                      fontStyle: FontStyle.italic, height: 1.3,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.15,
                      shadows: [
                        Shadow(
                          color: Color(0x66000000),
                          offset: Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ]))),
            ]),
          ),
          const SizedBox(height: 14),

          // Glass card — MY AI Scans + Near Miss breakdown
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Colors.white.withOpacity(0.25), width: 1)),
                child: Row(children: [
                  // My AI Scans
                  Expanded(child: GestureDetector(
                    onTap: () {
                      ReportsTab.pendingStatusFilter = null;
                      ReportsTab.pendingSeverityFilter = null;
                      ReportsTab.pendingTypeFilter = 'AI_SCAN';
                      ReportsTab.pendingMyReportsOnly = true;
                      ReportsTab.pendingGoToLog = true;
                      widget.onTabChange(4); // go to Reports → Log tab
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.camera_alt_rounded,
                              color: Colors.white, size: 14),
                          const SizedBox(width: 5),
                          Text('My AI Scans',
                              style: TextStyle(color: Colors.white70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3)),
                        ]),
                        const SizedBox(height: 4),
                        Text('$_myAiScans',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.w800, height: 1)),
                        Text('hazard scans',
                            style: TextStyle(color: Colors.white.withOpacity(0.7),
                                fontSize: 9)),
                      ]),
                  )),
                  // Vertical divider
                  Container(width: 1, height: 60,
                      color: Colors.white.withOpacity(0.25),
                      margin: const EdgeInsets.symmetric(horizontal: 10)),
                  // My Near Miss
                  Expanded(child: GestureDetector(
                    onTap: () {
                      ReportsTab.pendingStatusFilter = null;
                      ReportsTab.pendingSeverityFilter = null;
                      ReportsTab.pendingTypeFilter = 'NEAR_MISS';
                      ReportsTab.pendingMyReportsOnly = true;
                      ReportsTab.pendingGoToLog = true;
                      widget.onTabChange(4); // go to Reports → Log tab
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: Colors.white, size: 14),
                          const SizedBox(width: 5),
                          Text('My Near Miss',
                              style: TextStyle(color: Colors.white70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3)),
                        ]),
                        const SizedBox(height: 4),
                        Text('$_myNearMiss',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.w800, height: 1)),
                        Text('reported',
                            style: TextStyle(color: Colors.white.withOpacity(0.7),
                                fontSize: 9)),
                      ]),
                  )),
                ]),
              ))),
        ]),
      ]),
    );
  }

  Widget _glow(double size, Color color) => Container(
    width: size, height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color));

  // ═══════════════════════════════════════════════════════════════
  //  STATS GRID — 4 cards
  // ═══════════════════════════════════════════════════════════════
  Widget _statsGrid(SL sl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(children: [
        Row(children: [
          // Total Cases → Reports (no filter)
          Expanded(child: _statTile(
              sl, I18n.t('home.totalCases'), '$_total',
              Icons.assessment_rounded, const Color(0xFF6366F1),
              onTap: () => _goReports(null, null))),
          const SizedBox(width: 8),
          // Open → Reports filtered by the admin's FIRST status, not a literal
          // 'OPEN' that no longer exists once the stage is renamed.
          Expanded(child: _statTile(
              sl, I18n.t('home.openCases'), '$_open',
              Icons.lock_open_rounded, const Color(0xFFF59E0B),
              onTap: () => _goReports(null,
                  _statuses.isEmpty ? null : _statuses.first.toUpperCase()))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          // Critical → Reports filtered by CRITICAL severity
          Expanded(child: _statTile(
              sl, I18n.t('home.criticalCases'), '$_critical',
              Icons.warning_rounded, const Color(0xFFEF4444),
              onTap: () => _goReports('CRITICAL', null))),
          const SizedBox(width: 8),
          // Closed → Reports filtered by the admin's closing status.
          Expanded(child: _statTile(
              sl, I18n.t('home.closedCases'), '$_closed',
              Icons.check_circle_rounded, const Color(0xFF10B981),
              onTap: () => _goReports(null,
                  _closedStatus.isEmpty ? null : _closedStatus))),
        ]),
      ]),
    );
  }

  /// Navigate to Reports tab with given filters applied
  void _goReports(String? severityFilter, String? statusFilter) {
    ReportsTab.pendingSeverityFilter = severityFilter;
    ReportsTab.pendingStatusFilter   = statusFilter;
    widget.onTabChange(4);
  }

  Widget _statTile(SL sl, String label, String value, IconData icon, Color color,
      {VoidCallback? onTap}) {
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.card.withOpacity(0.7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.25), width: 1)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 18)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4)),
                child: Text(I18n.t('home.thisWeek'),
                    style: TextStyle(color: color, fontSize: 10,
                        fontWeight: FontWeight.w700, letterSpacing: 0.3))),
            ]),
            const SizedBox(height: 12),
            Text(value,
                style: TextStyle(color: sl.text1, fontSize: 26,
                    fontWeight: FontWeight.w800, height: 1)),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(color: sl.text3, fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ]),
        )),
    );
    if (onTap == null) return tile;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: tile,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SAFETY SCORE GAUGE
  // ═══════════════════════════════════════════════════════════════
  Widget _safetyScoreCard(SL sl) {
    final score = _safetyScore;
    Color scoreColor;
    String label;
    if (score >= 80)      { scoreColor = const Color(0xFF10B981); label = 'Excellent'; }
    else if (score >= 60) { scoreColor = const Color(0xFFF59E0B); label = 'Good'; }
    else if (score >= 40) { scoreColor = const Color(0xFFF97316); label = 'Average'; }
    else                  { scoreColor = const Color(0xFFEF4444); label = 'Needs Attention'; }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: sl.card.withOpacity(0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: sl.border, width: 1)),
            child: Row(children: [
              // Circular gauge
              SizedBox(width: 90, height: 90,
                child: CustomPaint(
                  painter: _GaugePainter(
                    progress: score / 100,
                    color: scoreColor,
                    trackColor: sl.border,
                  ),
                  child: Center(child: Column(
                    mainAxisSize: MainAxisSize.min, children: [
                    Text('$score',
                        style: TextStyle(color: scoreColor, fontSize: 26,
                            fontWeight: FontWeight.w800, height: 1)),
                    Text('/100',
                        style: TextStyle(color: sl.text4, fontSize: 9)),
                  ])),
                )),
              const SizedBox(width: 16),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(I18n.t('home.safetyScore'),
                    style: TextStyle(color: sl.text3, fontSize: 11,
                        fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(color: scoreColor, fontSize: 18,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                _miniProgressRow(sl, 'Open vs Closed',
                    _total == 0 ? 1 : _closed / _total,
                    AppColors.green),
                const SizedBox(height: 5),
                _miniProgressRow(sl, 'Critical Ratio',
                    _total == 0 ? 0 : 1 - (_critical / _total),
                    AppColors.red),
              ])),
            ]),
          ))),
    );
  }

  Widget _miniProgressRow(SL sl, String label, double v, Color color) {
    return Row(children: [
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: sl.text4, fontSize: 9)),
        const SizedBox(height: 2),
        Container(
          height: 5, width: double.infinity,
          decoration: BoxDecoration(
              color: sl.border, borderRadius: BorderRadius.circular(3)),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v.clamp(0, 1),
            child: Container(decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
          )),
      ])),
      const SizedBox(width: 6),
      Text('${(v * 100).clamp(0, 100).round()}%',
          style: TextStyle(color: color, fontSize: 10,
              fontWeight: FontWeight.w700)),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  //  QUICK ACTIONS — 2x2 grid
  // ═══════════════════════════════════════════════════════════════
  Widget _quickActionsGrid(SL sl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle(sl, I18n.t('home.quickActions'), Icons.flash_on_rounded),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _actionCard(sl,
              icon: Icons.camera_alt_rounded,
              label: I18n.t('home.startScan'),
              color: const Color(0xFF8B5CF6),
              onTap: () => widget.onTabChange(1))),
          const SizedBox(width: 8),
          Expanded(child: _actionCard(sl,
              icon: Icons.warning_amber_rounded,
              label: I18n.t('home.reportNearMiss'),
              color: const Color(0xFFF59E0B),
              onTap: () => widget.onTabChange(2))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _actionCard(sl,
              icon: Icons.assessment_rounded,
              label: I18n.t('home.viewReports'),
              color: const Color(0xFF06B6D4),
              onTap: () => widget.onTabChange(4))),
          const SizedBox(width: 8),
          Expanded(child: _actionCard(sl,
              icon: Icons.support_agent_rounded,
              label: I18n.t('home.askExpert'),
              color: const Color(0xFF10B981),
              onTap: () => widget.onTabChange(3))),
        ]),
      ]),
    );
  }

  Widget _actionCard(SL sl, {required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Container(
            height: 90,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [color.withOpacity(0.12), color.withOpacity(0.03)]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.3), width: 1)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 20)),
              Text(label,
                style: TextStyle(color: sl.text1, fontSize: 12,
                    fontWeight: FontWeight.w700, height: 1.2)),
            ]),
          ))),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  WEEKLY TREND CHART
  // ═══════════════════════════════════════════════════════════════
  Widget _weeklyTrendCard(SL sl) {
    final data = _weeklyTrend;
    final maxV = data.fold<int>(1, (m, v) => v > m ? v : m);
    final dayLabels = ['M','T','W','T','F','S','S'];
    final todayDow  = (DateTime.now().weekday - 1) % 7;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: sl.card.withOpacity(0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: sl.border, width: 1)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.trending_up_rounded, color: AppColors.accent, size: 16),
                const SizedBox(width: 6),
                Text(I18n.t('home.weeklyTrend'),
                    style: TextStyle(color: sl.text1, fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('$_thisWeek ${I18n.t('home.thisWeek').toLowerCase()}',
                    style: TextStyle(color: sl.text4, fontSize: 10)),
              ]),
              const SizedBox(height: 16),
              SizedBox(height: 90, child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(7, (i) {
                  final v = data[i];
                  final h = maxV == 0 ? 4.0 : (v / maxV) * 70 + 4;
                  final isToday = i == 6;
                  return Expanded(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(v > 0 ? '$v' : '',
                          style: TextStyle(color: sl.text3, fontSize: 9,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 600),
                        height: h,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter, end: Alignment.bottomCenter,
                            colors: isToday
                              ? [AppColors.accent, AppColors.accent.withOpacity(0.4)]
                              : [AppColors.cyan.withOpacity(0.7),
                                 AppColors.cyan.withOpacity(0.2)]),
                          borderRadius: BorderRadius.circular(4))),
                      const SizedBox(height: 4),
                      Text(dayLabels[(todayDow - (6 - i) + 7) % 7],
                          style: TextStyle(
                              color: isToday ? AppColors.accent : sl.text4,
                              fontSize: 9,
                              fontWeight: isToday ? FontWeight.w800 : FontWeight.w500)),
                    ]),
                  ));
                }))),
            ]),
          ))),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TOP PLANTS — horizontal bar chart
  // ═══════════════════════════════════════════════════════════════
  Widget _topPlantsCard(SL sl) {
    final list = _byPlant;
    if (list.isEmpty) return const SizedBox.shrink();
    final maxV = list.first.value;
    final colors = [
      AppColors.crit, AppColors.red, AppColors.amber,
      AppColors.cyan, AppColors.green
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: sl.card.withOpacity(0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: sl.border, width: 1)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.factory_outlined, color: AppColors.accent, size: 16),
                const SizedBox(width: 6),
                Text(I18n.t('home.byPlant'),
                    style: TextStyle(color: sl.text1, fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 14),
              ...List.generate(list.length, (i) {
                final entry = list[i];
                final pct   = entry.value / maxV;
                final color = colors[i % colors.length];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(children: [
                    SizedBox(width: 100,
                      child: Text(entry.key,
                        style: TextStyle(color: sl.text2, fontSize: 11),
                        overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Expanded(child: Stack(children: [
                      Container(height: 14,
                        decoration: BoxDecoration(
                          color: sl.border.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(7))),
                      FractionallySizedBox(
                        widthFactor: pct,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 800),
                          height: 14,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                                colors: [color, color.withOpacity(0.6)]),
                            borderRadius: BorderRadius.circular(7))),
                      ),
                    ])),
                    const SizedBox(width: 8),
                    SizedBox(width: 20,
                      child: Text('${entry.value}',
                          textAlign: TextAlign.right,
                          style: TextStyle(color: color, fontSize: 12,
                              fontWeight: FontWeight.w800))),
                  ]),
                );
              }),
            ]),
          ))),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  RECENT ACTIVITY
  // ═══════════════════════════════════════════════════════════════
  Widget _recentActivity(SL sl) {
    final recent = _incidents.toList()
      ..sort((a, b) =>
          (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    final list = recent.take(3).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _sectionTitle(sl, I18n.t('home.recentActivity'),
              Icons.history_rounded),
          const Spacer(),
          GestureDetector(
            onTap: () => widget.onTabChange(4),
            child: Row(children: [
              Text(I18n.t('home.viewAll'),
                  style: const TextStyle(color: AppColors.accent,
                      fontSize: 11, fontWeight: FontWeight.w600)),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.accent, size: 14),
            ])),
        ]),
        const SizedBox(height: 10),
        if (list.isEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
              decoration: BoxDecoration(
                color: sl.card.withOpacity(0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sl.border)),
              child: Center(child: Column(children: [
                Icon(Icons.inbox_outlined, color: sl.text4, size: 32),
                const SizedBox(height: 8),
                Text(I18n.t('home.noData'),
                    style: TextStyle(color: sl.text3, fontSize: 12)),
              ])),
            ))
        else
          ...list.map((i) => _recentItem(sl, i)),
      ]),
    );
  }

  Widget _recentItem(SL sl, Map<String, dynamic> i) {
    final sev = i['severity']?.toString().toUpperCase() ?? 'MEDIUM';
    // Blank status resolves to the admin's first stage, not a literal 'OPEN'.
    final status = _statusOf(i);
    Color sevColor;
    switch (sev) {
      case 'CRITICAL': sevColor = AppColors.crit; break;
      case 'HIGH':     sevColor = AppColors.red;  break;
      case 'MEDIUM':   sevColor = AppColors.amber; break;
      default:         sevColor = AppColors.green;
    }
    final date = (i['date']?.toString() ?? '');
    final dateStr = date.length > 10 ? date.substring(0, 10) : date;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: sl.card.withOpacity(0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: sevColor, width: 3),
                top: BorderSide(color: sl.border.withOpacity(0.5)),
                right: BorderSide(color: sl.border.withOpacity(0.5)),
                bottom: BorderSide(color: sl.border.withOpacity(0.5)))),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: sevColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10)),
                child: Icon(
                    sev == 'CRITICAL' ? Icons.warning_rounded
                        : sev == 'HIGH' ? Icons.error_outline_rounded
                        : Icons.info_outline_rounded,
                    color: sevColor, size: 18)),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i['title']?.toString() ?? 'Untitled',
                    style: TextStyle(color: sl.text1, fontSize: 12,
                        fontWeight: FontWeight.w700),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${i['plant'] ?? '—'} · $dateStr',
                    style: TextStyle(color: sl.text4, fontSize: 10)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: sevColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4)),
                child: Text(sev,
                    style: TextStyle(color: sevColor, fontSize: 8,
                        fontWeight: FontWeight.w800))),
            ]),
          ))),
    );
  }

  Widget _sectionTitle(SL sl, String title, IconData icon) => Row(children: [
    Container(width: 3, height: 14,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(2))),
    const SizedBox(width: 8),
    Icon(icon, color: AppColors.accent, size: 14),
    const SizedBox(width: 6),
    Text(title, style: TextStyle(color: sl.text1, fontSize: 14,
        fontWeight: FontWeight.w700)),
  ]);
}

// ═══════════════════════════════════════════════════════════════════
//  CIRCULAR GAUGE PAINTER for Safety Score
// ═══════════════════════════════════════════════════════════════════
class _GaugePainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  final Color trackColor;
  _GaugePainter({required this.progress, required this.color,
      required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 6;

    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..shader = SweepGradient(
        colors: [color.withOpacity(0.4), color],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.progress != progress || old.color != color;
}
