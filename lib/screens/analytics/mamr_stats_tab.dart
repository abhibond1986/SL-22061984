// lib/screens/analytics/mamr_stats_tab.dart
//
// Reports → MAMR (My Area My Responsibility).
//
// Reads top-down in the order a responsible person thinks:
//   1. Your area      — the areas the signed-in user is responsible for, each
//                       with its compliance ring and what is still pending.
//   2. Other areas    — the rest of the plant, areas needing action first;
//                       areas with nothing recorded are folded into one line
//                       instead of a wall of zeros.
//   3. Entire plant   — one big ring, the headline figures, and the
//                       departments ranked by what is pending.
//
// Complied = the admin's LAST status stage; Pending = every earlier stage;
// Overdue = pending past its automatic target date (MamrDeadlines).
// Scoped through PlantScope like every other analytics tab.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../main.dart' show AppColors, SL, SLLayout;
import '../../services/admin_master_data.dart';
import '../../services/assignment_inbox.dart';
import '../../services/local_db.dart';
import '../../services/mamr_service.dart';
import '../../services/plant_scope.dart';
import '../../services/realtime_sync.dart';
import '../../widgets/bottom_nav_gap.dart';
import '../../widgets/content_width.dart';
import '../../widgets/mamr_visuals.dart';
import '../incident_detail_screen.dart';
import '../../services/pdf_export_stub.dart'
    if (dart.library.html) '../../services/pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

class MamrStatsTab extends StatefulWidget {
  const MamrStatsTab({super.key});

  @override
  State<MamrStatsTab> createState() => _MamrStatsTabState();
}

class _AreaRow {
  final String areaId;
  final String plant;
  final String dept;
  final String area;
  final String responsible;
  final MamrTally tally = MamrTally();
  final List<Map<String, dynamic>> items = [];
  _AreaRow(this.areaId, this.plant, this.dept, this.area, this.responsible);
}

class _MamrStatsTabState extends State<MamrStatsTab> {
  bool _loading = true;
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _all = const []; // MAMR rows in scope
  String _lastStatus = '';
  List<String> _plantCodes = const [];
  String _plant = ''; // '' = all (admin only)
  String _plantLabel = '';
  final Map<String, MamrRegister> _regs = {};
  final Map<String, String> _codeOfRow = {}; // incident id → plant code

  late DateTime _from;
  late DateTime _to;
  String _preset = 'month';
  bool _needsActionOnly = true;
  bool _showQuietAreas = false;

  @override
  void initState() {
    super.initState();
    _applyPreset('month', notify: false);
    RealtimeSync.incidentsRevision.addListener(_load);
    MamrService.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    RealtimeSync.incidentsRevision.removeListener(_load);
    MamrService.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final user = await LocalDB.getCurrentUser();
    final scope = await PlantScope.forUser(user);
    final inc = await scope.filterIncidents(await LocalDB.getIncidents());
    final mamr = inc.where(MamrObs.isMamr).toList();
    final last = await AdminMasterData.lastStatus();
    final plants = await AdminMasterData.getPlants();
    final resolve = MamrService.plantCodeResolver(plants);
    _codeOfRow.clear();
    final codes = <String>{};
    for (final i in mamr) {
      final c = resolve(i['plant']?.toString() ?? '');
      _codeOfRow[i['id']?.toString() ?? ''] = c;
      if (c.isNotEmpty) codes.add(c);
    }
    final regs = await MamrService.getAllRegisters();
    var plant = _plant;
    if (!scope.seesAllPlants) {
      plant = (AdminMasterData.plantEntryFor(scope.plant, plants)?['code'] ?? '')
          .toUpperCase();
    } else {
      codes.addAll(regs.values.where((r) => !r.isEmpty).map((r) => r.plant));
      // An admin who is also responsible for an area starts on that plant.
      if (plant.isEmpty) {
        final own = await MamrService.userPlantCode(user);
        if (codes.contains(own)) plant = own;
      }
    }
    final label = plant.isEmpty ? 'All plants' : await MamrService.plantLabelFor(plant);
    if (!mounted) return;
    setState(() {
      _user = user;
      _scope = scope;
      _all = mamr;
      _lastStatus = last.trim().toUpperCase();
      _plantCodes = codes.toList()..sort();
      _plant = plant;
      _plantLabel = label;
      _regs
        ..clear()
        ..addAll(regs);
      _loading = false;
    });
  }

