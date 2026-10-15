// lib/widgets/mamr_home_card.dart
//
// Home → My Area My Responsibility.
//
// What an individual needs to track, in order:
//   1. My area      — each area they are responsible for: compliance ring,
//                     complied / pending / overdue, the Near Misses still open
//                     in that shop, and a Report button.
//      (Not responsible for any area? Their own shop is shown instead.)
//   2. My reports   — MAMR observations they filed themselves, and how many
//                     have been complied.
//   3. All areas    — the plant's full list, collapsible, pending first.
//
// "Mine" is matched by linked username OR by mobile number, so a responsible
// person sees their area even before the SED has linked their account.
// All counts are current status (not date-filtered): Home answers "what is
// open right now"; Reports answers "what happened between these dates".

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show AppColors, SL;
import '../screens/mamr_admin_screen.dart';
import '../services/admin_master_data.dart';
import '../services/assignment_inbox.dart';
import '../services/mamr_service.dart';
import '../services/plant_scope.dart';
import 'mamr_visuals.dart';

class MamrHomeCard extends StatefulWidget {
  const MamrHomeCard({
    super.key,
    required this.user,
    required this.incidents,
    required this.onReport,
  });

  final Map<String, dynamic>? user;

  /// Already plant-scoped by the Home tab. Contains MAMR and Near Miss rows.
  final List<Map<String, dynamic>> incidents;

  /// Called after the area has been queued on [MamrService.pendingArea];
  /// the Home tab switches to the MAMR tab.
  final VoidCallback onReport;

  @override
  State<MamrHomeCard> createState() => _MamrHomeCardState();
}

class _MamrHomeCardState extends State<MamrHomeCard> {
  List<String> _plants = const [];
  String _plant = '';
  MamrRegister _reg = const MamrRegister(plant: '');
  bool _canManage = false;
  String _lastStatus = '';
  bool _loaded = false;
  bool _allOpen = false;
  String _search = '';
  /// The whole card folds down to its status band. Remembered per device.
  bool _collapsed = false;
  static const _kCollapsedPref = 'mamr_home_collapsed';

