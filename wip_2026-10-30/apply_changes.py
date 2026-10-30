#!/usr/bin/env python3
"""Apply the 2026-10-30 changes (Hindi PDF, one-time permissions, My Profile)
to a checkout of SL-22061984. Usage: python3 apply_changes.py <repo_dir>
Idempotent: each edit is skipped if already applied."""
import os, shutil, sys

R = sys.argv[1]
OUT = os.path.dirname(os.path.abspath(__file__))


def P(rel):
    return os.path.join(R, rel)


def edit(rel, old, new, marker=None):
    p = P(rel)
    s = open(p, encoding='utf-8').read()
    if (marker or new) in s:
        return
    assert s.count(old) == 1, (rel, old[:80], s.count(old))
    s = s.replace(old, new)
    open(p, 'w', encoding='utf-8', newline='\n').write(s)


def add_import(rel, after, imp):
    p = P(rel)
    s = open(p, encoding='utf-8').read()
    if imp in s:
        return
    i = s.index(after)
    j = s.index('\n', i) + 1
    s = s[:j] + imp + '\n' + s[j:]
    open(p, 'w', encoding='utf-8', newline='\n').write(s)


# ── new files ────────────────────────────────────────────────────────────
for f in ['pdf_text.dart', 'pdf_text_raster_io.dart', 'pdf_text_raster_web.dart',
          'device_permissions.dart', 'device_permissions_io.dart',
          'device_permissions_web.dart']:
    shutil.copyfile(os.path.join(OUT, f), P('lib/services/' + f))
shutil.copyfile(os.path.join(OUT, 'permission_onboarding.dart'),
                P('lib/widgets/permission_onboarding.dart'))
shutil.copyfile(os.path.join(OUT, 'my_profile_screen.dart'),
                P('lib/screens/my_profile_screen.dart'))
os.makedirs(P('assets/fonts'), exist_ok=True)
for f in ['NotoSansDevanagari-Regular.ttf', 'NotoSansDevanagari-Bold.ttf',
          'OFL.txt']:
    src = os.path.join(OUT, 'fonts', f)
    if os.path.exists(src):
        shutil.copyfile(src, P('assets/fonts/' + f))
for f in ['pdf_hindi_test.dart', 'profile_permissions_render_test.dart']:
    src = os.path.join(OUT, f)
    if os.path.exists(src):
        shutil.copyfile(src, P('tools/' + f))
shutil.copyfile(os.path.join(OUT, 'migration_profile_self_edit.sql'),
                P('migration_profile_self_edit.sql'))

# ── pubspec ──────────────────────────────────────────────────────────────
edit('pubspec.yaml', "  assets:\n    - assets/images/\n",
     "  assets:\n    - assets/images/\n    # Noto Sans Devanagari (SIL OFL) for Hindi text in PDF reports - see\n"
     "    # lib/services/pdf_text.dart.\n    - assets/fonts/\n", marker='- assets/fonts/')

# ── pdf_export ───────────────────────────────────────────────────────────
pe = 'lib/services/pdf_export.dart'
edit(pe, "import 'package:pdf/widgets.dart' as pw;\n",
     """// `hide Text` + pdf_text.dart under the same prefix: every pw.Text(...) below
// goes through pdf_text.dart, which prints Hindi (and any non-Latin script)
// correctly shaped instead of failing on Helvetica. See that file.
import 'package:pdf/widgets.dart' as pw hide Text;
import 'pdf_text.dart' as pw show Text;
import 'pdf_text.dart' show PdfScript;
""", marker="import 'pdf_text.dart' show PdfScript;")
edit(pe, """  static Future<Uint8List> generateIncidentReportBytes({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
    Uint8List? imageBytes,
  }) async {
""", """  static Future<Uint8List> generateIncidentReportBytes({
    required Map<String, dynamic> incident,
    String reporterName = 'SAIL Safety Officer',
    String reporterPno = '',
    Uint8List? imageBytes,
  }) =>
      // ★ 2026-10-30: built through PdfScript.run so Hindi text is shaped and
      // printed (a second pass only when the report has non-Latin text).
      PdfScript.run(() => _incidentReportBytes(
            incident: incident,
            reporterName: reporterName,
            reporterPno: reporterPno,
            imageBytes: imageBytes,
          ));

  static Future<Uint8List> _incidentReportBytes({
    required Map<String, dynamic> incident,
    required String reporterName,
    required String reporterPno,
    Uint8List? imageBytes,
  }) async {
""", marker='static Future<Uint8List> _incidentReportBytes(')
edit(pe, """    DateTime? toDate,
  }) async {
    final pdf   = pw.Document();
    final now   = DateTime.now();""", """    DateTime? toDate,
  }) async {
    final now = DateTime.now();
    // ★ 2026-10-30: built through PdfScript.run (see pdf_text.dart) so Hindi
    // descriptions print instead of failing on the Latin-1 font.
    final bytes = await PdfScript.run(() => _consolidatedBytes(
        incidents: incidents, reporterName: reporterName,
        reportTitle: reportTitle, plant: plant,
        fromDate: fromDate, toDate: toDate, now: now));
    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/SafetyLens_Consolidated_'
        '${DateFormat('yyyyMMdd').format(now)}.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<Uint8List> _consolidatedBytes({
    required List<Map<String, dynamic>> incidents,
    required String reporterName,
    String? reportTitle,
    String? plant,
    DateTime? fromDate,
    DateTime? toDate,
    required DateTime now,
  }) async {
    final pdf   = pw.Document();""", marker='static Future<Uint8List> _consolidatedBytes(')
