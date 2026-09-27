// Shared harness for the screen-width sweep.
//
// Why a harness and not a plain pumpWidget:
//   * Every screen reads LocalDB (SharedPreferences) and SL.of(context), and
//     most read AppLocalizations. Without those the screens throw before they
//     lay out, and a width test would be measuring the error pane.
//   * Tests fall back to a square-glyph font that is roughly twice as wide as
//     the Inter/Roboto used in the app. That flags overflows no user can ever
//     see. Loading Roboto from the Flutter SDK gives realistic line breaks.
//     If the font can't be found (an unusual SDK layout), the test still runs
//     on the stricter fallback font. It never gets weaker.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/main.dart' show AppColors, AppLocalizations;
import 'package:safety_lens/services/local_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The widths the sweep checks: small phone, common phones, small tablet,
/// tablet portrait, tablet landscape / small laptop, laptop, full-HD desktop.
const sweepWidths = <double>[320, 360, 390, 600, 768, 1024, 1440, 1920];

bool _fontsLoaded = false;

Future<void> loadRealFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    var any = false;
    for (final f in files) {
      final file = File('$dir/$f');
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      any = true;
    }
    if (any) await loader.load();
  }

  const roboto = [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ];
  await load('Roboto', roboto);
  // Text styles with no fontFamily (e.g. a DropdownButton `style:`, which
  // replaces the theme style instead of merging with it) fall back to the
  // test font. On a device that fallback is the platform sans-serif, so give
  // the test font the same metrics.
  await load('FlutterTest', roboto);
  await load('Ahem', roboto);
  await load('MaterialIcons', const ['MaterialIcons-Regular.otf']);
}

/// Answers the platform channels that screens call from initState (mic
/// permission, speech engine, connectivity). There is no platform in a widget
/// test, so without these every call ends in an uncaught MissingPluginException,
/// which fails the test for a reason that has nothing to do with layout.
/// The answers are the "nothing available" ones: permission denied, no speech
/// engine, offline. That is also the state that shows the most fallback UI.
void mockPlatformChannels() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  void on(String name, Object? Function(MethodCall c) answer) {
    m.setMockMethodCallHandler(
        MethodChannel(name), (c) async => answer(c));
  }

  on('flutter.baseflow.com/permissions/methods', (c) {
    if (c.method == 'requestPermissions') return <int, int>{};
    if (c.method == 'checkPermissionStatus') return 0;
    if (c.method == 'checkServiceStatus') return 0;
    if (c.method == 'shouldShowRequestPermissionRationale') return false;
    return null;
  });
  on('plugin.csdcorp.com/speech_to_text', (c) {
    if (c.method == 'has_permission' || c.method == 'initialize') return false;
    if (c.method == 'locales') return <String>[];
    return null;
  });
  on('dev.fluttercommunity.plus/connectivity', (c) => <String>['none']);
  on('flutter.baseflow.com/geolocator', (c) => null);
  on('plugins.flutter.io/path_provider', (c) => '/tmp');
  on('plugins.flutter.io/url_launcher', (c) => false);
  _serveGoogleFontsFromDisk();
}

