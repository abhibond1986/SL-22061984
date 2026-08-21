// lib/widgets/universal_app_bar.dart
// v17 — Shared header for Home / AI Scan / Near Miss / Reports.
// ✅ FIX: Profile sheet Sign Out no longer hidden behind bottom nav bar
// ✅ UI: Polished profile sheet with better spacing, scrollable content
// ✅ Language picker with 4 languages (EN/HI/BN/OR)
// ✅ Export to Google Sheets

import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import '../services/i18n.dart';
import '../services/sync_service.dart';
import '../services/local_db.dart';
import '../utils/sail_logo.dart';

class UniversalAppBar extends StatefulWidget implements PreferredSizeWidget {
  /// Global "return to Home" hook. The parent shell (HomeScreen /
  /// ContractorHomeScreen) sets this so tapping the SAIL badge in any tab's
  /// app bar jumps straight back to the Home tab.
  static VoidCallback? onHome;

  final String title;
  final String? subtitle;
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;
  final Future<void> Function()? onExport;
  final bool showExport;

  /// Back arrow, shown only when this is set.
  ///
  /// This bar is normally used by nav-bar tabs, which have nowhere to go back
  /// to — hence no automatic leading button. But it is also used by *pushed*
  /// screens (DocQaScreen), and those had no way out: unlike a real [AppBar]
  /// this widget never synthesises a leading button, and the SAIL badge is not
  /// a substitute because [onHome] no-ops when the shell is already on the Home
  /// tab. On Flutter Web there is no system back gesture either, so the user
  /// was stranded. Pushed screens must pass this.
  final VoidCallback? onBack;

  const UniversalAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
    this.onExport,
    this.showExport = true,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  State<UniversalAppBar> createState() => _UniversalAppBarState();
}

