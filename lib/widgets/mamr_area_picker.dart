// lib/widgets/mamr_area_picker.dart
//
// The MAMR step that comes BEFORE the photo: which area is this, and which
// of the six scope categories. Shows the area's responsible person(s) so the
// reporter can see who the observation will go to.
//
// Stateless on purpose — the MAMR tab owns the selection, so it survives the
// switch between the capture view and the results view.

import 'package:flutter/material.dart';

import '../main.dart' show SL;
import '../services/mamr_service.dart';

const Color _kMamr = Color(0xFF0F766E);

class MamrAreaPicker extends StatelessWidget {
  const MamrAreaPicker({
    super.key,
    required this.plants,
    required this.plant,
    required this.register,
    required this.dept,
    required this.areaId,
    required this.category,
    required this.onPlant,
    required this.onDept,
    required this.onArea,
    required this.onCategory,
    this.loaded = true,
    this.locked = false,
    this.compact = false,
  });

  /// Plant codes the reporter may file against. One entry = no selector.
  final List<String> plants;
  final String plant;
  final MamrRegister register;
  final String? dept;
  final String? areaId;
  final String? category;
  final ValueChanged<String> onPlant;
  final ValueChanged<String?> onDept;
  final ValueChanged<String?> onArea;
  final ValueChanged<String?> onCategory;
  final bool loaded;

  /// After save the selection is part of the record and can't be changed.
  final bool locked;

  /// Results view: a one-line summary that expands when tapped.
  final bool compact;

  MamrArea? get _area => areaId == null ? null : register.byId(areaId!);

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final area = _area;
    final complete = area != null && category != null;

    if (!loaded) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }

    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: _kMamr, borderRadius: BorderRadius.circular(6)),
          child: const Text('MAMR',
              style: TextStyle(color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w900, letterSpacing: 0.6)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('My Area My Responsibility',
              style: TextStyle(color: sl.text1, fontSize: 13,
                  fontWeight: FontWeight.w800)),
        ),
        Icon(complete ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 18, color: complete ? sl.greenText : sl.text4),
      ]),
      const SizedBox(height: 10),
      if (plants.isEmpty || (register.isEmpty && plants.length <= 1))
        _notSetUp(sl)
      else ...[
        if (plants.length > 1) ...[
          _dropdown<String>(
            sl,
            label: 'Plant / Unit',
            value: plants.contains(plant) ? plant : null,
            items: {for (final c in plants) c: c},
            onChanged: locked
                ? null
                : (v) {
                    if (v != null) onPlant(v);
                  },
          ),
          const SizedBox(height: 8),
        ],
        if (register.isEmpty)
          _notSetUp(sl)
        else ...[
          _dropdown<String>(
            sl,
            label: '1 · Deptt./Shop',
            value: register.allDepartments
                    .any((d) => d == dept && register.areasIn(d).isNotEmpty)
                ? dept
                : null,
            items: {
              for (final d in register.allDepartments)
                if (register.areasIn(d).isNotEmpty) d: d,
            },
            onChanged: locked ? null : onDept,
          ),
          const SizedBox(height: 8),
          _dropdown<String>(
            sl,
            label: '2 · Section / Area',
            value: area != null && dept != null &&
                    register.areasIn(dept!).any((a) => a.id == area.id)
                ? area.id
                : null,
            items: {
              if (dept != null)
                for (final a in register.areasIn(dept!)) a.id: a.area,
            },
            onChanged: locked || dept == null ? null : onArea,
          ),
          if (area != null) ...[
            const SizedBox(height: 8),
            _responsible(sl, area),
          ],
          const SizedBox(height: 10),
          Text('3 · Observation category',
              style: TextStyle(color: sl.text3, fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in MamrCategories.all)
              ChoiceChip(
                label: Text(c, style: const TextStyle(fontSize: 12)),
                selected: category == c,
                selectedColor: _kMamr.withOpacity(sl.isDark ? 0.45 : 0.18),
                onSelected: locked ? null : (on) => onCategory(on ? c : null),
              ),
          ]),
        ],
      ],
    ]);

    if (compact && complete) {
      return _shell(
        sl,
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          shape: const Border(),
          leading: const Icon(Icons.place_rounded, color: _kMamr),
          title: Text('${area.dept} · ${area.area}',
              style: TextStyle(color: sl.text1, fontSize: 13,
                  fontWeight: FontWeight.w800)),
          subtitle: Text(
              '$category · ${area.persons.isEmpty ? 'no responsible person' : area.persons.map((p) => p.name).join(' & ')}',
              style: TextStyle(color: sl.text3, fontSize: 12)),
          children: [body],
        ),
      );
    }
    return _shell(sl, Padding(padding: const EdgeInsets.all(12), child: body));
  }

  Widget _shell(SL sl, Widget child) => Container(
        decoration: BoxDecoration(
          color: sl.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kMamr.withOpacity(0.55), width: 1.6),
        ),
        child: child,
      );

  Widget _notSetUp(SL sl) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: sl.amberText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'MAMR areas are not set up for ${plant.isEmpty ? 'your plant' : plant} yet — '
              'contact your plant SED. Observations can be filed once the '
              'area-wise responsibility list is uploaded.',
              style: TextStyle(color: sl.text2, fontSize: 12, height: 1.4)),
          ),
        ]),
      );

  Widget _responsible(SL sl, MamrArea area) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('RESPONSIBLE PERSON',
              style: TextStyle(color: sl.text3, fontSize: 11,
                  fontWeight: FontWeight.w800, letterSpacing: 0.6)),
          const SizedBox(height: 4),
          if (area.persons.isEmpty)
            Text('None assigned — the SED will route it.',
                style: TextStyle(color: sl.amberText, fontSize: 12)),
          for (final p in area.persons)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Icon(Icons.person_rounded, size: 16, color: sl.text2),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${p.label}${p.mobile.isEmpty ? '' : '  ·  ${p.mobilePretty}'}',
                    style: TextStyle(color: sl.text1, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
        ]),
      );

  Widget _dropdown<T>(
    SL sl, {
    required String label,
    required T? value,
    required Map<T, String> items,
    required ValueChanged<T?>? onChanged,
  }) =>
      DropdownButtonFormField<T>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        items: [
          for (final e in items.entries)
            DropdownMenuItem<T>(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      );
}