_s = open(P(pe), encoding='utf-8').read()
_old_tail = """    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/SafetyLens_Consolidated_'
        '${DateFormat('yyyyMMdd').format(now)}.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }"""
if _old_tail in _s:
    assert _s.count(_old_tail) == 1
    _s = _s.replace(_old_tail, """    return pdf.save();
  }""")
    open(P(pe), 'w', encoding='utf-8', newline='\n').write(_s)

# ── supabase_service ─────────────────────────────────────────────────────
ss = 'lib/services/supabase_service.dart'
edit(ss, """    'updatedAt': 'updated_at',
  };""", """    'updatedAt': 'updated_at',
    // ── Self-service profile (migration_profile_self_edit.sql, 2026-10-30) ──
    // Comma-separated app keys the account holder edited in My Profile. The
    // quarterly import keeps those values instead of overwriting them.
    'selfEditedFields': 'self_edited_fields',
    'selfEditedAt': 'self_edited_at',
  };""", marker="'selfEditedFields': 'self_edited_fields',")
edit(ss, "  /// Look up one user by username (for cross-device login).",
     open(os.path.join(OUT, 'snippet_supabase_profile.dart'), encoding='utf-8').read()
     + "  /// Look up one user by username (for cross-device login).",
     marker='static Future<bool> updateOwnProfile(')

# ── user_import_runner ───────────────────────────────────────────────────
ur = 'lib/services/user_import_runner.dart'
edit(ur, """      final rows = updates
          .map((r) => <String, dynamic>{...r.user, 'importedAt': now})
          .toList(growable: false);""", """      // ★ 2026-10-30: fields an employee corrected in My Profile are kept.
      // Every row keeps the same keys (a PostgREST bulk-upsert rule); for
      // those people the file's value is replaced by their own current value.
      final selfEdited = await SupabaseService.fetchSelfEditedProfiles();
      if (selfEdited == null) {
        errors.add('Could not read which employees edited their own profile, '
            'so their mobile/email/designation/department/unit may have been '
            'replaced by the file. ${SupabaseService.usersLastError}');
      }
      final rows = updates.map((r) {
        final row = <String, dynamic>{...r.user, 'importedAt': now};
        final uname = (r.user['username']?.toString() ?? '').toLowerCase();
        final own = selfEdited?[uname];
        if (own != null) {
          own.forEach((k, v) {
            if (row.containsKey(k)) row[k] = v;
          });
          keptSelfEdited++;
        }
        return row;
      }).toList(growable: false);""", marker='fetchSelfEditedProfiles()')
edit(ur, """    var updated = 0;
    final updates = plan.updates.toList(growable: false);""", """    var updated = 0;
    var keptSelfEdited = 0;
    final updates = plan.updates.toList(growable: false);""", marker='var keptSelfEdited = 0;')
edit(ur, """      errors: errors,
      batchId: plan.batchId,
    );
  }
""", """      errors: errors,
      batchId: plan.batchId,
      keptSelfEdited: keptSelfEdited,
    );
  }
""", marker='keptSelfEdited: keptSelfEdited,')
edit(ur, """    required this.batchId,
  });""", """    required this.batchId,
    this.keptSelfEdited = 0,
  });

  /// Existing employees whose own My Profile edits were kept over the file.
  final int keptSelfEdited;""", marker='this.keptSelfEdited = 0,')
