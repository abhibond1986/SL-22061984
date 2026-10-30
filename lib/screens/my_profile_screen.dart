// lib/screens/my_profile_screen.dart
//
// MY PROFILE: the signed-in user's own page (2026-10-30, owner request).
//
//  * Contact and job details the user may correct themselves: mobile, email,
//    designation, department, unit. Name, P.No, grade and plant stay with the
//    HR import / admin and are shown read-only.
//    Saved with SupabaseService.updateOwnProfile (an UPDATE of those columns
//    only) and marked in `self_edited_fields`, so the quarterly import keeps
//    the user's value (UserImportRunner).
//  * Device permissions: camera, microphone, location. Shows what the device
//    or browser currently allows, and the user's own on/off choice
//    (DevicePermissions). This is where the one-time post-login answer is
//    changed later.
//
// Contractor sessions have no account, so they only see the permissions part.
//
// Not to be confused with EmployeeProfileScreen, the admin's read-only view
// of any employee.

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/admin_master_data.dart';
import '../services/device_permissions.dart';
import '../services/i18n.dart';
import '../services/local_db.dart';
import '../services/supabase_service.dart';
import '../services/validators.dart';
import '../widgets/content_width.dart';

/// Bumped when the signed-in user's own record changes, so shells holding a
/// copy of it (HomeScreen) can reload.
final ValueNotifier<int> currentUserRevision = ValueNotifier<int>(0);

class MyProfileScreen extends StatefulWidget {
  final Map<String, dynamic>? user;
  const MyProfileScreen({super.key, this.user});

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _c = {
    for (final f in SupabaseService.kSelfEditableFields) f: TextEditingController(),
  };
  Map<String, dynamic> _u = {};
  List<String> _departments = const [];
  final Map<DeviceFeature, PermissionState> _state = {};
  bool _saving = false;
  bool _dirty = false;

  String get _uname => (_u['username']?.toString() ?? '').trim().toLowerCase();
  bool get _isContractor =>
      _u['role']?.toString() == 'contractor' || _uname == 'contractor';

  @override
  void initState() {
    super.initState();
    _u = Map<String, dynamic>.from(widget.user ?? const {});
    _fill();
    for (final c in _c.values) {
      c.addListener(_onEdit);
    }
    _load();
    DevicePermissions.revision.addListener(_refreshPermissions);
  }

