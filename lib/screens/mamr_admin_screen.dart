// lib/screens/mamr_admin_screen.dart
//
// MAMR Areas — the plant's area-wise responsibility register.
//
// Who sees this: the super admin (Admin → MAMR Areas, every plant) and a
// plant SED (Home → Manage MAMR, their own plant only). What it does, in the
// order of the hand-written requirement sheet:
//   • Add new department → Department name
//   • Upload Excel: SN | Plant/Unit | Dept/Shop | Section/Area |
//     Responsible person | Designation | Mob. No.
//   • Edit / reassign / deactivate an area; link a person to an app account.
//
// Nothing from an upload is written until the SED has seen the preview and
// chosen Merge or Replace. Replace never deletes — areas missing from the new
// file are deactivated so old observations still resolve their area.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show SL, AppColors;
import '../services/admin_audit.dart';
import '../services/admin_master_data.dart';
import '../services/assign_scope.dart';
import '../services/local_db.dart';
import '../services/mamr_service.dart';
import '../services/tabular_reader.dart';
import '../widgets/bottom_nav_gap.dart';
import '../widgets/content_width.dart';
import '../widgets/user_picker.dart';
import '../services/pdf_export_stub.dart'
    if (dart.library.html) '../services/pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

const Color kMamrColor = Color(0xFF0F766E); // teal-700 — MAMR module colour

/// Full-screen wrapper for an SED opening the register from Home.
class MamrAdminScreen extends StatelessWidget {
  const MamrAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      appBar: AppBar(
        title: const Text('MAMR Areas'),
        backgroundColor: kMamrColor,
        foregroundColor: Colors.white,
      ),
      body: const SafeArea(child: MamrAdminPanel()),
    );
  }
}

class MamrAdminPanel extends StatefulWidget {
  const MamrAdminPanel({super.key, this.actor, this.superAdmin = false});

  /// Name written to the audit log. Defaults to the signed-in username.
  final String? actor;

  /// Opened from the admin console: every plant is manageable.
  final bool superAdmin;

  @override
  State<MamrAdminPanel> createState() => _MamrAdminPanelState();
}

class _MamrAdminPanelState extends State<MamrAdminPanel> {
  List<String> _plants = const [];
  String _plant = '';
  String _plantLabel = '';
  MamrRegister _reg = const MamrRegister(plant: '');
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  String _actor = '';

  // Pending upload
  MamrImportPlan? _plan;
  String _planFile = '';
  bool _replace = false;

  String _search = '';

  @override
  void initState() {
    super.initState();
    MamrService.revision.addListener(_reloadRegister);
    _init();
  }

  @override
  void dispose() {
    MamrService.revision.removeListener(_reloadRegister);
    super.dispose();
  }

  Future<void> _init() async {
    final user = await LocalDB.getCurrentUser();
    _actor = widget.actor ?? (user?['username']?.toString() ?? 'unknown');
    List<String> plants;
    if (widget.superAdmin) {
      final all = await AdminMasterData.getPlants();
      plants = all
          .map((p) => (p['code'] ?? '').toUpperCase())
          .where((c) => c.isNotEmpty && c != 'OTHER')
          .toList();
    } else {
      plants = await MamrService.manageablePlants(user);
    }
    var initial = plants.isEmpty ? '' : plants.first;
    // Super admin: start on a plant that already has a register, if any.
    if (widget.superAdmin) {
      final regs = await MamrService.getAllRegisters();
      final withData = plants.where((c) => regs[c]?.isEmpty == false).toList();
      if (withData.isNotEmpty) initial = withData.first;
      final own = await MamrService.userPlantCode(user);
      if (plants.contains(own)) initial = own;
    }
    if (!mounted) return;
    setState(() => _plants = plants);
    await _selectPlant(initial);
  }

