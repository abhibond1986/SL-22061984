import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../main.dart' show AppColors, SL;
import '../../services/local_db.dart';
import '../../services/image_storage.dart';
import '../../services/admin_master_data.dart';
import '../../services/plant_scope.dart';
import '../../services/pdf_export.dart';
import '../../services/sync_service.dart';
import '../../services/realtime_sync.dart';
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

  @override
  void initState() {
    super.initState();
    _applyPendingFilters();
    _load();
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

  Future<void> _load() async {
    final scope = await PlantScope.forUser();
    // Scope the data at the source: a non-admin never holds another plant's
    // records in memory, so no filter, card, PDF export or delete action below
    // can reach them.
    final inc = await scope.filterIncidents(await LocalDB.getIncidents());
    final user = await LocalDB.getCurrentUser();
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

    // ★ v35: My reports filter
    if (_myReportsOnly && _currentUserName.isNotEmpty) {
      list = list.where((i) =>
          (i['reportedBy']?.toString() ?? '') == _currentUserName).toList();
    }

    // Plant filter — compare on canonical plant name so all format
    // variants of the same plant are matched together.
    if (_plantFilter != 'All') {
      list = list.where((i) => _canonPlant(i) == _plantFilter).toList();
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

    return Column(children: [
      // Filter section
      _filterSection(sl),
      // Summary
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(children: [
          Text('Showing ${filtered.length} of ${_all.length} incidents',
              style: TextStyle(color: sl.text3, fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          // The pinned plant doesn't count as an active filter for a locked
          // user, and "Clear filters" must not reset it to 'All' — that was the
          // one control that could have widened the view back out.
          if (_sevFilter.isNotEmpty || _statusFilter.isNotEmpty ||
              (!_scope.isLocked && _plantFilter != 'All') ||
              _departmentFilter != 'All' ||
              _typeFilter != 'All' || _myReportsOnly)
            GestureDetector(
              onTap: () => setState(() {
                _sevFilter.clear();
                _statusFilter.clear();
                if (!_scope.isLocked) _plantFilter = 'All';
                _departmentFilter = 'All'; // ★ NEW: Clear department filter
                _typeFilter = 'All';
                _dateRange = '90 days';
                _myReportsOnly = false;
              }),
              child: Text('Clear filters', style: TextStyle(
                  color: sl.accentText, fontSize: 11,
                  fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
      // Incident list
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.search_off_rounded, color: sl.text4, size: 40),
                const SizedBox(height: 8),
                Text('No incidents match filters',
                    style: TextStyle(color: sl.text3, fontSize: 13)),
              ]))
            : RefreshIndicator(
                onRefresh: _load,
                color: AppColors.accent,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 80),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _incidentCard(sl, filtered[i]),
                ),
              ),
      ),
    ]);
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
                  setState(() => _plantFilter = v))),
          const SizedBox(width: 8),
          Expanded(child: _dropdownChip(sl, _departmentFilter, _departments, (v) =>
              setState(() => _departmentFilter = v))),
          const SizedBox(width: 8),
          _dropdownChip(sl, _dateRange,
              ['7 days', '30 days', '90 days', 'All'], (v) =>
              setState(() => _dateRange = v)),
        ]),
        const SizedBox(height: 8),
        // Row 2: Severity chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final s in _severities)
              _filterChip(sl, s.toUpperCase(), _sevFilter, _sevColorFor(s)),
            const SizedBox(width: 12),
            _typeChip(sl, 'All'),
            _typeChip(sl, 'AI_SCAN'),
            _typeChip(sl, 'NEAR_MISS'),
            const SizedBox(width: 12),
            // ★ v35: My Reports toggle
            _myReportsChip(sl),
          ]),
        ),
        const SizedBox(height: 6),
        // Row 3: Status chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final s in _statuses)
              _statusChip(sl, s.toUpperCase(), _statusColorFor(s)),
          ]),
        ),
      ]),
    );
  }

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

  Widget _dropdownChip(SL sl, String value, List<String> items,
      ValueChanged<String> onChanged) {
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
              fontSize: 10, fontWeight: FontWeight.w700)),
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
            Icon(Icons.person_outline_rounded, size: 11,
                color: active ? const Color(0xFF2196F3) : sl.text3),
            const SizedBox(width: 3),
            Text('Mine', style: TextStyle(
                color: active ? const Color(0xFF2196F3) : sl.text3,
                fontSize: 10, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  INCIDENT CARD — with type column + thumbnail
  // ═══════════════════════════════════════════════════════════════
  Widget _incidentCard(SL sl, Map<String, dynamic> inc) {
    final sev = inc['severity']?.toString().toUpperCase() ?? 'MEDIUM';
    final status = inc['status']?.toString().toUpperCase() ?? 'OPEN';
    final type = inc['type']?.toString().toUpperCase() ?? '';

    // Shared with the filter chips so a card and its chip always agree.
    final sevColor = _sevColorFor(sev);
    final statusColor = _statusColorFor(status);

    final date = inc['date']?.toString() ?? '';
    final dateStr = date.length >= 10 ? date.substring(0, 10) : date;

    // ★ Type styling
    final isAiScan = type == 'AI_SCAN';
    final typeColor = isAiScan ? AppColors.accent : AppColors.amber;
    final typeLabel = isAiScan ? 'AI Scan' : 'Near Miss';
    final typeIcon = isAiScan ? Icons.image_search_rounded : Icons.warning_amber_rounded;

    // ★ Thumbnail — multi-source fallback chain
    final thumbnail = inc['thumbnailBase64']?.toString() ?? '';
    final imageBase64 = inc['imageBase64']?.toString() ?? '';
    final hasInlineThumbnail = thumbnail.isNotEmpty && thumbnail != 'null';
    final hasInlineImage = imageBase64.isNotEmpty && imageBase64 != 'null' && imageBase64 != '[image]' && imageBase64.length > 100;
    final hasImageRef = (inc['imageRef']?.toString() ?? '').isNotEmpty &&
        inc['imageRef'].toString() != 'null';
    // Cloud-synced records may carry only a Supabase Storage URL (no file ref,
    // no inline base64) — those must also load asynchronously via ImageStorage.
    final hasImageUrl = (inc['imageUrl']?.toString() ?? '').startsWith('http');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => IncidentDetailScreen(
              incident: inc, onStatusChanged: _load))),
        child: Container(
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(color: sevColor, width: 3),
              top: BorderSide(color: sl.glassBorder),
              right: BorderSide(color: sl.glassBorder),
              bottom: BorderSide(color: sl.glassBorder),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ★ LEFT COLUMN: Thumbnail with multi-source fallback
            Container(
              width: 52,
              height: 52,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: typeColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: typeColor.withOpacity(0.2)),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasInlineThumbnail
                  ? Image.memory(
                      base64Decode(thumbnail),
                      fit: BoxFit.cover,
                      width: 52, height: 52,
                      errorBuilder: (_, __, ___) => _typeIconWidget(typeIcon, typeColor),
                    )
                  : hasInlineImage
                      ? Image.memory(
                          base64Decode(imageBase64),
                          fit: BoxFit.cover,
                          width: 52, height: 52,
                          errorBuilder: (_, __, ___) => _typeIconWidget(typeIcon, typeColor),
                        )
                      : (hasImageRef || hasImageUrl)
                          ? _asyncThumbnail(inc, typeIcon, typeColor)
                          : _typeIconWidget(typeIcon, typeColor),
            ),
            // ★ RIGHT COLUMN: Details
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Title + Status
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(
                    inc['title']?.toString() ?? 'Untitled',
                    style: TextStyle(color: sl.text1, fontSize: 14.5,
                        fontWeight: FontWeight.w700, height: 1.3),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                  )),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: statusColor.withOpacity(0.3)),
                    ),
                    child: Text(status, style: TextStyle(
                        color: sl.textOn(statusColor), fontSize: 9.5, fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Info row: plant, date, severity
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.factory_outlined, color: sl.text4, size: 12),
                  const SizedBox(width: 4),
                  Flexible(child: Text(
                    inc['plant']?.toString() ?? '—',
                    style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.2),
                    overflow: TextOverflow.ellipsis,
                  )),
                  const SizedBox(width: 10),
                  Icon(Icons.calendar_today_outlined, color: sl.text4, size: 12),
                  const SizedBox(width: 4),
                  Text(dateStr, style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.2)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: sevColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4)),
                    child: Text(sev, style: TextStyle(
                        color: sl.textOn(sevColor), fontSize: 9.5, fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Bottom row: category + type badge + reported by
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if ((inc['wsaCategory']?.toString() ?? '').isNotEmpty) ...[
                    Icon(Icons.label_outline, color: sl.text4, size: 11),
                    const SizedBox(width: 4),
                    Flexible(child: Text(inc['wsaCategory'].toString(),
                        style: TextStyle(color: sl.text4, fontSize: 9.5, height: 1.2),
                        overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 10),
                  ],
                  // ★ Type badge (more prominent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: typeColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: typeColor.withOpacity(0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(typeIcon, color: typeColor, size: 10),
                      const SizedBox(width: 4),
                      Text(typeLabel, style: TextStyle(
                          color: typeColor, fontSize: 9.5, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                // ★ v35: Audit status badge
                if (inc['auditStatus']?.toString() == 'NEEDS_REVIEW') ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFDC2626).withOpacity(0.3)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.rate_review_outlined, color: Color(0xFFDC2626), size: 9),
                      SizedBox(width: 2),
                      Text('Review', style: TextStyle(
                          color: Color(0xFFDC2626), fontSize: 10, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ] else if (inc['auditStatus']?.toString() == 'VERIFIED') ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.verified_outlined, color: Color(0xFF10B981), size: 9),
                      SizedBox(width: 2),
                      Text('Verified', style: TextStyle(
                          color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ],
                const Spacer(),
                if ((inc['reportedBy']?.toString() ?? '').isNotEmpty)
                  Flexible(child: Text(inc['reportedBy'].toString(),
                      style: TextStyle(color: sl.text4, fontSize: 9),
                      overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 8),
              // ── Actions: PDF report (all) + Delete (owner or admin only) ──
              Row(children: [
                _cardAction(
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'PDF',
                  color: AppColors.cyan,
                  onTap: () => _exportPdf(inc),
                ),
                if (_canDelete(inc)) ...[
                  const SizedBox(width: 8),
                  _cardAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    color: AppColors.red,
                    onTap: () => _confirmDelete(inc),
                  ),
                ],
              ]),
            ])),
          ]),
        ),
      ),
    );
  }

  /// Small pill button used in the incident card action row.
  Widget _cardAction({
    required IconData icon, required String label,
    required Color color, required VoidCallback onTap,
  }) {
    final sl = SL.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: sl.textOn(color), size: 14),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(
                color: sl.textOn(color), fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
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
