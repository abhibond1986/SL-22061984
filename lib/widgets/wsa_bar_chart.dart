// lib/widgets/wsa_bar_chart.dart
// ✅ v23: WSA-13 Bar Chart — now uses AdminMasterData custom list as source of truth.
// Shows count of incidents by WSA category with a plant filter dropdown.

import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import '../services/i18n.dart';
import '../services/local_db.dart';
import '../services/admin_master_data.dart';

class WsaBarChart extends StatefulWidget {
  const WsaBarChart({super.key});

  @override
  State<WsaBarChart> createState() => _WsaBarChartState();
}

class _WsaBarChartState extends State<WsaBarChart> {
  List<Map<String, dynamic>> _incidents = [];
  List<String> _wsaCategories = [];
  String _selectedPlant = 'all';
  bool _loading = true;
  // Admin-editable canonical plant list for name normalization.
  List<Map<String, String>> _plantDefs = AdminMasterData.sailPlants;
  // Plant dropdown list — dynamically loaded from AdminMasterData
  List<Map<String, String>> _plants = [
    {'code': 'all',  'name': 'Entire SAIL'},
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final inc = await LocalDB.getIncidents();
    // ✅ v23: Load WSA categories from AdminMasterData (same source as admin panel)
    final wsa = await AdminMasterData.getWsaCauses();
    final plants = await AdminMasterData.getPlants();
    if (mounted) setState(() {
      _incidents = inc;
      _wsaCategories = wsa;
      _plantDefs = plants;
      // Build plant dropdown from loaded master data
      _plants = [
        {'code': 'all',  'name': 'Entire SAIL'},
        ...plants.map((p) {
          final code = p['code'] ?? '';
          final name = p['name'] ?? '';
          // Format: CODE — Name (or just name if it already contains a dash)
          final displayName = name.contains('—') ? name : '$code — $name';
          return {'code': code, 'name': displayName};
        }).toList(),
      ];
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filteredIncidents {
    if (_selectedPlant == 'all') return _incidents;
    final target = _selectedPlant.toUpperCase();
    return _incidents.where((i) {
      // Canonicalize first so "DSP Durgapur" / "Durgapur Steel Plant" etc.
      // all resolve to the same "CODE — Name" and match by code token.
      final canon = AdminMasterData.canonicalPlantFrom(
          i['plant']?.toString() ?? '', _plantDefs);
      final code = canon.contains(' — ')
          ? canon.split(' — ').first.toUpperCase()
          : canon.toUpperCase();
      return code == target || canon.toUpperCase().contains(target);
    }).toList();
  }

  /// Count incidents per WSA category using flexible matching.
  /// Matches the incident's wsaCategory field against the custom list entries.
  Map<String, int> get _wsaCounts {
    final filtered = _filteredIncidents;
    final counts = <String, int>{};

    for (final cat in _wsaCategories) {
      final catLower = cat.toLowerCase();
      // Extract keywords: strip leading number+dot, split on whitespace/punctuation
      final stripped = cat.replaceFirst(RegExp(r'^\d+\.\s*'), '').toLowerCase();
      final keywords = stripped.split(RegExp(r'[\s/()]+'))
          .where((w) => w.length > 2).toList();

      counts[cat] = filtered.where((i) {
        final wsa = (i['wsaCategory']?.toString() ?? '').toLowerCase();
        if (wsa.isEmpty) return false;
        // Exact match
        if (wsa == catLower) return true;
        // Contains match (either direction)
        if (wsa.contains(stripped) || stripped.contains(wsa)) return true;
        // Keyword match: any keyword from the category appears in the incident's wsaCategory
        for (final kw in keywords) {
          if (wsa.contains(kw)) return true;
        }
        return false;
      }).length;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);

    if (_loading) {
      return Container(
        padding: const EdgeInsets.all(24),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final counts = _wsaCounts;
    final maxCount = counts.values.fold(0, (a, b) => a > b ? a : b);
    final totalFiltered = _filteredIncidents.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sl.border),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(sl.isDark ? 0.2 : 0.06),
          blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with title + filter
          Row(children: [
            Icon(Icons.bar_chart_rounded, color: AppColors.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(
              I18n.t('dashboard.wsaChart'),
              style: TextStyle(color: sl.text1, fontSize: 15,
                fontWeight: FontWeight.w700))),
            // Plant filter dropdown
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.accent.withOpacity(0.3))),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedPlant,
                  isDense: true,
                  dropdownColor: sl.card,
                  style: TextStyle(color: AppColors.accent, fontSize: 11,
                    fontWeight: FontWeight.w600),
                  icon: Icon(Icons.arrow_drop_down,
                    color: AppColors.accent, size: 16),
                  items: _plants.map((p) => DropdownMenuItem(
                    value: p['code'],
                    child: Text(
                      p['code'] == 'all'
                        ? I18n.t('dashboard.entireSail')
                        : p['name']!,
                      style: TextStyle(color: sl.text1, fontSize: 11)),
                  )).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedPlant = val);
                  },
                ),
              ),
            ),
          ]),

          const SizedBox(height: 4),
          Text(
            '${I18n.t('home.totalCases')}: $totalFiltered',
            style: TextStyle(color: sl.text3, fontSize: 11)),
          const SizedBox(height: 16),

          // Bar chart — dynamically built from custom WSA list
          ..._wsaCategories.map((cat) {
            final count = counts[cat] ?? 0;
            final fraction = maxCount > 0 ? count / maxCount : 0.0;
            final barColor = _barColor(count, maxCount);
            // Display label: strip leading number for compact display
            final label = cat.replaceFirst(RegExp(r'^\d+\.\s*'), '');

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                // Category label
                SizedBox(
                  width: 100,
                  child: Text(
                    label,
                    style: TextStyle(color: sl.text2, fontSize: 10,
                      fontWeight: FontWeight.w500),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                // Bar
                Expanded(
                  child: Stack(
                    children: [
                      Container(
                        height: 20,
                        decoration: BoxDecoration(
                          color: sl.card2,
                          borderRadius: BorderRadius.circular(4))),
                      FractionallySizedBox(
                        widthFactor: fraction.clamp(0.0, 1.0),
                        child: Container(
                          height: 20,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [barColor.withOpacity(0.8), barColor]),
                            borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Count
                SizedBox(
                  width: 24,
                  child: Text(
                    '$count',
                    style: TextStyle(color: sl.text1, fontSize: 11,
                      fontWeight: FontWeight.w700),
                    textAlign: TextAlign.right)),
              ]),
            );
          }),
        ],
      ),
    );
  }

  Color _barColor(int count, int max) {
    if (count == 0) return AppColors.green;
    final ratio = max > 0 ? count / max : 0.0;
    if (ratio > 0.7) return AppColors.red;
    if (ratio > 0.4) return AppColors.amber;
    return AppColors.cyan;
  }
}
