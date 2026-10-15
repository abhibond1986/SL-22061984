// lib/widgets/mamr_home_card.dart
//
// Home → "My MAMR Area" (requirement ① of the MAMR sheet).
//
// Top: every area where the signed-in user is a responsible person, with its
// Pending / Complied counts and a Report button that opens the MAMR tab with
// that area already chosen. Below: the plant's full area-responsibility list,
// collapsible and searchable. An SED (or the admin) also gets Manage MAMR.
//
// "Mine" is matched by linked username OR by mobile number, so a responsible
// person sees their area even before the SED has linked their account.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show SL;
import '../screens/mamr_admin_screen.dart';
import '../services/admin_master_data.dart';
import '../services/assignment_inbox.dart';
import '../services/mamr_service.dart';
import '../services/plant_scope.dart';

const Color _kMamr = Color(0xFF0F766E);

class MamrHomeCard extends StatefulWidget {
  const MamrHomeCard({
    super.key,
    required this.user,
    required this.incidents,
    required this.onReport,
  });

  final Map<String, dynamic>? user;

  /// Already plant-scoped by the Home tab.
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
  String _search = '';

  @override
  void initState() {
    super.initState();
    MamrService.revision.addListener(_load);
    AdminMasterData.revision.addListener(_load);
    _load();
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
        _lastStatus = last.toUpperCase();
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

  Map<String, MamrTally> _tallies() {
    final out = <String, MamrTally>{};
    for (final i in widget.incidents) {
      final id = i['mamrAreaId']?.toString() ?? '';
      if (id.isEmpty) continue;
      final st = (i['status']?.toString() ?? '').trim().toUpperCase();
      final ok = st.isNotEmpty && st == _lastStatus;
      (out[id] ??= MamrTally()).add(
          isComplied: ok,
          date: DateTime.tryParse(i['date']?.toString() ?? ''),
          isOverdue: MamrDeadlines.isOverdue(i, complied: ok));
    }
    return out;
  }

  void _report(MamrArea a) {
    MamrService.pendingArea.value = '$_plant|${a.id}';
    widget.onReport();
  }

  Future<void> _call(String mobile) async {
    if (mobile.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$mobile'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (!_loaded) return const SizedBox.shrink();
    final isAdmin = widget.user != null && PlantScope.isAdminUser(widget.user!);
    // Nothing to show and nothing this user could do about it.
    if (_reg.isEmpty && !_canManage && !isAdmin && _plant.isEmpty) {
      return const SizedBox.shrink();
    }

    final ids = AssignmentInbox.identities(widget.user);
    final mobile = widget.user?['mobile']?.toString() ?? '';
    final mine = _reg.activeAreas
        .where((a) => MamrObs.ownsArea(a, ids, mobile))
        .toList();
    final tallies = _tallies();
    var rec = 0, comp = 0;
    for (final t in tallies.values) {
      rec += t.recorded;
      comp += t.complied;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: sl.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kMamr.withOpacity(0.55), width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Header ──
          Container(
            color: _kMamr,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(children: [
              const Icon(Icons.place_rounded, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('My MAMR Area',
                      style: TextStyle(color: Colors.white, fontSize: 14.5,
                          fontWeight: FontWeight.w800)),
                  Text(
                    'My Area My Responsibility'
                    '${_plant.isEmpty ? '' : ' · $_plant'}'
                    '${rec == 0 ? '' : ' · $rec recorded, ${rec - comp} pending'}',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                ]),
              ),
              if (_plants.length > 1)
                PopupMenuButton<String>(
                  tooltip: 'Plant',
                  icon: const Icon(Icons.factory_outlined, color: Colors.white),
                  onSelected: _switchPlant,
                  itemBuilder: (_) => [
                    for (final c in _plants)
                      PopupMenuItem(value: c, child: Text(c)),
                  ],
                ),
              if (_canManage)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () async {
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const MamrAdminScreen()));
                    _load();
                  },
                  icon: const Icon(Icons.settings_rounded, size: 16),
                  label: const Text('Manage', style: TextStyle(fontSize: 12)),
                ),
            ]),
          ),

