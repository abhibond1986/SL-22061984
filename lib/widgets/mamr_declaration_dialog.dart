// lib/widgets/mamr_declaration_dialog.dart
//
// ★ 2026-10-27: "You are the MAMR of this area".
//
// Shown to a person named in a plant's MAMR register (uploaded by the admin
// or SED from Admin → MAMR Areas). Opened from two places:
//   • Home, once, for every declaration the person has not acknowledged yet
//     (covers the person who was offline or logged out when it was uploaded);
//   • the notification bell, when the person taps a declaration row.
// Pressing "Got it" marks the declarations read in the bell's per-account
// read set, so the popup does not come back.

import 'package:flutter/material.dart';

import '../main.dart' show SL;
import '../services/assignment_notifications.dart';
import '../services/mamr_service.dart';

const Color _kTeal = Color(0xFF0F766E); // kMamrColor

/// One-line text for a toast / push about [d].
String mamrDeclarationText(MamrDeclaration d) =>
    'You are declared MAMR of ${d.area.area} (${d.area.dept}, ${d.plant})';

/// Guards against two Home builds (or Home + bell) stacking the same popup.
bool _open = false;

/// Keys acknowledged this session. A bell refresh already in flight when
/// "Got it" is pressed can briefly republish them as unread; this stops that
/// stale state from popping the dialog again.
final Set<String> _acked = <String>{};

/// [fromBell]: the user tapped the row on purpose — show it even if already
/// acknowledged.
Future<void> showMamrDeclarationDialog(
    BuildContext context, List<MamrDeclaration> all,
    {bool fromBell = false}) async {
  final decls =
      fromBell ? all : all.where((d) => !_acked.contains(d.key)).toList();
  if (decls.isEmpty || _open) return;
  _open = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final sl = SL.of(ctx);
        return AlertDialog(
          icon: const Icon(Icons.verified_user_rounded, color: _kTeal, size: 40),
          title: Text(
            decls.length == 1
                ? 'You are the MAMR of this area'
                : 'You are the MAMR of ${decls.length} areas',
            textAlign: TextAlign.center,
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Area My Responsibility: you have been declared the '
                    'responsible person for the area${decls.length == 1 ? '' : 's'} '
                    'below. Observations reported in '
                    '${decls.length == 1 ? 'it' : 'them'} will come to you for action.',
                    style: TextStyle(color: sl.text2, fontSize: 13, height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  for (final d in decls)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _kTeal.withOpacity(sl.isDark ? 0.18 : 0.07),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _kTeal.withOpacity(0.35)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.place_rounded, color: _kTeal, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.area.area,
                                  style: TextStyle(
                                      color: sl.text1,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 2),
                              Text('${d.area.dept}  ·  ${d.plant}',
                                  style: TextStyle(
                                      color: sl.text3, fontSize: 12)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kTeal),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it'),
            ),
          ],
        );
      },
    );
  } finally {
    // Mark read BEFORE releasing the guard, so a refresh landing in between
    // cannot pop the same declaration a second time.
    _acked.addAll(decls.map((d) => d.key));
    try {
      await AssignmentNotifications.markDeclarationsRead(decls);
    } finally {
      _open = false;
    }
  }
}