edit(ur, """    if (skipped > 0) parts.add('$skipped skipped');
""", """    if (skipped > 0) parts.add('$skipped skipped');
    if (keptSelfEdited > 0) {
      parts.add('$keptSelfEdited kept their own profile edits');
    }
""", marker='kept their own profile edits')

# ── i18n ─────────────────────────────────────────────────────────────────
i18 = 'lib/services/i18n.dart'
s = open(P(i18), encoding='utf-8').read()
if "'perm.camera'" not in s:
    en = open(os.path.join(OUT, 'snippet_i18n_en.txt'), encoding='utf-8').read()
    hi = open(os.path.join(OUT, 'snippet_i18n_hi.txt'), encoding='utf-8').read()

    def ins(s, start_pat, block):
        start = s.index(start_pat)
        end = s.index("\n  };", start)
        return s[:end] + "\n" + block.rstrip("\n") + s[end:]
    s = ins(s, "  static const Map<String, String> _hi = {", hi)
    s = ins(s, "  static const Map<String, String> _en = {", en)
    open(P(i18), 'w', encoding='utf-8', newline='\n').write(s)

# ── home_screen ──────────────────────────────────────────────────────────
hs = 'lib/screens/home_screen.dart'
edit(hs, "import '../widgets/safe_backdrop_filter.dart';\n",
     "import '../widgets/safe_backdrop_filter.dart';\nimport '../widgets/permission_onboarding.dart';\n"
     "import 'my_profile_screen.dart' show currentUserRevision;\n",
     marker="import '../widgets/permission_onboarding.dart';")
edit(hs, """    AdminMasterData.revision.addListener(_onMasterDataChanged);
  }
""", """    AdminMasterData.revision.addListener(_onMasterDataChanged);
    // ★ 2026-10-30: My Profile edits refresh the copy this shell hands out.
    currentUserRevision.addListener(_reloadUser);
  }

  Future<void> _reloadUser() async {
    final u = await LocalDB.getCurrentUser();
    if (mounted) setState(() => _user = u);
  }
""", marker='currentUserRevision.addListener(_reloadUser);')
edit(hs, """    AdminMasterData.revision.removeListener(_onMasterDataChanged);
    _tabAnim.dispose();""", """    AdminMasterData.revision.removeListener(_onMasterDataChanged);
    currentUserRevision.removeListener(_reloadUser);
    _tabAnim.dispose();""", marker='currentUserRevision.removeListener(_reloadUser);')
edit(hs, """    final u = await LocalDB.getCurrentUser();
    if (mounted) setState(() => _user = u);
    // ★ 2026-10-27""", """    final u = await LocalDB.getCurrentUser();
    if (mounted) setState(() => _user = u);
    // ★ 2026-10-30: the one-time camera / microphone / location request.
    // Shown only until this user has answered it on this device; the answer
    // can be changed later in My Profile. After the first frame so the shell
    // is on screen behind the sheet.
    final uname = (u?['username'] ?? u?['pno'] ?? '').toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PermissionOnboarding.maybeShow(context, uname);
    });
    // ★ 2026-10-27""", marker='PermissionOnboarding.maybeShow(context, uname)')

# ── contractor_home_screen ───────────────────────────────────────────────
ch = 'lib/screens/contractor_home_screen.dart'
edit(ch, "import '../widgets/safe_backdrop_filter.dart';\n",
     "import '../widgets/safe_backdrop_filter.dart';\nimport '../widgets/permission_onboarding.dart';\n"
     "import '../services/i18n.dart';\nimport 'my_profile_screen.dart';\n",
     marker="import '../widgets/permission_onboarding.dart';")
edit(ch, """  void _exitToLogin() {""", """  @override
  void initState() {
    super.initState();
    // ★ 2026-10-30: one-time camera / mic / location request for this device's
    // contractor session (there is no account, so it is keyed 'contractor').
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PermissionOnboarding.maybeShow(context, 'contractor');
    });
  }

  void _exitToLogin() {""", marker="PermissionOnboarding.maybeShow(context, 'contractor')")
edit(ch, """          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,""", """          IconButton(
            icon: Icon(Icons.verified_user_outlined, color: sl.text3, size: 20),
            tooltip: I18n.t('perm.section'),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => MyProfileScreen(user: _contractorUser))),
          ),
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,""",
     marker='MyProfileScreen(user: _contractorUser)')

