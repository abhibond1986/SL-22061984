// Render + behaviour check for 2026-10-30: the one-time permission sheet,
// the "turned off" guard dialog and My Profile.
// Run from a project copy: OUT=/tmp/out flutter test tools/profile_permissions_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/device_permissions.dart';
import 'package:safety_lens/services/i18n.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/screens/my_profile_screen.dart';
import 'package:safety_lens/widgets/permission_onboarding.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (!File(f).existsSync()) continue;
    l.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await l.load();
}

final _user = <String, dynamic>{
  'username': 'p12345',
  'name': 'Ravi Shankar',
  'pno': 'P12345',
  'grade': 'E4',
  'plant': 'BSL - Bokaro Steel Plant',
  'designation': 'Sr. Manager (Safety)',
  'department': 'Safety Engineering',
  'unit': 'Blast Furnace',
  'mobile': '9876543210',
  'email': 'ravi.shankar@sail.in',
};

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> fonts(WidgetTester t) => t.runAsync(() async {
        await _font('Roboto', [
          '$root/Roboto-Regular.ttf',
          '$root/Roboto-Medium.ttf',
          '$root/Roboto-Bold.ttf'
        ]);
        await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
        await _font('NotoDeva', [
          'assets/fonts/NotoSansDevanagari-Regular.ttf',
          'assets/fonts/NotoSansDevanagari-Bold.ttf'
        ]);
      });

  Widget app(bool dark, Widget home) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            fontFamily: 'Roboto',
            fontFamilyFallback: const ['NotoDeva'],
            useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light),
        home: home,
      );

  Future<void> snap(WidgetTester t, GlobalKey key, String name) async {
    for (var i = 0; i < 6; i++) {
      await Future.delayed(const Duration(milliseconds: 80));
      await t.pump(const Duration(milliseconds: 200));
    }
    final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final im = await ro.toImage(pixelRatio: 1.0);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    Directory(out).createSync(recursive: true);
    File('$out/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
  }

  Future<void> sheet(WidgetTester t, bool dark, String lang, Size size,
      String name) async {
    SharedPreferences.setMockInitialValues({});
    PermissionOnboarding.debugReset();
    await fonts(t);
    await t.runAsync(() async {
      await LocalDB.init();
      await I18n.setLocale(lang);
    });
    debugDisableShadows = false;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    late BuildContext ctx;
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(
          key: key,
          child: app(
              dark,
              Builder(builder: (c) {
                ctx = c;
                return const Scaffold(body: SizedBox.expand());
              }))));
      // ignore: unawaited_futures
      PermissionOnboarding.maybeShow(ctx, 'p12345');
      await snap(t, key, name);
    });
    t.takeException();
    await t.pumpWidget(const SizedBox());
    debugDisableShadows = true;
  }

  Future<void> profile(WidgetTester t, bool dark, String lang, Size size,
      String name) async {
    SharedPreferences.setMockInitialValues({});
    await fonts(t);
    await t.runAsync(() async {
      await LocalDB.init();
      await I18n.setLocale(lang);
      await DevicePermissions.loadFor('p12345');
      await DevicePermissions.recordAnswers({
        DeviceFeature.camera: true,
        DeviceFeature.microphone: false,
        DeviceFeature.location: true,
      });
    });
    debugDisableShadows = false;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(
          key: key, child: app(dark, MyProfileScreen(user: _user))));
      await snap(t, key, name);
    });
    t.takeException();
    await t.pumpWidget(const SizedBox());
    debugDisableShadows = true;
  }

  testWidgets('sheet phone light', (t) =>
      sheet(t, false, 'en', const Size(400, 860), 'perm_sheet_phone_light'));
  testWidgets('sheet phone dark hi', (t) =>
      sheet(t, true, 'hi', const Size(400, 860), 'perm_sheet_phone_dark_hi'));
  testWidgets('sheet laptop dark', (t) =>
      sheet(t, true, 'en', const Size(1280, 760), 'perm_sheet_laptop_dark'));
  testWidgets('profile phone light', (t) =>
      profile(t, false, 'en', const Size(400, 1500), 'profile_phone_light'));
  testWidgets('profile phone dark hi', (t) =>
      profile(t, true, 'hi', const Size(400, 1500), 'profile_phone_dark_hi'));
  testWidgets('profile laptop dark', (t) =>
      profile(t, true, 'en', const Size(1280, 1350), 'profile_laptop_dark'));

  testWidgets('one-time answer is remembered across logins', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.runAsync(() async {
      await DevicePermissions.loadFor('p12345');
      expect(DevicePermissions.answered, isFalse);
      // Defaults: nothing blocked for someone who never answered.
      expect(DevicePermissions.isEnabled(DeviceFeature.camera), isTrue);
      await DevicePermissions.recordAnswers({
        DeviceFeature.camera: true,
        DeviceFeature.microphone: false,
        DeviceFeature.location: true,
      });
      // "Log out" and back in: a fresh load reads the stored answer.
      await DevicePermissions.loadFor('someone_else');
      expect(DevicePermissions.answered, isFalse);
      await DevicePermissions.loadFor('P12345'); // case-insensitive
      expect(DevicePermissions.answered, isTrue);
      expect(DevicePermissions.isEnabled(DeviceFeature.microphone), isFalse);
      expect(DevicePermissions.isEnabled(DeviceFeature.camera), isTrue);
      // Changed later in My Profile.
      await DevicePermissions.setEnabled(DeviceFeature.microphone, true);
      await DevicePermissions.loadFor('p12345');
      expect(DevicePermissions.isEnabled(DeviceFeature.microphone), isTrue);
    });
  });

  testWidgets('guard asks before using a feature that is off', (t) async {
    SharedPreferences.setMockInitialValues({});
    await fonts(t);
    await t.runAsync(() async {
      await I18n.setLocale('en');
      await DevicePermissions.loadFor('p12345');
      await DevicePermissions.recordAnswers({
        DeviceFeature.camera: false,
        DeviceFeature.microphone: true,
        DeviceFeature.location: true,
      });
    });
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    late BuildContext ctx;
    late Future<bool> result;
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(
          key: key,
          child: app(
              false,
              Builder(builder: (c) {
                ctx = c;
                return const Scaffold(body: SizedBox.expand());
              }))));
      result = DevicePermissions.guard(ctx, DeviceFeature.camera);
      await snap(t, key, 'perm_guard_dialog');
      await t.tap(find.text('Keep off'));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(await result.timeout(const Duration(seconds: 5)), isFalse);
      expect(DevicePermissions.isEnabled(DeviceFeature.camera), isFalse);
      // A feature that is on goes straight through, no dialog.
      expect(await DevicePermissions.guard(ctx, DeviceFeature.microphone),
          isTrue);
    });
    await t.pumpWidget(const SizedBox());
  });
}
