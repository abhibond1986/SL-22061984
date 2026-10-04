import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/screens/incident_detail_screen.dart';
import 'package:safety_lens/services/local_db.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

final inc = <String, dynamic>{
  'id': 'INC-20260926-0042', 'title': 'AI Hazard Scan: Trip hazard on ground',
  'severity': 'MEDIUM', 'riskScore': 30, 'status': 'OPEN', 'type': 'AI_SCAN',
  'plant': 'SSO Ranchi', 'dept': 'Maintenance', 'location': 'Bay 3, near conveyor',
  'date': '2026-09-26T10:15:00', 'reportedBy': 'Abhishek Kumar',
  'reportedByPno': '22061984', 'wsaCategory': 'Slip/Fall', 'people': '2',
  'desc': 'Loose hoses and debris lying across the walkway in front of the excavator, creating a trip hazard for workers moving between bays.',
  'immediateAction': 'Area cordoned off with tape.',
  'hazards': [
    {'name': 'Trip hazard from hoses on walkway', 'severity': 'MEDIUM',
     'description': 'Hydraulic hoses routed across the pedestrian path.',
     'regulation': 'IS 14489 · Housekeeping', 'correctiveAction': 'Route hoses overhead or use cable ramps.'},
    {'name': 'Debris near moving machinery', 'severity': 'HIGH',
     'description': 'Scrap pieces within the excavator swing radius.',
     'correctiveAction': 'Clear debris; mark exclusion zone.'},
  ],
};

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';
  Future<void> shoot(WidgetTester tester, Size size, String name) async {
    await tester.runAsync(() async {
      await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
        '$root/Roboto-Bold.ttf', '$root/Roboto-Black.ttf']);
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
        home: IncidentDetailScreen(incident: inc),
      )));
      for (var i = 0; i < 12; i++) {
        await Future.delayed(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1.0);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  }
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'current_user': jsonEncode({'username': 'abhin', 'name': 'Abhinav Kumar',
        'pno': '22061984', 'plant': 'SSO Ranchi', 'isAdmin': true}),
      'incidents': jsonEncode([inc]),
    });
    await LocalDB.init();
  });
  testWidgets('laptop', (t) => shoot(t, const Size(1440, 800), 'detail_laptop'));
  testWidgets('phone', (t) => shoot(t, const Size(400, 1400), 'detail_phone'));
}
