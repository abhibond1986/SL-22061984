// lib/screens/analytics/mamr_stats_tab.dart
//
// Reports → MAMR (requirement ② of the MAMR sheet): how many observations
// were recorded From–To, and how many are Complied vs Pending — overall, by
// category, and by department → area with the responsible person.
//
// Complied = the admin's LAST status stage; Pending = every earlier stage.
// Never a literal 'CLOSED' — see overview_tab for the bug that caused.
// Scoped through PlantScope like every other analytics tab: a plant user
// and a plant SED see their own plant; the super admin can choose.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../main.dart' show SL, SLLayout;
import '../../services/admin_master_data.dart';
import '../../services/local_db.dart';
import '../../services/mamr_service.dart';
import '../../services/plant_scope.dart';
import '../../services/realtime_sync.dart';
import '../../widgets/bottom_nav_gap.dart';
import '../../widgets/content_width.dart';
import '../incident_detail_screen.dart';
import '../../services/pdf_export_stub.dart'
    if (dart.library.html) '../../services/pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

const Color _kMamr = Color(0xFF0F766E);

class MamrStatsTab extends StatefulWidget {
  const MamrStatsTab({super.key});

  @override
  State<MamrStatsTab> createState() => _MamrStatsTabState();
}

class _AreaRow {
  final String areaId;
  final String dept;
  final String area;
  final String responsible;
  final MamrTally tally = MamrTally();
  final List<Map<String, dynamic>> items = [];
  _AreaRow(this.areaId, this.dept, this.area, this.responsible);
}

