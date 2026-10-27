// lib/services/mamr_core.dart
//
// MAMR — "My Area My Responsibility". Pure-Dart core: models, the Excel
// cleaner and the merge rule. NO Flutter / SharedPreferences imports, on
// purpose, so `dart run tools/mamr_core_test.dart` can exercise it on the
// plain VM against the real ASP area-responsibility sheet. Storage, sync and
// user lookup live in mamr_service.dart.
//
// The register is the plant's area-wise responsibility list:
//   SN | Plant/Unit | Deptt./Shop | Section/Area | Responsible person |
//   Designation | Mobile no.
// Every observation filed from the MAMR tab names one area, and that area's
// responsible person(s) own it until it is Complied.

import 'dart:convert';

/// The scope line at the top of the SAIL area-responsibility sheet. These are
/// the MAMR observation categories the reporter picks from.
class MamrCategories {
  const MamrCategories._();
  static const String lineOfFire = 'Line of Fire identification';
  static const String housekeeping = 'Housekeeping';
  static const String signage = 'Safety Signage & Display';
  static const String painting = 'Painting & Identification Marking';
  static const String remediation = 'Safety Incident remediation';
  static const String other = 'Any other safety improvement point';
  static const List<String> all = [
    lineOfFire, housekeeping, signage, painting, remediation, other,
  ];
}

/// Reserved incident `type`. MAMR observations are currently written with
/// type 'AI_SCAN' (the MAMR tab is the photo-scan path and the analytics,
/// PDF and AI audit all key on that value) and are recognised by
/// `mamrAreaId` instead. [MamrObs.isMamr] accepts either form.
const String kMamrType = 'MAMR';

/// Last 10 digits of a phone number, or '' when there are fewer than 10.
///
/// One rule for every side of the match: the bulk user import stores
/// `918986875493` (country code, no plus), self-registration stores whatever
/// was typed (`+91 94347 98958`, `094347…`), and the area sheet holds
/// `9434798958` — sometimes with a leading TAB (`"\t9434798917"`, ASP row 12),
/// sometimes as an Excel number that came through as `9.434798958E9`.
String normaliseMobile(String? raw) {
  var s = (raw ?? '').trim();
  if (s.isEmpty) return '';
  // Excel numeric in scientific notation.
  if (RegExp(r'^\d+(\.\d+)?[eE]\+?\d+$').hasMatch(s)) {
    final d = double.tryParse(s);
    if (d != null) s = d.toStringAsFixed(0);
  }
  // "9434798958.0" from a float cell.
  s = s.replaceFirst(RegExp(r'\.0+$'), '');
  final digits = s.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 10) return '';
  return digits.substring(digits.length - 10);
}

/// Collapse tabs / runs of whitespace and trim. ASP rows 12 and 32 carry a
/// leading TAB; row 31's plant is "ASP " with a trailing space.
String cleanCell(String? raw) =>
    (raw ?? '').replaceAll(RegExp(r'[\t ]+'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();

/// Split a multi-person cell on line breaks. ASP rows 10 and 15 hold two
/// people in one cell ("JAYDEEP DUTTA\nRAVI ANAND"), with their designations
/// and mobiles stacked the same way in the neighbouring cells.
List<String> splitLines(String? raw) => (raw ?? '')
    .split(RegExp(r'\r\n|\r|\n|;|/(?=\s*\d{10})'))
    .map(cleanCell)
    .where((s) => s.isNotEmpty)
    .toList();

String _key(String s) =>
    cleanCell(s).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), ' ').trim();

class MamrPerson {
  final String name;
  final String designation;
  final String mobile; // last 10 digits, or ''
  /// Linked app account, when one was found by mobile or picked by the SED.
  final String username;

  const MamrPerson({
    required this.name,
    this.designation = '',
    this.mobile = '',
    this.username = '',
  });

  bool get isLinked => username.isNotEmpty;

  MamrPerson copyWith({String? username, String? designation, String? name, String? mobile}) =>
      MamrPerson(
        name: name ?? this.name,
        designation: designation ?? this.designation,
        mobile: mobile ?? this.mobile,
        username: username ?? this.username,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'designation': designation,
        'mobile': mobile,
        'username': username,
      };

