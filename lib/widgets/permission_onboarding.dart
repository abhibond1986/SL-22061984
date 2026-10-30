// lib/widgets/permission_onboarding.dart
//
// The one-time "Allow camera, microphone and location" sheet shown right
// after login. See DevicePermissions for what is stored and why it is shown
// only once per user per device.

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/device_permissions.dart';
import '../services/i18n.dart';

class PermissionOnboarding {
  PermissionOnboarding._();

  static bool _showing = false;

  /// Tests only: forget a sheet that a previous test left open.
  @visibleForTesting
  static void debugReset() => _showing = false;

  /// Show the sheet if [username] has not answered it on this device yet.
  /// Safe to call on every login and every home-screen build.
  static Future<void> maybeShow(BuildContext context, String username) async {
    if (_showing || username.trim().isEmpty) return;
    await DevicePermissions.loadFor(username);
    if (DevicePermissions.answered || !context.mounted) return;

    // Already allowed everywhere (e.g. granted before this feature existed):
    // record that silently instead of asking a question with no purpose.
    final states = <DeviceFeature, PermissionState>{
      for (final f in DeviceFeature.values) f: await DevicePermissions.status(f),
    };
    if (states.values.every((s) => s == PermissionState.allowed)) {
      await DevicePermissions.recordAnswers(
          {for (final f in DeviceFeature.values) f: true});
      return;
    }
    if (!context.mounted) return;

    _showing = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: SL.of(context).card,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _OnboardingSheet(initial: states),
      );
    } finally {
      _showing = false;
    }
  }
}

class _OnboardingSheet extends StatefulWidget {
  final Map<DeviceFeature, PermissionState> initial;
  const _OnboardingSheet({required this.initial});

  @override
  State<_OnboardingSheet> createState() => _OnboardingSheetState();
}

class _OnboardingSheetState extends State<_OnboardingSheet> {
  late final Map<DeviceFeature, bool> _want = {
    for (final f in DeviceFeature.values) f: true,
  };
  bool _busy = false;

  Future<void> _continue() async {
    setState(() => _busy = true);
    final blocked = <DeviceFeature>[];
    for (final f in DeviceFeature.values) {
      if (_want[f] != true) continue;
      if (widget.initial[f] == PermissionState.allowed) continue;
      // One system prompt at a time, in order.
      final s = await DevicePermissions.request(f);
      if (s == PermissionState.blocked) blocked.add(f);
    }
    await DevicePermissions.recordAnswers(Map.of(_want));
    if (!mounted) return;
    Navigator.pop(context);
    if (blocked.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(I18n.t('perm.someBlocked', args: {
          'list': blocked.map(DevicePermissions.title).join(', '),
        })),
      ));
    }
  }

  Future<void> _notNow() async {
    await DevicePermissions.recordAnswers(
        {for (final f in DeviceFeature.values) f: false});
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: sl.border,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 18),
                Row(children: [
                  Icon(Icons.verified_user_outlined,
                      color: sl.accentText, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(I18n.t('perm.sheetTitle'),
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(I18n.t('perm.sheetBody'),
                    style:
                        TextStyle(color: sl.text2, fontSize: 13, height: 1.4)),
                const SizedBox(height: 14),
                for (final f in DeviceFeature.values) _row(sl, f),
                const SizedBox(height: 10),
                Text(I18n.t('perm.sheetFoot'),
                    style:
                        TextStyle(color: sl.text3, fontSize: 12, height: 1.4)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _notNow,
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46)),
                      child: Text(I18n.t('perm.notNow')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _continue,
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(46)),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(I18n.t('perm.continue')),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(SL sl, DeviceFeature f) {
    final already = widget.initial[f] == PermissionState.allowed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: sl.isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.grey.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        child: CheckboxListTile(
          value: _want[f],
          onChanged: _busy ? null : (v) => setState(() => _want[f] = v ?? false),
          activeColor: AppColors.accent,
          controlAffinity: ListTileControlAffinity.trailing,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          secondary: Icon(DevicePermissions.icon(f), color: sl.text2),
          title: Text(DevicePermissions.title(f),
              style: TextStyle(
                  color: sl.text1, fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text(
              already
                  ? I18n.t('perm.alreadyAllowed')
                  : DevicePermissions.purpose(f),
              style: TextStyle(color: sl.text3, fontSize: 12)),
        ),
      ),
    );
  }
}