          if (_reg.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _canManage
                    ? 'No areas yet. Tap Manage to upload the area-wise '
                      'responsibility Excel for $_plant.'
                    : 'MAMR areas are not set up for ${_plant.isEmpty ? 'your plant' : _plant} yet. '
                      'Your plant SED will upload the area list.',
                style: TextStyle(color: sl.text2, fontSize: 12.5, height: 1.45)),
            )
          else ...[
            // ── My area(s) ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text('MY AREA',
                  style: TextStyle(color: sl.text3, fontSize: 11,
                      fontWeight: FontWeight.w800, letterSpacing: 0.6)),
            ),
            if (mine.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Text('No area is assigned to you.',
                    style: TextStyle(color: sl.text3, fontSize: 12.5)),
              ),
            for (final a in mine) _mineTile(sl, a, tallies[a.id]),

            // ── All areas ──
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                title: Text(
                  'All areas — $_plant (${_reg.activeAreas.length})',
                  style: TextStyle(color: sl.text1, fontSize: 13,
                      fontWeight: FontWeight.w700)),
                children: [
                  TextField(
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      hintText: 'Search area or person',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                  const SizedBox(height: 6),
                  ..._allAreas(sl, tallies),
                ],
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _countChip(SL sl, String label, int n, Color ink) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text('$label $n',
            style: TextStyle(color: ink, fontSize: 11.5,
                fontWeight: FontWeight.w800)),
      );

  Widget _mineTile(SL sl, MamrArea a, MamrTally? t) => Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.area,
                  style: TextStyle(color: sl.text1, fontSize: 13,
                      fontWeight: FontWeight.w800)),
              Text(a.dept, style: TextStyle(color: sl.text3, fontSize: 11.5)),
              const SizedBox(height: 6),
              Row(children: [
                _countChip(sl, 'Pending', t?.pending ?? 0,
                    (t?.pending ?? 0) > 0 ? sl.amberText : sl.text3),
                _countChip(sl, 'Complied', t?.complied ?? 0, sl.greenText),
                if ((t?.overdue ?? 0) > 0)
                  _countChip(sl, 'Overdue', t!.overdue, sl.redText),
              ]),
            ]),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: _kMamr,
                padding: const EdgeInsets.symmetric(horizontal: 12)),
            onPressed: () => _report(a),
            icon: const Icon(Icons.add_a_photo_outlined, size: 16),
            label: const Text('Report', style: TextStyle(fontSize: 12)),
          ),
        ]),
      );

  List<Widget> _allAreas(SL sl, Map<String, MamrTally> tallies) {
    final q = _search.trim().toUpperCase();
    final out = <Widget>[];
    for (final d in _reg.allDepartments) {
      var areas = _reg.areasIn(d);
      if (q.isNotEmpty) {
        final hit = d.toUpperCase().contains(q);
        areas = areas.where((a) => hit ||
            a.area.toUpperCase().contains(q) ||
            a.persons.any((p) => p.name.toUpperCase().contains(q))).toList();
      }
      if (areas.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(d,
            style: TextStyle(color: sl.text2, fontSize: 12,
                fontWeight: FontWeight.w800)),
      ));
      for (final a in areas) {
        final pending = tallies[a.id]?.pending ?? 0;
        out.add(Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          decoration: BoxDecoration(
            color: sl.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.area,
                    style: TextStyle(color: sl.text1, fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
                for (final p in a.persons)
                  Row(children: [
                    Expanded(
                      child: Text(p.label,
                          style: TextStyle(color: sl.text3, fontSize: 11.5)),
                    ),
                    if (p.mobile.isNotEmpty)
                      InkWell(
                        onTap: () => _call(p.mobile),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Text(p.mobilePretty,
                              style: TextStyle(color: sl.accentText, fontSize: 11.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
              ]),
            ),
            if (pending > 0)
              _countChip(sl, 'Pending', pending, sl.amberText),
          ]),
        ));
      }
    }
    if (out.isEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.all(10),
        child: Text('No matching area.', style: TextStyle(color: sl.text3, fontSize: 12)),
      ));
    }
    return out;
  }
}
