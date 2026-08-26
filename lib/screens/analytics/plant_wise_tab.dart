import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../main.dart' show AppColors, SL;
import '../../services/local_db.dart';
import '../../services/admin_master_data.dart';
import '../../services/plant_scope.dart';
import '../../services/realtime_sync.dart';
import '../incident_detail_screen.dart';
import '../../widgets/bottom_nav_gap.dart';

/// Plant dashboard — cross-plant, for everyone.
///
/// EVERY user can select ANY plant here, via a dropdown of the full admin plant
/// list, with a department drill-down inside the chosen plant. This screen is
/// intentionally exempt from PlantScope's plant lock: comparing plants is the
/// point of it. The lock still applies everywhere else.
///
/// It does still OPEN on the viewer's own plant, which is the one thing the
/// earlier versions got wrong in both directions — first defaulting to
/// `_plants.first` (the alphabetically-first plant with data, i.e. usually
/// somebody else's), then locking a plant user to their own with no way out.
class PlantWiseTab extends StatefulWidget {
  const PlantWiseTab({super.key});
  @override
  State<PlantWiseTab> createState() => _PlantWiseTabState();
}

class _PlantWiseTabState extends State<PlantWiseTab> {
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  String? _selectedPlant;
  /// Department drill-down within the plant. Empty = all departments.
  String _dept = '';
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);
  /// Kept separate from `_scope.problem`: a signed-in user with a misconfigured
  /// plant must still get the full dropdown. See build().
  bool _signedIn = true;
  /// EVERY admin-configured plant, for EVERY user.
  ///
  /// This screen is deliberately outside the plant lock. Plant Wise exists to
  /// compare plants, and a dashboard that can only ever show the viewer's own
  /// plant cannot do that — so a plant user sees the same list here as an admin.
  /// That is a conscious visibility decision, not an oversight: it applies to
  /// this tab only, and PlantScope still governs the operational screens.
  ///
  /// Loaded from the admin list rather than derived from the data so a plant
  /// that has reported nothing yet is still selectable (and visibly empty),
  /// which the old chip row could not do.
  List<String> _selectable = const [];
  // Active canonical plant list (admin-editable) for name normalization.
  List<Map<String, String>> _plantDefs = AdminMasterData.sailPlants;
  List<String> _statuses = List<String>.from(AdminMasterData.defaultStatuses);
  Set<String> _openStatuses =
      AdminMasterData.openStatusesFrom(AdminMasterData.defaultStatuses);
  String _closedStatus = 'CLOSED';

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
    // Read the user once and hand it to forUser(), so `signedIn` and the scope
    // can never disagree about whether anybody is logged in.
    final user     = await LocalDB.getCurrentUser();
    final scope    = await PlantScope.forUser(user);
    // DELIBERATELY UNFILTERED — see the note on _selectable. Plant Wise is a
    // cross-plant comparison screen, so it loads every plant's records for
    // everyone. scope.filterIncidents() is still applied on the operational
    // screens (incident log, dashboard, near miss); it is only skipped here.
    final inc      = await LocalDB.getIncidents();
    final plants   = await AdminMasterData.getPlants();
    final statuses = await AdminMasterData.getStatuses();
    final open     = await AdminMasterData.getOpenStatuses();
    final closed   = await AdminMasterData.lastStatus();
    final depts    = await AdminMasterData.getDepartments();
    // Every configured plant, not scope.selectablePlants() — a plant-locked
    // user gets the same list as an admin on this screen.
    final choices  = await AdminMasterData.getPlantLabels();
    if (mounted) {
      setState(() {
        _scope        = scope;
        _signedIn     = user != null;
        _all          = inc;
        _plantDefs    = plants;
        _statuses     = statuses;
        _openStatuses = open;
        _closedStatus = closed.toUpperCase();
        _deptOrder    = depts;
        _selectable   = choices;
        _loading      = false;
        // Own plant first; otherwise the first plant that actually HAS records,
        // so an admin doesn't land on an empty dashboard just because the
        // admin list happens to start with a plant that has reported nothing.
        final options = _plantOptions;
        if (_selectedPlant == null && options.isNotEmpty) {
          if (scope.plant.isNotEmpty && options.contains(scope.plant)) {
            _selectedPlant = scope.plant;
          } else {
            final counts = _plantCounts;
            _selectedPlant = options.firstWhere(
                (p) => (counts[p] ?? 0) > 0,
                orElse: () => options.first);
          }
        }
        // A plant the admin has just deleted must not stay selected.
        if (_selectedPlant != null && !options.contains(_selectedPlant)) {
          _selectedPlant = options.isEmpty ? null : options.first;
          _dept = '';
        }
        // A department that just vanished from the admin list (or from this
        // plant's data) must not stay silently applied as a filter.
        if (_dept.isNotEmpty && !_deptOptions.contains(_dept)) _dept = '';
      });
    }
  }

  /// The admin's configured department list, in the admin's own order.
  /// Deliberately starts EMPTY rather than seeded with defaultDepartments: if
  /// the admin has cleared the list, the drill-down must show nothing, not a
  /// built-in fallback.
  List<String> _deptOrder = const [];

  /// Departments available for drill-down: those the admin has configured AND
  /// that this plant has actually reported. Departments are global in
  /// AdminMasterData (there is no plant→department mapping), so intersecting
  /// with this plant's own records is the only way to scope them.
  List<String> get _deptOptions {
    final present = _plantIncidentsAllDepts
        .map((i) => (i['dept']?.toString() ?? '').trim().toUpperCase())
        .where((d) => d.isNotEmpty)
        .toSet();
    return _deptOrder
        .where((d) => present.contains(d.trim().toUpperCase()))
        .toList();
  }

  /// Everything the dropdown offers, identical for every user.
  ///
  /// ONLY shows plants from the admin's canonical plant list. All incidents
  /// are normalized to match these canonical names through the canonicalization
  /// function. This ensures the dropdown never shows outdated or incorrect
  /// plant names like "Corporate Ranchi", "SSO Ranchi", etc.
  ///
  /// No `seesAllPlants` branch: it used to return just the viewer's own plant
  /// for a plant user. See the note on [_selectable] for why that was dropped.
  /// EVERY admin-configured plant, including ones with no records yet.
  ///
  /// This used to filter to `counts[p] > 0` — plants that already had incidents.
  /// That filter was the cause of the "dropdown is missing" bug: when it removed
  /// every entry, [_plantSelector] hit its `options.isEmpty` guard and rendered
  /// SizedBox.shrink(), while build() simultaneously showed "Select a plant
  /// above" — telling the user to use a control that had just erased itself.
  ///
  /// The filter emptied the list in two ordinary situations, neither of them an
  /// error state:
  ///   1. A fresh deployment where no plant has reported yet.
  ///   2. Any case where incident `plant` strings do not canonicalise onto an
  ///      admin label. Counts are keyed by canonicalPlantFrom() output while
  ///      options come from plantLabel(); a single mismatch drops that plant's
  ///      count, and if it misses for all of them the dropdown vanishes rather
  ///      than degrading.
  ///
  /// The zero-count case was already handled downstream — the dropdown items
  /// deliberately render a muted row with '—' for `n == 0` — so the filter was
  /// also contradicting the item builder's own stated intent.
  ///
  /// Still admin-only: no data-derived plant names are added, so a plant that is
  /// not in the admin list cannot appear here. Admin remains authoritative.
  List<String> get _plantOptions => _selectable;

  /// Incident count per canonical plant, so the dropdown can show which plants
  /// actually have records instead of making the user select each one to find out.
  Map<String, int> get _plantCounts {
    final m = <String, int>{};
    for (final i in _all) {
      final p = _canonPlant(i);
      if (p.isNotEmpty) m[p] = (m[p] ?? 0) + 1;
    }
    return m;
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

  /// Everything for the selected plant, BEFORE the department drill-down.
  /// The department option list must come from this — filtering by a department
  /// and then deriving the options from the result would leave exactly one
  /// option and trap the user in it.
  List<Map<String, dynamic>> get _plantIncidentsAllDepts {
    if (_selectedPlant == null) return const [];
    return _all.where((i) => _canonPlant(i) == _selectedPlant).toList();
  }

  /// What the dashboard actually renders: plant + optional department.
  List<Map<String, dynamic>> get _plantIncidents =>
      PlantScope.filterByDepartment(_plantIncidentsAllDepts, _dept);

  /// True when [i] is still open, per the ADMIN's status ladder. Previously
  /// `status != 'CLOSED'`, which counted a renamed final stage as open and
  /// treated VERIFIED as open too.
  bool _isOpen(Map<String, dynamic> i) {
    final s = (i['status']?.toString().trim().toUpperCase() ?? '');
    if (s.isEmpty) return _openStatuses.isNotEmpty;
    return _openStatuses.contains(s);
  }

  bool _isClosedInc(Map<String, dynamic> i) =>
      _closedStatus.isNotEmpty &&
      (i['status']?.toString().trim().toUpperCase() ?? '') == _closedStatus;

  // KPIs for selected plant (+ department, if drilled down)
  int get _pTotal => _plantIncidents.length;
  int get _pOpen => _plantIncidents.where(_isOpen).length;
  int get _pCritical => _plantIncidents.where((i) =>
      i['severity']?.toString().toUpperCase() == 'CRITICAL').length;
  double get _pClosureRate {
    if (_pTotal == 0) return 0;
    return _plantIncidents.where(_isClosedInc).length / _pTotal * 100;
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
    // A record with no status counts as the FIRST status in the admin's ladder,
    // not a literal 'OPEN' — otherwise renaming that stage creates a phantom
    // 'OPEN' bucket alongside the real one.
    final fallback =
        _statuses.isEmpty ? '' : _statuses.first.trim().toUpperCase();
    for (final i in _plantIncidents) {
      var s = (i['status']?.toString().trim().toUpperCase() ?? '');
      if (s.isEmpty) s = fallback;
      if (s.isEmpty) continue;
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
    // Only a missing SESSION blocks this screen now.
    //
    // This used to bail out on any `_scope.problem`, which also covers "your
    // profile has no plant set" and "your plant doesn't match the admin list".
    // Those were fatal while the screen could only ever show the viewer's own
    // plant. They aren't any more: what's displayed no longer depends on the
    // viewer's plant, only on the dropdown selection. Such a user simply gets
    // no pre-selected plant and picks one — blocking them would deny the
    // cross-plant access this screen is now meant to give everyone.
    if (!_signedIn) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
              _scope.problem ?? 'Not signed in — no plant data available.',
              textAlign: TextAlign.center,
              style: TextStyle(color: sl.text3, fontSize: 13, height: 1.5)),
        ),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: Text(
            'No data recorded yet',
            textAlign: TextAlign.center,
            style: TextStyle(color: sl.text3, fontSize: 14)),
      );
    }

    return SingleChildScrollView(
      // Bottom inset clears the translucent bottom nav bar (`extendBody: true`).
      padding: EdgeInsets.fromLTRB(14, 14, 14, BottomNavGap.height(context) + 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Dropdown of EVERY plant, for every user — this screen is exempt from
        // the plant lock on purpose. It falls back to a plain header only when
        // a single plant exists, never as a permission check.
        _plantSelector(sl),
        const SizedBox(height: 10),
        // Department drill-down within the plant.
        _deptSelector(sl),
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
              // NEVER say "select a plant above" when there is no selector
              // above. _plantSelector renders nothing when the admin's plant
              // list is empty, and this message used to appear anyway — which
              // is exactly how the missing-dropdown bug presented: an
              // instruction pointing at a control that was not on screen.
              // Name the real blocker instead, and say who can clear it.
              _plantOptions.isEmpty
                  ? 'No plants configured yet.\nAsk your safety admin to add '
                      'plants in Admin → Plant & Department Master.'
                  : _selectedPlant == null
                      ? 'Select a plant above'
                      : _dept.isEmpty
                          ? 'No incidents recorded for $_selectedPlant yet'
                          : 'No incidents for $_dept in $_selectedPlant',
              textAlign: TextAlign.center,
              style: TextStyle(color: sl.text3, fontSize: 13, height: 1.5))),
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SINGLE PLANT HEADER — shown instead of a one-item dropdown
  // ═══════════════════════════════════════════════════════════════
  /// Used ONLY when there is genuinely one plant to choose from, so a dropdown
  /// would open to a single row and read as broken. This is no longer the
  /// plant-locked case: every user now gets the full dropdown (see
  /// [_selectable]), so the label comes from the selection rather than from
  /// `_scope.plant`, which is empty for an admin and rendered a blank header.
  Widget _singlePlantHeader(SL sl) {
    final label = _selectedPlant ??
        (_plantOptions.isEmpty ? '' : _plantOptions.first);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withOpacity(0.30)),
      ),
      child: Row(children: [
        Icon(Icons.factory_rounded, size: 16, color: sl.accentText),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PLANT',
                style: TextStyle(
                    color: sl.text3,
                    fontSize: 9,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  DEPARTMENT DRILL-DOWN — within the plant
  // ═══════════════════════════════════════════════════════════════
  Widget _deptSelector(SL sl) {
    final opts = _deptOptions;
    // Nothing to drill into: either the admin configured no departments, or
    // this plant has never reported one. Show nothing rather than an empty
    // control — the admin panel is authoritative.
    if (opts.isEmpty) return const SizedBox.shrink();

    Widget chip(String label, String value) {
      final active = _dept == value;
      return Padding(
        padding: const EdgeInsets.only(right: 7),
        child: GestureDetector(
          onTap: () => setState(() => _dept = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: active ? AppColors.cyan : sl.glassColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: active ? AppColors.cyan : sl.glassBorder),
            ),
            child: Text(label,
                style: TextStyle(
                    color: active ? Colors.white : sl.text2,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('DEPARTMENT',
          style: TextStyle(
              color: sl.text3,
              fontSize: 9,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 7),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          // '' means all departments in the plant — the drill-down is a
          // refinement, so there must always be a way back out of it.
          chip('All departments', ''),
          for (final d in opts) chip(d, d),
        ]),
      ),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT SELECTOR — dropdown over every plant this user may see
  // ═══════════════════════════════════════════════════════════════
  /// Was a horizontal chip row built from `_plants`, i.e. only plants that
  /// already had incidents. With one plant reporting, that rendered as a single
  /// chip which looked like a button that did nothing. A dropdown states the
  /// full list up front and shows the record count beside each entry.
  ///
  /// Lists every admin-configured plant, with or without records — see
  /// [_plantOptions] for why filtering by record count made the whole control
  /// disappear.
  Widget _plantSelector(SL sl) {
    final options = _plantOptions;

    // Nothing selectable: an unresolved scope is already reported by build(),
    // so this means the admin's plant list is genuinely empty. Admin is
    // authoritative — show nothing rather than a built-in fallback list.
    //
    // build() prints the matching "no plants configured" explanation for this
    // case. KEEP THE TWO IN STEP: when this returns shrink() and build() still
    // says "select a plant above", the user is told to use a control that is not
    // there, which is precisely the bug this pair was fixed for on 2026-08-17.
    if (options.isEmpty) return const SizedBox.shrink();

    // Exactly one plant exists: a dropdown would open to a single row and imply
    // there are others. State it plainly instead. NOT a permission check — the
    // plant lock no longer applies on this screen.
    if (options.length == 1) return _singlePlantHeader(sl);

    final counts = _plantCounts;
    final value  = (_selectedPlant != null && options.contains(_selectedPlant))
        ? _selectedPlant
        : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('PLANT',
          style: TextStyle(
              color: sl.text3,
              fontSize: 9,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 7),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: sl.glassColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withOpacity(0.35)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            hint: Text('Select a plant',
                style: TextStyle(color: sl.text3, fontSize: 12)),
            icon: Icon(Icons.expand_more_rounded,
                color: sl.accentText, size: 20),
            dropdownColor: sl.card,
            borderRadius: BorderRadius.circular(12),
            style: TextStyle(
                color: sl.text1, fontSize: 12, fontWeight: FontWeight.w600),
            items: options.map((p) {
              final n = counts[p] ?? 0;
              return DropdownMenuItem<String>(
                value: p,
                child: Row(children: [
                  Icon(Icons.factory_rounded,
                      size: 14, color: sl.accentText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(p,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            // A plant with no records is still selectable, but
                            // muted so the list reads at a glance.
                            color: n > 0 ? sl.text1 : sl.text3,
                            fontSize: 12,
                            fontWeight:
                                n > 0 ? FontWeight.w600 : FontWeight.w500)),
                  ),
                  const SizedBox(width: 8),
                  Text(n > 0 ? '$n' : '—',
                      style: TextStyle(
                          color: n > 0 ? sl.accentText : sl.text4,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ]),
              );
            }).toList(),
            // Reset the department too — the previous plant's department almost
            // certainly doesn't exist in the new one, and leaving it applied
            // shows a confusingly empty dashboard.
            onChanged: (p) {
              if (p == null) return;
              setState(() {
                _selectedPlant = p;
                _dept = '';
              });
            },
          ),
        ),
      ),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT KPI CARDS (tappable)
  // ═══════════════════════════════════════════════════════════════
  Widget _plantKpis(SL sl) {
    // Titles carry the department when one is applied, so a drill-through
    // sheet can't be mistaken for the whole plant.
    final scopeLabel =
        _dept.isEmpty ? '$_selectedPlant' : '$_dept, $_selectedPlant';
    return Row(children: [
      _miniKpi(sl, 'Total', '$_pTotal', const Color(0xFF6366F1),
          () => _showIncidentsSheet('All — $scopeLabel', _plantIncidents)),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Open', '$_pOpen', AppColors.amber,
          () => _showIncidentsSheet('Open — $scopeLabel',
              _plantIncidents.where(_isOpen).toList())),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Critical', '$_pCritical', AppColors.crit,
          () => _showIncidentsSheet('Critical — $scopeLabel',
              _plantIncidents.where((i) => i['severity']?.toString().toUpperCase() == 'CRITICAL').toList())),
      const SizedBox(width: 8),
      _miniKpi(sl, 'Closed %', '${_pClosureRate.toStringAsFixed(0)}%', AppColors.green,
          () => _showIncidentsSheet('Closed — $scopeLabel',
              _plantIncidents.where(_isClosedInc).toList())),
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
                color: sl.textOn(color), fontSize: 18, fontWeight: FontWeight.w800)),
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
              final fallbackKey = _statuses.isEmpty
                  ? '' : _statuses.first.trim().toUpperCase();
              return Expanded(child: GestureDetector(
                onTap: () => _showIncidentsSheet(
                    '$label — ${_dept.isEmpty ? _selectedPlant : '$_dept, $_selectedPlant'}',
                    _plantIncidents.where((i) {
                      var s = (i['status']?.toString().trim().toUpperCase() ?? '');
                      if (s.isEmpty) s = fallbackKey;
                      return s == statusKey;
                    }).toList()),
                child: Column(children: [
                  Text('$count', style: TextStyle(
                      color: sl.textOn(color), fontSize: 18, fontWeight: FontWeight.w800)),
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
                      color: sl.textOn(sevColor), fontSize: 8, fontWeight: FontWeight.w800)),
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
                  color: sl.accentText, fontSize: 14, fontWeight: FontWeight.w800)),
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
                                    color: sl.textOn(sevColor), fontSize: 8, fontWeight: FontWeight.w800)),
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