  @override
  void initState() {
    super.initState();
    MamrService.revision.addListener(_load);
    AdminMasterData.revision.addListener(_load);
    _load();
    SharedPreferences.getInstance().then((p) {
      final v = p.getBool(_kCollapsedPref) ?? false;
      if (mounted && v != _collapsed) setState(() => _collapsed = v);
    });
  }

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_kCollapsedPref, _collapsed));
  }

  @override
  void dispose() {
    MamrService.revision.removeListener(_load);
    AdminMasterData.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final u = widget.user;
      final plants = await MamrService.fileablePlants(u);
      final own = await MamrService.userPlantCode(u);
      var plant = _plant;
      if (plant.isEmpty || !plants.contains(plant)) {
        plant = own.isNotEmpty ? own : (plants.isEmpty ? '' : plants.first);
      }
      final reg = await MamrService.getRegister(plant);
      final manage = plant.isNotEmpty && await MamrService.canManage(u, plant);
      final last = await AdminMasterData.lastStatus();
      if (!mounted) return;
      setState(() {
        _plants = plants;
        _plant = plant;
        _reg = reg;
        _canManage = manage;
        _lastStatus = last.trim().toUpperCase();
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _switchPlant(String code) async {
    _plant = code;
    await _load();
  }

  // ── Counting ─────────────────────────────────────────────────────────────

  bool _complied(Map<String, dynamic> i) {
    final st = (i['status']?.toString() ?? '').trim().toUpperCase();
    return st.isNotEmpty && st == _lastStatus;
  }

  void _addTo(MamrTally t, Map<String, dynamic> i) {
    final ok = _complied(i);
    t.add(
        isComplied: ok,
        date: DateTime.tryParse(i['date']?.toString() ?? ''),
        isOverdue: MamrDeadlines.isOverdue(i, complied: ok));
  }

  static String _key(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '');

  /// Department names are typed differently in different places ("MED - SMS"
  /// in the area sheet, "MED-SMS" or "SMS MED" elsewhere), so compare on
  /// letters and digits only, and accept one containing the other.
  static bool _sameShop(String a, String b) {
    final x = _key(a), y = _key(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    if (x.length >= 3 && y.length >= 3) return x.contains(y) || y.contains(x);
    return false;
  }

  bool _isNearMiss(Map<String, dynamic> i) =>
      (i['type']?.toString().toUpperCase() ?? '') == 'NEAR_MISS';

  bool _isMine(Map<String, dynamic> i) {
    final u = widget.user;
    if (u == null) return false;
    final pno = (u['pno']?.toString() ?? '').trim().toLowerCase();
    final rp = (i['reportedByPno']?.toString() ?? '').trim().toLowerCase();
    if (pno.isNotEmpty && rp.isNotEmpty) return pno == rp;
    final name = (u['name']?.toString() ?? '').trim().toLowerCase();
    return name.isNotEmpty &&
        (i['reportedBy']?.toString() ?? '').trim().toLowerCase() == name;
  }

  /// (open, total) Near Misses for one shop.
  (int, int) _nearMissIn(String dept) {
    var open = 0, total = 0;
    for (final i in widget.incidents) {
      if (!_isNearMiss(i)) continue;
      if (!_sameShop(i['dept']?.toString() ?? '', dept)) continue;
      total++;
      if (!_complied(i)) open++;
    }
    return (open, total);
  }

  MamrTally _mamrInShop(String dept) {
    final t = MamrTally();
    for (final i in widget.incidents) {
      if (!MamrObs.isMamr(i)) continue;
      if (!_sameShop(i['mamrDept']?.toString() ?? i['dept']?.toString() ?? '', dept)) {
        continue;
      }
      _addTo(t, i);
    }
    return t;
  }

  void _report(MamrArea? a) {
    if (a != null) MamrService.pendingArea.value = '$_plant|${a.id}';
    widget.onReport();
  }

  Future<void> _call(String mobile) async {
    if (mobile.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$mobile'));
    } catch (_) {}
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (!_loaded) return const SizedBox.shrink();
    final isAdmin = widget.user != null && PlantScope.isAdminUser(widget.user!);
    if (_reg.isEmpty && !_canManage && !isAdmin && _plant.isEmpty) {
      return const SizedBox.shrink();
    }

    final ids = AssignmentInbox.identities(widget.user);
    final mobile = widget.user?['mobile']?.toString() ?? '';
    final mine = _reg.activeAreas
        .where((a) => MamrObs.ownsArea(a, ids, mobile))
        .toList();

    final byArea = <String, MamrTally>{};
    final myReports = MamrTally();
    for (final i in widget.incidents) {
      if (!MamrObs.isMamr(i)) continue;
      final id = i['mamrAreaId']?.toString() ?? '';
      if (id.isNotEmpty) _addTo(byArea[id] ??= MamrTally(), i);
      if (_isMine(i)) _addTo(myReports, i);
    }
    final myShop = (widget.user?['department']?.toString() ?? '').trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: sl.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kMamrTeal.withOpacity(0.6), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: kMamrTeal.withOpacity(sl.isDark ? 0.25 : 0.15),
              blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: MamrAreaBackdrop(
          intensity: 0.8,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(sl, mine, byArea, myShop),
            if (_collapsed)
              const SizedBox.shrink()
            else if (_reg.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  _canManage
                      ? 'No areas yet. Tap Manage to upload the area-wise '
                        'responsibility Excel for $_plant.'
                      : 'MAMR areas are not set up for ${_plant.isEmpty ? 'your plant' : _plant} yet. '
                        'Your plant SED will upload the area list.',
                  style: TextStyle(color: sl.text2, fontSize: 13, height: 1.45)),
              )
            else ...[
              const SizedBox(height: 12),
              // 1 ── My area / my shop
              if (mine.isNotEmpty)
                for (final a in mine)
                  _myAreaPanel(sl, a, byArea[a.id] ?? MamrTally())
              else
                _myShopPanel(sl, myShop),

              // 2 ── My reports
              _myReportsLine(sl, myReports),

              // 3 ── All areas
              _allAreas(sl, byArea),
            ],
          ]),
        ),
      ),
    );
  }

  /// Teal status band. Always visible; tapping it folds the card. When
  /// folded it carries the one-line status so nothing important is hidden.
  Widget _header(SL sl, List<MamrArea> mine, Map<String, MamrTally> byArea,
      String myShop) {
    final t = MamrTally();
    if (mine.isNotEmpty) {
      for (final a in mine) {
        final x = byArea[a.id];
        if (x == null) continue;
        t.recorded += x.recorded;
        t.complied += x.complied;
        t.overdue += x.overdue;
      }
    } else if (myShop.isNotEmpty) {
      final x = _mamrInShop(myShop);
      t.recorded = x.recorded;
      t.complied = x.complied;
      t.overdue = x.overdue;
    }
    final shop = mine.isNotEmpty ? mine.first.dept : myShop;
    final (nmOpen, _) = shop.isEmpty ? (0, 0) : _nearMissIn(shop);
    final where = mine.isNotEmpty
        ? mine.map((a) => a.area).join(' / ')
        : (myShop.isEmpty ? _plant : 'Shop: $myShop');

    Widget chip(String label, int n, Color fill) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: n > 0 ? fill : Colors.white.withOpacity(0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('$n $label',
              style: TextStyle(
                  color: n > 0 && fill == AppColors.amber
                      ? const Color(0xFF3B2600)
                      : Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w800)),
        );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggleCollapsed,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0F766E), Color(0xFF0E7490)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(11)),
                child: const Icon(Icons.place_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('My Area My Responsibility',
                      style: TextStyle(color: Colors.white, fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  Text(where,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withOpacity(0.9),
                          fontSize: 12.5)),
                ]),
              ),
              if (_plants.length > 1)
                PopupMenuButton<String>(
                  tooltip: 'Choose plant',
                  onSelected: _switchPlant,
                  icon: const Icon(Icons.factory_outlined, color: Colors.white),
                  itemBuilder: (_) => [
                    for (final c in _plants)
                      PopupMenuItem(value: c, child: Text(c)),
                  ],
                ),
              if (_canManage)
                IconButton(
                  tooltip: 'Manage MAMR areas',
                  onPressed: () async {
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const MamrAdminScreen()));
                    _load();
                  },
                  icon: const Icon(Icons.tune_rounded, color: Colors.white),
                ),
              Icon(_collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                  color: Colors.white),
              const SizedBox(width: 6),
            ]),
            if (!_reg.isEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                chip('done', t.complied, AppColors.green),
                chip('pending', t.pending, AppColors.amber),
                chip('overdue', t.overdue, AppColors.red),
                if (shop.isNotEmpty)
                  chip('near miss open', nmOpen, AppColors.amber),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _panelShell(SL sl, Widget child) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        decoration: BoxDecoration(
          color: sl.card.withOpacity(0.94),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border),
        ),
        child: child,
      );

  Widget _nearMissLine(SL sl, String dept) {
    final (open, total) = _nearMissIn(dept);
    return Row(children: [
      Icon(Icons.warning_amber_rounded, size: 18,
          color: open > 0 ? sl.amberText : sl.text3),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          total == 0
              ? 'No near misses reported in $dept'
              : open == 0
                  ? 'Near misses in $dept: all $total closed'
                  : 'Near misses in $dept: $open open of $total',
          style: TextStyle(
              color: open > 0 ? sl.text1 : sl.text3,
              fontSize: 13, fontWeight: open > 0 ? FontWeight.w700 : FontWeight.w500)),
      ),
    ]);
  }

  Widget _myAreaPanel(SL sl, MamrArea a, MamrTally t) => _panelShell(
        sl,
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Your area', style: TextStyle(color: sl.text3, fontSize: 12.5,
                fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(children: [
              MamrRing(tally: t, size: 76, stroke: 8),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.area,
                      style: TextStyle(color: sl.text1, fontSize: 16,
                          fontWeight: FontWeight.w800, height: 1.2)),
                  Text(a.dept, style: TextStyle(color: sl.text3, fontSize: 12.5)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 18, runSpacing: 8, children: [
                    MamrFigure(value: '${t.complied}', label: 'Done',
                        ink: t.complied > 0 ? sl.greenText : null),
                    MamrFigure(value: '${t.pending}', label: 'Pending',
                        ink: t.pending > 0 ? sl.amberText : null),
                    MamrFigure(value: '${t.overdue}', label: 'Overdue',
                        ink: t.overdue > 0 ? sl.redText : null),
                  ]),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            _nearMissLine(sl, a.dept),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: kMamrTeal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () => _report(a),
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text('Report in ${a.area}', overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      );

  Widget _myShopPanel(SL sl, String shop) {
    final t = shop.isEmpty ? MamrTally() : _mamrInShop(shop);
    return _panelShell(
      sl,
      Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            shop.isEmpty ? 'Your shop' : 'Your shop: $shop',
            style: TextStyle(color: sl.text1, fontSize: 15,
                fontWeight: FontWeight.w800)),
          Text('You are not the responsible person for any area. '
              'This is what is open in your shop.',
              style: TextStyle(color: sl.text3, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 12),
          if (shop.isNotEmpty) ...[
            Row(children: [
              MamrRing(tally: t, size: 60, stroke: 7),
              const SizedBox(width: 14),
              Expanded(
                child: Wrap(spacing: 18, runSpacing: 8, children: [
                  MamrFigure(value: '${t.complied}', label: 'MAMR done',
                      ink: t.complied > 0 ? sl.greenText : null),
                  MamrFigure(value: '${t.pending}', label: 'MAMR pending',
                      ink: t.pending > 0 ? sl.amberText : null),
                  if (t.overdue > 0)
                    MamrFigure(value: '${t.overdue}', label: 'Overdue', ink: sl.redText),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            _nearMissLine(sl, shop),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: () => _report(null),
            icon: const Icon(Icons.add_a_photo_outlined, size: 18),
            label: const Text('Report an MAMR observation'),
          ),
        ]),
      ),
    );
  }

  Widget _myReportsLine(SL sl, MamrTally t) => _panelShell(
        sl,
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(children: [
            Icon(Icons.person_pin_circle_outlined, color: sl.text2, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Observations you reported',
                    style: TextStyle(color: sl.text1, fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                MamrBar(tally: t, height: 6),
                const SizedBox(height: 4),
                Text(
                  t.recorded == 0
                      ? 'None yet'
                      : '${t.recorded} reported, ${t.complied} complied, ${t.pending} pending',
                  style: TextStyle(color: sl.text3, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );

  Widget _allAreas(SL sl, Map<String, MamrTally> byArea) {
    final q = _search.trim().toUpperCase();
    final areas = _reg.activeAreas.where((a) => q.isEmpty ||
        a.area.toUpperCase().contains(q) ||
        a.dept.toUpperCase().contains(q) ||
        a.persons.any((p) => p.name.toUpperCase().contains(q))).toList()
      ..sort((x, y) {
        final tx = byArea[x.id], ty = byArea[y.id];
        final p = (ty?.pending ?? 0).compareTo(tx?.pending ?? 0);
        if (p != 0) return p;
        final d = x.dept.compareTo(y.dept);
        return d != 0 ? d : x.area.compareTo(y.area);
      });
    final pendingAreas =
        _reg.activeAreas.where((a) => (byArea[a.id]?.pending ?? 0) > 0).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _allOpen = !_allOpen),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('All areas in $_plant',
                    style: TextStyle(color: sl.text1, fontSize: 14,
                        fontWeight: FontWeight.w800)),
                Text(
                  pendingAreas == 0
                      ? '${_reg.activeAreas.length} areas, nothing pending'
                      : '${_reg.activeAreas.length} areas, $pendingAreas with pending observations',
                  style: TextStyle(color: sl.text3, fontSize: 12.5)),
              ]),
            ),
            Icon(_allOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: sl.text2),
          ]),
        ),
      ),
      if (_allOpen) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: sl.card,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              hintText: 'Search area, shop or person',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        _panelShell(
          sl,
          Column(children: [
            for (var k = 0; k < areas.length; k++) ...[
              if (k > 0) Container(height: 1, color: sl.border),
              _areaRow(sl, areas[k], byArea[areas[k].id] ?? MamrTally()),
            ],
            if (areas.isEmpty)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text('No matching area.',
                    style: TextStyle(color: sl.text3, fontSize: 13)),
              ),
          ]),
        ),
        const SizedBox(height: 4),
      ],
    ]);
  }

  Widget _areaRow(SL sl, MamrArea a, MamrTally t) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          MamrRing(tally: t, size: 34, stroke: 4),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.area,
                  style: TextStyle(color: sl.text1, fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
              Text(a.dept, style: TextStyle(color: sl.text3, fontSize: 12)),
              for (final p in a.persons)
                Row(children: [
                  Flexible(
                    child: Text(p.label,
                        style: TextStyle(color: sl.text2, fontSize: 12)),
                  ),
                  if (p.mobile.isNotEmpty)
                    IconButton(
                      tooltip: 'Call ${p.name}',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => _call(p.mobile),
                      icon: Icon(Icons.call_rounded, color: sl.accentText),
                    ),
                ]),
            ]),
          ),
          Text(
            t.recorded == 0
                ? 'None'
                : t.pending == 0 ? 'All done' : '${t.pending} pending',
            style: TextStyle(
                color: t.recorded == 0
                    ? sl.text4
                    : t.pending == 0 ? sl.greenText : sl.amberText,
                fontSize: 12.5, fontWeight: FontWeight.w800)),
        ]),
      );
}