  Future<void> _selectPlant(String code) async {
    if (code.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final reg = await MamrService.getRegister(code);
    final label = await MamrService.plantLabelFor(code);
    if (!mounted) return;
    setState(() {
      _plant = code;
      _plantLabel = label;
      _reg = reg;
      _plan = null;
      _loading = false;
    });
  }

  Future<void> _reloadRegister() async {
    if (_plant.isEmpty || _busy) return;
    final reg = await MamrService.getRegister(_plant);
    if (mounted) setState(() => _reg = reg);
  }

  Future<void> _save(MamrRegister next, String what,
      {Map<String, dynamic>? meta}) async {
    setState(() => _busy = true);
    final stamped = next.copyWith(
        updatedBy: _actor, updatedAt: DateTime.now().toIso8601String());
    final ok = await MamrService.saveRegister(stamped);
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: _actor,
      target: 'mamr_areas_$_plant',
      targetName: what,
      meta: meta,
    );
    if (!mounted) return;
    setState(() {
      _reg = stamped;
      _busy = false;
    });
    _toast(ok ? '✅ $what' : '$what — saved on this device, will sync when online',
        ok ? kMamrColor : AppColors.amber);
  }

  void _toast(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: c,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  UPLOAD
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _pickExcel() async {
    setState(() => _error = '');
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: TabularReader.pickerExtensions,
        withData: true,
      );
    } catch (e) {
      setState(() => _error = 'Could not open the file picker: $e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      setState(() => _error = 'That file could not be read.');
      return;
    }
    setState(() => _busy = true);
    try {
      final sheet = await TabularReader.read(
          fileName: f.name, bytes: Uint8List.fromList(bytes));
      final plants = await AdminMasterData.getPlants();
      final plan = MamrImporter.buildPlan(
        headerKeys:
            sheet.headers.map(TabularSheet.normaliseKey).toList(),
        rows: sheet.rows,
        plantCode: _plant,
        plantCodeOf: MamrService.plantCodeResolver(plants),
        headerRowNumber: sheet.headerRowNumber,
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _planFile = f.name;
        _replace = false;
        _busy = false;
      });
    } on TabularException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message.contains('employee')
            ? 'That file has headings but no area rows below them.'
            : e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'That file could not be read: $e';
      });
    }
  }

  Future<void> _applyPlan() async {
    final plan = _plan;
    if (plan == null || !plan.canApply) return;
    setState(() => _busy = true);
    var next = MamrImporter.apply(_reg, plan,
        replace: _replace, updatedBy: _actor, sourceFile: _planFile);
    var linked = 0;
    try {
      final r = await MamrService.linkByMobile(next);
      next = r.$1;
      linked = r.$2;
    } catch (_) {}
    _plan = null;
    await _save(next,
        'Imported ${plan.rows.length} areas from $_planFile'
        '${linked > 0 ? ' · $linked people linked to app accounts' : ''}',
        meta: {
          'mode': _replace ? 'replace' : 'merge',
          'areas': plan.rows.length,
          'warnings': plan.warnings.length,
        });
  }

  Future<void> _downloadTemplate() async {
    final csv = MamrImporter.templateCsv(_plant.isEmpty ? 'ASP' : _plant);
    final name = 'MAMR_Area_Template_${_plant.isEmpty ? 'PLANT' : _plant}.csv';
    final bytes = Uint8List.fromList(utf8.encode(csv));
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
          subject: 'MAMR area template');
    } catch (e) {
      _toast('Could not share the template: $e', AppColors.red);
    }
  }

  Future<void> _linkByMobile() async {
    setState(() => _busy = true);
    final r = await MamrService.linkByMobile(_reg);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.$2 == 0) {
      _toast('No new matches — those mobiles are not on any app account.',
          AppColors.amber);
      return;
    }
    await _save(r.$1, 'Linked ${r.$2} people to app accounts');
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  DEPARTMENTS / AREAS
  // ═══════════════════════════════════════════════════════════════════════

  Future<String?> _askText(String title, String label,
      {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    final v = cleanCell(res);
    return v.isEmpty ? null : v;
  }

  Future<void> _addDepartment() async {
    final name = await _askText('Add new department', 'Department name');
    if (name == null) return;
    if (_reg.allDepartments
        .any((d) => d.toUpperCase() == name.toUpperCase())) {
      _toast('"$name" already exists', AppColors.amber);
      return;
    }
    await _save(_reg.copyWith(departments: [..._reg.departments, name]),
        'Department "$name" added');
  }

  Future<void> _removeDepartment(String dept) async {
    if (_reg.areasIn(dept).isNotEmpty) {
      _toast('Deactivate the areas under "$dept" first', AppColors.amber);
      return;
    }
    await _save(
        _reg.copyWith(
            departments: _reg.departments
                .where((d) => d.toUpperCase() != dept.toUpperCase())
                .toList()),
        'Department "$dept" removed');
  }

  Future<void> _editArea({MamrArea? area, String? dept}) async {
    final res = await showDialog<MamrArea>(
      context: context,
      builder: (_) => _AreaDialog(
        departments: _reg.allDepartments,
        area: area,
        dept: dept ?? area?.dept,
      ),
    );
    if (res == null) return;
    List<MamrArea> areas;
    if (area == null) {
      final created = res.copyWith(
          id: _reg.nextId(),
          sn: _reg.areas.fold<int>(0, (m, a) => a.sn > m ? a.sn : m) + 1);
      areas = [..._reg.areas, created];
    } else {
      areas = _reg.areas.map((a) => a.id == area.id ? res.copyWith(id: a.id, sn: a.sn) : a).toList();
    }
    var next = _reg.copyWith(areas: areas);
    try {
      next = (await MamrService.linkByMobile(next)).$1;
    } catch (_) {}
    await _save(next, area == null ? 'Area "${res.area}" added' : 'Area "${res.area}" updated');
  }

  Future<void> _toggleActive(MamrArea a) async {
    final areas = _reg.areas
        .map((x) => x.id == a.id ? x.copyWith(active: !x.active) : x)
        .toList();
    await _save(_reg.copyWith(areas: areas),
        a.active ? 'Area "${a.area}" deactivated' : 'Area "${a.area}" re-activated');
  }

  /// Replace the area's responsible person with an app user chosen from the
  /// plant's roster. The user's name/designation/mobile become the person.
  Future<void> _reassign(MamrArea a) async {
    final scope = await AssignScope.forIncident({'plant': _plant});
    if (!mounted) return;
    final res = await showUserPicker(context,
        title: 'Responsible person — ${a.area}',
        currentUsername: a.persons.isEmpty ? null : a.persons.first.username,
        allowClear: false,
        scope: scope);
    final u = res?.user;
    if (u == null) return;
    final p = MamrPerson(
      name: (u['name']?.toString() ?? '').trim().isEmpty
          ? res!.username
          : u['name'].toString().trim(),
      designation: u['designation']?.toString().trim() ?? '',
      mobile: normaliseMobile(u['mobile']?.toString()),
      username: res!.username.trim().toLowerCase(),
    );
    final areas = _reg.areas
        .map((x) => x.id == a.id ? x.copyWith(persons: [p]) : x)
        .toList();
    await _save(_reg.copyWith(areas: areas),
        '${a.area} → ${p.name}',
        meta: {'area': a.id, 'username': p.username});
  }

  /// Link one existing person (keeps name/designation from the sheet).
  Future<void> _linkPerson(MamrArea a, int index) async {
    final scope = await AssignScope.forIncident({'plant': _plant});
    if (!mounted) return;
    final res = await showUserPicker(context,
        title: 'Link ${a.persons[index].name} to an app account',
        allowClear: true,
        scope: scope);
    if (res == null) return;
    final persons = [...a.persons];
    persons[index] = persons[index]
        .copyWith(username: res.cleared ? '' : res.username.toLowerCase());
    final areas = _reg.areas
        .map((x) => x.id == a.id ? x.copyWith(persons: persons) : x)
        .toList();
    await _save(_reg.copyWith(areas: areas),
        res.cleared ? 'Link removed' : '${persons[index].name} linked');
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_plants.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'You are not the SED for any plant. The safety admin can grant '
            'the SED role from Admin → User Management.',
            textAlign: TextAlign.center,
            style: TextStyle(color: sl.text3, fontSize: 13, height: 1.5)),
        ),
      );
    }

    final depts = _reg.allDepartments;
    final q = _search.trim().toUpperCase();
    final allPersons = _reg.activeAreas.expand((a) => a.persons).toList();
    final unlinked = allPersons.where((p) => !p.isLinked).length;
    final inactive = _reg.areas.where((a) => !a.active).toList();

    return Stack(children: [
      ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          children: [
            _header(sl),
            const SizedBox(height: 12),
            if (_plants.length > 1) ...[
              _plantPicker(sl),
              const SizedBox(height: 12),
            ],
            _stats(sl, depts.length, allPersons.length, unlinked),
            const SizedBox(height: 12),
            _uploadCard(sl),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_error, style: TextStyle(color: sl.redText, fontSize: 12)),
            ],
            if (_plan != null) ...[
              const SizedBox(height: 12),
              _previewCard(sl, _plan!),
            ],
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: Text('DEPARTMENTS & AREAS',
                    style: TextStyle(
                        color: sl.text3, fontSize: 11,
                        fontWeight: FontWeight.w800, letterSpacing: 0.6)),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _addDepartment,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add new department'),
              ),
            ]),
            TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                hintText: 'Search area, department or person',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 10),
            if (depts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No areas yet for $_plantLabel. Upload the area-wise '
                  'responsibility Excel, or add a department and its areas by hand.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: sl.text3, fontSize: 12.5, height: 1.5)),
              ),
            for (final d in depts)
              ..._deptBlock(sl, d, q),
            if (inactive.isNotEmpty) ...[
              const SizedBox(height: 14),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Inactive areas (${inactive.length})',
                    style: TextStyle(color: sl.text3, fontSize: 12,
                        fontWeight: FontWeight.w700)),
                children: [
                  for (final a in inactive)
                    ListTile(
                      dense: true,
                      title: Text('${a.dept} · ${a.area}',
                          style: TextStyle(color: sl.text3)),
                      trailing: TextButton(
                          onPressed: _busy ? null : () => _toggleActive(a),
                          child: const Text('Re-activate')),
                    ),
                ],
              ),
            ],
            const BottomNavGap(),
          ],
        ),
      ),
      if (_busy)
        const Positioned(
            left: 0, right: 0, top: 0,
            child: LinearProgressIndicator(minHeight: 3)),
    ]);
  }

  Widget _header(SL sl) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kMamrColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          const Icon(Icons.map_rounded, color: Colors.white, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('MAMR — My Area My Responsibility',
                  style: TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                _plantLabel.isEmpty ? 'Area-wise responsibility register'
                    : 'Area register · $_plantLabel',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
              if (_reg.updatedAt.isNotEmpty)
                Text(
                  'Last updated ${_reg.updatedAt.substring(0, _reg.updatedAt.length >= 10 ? 10 : _reg.updatedAt.length)}'
                  '${_reg.updatedBy.isEmpty ? '' : ' by ${_reg.updatedBy}'}',
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ]),
          ),
        ]),
      );

  Widget _plantPicker(SL sl) => DropdownButtonFormField<String>(
        value: _plants.contains(_plant) ? _plant : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'Plant / Unit',
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        items: [
          for (final c in _plants)
            DropdownMenuItem(value: c, child: Text(c)),
        ],
        onChanged: _busy ? null : (c) => c == null ? null : _selectPlant(c),
      );

  Widget _stats(SL sl, int depts, int persons, int unlinked) {
    Widget tile(String n, String l, {Color? ink}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: sl.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sl.border),
            ),
            child: Column(children: [
              Text(n, style: TextStyle(color: ink ?? sl.text1, fontSize: 18,
                  fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(l, textAlign: TextAlign.center,
                  style: TextStyle(color: sl.text3, fontSize: 11)),
            ]),
          ),
        );
    return Column(children: [
      Row(children: [
        tile('${_reg.activeAreas.length}', 'Areas'),
        const SizedBox(width: 8),
        tile('$depts', 'Departments'),
        const SizedBox(width: 8),
        tile('$persons', 'Responsible'),
        const SizedBox(width: 8),
        tile('$unlinked', 'Not on app',
            ink: unlinked > 0 ? sl.amberText : sl.greenText),
      ]),
      if (unlinked > 0) ...[
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _busy ? null : _linkByMobile,
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('Link by mobile number'),
          ),
        ),
      ],
    ]);
  }

  Widget _uploadCard(SL sl) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Upload area-wise responsibility Excel',
              style: TextStyle(color: sl.text1, fontSize: 13.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Columns: SN · Plant/Unit · Deptt./Shop · Section/Area · '
            'Responsible person · Designation · Mobile no.\n'
            'Two people in one cell (one per line) are both made responsible. '
            'People are linked to app accounts by mobile number.',
            style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.45)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kMamrColor),
              onPressed: _busy ? null : _pickExcel,
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('Upload Excel'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _downloadTemplate,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download template'),
            ),
          ]),
        ]),
      );

  Widget _previewCard(SL sl, MamrImportPlan plan) {
    final warn = plan.warnings;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: plan.canApply ? kMamrColor : AppColors.red, width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Preview — $_planFile',
            style: TextStyle(color: sl.text1, fontSize: 13.5,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        if (plan.errors.isNotEmpty)
          for (final e in plan.errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('✖ $e', style: TextStyle(color: sl.redText, fontSize: 12)),
            ),
        if (plan.canApply) ...[
          Text(
            '${plan.rows.length} areas · ${plan.departments.length} departments · '
            '${plan.personCount} responsible persons'
            '${plan.ignoredBlank > 0 ? ' · ${plan.ignoredBlank} empty rows ignored' : ''}'
            '${plan.rejectedOtherPlant > 0 ? ' · ${plan.rejectedOtherPlant} rows for another plant skipped' : ''}',
            style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4)),
          const SizedBox(height: 6),
          Text('Departments: ${plan.departments.join(', ')}',
              style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.4)),
        ],
        if (warn.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('${warn.length} warning(s)',
              style: TextStyle(color: sl.amberText, fontSize: 12,
                  fontWeight: FontWeight.w700)),
          for (final w in warn.take(15))
            Text('• $w', style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.4)),
          if (warn.length > 15)
            Text('… and ${warn.length - 15} more',
                style: TextStyle(color: sl.text4, fontSize: 11)),
        ],
        if (plan.canApply) ...[
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Merge'),
                  icon: Icon(Icons.merge_rounded, size: 16)),
              ButtonSegment(value: true, label: Text('Replace'),
                  icon: Icon(Icons.swap_horiz_rounded, size: 16)),
            ],
            selected: {_replace},
            onSelectionChanged: (s) => setState(() => _replace = s.first),
          ),
          const SizedBox(height: 4),
          Text(
            _replace
                ? 'Areas not in this file will be marked inactive (kept for history).'
                : 'Matching areas are updated, new ones added, others left as they are.',
            style: TextStyle(color: sl.text4, fontSize: 11)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          TextButton(
              onPressed: _busy ? null : () => setState(() => _plan = null),
              child: const Text('Cancel')),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kMamrColor),
            onPressed: _busy || !plan.canApply ? null : _applyPlan,
            child: Text('Save ${plan.rows.length} areas'),
          ),
        ]),
      ]),
    );
  }

  List<Widget> _deptBlock(SL sl, String dept, String q) {
    var areas = _reg.areasIn(dept);
    if (q.isNotEmpty) {
      final deptHit = dept.toUpperCase().contains(q);
      areas = areas.where((a) => deptHit ||
          a.area.toUpperCase().contains(q) ||
          a.persons.any((p) => p.name.toUpperCase().contains(q))).toList();
      if (areas.isEmpty && !deptHit) return const [];
    }
    return [
      Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Expanded(
            child: Text('$dept  ·  ${areas.length} area${areas.length == 1 ? '' : 's'}',
                style: TextStyle(color: sl.text1, fontSize: 12.5,
                    fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Add area under $dept',
            onPressed: _busy ? null : () => _editArea(dept: dept),
            icon: const Icon(Icons.add_location_alt_outlined, size: 20),
          ),
          if (areas.isEmpty)
            IconButton(
              tooltip: 'Remove department',
              onPressed: _busy ? null : () => _removeDepartment(dept),
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
        ]),
      ),
      for (final a in areas) _areaTile(sl, a),
    ];
  }

  Widget _areaTile(SL sl, MamrArea a) => Container(
        margin: const EdgeInsets.only(top: 6, left: 6),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sl.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${a.sn}. ${a.area}',
                  style: TextStyle(color: sl.text1, fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              if (a.persons.isEmpty)
                Text('No responsible person', style: TextStyle(color: sl.amberText, fontSize: 11.5)),
              for (var i = 0; i < a.persons.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    Icon(a.persons[i].isLinked
                            ? Icons.verified_user_rounded
                            : Icons.person_off_outlined,
                        size: 14,
                        color: a.persons[i].isLinked ? sl.greenText : sl.amberText),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${a.persons[i].label}'
                        '${a.persons[i].mobile.isEmpty ? '' : ' · ${a.persons[i].mobilePretty}'}'
                        '${a.persons[i].isLinked ? '' : ' · not on app'}',
                        style: TextStyle(color: sl.text3, fontSize: 11.5)),
                    ),
                    InkWell(
                      onTap: _busy ? null : () => _linkPerson(a, i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text(a.persons[i].isLinked ? 'Relink' : 'Link',
                            style: TextStyle(color: sl.accentText, fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) {
              if (v == 'edit') _editArea(area: a);
              if (v == 'reassign') _reassign(a);
              if (v == 'deactivate') _toggleActive(a);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit area')),
              PopupMenuItem(value: 'reassign', child: Text('Reassign to app user')),
              PopupMenuItem(value: 'deactivate', child: Text('Deactivate')),
            ],
          ),
        ]),
      );
}

