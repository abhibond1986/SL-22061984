import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../main.dart' show AppColors, SL, SLLayout;
import '../../widgets/content_width.dart';
import '../../services/local_db.dart';
import '../../services/image_storage.dart';
import '../../services/admin_master_data.dart';
import '../../services/plant_scope.dart';
import '../../services/pdf_export.dart';
import '../../services/sync_service.dart';
import '../../services/realtime_sync.dart';
import '../../services/incident_assign.dart';
import '../incident_detail_screen.dart';
import '../reports_tab.dart';

class IncidentLogTab extends StatefulWidget {
  const IncidentLogTab({super.key});
  @override
  State<IncidentLogTab> createState() => _IncidentLogTabState();
}

class _IncidentLogTabState extends State<IncidentLogTab> {
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  // Server-sync state for the strip above the list. See _syncAndLoad.
  bool _syncing = false;
  bool? _lastSyncOk;
  DateTime? _lastSyncAt;
  int _unsyncedCount = 0;

  // Filters
  /// 'All' is only ever a real option for a user who may see all plants. For a
  /// plant user _load() pins this to their own plant; it used to default to
  /// 'All' for everyone, which showed every plant's incidents.
  String _plantFilter = 'All';
  String _departmentFilter = 'All'; // ★ NEW: Department filter
  final Set<String> _sevFilter = {};
  final Set<String> _statusFilter = {};
  String _typeFilter = 'All';
  String _dateRange = '90 days';
  bool _myReportsOnly = false; // ★ v35: filter by current user
  /// null = decide from the viewport height (collapsed on short screens).
  bool? _filtersOpen;
  String _currentUserName = '';
  String _currentUserPno = '';
  bool _currentUserIsAdmin = false;
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);
  // Active canonical plant list (admin-editable) for name normalization.
  List<Map<String, String>> _plantDefs = AdminMasterData.sailPlants;
  List<String> _departments = []; // ★ NEW: Department list
  // Admin-configured severity and status vocabularies. The filter chips used
  // to be four hardcoded literals each, so a renamed or added level was
  // simply unfilterable.
  List<String> _severities = List<String>.from(AdminMasterData.defaultSeverities);
  List<String> _statuses   = List<String>.from(AdminMasterData.defaultStatuses);

  /// Established colours; anything the admin invents falls back to neutral.
  Color _sevColorFor(String sev) {
    switch (sev.trim().toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.amber;
      case 'LOW':      return AppColors.green;
      default:         return Colors.blueGrey;
    }
  }

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

  /// True if the current user may delete [inc]: admins can delete anything;
  /// a reporter can delete only their own AI scan / near-miss report.
  bool _canDelete(Map<String, dynamic> inc) {
    if (_currentUserIsAdmin) return true;
    final byName = (inc['reportedBy']?.toString() ?? '').trim().toLowerCase();
    final byPno  = (inc['reportedByPno']?.toString() ??
                    inc['reporterPno']?.toString() ?? '').trim().toLowerCase();
    final myName = _currentUserName.trim().toLowerCase();
    final myPno  = _currentUserPno.trim().toLowerCase();
    if (myPno.isNotEmpty && byPno.isNotEmpty && myPno == byPno) return true;
    if (myName.isNotEmpty && byName.isNotEmpty && myName == byName) return true;
    return false;
  }

  /// Canonical plant label for an incident (dedupes name variants).
  String _canonPlant(Map<String, dynamic> i) =>
      AdminMasterData.canonicalPlantFrom(
          i['plant']?.toString() ?? '', _plantDefs);

  /// True when [i] belongs to the plant named by [filterLabel].
  ///
  /// ★ 2026-09-08. Compares by plant CODE, resolving BOTH sides through
  /// [AdminMasterData.plantEntryFor], for the reason spelled out in
  /// PlantScope.filterIncidents: one plant can be spelled two ways, and this
  /// filter used to be handed `scope.plant` on the left and a canonicalised
  /// incident on the right. When those spellings disagreed a plant-locked user's
  /// log came back EMPTY — every row had already passed filterIncidents, then the
  /// pinned filter dropped all of them again. Same visible symptom as a sync
  /// failure, same cause as the plant-wise dashboard showing '—'.
  bool _matchesPlant(Map<String, dynamic> i, String filterLabel) {
    final raw = i['plant']?.toString() ?? '';
    final theirs = AdminMasterData.plantEntryFor(raw, _plantDefs);
    final wanted = AdminMasterData.plantEntryFor(filterLabel, _plantDefs);
    if (theirs == null) {
      // No configured plant matches this record. A user whose view is PINNED to
      // their own plant did not choose this filter, and PlantScope deliberately
      // lets them see unresolved records — re-dropping them here would undo that
      // and hide a report from the person who filed it. An admin who actively
      // picked a plant gets the strict answer.
      return _scope.isLocked && filterLabel == _scope.plant;
    }
    if (wanted != null) {
      return (theirs['code'] ?? '').toUpperCase() ==
          (wanted['code'] ?? '').toUpperCase();
    }
    return _canonPlant(i) == filterLabel;
  }

  /// True when [i] was reported by the signed-in user.
  ///
  /// Matches on PNO **or** name. `reportedBy` has been written as the display
  /// name, as the PNO, and as "Name (PNO)" at different points in this app's
  /// history, so an equality test against the name alone silently emptied "My
  /// Reports" for anyone whose records were stored either of the other two ways.
  /// [_canDelete] already resolved authorship this way; the filter did not.
  bool _isMine(Map<String, dynamic> i) {
    final byName = (i['reportedBy']?.toString() ?? '').trim().toLowerCase();
    final byPno = (i['reportedByPno']?.toString() ??
            i['reporterPno']?.toString() ??
            '')
        .trim()
        .toLowerCase();
    final myName = _currentUserName.trim().toLowerCase();
    final myPno = _currentUserPno.trim().toLowerCase();
    if (myPno.isNotEmpty && byPno.isNotEmpty && myPno == byPno) return true;
    if (myName.isNotEmpty && byName.isNotEmpty) {
      if (byName == myName) return true;
      // "Name (PNO)" and other decorated forms.
      if (byName.contains(myName)) return true;
    }
    // Last resort: the PNO was written into the name field.
    if (myPno.isNotEmpty && byName.isNotEmpty && byName == myPno) return true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    _applyPendingFilters();
    // Cache first (instant), then the server. The unforced sync is throttled
    // and coalesced inside SyncService, so opening the log is cheap.
    _load().then((_) => _syncAndLoad());
    // Live refresh when any device adds/edits/deletes an incident.
    RealtimeSync.incidentsRevision.addListener(_onRealtime);
    // Live refresh when the admin edits plants/departments/severities/statuses.
    AdminMasterData.revision.addListener(_onRealtime);
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_onRealtime);
    AdminMasterData.revision.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    if (mounted) _load();
  }

  /// ★ v35: Apply pending filters set by Home tab navigation
  void _applyPendingFilters() {
    if (ReportsTab.pendingSeverityFilter != null) {
      _sevFilter.add(ReportsTab.pendingSeverityFilter!);
      ReportsTab.pendingSeverityFilter = null;
    }
    if (ReportsTab.pendingStatusFilter != null) {
      _statusFilter.add(ReportsTab.pendingStatusFilter!);
      ReportsTab.pendingStatusFilter = null;
    }
    if (ReportsTab.pendingTypeFilter != null) {
      _typeFilter = ReportsTab.pendingTypeFilter!;
      ReportsTab.pendingTypeFilter = null;
    }
    if (ReportsTab.pendingMyReportsOnly) {
      _myReportsOnly = true;
      _dateRange = 'All';
      ReportsTab.pendingMyReportsOnly = false;
    }
  }

  /// Pull the server set, then reload. [force] bypasses the 90 s throttle —
  /// used by pull-to-refresh, where the user has explicitly asked for the
  /// latest. Never throws: a failed pull leaves the local log as it was.
  ///
  /// ★ 2026-10-03. Pull-to-refresh used to call [_load] alone, which re-read
  /// THIS device's cache and never touched the server — so a report saved on
  /// another device could not be fetched from the log at all; the user had to
  /// leave the screen and hope a background sync ran. The empty state had no
  /// refresh at all, which is exactly the state a newly signed-in device is in.
  Future<void> _syncAndLoad({bool force = false}) async {
    if (mounted) setState(() => _syncing = true);
    try {
      final res = await SyncService.fullSync(force: force)
          .timeout(const Duration(seconds: 45));
      _lastSyncOk = res['ok'] == true;
      // A throttled call returns ok without pulling; show the time of the
      // pull that actually happened, not "now".
      if (res['ok'] == true) {
        _lastSyncAt = DateTime.tryParse(res['syncTime']?.toString() ?? '')
                ?.toLocal() ??
            (res['skipped'] == null ? DateTime.now() : _lastSyncAt);
      }
    } catch (_) {
      _lastSyncOk = false;
    }
    await _load();
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _load() async {
    final scope = await PlantScope.forUser();
    final user = await LocalDB.getCurrentUser();
    // Scope the data at the source: a non-admin never holds another plant's
    // records in memory, so no filter, card, PDF export or delete action below
    // can reach them.
    //
    // ★ 2026-10-03, with one exception: the user's OWN reports are always kept.
    // A report filed from another device under a different plant (a transfer,
    // a visit, a profile edit) is not another plant's data leaking in — it is
    // the reporter's own work, and the log is where they look for it.
    final everything = await LocalDB.getIncidents();
    final scoped = await scope.filterIncidents(everything);
    // _isMine reads these two fields, so set them before it is used here.
    _currentUserName = user?['name']?.toString() ?? '';
    _currentUserPno = user?['pno']?.toString() ?? '';
    final scopedIds = scoped.map((i) => i['id']?.toString() ?? '').toSet();
    final inc = [
      ...scoped,
      ...everything.where((i) =>
          !scopedIds.contains(i['id']?.toString() ?? '') && _isMine(i)),
    ];
    final unsynced =
        (await LocalDB.getUnsyncedIncidents()).where((i) => inc.any(
            (x) => x['id']?.toString() == i['id']?.toString())).length;
    final plants = await AdminMasterData.getPlants();
    final depts = await AdminMasterData.getDepartments(); // ★ NEW: Load departments
    final sevs = await AdminMasterData.getSeverities();
    final statuses = await AdminMasterData.getStatuses();
    final adminVal = user?['isAdmin'];
    final isAdmin = adminVal is bool
        ? adminVal
        : adminVal?.toString().toLowerCase() == 'true';
    if (mounted) setState(() {
      _scope = scope;
      _all = inc;
      _unsyncedCount = unsynced;
      _plantDefs = plants;
      // A locked user's plant filter is pinned, not chosen — so a stale 'All'
      // (or a plant carried over from a previous session) can't widen the view.
      if (scope.isLocked) _plantFilter = scope.plant;
      _departments = ['All', ...depts]; // ★ NEW: Set departments
      _severities = sevs;
      _statuses = statuses;
      // Drop any active filter selection the admin has since deleted.
      _sevFilter.removeWhere(
          (s) => !sevs.map((e) => e.toUpperCase()).contains(s.toUpperCase()));
      _statusFilter.removeWhere((s) =>
          !statuses.map((e) => e.toUpperCase()).contains(s.toUpperCase()));
      _currentUserName = user?['name']?.toString() ?? '';
      _currentUserPno = user?['pno']?.toString() ?? '';
      _currentUserIsAdmin = isAdmin;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filtered {
    var list = List<Map<String, dynamic>>.from(_all);

    // ★ v35: My reports filter. Authorship is resolved by [_isMine] — PNO first,
    // then name — not by display-name equality.
    if (_myReportsOnly &&
        (_currentUserName.isNotEmpty || _currentUserPno.isNotEmpty)) {
      list = list.where(_isMine).toList();
    }

    // Plant filter — by plant CODE via [_matchesPlant], never by spelling.
    if (_plantFilter != 'All') {
      // A locked user's own reports stay visible under their pinned plant —
      // they were added past the scope in _load on purpose.
      list = list.where((i) =>
          (_scope.isLocked && _plantFilter == _scope.plant && _isMine(i)) ||
          _matchesPlant(i, _plantFilter)).toList();
    }

    // ★ NEW: Department filter
    if (_departmentFilter != 'All') {
      list = list.where((i) =>
          (i['dept']?.toString() ?? 'Unknown') == _departmentFilter).toList();
    }

    // Severity filter
    if (_sevFilter.isNotEmpty) {
      list = list.where((i) =>
          _sevFilter.contains(i['severity']?.toString().toUpperCase() ?? 'MEDIUM')).toList();
    }

    // Status filter
    if (_statusFilter.isNotEmpty) {
      list = list.where((i) =>
          _statusFilter.contains(i['status']?.toString().toUpperCase() ?? 'OPEN')).toList();
    }

    // Type filter
    if (_typeFilter != 'All') {
      list = list.where((i) =>
          (i['type']?.toString().toUpperCase() ?? '') == _typeFilter).toList();
    }

    // Date range filter
    final now = DateTime.now();
    int days = 90;
    if (_dateRange == '7 days') days = 7;
    else if (_dateRange == '30 days') days = 30;
    else if (_dateRange == 'All') days = 99999;

    if (days < 99999) {
      final cutoff = now.subtract(Duration(days: days));
      list = list.where((i) {
        final d = DateTime.tryParse(i['date']?.toString() ?? '');
        return d != null && d.isAfter(cutoff);
      }).toList();
    }

    // Sort by date descending
    list.sort((a, b) =>
        (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    return list;
  }

  // Unique CANONICAL plants present in the data (each appears once).
  List<String> get _plants {
    final s = <String>{};
    for (final i in _all) {
      final p = _canonPlant(i);
      if (p.isNotEmpty) s.add(p);
    }
    final list = s.toList()..sort();
    // 'All' is offered only to a user who may actually see all plants.
    // Prepending it unconditionally handed a locked user a way back out of
    // their own scope.
    if (_scope.isLocked) return [_scope.plant];
    return ['All', ...list];
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

    final filtered = _filtered;

    // ★ 2026-10-04. ONE scroll view for filters + list. The filter bar, the
    // summary and the sync strip used to sit in a fixed Column above an
    // Expanded list, so on a laptop (app bar + tab bar + filters + bottom nav)
    // the list got barely one card of height and scrolling never revealed a
    // whole case. Now the filters scroll away with the list, and on a short
    // viewport they start collapsed behind a "Filters" toggle.
    return LayoutBuilder(builder: (ctx, box) {
      final filtersOpen = _filtersOpen ?? box.maxHeight >= 620;
      final contentW =
          (box.maxWidth < SLLayout.wide ? box.maxWidth : SLLayout.wide) - 28;
      final table = contentW >= _kTableMinWidth;
      final gutter = slGutter(context,
          maxWidth: SLLayout.wide,
          base: const EdgeInsets.fromLTRB(14, 0, 14, 80));
      return RefreshIndicator(
        onRefresh: () => _syncAndLoad(force: true),
        color: AppColors.accent,
        child: CustomScrollView(
          // Pullable even when empty — a newly signed-in device starts here.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: ContentWidth(
                maxWidth: SLLayout.wide,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  _summaryBar(sl, filtered.length, filtersOpen),
                  if (filtersOpen) _filterSection(sl),
                  _syncStrip(sl),
                ]),
              ),
            ),
            if (filtered.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.search_off_rounded, color: sl.text4, size: 40),
                    const SizedBox(height: 8),
                    Text(_all.isEmpty
                            ? 'No reports on this device yet'
                            : 'No incidents match filters',
                        style: TextStyle(color: sl.text3, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('Pull down to fetch reports saved on other devices',
                        style: TextStyle(color: sl.text4, fontSize: 11)),
                  ]),
                )),
              )
            else ...[
              if (table)
                SliverPadding(
                  padding: EdgeInsets.only(
                      left: gutter.left, right: gutter.right),
                  sliver: SliverToBoxAdapter(child: _tableHeader(sl)),
                ),
              SliverPadding(
                // Gutter, not a wrap: this list is the app's longest and must
                // stay lazily built.
                padding: gutter,
                sliver: SliverList.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => table
                      ? _incidentRow(sl, filtered[i])
                      : _incidentCard(sl, filtered[i]),
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  /// Number of filters that differ from the defaults (pinned plant excluded).
  int get _activeFilterCount =>
      _sevFilter.length +
      _statusFilter.length +
      ((!_scope.isLocked && _plantFilter != 'All') ? 1 : 0) +
      (_departmentFilter != 'All' ? 1 : 0) +
      (_typeFilter != 'All' ? 1 : 0) +
      (_myReportsOnly ? 1 : 0) +
      (_dateRange != '90 days' ? 1 : 0);

  /// "Showing N of M" + Clear filters + the show/hide-filters toggle.
  Widget _summaryBar(SL sl, int shown, bool filtersOpen) {
    final active = _activeFilterCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Row(children: [
        Expanded(
          child: Text('Showing $shown of ${_all.length} incidents',
              style: TextStyle(color: sl.text3, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
        // The pinned plant doesn't count as an active filter for a locked
        // user, and "Clear filters" must not reset it to 'All' — that was the
        // one control that could have widened the view back out.
        if (active > 0)
          TextButton(
            onPressed: () => setState(() {
              _sevFilter.clear();
              _statusFilter.clear();
              if (!_scope.isLocked) _plantFilter = 'All';
              _departmentFilter = 'All';
              _typeFilter = 'All';
              _dateRange = '90 days';
              _myReportsOnly = false;
            }),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text('Clear filters', style: TextStyle(
                color: sl.accentText, fontSize: 12,
                fontWeight: FontWeight.w700)),
          ),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: () => setState(() => _filtersOpen = !filtersOpen),
          icon: Icon(
              filtersOpen
                  ? Icons.expand_less_rounded
                  : Icons.tune_rounded,
              size: 16, color: sl.accentText),
          label: Text(
              filtersOpen
                  ? 'Hide filters'
                  : (active > 0 ? 'Filters ($active)' : 'Filters'),
              style: TextStyle(color: sl.accentText, fontSize: 12,
                  fontWeight: FontWeight.w700)),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: BorderSide(color: sl.glassBorder),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ]),
    );
  }

  /// One-line server status above the list: syncing / N not uploaded yet /
  /// last pulled. Makes "is this every device's data?" answerable at a glance,
  /// and gives a stuck upload a button instead of a wait.
  Widget _syncStrip(SL sl) {
    final String label;
    final Color colour;
    final IconData icon;
    if (_syncing) {
      label = 'Syncing with server…';
      colour = sl.text3;
      icon = Icons.sync_rounded;
    } else if (_unsyncedCount > 0) {
      label = '$_unsyncedCount report${_unsyncedCount == 1 ? '' : 's'} on this '
          'device not uploaded yet — other devices can\'t see '
          '${_unsyncedCount == 1 ? 'it' : 'them'}';
      colour = const Color(0xFFE65100);
      icon = Icons.cloud_upload_outlined;
    } else if (_lastSyncOk == false) {
      label = 'Offline — showing reports saved on this device';
      colour = const Color(0xFFE65100);
      icon = Icons.cloud_off_rounded;
    } else if (_lastSyncAt != null) {
      final t = _lastSyncAt!;
      label = 'Up to date with all devices · '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      colour = const Color(0xFF2E7D32);
      icon = Icons.cloud_done_outlined;
    } else {
      return const SizedBox.shrink();
    }
    final showAction = !_syncing && (_unsyncedCount > 0 || _lastSyncOk == false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Row(children: [
        Icon(icon, size: 14, color: colour),
        const SizedBox(width: 6),
        Expanded(child: Text(label,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colour, fontSize: 11,
                fontWeight: FontWeight.w600))),
        if (showAction)
          TextButton(
            onPressed: () => _syncAndLoad(force: true),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text(_unsyncedCount > 0 ? 'Upload now' : 'Retry',
                style: const TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  FILTER SECTION
  // ═══════════════════════════════════════════════════════════════
  Widget _filterSection(SL sl) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Row 1: Plant dropdown + Department dropdown + Date range
        Row(children: [
          // A locked user gets their plant as a label, not a control: a
          // single-item dropdown would still read as "there are others to pick".
          // The department dropdown beside it stays fully usable.
          Expanded(child: _scope.isLocked
              ? _lockedPlantLabel(sl)
              : _dropdownChip(sl, _plantFilter, _plants, (v) =>
                  setState(() => _plantFilter = v), expand: true)),
          const SizedBox(width: 8),
          Expanded(child: _dropdownChip(sl, _departmentFilter, _departments, (v) =>
              setState(() => _departmentFilter = v), expand: true)),
          const SizedBox(width: 8),
          _dropdownChip(sl, _dateRange,
              ['7 days', '30 days', '90 days', 'All'], (v) =>
              setState(() => _dateRange = v)),
        ]),
        const SizedBox(height: 8),
        // Rows 2+: severity · type · mine · status chips in ONE wrap, so a
        // wide window spends one line on them instead of two fixed rows.
        Wrap(
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final s in _severities)
              _filterChip(sl, s.toUpperCase(), _sevFilter, _sevColorFor(s)),
            _chipGap(),
            _typeChip(sl, 'All'),
            _typeChip(sl, 'AI_SCAN'),
            _typeChip(sl, 'NEAR_MISS'),
            _chipGap(),
            // ★ v35: My Reports toggle
            _myReportsChip(sl),
            _chipGap(),
            for (final s in _statuses)
              _statusChip(sl, s.toUpperCase(), _statusColorFor(s)),
          ],
        ),
      ]),
    );
  }

  Widget _chipGap() => const SizedBox(width: 10, height: 1);

  /// The plant shown as plain text, in the same pill as the dropdowns beside
  /// it so the filter row keeps its shape. No affordance to change it.
  Widget _lockedPlantLabel(SL sl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: sl.glassBorder),
      ),
      child: Row(children: [
        Icon(Icons.factory_rounded, size: 13, color: sl.accentText),
        const SizedBox(width: 6),
        Expanded(child: Text(_scope.plant,
            style: TextStyle(color: sl.text1, fontSize: 12,
                fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  /// [expand] = the chip sits in an Expanded slot: the dropdown then fills it
  /// and ellipsizes a long plant/department name instead of overflowing on a
  /// phone (it used to overflow by ~230 px at 400 px wide).
  Widget _dropdownChip(SL sl, String value, List<String> items,
      ValueChanged<String> onChanged, {bool expand = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      decoration: BoxDecoration(
        color: sl.glassColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: sl.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: expand,
          dropdownColor: sl.card,
          style: TextStyle(color: sl.text1, fontSize: 12),
          icon: Icon(Icons.keyboard_arrow_down, color: sl.text3, size: 16),
          items: items.map((v) => DropdownMenuItem(
              value: v, child: Text(v, style: TextStyle(
                  color: sl.text1, fontSize: 12),
                  overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) { if (v != null) onChanged(v); },
        ),
      ),
    );
  }

  Widget _filterChip(SL sl, String label, Set<String> set, Color color) {
    final active = set.contains(label);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() {
          if (active) set.remove(label); else set.add(label);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.15) : sl.glassColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? color : sl.glassBorder, width: active ? 1.5 : 1),
          ),
          child: Text(label, style: TextStyle(
              color: active ? color : sl.text3,
              fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _statusChip(SL sl, String label, Color color) {
    final active = _statusFilter.contains(label);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() {
          if (active) _statusFilter.remove(label);
          else _statusFilter.add(label);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.15) : sl.glassColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? color : sl.glassBorder, width: active ? 1.5 : 1),
          ),
          child: Text(label, style: TextStyle(
              color: active ? color : sl.text3,
              fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _typeChip(SL sl, String label) {
    final active = _typeFilter == label;
    final displayLabel = label == 'AI_SCAN' ? 'AI Scan'
        : label == 'NEAR_MISS' ? 'Near Miss' : 'All Types';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _typeFilter = label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? AppColors.accent.withOpacity(0.15) : sl.glassColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? AppColors.accent : sl.glassBorder,
                width: active ? 1.5 : 1),
          ),
          child: Text(displayLabel, style: TextStyle(
              color: active ? AppColors.accent : sl.text3,
              fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  // ★ v35: "My Reports" filter chip
  Widget _myReportsChip(SL sl) {
    final active = _myReportsOnly;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _myReportsOnly = !_myReportsOnly),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2196F3).withOpacity(0.15) : sl.glassColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? const Color(0xFF2196F3) : sl.glassBorder,
                width: active ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.person_outline_rounded, size: 13,
                color: active ? const Color(0xFF2196F3) : sl.text3),
            const SizedBox(width: 3),
            Text('Mine', style: TextStyle(
                color: active ? const Color(0xFF2196F3) : sl.text3,
                fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  INCIDENT ROWS — ★ 2026-10-04 redesign
  //
  //  Two layouts from one set of parts:
  //   • TABLE (content ≥ _kTableMinWidth, i.e. laptop/desktop): one line per
  //     case in FIXED-WIDTH columns under a header, so plant, risk, status,
  //     owner and the action buttons line up vertically down the whole list.
  //     The action column always reserves the Delete slot, so PDF never jumps
  //     left on rows the user cannot delete.
  //   • CARD (phones / narrow windows): details on top, a divider, then a
  //     full-width footer — owner on the left, buttons right-aligned. The old
  //     card put the buttons inside the text column, indented under the
  //     thumbnail, which is the misalignment visible in the screenshot.
  //  Every row is lightly tinted by its RISK SCORE band (same bands as
  //  AdminMasterData.severityBands), with a solid bar of that colour on the
  //  left edge.
  // ═══════════════════════════════════════════════════════════════

  static const double _kTableMinWidth = 1000;
  static const double _kColThumb = 44;
  static const double _kColPlant = 160;
  static const double _kColRisk = 88;
  static const double _kColStatus = 170;
  static const double _kBtnAssign = 96;
  static const double _kBtnPdf = 64;
  static const double _kBtnDelete = 80;
  static const double _kBtnGap = 6;
  static const double _kColActions =
      _kBtnAssign + _kBtnPdf + _kBtnDelete + 2 * _kBtnGap;
  static const double _kColGap = 12;

  /// Stored 0–100 risk score, or null when the record carries none.
  int? _riskScoreOf(Map<String, dynamic> inc) {
    final raw = inc['riskScore'];
    if (raw == null) return null;
    final v = raw is num ? raw.round() : int.tryParse(raw.toString().trim());
    return v?.clamp(0, 100);
  }

  /// Band colour for a risk score; falls back to the severity colour when the
  /// record has no score. Bands = AdminMasterData.severityBands.
  Color _riskColorFor(int? score, String sev) {
    if (score == null) return _sevColorFor(sev);
    final b = AdminMasterData.severityBands;
    if (score >= (b['CRITICAL']?.min ?? 80)) return AppColors.crit;
    if (score >= (b['HIGH']?.min ?? 60)) return AppColors.red;
    if (score >= (b['MEDIUM']?.min ?? 35)) return AppColors.amber;
    return AppColors.green;
  }

  /// Light, opaque row background tinted with [c].
  Color _rowTint(SL sl, Color c) => Color.alphaBlend(
      c.withOpacity(sl.isDark ? 0.12 : 0.07),
      sl.isDark ? AppColors.darkCard : Colors.white);

  /// Row shell: rounded, risk-tinted, hairline border in the risk colour and
  /// a solid 4 px risk bar on the left. Built from a clipped Material + an
  /// unrounded left border because Flutter cannot paint a borderRadius on a
  /// Border whose sides differ in colour (it asserts).
  Widget _rowShell(SL sl, Color riskColor, Map<String, dynamic> inc,
      EdgeInsets padding, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _rowTint(sl, riskColor),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: riskColor.withOpacity(0.25)),
        ),
        child: InkWell(
          onTap: () => _openDetail(inc),
          child: Container(
            decoration: BoxDecoration(
                border: Border(left: BorderSide(color: riskColor, width: 4))),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }

  void _openDetail(Map<String, dynamic> inc) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              IncidentDetailScreen(incident: inc, onStatusChanged: _load)));

  /// Column headings for the table layout — same widths as [_incidentRow].
  Widget _tableHeader(SL sl) {
    TextStyle st() => TextStyle(
        color: sl.text4, fontSize: 10.5,
        fontWeight: FontWeight.w800, letterSpacing: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Row(children: [
        const SizedBox(width: _kColThumb + _kColGap),
        Expanded(child: Text('INCIDENT', style: st())),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColPlant, child: Text('PLANT · DATE', style: st())),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColRisk,
            child: Text('RISK', style: st(), textAlign: TextAlign.center)),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColStatus,
            child: Text('STATUS · ACTION OWNER', style: st())),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColActions,
            child: Text('ACTIONS', style: st(), textAlign: TextAlign.right)),
      ]),
    );
  }

  /// Desktop/laptop row: fixed columns, everything vertically centred.
  Widget _incidentRow(SL sl, Map<String, dynamic> inc) {
    final sev = inc['severity']?.toString().toUpperCase() ?? 'MEDIUM';
    final score = _riskScoreOf(inc);
    final riskColor = _riskColorFor(score, sev);
    final date = inc['date']?.toString() ?? '';
    final dateStr = date.length >= 10 ? date.substring(0, 10) : date;
    final reporter = inc['reportedBy']?.toString() ?? '';

    return _rowShell(sl, riskColor, inc,
        const EdgeInsets.fromLTRB(10, 10, 12, 10),
            Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
              _thumbnail(inc, _kColThumb),
              const SizedBox(width: _kColGap),
              // INCIDENT
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                _titleText(sl, inc),
                const SizedBox(height: 5),
                _tagRow(sl, inc),
              ])),
              const SizedBox(width: _kColGap),
              // PLANT · DATE
              SizedBox(width: _kColPlant, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                _iconLine(sl, Icons.factory_outlined,
                    inc['plant']?.toString() ?? '—', sl.text2),
                const SizedBox(height: 3),
                _iconLine(sl, Icons.calendar_today_outlined, dateStr, sl.text3),
                if (reporter.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  _iconLine(sl, Icons.edit_note_rounded, reporter, sl.text4),
                ],
              ])),
              const SizedBox(width: _kColGap),
              // RISK
              SizedBox(width: _kColRisk,
                  child: Center(child: _riskBadge(sl, score, sev, riskColor))),
              const SizedBox(width: _kColGap),
              // STATUS · OWNER
              SizedBox(width: _kColStatus, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                _statusPill(sl, inc),
                const SizedBox(height: 6),
                _assigneeLine(sl, inc),
              ])),
              const SizedBox(width: _kColGap),
              // ACTIONS — Delete slot always reserved so buttons line up.
              SizedBox(width: _kColActions,
                  child: _actionButtons(inc, reserveDeleteSlot: true)),
            ]),
    );
  }

  /// Phone / narrow-window card.
  Widget _incidentCard(SL sl, Map<String, dynamic> inc) {
    final sev = inc['severity']?.toString().toUpperCase() ?? 'MEDIUM';
    final score = _riskScoreOf(inc);
    final riskColor = _riskColorFor(score, sev);
    final date = inc['date']?.toString() ?? '';
    final dateStr = date.length >= 10 ? date.substring(0, 10) : date;

    return _rowShell(sl, riskColor, inc,
        const EdgeInsets.fromLTRB(10, 12, 12, 10),
            Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _thumbnail(inc, 52),
                const SizedBox(width: 10),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _titleText(sl, inc),
                  const SizedBox(height: 5),
                  Row(children: [
                    Flexible(child: _iconLine(sl, Icons.factory_outlined,
                        inc['plant']?.toString() ?? '—', sl.text3)),
                    const SizedBox(width: 10),
                    _iconLine(sl, Icons.calendar_today_outlined, dateStr,
                        sl.text3, shrink: false),
                  ]),
                ])),
                const SizedBox(width: 8),
                _riskBadge(sl, score, sev, riskColor),
              ]),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6, runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _statusPill(sl, inc),
                  ..._tags(sl, inc),
                ],
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: riskColor.withOpacity(0.18)),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (_, c) {
                final buttons = _actionButtons(inc, reserveDeleteSlot: false);
                // Side by side when there is room; otherwise owner on its own
                // line and the buttons right-aligned beneath it.
                if (c.maxWidth >= _kColActions + 140) {
                  return Row(children: [
                    Expanded(child: _assigneeLine(sl, inc)),
                    const SizedBox(width: 8),
                    buttons,
                  ]);
                }
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  _assigneeLine(sl, inc),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: buttons),
                ]);
              }),
            ]),
    );
  }

  // ── shared parts ────────────────────────────────────────────────

  Widget _titleText(SL sl, Map<String, dynamic> inc) => Text(
        inc['title']?.toString() ?? 'Untitled',
        style: TextStyle(color: sl.text1, fontSize: 14,
            fontWeight: FontWeight.w700, height: 1.3),
        maxLines: 2, overflow: TextOverflow.ellipsis,
      );

  Widget _iconLine(SL sl, IconData icon, String text, Color color,
      {bool shrink = true}) {
    final label = Text(text,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 11.5, height: 1.2));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: sl.text4, size: 12),
      const SizedBox(width: 4),
      shrink ? Flexible(child: label) : label,
    ]);
  }

  Widget _pillBox(String text, Color color, {IconData? icon, Color? fg}) {
    final sl = SL.of(context);
    final ink = fg ?? _inkOn(sl, color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, color: ink, size: 11),
          const SizedBox(width: 4),
        ],
        Text(text, style: TextStyle(color: ink, fontSize: 10,
            fontWeight: FontWeight.w800, letterSpacing: 0.2)),
      ]),
    );
  }

  /// Readable text colour on a tinted pill. Purple (ACTION TAKEN) and the
  /// neutral fallback are not in SL.textOn's map, so handle them here.
  Color _inkOn(SL sl, Color c) {
    if (c == AppColors.purple) {
      return sl.isDark ? const Color(0xFFB4A9FF) : const Color(0xFF5B3FD6);
    }
    if (c == Colors.blueGrey) return sl.text2;
    return sl.textOn(c);
  }

  Widget _statusPill(SL sl, Map<String, dynamic> inc) {
    final status = inc['status']?.toString().toUpperCase() ?? 'OPEN';
    return _pillBox(status, _statusColorFor(status));
  }

  /// Type badge, WSA category and audit badge.
  List<Widget> _tags(SL sl, Map<String, dynamic> inc) {
    final type = inc['type']?.toString().toUpperCase() ?? '';
    final isAiScan = type == 'AI_SCAN';
    final cat = inc['wsaCategory']?.toString() ?? '';
    final audit = inc['auditStatus']?.toString() ?? '';
    return [
      _pillBox(isAiScan ? 'AI Scan' : 'Near Miss',
          isAiScan ? AppColors.accent : AppColors.amber,
          icon: isAiScan
              ? Icons.image_search_rounded
              : Icons.warning_amber_rounded),
      if (audit == 'NEEDS_REVIEW')
        _pillBox('Review', AppColors.crit, icon: Icons.rate_review_outlined)
      else if (audit == 'VERIFIED')
        _pillBox('Verified', AppColors.green, icon: Icons.verified_outlined),
      if (cat.isNotEmpty && cat != '—')
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.label_outline, color: sl.text4, size: 12),
            const SizedBox(width: 3),
            Flexible(child: Text(cat,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: sl.text3, fontSize: 11))),
          ]),
        ),
    ];
  }

  Widget _tagRow(SL sl, Map<String, dynamic> inc) {
    final tags = _tags(sl, inc);
    return Row(children: [
      for (var i = 0; i < tags.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        // The category (last, free text) is the one allowed to shrink.
        i == tags.length - 1 && tags.length > 1
            ? Flexible(child: tags[i])
            : tags[i],
      ],
    ]);
  }

  /// Score over severity label, both in the risk-band colour.
  Widget _riskBadge(SL sl, int? score, String sev, Color riskColor) {
    final ink = sl.textOn(riskColor);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: score == null ? '—' : '$score',
            style: TextStyle(color: ink, fontSize: 18,
                fontWeight: FontWeight.w900, height: 1.0)),
        if (score != null)
          TextSpan(text: '/100',
              style: TextStyle(color: sl.text4, fontSize: 9.5,
                  fontWeight: FontWeight.w600)),
      ])),
      const SizedBox(height: 4),
      _pillBox(sev, _sevColorFor(sev)),
    ]);
  }

  /// Who implements the corrective action — or a visible "Unassigned".
  Widget _assigneeLine(SL sl, Map<String, dynamic> inc) {
    final name = IncidentAssign.assigneeName(inc);
    final has = name.isNotEmpty;
    final color = has ? sl.text2 : sl.amberText;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(has ? Icons.engineering_rounded : Icons.person_off_outlined,
          size: 13, color: has ? sl.accentText : sl.amberText),
      const SizedBox(width: 5),
      Flexible(child: Text(has ? name : 'Unassigned',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 11.5,
              fontWeight: has ? FontWeight.w600 : FontWeight.w700))),
    ]);
  }

  /// Assign · PDF · Delete, fixed widths. [reserveDeleteSlot] keeps the
  /// column the same width on rows the user may not delete (table layout).
  Widget _actionButtons(Map<String, dynamic> inc,
      {required bool reserveDeleteSlot}) {
    final assigned = IncidentAssign.hasAssignee(inc);
    final canDelete = _canDelete(inc);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _cardAction(
          icon: assigned
              ? Icons.swap_horiz_rounded
              : Icons.person_add_alt_1_rounded,
          label: assigned ? 'Transfer' : 'Assign',
          tooltip: assigned
              ? 'Hand the corrective action to someone else'
              : 'Assign who will implement the corrective action',
          color: AppColors.accent,
          width: _kBtnAssign,
          onTap: () => _assign(inc),
        ),
        const SizedBox(width: _kBtnGap),
        _cardAction(
          icon: Icons.picture_as_pdf_rounded,
          label: 'PDF',
          tooltip: 'Download / share PDF report',
          color: AppColors.cyan,
          width: _kBtnPdf,
          onTap: () => _exportPdf(inc),
        ),
        if (canDelete || reserveDeleteSlot)
          const SizedBox(width: _kBtnGap),
        if (canDelete)
          _cardAction(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            tooltip: 'Delete this report',
            color: AppColors.red,
            width: _kBtnDelete,
            onTap: () => _confirmDelete(inc),
          )
        else if (reserveDeleteSlot)
          const SizedBox(width: _kBtnDelete),
      ],
    );
  }

  /// Fixed-size pill button used in the row/card action area.
  Widget _cardAction({
    required IconData icon, required String label,
    required Color color, required VoidCallback onTap,
    required double width, String? tooltip,
  }) {
    final sl = SL.of(context);
    final btn = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          width: width,
          height: 32,
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.40)),
          ),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
            Icon(icon, color: sl.textOn(color), size: 14),
            const SizedBox(width: 5),
            Flexible(child: Text(label,
                maxLines: 1, overflow: TextOverflow.clip,
                style: TextStyle(color: sl.textOn(color), fontSize: 11.5,
                    fontWeight: FontWeight.w700))),
          ]),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  /// Assign / transfer the corrective action straight from the log.
  Future<void> _assign(Map<String, dynamic> inc) async {
    final res = await IncidentAssign.pickAndSave(context, inc);
    if (!mounted) return;
    if (res.changed) await _load();
    if (!mounted || res.message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.message),
      backgroundColor: res.changed ? AppColors.accent : AppColors.red,
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Thumbnail with the multi-source fallback chain (inline thumb → inline
  /// image → stored file / Storage URL → type icon).
  Widget _thumbnail(Map<String, dynamic> inc, double size) {
    final type = inc['type']?.toString().toUpperCase() ?? '';
    final isAiScan = type == 'AI_SCAN';
    final typeColor = isAiScan ? AppColors.accent : AppColors.amber;
    final typeIcon =
        isAiScan ? Icons.image_search_rounded : Icons.warning_amber_rounded;
    final thumbnail = inc['thumbnailBase64']?.toString() ?? '';
    final imageBase64 = inc['imageBase64']?.toString() ?? '';
    final hasInlineThumbnail = thumbnail.isNotEmpty && thumbnail != 'null';
    final hasInlineImage = imageBase64.isNotEmpty && imageBase64 != 'null' &&
        imageBase64 != '[image]' && imageBase64.length > 100;
    final hasImageRef = (inc['imageRef']?.toString() ?? '').isNotEmpty &&
        inc['imageRef'].toString() != 'null';
    final hasImageUrl = (inc['imageUrl']?.toString() ?? '').startsWith('http');

    Widget child;
    if (hasInlineThumbnail || hasInlineImage) {
      Uint8List? bytes;
      try {
        bytes = base64Decode(hasInlineThumbnail ? thumbnail : imageBase64);
      } catch (_) {}
      child = bytes == null
          ? _typeIconWidget(typeIcon, typeColor)
          : Image.memory(bytes, fit: BoxFit.cover,
              width: size, height: size, gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  _typeIconWidget(typeIcon, typeColor));
    } else if (hasImageRef || hasImageUrl) {
      child = _asyncThumbnail(inc, typeIcon, typeColor);
    } else {
      child = _typeIconWidget(typeIcon, typeColor);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: typeColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: typeColor.withOpacity(0.2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  /// Generate + download/share the PDF report for one incident.
  Future<void> _exportPdf(Map<String, dynamic> inc) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Generating PDF…'),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
    try {
      Uint8List? imageBytes;
      try {
        imageBytes = await ImageStorage.getImageForIncident(inc);
      } catch (_) {}
      await PdfExport.downloadOrShareIncident(
        incident: inc,
        reporterName: inc['reportedBy']?.toString() ?? 'SAIL Safety Officer',
        reporterPno: inc['reportedByPno']?.toString() ?? inc['reporterPno']?.toString() ?? '',
        imageBytes: imageBytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('PDF failed: $e'),
        backgroundColor: AppColors.red,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// Confirm + delete an incident (AI scan or near miss), then refresh.
  Future<void> _confirmDelete(Map<String, dynamic> inc) async {
    final sl = SL.of(context);
    final id = inc['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final title = inc['title']?.toString() ?? 'this report';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          Icon(Icons.delete_forever_rounded, color: sl.redText, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('Delete report?',
              style: TextStyle(color: sl.text1, fontSize: 15, fontWeight: FontWeight.w800))),
        ]),
        content: Text('“$title” will be permanently deleted. This cannot be undone.',
            style: TextStyle(color: sl.text2, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: sl.text3))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await LocalDB.deleteIncident(id);
      await SyncService.deleteIncident(id).catchError((_) => false);
    } catch (_) {}
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Report deleted'),
      backgroundColor: AppColors.red,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _typeIconWidget(IconData icon, Color color) {
    return Center(child: Icon(icon, color: color.withOpacity(0.5), size: 24));
  }

  // ═══════════════════════════════════════════════════════════════
  //  ASYNC THUMBNAIL — loads from ImageStorage file system
  // ═══════════════════════════════════════════════════════════════
  final Map<String, Uint8List?> _imageCache = {};

  Widget _asyncThumbnail(Map<String, dynamic> inc, IconData typeIcon, Color typeColor) {
    final imageRef = inc['imageRef']?.toString() ?? '';
    final incId = inc['id']?.toString() ?? imageRef;

    // Check cache first
    if (_imageCache.containsKey(incId)) {
      final cached = _imageCache[incId];
      if (cached != null) {
        return Image.memory(cached, fit: BoxFit.cover, width: 52, height: 52,
            errorBuilder: (_, __, ___) => _typeIconWidget(typeIcon, typeColor));
      }
      return _typeIconWidget(typeIcon, typeColor);
    }

    // Load asynchronously and generate thumbnail if needed
    return FutureBuilder<Uint8List?>(
      future: _loadAndCacheThumbnail(inc),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done && snapshot.data != null) {
          _imageCache[incId] = snapshot.data;
          return Image.memory(snapshot.data!, fit: BoxFit.cover, width: 52, height: 52,
              errorBuilder: (_, __, ___) => _typeIconWidget(typeIcon, typeColor));
        }
        if (snapshot.connectionState == ConnectionState.done) {
          _imageCache[incId] = null; // Mark as "no image"
          return _typeIconWidget(typeIcon, typeColor);
        }
        // Loading state
        return Center(child: SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: typeColor.withOpacity(0.5))));
      },
    );
  }

  /// Load image and generate thumbnail on-the-fly for efficient display
  Future<Uint8List?> _loadAndCacheThumbnail(Map<String, dynamic> inc) async {
    try {
      // Get the full image from storage
      final imageBytes = await ImageStorage.getImageForIncident(inc);
      if (imageBytes == null) return null;

      // Generate a small thumbnail for display (more efficient than showing full image)
      final thumbnail = ImageStorage.generateThumbnail(imageBytes);
      if (thumbnail != null) {
        return base64Decode(thumbnail);
      }

      // Fallback: return original if thumbnail generation fails
      return imageBytes;
    } catch (e) {
      print('[IncidentLog] Failed to load thumbnail: $e');
      return null;
    }
  }
}
