// Render check for Admin → Company Branding (default + custom brand), the
// branded app chrome, and the PDF masthead with a custom logo.
// Run from a project copy:  OUT=/tmp/out flutter test test/branding_render_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
// BrandTitle uses google_fonts (network) — not renderable offline; the
// same Branding.appTitle text is drawn with Roboto instead.
import 'package:safety_lens/main.dart' show SailLogoTile;
import 'package:safety_lens/screens/admin/branding_panel.dart';
import 'package:safety_lens/services/branding.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/pdf_export.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

/// A stand-in third-party logo: navy disc, orange ring, "AC" mark.
Uint8List _fakeLogo() {
  final im = img.Image(width: 300, height: 300, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
  img.fillCircle(im, x: 150, y: 150, radius: 140, color: img.ColorRgba8(234, 88, 12, 255));
  img.fillCircle(im, x: 150, y: 150, radius: 118, color: img.ColorRgba8(30, 58, 138, 255));
  img.drawString(im, 'ACME', font: img.arial48, x: 92, y: 124,
      color: img.ColorRgba8(255, 255, 255, 255));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  Future<void> shoot(WidgetTester t, Size size, String name, Widget home,
      {bool dark = false}) async {
    await t.runAsync(() async {
      await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
        '$root/Roboto-Bold.ttf', '$root/Roboto-Black.ttf']);
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
    });
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    final key = GlobalKey();
    await t.runAsync(() async {
      await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(body: home),
      )));
      for (var i = 0; i < 8; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        await t.pump(const Duration(milliseconds: 100));
      }
      final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await ro.toImage(pixelRatio: 1.0);
      final bd = await im.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bd!.buffer.asUint8List());
    });
    await t.pumpWidget(const SizedBox());
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'current_user': jsonEncode({'username': 'abhin', 'name': 'Abhinav Kumar',
        'pno': '22061984', 'plant': 'SSO Ranchi', 'isAdmin': true}),
    });
    await LocalDB.init();
  });

  testWidgets('panel default', (t) async {
    await Branding.resetToDefault();
    await shoot(t, const Size(1100, 820), 'branding_panel_default',
        const BrandingPanel(actor: 'abhin'));
  });

  testWidgets('panel custom + chrome', (t) async {
    await t.runAsync(() => Branding.save(
        companyName: 'Acme Metals & Mining Corporation',
        shortName: 'ACME', logoBytes: _fakeLogo()));
    await shoot(t, const Size(1100, 820), 'branding_panel_custom',
        const BrandingPanel(actor: 'abhin'));
    await shoot(t, const Size(520, 200), 'branding_chrome_custom',
        const Padding(padding: EdgeInsets.all(24), child: Row(children: [
          SailLogoTile(size: 44), SizedBox(width: 12), _Title(),
        ])), dark: true);
    expect(Branding.appTitle, 'ACME Safety Lens');
  });

  testWidgets('pdf custom', (t) async {
    await t.runAsync(() async {
      await Branding.save(companyName: 'Acme Metals & Mining Corporation',
          shortName: 'ACME', logoBytes: _fakeLogo());
      final bytes = await PdfExport.generateIncidentReportBytes(incident: {
        'id': 'INC-20260926-0042', 'title': 'Trip hazard on walkway',
        'severity': 'MEDIUM', 'riskScore': 30, 'status': 'OPEN', 'type': 'AI_SCAN',
        'plant': 'BSL', 'dept': 'Maintenance', 'location': 'Bay 3',
        'date': '2026-09-26T10:15:00', 'reportedBy': 'Abhishek Kumar',
        'desc': 'Loose hoses across the walkway.', 'hazards': [
          {'name': 'Trip hazard', 'severity': 'MEDIUM', 'description': 'Hoses on path.'}],
      }, reporterName: Branding.defaultReporter);
      Directory(out).createSync(recursive: true);
      File('$out/branding_report.pdf').writeAsBytesSync(bytes);
    });
  });
}

class _Title extends StatelessWidget {
  const _Title();
  @override
  Widget build(BuildContext context) => Text(Branding.appTitle,
      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900,
          color: Colors.white));
}
