// Plain-VM tests for lib/services/mamr_core.dart (MAMR area register).
//
// Run with:  dart run tools/mamr_core_test.dart
//
// The fixture below is the REAL "ASP AREA responsibility (2).xlsx" sheet, keyed
// exactly the way TabularReader keys rows (normalised header → trimmed cell),
// so every quirk the importer must survive is exercised: the merged title row
// (already skipped by the reader), "ASP " with a trailing space, two people in
// one cell, TAB-prefixed mobile and name, SN-only blank rows and two different
// people both called AMIT KUMAR.

import 'dart:convert';
import '../lib/services/mamr_core.dart';

int _pass = 0, _fail = 0;
void ok(bool c, String what) {
  if (c) { _pass++; } else { _fail++; print('FAIL: $what'); }
}

const _aspJson = r'''[{"SN": "1", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "SMS", "SECTION_AREA": "Pit Side, LF #1, VAD, MS Bay", "RESPONSIBLE_PERSON": "CHAKRADHAR SAHOO", "DESIGNATION": "DGM (SMS & CCS)", "MOBILE_NO": "9434798958"}, {"SN": "2", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "SMS", "SECTION_AREA": "Furnace Floor, SMS 2", "RESPONSIBLE_PERSON": "TARAK NATH BISWAS", "DESIGNATION": "DGM (SMS & CCS)", "MOBILE_NO": "9434798762"}, {"SN": "3", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MRD", "SECTION_AREA": "Scrap Yards", "RESPONSIBLE_PERSON": "TANMAY BASU", "DESIGNATION": "AGM (SMS-PLANNING & MRD)", "MOBILE_NO": "9434798751"}, {"SN": "4", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "CCS", "SECTION_AREA": "CCS, VOD,  AOD, LF #2", "RESPONSIBLE_PERSON": "RATAN SAHA", "DESIGNATION": "SR MGR (SMS & CCS)", "MOBILE_NO": "9434798901"}, {"SN": "5", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MED - SMS", "SECTION_AREA": "MED - SMS", "RESPONSIBLE_PERSON": "SANJEEV KUMAR", "DESIGNATION": "AGM (FM-SMS & CCS (MED))", "MOBILE_NO": "9434798948"}, {"SN": "6", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "EED - SMS", "SECTION_AREA": "EED - SMS", "RESPONSIBLE_PERSON": "P VIJAYASARADHI", "DESIGNATION": "AGM (FM-SMS & CCS (EED))", "MOBILE_NO": "9434798916"}, {"SN": "7", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "FORGE SHOP", "SECTION_AREA": "FORGE SHOP", "RESPONSIBLE_PERSON": "SAGAR BANERJEE", "DESIGNATION": "AM (FORGE SHOP)", "MOBILE_NO": "9434799005"}, {"SN": "8", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "BBM", "SECTION_AREA": "SOAKING PIT AREA", "RESPONSIBLE_PERSON": "SANJEEV KUMAR MISHRA", "DESIGNATION": "DGM (BBM & FORGE SHOP)", "MOBILE_NO": "9434798662"}, {"SN": "9", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "BBM", "SECTION_AREA": "MILLS AREA", "RESPONSIBLE_PERSON": "AMIT KUMAR", "DESIGNATION": "AGM (BBM)", "MOBILE_NO": "9434798680"}, {"SN": "10", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MILLS(EED)", "SECTION_AREA": "PRIMARY - MILLS(EED)", "RESPONSIBLE_PERSON": "JAYDEEP DUTTA\nRAVI ANAND", "DESIGNATION": "DGM (FM-MILLS (EED))\nAM (FM-MILLS(EED))", "MOBILE_NO": "9434798912\n9434799019"}, {"SN": "11", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MILLS(MED)", "SECTION_AREA": "PRIMARY - MILLS(MED)", "RESPONSIBLE_PERSON": "Arup Mondal", "DESIGNATION": "SR MGR (FM-MILLS (MED))", "MOBILE_NO": "9434798969"}, {"SN": "12", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "CONDITIONING", "SECTION_AREA": "CONDITIONING - I", "RESPONSIBLE_PERSON": "UTTAM KUMAR", "DESIGNATION": "AGM (CONDITIONING & HTF)", "MOBILE_NO": "9434798917"}, {"SN": "13", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "CONDITIONING", "SECTION_AREA": "CONDITIONING - II", "RESPONSIBLE_PERSON": "PRAKASH CHANDRA DEWANGAN", "DESIGNATION": "AGM (CONDITIONING & HTF)", "MOBILE_NO": "9434798674"}, {"SN": "14", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "HTF", "SECTION_AREA": "HTF", "RESPONSIBLE_PERSON": "AKHILESH P BARA", "DESIGNATION": "AGM (CONDITIONING & HTF)", "MOBILE_NO": "9434798722"}, {"SN": "15", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MILLS(EED)", "SECTION_AREA": "SECONDARY - MILLS(EED)", "RESPONSIBLE_PERSON": "UPENDRA KUMAR PARIDA\nASHIK MUNSHI", "DESIGNATION": "AGM (FM-MILLS (EED))\nAGM (FM-MILLS(EED))", "MOBILE_NO": "9434798671\n9434798964"}, {"SN": "16", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MILLS(MED)", "SECTION_AREA": "SECONDARY - MILLS(MED)", "RESPONSIBLE_PERSON": "RAJIB LOCHAN PATRO", "DESIGNATION": "DGM (FM-MILLS (MED))", "MOBILE_NO": "9434798721"}, {"SN": "17", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MED-POWER & FUEL", "SECTION_AREA": "BOILER HOUSE, COMPRESSOR HOUSE", "RESPONSIBLE_PERSON": "SURESH PRASAD", "DESIGNATION": "DGM (MED-POWER & FUEL)", "MOBILE_NO": "9434798777"}, {"SN": "18", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MED-POWER & FUEL", "SECTION_AREA": "LPG & OTHER TANK Farms", "RESPONSIBLE_PERSON": "SAMIR MONDAL", "DESIGNATION": "DM (MED-POWER & FUEL)", "MOBILE_NO": "9434798647"}, {"SN": "19", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "RDRS & PM", "SECTION_AREA": "RDRS & PM", "RESPONSIBLE_PERSON": "DIPANKAR MAJI", "DESIGNATION": "SR MGR (RDRS & PM)", "MOBILE_NO": "9434798628"}, {"SN": "20", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "EED-CRANE, ERS & AC", "SECTION_AREA": "ERS", "RESPONSIBLE_PERSON": "TUHIN CHAKRABORTY", "DESIGNATION": "AM (EED-ERS & AC)", "MOBILE_NO": "9434707605"}, {"SN": "21", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "EED-CRANE, ERS & AC", "SECTION_AREA": "EED- CRANE MAINTENANCE", "RESPONSIBLE_PERSON": "RAJEEV KUMAR", "DESIGNATION": "AGM (CRANE MAINTENANCE)", "MOBILE_NO": "9434798949"}, {"SN": "22", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "EED-CRANE, ERS & AC", "SECTION_AREA": "MED- CRANE MAINTENANCE", "RESPONSIBLE_PERSON": "SHESHANK", "DESIGNATION": "MGR (CRANE MAINTENANCE)", "MOBILE_NO": "9434798630"}, {"SN": "23", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MED-Shops & HM", "SECTION_AREA": "MRS", "RESPONSIBLE_PERSON": "YOGESH BHATT", "DESIGNATION": "GM (BP, MRS & CDO)", "MOBILE_NO": "9434798725"}, {"SN": "24", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MED-POWER & FUEL", "SECTION_AREA": "RWTP, PUMP HOUSE", "RESPONSIBLE_PERSON": "ALOK CHANDRA", "DESIGNATION": "GM (MED-POWER & FUEL)", "MOBILE_NO": "9434791689"}, {"SN": "25", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MM-S&I", "SECTION_AREA": "NABINA & FERRO ALLOY STORE", "RESPONSIBLE_PERSON": "SADHAN SINHA", "DESIGNATION": "DM (MM-S&I)", "MOBILE_NO": "9434798834"}, {"SN": "26", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "MM-S&I", "SECTION_AREA": "OTHER STORES", "RESPONSIBLE_PERSON": "RAJESHWAR SHARMA", "DESIGNATION": "AM (MM-S&I)", "MOBILE_NO": "9434799003"}, {"SN": "27", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "RCL", "SECTION_AREA": "RCL", "RESPONSIBLE_PERSON": "KRISHNENDU KARMAKAR", "DESIGNATION": "AM (RCL)", "MOBILE_NO": "9434799021"}, {"SN": "28", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "ALRS & TRAFFIC", "SECTION_AREA": "ALRS & TRAFFIC", "RESPONSIBLE_PERSON": "SATYAJIT KUMAR", "DESIGNATION": "AM (Traffic & ALRS)", "MOBILE_NO": "9434799020"}, {"SN": "29", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "PPCD & SHIPPING", "SECTION_AREA": "SHIPPING", "RESPONSIBLE_PERSON": "RAJESH RANJAN KHAKHA", "DESIGNATION": "DGM (PPCD & SHIPPING)", "MOBILE_NO": "9434798810"}, {"SN": "30", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "EED-PD", "SECTION_AREA": "PD", "RESPONSIBLE_PERSON": "AMIT KUMAR", "DESIGNATION": "SR MGR (EED-PD)", "MOBILE_NO": "9434798904"}, {"SN": "31", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "RED", "SECTION_AREA": "RED", "RESPONSIBLE_PERSON": "ABHIJIT BHATTACHARYYA", "DESIGNATION": "GM (RED-MILLS & PLANNING)", "MOBILE_NO": "9434798699"}, {"SN": "32", "PLANT_UNIT": "ASP", "DEPTT_SHOP": "PCM & PROJECTS", "SECTION_AREA": "PCM", "RESPONSIBLE_PERSON": "SUMAN KUMAR JHA", "DESIGNATION": "AGM (PCM & PROJECTS)", "MOBILE_NO": "9434798921"}, {"SN": "33", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "34", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "35", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "36", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "37", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "38", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "39", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "40", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "41", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "42", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "43", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "44", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "45", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "46", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "47", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "48", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "49", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "50", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "51", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "52", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "53", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "54", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "55", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "56", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}, {"SN": "57", "PLANT_UNIT": "", "DEPTT_SHOP": "", "SECTION_AREA": "", "RESPONSIBLE_PERSON": "", "DESIGNATION": "", "MOBILE_NO": ""}]''';

