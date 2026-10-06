// PDF check for 2026-10-06: the longer, sub-clause Factories Act citations
// ("FA 1948 S7A(2)(b)", "FA 1948 S111(1)(c)") in the 1.25-flex REGULATION
// column of the hazards table. Offline: no network, no photo.
// Run: OUT=/tmp/out flutter test test/pdf_regulation_column_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/pdf_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  test('hazards table with the new citations renders', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalDB.init();
    Map<String, dynamic> h(String n, String sev, String reg, String d, String a) =>
        {'name': n, 'severity': sev, 'regulation': reg, 'description': d,
         'correctiveAction': a};
    final inc = <String, dynamic>{
      'id': 'test-fa-citations',
      'date': '2026-10-06T11:20:00',
      'type': 'Unsafe Condition',
      'severity': 'HIGH',
      'location': 'BF-2 Cast House, Bay 4',
      'description': 'AI scan of cast house floor and stock yard.',
      'reportedBy': 'Test Officer',
      'reportedByPno': 'P12345',
      'hazards': [
        h('Coil stack without chocks', 'HIGH', 'FA 1948 S7A(2)(b)',
          'Three hot-rolled coils stacked two-high with no chocks on the outer coil; roll-off path crosses the walkway.',
          'Chock every coil at the stack edge; limit stacking height; keep walkway clear of the roll-off zone.'),
        h('Worker without face shield at tap hole', 'HIGH', 'FA 1948 S111(1)(c)',
          'Worker at the tap hole wearing aluminised jacket but no face shield, which is hung on the rail behind him.',
          'Stop the task until the face shield is worn; brief the crew; supervisor to check at shift start.'),
        h('Fugitive dust at transfer chute', 'MEDIUM', 'FA 1948 S14',
          'Visible dust plume at the conveyor transfer point; extraction hood damaged.',
          'Repair the hood and restore extraction at the point of origin; issue respirators until fixed.'),
        h('Radiant heat at runner', 'MEDIUM', 'FA 1948 S13',
          'Workers within 2 m of the open iron runner with no heat shield.',
          'Install a portable heat shield; rotate crew; provide cool drinking water.'),
        h('Open edge on gallery', 'HIGH', 'FA 1948 S32(c)',
          'Handrail section missing at the upper gallery edge, 6 m drop.',
          'Barricade immediately; reinstate the handrail and toe board before use.'),
        h('Corroded gallery members', 'MEDIUM', 'FA 1948 S7A(2)(d)',
          'Perforated chequered plate and corroded stringers on the access gallery.',
          'Restrict access; structural inspection; replace the plate and stringers.'),
      ],
    };
    final bytes = await PdfExport.generateIncidentReportBytes(incident: inc);
    Directory(out).createSync(recursive: true);
    File('$out/pdf_fa_citations.pdf').writeAsBytesSync(bytes);
    expect(bytes.length, greaterThan(1000));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
