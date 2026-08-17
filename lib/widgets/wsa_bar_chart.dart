// lib/widgets/wsa_bar_chart.dart
// ✅ v23: WSA-13 Bar Chart — now uses AdminMasterData custom list as source of truth.
// Shows count of incidents by WSA category with a plant filter dropdown.

import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import '../services/i18n.dart';
import '../services/local_db.dart';
import '../services/admin_master_data.dart';
import '../services/plant_scope.dart';
// For incidentsRevision. This chart used to be refreshed only as a side effect
// of its parent being destroyed and rebuilt after a sync (the home shell bumped
// HomeTab's ValueKey). That remount is gone, so the chart now subscribes to the
// same notifiers as every other data widget — otherwise it renders whatever was
// in LocalDB at first build and silently disagrees with the stat cards above it.
import '../services/realtime_sync.dart';

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
  /// This widget is embedded in the landing screen, where it used to offer an
  /// "Entire SAIL" option to every user — an all-plants control on a screen that
  /// otherwise has no plant selector. A locked user now gets neither the option
  /// nor the dropdown.
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);

  /// Guards against out-of-order loads. A single sync bumps `revision` once per
  /// master-data list it writes (six of them) plus `incidentsRevision` once, so
  /// several `_loadData` calls can be in flight together and finish in any order.
  /// Without this, a slower earlier load could overwrite a newer snapshot.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
    RealtimeSync.incidentsRevision.addListener(_reload);
    AdminMasterData.revision.addListener(_reload);
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_reload);
    AdminMasterData.revision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    final gen = ++_loadGen;
    final scope = await PlantScope.forUser();
    // Scope at the source, so even the 'all' code can only ever mean "all the
    // plants this user may see".
    final inc = await scope.filterIncidents(await LocalDB.getIncidents());
    // ✅ v23: Load WSA categories from AdminMasterData (same source as admin panel)
    final wsa = await AdminMasterData.getWsaCauses();
    final plants = await AdminMasterData.getPlants();
    if (mounted && gen == _loadGen) setState(() {
      _scope = scope;
      _incidents = inc;
      _wsaCategories = wsa;
      _plantDefs = plants;
      // Build plant dropdown from loaded master data
      _plants = [
        // 'all' is offered only to a user who may actually see all plants.
        if (scope.seesAllPlants)
          <String, String>{'code': 'all', 'name': 'Entire SAIL'},
        ...plants.map((p) {
          final code = p['code'] ?? '';
          final name = p['name'] ?? '';
          // Format: CODE — Name (or just name if it already contains a dash)
          final displayName = name.contains('—') ? name : '$code — $name';
          return {'code': code, 'name': displayName};
        }).toList(),
      ];
      // Pin a locked user to their own plant instead of leaving the stale 'all'.
      if (scope.isLocked) _selectedPlant = _codeOf(scope.plant);
      // Keep the selection inside the rebuilt list. DropdownButton ASSERTS when
      // its value matches no item, and this list is now rebuilt in place on every
      // master-data change rather than only on a remount — so an admin deleting
      // the plant a user happens to have selected would crash their chart. Also
      // covers the pre-existing case of a user who sees neither 'all' nor any
      // plant matching the default.
      if (!_plants.any((p) => p['code'] == _selectedPlant)) {
        _selectedPlant = _plants.isNotEmpty ? (_plants.first['code'] ?? 'all') : 'all';
      }
      _loading = false;
    });
  }

  /// Code token of a canonical "CODE — Name" label, used as the filter value.
  String _codeOf(String canonicalLabel) => canonicalLabel.contains(' — ')
      ? canonicalLabel.split(' — ').first.trim()
      : canonicalLabel.trim();

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
    // An unresolved scope is reported, not silently widened to all plants.
    if (_scope.problem != null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sl.border),
        ),
        child: Center(
          child: Text(_scope.problem!,
              textAlign: TextAlign.center,
              style: TextStyle(color: sl.text3, fontSize: 12, height: 1.5)),
        ),
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
            // Plant filter — a locked user gets their plant as a plain label in
            // the same pill, with no affordance to switch away from it.
            if (_scope.isLocked)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.accent.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.factory_rounded,
                      size: 12, color: AppColors.accent),
                  const SizedBox(width: 5),
                  // Bounded rather than Flexible: this Row sits in an unbounded
                  // slot of the header row, where a flex child would throw.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(_scope.plant,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              )
            else
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
