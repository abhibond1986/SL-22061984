// PDF check for 2026-10-30: a near miss written in Hindi. Before the fix the
// Latin-1 Helvetica could not draw Devanagari ("Unable to find a font to draw
// क") and every Hindi letter printed as an empty box. Now each Hindi word is
// shaped by the text engine (see lib/services/pdf_text.dart).
// Run: OUT=/tmp/out flutter test tools/pdf_hindi_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/pdf_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  testWidgets('Hindi near miss renders', (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await LocalDB.init();
      final inc = <String, dynamic>{
        'id': '1793330000000',
        'title': 'क्रेन के नीचे कर्मचारी',
        'plant': 'BSL',
        'dept': 'Operations',
        'location': 'ब्लास्ट फर्नेस-2, कास्ट हाउस',
        'severity': 'HIGH',
        'wsaCategory': 'Unsafe Act',
        'obsType': 'Near Miss',
        'desc': 'EOT crane से लटके भार के नीचे एक कर्मचारी चल रहा था। '
            'स्लिंग का एक हिस्सा क्षतिग्रस्त था और हुक का सेफ्टी लैच टूटा हुआ था। '
            'श्रमिक ने हेलमेट पहना था, परन्तु सुरक्षा जूते नहीं थे।\n\n'
            'शिफ्ट इंचार्ज को तुरंत सूचित किया गया।',
        'immediateAction': 'क्रेन का संचालन रोका गया | क्षेत्र को बैरिकेड किया गया | '
            'स्लिंग बदली गई और PPE सुनिश्चित किए गए',
        'type': 'NEAR_MISS',
        'status': 'OPEN',
        'reportedBy': 'रवि शंकर',
        'reportedByPno': 'P12345',
        'date': '2026-10-30T10:15:00',
        'riskScore': 70,
        'confidence': 100,
        'overallRisk': 'HIGH',
      };
      final bytes = await PdfExport.generateIncidentReportBytes(incident: inc);
      Directory(out).createSync(recursive: true);
      File('$out/pdf_hindi_near_miss.pdf').writeAsBytesSync(bytes);
      expect(bytes.length, greaterThan(1000));

      // English report: unchanged path, single pass.
      final en = Map<String, dynamic>.from(inc)
        ..['title'] = 'Worker under crane load'
        ..['location'] = 'Blast Furnace-2 cast house'
        ..['desc'] = 'A worker walked under a suspended EOT crane load.'
        ..['immediateAction'] = 'Crane stopped | Area barricaded'
        ..['reportedBy'] = 'Ravi Shankar';
      final enBytes = await PdfExport.generateIncidentReportBytes(incident: en);
      File('$out/pdf_english_near_miss.pdf').writeAsBytesSync(enBytes);
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
