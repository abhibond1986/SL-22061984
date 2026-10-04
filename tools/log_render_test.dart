// Renders the Incident Log at laptop and phone sizes to PNG for visual review.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/screens/analytics/incident_log_tab.dart';
import 'package:safety_lens/services/local_db.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

Map<String, dynamic> _inc(String id, String title, String sev, int? score,
    String status, String type, String plant, String date,
    {String? assignee, String cat = ''}) => {
      'id': id, 'title': title, 'severity': sev,
      if (score != null) 'riskScore': score,
      'status': status, 'type': type, 'plant': plant, 'date': date,
      'reportedBy': 'Abhinav Kumar', 'reportedByPno': '22061984',
      'wsaCategory': cat,
      if (assignee != null) ...{
        'assignedTo': assignee.toLowerCase().replaceAll(' ', '.'),
        'assignedToName': assignee,
        'assignedAt': '2026-10-02T10:00:00',
      },
    };

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  Future<void> shoot(WidgetTester tester, Size size, String name,
      {bool dark = false}) async {
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
        theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: 'Roboto', useMaterial3: true),
        home: Scaffold(
          backgroundColor: dark ? const Color(0xFF0D1117) : const Color(0xFFF5F7FA),
          body: const IncidentLogTab()),
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
      'incidents': jsonEncode([
        _inc('1', 'AI Hazard Scan: Exposed gear mesh on conveyor drive', 'CRITICAL', 88,
            'OPEN', 'AI_SCAN', 'Bhilai Steel Plant', '2026-10-03T09:10:00',
            cat: 'Machine guarding'),
        _inc('2', 'Near miss: Crane load swung close to worker', 'HIGH', 66,
            'INVESTIGATING', 'NEAR_MISS', 'Rourkela Steel Plant', '2026-10-02T15:00:00',
            assignee: 'Ravi Shankar', cat: 'Lifting operations'),
        _inc('3', 'AI Hazard Scan: Worker without chin strap', 'MEDIUM', 42,
            'ACTION TAKEN', 'AI_SCAN', 'Durgapur Steel Plant', '2026-10-01T11:00:00',
            assignee: 'Priya Singh', cat: 'PPE'),
        _inc('4', 'Housekeeping: oil spill near stairs', 'LOW', 18,
            'CLOSED', 'NEAR_MISS', 'Bokaro Steel Plant', '2026-09-28T08:00:00',
            assignee: 'Amit Das'),
        _inc('5', 'AI Hazard Scan: Open cable tray, no score stored', 'HIGH', null,
            'OPEN', 'AI_SCAN', 'SSO Ranchi', '2026-09-27T08:00:00'),
      ]),
    });
    await LocalDB.init();
  });

  testWidgets('laptop', (t) => shoot(t, const Size(1280, 640), 'log_laptop'));
  testWidgets('laptop_dark',
      (t) => shoot(t, const Size(1280, 640), 'log_laptop_dark', dark: true));
  testWidgets('laptop_short', (t) => shoot(t, const Size(1366, 500), 'log_laptop_short'));
  testWidgets('phone', (t) => shoot(t, const Size(400, 860), 'log_phone'));
}