  factory MamrPerson.fromJson(Map m) => MamrPerson(
        name: m['name']?.toString() ?? '',
        designation: m['designation']?.toString() ?? '',
        mobile: normaliseMobile(m['mobile']?.toString()),
        username: (m['username']?.toString() ?? '').trim().toLowerCase(),
      );

  /// "NAME, Designation" — the single line used on cards and in the PDF.
  String get label =>
      designation.isEmpty ? name : '$name, $designation';

  /// Mobile grouped for reading aloud: "94347 98958".
  String get mobilePretty => mobile.length == 10
      ? '${mobile.substring(0, 5)} ${mobile.substring(5)}'
      : mobile;
}

class MamrArea {
  /// Stable for the life of the area. Re-uploads match on dept + area name
  /// and keep the id, so past observations keep resolving.
  final String id;
  final int sn;
  final String dept;
  final String area;
  final List<MamrPerson> persons;
  final bool active;

  const MamrArea({
    required this.id,
    required this.sn,
    required this.dept,
    required this.area,
    required this.persons,
    this.active = true,
  });

  String get matchKey => '${_key(dept)}|${_key(area)}';

  MamrArea copyWith({
    String? id,
    int? sn,
    String? dept,
    String? area,
    List<MamrPerson>? persons,
    bool? active,
  }) =>
      MamrArea(
        id: id ?? this.id,
        sn: sn ?? this.sn,
        dept: dept ?? this.dept,
        area: area ?? this.area,
        persons: persons ?? this.persons,
        active: active ?? this.active,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sn': sn,
        'dept': dept,
        'area': area,
        'persons': persons.map((p) => p.toJson()).toList(),
        'active': active,
      };

  factory MamrArea.fromJson(Map m) => MamrArea(
        id: m['id']?.toString() ?? '',
        sn: int.tryParse(m['sn']?.toString() ?? '') ?? 0,
        dept: m['dept']?.toString() ?? '',
        area: m['area']?.toString() ?? '',
        persons: ((m['persons'] as List?) ?? const [])
            .whereType<Map>()
            .map(MamrPerson.fromJson)
            .toList(),
        active: m['active'] != false && m['active']?.toString() != 'false',
      );

  /// Snapshot written onto an observation. A later reassignment must not
  /// rewrite who was responsible when the observation was filed.
  List<Map<String, dynamic>> responsibleSnapshot() =>
      persons.map((p) => p.toJson()).toList();
}

class MamrRegister {
  /// Plant CODE ("ASP"), never a label — see project memory "one plant, one
  /// label". Display strings are derived from the plant master.
  final String plant;
  /// Departments in display order. Includes departments the SED added by
  /// hand before any area existed under them.
  final List<String> departments;
  final List<MamrArea> areas;
  final String updatedBy;
  final String updatedAt;
  final String sourceFile;

  const MamrRegister({
    required this.plant,
    this.departments = const [],
    this.areas = const [],
    this.updatedBy = '',
    this.updatedAt = '',
    this.sourceFile = '',
  });

  bool get isEmpty => areas.where((a) => a.active).isEmpty;

  List<MamrArea> get activeAreas => areas.where((a) => a.active).toList();

  /// Departments that have at least one active area, plus hand-added ones,
  /// in register order.
  List<String> get allDepartments {
    final out = <String>[];
    final seen = <String>{};
    void add(String d) {
      final k = _key(d);
      if (k.isEmpty || seen.contains(k)) return;
      seen.add(k);
      out.add(d);
    }
    departments.forEach(add);
    for (final a in activeAreas) {
      add(a.dept);
    }
    return out;
  }

  List<MamrArea> areasIn(String dept) =>
      activeAreas.where((a) => _key(a.dept) == _key(dept)).toList();

  MamrArea? byId(String id) {
    for (final a in areas) {
      if (a.id == id) return a;
    }
    return null;
  }

  MamrRegister copyWith({
    List<String>? departments,
    List<MamrArea>? areas,
    String? updatedBy,
    String? updatedAt,
    String? sourceFile,
  }) =>
      MamrRegister(
        plant: plant,
        departments: departments ?? this.departments,
        areas: areas ?? this.areas,
        updatedBy: updatedBy ?? this.updatedBy,
        updatedAt: updatedAt ?? this.updatedAt,
        sourceFile: sourceFile ?? this.sourceFile,
      );