/// Add / edit one area: department, name and up to two responsible persons.
class _AreaDialog extends StatefulWidget {
  const _AreaDialog({required this.departments, this.area, this.dept});
  final List<String> departments;
  final MamrArea? area;
  final String? dept;

  @override
  State<_AreaDialog> createState() => _AreaDialogState();
}

class _AreaDialogState extends State<_AreaDialog> {
  late String? _dept;
  late final TextEditingController _area;
  final _names = <TextEditingController>[];
  final _desigs = <TextEditingController>[];
  final _mobiles = <TextEditingController>[];
  final _usernames = <String>[];
  String _err = '';

  @override
  void initState() {
    super.initState();
    _dept = widget.dept ?? (widget.departments.isEmpty ? null : widget.departments.first);
    _area = TextEditingController(text: widget.area?.area ?? '');
    final persons = widget.area?.persons ?? const <MamrPerson>[];
    for (var i = 0; i < 2; i++) {
      final p = i < persons.length ? persons[i] : null;
      _names.add(TextEditingController(text: p?.name ?? ''));
      _desigs.add(TextEditingController(text: p?.designation ?? ''));
      _mobiles.add(TextEditingController(text: p?.mobile ?? ''));
      _usernames.add(p?.username ?? '');
    }
  }

  @override
  void dispose() {
    _area.dispose();
    for (final c in [..._names, ..._desigs, ..._mobiles]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final area = cleanCell(_area.text);
    if (_dept == null || area.isEmpty) {
      setState(() => _err = 'Department and Section/Area are required.');
      return;
    }
    final persons = <MamrPerson>[];
    for (var i = 0; i < 2; i++) {
      final n = cleanCell(_names[i].text);
      if (n.isEmpty) continue;
      final rawMob = _mobiles[i].text.trim();
      final mob = normaliseMobile(rawMob);
      if (rawMob.isNotEmpty && mob.isEmpty) {
        setState(() => _err = 'Mobile for $n must have 10 digits.');
        return;
      }
      final old = widget.area != null && i < widget.area!.persons.length
          ? widget.area!.persons[i]
          : null;
      persons.add(MamrPerson(
        name: n,
        designation: cleanCell(_desigs[i].text),
        mobile: mob,
        // Keep a manual link only while the mobile is unchanged.
        username: old != null && old.mobile == mob ? _usernames[i] : '',
      ));
    }
    Navigator.pop(
        context,
        MamrArea(
          id: widget.area?.id ?? '',
          sn: widget.area?.sn ?? 0,
          dept: _dept!,
          area: area,
          persons: persons,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    Widget person(int i) => Column(children: [
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(i == 0 ? 'Responsible person' : 'Second responsible person (optional)',
                style: TextStyle(color: sl.text3, fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ),
          TextField(controller: _names[i],
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Name', isDense: true)),
          TextField(controller: _desigs[i],
              decoration: const InputDecoration(labelText: 'Designation', isDense: true)),
          TextField(controller: _mobiles[i],
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Mobile no.', isDense: true)),
        ]);
    return AlertDialog(
      title: Text(widget.area == null ? 'Add area' : 'Edit area'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: widget.departments.contains(_dept) ? _dept : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Deptt./Shop', isDense: true),
              items: [
                for (final d in widget.departments)
                  DropdownMenuItem(value: d, child: Text(d)),
              ],
              onChanged: (v) => setState(() => _dept = v),
            ),
            TextField(controller: _area,
                decoration: const InputDecoration(labelText: 'Section / Area', isDense: true)),
            person(0),
            person(1),
            if (_err.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_err, style: TextStyle(color: sl.redText, fontSize: 12)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kMamrColor),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