# ── universal_app_bar: My Profile row ────────────────────────────────────
ua = 'lib/widgets/universal_app_bar.dart'
edit(ua, """                // ── SETTINGS ROWS ──
                _menuRow(""", """                // ── SETTINGS ROWS ──
                // ★ 2026-10-30: My Profile - own contact/job details and the
                // camera / microphone / location choices.
                _menuRow(
                  icon: Icons.person_outline_rounded,
                  label: I18n.t('profile.open'),
                  trailing: Icon(Icons.chevron_right_rounded,
                      color: sl.text3, size: 20),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(context, MaterialPageRoute(
                        builder: (_) => MyProfileScreen(user: widget.user)));
                  },
                  sl: sl,
                ),
                const SizedBox(height: 4),
                _menuRow(""", marker="label: I18n.t('profile.open'),")
add_import(ua, "import 'package:flutter/material.dart';",
           "import '../screens/my_profile_screen.dart';")

# ── camera guards ────────────────────────────────────────────────────────
G = """    // ★ 2026-10-30: respect the user's camera choice (My Profile).
    if (source == ImageSource.camera &&
        !await DevicePermissions.guard(context, DeviceFeature.camera)) {
      return;
    }
"""
edit('lib/screens/near_miss_tab.dart', """      _snack(ScanJobs.busyMessage(), const Color(0xFFD97706));
      return;
    }
    final picker = ImagePicker();""", """      _snack(ScanJobs.busyMessage(), const Color(0xFFD97706));
      return;
    }
""" + G + """    final picker = ImagePicker();""")
edit('lib/screens/incident_detail_screen.dart', """    if (source == null || !mounted) return;
    XFile? f;""", """    if (source == null || !mounted) return;
""" + G + """    XFile? f;""")
edit('lib/screens/sop_scan_screen.dart', """  Future<void> _addPages(ImageSource source) async {
""", """  Future<void> _addPages(ImageSource source) async {
""" + G)
edit('lib/screens/sop_scan_screen.dart', """  Future<void> _retake(int index) async {
""", """  Future<void> _retake(int index) async {
    if (!await DevicePermissions.guard(context, DeviceFeature.camera)) return;
""")
edit('lib/screens/ai_scan_tab.dart', """    final picker = ImagePicker();
    final bool isGallery = source == ImageSource.gallery;""", G + """    final picker = ImagePicker();
    final bool isGallery = source == ImageSource.gallery;""")
edit('lib/screens/ai_scan_tab.dart', """  Future<void> _pickManualPhoto(ImageSource source) async {
""", """  Future<void> _pickManualPhoto(ImageSource source) async {
""" + G)

# ── microphone guards ────────────────────────────────────────────────────
M = """    // ★ 2026-10-30: respect the user's microphone choice (My Profile).
    if (!await DevicePermissions.guard(context, DeviceFeature.microphone)) {
      return;
    }
    if (!mounted) return;
"""
edit('lib/screens/near_miss_tab.dart', """      await current.end(DictationEnd.switchedField);
    }

    if (!_speechAvailable) {""", """      await current.end(DictationEnd.switchedField);
    }

""" + M + """    if (!_speechAvailable) {""")
edit('lib/widgets/voice_text_field.dart', """      _finish();
      return;
    }

    if (!_speechAvailable) {""", """      _finish();
      return;
    }

""" + M + """    if (!_speechAvailable) {""")

for rel, after, imp in [
    ('lib/screens/near_miss_tab.dart', "import 'package:flutter/material.dart';", "import '../services/device_permissions.dart';"),
    ('lib/screens/incident_detail_screen.dart', "import 'package:flutter/material.dart';", "import '../services/device_permissions.dart';"),
    ('lib/screens/sop_scan_screen.dart', "import 'package:flutter/material.dart';", "import '../services/device_permissions.dart';"),
    ('lib/screens/ai_scan_tab.dart', "import 'package:flutter/material.dart';", "import '../services/device_permissions.dart';"),
    ('lib/widgets/voice_text_field.dart', "import 'package:flutter/material.dart';", "import '../services/device_permissions.dart';"),
    ('lib/services/geo_service.dart', "import 'package:permission_handler/permission_handler.dart';", "import 'device_permissions.dart';"),
]:
    add_import(rel, after, imp)

# ── location ─────────────────────────────────────────────────────────────
edit('lib/services/geo_service.dart', """  static Future<LocationData?> getCurrentLocation() async {
    try {""", """  static Future<LocationData?> getCurrentLocation() async {
    // ★ 2026-10-30: the user turned location off in My Profile - no GPS
    // prompt, no fix; reports simply carry no coordinates (EXIF still works).
    if (!DevicePermissions.isEnabled(DeviceFeature.location)) {
      return LocationData(error: 'Location is turned off in My Profile');
    }
    try {""")

print('applied')
