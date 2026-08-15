import 'dart:convert' show base64Decode;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../main.dart' show AppColors, SL;
import '../../services/local_db.dart';
import '../../services/admin_master_data.dart';
import '../../services/plant_scope.dart';
import '../../services/realtime_sync.dart';
import '../incident_detail_screen.dart';

/// Org overview.
///
/// It used to compute every KPI and chart over ALL incidents with no plant
/// filter, so a plant user's "overview" was actually SAIL-wide. The data is now
/// scoped through PlantScope at load time. There is deliberately no plant
/// selector — this screen never had one — so an admin still sees org-wide
/// figures and a plant user sees only their own plant.
class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key});
  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  List<Map<String, dynamic>> _incidents = [];
  List<Map<String, dynamic>> _allIncidents = []; // Unscoped incidents for SPI calculation
  bool _loading = true;
  bool _spiExpanded = false;
  bool _spiCardVisible = true; // Admin-controlled setting
  Map<String, int> _spiParams = Map<String, int>.from(AdminMasterData.defaultSpiParams);
  // Admin-configured severities, so charts show exactly the levels the admin
  // defined (a renamed level no longer leaves a phantom zero row).
  List<String> _severities =
      List<String>.from(AdminMasterData.defaultSeverities);
  // Admin-configured workflow statuses, in the admin's own order — the
  // pipeline used to hardcode four and silently dropped VERIFIED.
  List<String> _statuses =
      List<String>.from(AdminMasterData.defaultStatuses);
  // Statuses that mean "still open", from the admin's own ladder. The KPIs used
  // to test `status != 'CLOSED'`, which counted a renamed final stage as open
  // and counted VERIFIED as open too.
  Set<String> _openStatuses =
      AdminMasterData.openStatusesFrom(AdminMasterData.defaultStatuses);
  // The closing status — the last rung of the admin's ladder, not a literal.
  String _closedStatus = 'CLOSED';
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);

  @override
  void initState() {
    super.initState();
    _load();
    RealtimeSync.incidentsRevision.addListener(_onRealtime);
    AdminMasterData.revision.addListener(_load);
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_onRealtime);
    AdminMasterData.revision.removeListener(_load);
    super.dispose();
  }

  void _onRealtime() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final scope = await PlantScope.forUser();
    final allInc = await LocalDB.getIncidents(); // Unscoped incidents for SPI
    // Scope the data at the source: a non-admin never holds another plant's
    // records in memory, so no KPI, chart or drill-through sheet below can
    // reveal them.
    final inc = await scope.filterIncidents(allInc);
    final sevs = await AdminMasterData.getSeverities();
    final statuses = await AdminMasterData.getStatuses();
    final open = await AdminMasterData.getOpenStatuses();
    final closed = await AdminMasterData.lastStatus();
    final spiVisible = await AdminMasterData.getSpiCardVisible();
    final spiParams = await AdminMasterData.getSpiParams();
    if (mounted) {
      setState(() {
        _scope = scope;
        _incidents = inc;
        _allIncidents = allInc; // Store unscoped for SPI calculation
        _severities = sevs;
        _statuses = statuses;
        _openStatuses = open;
        _closedStatus = closed.toUpperCase();
        _spiCardVisible = spiVisible;
        _spiParams = spiParams;
        _loading = false;
      });
    }
  }

  /// A record with no status counts as the FIRST status in the admin's ladder,
  /// not a literal 'OPEN' — renaming that stage otherwise creates a phantom
  /// 'OPEN' bucket alongside the real one.
  String _statusOf(Map<String, dynamic> i) {
    final s = (i['status']?.toString().trim().toUpperCase() ?? '');
    if (s.isNotEmpty) return s;
    return _statuses.isEmpty ? '' : _statuses.first.trim().toUpperCase();
  }

  /// True when [i] is still open, per the ADMIN's status ladder. Previously
  /// `status != 'CLOSED'`, which counted a renamed final stage as open and
  /// treated VERIFIED as open too.
  bool _isOpen(Map<String, dynamic> i) {
    final s = _statusOf(i);
    if (s.isEmpty) return _openStatuses.isNotEmpty;
    return _openStatuses.contains(s);
  }

  /// True when [i] sits at the admin's closing status.
  bool _isClosed(Map<String, dynamic> i) =>
      _closedStatus.isNotEmpty && _statusOf(i) == _closedStatus;

  // ── COMPUTED KPIs ─────────────────────────────────────────────
  int get _total => _incidents.length;

  int get _open => _incidents.where(_isOpen).length;

  int get _closed => _incidents.where(_isClosed).length;

  double get _closureRate => _total == 0 ? 0 : (_closed / _total * 100);

  int get _daysSinceCritical {
    final crits = _incidents.where((i) =>
        i['severity']?.toString().toUpperCase() == 'CRITICAL').toList();
    if (crits.isEmpty) return 365;
    crits.sort((a, b) =>
        (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    final last = DateTime.tryParse(crits.first['date']?.toString() ?? '');
    if (last == null) return 365;
    return DateTime.now().difference(last).inDays;
  }

  double get _avgClosureTime {
    // Closed-ness comes from the admin's closing status, not a literal 'CLOSED'.
    final closedInc = _incidents.where((i) =>
        _isClosed(i) &&
        i['closedAt'] != null && i['date'] != null).toList();
    if (closedInc.isEmpty) return 0;
    double totalDays = 0;
    for (final i in closedInc) {
      final opened = DateTime.tryParse(i['date'].toString());
      final closed = DateTime.tryParse(i['closedAt'].toString());
      if (opened != null && closed != null) {
        totalDays += closed.difference(opened).inDays.abs();
      }
    }
    return totalDays / closedInc.length;
  }

  // Status counts. A blank status is attributed to the admin's first stage
  // rather than a hardcoded 'OPEN'.
  int _statusCount(String status) =>
      _incidents.where((i) => _statusOf(i) == status).length;

  // Severity counts
  Map<String, int> get _severityCounts {
    // Seeded from the admin's severity list (reverse-ordered so the most
    // severe reads first, matching the previous CRITICAL→LOW presentation).
    final m = <String, int>{
      for (final s in _severities.reversed) s.toUpperCase(): 0
    };
    for (final i in _incidents) {
      final s = (i['severity']?.toString().toUpperCase() ?? 'MEDIUM');
      m[s] = (m[s] ?? 0) + 1;
    }
    return m;
  }

  // Monthly trend (last 6 months)
  List<MapEntry<String, int>> get _monthlyTrend {
    final now = DateTime.now();
    final result = <String, int>{};
    for (int m = 5; m >= 0; m--) {
      final month = DateTime(now.year, now.month - m, 1);
      final key = '${_monthName(month.month)} ${month.year.toString().substring(2)}';
      result[key] = 0;
    }
    for (final i in _incidents) {
      final d = DateTime.tryParse(i['date']?.toString() ?? '');
      if (d == null) continue;
      final monthsDiff = (now.year - d.year) * 12 + (now.month - d.month);
      if (monthsDiff >= 0 && monthsDiff < 6) {
        final key = '${_monthName(d.month)} ${d.year.toString().substring(2)}';
        if (result.containsKey(key)) result[key] = result[key]! + 1;
      }
    }
    return result.entries.toList();
  }

  String _monthName(int m) {
    const names = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return names[((m - 1) % 12) + 1];
  }

  // Top problem areas
  String get _worstPlant {
    final m = <String, int>{};
    for (final i in _incidents) {
      // Skip finished cases via the admin's ladder, not a literal 'CLOSED'.
      if (!_isOpen(i)) continue;
      final p = i['plant']?.toString() ?? '';
      if (p.isNotEmpty) m[p] = (m[p] ?? 0) + 1;
    }
    if (m.isEmpty) return '—';
    final sorted = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return '${sorted.first.key} (${sorted.first.value} open)';
  }

  String get _worstCategory {
    final m = <String, int>{};
    for (final i in _incidents) {
      final c = i['wsaCategory']?.toString() ?? '';
      if (c.isNotEmpty) m[c] = (m[c] ?? 0) + 1;
    }
    if (m.isEmpty) return '—';
    final sorted = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return '${sorted.first.key} (${sorted.first.value})';
  }

  String get _longestOpen {
    // "Open" per the admin's ladder — was `!= 'CLOSED'`, which also counted
    // VERIFIED cases as still open.
    final openInc = _incidents.where(_isOpen).toList();
    if (openInc.isEmpty) return '—';
    openInc.sort((a, b) =>
        (a['date']?.toString() ?? '').compareTo(b['date']?.toString() ?? ''));
    final oldest = openInc.first;
    final d = DateTime.tryParse(oldest['date']?.toString() ?? '');
    if (d == null) return oldest['title']?.toString() ?? '—';
    final days = DateTime.now().difference(d).inDays;
    return '${oldest['title'] ?? 'Untitled'} ($days days)';
  }

  // ── SPI SCORECARD DATA ───────────────────────────────────────────
  List<_PlantScore> get _plantScores {
    final byPlant = <String, _PlantScore>{};
    final plants = AdminMasterData.sailPlants;

    // Use ALL incidents (unscoped) for organization-wide SPI calculation
    for (final inc in _allIncidents) {
      final plantRaw = inc['plant']?.toString() ?? '';
      final canon = AdminMasterData.canonicalPlantFrom(plantRaw, plants);
      final p = canon.isEmpty ? '—' : canon;

      byPlant.putIfAbsent(p, () => _PlantScore(p, _spiParams));
      final ps = byPlant[p]!;
      ps.total++;

      final sev = inc['severity']?.toString().toUpperCase() ?? '';
      final isClosed = _isClosed(inc);

      if (sev == 'CRITICAL') ps.critical++;
      if (sev == 'HIGH') ps.high++;
      if (isClosed) {
        ps.closed++;
      } else {
        ps.open++;
        if (sev == 'CRITICAL' || sev == 'HIGH') {
          final d = DateTime.tryParse(inc['date']?.toString() ?? '');
          if (d != null && DateTime.now().difference(d).inDays > 7) {
            ps.staleHighCritical++;
          }
        }
      }
    }

    final scores = byPlant.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return scores.where((s) => s.plant != '—').toList();
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // An unresolved scope is reported, not silently widened to all plants.
    if (_scope.problem != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(_scope.problem!,
              textAlign: TextAlign.center,
              style: TextStyle(color: sl.text3, fontSize: 13, height: 1.5)),
        ),
      );
    }
    if (_incidents.isEmpty) {
      // Name the plant for a locked user, so an empty overview can't be read as
      // "SAIL has no incidents".
      return Center(child: Text(
          _scope.isLocked
              ? 'No data recorded yet for ${_scope.plant}'
              : 'No data recorded yet',
          textAlign: TextAlign.center,
          style: TextStyle(color: sl.text3, fontSize: 14)));
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.accent,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Every card below is now plant-scoped, so a locked user gets one
          // header naming the scope. Without it these figures read as SAIL-wide,
          // which is exactly how this screen used to be wrong.
          if (_scope.isLocked) ...[
            _lockedPlantHeader(sl),
            const SizedBox(height: 12),
          ],
          _kpiStrip(sl),
          const SizedBox(height: 16),
          if (_spiCardVisible && _allIncidents.isNotEmpty) ...[
            _spiScorecard(sl),
            const SizedBox(height: 16),
          ],
          _statusPipeline(sl),
          const SizedBox(height: 16),
          _monthlyTrendChart(sl),
          const SizedBox(height: 16),
          _severityDonut(sl),
          const SizedBox(height: 16),
          _problemAreas(sl),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  LOCKED PLANT HEADER — states the scope, no affordance to change it
  // ═══════════════════════════════════════════════════════════════
  Widget _lockedPlantHeader(SL sl) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withOpacity(0.30)),
      ),
      child: Row(children: [
        const Icon(Icons.factory_rounded, size: 16, color: AppColors.accent),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('YOUR PLANT',
                style: TextStyle(
                    color: sl.text3,
                    fontSize: 9,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(_scope.plant,
                style: TextStyle(
                    color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  KPI STRIP — 5 metric cards (tappable)
  // ═══════════════════════════════════════════════════════════════
  Widget _kpiStrip(SL sl) {
    return Column(children: [
      Row(children: [
        _kpiCard(sl, 'Total', '$_total', Icons.assessment_rounded,
            const Color(0xFF6366F1), () => _showIncidentsSheet('All Incidents', _incidents)),
        const SizedBox(width: 8),
        // The drill-through lists must agree with the number above them, so they
        // use the same admin-driven open/closed tests rather than 'CLOSED'.
        _kpiCard(sl, 'Open', '$_open', Icons.warning_amber_rounded,
            AppColors.amber, () => _showIncidentsSheet('Open Incidents',
                _incidents.where(_isOpen).toList())),
        const SizedBox(width: 8),
        _kpiCard(sl, 'Avg Close', '${_avgClosureTime.toStringAsFixed(1)}d',
            Icons.timer_outlined, AppColors.cyan, () => _showIncidentsSheet('Closed Incidents',
                _incidents.where(_isClosed).toList())),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        _kpiCard(sl, 'LTI-Free', '$_daysSinceCritical d',
            Icons.shield_outlined, AppColors.green, () => _showIncidentsSheet('Critical Incidents',
                _incidents.where((i) => i['severity']?.toString().toUpperCase() == 'CRITICAL').toList())),
        const SizedBox(width: 8),
        _kpiCard(sl, 'Closure %', '${_closureRate.toStringAsFixed(0)}%',
            Icons.check_circle_outline, const Color(0xFF10B981), () => _showIncidentsSheet('Closed Incidents',
                _incidents.where(_isClosed).toList())),
        const SizedBox(width: 8),
        Expanded(child: Container()),
      ]),
    ]);
  }

  Widget _kpiCard(SL sl, String label, String value, IconData icon, Color color, [VoidCallback? onTap]) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: sl.glassColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withOpacity(0.3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(height: 8),
                Text(value, style: TextStyle(
                    color: sl.text1, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(
                    color: sl.text3, fontSize: 10, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  STATUS PIPELINE — stages come from the admin's status list, in order
  // ═══════════════════════════════════════════════════════════════
  /// Established colours for the standard SAIL pipeline; a status the admin
  /// invents gets a neutral colour rather than breaking the widget.
  Color _statusColorFor(String status) {
    switch (status.trim().toUpperCase()) {
      case 'OPEN':          return AppColors.amber;
      case 'INVESTIGATING': return AppColors.cyan;
      case 'ACTION TAKEN':  return AppColors.purple;
      case 'VERIFIED':      return AppColors.accent;
      case 'CLOSED':        return AppColors.green;
      default:              return Colors.blueGrey;
    }
  }

  Widget _statusPipeline(SL sl) {
    final stages = [
      for (final s in _statuses)
        (s.toUpperCase(), _statusCount(s.toUpperCase()), _statusColorFor(s)),
    ];
    if (stages.isEmpty) return const SizedBox();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.glassBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Status Pipeline', style: TextStyle(
                color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: stages.asMap().entries.map((e) {
                final idx = e.key;
                final (label, count, color) = e.value;
                return Expanded(child: Row(children: [
                  if (idx > 0)
                    Icon(Icons.chevron_right, color: sl.text4, size: 14),
                  Expanded(child: GestureDetector(
                    // Same blank-status attribution as the count above, so tapping
                    // a stage can't show a different number than it displays.
                    onTap: () => _showIncidentsSheet('$label Incidents',
                        _incidents.where((i) => _statusOf(i) == label).toList()),
                    child: Column(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: color.withOpacity(0.3)),
                        ),
                        child: Center(child: Text('$count',
                            style: TextStyle(color: color, fontSize: 16,
                                fontWeight: FontWeight.w800))),
                      ),
                      const SizedBox(height: 4),
                      Text(label, style: TextStyle(
                          color: sl.text4, fontSize: 8, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center),
                    ]),
                  )),
                ]));
              }).toList(),
            ),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  MONTHLY TREND — bar chart, last 6 months
  // ═══════════════════════════════════════════════════════════════
  Widget _monthlyTrendChart(SL sl) {
    final data = _monthlyTrend;
    final maxVal = data.fold<int>(1, (m, e) => e.value > m ? e.value : m);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.glassBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.trending_up_rounded, color: AppColors.accent, size: 16),
              const SizedBox(width: 6),
              Text('Monthly Trend', style: TextStyle(
                  color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              height: 100,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: data.map((e) {
                  final h = maxVal == 0 ? 4.0 : (e.value / maxVal) * 80 + 4;
                  final isLast = e == data.last;
                  return Expanded(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      if (e.value > 0)
                        Text('${e.value}', style: TextStyle(
                            color: sl.text3, fontSize: 9, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Container(
                        height: h,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: isLast
                                ? [AppColors.accent, AppColors.accent.withOpacity(0.4)]
                                : [AppColors.cyan.withOpacity(0.7), AppColors.cyan.withOpacity(0.2)],
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(e.key, style: TextStyle(
                          color: isLast ? AppColors.accent : sl.text4,
                          fontSize: 8, fontWeight: FontWeight.w600)),
                    ]),
                  ));
                }).toList(),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SEVERITY DONUT
  // ═══════════════════════════════════════════════════════════════
  Widget _severityDonut(SL sl) {
    final counts = _severityCounts;
    final total = counts.values.fold<int>(0, (s, v) => s + v);
    if (total == 0) return const SizedBox();

    // Driven by the admin's severity list, so adding or renaming a level
    // shows up here instead of being dropped. Previously these four rows
    // force-unwrapped fixed keys (counts['CRITICAL']!), which would crash
    // outright if an admin renamed a severity.
    final sections = [
      for (final entry in counts.entries)
        PieChartSectionData(
            value: entry.value.toDouble(),
            color: _sevColorFor(entry.key),
            radius: 22,
            title: ''),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.glassBorder),
          ),
          child: Row(children: [
            SizedBox(width: 100, height: 100,
              child: PieChart(PieChartData(
                sections: sections,
                centerSpaceRadius: 24,
                sectionsSpace: 2,
              )),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Severity Split', style: TextStyle(
                    color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                for (final entry in counts.entries)
                  _sevRow(_titleCase(entry.key), entry.value,
                      _sevColorFor(entry.key), sl),
              ],
            )),
          ]),
        ),
      ),
    );
  }

  /// Colour for a severity label. Known SAIL levels keep their established
  /// colours; an admin-added level falls back to a neutral grey rather than
  /// failing.
  Color _sevColorFor(String severity) {
    switch (severity.trim().toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.amber;
      case 'LOW':      return AppColors.green;
      default:         return Colors.blueGrey;
    }
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  Widget _sevRow(String label, int count, Color color, SL sl) {
    return GestureDetector(
      onTap: () => _showIncidentsSheet('$label Severity',
          _incidents.where((i) => i['severity']?.toString().toUpperCase() == label.toUpperCase()).toList()),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: sl.text2, fontSize: 11)),
          const Spacer(),
          Text('$count', style: TextStyle(
              color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TOP 3 PROBLEM AREAS
  // ═══════════════════════════════════════════════════════════════
  Widget _problemAreas(SL sl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sl.glassBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.priority_high_rounded, color: AppColors.red, size: 16),
              const SizedBox(width: 6),
              Text('Attention Areas', style: TextStyle(
                  color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            _problemRow(sl, 'Worst Plant', _worstPlant,
                Icons.factory_outlined, AppColors.red),
            const SizedBox(height: 8),
            _problemRow(sl, 'Top Hazard', _worstCategory,
                Icons.category_outlined, AppColors.amber),
            const SizedBox(height: 8),
            _problemRow(sl, 'Longest Open', _longestOpen,
                Icons.schedule_outlined, const Color(0xFF8B5CF6)),
          ]),
        ),
      ),
    );
  }

  Widget _problemRow(SL sl, String label, String value, IconData icon, Color color) {
    return Row(children: [
      Container(
        width: 30, height: 30,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 15),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: sl.text4, fontSize: 9,
            fontWeight: FontWeight.w600)),
        Text(value, style: TextStyle(color: sl.text1, fontSize: 12,
            fontWeight: FontWeight.w600),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ])),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  //  BOTTOM SHEET — tappable number detail view
  // ═══════════════════════════════════════════════════════════════
  void _showIncidentsSheet(String title, List<Map<String, dynamic>> incidents) {
    final sl = SL.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: sl.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(children: [
              Container(width: 36, height: 4,
                  decoration: BoxDecoration(color: sl.border,
                      borderRadius: BorderRadius.circular(2))),
              const Spacer(),
              Text(title, style: TextStyle(color: sl.text1, fontSize: 14,
                  fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${incidents.length}', style: TextStyle(
                  color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.w800)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: incidents.isEmpty
                ? Center(child: Text('No incidents', style: TextStyle(color: sl.text3)))
                : ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: incidents.length,
                    itemBuilder: (_, i) => _sheetIncidentCard(sl, incidents[i]),
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _sheetIncidentCard(SL sl, Map<String, dynamic> inc) {
    final sev = inc['severity']?.toString().toUpperCase() ?? 'MEDIUM';
    Color sevColor;
    switch (sev) {
      case 'CRITICAL': sevColor = AppColors.crit; break;
      case 'HIGH': sevColor = AppColors.red; break;
      case 'MEDIUM': sevColor = AppColors.amber; break;
      default: sevColor = AppColors.green;
    }
    final date = inc['date']?.toString() ?? '';
    final dateStr = date.length >= 10 ? date.substring(0, 10) : date;
    // Blank status shows the admin's first stage, not a literal 'OPEN'.
    final status = _statusOf(inc);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () {
          Navigator.pop(context);
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => IncidentDetailScreen(incident: inc, onStatusChanged: _load)));
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(color: sevColor, width: 3),
              top: BorderSide(color: sl.glassBorder),
              right: BorderSide(color: sl.glassBorder),
              bottom: BorderSide(color: sl.glassBorder),
            ),
          ),
          child: Row(children: [
            // ✅ Thumbnail
            _buildSheetThumbnail(inc, sevColor),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(inc['title']?.toString() ?? 'Untitled',
                  style: TextStyle(color: sl.text1, fontSize: 12, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text('${inc['plant'] ?? '—'} · ${inc['dept'] ?? '—'} · $dateStr',
                  style: TextStyle(color: sl.text4, fontSize: 9)),
            ])),
            Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: sevColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4)),
                child: Text(sev, style: TextStyle(color: sevColor, fontSize: 8, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 4),
              Text(status, style: TextStyle(color: sl.text4, fontSize: 10, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Thumbnail widget for overview incident cards
  Widget _buildSheetThumbnail(Map<String, dynamic> inc, Color sevColor) {
    final thumbnail = inc['thumbnailBase64']?.toString() ?? '';
    final isAiScan = (inc['type']?.toString().toUpperCase() ?? '') == 'AI_SCAN';
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: sevColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: sevColor.withOpacity(0.2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: thumbnail.isNotEmpty
          ? Image.memory(
              base64Decode(thumbnail),
              fit: BoxFit.cover,
              width: 42, height: 42,
              errorBuilder: (_, __, ___) => Icon(
                isAiScan ? Icons.image_search_rounded : Icons.warning_amber_rounded,
                color: sevColor, size: 20),
            )
          : Icon(
              isAiScan ? Icons.image_search_rounded : Icons.warning_amber_rounded,
              color: sevColor, size: 20),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SPI SCORECARD — Modern, informative safety performance indicator
  // ═══════════════════════════════════════════════════════════════
  Widget _spiScorecard(SL sl) {
    final scores = _plantScores;
    if (scores.isEmpty) return const SizedBox();

    final avgScore = scores.fold(0, (sum, s) => sum + s.score) / scores.length;
    final topPlant = scores.first;
    final needsAttention = scores.where((s) => s.score < 50).length;

    return GestureDetector(
      onTap: () => setState(() => _spiExpanded = !_spiExpanded),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF1E88E5).withOpacity(0.15),
                  const Color(0xFF1565C0).withOpacity(0.08),
                ]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1E88E5).withOpacity(0.4)),
            ),
            child: Column(children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1E88E5), Color(0xFF1565C0)]),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF1E88E5).withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2))
                      ]),
                    child: const Icon(Icons.assessment_rounded,
                        color: Colors.white, size: 22)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Safety Performance Indicator',
                            style: TextStyle(
                                color: Color(0xFF1E88E5),
                                fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Row(children: [
                          Icon(Icons.factory_rounded,
                              size: 11, color: sl.text4),
                          const SizedBox(width: 4),
                          Text('${scores.length} plants monitored',
                              style: TextStyle(
                                  color: sl.text4,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _scoreColor(avgScore.round())
                                  .withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: _scoreColor(avgScore.round()))),
                            child: Text('Avg ${avgScore.round()}',
                                style: TextStyle(
                                    color: _scoreColor(avgScore.round()),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800))),
                        ]),
                      ]),
                  ),
                  GestureDetector(
                    onTap: () {
                      _showScoreFormulaDialog(sl);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5).withOpacity(0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF1E88E5).withOpacity(0.3))),
                      child: const Icon(Icons.help_outline_rounded,
                          color: Color(0xFF1E88E5), size: 17))),
                  const SizedBox(width: 10),
                  Icon(
                      _spiExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: const Color(0xFF1E88E5),
                      size: 24),
                ]),
              ),

              // Compact summary (always visible)
              if (!_spiExpanded) ...[
                const Divider(height: 1, thickness: 0.5),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Expanded(
                      child: _spiQuickStat(
                          '🏆 Top Performer',
                          topPlant.plant,
                          topPlant.score.toString(),
                          _scoreColor(topPlant.score),
                          sl)),
                    Container(
                        width: 1,
                        height: 40,
                        color: sl.border.withOpacity(0.3)),
                    Expanded(
                      child: _spiQuickStat(
                          '⚠️ Needs Attention',
                          needsAttention == 0 ? 'None' : '$needsAttention ${needsAttention == 1 ? 'plant' : 'plants'}',
                          needsAttention == 0 ? '—' : '',
                          needsAttention == 0 ? AppColors.green : AppColors.red,
                          sl)),
                  ]),
                ),
              ],

              // Expanded detailed view
              if (_spiExpanded) ...[
                const Divider(height: 1, thickness: 0.5),
                Container(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(14),
                    shrinkWrap: true,
                    itemCount: scores.length,
                    itemBuilder: (context, i) => _plantScoreCard(scores[i], sl)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _spiQuickStat(String label, String value, String badge, Color color, SL sl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(children: [
        Text(label,
            style: TextStyle(
                color: sl.text4, fontSize: 10, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(
            child: Text(value,
                style: TextStyle(
                    color: sl.text1, fontSize: 13, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis)),
          if (badge.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: color)),
              child: Text(badge,
                  style: TextStyle(
                      color: color, fontSize: 10, fontWeight: FontWeight.w800))),
          ],
        ]),
      ]),
    );
  }

  Widget _plantScoreCard(_PlantScore ps, SL sl) {
    final scoreColor = _scoreColor(ps.score);
    final closureRate = ps.total == 0 ? 0.0 : (ps.closed / ps.total);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scoreColor.withOpacity(0.3)),
      ),
      child: Column(children: [
        // Header row
        Row(children: [
          Expanded(
            child: Text(ps.plant,
                style: TextStyle(
                    color: sl.text1, fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                scoreColor.withOpacity(0.2),
                scoreColor.withOpacity(0.1)
              ]),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scoreColor, width: 1.5)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${ps.score}',
                  style: TextStyle(
                      color: scoreColor, fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(width: 3),
              Text('/100',
                  style: TextStyle(
                      color: scoreColor.withOpacity(0.7),
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ])),
        ]),

        const SizedBox(height: 10),

        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(children: [
            Container(
              height: 8,
              decoration: BoxDecoration(
                color: sl.border.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6)),
            ),
            FractionallySizedBox(
              widthFactor: (ps.score / 100).clamp(0.0, 1.0),
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scoreColor, scoreColor.withOpacity(0.7)]),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: scoreColor.withOpacity(0.4),
                      blurRadius: 4,
                      offset: const Offset(0, 1))
                  ]),
              )),
          ]),
        ),

        const SizedBox(height: 10),

        // Metrics row
        Row(children: [
          _spiMetric(Icons.list_alt_rounded, 'Total', '${ps.total}', sl.text2, sl),
          const SizedBox(width: 12),
          _spiMetric(Icons.error_outline_rounded, 'Critical', '${ps.critical}',
              ps.critical > 0 ? AppColors.crit : sl.text3, sl),
          const SizedBox(width: 12),
          _spiMetric(Icons.check_circle_outline, 'Closure', '${(closureRate * 100).round()}%',
              closureRate >= 0.8 ? AppColors.green
                : closureRate >= 0.5 ? AppColors.amber : AppColors.red, sl),
          const SizedBox(width: 12),
          _spiMetric(Icons.access_time_rounded, 'Stale', '${ps.staleHighCritical}',
              ps.staleHighCritical > 0 ? AppColors.red : AppColors.green, sl),
        ]),

        if (ps.staleHighCritical > 0) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.red.withOpacity(0.3))),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.red, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${ps.staleHighCritical} HIGH/CRITICAL incident(s) open >7 days',
                  style: const TextStyle(
                      color: AppColors.red, fontSize: 10, fontWeight: FontWeight.w700))),
            ])),
        ],
      ]),
    );
  }

  Widget _spiMetric(IconData icon, String label, String value, Color color, SL sl) {
    return Expanded(
      child: Column(children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 1),
        Text(label,
            style: TextStyle(
                color: sl.text4, fontSize: 8, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 80) return AppColors.green;
    if (score >= 50) return AppColors.amber;
    return AppColors.red;
  }

  void _showScoreFormulaDialog(SL sl) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E88E5), Color(0xFF1565C0)]),
              borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.calculate_rounded,
                color: Colors.white, size: 20)),
          const SizedBox(width: 12),
          const Text('SPI Score Calculation',
              style: TextStyle(
                  color: Color(0xFF1E88E5),
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    const Color(0xFF1E88E5).withOpacity(0.1),
                    const Color(0xFF1565C0).withOpacity(0.05)
                  ]),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFF1E88E5).withOpacity(0.3))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Score = Closure + Stale + Critical',
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text('Maximum: 100 points',
                        style: TextStyle(color: sl.text3, fontSize: 11)),
                  ]),
              ),
              const SizedBox(height: 16),
              _formulaSection(
                  '1. Closure Rate',
                  '(max ${_spiParams['closureMaxPoints']} points)',
                  [
                    'Rate = Closed ÷ Total',
                    'Points = Rate × ${_spiParams['closureMaxPoints']}',
                  ],
                  sl),
              const SizedBox(height: 14),
              _formulaSection(
                  '2. Stale HIGH/CRITICAL',
                  '(max ${_spiParams['staleMaxPoints']} points)',
                  [
                    'If stale = 0: ${_spiParams['staleMaxPoints']} points',
                    'Else: max(0, ${_spiParams['staleMaxPoints']} - stale×${_spiParams['stalePenalty']})',
                    'Each stale (>7d) costs ${_spiParams['stalePenalty']} pts',
                  ],
                  sl),
              const SizedBox(height: 14),
              _formulaSection(
                  '3. Critical Incidents',
                  '(max ${_spiParams['criticalMaxPoints']} points)',
                  [
                    'If critical = 0: ${_spiParams['criticalMaxPoints']} points',
                    'Else: max(0, ${_spiParams['criticalMaxPoints']} - critical×${_spiParams['criticalPenalty']})',
                    'Each critical costs ${_spiParams['criticalPenalty']} point(s)',
                  ],
                  sl),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.amber.withOpacity(0.4))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        color: AppColors.amber, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Ranges: ≥80 Excellent (green), ≥50 Good (amber), <50 Needs Attention (red)',
                        style: TextStyle(
                            color: sl.text2, fontSize: 10.5, height: 1.4))),
                  ]),
              ),
            ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close',
                style: TextStyle(
                    color: Color(0xFF1E88E5), fontWeight: FontWeight.w700))),
        ]));
  }

  Widget _formulaSection(String title, String subtitle, List<String> points, SL sl) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: TextStyle(
              color: sl.text1, fontSize: 12, fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      Text(subtitle,
          style: TextStyle(color: sl.text4, fontSize: 10)),
      const SizedBox(height: 8),
      ...points.map((p) => Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• ',
                    style: TextStyle(color: sl.text3, fontSize: 11)),
                Expanded(
                  child: Text(p,
                      style: TextStyle(
                          color: sl.text2, fontSize: 11, height: 1.4))),
              ]),
          )),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════
//  PLANT SCORE DATA CLASS
// ═══════════════════════════════════════════════════════════════
class _PlantScore {
  final String plant;
  final Map<String, int> params;
  int total = 0;
  int critical = 0;
  int high = 0;
  int open = 0;
  int closed = 0;
  int staleHighCritical = 0;

  _PlantScore(this.plant, this.params);

  int get score {
    final closureRate = total == 0 ? 0.0 : closed / total;
    final closureMaxPts = params['closureMaxPoints'] ?? 60;
    final staleMaxPts = params['staleMaxPoints'] ?? 25;
    final critMaxPts = params['criticalMaxPoints'] ?? 15;
    final stalePenalty = params['stalePenalty'] ?? 5;
    final critPenalty = params['criticalPenalty'] ?? 1;

    final closurePoints = (closureRate * closureMaxPts).round();
    final stalePoints = staleHighCritical == 0
        ? staleMaxPts
        : (staleMaxPts - staleHighCritical * stalePenalty).clamp(0, staleMaxPts);
    final criticalPoints = critical == 0
        ? critMaxPts
        : (critMaxPts - critical * critPenalty).clamp(0, critMaxPts);
    return (closurePoints + stalePoints + criticalPoints).clamp(0, 100);
  }
}
