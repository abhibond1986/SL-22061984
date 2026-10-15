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
// Collapsed to one line once an area is chosen (the reporter's own area is
// preselected); "Change area" opens the pickers. The MAMR tab still owns the
// selection itself, so it survives the switch between capture and results —
// this widget only remembers whether it is open.

import 'package:flutter/material.dart';

import '../main.dart' show SL;
import '../services/mamr_service.dart';
import 'mamr_visuals.dart';

class MamrAreaPicker extends StatefulWidget {
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

  /// Kept for call-site compatibility; the card is always collapsible now.
  final bool compact;

  @override
  State<MamrAreaPicker> createState() => _MamrAreaPickerState();
}

/// Collapsed by default: ONE line saying which area this is and who it goes
/// to, with a Change button. The department / area pickers only appear when
/// the user wants to report for another area (2026-10-15: "the box is too
/// big with unnecessary information").
class _MamrAreaPickerState extends State<MamrAreaPicker> {
  bool? _expandedOverride;

  MamrArea? get _area =>
      widget.areaId == null ? null : widget.register.byId(widget.areaId!);

  /// Open while nothing is chosen; closed once an area is set, unless the
  /// user asked to change it.
  bool get _expanded =>
      !widget.locked && (_area == null || (_expandedOverride ?? false));

  void _choose(MamrArea a) {
    widget.onDept(a.dept);
    widget.onArea(a.id);
    setState(() => _expandedOverride = false);
  }

  @override
  void didUpdateWidget(MamrAreaPicker old) {
    super.didUpdateWidget(old);
    if (widget.locked) _expandedOverride = false;
  }

  // Shorthands so the helpers below read as before.
  List<String> get plants => widget.plants;
  String get plant => widget.plant;
  MamrRegister get register => widget.register;
  String? get dept => widget.dept;
  String? get areaId => widget.areaId;
  bool get locked => widget.locked;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final area = _area;

    if (!widget.loaded) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }

    final mine = [
      for (final id in widget.myAreaIds)
        if (register.byId(id) case final a? when a.active) a,
    ];
    final notSetUp = plants.isEmpty || register.isEmpty;

    // ── Collapsed: one line ──
    if (!_expanded && area != null) {
      final isMine = mine.any((m) => m.id == area.id);
      final to = area.persons.isEmpty
          ? 'No responsible person yet'
          : isMine
              ? 'You are responsible for this area'
              : 'Goes to ${area.persons.map((p) => p.name).join(' & ')}';
      return _shell(
        sl,
        InkWell(
          onTap: locked ? null : () => setState(() => _expandedOverride = true),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    color: kMamrTeal, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.place_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(area.area,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: sl.text1, fontSize: 14.5,
                          fontWeight: FontWeight.w800)),
                  Text('${area.dept}  ·  $to',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: sl.text3, fontSize: 12)),
                ]),
              ),
              if (locked)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.lock_outline_rounded, size: 18, color: sl.text4),
                )
              else
                FilledButton.icon(
                  onPressed: () => setState(() => _expandedOverride = true),
                  style: FilledButton.styleFrom(
                    backgroundColor: kMamrTeal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.edit_location_alt_rounded, size: 18),
                  label: const Text('Change area',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 6),
            ]),
          ),
        ),
      );
    }

    // ── Expanded: choose an area ──
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
            area == null ? 'Where did you see it?' : 'Report for another area',
            style: TextStyle(color: sl.text1, fontSize: 15,
                fontWeight: FontWeight.w800)),
        ),
        if (area != null)
          TextButton(
            onPressed: () => setState(() => _expandedOverride = false),
            child: const Text('Done'),
          ),
      ]),
      const SizedBox(height: 10),
      if (notSetUp && plants.length <= 1)
        _notSetUp(sl)
      else ...[
        if (plants.length > 1) ...[
          _dropdown<String>(
            sl,
            label: 'Plant / Unit',
            value: plants.contains(plant) ? plant : null,
            items: {for (final c in plants) c: c},
            onChanged: (v) {
              if (v != null) widget.onPlant(v);
            },
          ),
          const SizedBox(height: 10),
        ],
        if (register.isEmpty)
          _notSetUp(sl)
        else ...[
          // Own areas as one-tap choices, but only the ones not already chosen.
          for (final a in mine)
            if (a.id != areaId) _myAreaTile(sl, a, false),
          if (mine.any((a) => a.id != areaId)) const SizedBox(height: 4),
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
            onChanged: widget.onDept,
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
            onChanged: dept == null
                ? null
                : (id) {
                    final a = id == null ? null : register.byId(id);
                    if (a != null) _choose(a);
                  },
          ),
        ],
      ],
    ]);
    return _shell(sl, Padding(padding: const EdgeInsets.all(14), child: body));
  }

  /// Plain card surface (the plant-layout background was removed 2026-10-15).
  Widget _shell(SL sl, Widget child) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: sl.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kMamrTeal.withOpacity(0.6), width: 1.6),
        ),
        child: child,
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
            onTap: locked ? null : () => _choose(a),
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
                    Text('Your area  ·  ${a.dept}',
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
