import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../main.dart' show AppColors, SL;
import '../../services/local_db.dart';
import '../../services/admin_master_data.dart';
import '../../services/realtime_sync.dart';

class DataAnalysisTab extends StatefulWidget {
  const DataAnalysisTab({super.key});

  @override
  State<DataAnalysisTab> createState() => _DataAnalysisTabState();
}

class _DataAnalysisTabState extends State<DataAnalysisTab> {
  List<Map<String, dynamic>> _incidents = [];
  List<String> _wsaCategories = [];
  List<String> _severities =
      List<String>.from(AdminMasterData.defaultSeverities);
  bool _loading = true;

  // ── Interactive filters ──────────────────────────────────────────────
  // Type toggle: 'ALL' | 'AI_SCAN' | 'NEAR_MISS'. Plant: null = all plants.
  String _typeFilter = 'ALL';
  String? _plantFilter;

  /// The incident set every chart/summary reads from, after applying the
  /// active type + plant filters to the raw [_incidents].
  List<Map<String, dynamic>> get _view {
    return _incidents.where((i) {
      if (_typeFilter != 'ALL' &&
          (i['type']?.toString().toUpperCase() ?? '') != _typeFilter) {
        return false;
      }
      if (_plantFilter != null &&
          (i['plant']?.toString() ?? 'Other') != _plantFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Distinct plant names present in the data (for the filter dropdown).
  List<String> get _plantOptions {
    final set = <String>{};
    for (final i in _incidents) {
      set.add(i['plant']?.toString() ?? 'Other');
    }
    final list = set.toList()..sort();
    return list;
  }

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
    final inc = await LocalDB.getIncidents();
    final wsa = await AdminMasterData.getWsaCauses();
    final sevs = await AdminMasterData.getSeverities();
    if (mounted) {
      setState(() {
        _incidents = inc;
        _wsaCategories = wsa;
        _severities = sevs;
        _loading = false;
      });
    }
  }

  // Severity counts
  Map<String, int> get _severityCounts {
    // Seeded from the admin's severity list rather than four fixed keys.
    final map = <String, int>{
      for (final s in _severities.reversed) s.toUpperCase(): 0
    };
    for (final i in _view) {
      final sev = (i['severity']?.toString() ?? 'MEDIUM').toUpperCase();
      map[sev] = (map[sev] ?? 0) + 1;
    }
    return map;
  }

  // Plant-wise counts
  Map<String, int> get _plantCounts {
    final map = <String, int>{};
    for (final i in _view) {
      final plant = i['plant']?.toString() ?? 'Other';
      map[plant] = (map[plant] ?? 0) + 1;
    }
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(sorted);
  }

  // Category counts — mapped to custom WSA list via fuzzy matching
  Map<String, int> get _categoryCounts {
    final map = <String, int>{};
    for (final i in _view) {
      final raw = (i['wsaCategory']?.toString() ?? '').trim();
      if (raw.isEmpty) continue;
      final matched = _matchWsaCategory(raw);
      final label = matched ?? raw; // fallback to raw if no match
      map[label] = (map[label] ?? 0) + 1;
    }
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(sorted);
  }

  /// Fuzzy-match a raw wsaCategory value to the custom list
  String? _matchWsaCategory(String rawWsa) {
    final rawLower = rawWsa.toLowerCase();
    final rawStripped = rawLower.replaceFirst(RegExp(r'^\d+\.\s*'), '');

    for (final cat in _wsaCategories) {
      final catLower = cat.toLowerCase();
      final catStripped = catLower.replaceFirst(RegExp(r'^\d+\.\s*'), '');
      if (rawLower == catLower || rawStripped == catStripped) return cat;
      if (rawStripped.contains(catStripped) || catStripped.contains(rawStripped)) return cat;
    }

    // Keyword match
    final rawKeywords = rawStripped.split(RegExp(r'[\s/()]+'))
        .where((w) => w.length > 2).toList();
    String? best;
    int bestScore = 0;
    for (final cat in _wsaCategories) {
      final catStripped = cat.toLowerCase().replaceFirst(RegExp(r'^\d+\.\s*'), '');
      int score = 0;
      for (final kw in rawKeywords) {
        if (catStripped.contains(kw)) score += 2;
      }
      if (score > bestScore) { bestScore = score; best = cat; }
    }
    return bestScore >= 2 ? best : null;
  }

  // Type counts
  int get _aiScanCount => _view.where(
      (i) => i['type']?.toString().toUpperCase() == 'AI_SCAN').length;
  int get _nearMissCount => _view.where(
      (i) => i['type']?.toString().toUpperCase() == 'NEAR_MISS').length;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_incidents.isEmpty) {
      return Center(child: Text('No data recorded yet',
          style: TextStyle(color: sl.text3, fontSize: 14)));
    }

    final hasView = _view.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Interactive filter bar ──────────────────────────────────
          _filterBar(sl),
          const SizedBox(height: 16),
          if (!hasView)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('No records match these filters',
                  style: TextStyle(color: sl.text3, fontSize: 14))),
            )
          else ...[
          // Summary row
          _summaryCards(sl),
          const SizedBox(height: 20),
          // Severity Pie Chart
          _sectionTitle('Severity Distribution', sl),
          const SizedBox(height: 12),
          _severityPieChart(sl),
          const SizedBox(height: 24),
          // Type Pie Chart
          _sectionTitle('Report Type Breakdown', sl),
          const SizedBox(height: 12),
          _typePieChart(sl),
          const SizedBox(height: 24),
          // Plant-wise Bar Chart
          _sectionTitle('Incidents by Plant', sl),
          const SizedBox(height: 12),
          _plantBarChart(sl),
          const SizedBox(height: 24),
          // Category Bar Chart
          _sectionTitle('WSA Category Breakdown', sl),
          const SizedBox(height: 12),
          _categoryBarChart(sl),
          const SizedBox(height: 24),
          // Department Bar Chart
          _sectionTitle('Top Departments', sl),
          const SizedBox(height: 12),
          _departmentBarChart(sl),
          const SizedBox(height: 24),
          // Response Time Analysis
          _sectionTitle('Response Time', sl),
          const SizedBox(height: 12),
          _responseTimeCards(sl),
          const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  FILTER BAR — type toggle (All / AI Scan / Near Miss) + plant picker
  // ═══════════════════════════════════════════════════════════════
  Widget _filterBar(SL sl) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Type segmented toggle
          Row(
            children: [
              _typeChip(sl, 'All', 'ALL'),
              const SizedBox(width: 6),
              _typeChip(sl, 'AI Scan', 'AI_SCAN'),
              const SizedBox(width: 6),
              _typeChip(sl, 'Near Miss', 'NEAR_MISS'),
            ],
          ),
          const SizedBox(height: 10),
          // Plant dropdown
          Row(
            children: [
              Icon(Icons.factory_outlined, size: 16, color: sl.text3),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: _plantFilter,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: sl.glassColor,
                    style: TextStyle(fontSize: 12.5, color: sl.text1),
                    hint: Text('All plants',
                        style: TextStyle(fontSize: 12.5, color: sl.text2)),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All plants',
                            style: TextStyle(fontSize: 12.5, color: sl.text1)),
                      ),
                      ..._plantOptions.map((p) => DropdownMenuItem<String?>(
                            value: p,
                            child: Text(p,
                                style: TextStyle(fontSize: 12.5, color: sl.text1),
                                overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    onChanged: (v) => setState(() => _plantFilter = v),
                  ),
                ),
              ),
              if (_plantFilter != null || _typeFilter != 'ALL')
                GestureDetector(
                  onTap: () => setState(() {
                    _plantFilter = null;
                    _typeFilter = 'ALL';
                  }),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('Clear',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.accent,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeChip(SL sl, String label, String value) {
    final active = _typeFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _typeFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppColors.accent : sl.border.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : sl.text2)),
      ),
    );
  }

  Widget _sectionTitle(String title, SL sl) {
    return Text(title,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: sl.text1));
  }

  Widget _summaryCards(SL sl) {
    final total = _view.length;
    final critical = _severityCounts['CRITICAL'] ?? 0;
    final open = _view.where(
        (i) => i['status']?.toString().toUpperCase() == 'OPEN').length;
    return Row(
      children: [
        _miniCard(sl, 'Total', '$total', AppColors.accent),
        const SizedBox(width: 8),
        _miniCard(sl, 'Critical', '$critical', AppColors.crit),
        const SizedBox(width: 8),
        _miniCard(sl, 'Open', '$open', AppColors.amber),
        const SizedBox(width: 8),
        _miniCard(sl, 'AI Scans', '$_aiScanCount', AppColors.cyan),
      ],
    );
  }

  Widget _miniCard(SL sl, String label, String value, Color color) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Column(children: [
              Text(value, style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 9, color: sl.text3)),
            ]),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SEVERITY PIE CHART
  // ═══════════════════════════════════════════════════════════════
  Widget _severityPieChart(SL sl) {
    final counts = _severityCounts;
    final total = counts.values.fold<int>(0, (s, v) => s + v);
    if (total == 0) return const SizedBox();

    // Driven by the admin's severity list. Previously force-unwrapped four
    // fixed keys, which would crash if a severity were renamed in admin.
    final sections = <PieChartSectionData>[
      for (final e in counts.entries)
        _pieSection(e.value, total, _sevColorFor(e.key), _titleCase(e.key)),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 130, height: 130,
            child: PieChart(PieChartData(
              sections: sections,
              centerSpaceRadius: 28,
              sectionsSpace: 2,
            )),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in counts.entries)
                _legendRow(_titleCase(e.key), e.value, _sevColorFor(e.key), sl),
            ],
          ),
        ],
      ),
    );
  }

  /// Colour for a severity label; admin-added levels get a neutral fallback.
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

  PieChartSectionData _pieSection(int count, int total, Color color, String title) {
    final pct = total > 0 ? (count / total * 100) : 0.0;
    return PieChartSectionData(
      value: count.toDouble(),
      color: color,
      radius: 24,
      title: pct >= 5 ? '${pct.round()}%' : '',
      titleStyle: const TextStyle(
          fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
    );
  }

  Widget _legendRow(String label, int count, Color color, SL sl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Container(width: 10, height: 10,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text('$label: ', style: TextStyle(fontSize: 11, color: sl.text2)),
        Text('$count', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: sl.text1)),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TYPE PIE CHART
  // ═══════════════════════════════════════════════════════════════
  Widget _typePieChart(SL sl) {
    final total = _view.length;
    if (total == 0) return const SizedBox();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 130, height: 130,
            child: PieChart(PieChartData(
              sections: [
                PieChartSectionData(
                  value: _aiScanCount.toDouble(),
                  color: AppColors.accent,
                  radius: 24,
                  title: _aiScanCount > 0
                      ? '${(_aiScanCount / total * 100).round()}%' : '',
                  titleStyle: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                PieChartSectionData(
                  value: _nearMissCount.toDouble(),
                  color: AppColors.amber,
                  radius: 24,
                  title: _nearMissCount > 0
                      ? '${(_nearMissCount / total * 100).round()}%' : '',
                  titleStyle: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ],
              centerSpaceRadius: 28,
              sectionsSpace: 2,
            )),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _legendRow('AI Scan', _aiScanCount, AppColors.accent, sl),
              _legendRow('Near Miss', _nearMissCount, AppColors.amber, sl),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT BAR CHART
  // ═══════════════════════════════════════════════════════════════
  Widget _plantBarChart(SL sl) {
    final data = _plantCounts;
    if (data.isEmpty) return const SizedBox();
    final entries = data.entries.toList();
    final maxVal = entries.first.value;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Column(
        children: entries.map((e) {
          final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(width: 80,
                  child: Text(_shortPlant(e.key),
                      style: TextStyle(fontSize: 11, color: sl.text2),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: sl.border.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(5)),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.03, 1.0),
                      child: Container(
                        height: 20,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [AppColors.accent, AppColors.cyan]),
                          borderRadius: BorderRadius.circular(5)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('${e.value}', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: sl.text1)),
            ]),
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  CATEGORY BAR CHART
  // ═══════════════════════════════════════════════════════════════
  Widget _categoryBarChart(SL sl) {
    final data = _categoryCounts;
    if (data.isEmpty) return const SizedBox();
    final entries = data.entries.take(8).toList();
    final maxVal = entries.first.value;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Column(
        children: entries.map((e) {
          final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(width: 100,
                  child: Text(e.key,
                      style: TextStyle(fontSize: 10, color: sl.text2),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: sl.border.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4)),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.03, 1.0),
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [AppColors.amber, AppColors.red]),
                          borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('${e.value}', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: sl.text1)),
            ]),
          );
        }).toList(),
      ),
    );
  }

  String _shortPlant(String plant) {
    final parts = plant.split(' ');
    return parts.first;
  }

  // ═══════════════════════════════════════════════════════════════
  //  DEPARTMENT BAR CHART
  // ═══════════════════════════════════════════════════════════════
  Map<String, int> get _deptCounts {
    final map = <String, int>{};
    for (final i in _view) {
      final dept = i['dept']?.toString() ?? '';
      if (dept.isEmpty) continue;
      map[dept] = (map[dept] ?? 0) + 1;
    }
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(sorted.take(8));
  }

  Widget _departmentBarChart(SL sl) {
    final data = _deptCounts;
    if (data.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.glassColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.glassBorder),
        ),
        child: Center(child: Text('No department data',
            style: TextStyle(color: sl.text4, fontSize: 12))),
      );
    }
    final entries = data.entries.toList();
    final maxVal = entries.first.value;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Column(
        children: entries.map((e) {
          final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(width: 100,
                  child: Text(e.key,
                      style: TextStyle(fontSize: 10, color: sl.text2),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: sl.border.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4)),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.03, 1.0),
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [Color(0xFF8B5CF6), AppColors.accent]),
                          borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('${e.value}', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: sl.text1)),
            ]),
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  RESPONSE TIME ANALYSIS
  // ═══════════════════════════════════════════════════════════════
  Widget _responseTimeCards(SL sl) {
    // Compute average days for each transition
    double avgToInvestigation = 0;
    double avgToAction = 0;
    double avgToClosed = 0;
    int countInv = 0, countAct = 0, countClose = 0;

    for (final i in _view) {
      final opened = DateTime.tryParse(i['date']?.toString() ?? '');
      if (opened == null) continue;

      final invAt = DateTime.tryParse(i['investigationStartedAt']?.toString() ?? '');
      final actAt = DateTime.tryParse(i['actionTakenAt']?.toString() ?? '');
      final closedAt = DateTime.tryParse(i['closedAt']?.toString() ?? '');

      if (invAt != null) {
        avgToInvestigation += invAt.difference(opened).inHours.abs();
        countInv++;
      }
      if (actAt != null && invAt != null) {
        avgToAction += actAt.difference(invAt).inHours.abs();
        countAct++;
      }
      if (closedAt != null && actAt != null) {
        avgToClosed += closedAt.difference(actAt).inHours.abs();
        countClose++;
      }
    }

    final invDays = countInv > 0 ? (avgToInvestigation / countInv / 24) : 0.0;
    final actDays = countAct > 0 ? (avgToAction / countAct / 24) : 0.0;
    final closeDays = countClose > 0 ? (avgToClosed / countClose / 24) : 0.0;

    return Row(children: [
      _responseCard(sl, 'To Investigation', invDays, AppColors.cyan),
      const SizedBox(width: 8),
      _responseCard(sl, 'To Action', actDays, const Color(0xFF8B5CF6)),
      const SizedBox(width: 8),
      _responseCard(sl, 'To Closure', closeDays, AppColors.green),
    ]);
  }

  Widget _responseCard(SL sl, String label, double days, Color color) {
    final display = days < 1 ? '< 1d' : '${days.toStringAsFixed(1)}d';
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(children: [
          Icon(Icons.timer_outlined, color: color, size: 18),
          const SizedBox(height: 6),
          Text(display, style: TextStyle(
              color: color, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(
              color: sl.text3, fontSize: 9, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