  Future<void> _selectPlant(String code) async {
    final label = code.isEmpty ? 'All plants' : await MamrService.plantLabelFor(code);
    if (!mounted) return;
    setState(() {
      _plant = code;
      _plantLabel = label;
    });
  }

  bool _isComplied(Map<String, dynamic> i) {
    final s = (i['status']?.toString() ?? '').trim().toUpperCase();
    return s.isNotEmpty && s == _lastStatus;
  }

  DateTime? _dateOf(Map<String, dynamic> i) =>
      DateTime.tryParse(i['date']?.toString() ?? '')?.toLocal();

  String _plantOf(Map<String, dynamic> i) =>
      _codeOfRow[i['id']?.toString() ?? ''] ?? '';

  List<Map<String, dynamic>> get _inRange {
    final end = DateTime(_to.year, _to.month, _to.day, 23, 59, 59);
    return _all.where((i) {
      if (_plant.isNotEmpty && _plantOf(i) != _plant) return false;
      final d = _dateOf(i);
      if (d == null) return false;
      return !d.isBefore(_from) && !d.isAfter(end);
    }).toList();
  }

  // ── Dates ────────────────────────────────────────────────────────────────

  void _applyPreset(String p, {bool notify = true}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    void set() {
      _preset = p;
      _to = today;
      switch (p) {
        case 'month':
          _from = DateTime(now.year, now.month, 1);
          break;
        case '30':
          _from = today.subtract(const Duration(days: 29));
          break;
        case 'fy':
          // Indian financial year starts 1 April.
          _from = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
          break;
        case 'all':
          _from = DateTime(2020);
          break;
      }
    }
    notify ? setState(set) : set();
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      helpText: 'Observations recorded between',
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
      _preset = 'custom';
    });
  }

  String get _rangeText {
    if (_preset == 'all') return 'All time';
    final sameYear = _from.year == _to.year;
    final f = DateFormat(sameYear ? 'd MMM' : 'd MMM yyyy').format(_from);
    final t = DateFormat('d MMM yyyy').format(_to);
    return '$f – $t';
  }

  // ── Aggregation ──────────────────────────────────────────────────────────

  List<_AreaRow> _byArea(List<Map<String, dynamic>> rows) {
    final out = <String, _AreaRow>{};
    // Every active area appears, even with nothing recorded — "nobody has
    // reported anything in Scrap Yards" is itself worth knowing.
    final regs = _plant.isEmpty
        ? _regs.values
        : [if (_regs[_plant] != null) _regs[_plant]!];
    for (final reg in regs) {
      for (final a in reg.activeAreas) {
        out[a.id] = _AreaRow(a.id, reg.plant, a.dept, a.area,
            a.persons.map((p) => p.name).join(' & '));
      }
    }
    for (final i in rows) {
      final id = i['mamrAreaId']?.toString() ?? '';
      final row = out[id] ??= _AreaRow(
        id,
        _plantOf(i),
        i['mamrDept']?.toString() ?? '',
        i['mamrArea']?.toString() ?? '',
        MamrObs.responsible(i).map((p) => p.name).join(' & '),
      );
      final ok = _isComplied(i);
      row.tally.add(isComplied: ok, date: _dateOf(i),
          isOverdue: MamrDeadlines.isOverdue(i, complied: ok));
      row.items.add(i);
    }
    return out.values.toList();
  }

  Set<String> _myAreaIds() {
    final ids = AssignmentInbox.identities(_user);
    final mobile = _user?['mobile']?.toString() ?? '';
    final out = <String>{};
    for (final reg in _regs.values) {
      if (_plant.isNotEmpty && reg.plant != _plant) continue;
      for (final a in reg.activeAreas) {
        if (MamrObs.ownsArea(a, ids, mobile)) out.add(a.id);
      }
    }
    return out;
  }

  // ── Export ───────────────────────────────────────────────────────────────

  Future<void> _export(List<_AreaRow> rows, MamrTally total) async {
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final fmt = DateFormat('dd-MM-yyyy');
    final b = StringBuffer()
      ..writeln('MAMR - My Area My Responsibility')
      ..writeln('Plant,${q(_plantLabel)}')
      ..writeln('From,${fmt.format(_from)},To,${fmt.format(_to)}')
      ..writeln('Recorded,${total.recorded},Complied,${total.complied},'
          'Pending,${total.pending},Overdue,${total.overdue}')
      ..writeln()
      ..writeln('Plant,Deptt./Shop,Section/Area,Responsible person,Recorded,'
          'Complied,Pending,Overdue,Oldest pending (days)');
    final sorted = [...rows]
      ..sort((a, b) {
        final d = a.dept.compareTo(b.dept);
        return d != 0 ? d : a.area.compareTo(b.area);
      });
    for (final r in sorted) {
      b.writeln([
        q(r.plant), q(r.dept), q(r.area), q(r.responsible),
        r.tally.recorded, r.tally.complied, r.tally.pending, r.tally.overdue,
        r.tally.oldestPendingDays ?? '',
      ].join(','));
    }
    final name = 'MAMR_${_plant.isEmpty ? 'ALL' : _plant}_'
        '${DateFormat('yyyyMMdd').format(_from)}-${DateFormat('yyyyMMdd').format(_to)}.csv';
    final bytes = Uint8List.fromList(utf8.encode(b.toString()));
    if (kIsWeb) {
      try {
        final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', name)
          ..click();
        html.Url.revokeObjectUrl(url);
        return;
      } catch (_) {}
    }
    try {
      await Share.shareXFiles(
          [XFile.fromData(bytes, mimeType: 'text/csv', name: name)],
          subject: 'MAMR statistics');
    } catch (_) {}
  }

  Future<void> _open(Map<String, dynamic> inc) async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => IncidentDetailScreen(incident: inc)));
    _load();
  }

  void _openArea(_AreaRow r) {
    if (r.items.isEmpty) return;
    final sl = SL.of(context);
    final items = [...r.items]
      ..sort((a, b) {
        final ca = _isComplied(a), cb = _isComplied(b);
        if (ca != cb) return ca ? 1 : -1;
        return (mamrDaysLeft(a) ?? 999).compareTo(mamrDaysLeft(b) ?? 999);
      });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: sl.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          children: [
            Row(children: [
              MamrRing(tally: r.tally, size: 52, stroke: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.area,
                      style: TextStyle(color: sl.text1, fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  Text('${r.dept}  ·  ${mamrStatusLine(r.tally)}',
                      style: TextStyle(color: sl.text3, fontSize: 12.5)),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            for (final i in items)
              _ObsRow(
                inc: i,
                complied: _isComplied(i),
                onTap: () {
                  Navigator.pop(ctx);
                  _open(i);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_scope.problem != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_scope.problem!, textAlign: TextAlign.center,
              style: TextStyle(color: sl.text3, fontSize: 13)),
        ),
      );
    }

    final rows = _inRange;
    final total = MamrTally();
    for (final i in rows) {
      final ok = _isComplied(i);
      final late = MamrDeadlines.isOverdue(i, complied: ok);
      total.add(isComplied: ok, date: _dateOf(i), isOverdue: late);
    }
    final areas = _byArea(rows);
    final mine = _myAreaIds();
    final myRows = areas.where((a) => mine.contains(a.areaId)).toList();
    final otherRows = areas.where((a) => !mine.contains(a.areaId)).toList();
    final shortPlant = _plant.isEmpty ? 'all plants' : _plant;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        children: [
          ContentWidth(
            maxWidth: SLLayout.wide,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _filterBar(sl, areas, total),
              const SizedBox(height: 22),

              // 1 ── Your area ────────────────────────────────────────────
              _SectionTitle(
                title: myRows.length > 1 ? 'Your areas' : 'Your area',
                subtitle: myRows.isEmpty
                    ? null
                    : 'Where you are the responsible person',
              ),
              if (myRows.isEmpty)
                _quietNote(sl,
                    'You are not listed as the responsible person for any area '
                    'in $shortPlant. The figures for other areas and the whole '
                    'plant are below.')
              else
                for (final r in myRows) _myAreaCard(sl, r),
              const SizedBox(height: 26),

              // 2 ── Other areas ──────────────────────────────────────────
              _SectionTitle(
                title: myRows.isEmpty ? 'Areas' : 'Other areas',
                subtitle: 'Areas with pending observations come first',
                trailing: _needsActionToggle(sl),
              ),
              ..._otherAreas(sl, otherRows),
              const SizedBox(height: 26),

              // 3 ── Entire plant ─────────────────────────────────────────
              _SectionTitle(
                title: _plant.isEmpty ? 'All plants' : 'Entire $_plant',
                subtitle: _plantLabel,
              ),
              _plantSummary(sl, total),
              const SizedBox(height: 14),
              _departmentCard(sl, areas),
              const SizedBox(height: 10),
              Text(
                'Overdue means still pending after its target date. The target '
                'is set automatically when the observation is saved: Critical '
                '1 day, High 2 days, Medium 7 days, Low 15 days.',
                style: TextStyle(color: sl.text4, fontSize: 11.5, height: 1.4)),
              const BottomNavGap(),
            ]),
          ),
        ],
      ),
    );
  }

  // ── Filter bar ───────────────────────────────────────────────────────────

  Widget _filterBar(SL sl, List<_AreaRow> areas, MamrTally total) {
    Widget preset(String id, String label) => ChoiceChip(
          label: Text(label),
          selected: _preset == id,
          showCheckmark: false,
          selectedColor: kMamrTeal.withOpacity(sl.isDark ? 0.55 : 0.16),
          labelStyle: TextStyle(
              fontSize: 12.5,
              fontWeight: _preset == id ? FontWeight.w800 : FontWeight.w500,
              color: sl.text1),
          onSelected: (_) => _applyPreset(id),
        );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kMamrTeal.withOpacity(0.45)),
      ),
      child: MamrAreaBackdrop(
        intensity: 0.9,
        child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: kMamrTeal, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.place_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('My Area My Responsibility',
                  style: TextStyle(color: sl.text1, fontSize: 15,
                      fontWeight: FontWeight.w800)),
              if (_scope.seesAllPlants && _plantCodes.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Choose plant',
                  onSelected: _selectPlant,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('All plants')),
                    for (final c in _plantCodes)
                      PopupMenuItem(value: c, child: Text(c)),
                  ],
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(_plantLabel,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: sl.accentText, fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                    Icon(Icons.arrow_drop_down_rounded, color: sl.accentText),
                  ]),
                )
              else
                Text(_plantLabel,
                    style: TextStyle(color: sl.text3, fontSize: 13)),
            ]),
          ),
          IconButton(
            tooltip: 'Download as Excel (CSV)',
            onPressed: () => _export(areas, total),
            icon: Icon(Icons.file_download_outlined, color: sl.text2),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
            children: [
          InkWell(
            onTap: _pickRange,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kMamrTeal, width: 1.4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.date_range_rounded, size: 18, color: sl.text1),
                const SizedBox(width: 6),
                Text(_rangeText,
                    style: TextStyle(color: sl.text1, fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          preset('month', 'This month'),
          preset('30', 'Last 30 days'),
          preset('fy', 'This financial year'),
          preset('all', 'All time'),
        ]),
      ]),
        ),
      ),
    );
  }

  // ── 1. Your area ─────────────────────────────────────────────────────────

  Widget _myAreaCard(SL sl, _AreaRow r) {
    final pending = r.items.where((i) => !_isComplied(i)).toList()
      ..sort((a, b) =>
          (mamrDaysLeft(a) ?? 999).compareTo(mamrDaysLeft(b) ?? 999));
    final t = r.tally;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kMamrTeal.withOpacity(0.7), width: 1.6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            MamrRing(tally: t, size: 96, stroke: 10, caption: 'complied'),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.area,
                    style: TextStyle(color: sl.text1, fontSize: 18,
                        fontWeight: FontWeight.w800, height: 1.2)),
                const SizedBox(height: 2),
                Text(r.dept, style: TextStyle(color: sl.text3, fontSize: 13)),
                const SizedBox(height: 12),
                Wrap(spacing: 22, runSpacing: 10, children: [
                  MamrFigure(value: '${t.recorded}', label: 'Recorded'),
                  MamrFigure(value: '${t.complied}', label: 'Complied',
                      ink: t.complied > 0 ? sl.greenText : null),
                  MamrFigure(value: '${t.pending}', label: 'Pending',
                      ink: t.pending > 0 ? sl.amberText : null),
                  MamrFigure(value: '${t.overdue}', label: 'Overdue',
                      ink: t.overdue > 0 ? sl.redText : null),
                ]),
              ]),
            ),
          ]),
        ),
        Container(height: 1, color: sl.border),
        if (t.recorded == 0)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text('Nothing recorded in your area in this period.',
                style: TextStyle(color: sl.text3, fontSize: 13)),
          )
        else if (pending.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(Icons.verified_rounded, color: sl.greenText, size: 20),
              const SizedBox(width: 8),
              Text('Everything in your area is complied.',
                  style: TextStyle(color: sl.greenText, fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Waiting for your action',
                style: TextStyle(color: sl.text2, fontSize: 13,
                    fontWeight: FontWeight.w800)),
          ),
          for (final i in pending.take(4))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _ObsRow(inc: i, complied: false, onTap: () => _open(i)),
            ),
          if (pending.length > 4)
            TextButton(
              onPressed: () => _openArea(r),
              child: Text('See all ${pending.length} pending'),
            ),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }

  // ── 2. Other areas ───────────────────────────────────────────────────────

  Widget _needsActionToggle(SL sl) => FilterChip(
        label: const Text('Pending only'),
        selected: _needsActionOnly,
        showCheckmark: true,
        selectedColor: AppColors.amber.withOpacity(sl.isDark ? 0.35 : 0.18),
        labelStyle: TextStyle(color: sl.text1, fontSize: 12.5,
            fontWeight: FontWeight.w600),
        onSelected: (v) => setState(() => _needsActionOnly = v),
      );

  List<Widget> _otherAreas(SL sl, List<_AreaRow> rows) {
    final active = rows.where((r) => r.tally.recorded > 0).toList();
    final quiet = rows.where((r) => r.tally.recorded == 0).toList()
      ..sort((a, b) => a.area.compareTo(b.area));
    final shown = (_needsActionOnly
            ? active.where((r) => r.tally.pending > 0)
            : active)
        .toList()
      ..sort((a, b) {
        final o = b.tally.overdue.compareTo(a.tally.overdue);
        if (o != 0) return o;
        final p = b.tally.pending.compareTo(a.tally.pending);
        if (p != 0) return p;
        return b.tally.recorded.compareTo(a.tally.recorded);
      });
    final hiddenComplied = active.length - shown.length;

    final out = <Widget>[];
    if (shown.isEmpty) {
      out.add(_quietNote(
          sl,
          active.isEmpty
              ? 'No observations were recorded in any other area in this period.'
              : 'No area has anything pending. '
                '${active.length} area${active.length == 1 ? '' : 's'} complied everything.'));
    } else {
      out.add(Container(
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border),
        ),
        child: Column(children: [
          for (var k = 0; k < shown.length; k++) ...[
            if (k > 0) Container(height: 1, color: sl.border),
            _areaLine(sl, shown[k]),
          ],
        ]),
      ));
    }
    if (_needsActionOnly && hiddenComplied > 0) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: TextButton(
          onPressed: () => setState(() => _needsActionOnly = false),
          child: Text('Show $hiddenComplied fully complied area'
              '${hiddenComplied == 1 ? '' : 's'}'),
        ),
      ));
    }
    if (quiet.isNotEmpty) {
      out.add(InkWell(
        onTap: () => setState(() => _showQuietAreas = !_showQuietAreas),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(children: [
            Icon(_showQuietAreas ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: sl.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${quiet.length} area${quiet.length == 1 ? '' : 's'} with no '
                'observations in this period',
                style: TextStyle(color: sl.text3, fontSize: 13)),
            ),
          ]),
        ),
      ));
      if (_showQuietAreas) {
        out.add(Wrap(spacing: 6, runSpacing: 6, children: [
          for (final r in quiet)
            Tooltip(
              message: r.responsible.isEmpty
                  ? r.dept : '${r.dept}\nResponsible: ${r.responsible}',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: sl.card2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(r.area,
                    style: TextStyle(color: sl.text2, fontSize: 12)),
              ),
            ),
        ]));
      }
    }
    return out;
  }

  Widget _areaLine(SL sl, _AreaRow r) {
    final t = r.tally;
    return InkWell(
      onTap: () => _openArea(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(children: [
          MamrRing(tally: t, size: 40, stroke: 5),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.area,
                  style: TextStyle(color: sl.text1, fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 1),
              Text(
                r.responsible.isEmpty ? r.dept : '${r.dept}  ·  ${r.responsible}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: sl.text3, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              t.pending == 0 ? 'All complied' : '${t.pending} pending',
              style: TextStyle(
                  color: t.pending == 0 ? sl.greenText : sl.amberText,
                  fontSize: 13, fontWeight: FontWeight.w800)),
            if (t.overdue > 0)
              Text('${t.overdue} overdue',
                  style: TextStyle(color: sl.redText, fontSize: 12,
                      fontWeight: FontWeight.w700))
            else
              Text('of ${t.recorded}',
                  style: TextStyle(color: sl.text4, fontSize: 12)),
          ]),
          Icon(Icons.chevron_right_rounded, color: sl.text4),
        ]),
      ),
    );
  }

  // ── 3. Entire plant ──────────────────────────────────────────────────────

  Widget _plantSummary(SL sl, MamrTally t) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sl.border),
        ),
        child: LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 460;
          final ring = MamrRing(tally: t, size: narrow ? 120 : 140,
              stroke: narrow ? 12 : 14, caption: 'complied');
          final figures = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 28, runSpacing: 14, children: [
              MamrFigure(value: '${t.recorded}', label: 'Recorded', big: true),
              MamrFigure(value: '${t.complied}', label: 'Complied', big: true,
                  ink: t.complied > 0 ? sl.greenText : null),
              MamrFigure(value: '${t.pending}', label: 'Pending', big: true,
                  ink: t.pending > 0 ? sl.amberText : null),
              MamrFigure(value: '${t.overdue}', label: 'Overdue', big: true,
                  ink: t.overdue > 0 ? sl.redText : null),
            ]),
            const SizedBox(height: 14),
            Text(
              t.recorded == 0
                  ? 'No observations recorded in this period. Try "All time" '
                    'above, or file one from the MAMR tab.'
                  : t.oldestPendingDays == null
                      ? 'Nothing is pending.'
                      : 'Oldest pending observation is ${t.oldestPendingDays} '
                        'day${t.oldestPendingDays == 1 ? '' : 's'} old.',
              style: TextStyle(color: sl.text3, fontSize: 13, height: 1.4)),
            const SizedBox(height: 10),
            const MamrLegend(),
          ]);
          return narrow
              ? Column(children: [ring, const SizedBox(height: 16), figures])
              : Row(children: [
                  ring,
                  const SizedBox(width: 28),
                  Expanded(child: figures),
                ]);
        }),
      );

  Widget _departmentCard(SL sl, List<_AreaRow> areas) {
    final byDept = <String, MamrTally>{};
    final areaCount = <String, int>{};
    for (final a in areas) {
      final key = _plant.isEmpty && a.plant.isNotEmpty ? '${a.plant} · ${a.dept}' : a.dept;
      final t = byDept[key] ??= MamrTally();
      t.recorded += a.tally.recorded;
      t.complied += a.tally.complied;
      t.overdue += a.tally.overdue;
      areaCount[key] = (areaCount[key] ?? 0) + 1;
    }
    final list = byDept.entries.toList()
      ..sort((a, b) {
        final p = b.value.pending.compareTo(a.value.pending);
        return p != 0 ? p : b.value.recorded.compareTo(a.value.recorded);
      });
    if (list.isEmpty) return const SizedBox.shrink();
    return _panel(sl, 'By department', [
      for (final e in list)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.key.isEmpty ? 'Unspecified' : e.key,
                    style: TextStyle(color: sl.text1, fontSize: 13,
                        fontWeight: FontWeight.w700)),
                Text(
                  '${areaCount[e.key]} area${areaCount[e.key] == 1 ? '' : 's'}',
                  style: TextStyle(color: sl.text4, fontSize: 12)),
              ]),
            ),
            Expanded(flex: 4, child: MamrBar(tally: e.value, height: 8)),
            SizedBox(
              width: 92,
              child: Text(
                e.value.recorded == 0
                    ? 'None recorded'
                    : e.value.pending == 0
                        ? 'All complied'
                        : '${e.value.pending} pending',
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: e.value.recorded == 0
                        ? sl.text4
                        : e.value.pending == 0 ? sl.greenText : sl.amberText,
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
    ]);
  }

  // ── Shared bits ──────────────────────────────────────────────────────────

  Widget _panel(SL sl, String title, List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title,
              style: TextStyle(color: sl.text1, fontSize: 14.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          ...children,
        ]),
      );

  Widget _quietNote(SL sl, String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(color: sl.text2, fontSize: 13, height: 1.45)),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(color: sl.text1, fontSize: 19,
                    fontWeight: FontWeight.w800)),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(subtitle!,
                  style: TextStyle(color: sl.text3, fontSize: 12.5)),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

