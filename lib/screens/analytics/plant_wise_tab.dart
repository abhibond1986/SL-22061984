import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../main.dart' show AppColors, SL;
import '../../services/local_db.dart';
import '../../services/admin_master_data.dart';
import '../../services/realtime_sync.dart';
import '../incident_detail_screen.dart';

class PlantWiseTab extends StatefulWidget {
  const PlantWiseTab({super.key});
  @override
  State<PlantWiseTab> createState() => _PlantWiseTabState();
}

class _PlantWiseTabState extends State<PlantWiseTab> {
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  String? _selectedPlant;
  // Active canonical plant list (admin-editable) for name normalization.
  List<Map<String, String>> _plantDefs = AdminMasterData.sailPlants;
  List<String> _statuses = List<String>.from(AdminMasterData.defaultStatuses);

  /// Canonical plant label for an incident (dedupes name variants).
  String _canonPlant(Map<String, dynamic> i) =>
      AdminMasterData.canonicalPlantFrom(
          i['plant']?.toString() ?? '', _plantDefs);

  @override
  void initState() {
    super.initState();
    _load();
    RealtimeSync.incidentsRevision.addListener(_onRealtime);
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final inc = await LocalDB.getIncidents();
    final plants = await AdminMasterData.getPlants();
    final statuses = await AdminMasterData.getStatuses();
    if (mounted) {
      setState(() {
        _all = inc;
        _plantDefs = plants;
        _statuses = statuses;
        _loading = false;
        if (_selectedPlant == null && _plants.isNotEmpty) {
          _selectedPlant = _plants.first;
        }
      });
    }
  }

  // Unique CANONICAL plants present in the data (each appears once).
  List<String> get _plants {
    final s = <String>{};
    for (final i in _all) {
      final p = _canonPlant(i);
      if (p.isNotEmpty) s.add(p);
    }
    final list = s.toList()..sort();
    return list;
  }

  List<Map<String, dynamic>> get _plantIncidents {
    if (_selectedPlant == null) return [];
    return _all.where((i) => _canonPlant(i) == _selectedPlant).toList();
  }

  // KPIs for selected plant
  int get _pTotal => _plantIncidents.length;
  int get _pOpen => _plantIncidents.where((i) =>
      (i['status']?.toString().toUpperCase() ?? 'OPEN') != 'CLOSED').length;
  int get _pCritical => _plantIncidents.where((i) =>
      i['severity']?.toString().toUpperCase() == 'CRITICAL').length;
  double get _pClosureRate {
    if (_pTotal == 0) return 0;
    final closed = _plantIncidents.where((i) =>
        i['status']?.toString().toUpperCase() == 'CLOSED').length;
    return closed / _pTotal * 100;
  }

  // Top 5 hazard categories for this plant
  List<MapEntry<String, int>> get _top5Categories {
    final m = <String, int>{};
    for (final i in _plantIncidents) {
      final c = i['wsaCategory']?.toString() ?? 'Other';
      m[c] = (m[c] ?? 0) + 1;
    }
    final sorted = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(5).toList();
  }

  // Department breakdown for this plant
  List<MapEntry<String, int>> get _deptBreakdown {
    final m = <String, int>{};
    for (final i in _plantIncidents) {
      final d = i['dept']?.toString() ?? '';
      if (d.isNotEmpty) m[d] = (m[d] ?? 0) + 1;
    }
    final sorted = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(6).toList();
  }

  /// Established colours for the standard SAIL pipeline; admin-added
  /// statuses get a neutral fallback rather than failing.
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

