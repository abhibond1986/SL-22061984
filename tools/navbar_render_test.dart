// Render check for the coloured bottom navigation bar (NavBarStyle).
// The two shells' _bottomNav builders are private, so this mirrors their
// layout (pill + 22px icon + 11px label) and uses the SAME NavBarStyle calls.
// Run from a project copy:  OUT=/tmp/out flutter test test/navbar_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/main.dart';
import 'package:safety_lens/widgets/nav_bar_style.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final b = File(f).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(b.buffer)));
  }
  await l.load();
}

const _items = [
  (Icons.home_outlined, Icons.home_rounded, 'Home'),
  (Icons.document_scanner_outlined, Icons.document_scanner_rounded, 'AI Scan'),
  (Icons.warning_amber_outlined, Icons.warning_amber_rounded, 'Near Miss'),
  (Icons.menu_book_outlined, Icons.menu_book_rounded, 'SOP'),
  (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Ask AI'),
  (Icons.bar_chart_outlined, Icons.bar_chart_rounded, 'Reports'),
];

Widget _bar(SL sl, int selected) => Container(
      decoration: NavBarStyle.decoration(sl),
      height: 64,
      child: Row(children: [
        for (var i = 0; i < _items.length; i++)
          Expanded(child: Builder(builder: (_) {
            final sel = i == selected;
            final it = _items[i];
            return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: NavBarStyle.pill(sl, sel),
                    borderRadius: BorderRadius.circular(20)),
                child: Icon(sel ? it.$2 : it.$1,
                    size: 22, color: NavBarStyle.icon(sl, sel)),
              ),
              const SizedBox(height: 2),
              Text(it.$3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      color: NavBarStyle.label(sl, sel))),
            ]);
          })),
      ]),
    );

void main() {
  final root = '/tmp/fl/flutter/bin/cache/artifacts/material_fonts';
  final out = Platform.environment['OUT'] ?? '/tmp/out';

  for (final dark in [false, true]) {
    for (final w in [420.0, 1000.0]) {
      testWidgets('navbar ${dark ? 'dark' : 'light'} ${w.toInt()}', (t) async {
        await t.runAsync(() async {
          await _font('Roboto', ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf',
            '$root/Roboto-Bold.ttf']);
          await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
        });
        t.view.physicalSize = Size(w, 220);
        t.view.devicePixelRatio = 1;
        final key = GlobalKey();
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: 'Roboto'),
          home: RepaintBoundary(
            key: key,
            child: Builder(builder: (ctx) {
              final sl = SL.of(ctx);
              return Scaffold(
                backgroundColor: dark ? const Color(0xFF0D1117) : const Color(0xFFF4F6FB),
                body: Center(child: Text('page content',
                    style: TextStyle(color: sl.text3))),
                bottomNavigationBar: _bar(sl, 1),
              );
            }),
          ),
        ));
        await t.pumpAndSettle();
        expect(tester_takeException(t), isNull);
        await t.runAsync(() async {
          final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await ro.toImage();
          final bd = await img.toByteData(format: ui.ImageByteFormat.png);
          File('$out/navbar_${dark ? 'dark' : 'light'}_${w.toInt()}.png')
              .writeAsBytesSync(bd!.buffer.asUint8List());
        });
        t.view.resetPhysicalSize();
      });
    }
  }
}

Object? tester_takeException(WidgetTester t) => t.takeException();