String _subline(Map<String, dynamic> inc) {
  final d = DateTime.tryParse(inc['date']?.toString() ?? '')?.toLocal();
  final by = (inc['reportedBy']?.toString() ?? '').trim();
  final when = d == null ? '' : 'Reported ${DateFormat('d MMM').format(d)}';
  if (by.isEmpty) return when;
  return when.isEmpty ? 'By $by' : '$when by $by';
}

/// One observation: status icon, title, who reported it and how long is left.
class _ObsRow extends StatelessWidget {
  const _ObsRow({required this.inc, required this.complied, required this.onTap});
  final Map<String, dynamic> inc;
  final bool complied;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final days = mamrDaysLeft(inc);
    final late = !complied && days != null && days < 0;
    final ink = complied ? sl.greenText : late ? sl.redText : sl.amberText;
    final title = (inc['title']?.toString() ?? '').replaceFirst(RegExp(r'^MAMR:\s*'), '');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(children: [
          Icon(
            complied
                ? Icons.check_circle_rounded
                : late ? Icons.error_rounded : Icons.schedule_rounded,
            color: ink, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title.isEmpty ? 'Observation' : title,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: sl.text1, fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
              Text(_subline(inc),
                  style: TextStyle(color: sl.text3, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(complied ? 'Complied' : mamrDueText(days),
              style: TextStyle(color: ink, fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}
