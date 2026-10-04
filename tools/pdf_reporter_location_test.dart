// PDF check for 2026-10-04: reporter name, lighter masthead, GPS location.
// Pulls the REAL incident 1791107789679 (Ravi Shankar, DSP) from Supabase and
// generates the report the way an admin would (viewer = System Admin).
// Run from a project copy:  OUT=/tmp/out flutter test test/pdf_reporter_location_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/pdf_export.dart';
import 'package:safety_lens/services/supabase_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real network for the live record + photo
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  test('report names the filer, not the viewer; GPS printed', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalDB.init();
    await SupabaseService.init();
    final all = await SupabaseService.fetchIncidentsOrNull();
    final inc = all!.firstWhere((i) => i['id'].toString() == '1791107789679');
    expect(inc['reportedBy'], 'Ravi Shankar');

    final req = await HttpClient().getUrl(Uri.parse(inc['imageUrl'] ??
        inc['image_url'] ??
        'https://mptdergmcakhufsmcogd.supabase.co/storage/v1/object/public/incident-images/img_1791107789679.jpg'));
    final resp = await req.close();
    final img = await resp.fold<List<int>>([], (a, b) => a..addAll(b));

    Future<void> gen(String name, Map<String, dynamic> m) async {
      final bytes = await PdfExport.generateIncidentReportBytes(
        incident: m,
        // What the incident detail screen used to pass: the logged-in viewer.
        reporterName: 'System Admin', reporterPno: 'ADMIN001',
        imageBytes: img.isEmpty ? null : Uint8List.fromList(img));
      File('$out/$name.pdf').writeAsBytesSync(bytes);
    }

    await gen('pdf_real_critical', Map<String, dynamic>.from(inc));
    // Same report as if the photo had carried GPS (this one did not).
    final gps = Map<String, dynamic>.from(inc)
      ..['latitude'] = 23.5469
      ..['longitude'] = 87.2905
      ..['locationAccuracy'] = 12
      ..['locationAddress'] = 'Blast Furnace Road, Durgapur Steel Plant, Durgapur'
      ..['locationTimestamp'] = '2026-10-04T15:26:10';
    await gen('pdf_gps_critical', gps);
    for (final s in ['HIGH', 'MEDIUM', 'LOW']) {
      await gen('pdf_gps_${s.toLowerCase()}',
          Map<String, dynamic>.from(gps)..['severity'] = s);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
