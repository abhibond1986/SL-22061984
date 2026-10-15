// lib/widgets/mamr_area_picker.dart
//
// The MAMR step that comes BEFORE the photo: which area is this? Shows the
// reporter's OWN area(s) first as one-tap choices (and preselects one), then
// the full Deptt./Shop → Section/Area pickers for any other area, and the
// responsible person the observation will go to.
//
// The observation-category step was removed on 2026-10-15 at the user's
// request — the AI hazard list already says what kind of finding it is.
//
// Stateless on purpose — the MAMR tab owns the selection, so it survives the
// switch between the capture view and the results view.

import 'package:flutter/material.dart';

import '../main.dart' show SL;
import '../services/mamr_service.dart';
import 'mamr_visuals.dart';

class MamrAreaPicker extends StatelessWidget {
  const MamrAreaPicker({
    super.key,
    required this.plants,
    required this.plant,
    required this.register,
    required this.dept,
    required this.areaId,
    required this.onPlant,
    required this.onDept,
    required this.onArea,
    this.myAreaIds = const [],
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
  final ValueChanged<String> onPlant;
  final ValueChanged<String?> onDept;
  final ValueChanged<String?> onArea;

  /// Areas of [register] where the signed-in user is the responsible person.
  final List<String> myAreaIds;
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
    final complete = area != null;

    if (!loaded) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }

    final mine = [
      for (final id in myAreaIds)
        if (register.byId(id) case final a? when a.active) a,
    ];

    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _header(sl, complete),
      const SizedBox(height: 14),
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
          const SizedBox(height: 10),
        ],
        if (register.isEmpty)
          _notSetUp(sl)
        else ...[
          if (mine.isNotEmpty) ...[
            Text(mine.length == 1 ? 'Your area' : 'Your areas',
                style: TextStyle(color: sl.text2, fontSize: 13,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final a in mine) _myAreaTile(sl, a, a.id == areaId),
            const SizedBox(height: 10),
            Text('Reporting somewhere else? Choose the area',
                style: TextStyle(color: sl.text3, fontSize: 12.5)),
            const SizedBox(height: 6),
          ],
          _dropdown<String>(
            sl,
            label: 'Deptt./Shop',
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
          const SizedBox(height: 10),
          _dropdown<String>(
            sl,
            label: 'Section / Area',
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
            const SizedBox(height: 10),
            _responsible(sl, area, mine.any((m) => m.id == area.id)),
          ],
        ],
      ],
    ]);

    if (compact && complete) {
      return _shell(
        sl,
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          shape: const Border(),
          leading: const Icon(Icons.place_rounded, color: kMamrTeal),
          title: Text(area.area,
              style: TextStyle(color: sl.text1, fontSize: 14,
                  fontWeight: FontWeight.w800)),
          subtitle: Text(
              area.persons.isEmpty
                  ? '${area.dept}. No responsible person'
                  : '${area.dept}. Goes to ${area.persons.map((p) => p.name).join(' & ')}',
              style: TextStyle(color: sl.text3, fontSize: 12)),
          children: [body],
        ),
      );
    }
    return _shell(sl, Padding(padding: const EdgeInsets.all(16), child: body));
  }

  Widget _header(SL sl, bool complete) => Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
              color: kMamrTeal, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.place_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('My Area My Responsibility',
                style: TextStyle(color: sl.text1, fontSize: 16,
                    fontWeight: FontWeight.w800)),
            Text(
              complete
                  ? 'Area chosen. Now take the photo below.'
                  : 'Where did you see it? Choose the area first.',
              style: TextStyle(color: sl.text3, fontSize: 12.5)),
          ]),
        ),
        Icon(complete ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 22, color: complete ? sl.greenText : sl.text4),
      ]);

  /// Card surface with the plant-layout motif painted behind the content.
  Widget _shell(SL sl, Widget child) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: sl.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kMamrTeal.withOpacity(0.6), width: 1.6),
        ),
        child: MamrAreaBackdrop(child: child),
      );

  Widget _myAreaTile(SL sl, MamrArea a, bool selected) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: selected
              ? kMamrTeal.withOpacity(sl.isDark ? 0.40 : 0.12)
              : sl.card2,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: locked
                ? null
                : () {
                    onDept(a.dept);
                    onArea(a.id);
                  },
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? kMamrTeal : sl.border,
                    width: selected ? 1.8 : 1),
              ),
              child: Row(children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: selected ? sl.greenText : sl.text3, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.area,
                        style: TextStyle(color: sl.text1, fontSize: 14,
                            fontWeight: FontWeight.w800)),
                    Text(a.dept,
                        style: TextStyle(color: sl.text3, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );

  Widget _notSetUp(SL sl) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 20, color: sl.amberText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'MAMR areas are not set up for ${plant.isEmpty ? 'your plant' : plant} yet. '
              'Ask your plant SED to upload the area-wise responsibility list.',
              style: TextStyle(color: sl.text2, fontSize: 12.5, height: 1.4)),
          ),
        ]),
      );

  Widget _responsible(SL sl, MamrArea area, bool isMine) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isMine ? 'You are responsible for this area' : 'This observation will go to',
              style: TextStyle(color: sl.text3, fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (area.persons.isEmpty)
            Text('No one yet. The plant SED will route it.',
                style: TextStyle(color: sl.amberText, fontSize: 13)),
          for (final p in area.persons)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: kMamrTeal,
                  child: Text(p.name.isEmpty ? '?' : p.name[0],
                      style: const TextStyle(color: Colors.white, fontSize: 12,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(p.label,
                      style: TextStyle(color: sl.text1, fontSize: 13,
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
          filled: true,
          fillColor: sl.surface.withOpacity(0.85),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