  Map<String, dynamic> toJson() => {
        'plant': plant,
        'departments': departments,
        'areas': areas.map((a) => a.toJson()).toList(),
        'updatedBy': updatedBy,
        'updatedAt': updatedAt,
        'sourceFile': sourceFile,
      };

  factory MamrRegister.fromJson(Map m) => MamrRegister(
        plant: (m['plant']?.toString() ?? '').trim().toUpperCase(),
        departments: ((m['departments'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        areas: ((m['areas'] as List?) ?? const [])
            .whereType<Map>()
            .map(MamrArea.fromJson)
            .where((a) => a.id.isNotEmpty)
            .toList(),
        updatedBy: m['updatedBy']?.toString() ?? '',
        updatedAt: m['updatedAt']?.toString() ?? '',
        sourceFile: m['sourceFile']?.toString() ?? '',
      );

  static MamrRegister? tryDecode(dynamic raw) {
    try {
      final v = raw is String ? jsonDecode(raw) : raw;
      if (v is Map) return MamrRegister.fromJson(v);
    } catch (_) {}
    return null;
  }

  /// Next free area id for this plant: "ASP-033".
  String nextId() {
    var max = 0;
    for (final a in areas) {
      final m = RegExp(r'(\d+)$').firstMatch(a.id);
      final n = m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
      if (n > max) max = n;
    }
    return '$plant-${(max + 1).toString().padLeft(3, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  EXCEL → REGISTER
// ═══════════════════════════════════════════════════════════════════════════

class MamrImportRow {
  final int rowNumber; // spreadsheet row, for messages
  final int sn;
  final String dept;
  final String area;
  final List<MamrPerson> persons;
  const MamrImportRow({
    required this.rowNumber,
    required this.sn,
    required this.dept,
    required this.area,
    required this.persons,
  });
}

class MamrImportPlan {
  final String plant;
  final List<MamrImportRow> rows;
  final List<String> warnings;
  final List<String> errors; // blocking
  final int ignoredBlank;
  final int rejectedOtherPlant;
  final Map<String, String> mapping; // field → column key

  const MamrImportPlan({
    required this.plant,
    required this.rows,
    required this.warnings,
    required this.errors,
    required this.ignoredBlank,
    required this.rejectedOtherPlant,
    required this.mapping,
  });

  bool get canApply => errors.isEmpty && rows.isNotEmpty;

  List<String> get departments {
    final out = <String>[];
    final seen = <String>{};
    for (final r in rows) {
      if (seen.add(_key(r.dept))) out.add(r.dept);
    }
    return out;
  }

  int get personCount => rows.fold(0, (n, r) => n + r.persons.length);
}

class MamrImporter {
  const MamrImporter._();

  /// Column aliases, matched against TabularSheet.normaliseKey(header).
  /// The ASP sheet's own headings are listed first.
  static const Map<String, List<String>> fieldAliases = {
    'sn': ['SN', 'S_N', 'SL_NO', 'S_NO', 'SR_NO', 'SNO', 'SERIAL_NO'],
    'plant': ['PLANT_UNIT', 'PLANT', 'UNIT', 'PLANT_UNIT_NAME'],
    'dept': ['DEPTT_SHOP', 'DEPT_SHOP', 'DEPARTMENT_SHOP', 'DEPTT', 'DEPT',
        'DEPARTMENT', 'SHOP'],
    'area': ['SECTION_AREA', 'SECTION', 'AREA', 'SECTION_AREA_NAME',
        'LOCATION'],
    'person': ['RESPONSIBLE_PERSON', 'RESPONSIBLE', 'NAME', 'PERSON',
        'RESPONSIBLE_PERSON_NAME', 'AREA_OWNER'],
    'designation': ['DESIGNATION', 'DESIG', 'POST'],
    'mobile': ['MOBILE_NO', 'MOBILE', 'MOBILE_NUMBER', 'PHONE', 'CONTACT_NO',
        'CONTACT'],
  };

  static const List<String> requiredFields = ['dept', 'area', 'person'];

  static const List<String> templateHeaders = [
    'SN', 'Plant/Unit', 'Deptt./Shop', 'Section/ Area',
    'Responsible person', 'Designation', 'Mobile no.',
  ];

  /// Build an import plan from rows already keyed by normalised header (the
  /// shape TabularReader produces).
  ///
  /// [plantCode] is the plant being imported into. [plantCodeOf] resolves a
  /// Plant/Unit cell to a plant code ('' when unknown) — injected so this file
  /// stays free of the Flutter-importing plant master.
  /// [headerRowNumber] is the 1-based spreadsheet row of the headings.
  static MamrImportPlan buildPlan({
    required List<String> headerKeys,
    required List<Map<String, String>> rows,
    required String plantCode,
    required String Function(String raw) plantCodeOf,
    int headerRowNumber = 1,
  }) {
    final warnings = <String>[];
    final errors = <String>[];
    final available = <String>{...headerKeys};
    if (rows.isNotEmpty) available.addAll(rows.first.keys);

    final mapping = <String, String>{};
    final used = <String>{};
    fieldAliases.forEach((field, aliases) {
      for (final a in aliases) {
        if (available.contains(a) && !used.contains(a)) {
          mapping[field] = a;
          used.add(a);
          return;
        }
      }
    });
    for (final f in requiredFields) {
      if (!mapping.containsKey(f)) {
        errors.add('Column for "${_fieldLabel(f)}" not found. Expected a '
            'heading like "${fieldAliases[f]!.first.replaceAll('_', ' ')}".');
      }
    }
    if (!mapping.containsKey('mobile')) {
      warnings.add('No Mobile column — responsible persons cannot be linked '
          'to app accounts automatically. You can link them by hand later.');
    }
    final code = plantCode.trim().toUpperCase();
    if (errors.isNotEmpty) {
      return MamrImportPlan(
          plant: code, rows: const [], warnings: warnings, errors: errors,
          ignoredBlank: 0, rejectedOtherPlant: 0, mapping: mapping);
    }

    String cell(Map<String, String> r, String f) =>
        mapping[f] == null ? '' : (r[mapping[f]!] ?? '');

    final out = <MamrImportRow>[];
    final seenKeys = <String, int>{};
    var blank = 0, otherPlant = 0;

    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final rowNo = headerRowNumber + 1 + i;
      final dept = cleanCell(cell(r, 'dept'));
      final area = cleanCell(cell(r, 'area'));
      final names = splitLines(cell(r, 'person'));

      // ASP rows 33–57: an SN and nothing else. Not an error, not a warning.
      if (dept.isEmpty && area.isEmpty && names.isEmpty) {
        blank++;
        continue;
      }

      final plantCell = cleanCell(cell(r, 'plant'));
      if (plantCell.isNotEmpty) {
        final pc = plantCodeOf(plantCell).toUpperCase();
        if (pc.isEmpty) {
          warnings.add('Row $rowNo: plant "$plantCell" is not in the plant '
              'master — imported into $code.');
        } else if (pc != code) {
          otherPlant++;
          warnings.add('Row $rowNo: belongs to $pc, not $code — skipped.');
          continue;
        }
      }

      if (dept.isEmpty || area.isEmpty) {
        warnings.add('Row $rowNo: ${dept.isEmpty ? 'Dept./Shop' : 'Section/Area'} '
            'is empty — skipped.');
        continue;
      }
      if (names.isEmpty) {
        warnings.add('Row $rowNo ($area): no responsible person — imported; '
            'assign one before observations can reach anyone.');
      }

      final desigs = splitLines(cell(r, 'designation'));
      final mobilesRaw = splitLines(cell(r, 'mobile'));
      final mobiles = mobilesRaw.map(normaliseMobile).toList();
      if (names.length > 1 &&
          ((desigs.isNotEmpty && desigs.length != names.length) ||
              (mobiles.isNotEmpty && mobiles.length != names.length))) {
        warnings.add('Row $rowNo ($area): ${names.length} people but '
            '${desigs.length} designation(s) / ${mobiles.length} mobile(s) — '
            'check the pairing.');
      }
      final persons = <MamrPerson>[];
      for (var p = 0; p < names.length; p++) {
        final mob = p < mobiles.length ? mobiles[p] : '';
        if (p < mobilesRaw.length && mobilesRaw[p].isNotEmpty && mob.isEmpty) {
          warnings.add('Row $rowNo: mobile "${mobilesRaw[p]}" for '
              '${names[p]} is not a 10-digit number.');
        }
        persons.add(MamrPerson(
          name: names[p],
          designation: p < desigs.length
              ? desigs[p]
              : (desigs.length == 1 ? desigs.first : ''),
          mobile: mob,
        ));
      }

      final k = '${_key(dept)}|${_key(area)}';
      if (seenKeys.containsKey(k)) {
        warnings.add('Row $rowNo repeats "$dept / $area" from row '
            '${seenKeys[k]} — the later row wins.');
        out.removeWhere((x) => '${_key(x.dept)}|${_key(x.area)}' == k);
      }
      seenKeys[k] = rowNo;

      out.add(MamrImportRow(
        rowNumber: rowNo,
        sn: int.tryParse(cleanCell(cell(r, 'sn'))) ?? (out.length + 1),
        dept: dept,
        area: area,
        persons: persons,
      ));
    }

    if (out.isEmpty && errors.isEmpty) {
      errors.add('No area rows were found below the headings.');
    }

    return MamrImportPlan(
      plant: code,
      rows: out,
      warnings: warnings,
      errors: errors,
      ignoredBlank: blank,
      rejectedOtherPlant: otherPlant,
      mapping: mapping,
    );
  }

  /// Apply [plan] to [current].
  ///
  /// [replace] false = MERGE: matching areas are updated, new ones added,
  /// areas absent from the file are left as they were.
  /// [replace] true = REPLACE: areas absent from the file are marked INACTIVE
  /// (never deleted — past observations still resolve their area).
  ///
  /// An existing person's linked username is kept when the same mobile (or,
  /// with no mobile, the same name) appears again, so a re-upload does not
  /// undo the SED's manual links.
  static MamrRegister apply(
    MamrRegister current,
    MamrImportPlan plan, {
    required bool replace,
    String updatedBy = '',
    String sourceFile = '',
    DateTime? now,
  }) {
    final byKey = <String, MamrArea>{
      for (final a in current.areas) a.matchKey: a,
    };
    var reg = current;
    final result = <MamrArea>[];
    final touched = <String>{};

    for (final row in plan.rows) {
      final k = '${_key(row.dept)}|${_key(row.area)}';
      final old = byKey[k];
      final persons = row.persons.map((p) {
        final prev = old?.persons.firstWhere(
          (o) => p.mobile.isNotEmpty
              ? o.mobile == p.mobile
              : _key(o.name) == _key(p.name),
          orElse: () => const MamrPerson(name: ''),
        );
        return (prev != null && prev.username.isNotEmpty)
            ? p.copyWith(username: prev.username)
            : p;
      }).toList();
      if (old != null) {
        result.add(old.copyWith(
            sn: row.sn, dept: row.dept, area: row.area,
            persons: persons, active: true));
      } else {
        final id = reg.copyWith(areas: [...reg.areas, ...result]).nextId();
        result.add(MamrArea(
            id: id, sn: row.sn, dept: row.dept, area: row.area,
            persons: persons));
      }
      touched.add(k);
    }
    for (final a in current.areas) {
      if (touched.contains(a.matchKey)) continue;
      result.add(replace ? a.copyWith(active: false) : a);
    }
    result.sort((a, b) {
      if (a.active != b.active) return a.active ? -1 : 1;
      return a.sn.compareTo(b.sn);
    });

    final depts = <String>[...current.departments];
    for (final d in plan.departments) {
      if (!depts.any((x) => _key(x) == _key(d))) depts.add(d);
    }
    reg = current.copyWith(
      areas: result,
      departments: depts,
      updatedBy: updatedBy,
      updatedAt: (now ?? DateTime.now()).toIso8601String(),
      sourceFile: sourceFile,
    );
    return reg;
  }

  static String _fieldLabel(String f) => const {
        'sn': 'SN',
        'plant': 'Plant/Unit',
        'dept': 'Deptt./Shop',
        'area': 'Section/Area',
        'person': 'Responsible person',
        'designation': 'Designation',
        'mobile': 'Mobile no.',
      }[f] ?? f;

  /// CSV template with the exact headings the importer recognises.
  static String templateCsv(String plantCode) =>
      '${templateHeaders.join(',')}\n'
      '1,$plantCode,SMS,"Pit Side, LF #1",FULL NAME,DGM (SMS),9XXXXXXXXX\n';
}

// ═══════════════════════════════════════════════════════════════════════════
//  OBSERVATION HELPERS (pure)
// ═══════════════════════════════════════════════════════════════════════════

class MamrObs {
  const MamrObs._();

  static bool isMamr(Map<String, dynamic> inc) =>
      (inc['type']?.toString().toUpperCase() ?? '') == kMamrType ||
      (inc['mamrAreaId']?.toString() ?? '').isNotEmpty;

  /// Report heading: "MAMR: <area name>" (decided 2026-10-15). Falls back to
  /// the stored title for anything that is not an MAMR row.
  static String heading(Map<String, dynamic> inc) {
    final area = (inc['mamrArea']?.toString() ?? '').trim();
    if (isMamr(inc) && area.isNotEmpty) return 'MAMR: $area';
    return inc['title']?.toString() ?? '';
  }

  /// The headline hazard of an MAMR row ("Corroded control mounting
  /// bracket"), kept as a sub-line now that the heading names the area.
  static String finding(Map<String, dynamic> inc) {
    final f = (inc['mamrFinding']?.toString() ?? '').trim();
    if (f.isNotEmpty) return f;
    final t = (inc['title']?.toString() ?? '').trim();
    final area = (inc['mamrArea']?.toString() ?? '').trim();
    final stripped = t.replaceFirst(RegExp(r'^(MAMR|AI Hazard Scan):\s*'), '');
    return stripped == area ? '' : stripped;
  }

  /// True when [user] filed this observation (P.no first, then name).
  static bool isReporter(Map<String, dynamic>? user, Map<String, dynamic> inc) {
    if (user == null) return false;
    final pno = (user['pno']?.toString() ?? '').trim().toLowerCase();
    final rp = (inc['reportedByPno']?.toString() ?? '').trim().toLowerCase();
    if (pno.isNotEmpty && rp.isNotEmpty) return pno == rp;
    final name = (user['name']?.toString() ?? '').trim().toLowerCase();
    final rb = (inc['reportedBy']?.toString() ?? '').trim().toLowerCase();
    return name.isNotEmpty && rb == name;
  }

  /// The responsible-person snapshot stored on an observation. Tolerates the
  /// JSON-string form a round trip through SharedPreferences or Sheets leaves.
  static List<MamrPerson> responsible(Map<String, dynamic> inc) {
    var v = inc['mamrResponsible'];
    if (v is String && v.trim().isNotEmpty) {
      try { v = jsonDecode(v); } catch (_) { return const []; }
    }
    if (v is! List) return const [];
    return v.whereType<Map>().map(MamrPerson.fromJson).toList();
  }

  /// True when [identities] (lower-cased username / pno) or [mobile] names one
  /// of the observation's responsible persons.
  static bool isResponsible(
      Map<String, dynamic> inc, Set<String> identities, String mobile) {
    final m = normaliseMobile(mobile);
    for (final p in responsible(inc)) {
      if (p.username.isNotEmpty && identities.contains(p.username)) return true;
      if (m.isNotEmpty && p.mobile == m) return true;
    }
    return false;
  }

  /// Same test against a register area (for the Home "My Area" card).
  static bool ownsArea(MamrArea a, Set<String> identities, String mobile) {
    final m = normaliseMobile(mobile);
    for (final p in a.persons) {
      if (p.username.isNotEmpty && identities.contains(p.username)) return true;
      if (m.isNotEmpty && p.mobile == m) return true;
    }
    return false;
  }
}

/// Automatic compliance deadline for an MAMR observation (decided
/// 2026-10-15: "yes, automatic"). Days from filing, by the worst severity.
/// Written as `targetDate` ('yyyy-MM-dd') — the field the incident screen,
/// My Assignments and the overdue sort already use — so the responsible
/// person or SED can still move it by hand.
class MamrDeadlines {
  const MamrDeadlines._();
  static const Map<String, int> days = {
    'CRITICAL': 1,
    'HIGH': 2,
    'MEDIUM': 7,
    'MODERATE': 7,
    'LOW': 15,
  };
  /// Severity not on the list (renamed by the admin, or UNKNOWN): 7 days.
  static const int fallbackDays = 7;

  static int daysFor(String? severity) =>
      days[(severity ?? '').trim().toUpperCase()] ?? fallbackDays;

  static String targetFor(DateTime filed, String? severity) {
    final d = DateTime(filed.year, filed.month, filed.day)
        .add(Duration(days: daysFor(severity)));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// Pending AND past its target date.
  static bool isOverdue(Map<String, dynamic> inc, {required bool complied, DateTime? now}) {
    if (complied) return false;
    final t = DateTime.tryParse(inc['targetDate']?.toString() ?? '');
    if (t == null) return false;
    final n = now ?? DateTime.now();
    return DateTime(n.year, n.month, n.day).isAfter(t);
  }
}

/// ★ 2026-10-27: "You are the MAMR of this area". One area of one plant's
/// register that names the reader as a responsible person.
///
/// DERIVED, NOT STORED — same reasoning as AssignmentInbox: the register is
/// the truth, so a declaration appears the moment the upload syncs to the
/// person's device and disappears by itself when the area is reassigned or
/// deactivated. Only the "already read" set is persisted (by the bell).
class MamrDeclaration {
  /// Plant CODE ("ASP").
  final String plant;
  final MamrArea area;

  const MamrDeclaration(this.plant, this.area);

  /// Stable notification key. Includes the plant because area ids are only
  /// unique within a plant's register.
  String get key => 'mamrDeclared:$plant:${area.id}';

  /// Every active area, in every register, that names this person — matched
  /// on username/P.no OR on mobile (last 10 digits), the same test the Home
  /// card uses, so a person who is "not on app" by link but whose account
  /// carries the same mobile still gets told.
  static List<MamrDeclaration> forUser(
    Iterable<MamrRegister> registers,
    Set<String> identities,
    String mobile,
  ) {
    final out = <MamrDeclaration>[];
    for (final r in registers) {
      if (r.plant.isEmpty) continue;
      for (final a in r.activeAreas) {
        if (MamrObs.ownsArea(a, identities, mobile)) {
          out.add(MamrDeclaration(r.plant, a));
        }
      }
    }
    out.sort((x, y) {
      final p = x.plant.compareTo(y.plant);
      return p != 0 ? p : x.area.sn.compareTo(y.area.sn);
    });
    return out;
  }

  /// People who are responsible for an area in [after] but were NOT
  /// responsible for that same area (by id) in [before] — i.e. the people a
  /// save has just declared. Used to send the phone push once per new
  /// declaration rather than to everyone on every re-upload.
  ///
  /// A person is "the same" when the username matches or, failing a link on
  /// either side, the mobile matches.
  static List<(MamrArea, MamrPerson)> newlyDeclared(
      MamrRegister before, MamrRegister after) {
    bool same(MamrPerson a, MamrPerson b) {
      if (a.username.isNotEmpty && b.username.isNotEmpty) {
        return a.username == b.username;
      }
      return a.mobile.isNotEmpty && a.mobile == b.mobile;
    }

    final out = <(MamrArea, MamrPerson)>[];
    for (final a in after.activeAreas) {
      final old = before.byId(a.id);
      final oldPersons =
          (old == null || !old.active) ? const <MamrPerson>[] : old.persons;
      for (final p in a.persons) {
        if (!oldPersons.any((o) => same(o, p))) out.add((a, p));
      }
    }
    return out;
  }
}

/// Recorded / complied / pending counts for one bucket.
class MamrTally {
  int recorded = 0;
  int complied = 0;
  /// Pending observations past their automatic target date.
  int overdue = 0;
  int get pending => recorded - complied;
  /// Age in days of the oldest still-pending observation, or null.
  int? oldestPendingDays;

  double get compliedPct => recorded == 0 ? 0 : complied * 100 / recorded;

  void add({required bool isComplied, DateTime? date, DateTime? now,
      bool isOverdue = false}) {
    recorded++;
    if (isOverdue && !isComplied) overdue++;
    if (isComplied) {
      complied++;
    } else if (date != null) {
      final d = (now ?? DateTime.now()).difference(date).inDays;
      if (oldestPendingDays == null || d > oldestPendingDays!) {
        oldestPendingDays = d;
      }
    }
  }
}
