import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:safety_lens/services/pdf_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List photo() {
  final im = img.Image(width: 1200, height: 900);
  for (var y = 0; y < 900; y++) {
    for (var x = 0; x < 1200; x++) {
      im.setPixelRgb(x, y, 70 + (x ~/ 12) % 40, 95 + (y ~/ 10) % 30, 100);
    }
  }
  img.fillRect(im, x1: 100, y1: 450, x2: 1100, y2: 560, color: img.ColorRgb8(60, 60, 60)); // conveyor
  img.fillCircle(im, x: 900, y: 300, radius: 40, color: img.ColorRgb8(230, 190, 150)); // head
  img.fillRect(im, x1: 860, y1: 340, x2: 940, y2: 600, color: img.ColorRgb8(40, 80, 160)); // body
  img.fillRect(im, x1: 300, y1: 200, x2: 324, y2: 226, color: img.ColorRgb8(200, 30, 30)); // tiny item
  return Uint8List.fromList(img.encodeJpg(im, quality: 85));
}

Map<String, dynamic> inc(List<Map<String, dynamic>> hz) => {
  'id': 'audit_test_1', 'type': 'AI_SCAN', 'title': 'Missing eye protection',
  'severity': 'HIGH', 'plant': 'SSO Ranchi', 'dept': 'Safety', 'location': 'Conveyor C3',
  'date': '2026-10-03T11:48:00', 'riskScore': 70, 'confidence': 88,
  'summary': 'Worker near running conveyor without eye protection; a small exposed item on the left.',
  'hazards': hz, 'status': 'OPEN',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test('render', () async {
    final p = photo();
    final hz = [
      {'name': 'Missing eye protection', 'severity': 'HIGH', 'description': 'Worker beside the conveyor without goggles.',
       'regulation': 'FA 1948 S35', 'correctiveAction': 'Issue goggles.', 'locationUnpinned': true},
      {'name': 'Exposed sharp item', 'severity': 'MEDIUM', 'description': 'Small exposed item on the bench.',
       'regulation': 'IS 14489', 'correctiveAction': 'Remove.', 'bbox': {'x': 0.245, 'y': 0.215, 'w': 0.03, 'h': 0.035}},
      {'name': 'Worker in line of fire of running conveyor', 'type': 'Line of Fire', 'severity': 'CRITICAL',
       'description': 'Worker standing next to the running conveyor belt nip point.', 'visualEvidence': 'conveyor belt running, worker adjacent',
       'regulation': 'FA 1948 S21', 'correctiveAction': 'Guard the conveyor; barricade.',
       'bbox': {'x': 0.70, 'y': 0.28, 'w': 0.11, 'h': 0.40},
       'lofZone': {'x1': 0.35, 'y1': 0.56, 'x2': 0.75, 'y2': 0.50, 'source': 'conveyor belt', 'exposure': 'worker', 'personVisible': true},
       '_peopleVisible': 1},
    ];
    final a = await PdfExport.generateIncidentReportBytes(incident: inc(hz), reporterName: 'Audit', reporterPno: '1', imageBytes: p);
    File('/tmp/out/with_lof.pdf')..createSync(recursive: true)..writeAsBytesSync(a);
    final b = await PdfExport.generateIncidentReportBytes(incident: inc(hz.take(2).toList()), reporterName: 'Audit', reporterPno: '1', imageBytes: p);
    File('/tmp/out/no_lof.pdf').writeAsBytesSync(b);
    final c = await PdfExport.generateIncidentReportBytes(incident: {
      ...inc(const []), 'aiAnalysed': false, 'severity': '', 'summary': 'This image was NOT analysed.'},
      reporterName: 'Audit', reporterPno: '1', imageBytes: p);
    File('/tmp/out/not_analysed.pdf').writeAsBytesSync(c);
    final d = await PdfExport.generateIncidentReportBytes(incident: {
      'id': 'nm_000123', 'type': 'NEAR_MISS', 'title': 'Hose lying across walkway',
      'severity': 'MEDIUM', 'plant': 'BSL', 'dept': 'Blast Furnace', 'location': 'BF-2 cast house',
      'date': '2026-10-03T09:15:00', 'riskScore': 45, 'status': 'OPEN', 'people': 2,
      'obsType': 'Unsafe Condition', 'wsaCategory': 'Slips, trips and falls',
      'summary': 'An oxygen hose was lying across the main walkway near tap hole 2 — two workers nearly tripped while carrying tools.',
      'immediateAction': 'Hose rerouted along wall | Area cordoned | Supervisor informed',
      'latitude': 23.6693, 'longitude': 86.1511, 'locationAccuracy': 8, 'locationAddress': 'Bokaro Steel Plant, Jharkhand'},
      reporterName: 'R. Kumar', reporterPno: '123456');
    File('/tmp/out/near_miss.pdf').writeAsBytesSync(d);
    final e = await PdfExport.generateIncidentReportBytes(incident: {
      ...inc([hz[1]..['severity'] = 'LOW']), 'severity': 'LOW', 'plant': 'RSP', 'title': 'Loose item on bench', 'confidence': 80},
      reporterName: 'Audit', reporterPno: '1', imageBytes: p);
    File('/tmp/out/low.pdf').writeAsBytesSync(e);
  });
}