String plantCodeOf(String raw) {
  final s = raw.trim().toUpperCase();
  if (s == 'ASP' || s.contains('ALLOY')) return 'ASP';
  if (s == 'BSP') return 'BSP';
  return '';
}

void main() {
  // ── normaliseMobile ──
  ok(normaliseMobile('9434798958') == '9434798958', 'plain 10 digits');
  ok(normaliseMobile('\t9434798917') == '9434798917', 'leading tab');
  ok(normaliseMobile('918986875493') == '8986875493', 'country code no plus');
  ok(normaliseMobile('+91 94347 98958') == '9434798958', 'spaced +91');
  ok(normaliseMobile('09434798958') == '9434798958', 'leading zero');
  ok(normaliseMobile('9.434798958E9') == '9434798958', 'scientific');
  ok(normaliseMobile('9434798958.0') == '9434798958', 'float cell');
  ok(normaliseMobile('12345') == '', 'too short');
  ok(normaliseMobile(null) == '', 'null');

  // ── ASP sheet ──
  final rows = (jsonDecode(_aspJson) as List)
      .map((e) => Map<String, String>.from(e as Map))
      .toList();
  final keys = rows.first.keys.toList();
  final plan = MamrImporter.buildPlan(
      headerKeys: keys, rows: rows, plantCode: 'ASP',
      plantCodeOf: plantCodeOf, headerRowNumber: 2);

  ok(plan.errors.isEmpty, 'no blocking errors: ${plan.errors}');
  ok(plan.canApply, 'plan can apply');
  ok(plan.rows.length == 32, 'exactly 32 areas (got ${plan.rows.length})');
  ok(plan.ignoredBlank == 25, 'SN-only rows 33-57 ignored (got ${plan.ignoredBlank})');
  ok(plan.rejectedOtherPlant == 0, 'nothing rejected for plant');
  ok(plan.mapping['dept'] == 'DEPTT_SHOP', 'dept mapped');
  ok(plan.mapping['area'] == 'SECTION_AREA', 'area mapped');
  ok(plan.mapping['person'] == 'RESPONSIBLE_PERSON', 'person mapped');
  ok(plan.mapping['mobile'] == 'MOBILE_NO', 'mobile mapped');

  MamrImportRow bySn(int sn) => plan.rows.firstWhere((r) => r.sn == sn);

  final r1 = bySn(1);
  ok(r1.dept == 'SMS' && r1.area == 'Pit Side, LF #1, VAD, MS Bay', 'row 1 dept/area');
  ok(r1.persons.length == 1 && r1.persons.first.name == 'CHAKRADHAR SAHOO', 'row 1 person');
  ok(r1.persons.first.mobile == '9434798958', 'row 1 mobile');
  ok(r1.persons.first.designation == 'DGM (SMS & CCS)', 'row 1 designation');

  final r10 = bySn(10);
  ok(r10.persons.length == 2, 'row 10 two people');
  ok(r10.persons[0].name == 'JAYDEEP DUTTA' && r10.persons[0].mobile == '9434798912'
      && r10.persons[0].designation == 'DGM (FM-MILLS (EED))', 'row 10 first person paired');
  ok(r10.persons[1].name == 'RAVI ANAND' && r10.persons[1].mobile == '9434799019'
      && r10.persons[1].designation == 'AM (FM-MILLS(EED))', 'row 10 second person paired');
  final r15 = bySn(15);
  ok(r15.persons.length == 2 && r15.persons[1].name == 'ASHIK MUNSHI'
      && r15.persons[1].mobile == '9434798964', 'row 15 two people');

  ok(bySn(12).persons.first.mobile == '9434798917', 'row 12 tab mobile');
  ok(bySn(32).persons.first.name == 'SUMAN KUMAR JHA', 'row 32 tab name');
  ok(plan.rows.any((r) => r.sn == 31), 'row 31 "ASP " kept');

  final amits = plan.rows.expand((r) => r.persons).where((p) => p.name == 'AMIT KUMAR').toList();
  ok(amits.length == 2 && amits[0].mobile != amits[1].mobile, 'two AMIT KUMARs stay distinct');

  ok(plan.departments.contains('SMS') && plan.departments.contains('PCM & PROJECTS'), 'departments collected');
  ok(plan.warnings.where((w) => w.contains('check the pairing')).isEmpty, 'no pairing warnings');
  ok(plan.personCount == 34, 'person count 34 (got ${plan.personCount})');

  // ── apply: fresh ──
  final empty = const MamrRegister(plant: 'ASP');
  final reg = MamrImporter.apply(empty, plan, replace: false, updatedBy: 't',
      now: DateTime(2026, 10, 15));
  ok(reg.activeAreas.length == 32, 'register has 32 active areas');
  ok(reg.areas.map((a) => a.id).toSet().length == 32, 'ids unique');
  ok(reg.areas.first.id == 'ASP-001', 'first id ASP-001 (got ${reg.areas.first.id})');
  ok(reg.areasIn('SMS').length == 2, 'SMS has 2 areas');

  // JSON round trip.
  final back = MamrRegister.tryDecode(jsonEncode(reg.toJson()))!;
  ok(back.activeAreas.length == 32 && back.plant == 'ASP', 'json round trip');
  ok(back.byId('ASP-010')!.persons.length == 2, 'round trip keeps two persons');

  // ── apply: re-upload keeps ids and manual links ──
  final linked = reg.copyWith(areas: reg.areas.map((a) => a.sn == 1
      ? a.copyWith(persons: [a.persons.first.copyWith(username: 'p12345')])
      : a).toList());
  final shorter = MamrImportPlan(
      plant: 'ASP', rows: plan.rows.where((r) => r.sn != 2).toList(),
      warnings: const [], errors: const [], ignoredBlank: 0,
      rejectedOtherPlant: 0, mapping: plan.mapping);
  final merged = MamrImporter.apply(linked, shorter, replace: false);
  ok(merged.activeAreas.length == 32, 'merge keeps area missing from file');
  final a1 = merged.areas.firstWhere((a) => a.sn == 1);
  ok(a1.id == reg.areas.firstWhere((a) => a.sn == 1).id, 'id stable on re-upload');
  ok(a1.persons.first.username == 'p12345', 'manual link survives re-upload');
  final replaced = MamrImporter.apply(linked, shorter, replace: true);
  ok(replaced.activeAreas.length == 31, 'replace deactivates missing area');
  ok(replaced.areas.length == 32, 'replace never deletes');
  ok(replaced.nextId() == 'ASP-033', 'next id after 32');

  // ── other plant rows ──
  final mixed = [...rows.take(3), {...rows.first, 'PLANT_UNIT': 'BSP', 'SECTION_AREA': 'X'}];
  final p2 = MamrImporter.buildPlan(headerKeys: keys, rows: mixed,
      plantCode: 'ASP', plantCodeOf: plantCodeOf);
  ok(p2.rejectedOtherPlant == 1 && p2.rows.length == 3, 'BSP row rejected for ASP import');

  // ── missing columns ──
  final p3 = MamrImporter.buildPlan(headerKeys: const ['FOO', 'BAR'],
      rows: const [{'FOO': '1', 'BAR': '2'}], plantCode: 'ASP', plantCodeOf: plantCodeOf);
  ok(!p3.canApply && p3.errors.length == 3, 'missing required columns block');

  // ── observation helpers ──
  final inc = <String, dynamic>{
    'type': 'MAMR',
    'mamrResponsible': jsonEncode(reg.byId('ASP-010')!.responsibleSnapshot()),
  };
  ok(MamrObs.isMamr(inc), 'isMamr');
  ok(MamrObs.responsible(inc).length == 2, 'responsible decodes JSON string');
  ok(MamrObs.isResponsible(inc, const {}, '+91 94347 99019'), 'responsible by mobile');
  ok(!MamrObs.isResponsible(inc, const {'x'}, '9999999999'), 'not responsible');
  final inc2 = {...inc, 'mamrResponsible': [ {'name': 'A', 'username': 'P1'} ]};
  ok(MamrObs.isResponsible(inc2, const {'p1'}, ''), 'responsible by username (case)');
  ok(MamrObs.ownsArea(reg.byId('ASP-001')!, const {}, '919434798958'), 'owns area by mobile');
  ok(!MamrObs.isMamr({'type': 'AI_SCAN'}), 'AI_SCAN is not MAMR');

  final t = MamrTally();
  t.add(isComplied: true);
  t.add(isComplied: false, date: DateTime(2026, 10, 1), now: DateTime(2026, 10, 15));
  t.add(isComplied: false, date: DateTime(2026, 10, 10), now: DateTime(2026, 10, 15));
  ok(t.recorded == 3 && t.complied == 1 && t.pending == 2, 'tally counts');
  ok(t.oldestPendingDays == 14, 'oldest pending 14 days');

  // ── automatic deadlines ──
  final filed = DateTime(2026, 10, 15, 16, 30);
  ok(MamrDeadlines.targetFor(filed, 'CRITICAL') == '2026-10-16', 'critical +1 day');
  ok(MamrDeadlines.targetFor(filed, 'high') == '2026-10-17', 'high +2 days');
  ok(MamrDeadlines.targetFor(filed, 'MEDIUM') == '2026-10-22', 'medium +7 days');
  ok(MamrDeadlines.targetFor(filed, 'LOW') == '2026-10-30', 'low +15 days');
  ok(MamrDeadlines.targetFor(filed, 'UNKNOWN') == '2026-10-22', 'unknown → 7 days');
  ok(MamrDeadlines.targetFor(DateTime(2026, 12, 30), 'HIGH') == '2027-01-01', 'year rollover');
  final due = {'targetDate': '2026-10-17'};
  ok(!MamrDeadlines.isOverdue(due, complied: false, now: DateTime(2026, 10, 17, 23)), 'due day not overdue');
  ok(MamrDeadlines.isOverdue(due, complied: false, now: DateTime(2026, 10, 18)), 'next day overdue');
  ok(!MamrDeadlines.isOverdue(due, complied: true, now: DateTime(2026, 11, 1)), 'complied never overdue');
  ok(!MamrDeadlines.isOverdue(const {}, complied: false), 'no target never overdue');
  final t2 = MamrTally()
    ..add(isComplied: false, isOverdue: true)
    ..add(isComplied: true, isOverdue: true)
    ..add(isComplied: false);
  ok(t2.overdue == 1 && t2.pending == 2, 'overdue counts only pending');

  ok(MamrCategories.all.length == 6, 'six categories');
  ok(MamrImporter.templateCsv('ASP').startsWith('SN,Plant/Unit'), 'template header');

  // ── ★ 2026-10-27: MAMR declarations ("You are the MAMR of this area") ──
  {
    const pA = MamrPerson(name: 'A', mobile: '9434798958', username: '111');
    const pB = MamrPerson(name: 'B', mobile: '9434798762');
    const pBlinked = MamrPerson(name: 'B', mobile: '9434798762', username: '222');
    const a1 = MamrArea(id: 'ASP-001', sn: 1, dept: 'SMS', area: 'Pit Side', persons: [pA]);
    const a2 = MamrArea(id: 'ASP-002', sn: 2, dept: 'SMS', area: 'Furnace', persons: [pB]);
    const a3off = MamrArea(id: 'ASP-003', sn: 3, dept: 'SMS', area: 'Old', persons: [pA], active: false);
    const reg = MamrRegister(plant: 'ASP', areas: [a2, a1, a3off]);
    const bsp = MamrRegister(plant: 'BSP', areas: [
      MamrArea(id: 'BSP-001', sn: 1, dept: 'BF', area: 'Cast house', persons: [pA]),
    ]);

    final mine = MamrDeclaration.forUser([reg, bsp], {'111'}, '');
    ok(mine.length == 2, 'declared in two plants, inactive area skipped');
    ok(mine.first.plant == 'ASP' && mine.first.area.id == 'ASP-001', 'sorted plant then SN');
    ok(mine.first.key == 'mamrDeclared:ASP:ASP-001', 'stable key includes plant');
    ok(MamrDeclaration.forUser([reg], {'999'}, '9434798762').single.area.id == 'ASP-002',
        'unlinked person matched by mobile');
    ok(MamrDeclaration.forUser([reg], {'999'}, '+91 94347 98762').length == 1,
        'mobile normalised before matching');
    ok(MamrDeclaration.forUser([reg], {'999'}, '').isEmpty, 'other users: no declaration');
    ok(MamrDeclaration.forUser([const MamrRegister(plant: '', areas: [a1])], {'111'}, '').isEmpty,
        'register without plant code ignored');

    // newlyDeclared
    const empty = MamrRegister(plant: 'ASP');
    ok(MamrDeclaration.newlyDeclared(empty, reg).length == 2, 'first upload declares every active person');
    ok(MamrDeclaration.newlyDeclared(reg, reg).isEmpty, 're-upload of same file declares nobody');
    final linkedReg = reg.copyWith(areas: [a2.copyWith(persons: [pBlinked]), a1, a3off]);
    ok(MamrDeclaration.newlyDeclared(reg, linkedReg).isEmpty, 'linking by mobile is not a new declaration');
    final reassigned = reg.copyWith(areas: [a2.copyWith(persons: [pA]), a1, a3off]);
    final nd = MamrDeclaration.newlyDeclared(reg, reassigned);
    ok(nd.length == 1 && nd.first.$1.id == 'ASP-002' && nd.first.$2.username == '111',
        'reassignment declares the new person for that area only');
    final reactivated = reg.copyWith(areas: [a2, a1, a3off.copyWith(active: true)]);
    ok(MamrDeclaration.newlyDeclared(reg, reactivated).length == 1, 're-activated area re-declares');
    final second = reg.copyWith(areas: [a2.copyWith(persons: [pB, pA]), a1, a3off]);
    ok(MamrDeclaration.newlyDeclared(reg, second).single.$2.name == 'A', 'added second person only');
    ok(MamrDeclaration.newlyDeclared(reg, reg.copyWith(areas: [a1])).isEmpty, 'removal declares nobody');
  }

  print('mamr_core: $_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail failures');
}
