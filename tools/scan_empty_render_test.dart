// Render check for the AI Scan empty capture card (feature chips contrast).
// Run from a project copy: OUT=/tmp/out flutter test test/scan_empty_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/screens/ai_scan_tab.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (!File(f).existsSync()) continue;
    l.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await l.load();
}

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> shoot(WidgetTester t, bool dark, String name) async {
    await t.runAsync(() async {
      await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
        '$root/Roboto-Bold.ttf']);
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
    });
    debugDisableShadows = false;
    t.view.physicalSize = const Size(1000, 560);
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(body: AIScanTab(isDark: dark, showAppBar: false)),
      )));
      for (var i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 120));
        await t.pump(const Duration(milliseconds: 150));
      }
      final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await ro.toImage(pixelRatio: 1.0);
      final bd = await im.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
    });
    t.takeException();
    await t.pumpWidget(const SizedBox());
    debugDisableShadows = true;
  }

  testWidgets('scan empty dark', (t) => shoot(t, true, 'scan_empty_dark'));
  testWidgets('scan empty light', (t) => shoot(t, false, 'scan_empty_light'));
}