  /// 'ACTION TAKEN' → 'Action Taken'
  String _titleCaseWords(String s) => s
      .split(' ')
      .map((w) => w.isEmpty
          ? w
          : w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  // Status distribution for this plant, seeded from the admin's status list.
  // Previously hardcoded four statuses, which silently omitted VERIFIED.
  Map<String, int> get _statusDist {
    final m = <String, int>{for (final s in _statuses) s.toUpperCase(): 0};
    for (final i in _plantIncidents) {
      final s = i['status']?.toString().toUpperCase() ?? 'OPEN';
      m[s] = (m[s] ?? 0) + 1;
    }
    return m;
  }

  // Recent 5 incidents for this plant
  List<Map<String, dynamic>> get _recent {
    final list = List<Map<String, dynamic>>.from(_plantIncidents);
    list.sort((a, b) =>
        (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    return list.take(5).toList();
  }

  static const _barColors = [
    AppColors.crit, AppColors.amber, AppColors.accent, AppColors.cyan, AppColors.green,
  ];

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_all.isEmpty) {
      return Center(child: Text('No data recorded yet',
          style: TextStyle(color: sl.text3, fontSize: 14)));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Plant selector chips
        _plantSelector(sl),
        const SizedBox(height: 14),

        if (_selectedPlant != null && _plantIncidents.isNotEmpty) ...[
          // KPI row
          _plantKpis(sl),
          const SizedBox(height: 14),
          // Status distribution
          _statusSection(sl),
          const SizedBox(height: 14),
          // Top 5 hazards
          _top5Section(sl),
          const SizedBox(height: 14),
          // Department breakdown
          _deptSection(sl),
          const SizedBox(height: 14),
          // Recent incidents
          _recentSection(sl),
          const SizedBox(height: 20),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(child: Text(
              _selectedPlant == null
                  ? 'Select a plant above'
                  : 'No incidents for $_selectedPlant',
              style: TextStyle(color: sl.text3, fontSize: 13))),
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT SELECTOR — horizontal scrollable chips
  // ═══════════════════════════════════════════════════════════════
  Widget _plantSelector(SL sl) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _plants.map((p) {
          final active = p == _selectedPlant;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _selectedPlant = p),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: active ? AppColors.accent : sl.glassColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: active ? AppColors.accent : sl.glassBorder),
                ),
                child: Text(p, style: TextStyle(
                    color: active ? Colors.white : sl.text2,
                    fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT KPI CARDS (tappable)
  // ═══════════════════════════════════════════════════════════════
  Widget _plantKpis(SL sl) {
    return Row(children: [
      _miniKpi(sl, 'Total', '$_pTotal', const Color(0xFF6366F1),
          () => _showIncidentsSheet('All — $_selectedPlant', _plantIncidents)),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Open', '$_pOpen', AppColors.amber,
          () => _showIncidentsSheet('Open — $_selectedPlant',
              _plantIncidents.where((i) => (i['status']?.toString().toUpperCase() ?? 'OPEN') != 'CLOSED').toList())),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Critical', '$_pCritical', AppColors.crit,
          () => _showIncidentsSheet('Critical — $_selectedPlant',
              _plantIncidents.where((i) => i['severity']?.toString().toUpperCase() == 'CRITICAL').toList())),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Closed %', '${_pClosureRate.toStringAsFixed(0)}%', AppColors.green,
          () => _showIncidentsSheet('Closed — $_selectedPlant',
              _plantIncidents.where((i) => i['status']?.toString().toUpperCase() == 'CLOSED').toList())),
    ]);
  }

  Widget _miniKpi(SL sl, String label, String value, Color color, [VoidCallback? onTap]) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Column(children: [
            Text(value, style: TextStyle(
                color: color, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: sl.text3, fontSize: 9)),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  STATUS DISTRIBUTION — colored pills
  // ═══════════════════════════════════════════════════════════════
  Widget _statusSection(SL sl) {
    final dist = _statusDist;
    // Built from the admin's status list. Previously four force-unwrapped
    // keys, which omitted VERIFIED and would crash on a renamed status.
    final stages = [
      for (final e in dist.entries)
        (_titleCaseWords(e.key), e.value, _statusColorFor(e.key)),
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
            Text('Status Distribution', style: TextStyle(
                color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(children: stages.map((s) {
              final (label, count, color) = s;
              // Recover the raw key from the display label instead of a
              // hardcoded four-way ladder that defaulted everything unknown
              // to 'CLOSED'.
              final statusKey = label.toUpperCase();
              return Expanded(child: GestureDetector(
                onTap: () => _showIncidentsSheet('$label — $_selectedPlant',
                    _plantIncidents.where((i) => (i['status']?.toString().toUpperCase() ?? 'OPEN') == statusKey).toList()),
                child: Column(children: [
                  Text('$count', style: TextStyle(
                      color: color, fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(
                      color: sl.text3, fontSize: 9), textAlign: TextAlign.center),
                ]),
              ));
            }).toList()),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TOP 5 HAZARD CATEGORIES
  // ═══════════════════════════════════════════════════════════════
  Widget _top5Section(SL sl) {
    final top5 = _top5Categories;
    if (top5.isEmpty) return const SizedBox();
    final maxVal = top5.first.value;
    final total = top5.fold<int>(0, (s, e) => s + e.value);

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
              Text('Top Hazard Categories', style: TextStyle(
                  color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('$total total', style: TextStyle(
                  color: sl.text4, fontSize: 10)),
            ]),
            const SizedBox(height: 12),
            // Pie + legend
            Row(children: [
              SizedBox(width: 80, height: 80,
                child: PieChart(PieChartData(
                  sections: List.generate(top5.length, (i) =>
                    PieChartSectionData(
                      value: top5[i].value.toDouble(),
                      color: _barColors[i % _barColors.length],
                      radius: 16, title: '')),
                  centerSpaceRadius: 16,
                  sectionsSpace: 1.5,
                )),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(top5.length, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(
                        color: _barColors[i % _barColors.length],
                        borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 5),
                    Expanded(child: Text(top5[i].key,
                        style: TextStyle(color: sl.text2, fontSize: 10),
                        overflow: TextOverflow.ellipsis)),
                    Text('${top5[i].value}', style: TextStyle(
                        color: sl.text1, fontSize: 10, fontWeight: FontWeight.w700)),
                  ]),
                )),
              )),
            ]),
            const SizedBox(height: 10),
            // Bar chart
            ...List.generate(top5.length, (i) {
              final fraction = maxVal > 0 ? top5[i].value / maxVal : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(width: 14,
                    child: Text('${i + 1}', style: TextStyle(fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _barColors[i % _barColors.length]))),
                  const SizedBox(width: 6),
                  Expanded(child: Stack(children: [
                    Container(height: 14, decoration: BoxDecoration(
                      color: sl.border.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4))),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.05, 1.0),
                      child: Container(height: 14, decoration: BoxDecoration(
                        color: _barColors[i % _barColors.length],
                        borderRadius: BorderRadius.circular(4))),
                    ),
                  ])),
                  const SizedBox(width: 6),
                  Text('${top5[i].value}', style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w700, color: sl.text1)),
                ]),
              );
            }),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  DEPARTMENT BREAKDOWN
  // ═══════════════════════════════════════════════════════════════
  Widget _deptSection(SL sl) {
    final depts = _deptBreakdown;
    if (depts.isEmpty) return const SizedBox();
    final maxVal = depts.first.value;

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
            Text('Department Breakdown', style: TextStyle(
                color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ...depts.map((e) {
              final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(children: [
                  SizedBox(width: 90, child: Text(e.key,
                      style: TextStyle(color: sl.text2, fontSize: 10),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 6),
                  Expanded(child: Stack(children: [
                    Container(height: 14, decoration: BoxDecoration(
                      color: sl.border.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4))),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.05, 1.0),
                      child: Container(height: 14, decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [AppColors.accent, AppColors.cyan]),
                        borderRadius: BorderRadius.circular(4))),
                    ),
                  ])),
                  const SizedBox(width: 6),
                  Text('${e.value}', style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w700, color: sl.text1)),
                ]),
              );
            }),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  RECENT INCIDENTS
  // ═══════════════════════════════════════════════════════════════
  Widget _recentSection(SL sl) {
    final list = _recent;
    if (list.isEmpty) return const SizedBox();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Recent Incidents', style: TextStyle(
          color: sl.text1, fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      ...list.map((inc) {
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

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => IncidentDetailScreen(
                  incident: inc, onStatusChanged: _load))),
            child: Container(
              padding: const EdgeInsets.all(10),
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
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(inc['title']?.toString() ?? 'Untitled',
                        style: TextStyle(color: sl.text1, fontSize: 12,
                            fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('${inc['dept'] ?? '—'} · $dateStr',
                        style: TextStyle(color: sl.text4, fontSize: 9)),
                  ],
                )),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: sevColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4)),
                  child: Text(sev, style: TextStyle(
                      color: sevColor, fontSize: 8, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ),
        );
      }),
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
                    itemBuilder: (_, i) {
                      final inc = incidents[i];
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

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(
                              builder: (_) => IncidentDetailScreen(
                                  incident: inc, onStatusChanged: _load)));
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
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(inc['title']?.toString() ?? 'Untitled',
                                      style: TextStyle(color: sl.text1, fontSize: 12,
                                          fontWeight: FontWeight.w600),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 3),
                                  Text('${inc['dept'] ?? '—'} · $dateStr',
                                      style: TextStyle(color: sl.text4, fontSize: 9)),
                                ],
                              )),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                    color: sevColor.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4)),
                                child: Text(sev, style: TextStyle(
                                    color: sevColor, fontSize: 8, fontWeight: FontWeight.w800)),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