class _UniversalAppBarState extends State<UniversalAppBar> {
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    I18n.instance.addListener(_rebuild);
  }

  @override
  void dispose() {
    I18n.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() { if (mounted) setState(() {}); }

  // ── LANGUAGE PICKER ──────────────────────────────────────────
  void _showLanguagePicker() {
    final sl = SL.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: sl.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4,
              decoration: BoxDecoration(
                color: sl.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 18),
            Text(I18n.t('settings.language'),
              style: TextStyle(color: sl.text1, fontSize: 16,
                fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ...I18n.supportedCodes.map((code) {
              final isSelected = I18n.currentLang == code;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () async {
                    await I18n.setLocale(code);
                    if (mounted) setState(() {});
                    if (Navigator.canPop(ctx)) Navigator.pop(ctx);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isSelected
                        ? AppColors.accent.withOpacity(0.15)
                        : sl.card2,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                          ? AppColors.accent
                          : sl.border,
                        width: isSelected ? 1.5 : 1)),
                    child: Row(children: [
                      Text(_flagForCode(code),
                        style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(I18n.langName(code),
                            style: TextStyle(
                              color: sl.text1, fontSize: 14,
                              fontWeight: FontWeight.w600)),
                          Text(_englishName(code),
                            style: TextStyle(
                              color: sl.text3, fontSize: 11)),
                        ])),
                      if (isSelected)
                        const Icon(Icons.check_circle,
                          color: AppColors.accent, size: 22),
                    ]),
                  ),
                ),
              );
            }),
          ]),
        ),
      ),
    );
  }

  String _flagForCode(String code) {
    switch (code) {
      case 'hi': return '🇮🇳';
      default:   return '🇬🇧';
    }
  }

  String _englishName(String code) {
    switch (code) {
      case 'hi': return 'Hindi';
      default:   return 'English';
    }
  }

  // ── EXPORT TO SHEETS ─────────────────────────────────────────
  Future<void> _doExport() async {
    if (widget.onExport != null) {
      setState(() => _exporting = true);
      try { await widget.onExport!(); }
      finally { if (mounted) setState(() => _exporting = false); }
      return;
    }

    setState(() => _exporting = true);
    try {
      final all = await LocalDB.getIncidents();
      if (all.isEmpty) {
        if (mounted) _snack(I18n.t('home.noData'), AppColors.amber);
        return;
      }
      int success = 0;
      for (final inc in all) {
        final ok = await SyncService.pushIncident(inc).catchError((_) => false);
        if (ok == true) success++;
      }
      if (mounted) {
        _snack('$success / ${all.length} ${I18n.t('msg.savedSheets')}',
            success > 0 ? AppColors.green : AppColors.red);
      }
    } catch (e) {
      if (mounted) _snack('${I18n.t('msg.networkError')}: $e', AppColors.red);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 12)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 3),
    ));
  }

  // ── PROFILE MENU ─────────────────────────────────────────────
  // ✅ FIX v17: Made scrollable + added bottom padding so Sign Out
  //    is visible above the bottom navigation bar
  void _showProfileMenu() {
    final sl = SL.of(context);
    final u  = widget.user ?? {};
    showModalBottomSheet(
      context: context,
      backgroundColor: sl.card,
      isScrollControlled: true, // ✅ Allows sheet to size properly
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        // Get bottom padding (nav bar height + safe area)
        final bottomPad = MediaQuery.of(ctx).viewPadding.bottom + 80;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPad),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Drag handle
                Container(width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: sl.border, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 20),

                // ── USER INFO SECTION ──
                Row(children: [
                  Container(
                    width: 60, height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [Color(0xFF4F5BD5), Color(0xFF0EA5B5)])),
                    child: Center(child: Text(
                      (u['name']?.toString().isNotEmpty == true
                          ? u['name'].toString()[0] : '?').toUpperCase(),
                      style: const TextStyle(color: Colors.white,
                          fontSize: 24, fontWeight: FontWeight.w800))),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(u['name']?.toString() ?? 'User',
                        style: TextStyle(color: sl.text1, fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(u['designation']?.toString() ?? '—',
                        style: TextStyle(color: sl.text3, fontSize: 13)),
                    if ((u['pno']?.toString() ?? '').isNotEmpty)
                      Text('PNO: ${u['pno']}',
                          style: TextStyle(color: sl.text4, fontSize: 11)),
                  ])),
                ]),

                const SizedBox(height: 12),

                // Plant chip
                if ((u['plant']?.toString() ?? '').isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.accent.withOpacity(0.3))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.factory_outlined, color: AppColors.accent, size: 14),
                      const SizedBox(width: 6),
                      Text('${u['plant']}',
                          style: const TextStyle(color: AppColors.accent,
                              fontSize: 12, fontWeight: FontWeight.w600)),
                    ])),

                const SizedBox(height: 16),
                Divider(color: sl.border, height: 1),
                const SizedBox(height: 12),

                // ── SETTINGS ROWS ──
                _menuRow(
                  icon: widget.isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  label: widget.isDark ? I18n.t('settings.darkMode') : I18n.t('settings.lightMode'),
                  trailing: Switch(
                    value: widget.isDark,
                    activeColor: AppColors.accent,
                    onChanged: (_) {
                      if (widget.toggleTheme != null) widget.toggleTheme!();
                      Navigator.pop(ctx);
                    },
                  ),
                  sl: sl,
                ),
                const SizedBox(height: 4),
                _menuRow(
                  icon: Icons.language_rounded,
                  label: I18n.t('settings.language'),
                  trailing: GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _showLanguagePicker();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.amber.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.amber.withOpacity(0.4))),
                      child: Text(
                        I18n.langName(I18n.currentLang),
                        style: const TextStyle(color: AppColors.amber,
                            fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  sl: sl,
                ),
                const SizedBox(height: 4),
                _menuRow(
                  icon: Icons.cloud_upload_rounded,
                  label: I18n.t('settings.exportData'),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: AppColors.text3, size: 20),
                  onTap: () { Navigator.pop(ctx); _doExport(); },
                  sl: sl,
                ),

                const SizedBox(height: 16),
                Divider(color: sl.border, height: 1),
                const SizedBox(height: 16),

                // ── SIGN OUT — visible above nav bar ──
                if (widget.onSignOut != null)
                  GestureDetector(
                    onTap: () { Navigator.pop(ctx); widget.onSignOut!(); },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.red.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.red.withOpacity(0.3))),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.logout_rounded, color: AppColors.red, size: 18),
                        const SizedBox(width: 8),
                        Text(I18n.t('settings.signOut'),
                            style: const TextStyle(color: AppColors.red,
                                fontSize: 14, fontWeight: FontWeight.w700)),
                      ]))),

                // ✅ Extra bottom spacing to clear bottom nav bar
                const SizedBox(height: 20),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _menuRow({
    required IconData icon, required String label,
    Widget? trailing, VoidCallback? onTap, required SL sl,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            color: sl.isDark ? Colors.white.withOpacity(0.06) : Colors.grey.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: sl.text2, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Text(label,
            style: TextStyle(color: sl.text1, fontSize: 14,
                fontWeight: FontWeight.w600))),
        if (trailing != null) trailing,
      ]),
    ));

  // ── BUILD ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final initial = (widget.user?['name']?.toString().isNotEmpty == true
        ? widget.user!['name'].toString()[0] : '?').toUpperCase();

    // Short label for current language (ISO codes only)
    String langLabel;
    switch (I18n.currentLang) {
      case 'hi': langLabel = 'HI'; break;
      default:   langLabel = 'EN'; break;
    }

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            // Subtle brand-tinted ribbon. Previously a flat sl.glassColor
            // (plain white at 8%/45%), which made the header read as a washed
            // -out band and left the title fighting whatever scrolled beneath
            // it. The tint is low-chroma indigo→teal at high opacity: enough
            // colour to feel deliberate, opaque enough that text stays legible.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: sl.isDark
                  ? [
                      const Color(0xFF1D2444).withOpacity(0.92), // indigo
                      const Color(0xFF14203A).withOpacity(0.92), // indigo→teal
                    ]
                  : [
                      const Color(0xFFECEEFD).withOpacity(0.92), // pale indigo
                      const Color(0xFFF2FAFC).withOpacity(0.92), // pale teal
                    ],
            ),
            border: Border(
              bottom: BorderSide(
                color: AppColors.accent.withOpacity(sl.isDark ? 0.26 : 0.18),
                width: 1)),
            // NB: no boxShadow here — the enclosing ClipRRect clips to the
            // container's rect, so any drop shadow would be cut away anyway.
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
              child: Row(children: [
            // Back arrow — pushed screens only (see [onBack]).
            if (widget.onBack != null) ...[
              Semantics(
                button: true,
                label: I18n.t('common.back'),
                child: Tooltip(
                  message: I18n.t('common.back'),
                  child: InkWell(
                    onTap: widget.onBack,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.arrow_back_rounded,
                        color: sl.text1, size: 22),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],

            // SAIL Safety Lens badge icon — tap to return to the Home tab
            Semantics(
              button: true,
              label: 'Go to Home',
              child: Tooltip(
                message: 'Home',
                child: InkWell(
                  onTap: UniversalAppBar.onHome,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: SizedBox(
                      width: 36, height: 36,
                      child: Image.asset('assets/images/app_icon.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.shield, color: Colors.white, size: 20))),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),

            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title,
                    style: TextStyle(color: sl.text1, fontSize: 15,
                        fontWeight: FontWeight.w700, height: 1.1),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (widget.subtitle != null)
                  Text(widget.subtitle!,
                      // 9.5px was below the 11px hint-text floor — unreadable
                      // on a plant floor, especially through safety glasses.
                      style: TextStyle(color: sl.text3, fontSize: 11),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),

            // Language quick toggle (tap = cycle, long press = picker)
            GestureDetector(
              onLongPress: _showLanguagePicker,
              child: _IconBtn(
                icon: Icons.language_rounded,
                label: langLabel,
                color: AppColors.amber,
                onTap: () async {
                  await I18n.toggle();
                  if (mounted) setState(() {});
                },
              ),
            ),
            const SizedBox(width: 4),

            // Theme quick toggle
            if (widget.toggleTheme != null)
              IconButton(
                tooltip: widget.isDark
                    ? I18n.t('settings.lightMode')
                    : I18n.t('settings.darkMode'),
                icon: Icon(widget.isDark
                    ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    color: sl.text2, size: 20),
                onPressed: widget.toggleTheme,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),

            // Export to Sheets
            if (widget.showExport)
              IconButton(
                tooltip: I18n.t('settings.exportData'),
                icon: _exporting
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.green))
                    : const Icon(Icons.cloud_upload_outlined,
                        color: AppColors.green, size: 20),
                onPressed: _exporting ? null : _doExport,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),

            // User avatar
            GestureDetector(
              onTap: _showProfileMenu,
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                width: 34, height: 34,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFF4F5BD5), Color(0xFF0EA5B5)])),
                child: Center(child: Text(initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13, fontWeight: FontWeight.w800))),
              ),
            ),
          ]),
        ),
      ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.label,
    required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30, padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color, fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}
