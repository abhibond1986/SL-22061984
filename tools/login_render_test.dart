// Render check for the glassmorphism login screen (2026-10-05).
// Run from a project copy:
//   OUT=/tmp/out POPPINS=/tmp/pop flutter test test/login_render_test.dart
// Needs network: google_fonts fetches Poppins at runtime, as the app does.
// POPPINS (optional) is a folder holding Poppins-Black/ExtraBold/ExtraBoldItalic
// .ttf, loaded under the fallback family "Poppins" in case the fetch fails.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/widgets/copyright_footer.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/screens/login_screen.dart';
import 'package:safety_lens/widgets/plant_backdrop.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (!File(f).existsSync()) continue;
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';
  final pop = Platform.environment['POPPINS'] ?? '/tmp/pop';

  TestWidgetsFlutterBinding.ensureInitialized();
  // Real network so google_fonts can fetch Poppins exactly as the app does
  // (and the GitHub release lookup for the download tile can answer).
  HttpOverrides.global = null;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // google_fonts caches fetched files under the app-support directory.
    Directory('/tmp/gf').createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => '/tmp/gf');
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  Future<void> shoot(WidgetTester t, Size size, String name,
      {bool dark = false, bool register = false, bool error = false,
      double frame = 0.3, double scroll = 0}) async {
    // Pin the backdrop loop at a fixed point so renders are repeatable.
    PlantBackdrop.debugFrame = frame;
    await t.runAsync(() async {
      await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
        '$root/Roboto-Bold.ttf', '$root/Roboto-Black.ttf']);
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
      await _font('Poppins', ['$pop/Poppins-Black.ttf',
        '$pop/Poppins-ExtraBold.ttf', '$pop/Poppins-ExtraBoldItalic.ttf']);
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
        // Same as main.dart: the copyright strip sits below every route.
        builder: (context, child) => CopyrightFooter(child: child!),
        home: LoginScreen(toggleTheme: () {}),
      )));
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await Future.delayed(const Duration(milliseconds: 120));
          await t.pump(const Duration(milliseconds: 150));
        }
      }
      await settle();
      try { await GoogleFonts.pendingFonts(); } catch (_) {}
      await settle();
      if (register) {
        await t.tap(find.text('Register'));
        await settle();
      }
      if (scroll > 0) {
        // Drag the form column: on wide layouts only it should move.
        await t.drag(find.text('Full name'), Offset(0, -scroll));
        await settle();
      }
      if (error) {
        // Empty username + Sign in → the inline error box.
        await t.tap(find.text('Sign in').last);
        await settle();
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
    PlantBackdrop.debugFrame = null;
  }

  testWidgets('phone light', (t) => shoot(t, const Size(390, 844), 'login_phone_light'));
  testWidgets('phone dark', (t) => shoot(t, const Size(390, 844), 'login_phone_dark', dark: true));
  testWidgets('phone error', (t) => shoot(t, const Size(390, 844), 'login_phone_error', error: true));
  testWidgets('phone register', (t) => shoot(t, const Size(390, 1300), 'login_phone_register', register: true));
  testWidgets('small 320', (t) => shoot(t, const Size(320, 700), 'login_320_light'));
  testWidgets('desktop light', (t) => shoot(t, const Size(1440, 900), 'login_desktop_light'));
  testWidgets('desktop dark register', (t) => shoot(t, const Size(1440, 900), 'login_desktop_dark_register', dark: true, register: true));
  testWidgets('desktop dark register scrolled', (t) => shoot(t, const Size(1440, 900), 'login_desktop_dark_register_scrolled', dark: true, register: true, scroll: 400));
  testWidgets('desktop dark', (t) => shoot(t, const Size(1440, 900), 'login_desktop_dark', dark: true));
  testWidgets('laptop dark', (t) => shoot(t, const Size(1024, 640), 'login_laptop_dark', dark: true));
  testWidgets('laptop light', (t) => shoot(t, const Size(1024, 640), 'login_laptop_light'));
  // Close-up of the hot-metal pour in the background (desktop, dark).
  testWidgets('desktop dark motion', (t) => shoot(t, const Size(1440, 900), 'login_desktop_dark_motion', dark: true, frame: 0.537));
  // FRAMES=1: frame sequence for an animated preview (first 3.6 s of the loop).
  if (Platform.environment['FRAMES'] == '1') {
    for (var i = 0; i < 36; i++) {
      final u = i / 120; // 0.1 s steps over the first 3.6 s of the loop
      final n = i.toString().padLeft(2, '0');
      testWidgets('frame $n', (t) => shoot(t, const Size(1440, 900),
          'frame_$n', dark: Platform.environment['LIGHT'] != '1', frame: u));
    }
  }
}