  @override
  void dispose() {
    DevicePermissions.revision.removeListener(_refreshPermissions);
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill() {
    for (final f in SupabaseService.kSelfEditableFields) {
      _c[f]!.text = _u[f]?.toString() ?? '';
    }
    _dirty = false;
  }

  void _onEdit() {
    final d = SupabaseService.kSelfEditableFields
        .any((f) => _c[f]!.text.trim() != (_u[f]?.toString() ?? '').trim());
    if (d != _dirty) setState(() => _dirty = d);
  }

  Future<void> _load() async {
    final cur = await LocalDB.getCurrentUser();
    if (cur != null && widget.user == null) {
      _u = Map<String, dynamic>.from(cur);
      _fill();
    }
    await DevicePermissions.loadFor(_uname.isEmpty ? 'contractor' : _uname);
    try {
      _departments = await AdminMasterData.getDepartments();
    } catch (_) {}
    if (mounted) setState(() {});
    await _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    for (final f in DeviceFeature.values) {
      _state[f] = await DevicePermissions.status(f);
    }
    if (mounted) setState(() {});
  }

  // ── save ────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final changed = <String, dynamic>{};
    for (final f in SupabaseService.kSelfEditableFields) {
      final v = _c[f]!.text.trim();
      if (v != (_u[f]?.toString() ?? '').trim()) changed[f] = v;
    }
    if (changed.isEmpty) return;
    setState(() => _saving = true);

    final edited = <String>{
      ...(_u['selfEditedFields']?.toString() ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty),
      ...changed.keys,
    };
    final ok = await SupabaseService.updateOwnProfile(_uname, changed, edited);
    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      _snack(I18n.t('profile.saveFailed',
          args: {'err': SupabaseService.usersLastError}), error: true);
      return;
    }
    final updated = <String, dynamic>{
      ..._u,
      ...changed,
      'selfEditedFields': (edited.toList()..sort()).join(','),
    };
    // The device copies: the session user (app bar, near-miss defaults) and
    // the user directory.
    await LocalDB.setCurrentUser(updated);
    await LocalDB.upsertUser(updated);
    currentUserRevision.value++;
    if (!mounted) return;
    setState(() {
      _u = updated;
      _saving = false;
      _fill();
    });
    _snack(SupabaseService.selfEditUnprotected
        ? I18n.t('profile.savedUnprotected')
        : I18n.t('profile.saved'));
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? AppColors.red : null,
      content: Text(msg),
    ));
  }

  // ── permissions ─────────────────────────────────────────────────────────
  Future<void> _toggle(DeviceFeature f, bool on) async {
    await DevicePermissions.setEnabled(f, on);
    if (on) {
      final s = await DevicePermissions.request(f);
      if (s == PermissionState.blocked && mounted) {
        await DevicePermissions.showBlockedHelp(context, f);
      }
    }
    await _refreshPermissions();
  }

  // ── ui ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      appBar: AppBar(
        backgroundColor: sl.card,
        foregroundColor: sl.text1,
        elevation: 0,
        title: Text(I18n.t('profile.title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            ContentWidth(
              maxWidth: 680,
              fillHeight: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(sl),
                  const SizedBox(height: 14),
                  if (!_isContractor) ...[
                    _card(sl, I18n.t('profile.fromHr'), Icons.badge_outlined,
                        _readOnly(sl)),
                    const SizedBox(height: 14),
                    _card(sl, I18n.t('profile.yourDetails'),
                        Icons.edit_note_rounded, _editForm(sl)),
                    const SizedBox(height: 14),
                  ],
                  _card(sl, I18n.t('perm.section'),
                      Icons.verified_user_outlined, _permissions(sl)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(SL sl) {
    final name = _u['name']?.toString() ?? '';
    return Row(children: [
      Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4F5BD5), Color(0xFF0EA5B5)]),
        ),
        child: Center(
          child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800)),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.isEmpty ? 'User' : name,
              style: TextStyle(
                  color: sl.text1, fontSize: 18, fontWeight: FontWeight.w700)),
          if ((_u['designation']?.toString() ?? '').isNotEmpty)
            Text(_u['designation'].toString(),
                style: TextStyle(color: sl.text3, fontSize: 13)),
        ]),
      ),
    ]);
  }

  Widget _card(SL sl, String title, IconData icon, Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sl.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 18, color: sl.accentText),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      );

  Widget _readOnly(SL sl) {
    Widget row(String label, String? v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 120,
              child: Text(label,
                  style: TextStyle(color: sl.text3, fontSize: 12.5)),
            ),
            Expanded(
              child: Text((v ?? '').trim().isEmpty ? '-' : v!.trim(),
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row(I18n.t('profile.name'), _u['name']?.toString()),
      row(I18n.t('profile.pno'), _u['pno']?.toString()),
      row(I18n.t('profile.grade'), _u['grade']?.toString()),
      row(I18n.t('profile.plant'), _u['plant']?.toString()),
      const SizedBox(height: 6),
      Text(I18n.t('profile.fromHrNote'),
          style: TextStyle(color: sl.text4, fontSize: 11.5, height: 1.35)),
    ]);
  }

  InputDecoration _dec(SL sl, String label, IconData icon, {Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 19),
        suffixIcon: suffix,
        isDense: true,
        counterText: '',
        filled: true,
        fillColor: sl.isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.grey.withOpacity(0.06),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  Widget _editForm(SL sl) {
    final style = TextStyle(color: sl.text1, fontSize: 14);
    Widget gap() => const SizedBox(height: 12);
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextFormField(
          controller: _c['mobile'],
          style: style,
          keyboardType: TextInputType.phone,
          autocorrect: false,
          enableSuggestions: false,
          decoration: _dec(sl, I18n.t('profile.mobile'), Icons.phone_outlined),
          validator: (v) => (v ?? '').trim().isEmpty
              ? null
              : Validators.validatePhone(
                  v!.replaceAll(RegExp(r'[\s-]'), '').replaceFirst(
                      RegExp(r'^(\+91|0)'), '')),
        ),
        gap(),
        TextFormField(
          controller: _c['email'],
          style: style,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          decoration: _dec(sl, I18n.t('profile.email'), Icons.mail_outline),
          validator: (v) => (v ?? '').trim().isEmpty
              ? null
              : Validators.validateEmail(v!.trim()),
        ),
        gap(),
        TextFormField(
          controller: _c['designation'],
          style: style,
          maxLength: 100,
          decoration: _dec(
              sl, I18n.t('profile.designation'), Icons.work_outline),
        ),
        gap(),
        TextFormField(
          controller: _c['department'],
          style: style,
          maxLength: 100,
          decoration: _dec(
            sl,
            I18n.t('profile.department'),
            Icons.apartment_outlined,
            suffix: _departments.isEmpty
                ? null
                : PopupMenuButton<String>(
                    tooltip: I18n.t('profile.pickDepartment'),
                    icon: const Icon(Icons.arrow_drop_down_rounded),
                    onSelected: (d) => _c['department']!.text = d,
                    itemBuilder: (_) => [
                      for (final d in _departments)
                        PopupMenuItem(value: d, child: Text(d)),
                    ],
                  ),
          ),
        ),
        gap(),
        TextFormField(
          controller: _c['unit'],
          style: style,
          maxLength: 100,
          decoration:
              _dec(sl, I18n.t('profile.unit'), Icons.factory_outlined),
        ),
        const SizedBox(height: 4),
        Text(I18n.t('profile.keptNote'),
            style: TextStyle(color: sl.text4, fontSize: 11.5, height: 1.35)),
        const SizedBox(height: 12),
        Row(children: [
          if (_dirty)
            TextButton(
              onPressed: _saving ? null : () => setState(_fill),
              child: Text(I18n.t('common.cancel')),
            ),
          const Spacer(),
          FilledButton.icon(
            onPressed: (_dirty && !_saving) ? _save : null,
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(I18n.t('common.save')),
          ),
        ]),
      ]),
    );
  }

  Widget _permissions(SL sl) {
    Color stateColor(PermissionState? s) => switch (s) {
          PermissionState.allowed => sl.greenText,
          PermissionState.blocked || PermissionState.denied => sl.redText,
          _ => sl.text3,
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final f in DeviceFeature.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: sl.isDark
                    ? Colors.white.withOpacity(0.06)
                    : Colors.grey.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(DevicePermissions.icon(f), size: 19, color: sl.text2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(DevicePermissions.title(f),
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      _state[f] == null
                          ? '...'
                          : I18n.t('perm.deviceSays', args: {
                              'state': DevicePermissions.stateLabel(_state[f]!)
                            }),
                      style: TextStyle(color: stateColor(_state[f]), fontSize: 12),
                    ),
                  ]),
            ),
            Switch(
              value: DevicePermissions.isEnabled(f),
              activeColor: AppColors.accent,
              onChanged: (v) => _toggle(f, v),
            ),
          ]),
        ),
      const SizedBox(height: 8),
      Text(
          I18n.t(DevicePermissions.isWeb ? 'perm.helpWeb' : 'perm.helpApp'),
          style: TextStyle(color: sl.text4, fontSize: 11.5, height: 1.35)),
      if (!DevicePermissions.isWeb) ...[
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: DevicePermissions.openSettings,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: Text(I18n.t('perm.openSettings')),
          ),
        ),
      ],
    ]);
  }
}
