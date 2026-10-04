// lib/screens/admin/branding_panel.dart
//
// Admin → Company Branding. Lets an admin white-label the app for another
// company: full company name, short mark ("SAIL" in "SAIL Safety Lens") and
// logo. Saved through [Branding], which caches locally and pushes to the shared
// master_data table so every device picks it up on its next sync.

import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../../main.dart' show SL, AppColors;
import '../../services/admin_audit.dart';
import '../../services/branding.dart';

class BrandingPanel extends StatefulWidget {
  const BrandingPanel({super.key, required this.actor});

  /// Username recorded in the audit log.
  final String actor;

  @override
  State<BrandingPanel> createState() => _BrandingPanelState();
}

class _BrandingPanelState extends State<BrandingPanel> {
  static const _accent = Color(0xFF0E7490); // cyan-700 — module colour
  static const _maxUploadBytes = 8 * 1024 * 1024;

  late final TextEditingController _name;
  late final TextEditingController _short;
  Uint8List? _logo; // pending logo (null = bundled default)
  bool _saving = false;
  bool _processing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: Branding.companyName)
      ..addListener(_changed);
    _short = TextEditingController(text: Branding.shortName)
      ..addListener(_changed);
    _logo = Branding.logoBytes;
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _name.text.trim() != Branding.companyName ||
      _short.text.trim() != Branding.shortName ||
      !identical(_logo, Branding.logoBytes);

  String get _previewTitle {
    final s = _short.text.trim();
    return s.isEmpty ? Branding.productName : '$s ${Branding.productName}';
  }

  // ── logo upload ───────────────────────────────────────────────────────
  Future<void> _pickLogo() async {
    setState(() => _error = null);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      withData: true,
    );
    final bytes = res?.files.firstOrNull?.bytes;
    if (bytes == null) return; // cancelled
    if (bytes.length > _maxUploadBytes) {
      setState(() => _error = 'That file is over 8 MB. Please use a smaller image.');
      return;
    }
    setState(() => _processing = true);
    try {
      final png = _normaliseLogo(bytes);
      setState(() => _logo = png);
    } catch (_) {
      setState(() => _error =
          'Could not read that image. Use a PNG or JPG file (SVG is not supported).');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// Decodes any supported format, caps the longest edge at
  /// [Branding.maxLogoPx] and re-encodes as PNG (keeps transparency, and the
  /// PDF library embeds PNG directly).
  static Uint8List _normaliseLogo(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) throw const FormatException('undecodable');
    var im = decoded;
    final longest = im.width > im.height ? im.width : im.height;
    if (longest > Branding.maxLogoPx) {
      im = im.width >= im.height
          ? img.copyResize(im, width: Branding.maxLogoPx,
              interpolation: img.Interpolation.average)
          : img.copyResize(im, height: Branding.maxLogoPx,
              interpolation: img.Interpolation.average);
    }
    return Uint8List.fromList(img.encodePng(im, level: 6));
  }

  // ── save / reset ──────────────────────────────────────────────────────
  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Company name is required.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final before = {
      'companyName': Branding.companyName,
      'shortName': Branding.shortName,
      'customLogo': Branding.hasCustomLogo,
    };
    final pushed = await Branding.save(
      companyName: name,
      shortName: _short.text.trim(),
      logoBytes: _logo,
      updatedBy: widget.actor,
    );
    await AdminAudit.log(
      action: AdminAudit.actSettingsChange,
      actor: widget.actor,
      targetName: 'Company branding',
      meta: {
        'before': before,
        'after': {
          'companyName': name,
          'shortName': _short.text.trim(),
          'customLogo': _logo != null,
        },
        'synced': pushed,
      },
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _logo = Branding.logoBytes; // re-align identity for _dirty
    });
    _toast(pushed
        ? 'Branding saved and shared with all devices.'
        : 'Saved on this device. It will reach other devices once the backend is reachable — save again later if it does not.',
        ok: pushed);
  }

  Future<void> _reset() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset branding?'),
        content: Text('Restore "${Branding.defaultCompanyName}", '
            '"${Branding.defaultShortName}" and the default logo on every device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (sure != true) return;
    _name.text = Branding.defaultCompanyName;
    _short.text = Branding.defaultShortName;
    _logo = null;
    await _save();
  }

  void _toast(String msg, {bool ok = true}) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? const Color(0xFF15803D) : const Color(0xFFB45309),
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(sl),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= 700;
              final form = Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_identityCard(sl), const SizedBox(height: 14),
                    _logoCard(sl)]);
              final preview = _previewCard(sl);
              return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 6, child: form),
                      const SizedBox(width: 14),
                      Expanded(flex: 5, child: preview),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [form, const SizedBox(height: 14), preview]);
            }),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _banner(sl, _error!),
            ],
            const SizedBox(height: 16),
            _actions(sl),
            const SizedBox(height: 10),
            Text(
              'Applies to the app header, login and splash screens, share messages '
              'and every PDF report. The browser tab icon, Android launcher icon '
              'and install splash are built into the app and need a new release '
              'to change.',
              style: TextStyle(color: sl.text4, fontSize: 11, height: 1.45)),
          ]),
        ),
      ),
    ]);
  }

  BoxDecoration _card(SL sl) => BoxDecoration(
        color: sl.isDark ? const Color(0xFF252840) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sl.border.withOpacity(0.6)),
      );

  Widget _header(SL sl) => Container(
        padding: const EdgeInsets.all(16),
        decoration: _card(sl),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.storefront_rounded, color: _accent, size: 22)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Company branding', style: TextStyle(color: sl.text1,
                fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('Customise the company name and logo used throughout the app '
                'and on PDF reports.',
                style: TextStyle(color: sl.text3, fontSize: 12)),
          ])),
          if (!Branding.isDefault)
            _chip('Customised', _accent)
          else
            _chip('Default', sl.text3),
        ]),
      );

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
            color: c.withOpacity(0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.withOpacity(0.35))),
        child: Text(t, style: TextStyle(color: c, fontSize: 10.5,
            fontWeight: FontWeight.w700)));

  Widget _sectionTitle(SL sl, IconData icon, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Icon(icon, size: 16, color: _accent),
          const SizedBox(width: 8),
          Text(t.toUpperCase(), style: const TextStyle(color: _accent,
              fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
        ]));

  InputDecoration _input(SL sl, String label, String hint, {String? helper}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _accent, width: 1.6)),
      );

  Widget _identityCard(SL sl) => Container(
        padding: const EdgeInsets.all(16),
        decoration: _card(sl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sectionTitle(sl, Icons.badge_outlined, 'Company identity'),
          TextField(
            controller: _name,
            maxLength: 80,
            textCapitalization: TextCapitalization.words,
            decoration: _input(sl, 'Company name *',
                'e.g. Steel Authority of India Limited',
                helper: 'Printed at the top of every PDF report.'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _short,
            maxLength: 12,
            textCapitalization: TextCapitalization.characters,
            decoration: _input(sl, 'Short name', 'e.g. SAIL',
                helper: 'Shown before "Safety Lens" — the app will be called '
                    '"$_previewTitle". Leave empty for just "Safety Lens".'),
          ),
        ]),
      );

  Widget _logoCard(SL sl) => Container(
        padding: const EdgeInsets.all(16),
        decoration: _card(sl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sectionTitle(sl, Icons.image_outlined, 'Logo'),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              width: 92, height: 92,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sl.border)),
              child: _processing
                  ? const Center(child: SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4)))
                  : _logoImage(),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_logo == null ? 'Default logo' : 'Custom logo',
                  style: TextStyle(color: sl.text1, fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text('PNG or JPG, square works best. Transparent PNGs look '
                  'cleanest. Resized to ${Branding.maxLogoPx} px automatically.',
                  style: TextStyle(color: sl.text3, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: _processing || _saving ? null : _pickLogo,
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: Text(_logo == null ? 'Upload logo' : 'Replace logo')),
                if (_logo != null)
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => setState(() => _logo = null),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Use default')),
              ]),
            ])),
          ]),
        ]),
      );

  Widget _logoImage({double? size}) => _logo != null
      ? Image.memory(_logo!, width: size, height: size,
          fit: BoxFit.contain, gaplessPlayback: true)
      : Image.asset('assets/images/app_icon.png', width: size, height: size,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.shield, color: AppColors.accent));

  Widget _previewCard(SL sl) {
    final company = _name.text.trim().isEmpty
        ? 'Company name' : _name.text.trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _card(sl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionTitle(sl, Icons.visibility_outlined, 'Live preview'),
        Text('App header', style: TextStyle(color: sl.text3, fontSize: 11,
            fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: sl.isDark ? const Color(0xFF1B1D2E) : const Color(0xFFF6F7FB),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.border.withOpacity(0.6))),
          child: Row(children: [
            _logoTile(32),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_previewTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: sl.text1, fontSize: 14,
                      fontWeight: FontWeight.w800)),
              Text('AI Safety Platform',
                  style: TextStyle(color: sl.text3, fontSize: 11)),
            ])),
          ]),
        ),
        const SizedBox(height: 14),
        Text('PDF report masthead', style: TextStyle(color: sl.text3,
            fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: const Color(0xFFD97706), // a MEDIUM-risk masthead
            borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            _logo != null
                ? Container(
                    width: 34, height: 34,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: Colors.white,
                        borderRadius: BorderRadius.circular(4)),
                    child: _logoImage())
                : SizedBox(width: 34, height: 34,
                    child: Image.asset('assets/images/sail_emblem_white.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.shield, color: Colors.white))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(company.toUpperCase(), maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withOpacity(0.85),
                      fontSize: 8.5, fontWeight: FontWeight.w800,
                      letterSpacing: 1.1)),
              const SizedBox(height: 2),
              const Text('Bokaro Steel Plant', maxLines: 1,
                  style: TextStyle(color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w800)),
              const Text('Incident report  ·  Ref. INC-0001',
                  style: TextStyle(color: Colors.white70, fontSize: 9.5)),
            ])),
          ]),
        ),
        const SizedBox(height: 6),
        Text('Footer: $_previewTitle  ·  Ref. INC-0001',
            style: TextStyle(color: sl.text4, fontSize: 10.5)),
      ]),
    );
  }

  Widget _logoTile(double size) => _logo != null
      ? Container(
          width: size, height: size,
          padding: EdgeInsets.all(size * 0.08),
          decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(size * 0.2)),
          child: _logoImage())
      : _logoImage(size: size);

  Widget _banner(SL sl, String msg) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFB91C1C).withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFB91C1C).withOpacity(0.3))),
        child: Row(children: [
          const Icon(Icons.error_outline_rounded,
              color: Color(0xFFB91C1C), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(msg, style: TextStyle(
              color: sl.isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
              fontSize: 12.5))),
        ]));

  Widget _actions(SL sl) {
    final at = Branding.updatedAt;
    return Wrap(
      spacing: 10, runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _accent,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          onPressed: _saving || _processing || !_dirty ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_rounded, size: 18),
          label: Text(_saving ? 'Saving…' : 'Save branding')),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
          onPressed: _saving || Branding.isDefault ? null : _reset,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text('Reset to ${Branding.defaultShortName} default')),
        if (at != null)
          Text('Last changed ${_fmt(at)}',
              style: TextStyle(color: sl.text4, fontSize: 11)),
      ],
    );
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
               'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${m[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
  }
}