class _MamrStatsTabState extends State<MamrStatsTab> {
  bool _loading = true;
  PlantScope _scope = const PlantScope(plant: '', seesAllPlants: false);
  List<Map<String, dynamic>> _all = const []; // MAMR rows in scope
  String _lastStatus = '';
  List<String> _plantCodes = const [];
  String _plant = ''; // '' = all (admin only)
  final Map<String, MamrRegister> _regs = {};
  final Map<String, String> _codeOfRow = {}; // incident id → plant code

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
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
    final scope = await PlantScope.forUser();
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
    }
    if (!mounted) return;
    setState(() {
      _scope = scope;
      _all = mamr;
      _lastStatus = last.trim().toUpperCase();
      _plantCodes = codes.toList()..sort();
      _plant = plant;
      _regs
        ..clear()
        ..addAll(regs);
      _loading = false;
    });
  }

  bool _isComplied(Map<String, dynamic> i) {
    final s = (i['status']?.toString() ?? '').trim().toUpperCase();
    return s.isNotEmpty && s == _lastStatus;
  }

  DateTime? _dateOf(Map<String, dynamic> i) =>
      DateTime.tryParse(i['date']?.toString() ?? '')?.toLocal();

  List<Map<String, dynamic>> get _inRange {
    final end = DateTime(_to.year, _to.month, _to.day, 23, 59, 59);
    return _all.where((i) {
      if (_plant.isNotEmpty &&
          (_codeOfRow[i['id']?.toString() ?? ''] ?? '') != _plant) {
        return false;
      }
      final d = _dateOf(i);
      if (d == null) return false;
      return !d.isBefore(_from) && !d.isAfter(end);
    }).toList();
  }

  Future<void> _pickDate(bool from) async {
    final initial = from ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: from ? 'From date' : 'To date',
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
  }

  void _preset(String p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _to = today;
      switch (p) {
        case 'month':
          _from = DateTime(now.year, now.month, 1);
          break;
        case '30':
          _from = today.subtract(const Duration(days: 29));
          break;
        case 'fy':
          // Indian financial year: 1 April.
          _from = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
          break;
        case 'all':
          _from = DateTime(2020);
          break;
      }
    });
  }

  List<_AreaRow> _byArea(List<Map<String, dynamic>> rows) {
    final out = <String, _AreaRow>{};
    // Every active area of the selected plant appears, even with zero
    // observations — "no one has reported anything in Scrap Yards" is itself
    // worth seeing.
    final reg = _plant.isEmpty ? null : _regs[_plant];
    if (reg != null) {
      for (final a in reg.activeAreas) {
        out[a.id] = _AreaRow(a.id, a.dept, a.area,
            a.persons.map((p) => p.name).join(' & '));
      }
    }
    for (final i in rows) {
      final id = i['mamrAreaId']?.toString() ?? '';
      final row = out[id] ??= _AreaRow(
        id,
        i['mamrDept']?.toString() ?? '',
        i['mamrArea']?.toString() ?? '',
        MamrObs.responsible(i).map((p) => p.name).join(' & '),
      );
      row.tally.add(isComplied: _isComplied(i), date: _dateOf(i),
          isOverdue: MamrDeadlines.isOverdue(i, complied: _isComplied(i)));
      row.items.add(i);
    }
    final list = out.values.toList()
      ..sort((a, b) {
        final d = a.dept.compareTo(b.dept);
        return d != 0 ? d : a.area.compareTo(b.area);
      });
    return list;
  }

  Future<void> _export(List<_AreaRow> rows, MamrTally total) async {
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final fmt = DateFormat('dd-MM-yyyy');
    final b = StringBuffer()
      ..writeln('MAMR - My Area My Responsibility')
      ..writeln('Plant,${q(_plant.isEmpty ? 'All plants' : _plant)}')
      ..writeln('From,${fmt.format(_from)},To,${fmt.format(_to)}')
      ..writeln('Recorded,${total.recorded},Complied,${total.complied},Pending,${total.pending},Overdue,${total.overdue}')
      ..writeln()
      ..writeln('Deptt./Shop,Section/Area,Responsible person,Recorded,Complied,Pending,Overdue,Oldest pending (days)');
    for (final r in rows) {
      b.writeln([
        q(r.dept), q(r.area), q(r.responsible),
        r.tally.recorded, r.tally.complied, r.tally.pending, r.tally.overdue,
        r.tally.oldestPendingDays ?? '',
      ].join(','));
    }
    final name =
        'MAMR_${_plant.isEmpty ? 'ALL' : _plant}_${DateFormat('yyyyMMdd').format(_from)}-${DateFormat('yyyyMMdd').format(_to)}.csv';
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

  void _openItems(_AreaRow r) {
    if (r.items.isEmpty) return;
    final sl = SL.of(context);
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
          padding: const EdgeInsets.all(14),
          children: [
            Text('${r.dept} · ${r.area}',
                style: TextStyle(color: sl.text1, fontSize: 15,
                    fontWeight: FontWeight.w800)),
            Text('${r.tally.recorded} observations · ${r.tally.pending} pending',
                style: TextStyle(color: sl.text3, fontSize: 12)),
            const SizedBox(height: 10),
            for (final i in r.items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    _isComplied(i) ? Icons.check_circle_rounded : Icons.pending_rounded,
                    color: _isComplied(i) ? sl.greenText : sl.amberText),
                title: Text(i['title']?.toString() ?? '',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: sl.text1, fontSize: 13)),
                subtitle: Text(
                    '${i['mamrCategory'] ?? ''} · '
                    '${_dateOf(i) == null ? '' : DateFormat('dd MMM yyyy').format(_dateOf(i)!)} · '
                    '${_isComplied(i) ? 'Complied' : 'Pending'}',
                    style: TextStyle(color: sl.text3, fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => IncidentDetailScreen(incident: i)));
                  _load();
                },
              ),
          ],
        ),
      ),
    );
  }

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
    final byCat = <String, MamrTally>{
      for (final c in MamrCategories.all) c: MamrTally(),
    };
    for (final i in rows) {
      final ok = _isComplied(i);
      final late = MamrDeadlines.isOverdue(i, complied: ok);
      total.add(isComplied: ok, date: _dateOf(i), isOverdue: late);
      final c = i['mamrCategory']?.toString() ?? '';
      (byCat[c.isEmpty ? MamrCategories.other : c] ??= MamrTally())
          .add(isComplied: ok, date: _dateOf(i), isOverdue: late);
    }
    final areas = _byArea(rows);
    final fmt = DateFormat('dd MMM yyyy');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        children: [
          ContentWidth(
            maxWidth: SLLayout.wide,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // ── Filters ──
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sl.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sl.border),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Icon(Icons.place_rounded, color: _kMamr, size: 20),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('MAMR — My Area My Responsibility',
                          style: TextStyle(color: sl.text1, fontSize: 13.5,
                              fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      tooltip: 'Export CSV',
                      onPressed: () => _export(areas, total),
                      icon: const Icon(Icons.download_rounded),
                    ),
                  ]),
                  if (_scope.seesAllPlants) ...[
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: _plant,
                      isDense: true,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Plant / Unit',
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('All plants')),
                        for (final c in _plantCodes)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => setState(() => _plant = v ?? ''),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(_scope.label,
                          style: TextStyle(color: sl.text3, fontSize: 12)),
                    ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _dateBox(sl, 'From', fmt.format(_from), () => _pickDate(true))),
                    const SizedBox(width: 8),
                    Expanded(child: _dateBox(sl, 'To', fmt.format(_to), () => _pickDate(false))),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    ActionChip(label: const Text('This month'), onPressed: () => _preset('month')),
                    ActionChip(label: const Text('Last 30 days'), onPressed: () => _preset('30')),
                    ActionChip(label: const Text('This FY'), onPressed: () => _preset('fy')),
                    ActionChip(label: const Text('All time'), onPressed: () => _preset('all')),
                  ]),
                ]),
              ),
              const SizedBox(height: 12),

              // ── Headline tiles ──
              Row(children: [
                _tile(sl, '${total.recorded}', 'Recorded', sl.text1),
                const SizedBox(width: 8),
                _tile(sl, '${total.complied}', 'Complied', sl.greenText),
                const SizedBox(width: 8),
                _tile(sl, '${total.pending}', 'Pending',
                    total.pending > 0 ? sl.amberText : sl.text1),
                const SizedBox(width: 8),
                _tile(sl, '${total.overdue}', 'Overdue',
                    total.overdue > 0 ? sl.redText : sl.text1),
                const SizedBox(width: 8),
                _tile(sl, '${total.compliedPct.toStringAsFixed(0)}%', 'Complied %', sl.text1),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Overdue = pending past its automatic target date '
                  '(Critical 1 day · High 2 · Medium 7 · Low 15).',
                  style: TextStyle(color: sl.text4, fontSize: 11)),
              ),
              const SizedBox(height: 14),

              // ── By category ──
              _heading(sl, 'BY CATEGORY'),
              Container(
                decoration: BoxDecoration(
                  color: sl.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sl.border),
                ),
                child: Column(children: [
                  for (final e in byCat.entries)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(children: [
                        Expanded(child: Text(e.key,
                            style: TextStyle(color: sl.text2, fontSize: 12.5))),
                        Text('${e.value.recorded}',
                            style: TextStyle(color: sl.text1, fontSize: 12.5,
                                fontWeight: FontWeight.w800)),
                        SizedBox(
                          width: 92,
                          child: Text('  ${e.value.pending} pending',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  color: e.value.pending > 0 ? sl.amberText : sl.text4,
                                  fontSize: 12)),
                        ),
                      ]),
                    ),
                ]),
              ),
              const SizedBox(height: 14),

              // ── By department → area ──
              _heading(sl, 'BY DEPARTMENT & AREA'),
              if (areas.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _all.isEmpty
                        ? 'No MAMR observations yet.'
                        : 'No MAMR observations between ${fmt.format(_from)} and ${fmt.format(_to)}.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: sl.text3, fontSize: 12.5)),
                ),
              ..._areaTable(sl, areas),
              const BottomNavGap(),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _heading(SL sl, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
        child: Text(t,
            style: TextStyle(color: sl.text3, fontSize: 11.5,
                fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      );

  Widget _dateBox(SL sl, String label, String value, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            suffixIcon: const Icon(Icons.calendar_month_rounded, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(value, style: TextStyle(color: sl.text1, fontSize: 13)),
        ),
      );

  Widget _tile(SL sl, String n, String l, Color ink) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sl.border),
          ),
          child: Column(children: [
            Text(n, style: TextStyle(color: ink, fontSize: 20,
                fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(l, textAlign: TextAlign.center,
                style: TextStyle(color: sl.text3, fontSize: 11.5)),
          ]),
        ),
      );

  List<Widget> _areaTable(SL sl, List<_AreaRow> rows) {
    final out = <Widget>[];
    String? lastDept;
    for (final r in rows) {
      if (r.dept != lastDept) {
        lastDept = r.dept;
        final deptRows = rows.where((x) => x.dept == r.dept);
        final rec = deptRows.fold<int>(0, (n, x) => n + x.tally.recorded);
        final pen = deptRows.fold<int>(0, (n, x) => n + x.tally.pending);
        out.add(Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          decoration: BoxDecoration(
            color: sl.card2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Expanded(child: Text(r.dept.isEmpty ? '—' : r.dept,
                style: TextStyle(color: sl.text1, fontSize: 12.5,
                    fontWeight: FontWeight.w800))),
            Text('$rec recorded · $pen pending',
                style: TextStyle(color: sl.text3, fontSize: 11.5)),
          ]),
        ));
      }
      out.add(InkWell(
        onTap: r.items.isEmpty ? null : () => _openItems(r),
        child: Container(
          margin: const EdgeInsets.only(top: 4, left: 6),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.border),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.area,
                    style: TextStyle(color: sl.text1, fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
                if (r.responsible.isNotEmpty)
                  Text(r.responsible,
                      style: TextStyle(color: sl.text3, fontSize: 11.5)),
              ]),
            ),
            _num(sl, r.tally.recorded, 'Rec', sl.text1),
            _num(sl, r.tally.complied, 'Comp', sl.greenText),
            _num(sl, r.tally.pending, 'Pend',
                r.tally.pending > 0 ? sl.amberText : sl.text4),
            if (r.tally.overdue > 0)
              _num(sl, r.tally.overdue, 'Late', sl.redText),
            if (r.tally.oldestPendingDays != null)
              _num(sl, r.tally.oldestPendingDays!, 'Days', sl.text3),
          ]),
        ),
      ));
    }
    return out;
  }

  Widget _num(SL sl, int n, String l, Color ink) => SizedBox(
        width: 44,
        child: Column(children: [
          Text('$n', style: TextStyle(color: ink, fontSize: 14,
              fontWeight: FontWeight.w800)),
          Text(l, style: TextStyle(color: sl.text4, fontSize: 11)),
        ]),
      );
}
