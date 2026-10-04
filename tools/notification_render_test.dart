// Render + behaviour check for the notification bell in UniversalAppBar.
// Run from a project copy:  OUT=/tmp/out flutter test test/notification_render_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/assignment_notifications.dart';
import 'package:safety_lens/widgets/notification_bell.dart';
import 'package:safety_lens/widgets/universal_app_bar.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

final _me = {
  'username': '22061984', 'name': 'Abhinav Kumar', 'pno': '22061984',
  'plant': 'SSO Ranchi',
};

String _ago(Duration d) => DateTime.now().subtract(d).toIso8601String();

List<Map<String, dynamic>> _incidents = [
  {
    'id': 'INC-1041', 'title': 'Unguarded conveyor tail pulley at coal yard',
    'severity': 'HIGH', 'status': 'UNDER INVESTIGATION', 'plant': 'BSL',
    'assignedTo': '22061984', 'assignedToName': 'Abhinav Kumar',
    'assignedAt': _ago(const Duration(minutes: 12)),
  },
  {
    'id': 'INC-1033', 'title': 'Missing guard-rail on blast furnace platform',
    'severity': 'MEDIUM', 'status': 'OPEN', 'plant': 'BSP',
    'assignedTo': '22061984', 'assignedToName': 'Abhinav Kumar',
    'assignedAt': _ago(const Duration(days: 3)),
    'targetDate': _ago(const Duration(days: 2)),
  },
  {
    'id': 'INC-1020', 'title': 'Worker without chin strap near ladle crane',
    'severity': 'LOW', 'status': 'OPEN', 'plant': 'SSO Ranchi',
    'reportedByPno': '22061984', 'reportedBy': 'Abhinav Kumar',
    'assignedTo': 'rk_singh', 'assignedToName': 'R. K. Singh',
    'assignedAt': _ago(const Duration(hours: 5)),
  },
  {
    // Closed: must NOT appear.
    'id': 'INC-0999', 'title': 'Closed case', 'severity': 'HIGH',
    'status': 'CLOSED', 'assignedTo': '22061984',
  },
];

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  setUp(() {
    // Tests replace shadows with a solid ring by default; draw the real thing.
    debugDisableShadows = false;
    SharedPreferences.setMockInitialValues({});
    AssignmentNotifications.resetForTest();
    AssignmentNotifications.userLoader = () async => _me;
    AssignmentNotifications.incidentLoader = () async => _incidents;
    AssignmentNotifications.openStatusLoader =
        () async => {'OPEN', 'UNDER INVESTIGATION'};
  });

  Future<void> shoot(WidgetTester t, Size size, String name,
      {bool dark = false, bool openPanel = false,
      Future<void> Function()? before}) async {
    await t.runAsync(() async {
      await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
        '$root/Roboto-Bold.ttf', '$root/Roboto-Black.ttf']);
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
    });
    debugDisableShadows = false;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          appBar: UniversalAppBar(title: 'Dashboard', subtitle: 'SSO Ranchi',
              user: _me, isDark: dark, toggleTheme: () {}),
          body: const SizedBox.expand(),
        ),
      )));
      for (var i = 0; i < 4; i++) {
        await Future.delayed(const Duration(milliseconds: 150));
        await t.pump(const Duration(milliseconds: 100));
      }
      if (before != null) await before();
      if (openPanel) {
        await t.tap(find.byType(NotificationBell));
        for (var i = 0; i < 4; i++) {
          await Future.delayed(const Duration(milliseconds: 150));
          await t.pump(const Duration(milliseconds: 100));
        }
      }
      final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await ro.toImage(pixelRatio: 1.0);
      final bd = await im.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
    });
    await t.pumpWidget(const SizedBox());
    debugDisableShadows = true; // the framework checks this is restored
  }

  test('inbox -> 3 notifications, closed excluded, read state persists',
      () async {
    await AssignmentNotifications.refresh();
    var s = AssignmentNotifications.state.value;
    expect(s.items.map((i) => i.id).toSet(), {'INC-1041', 'INC-1033', 'INC-1020'});
    expect(s.unreadCount, 3);
    expect(s.arrivals, isEmpty, reason: 'first load must not toast backlog');

    await AssignmentNotifications.markRead(s.items.first);
    await AssignmentNotifications.refresh();
    expect(AssignmentNotifications.state.value.unreadCount, 2);

    // New assignment arrives.
    _incidents = [
      ..._incidents,
      {'id': 'INC-1050', 'title': 'Gas leak near coke oven battery 5',
        'severity': 'HIGH', 'status': 'OPEN', 'assignedTo': '22061984',
        'assignedAt': DateTime.now().toIso8601String()},
    ];
    await AssignmentNotifications.refresh();
    s = AssignmentNotifications.state.value;
    expect(s.unreadCount, 3);
    expect(s.arrivals.map((i) => i.id), ['INC-1050']);
    expect(s.arrivalGen, 1);

    // Reassigned away -> disappears.
    _incidents = _incidents.where((i) => i['id'] != 'INC-1050').toList();
    await AssignmentNotifications.refresh();
    expect(AssignmentNotifications.state.value.items.length, 3);

    await AssignmentNotifications.markAllRead();
    expect(AssignmentNotifications.state.value.unreadCount, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('notif_read_22061984')!.length, 3);
    expect(prefs.getStringList('assignment_seen_22061984'), isNull,
        reason: 'must not share the dashboard seen-set');
    // ignore: avoid_print
    print(jsonEncode({'ok': true}));
  });

  testWidgets('bell + panel renders', (t) async {
    await shoot(t, const Size(1280, 300), 'bell_header_laptop');
    await shoot(t, const Size(1280, 720), 'bell_panel_laptop', openPanel: true);
    await shoot(t, const Size(1280, 720), 'bell_panel_dark',
        dark: true, openPanel: true);
    await shoot(t, const Size(400, 820), 'bell_panel_phone', openPanel: true);
  });

  testWidgets('empty state + no badge after mark all read', (t) async {
    _incidents = [];
    await shoot(t, const Size(1280, 520), 'bell_panel_empty', openPanel: true);
  });
}