/// Makes google_fonts find its fonts as bundled assets.
///
/// The brand wordmark (BrandTitle) uses GoogleFonts.poppins. In a widget test
/// there is no network, so google_fonts' download fails and the failure
/// arrives as an uncaught async error a few frames later. That fails the test
/// for a reason that has nothing to do with layout. google_fonts checks the
/// asset manifest before it tries the network, so this adds
/// `google_fonts/<Family>-<Variant>.ttf` entries to the test asset manifest
/// and serves Roboto bytes for them. The metrics are close to Poppins/Inter,
/// which also makes the width checks more realistic than the square test font.
///
/// All other asset requests are answered exactly as flutter_test does: from
/// the UNIT_TEST_ASSETS folder that `flutter test` builds.
void _serveGoogleFontsFromDisk() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final assetsDir = Platform.environment['UNIT_TEST_ASSETS'];
  final app = Platform.environment['APP_NAME'];
  final fontDir = root == null ? null : '$root/bin/cache/artifacts/material_fonts';
  const weights = {
    'Thin': 'Regular', 'ExtraLight': 'Regular', 'Light': 'Regular',
    'Regular': 'Regular', 'Medium': 'Medium', 'SemiBold': 'Medium',
    'Bold': 'Bold', 'ExtraBold': 'Black', 'Black': 'Black',
  };
  final fonts = <String, String>{}; // asset key -> Roboto file
  for (final family in const ['Poppins', 'Inter']) {
    weights.forEach((w, roboto) {
      fonts['google_fonts/$family-$w.ttf'] = 'Roboto-$roboto.ttf';
      final italic = w == 'Regular' ? 'Italic' : '${w}Italic';
      fonts['google_fonts/$family-$italic.ttf'] = 'Roboto-$roboto.ttf';
    });
  }

  File? assetFile(String key) {
    if (assetsDir == null) return null;
    var f = File('$assetsDir/$key');
    if (f.existsSync()) return f;
    final prefix = 'packages/$app/';
    if (app != null && key.startsWith(prefix)) {
      f = File('$assetsDir/${key.substring(prefix.length)}');
      if (f.existsSync()) return f;
    }
    return null;
  }

  ByteData bytes(List<int> b) => Uint8List.fromList(b).buffer.asByteData();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
    final key = utf8.decode(message!.buffer.asUint8List());
    if (key == 'AssetManifest.bin') {
      final f = assetFile(key);
      final manifest = <Object?, Object?>{};
      if (f != null) {
        final decoded = const StandardMessageCodec()
            .decodeMessage(bytes(f.readAsBytesSync()));
        if (decoded is Map) manifest.addAll(decoded);
      }
      if (fontDir != null) {
        for (final k in fonts.keys) {
          manifest[k] = [
            {'asset': k}
          ];
        }
      }
      return const StandardMessageCodec().encodeMessage(manifest);
    }
    final roboto = fonts[key];
    if (roboto != null && fontDir != null) {
      final f = File('$fontDir/$roboto');
      if (f.existsSync()) return bytes(f.readAsBytesSync());
    }
    final f = assetFile(key);
    return f == null ? null : bytes(f.readAsBytesSync());
  });
}

/// A signed-in employee (or admin) in LocalDB, so shells render their real body.
Future<Map<String, dynamic>> seedSignedInUser({bool admin = false}) async {
  mockPlatformChannels();
  SharedPreferences.setMockInitialValues({});
  await LocalDB.init();
  final user = <String, dynamic>{
    'username': admin ? 'sweep_admin' : 'sweep_emp',
    'name': admin ? 'Sweep Admin' : 'Sweep Employee',
    'pno': admin ? '900001' : '900002',
    'plant': 'Bhilai Steel Plant',
    'department': 'Blast Furnace',
    'designation': 'Senior Manager (Safety)',
    'isAdmin': admin,
    'role': admin ? 'corporate_admin' : 'employee',
    'status': 'active',
  };
  await LocalDB.setCurrentUser(user);
  return user;
}

ThemeData _theme(Brightness b) {
  final dark = b == Brightness.dark;
  final base = dark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
    colorScheme: dark
        ? const ColorScheme.dark(primary: AppColors.accent)
        : const ColorScheme.light(primary: AppColors.accent),
    textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
  );
}

/// Wraps [home] the way the real app does (theme + localisations).
Widget appHost(Widget home, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('hi')],
      home: home,
    );

/// Sets the logical window size for the rest of the test.
void setWindow(WidgetTester tester, double width, {double height = 900}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
}

/// Collects layout overflow reports ("A RenderFlex overflowed by …") and
/// unbounded-constraint failures, which are the two width bugs, and rethrows
/// nothing else. Other errors come from services with no backend in tests, and
/// are recorded separately so a real crash is still visible in the output.
class LayoutErrors {
  final overflows = <String>[];
  final other = <String>[];
  FlutterExceptionHandler? _prev; // from foundation

  void start() {
    _prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final s = details.exceptionAsString();
      if (s.contains('overflowed') ||
          s.contains('unbounded') ||
          s.contains('infinite size') ||
          s.contains('BoxConstraints forces an infinite') ||
          s.contains('was not laid out') ||
          s.contains('RenderBox was not laid out')) {
        final ctx = details.context?.toDescription() ?? '';
        final info = details.informationCollector?.call().take(3).join(' | ');
        overflows.add('${s.split('\n').first}  [$ctx]  ${info ?? ''}');
      } else {
        other.add(s.split('\n').first);
      }
    };
  }

  void stop() {
    FlutterError.onError = _prev;
  }
}

/// Unmounts the screen and runs out the clock, so timeouts the screens start
/// (network deadlines, retry back-offs) fire here and not as a "Timer is
/// still pending" failure after the test.
Future<void> drainTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 30));
  }
}

/// Pumps a few frames without waiting for settle. Several screens run a
/// repeating animation (skeleton shimmer, progress), so pumpAndSettle would
/// hang forever.
Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}
