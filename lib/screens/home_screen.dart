// lib/screens/home_screen.dart
//
// CHANGES:
// ✅ Removed LanguageFab (language toggle already in UniversalAppBar)
// ✅ Everything else preserved

import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart';
import '../utils/app_tabs.dart';
import '../services/local_db.dart';
import '../services/sync_service.dart';
import 'login_screen.dart';
import 'home_tab.dart';
import 'ai_scan_tab.dart';
import 'near_miss_tab.dart';
import 'sop_scan_screen.dart';
import 'chat_tab.dart';
import 'reports_tab.dart';
import '../widgets/universal_app_bar.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const HomeScreen({super.key, required this.toggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  int _tabIndex = 0;
  Map<String, dynamic>? _user;
  late AnimationController _tabAnim;

  @override
  void initState() {
    super.initState();
    _tabAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _loadUser();
  }

  @override
  void dispose() {
    _tabAnim.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final u = await LocalDB.getCurrentUser();
    if (mounted) setState(() => _user = u);
    // Warm the shared data for the tabs that don't sync themselves (AI Scan,
    // Near Miss, Reports). Throttled and coalesced inside fullSync, so this and
    // HomeTab's own call cost one round-trip between them. No setState here: it
    // used to bump _syncKey, which remounted HomeTab and started a second sync.
    SyncService.fullSync().catchError((_) => <String, dynamic>{});
  }

  Future<void> _signOut() async {
    await LocalDB.signOut();
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) =>
              LoginScreen(toggleTheme: widget.toggleTheme),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ));
  }

  void _changeTab(int i) {
    // AppTabs.count, not a literal: the bounds check used to hard-code 5, which
    // would have silently rejected any tab added at the end.
    if (i < 0 || i >= AppTabs.count || i == _tabIndex) return;
    _guardedSwitch(i);
  }

  /// Switches tabs, but asks first when it would destroy captured SOP pages.
  ///
  /// Necessary because the body below is an AnimatedSwitcher keyed by tab index:
  /// changing tabs DISPOSES the outgoing tab, and for the scan tab that throws
  /// away photographs of a printed document that the user walked out to the shop
  /// floor to take. Every other tab holds either saved data or a form that costs
  /// seconds to retype, which is why none of them needed this.
  Future<void> _guardedSwitch(int i) async {
    if (_tabIndex == AppTabs.sopScan && SopScanScreen.hasUnsavedWork.value) {
      final leave = await _confirmDiscardScan();
      if (leave != true || !mounted) return;
      // The State clears this in dispose(), but clear it here too: if the user
      // confirms and the frame has not rebuilt yet, a second fast tap would
      // otherwise raise the same dialog again.
      SopScanScreen.hasUnsavedWork.value = false;
    }
    if (!mounted) return;
    setState(() => _tabIndex = i);
  }

  Future<bool?> _confirmDiscardScan() {
    final sl = SL.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        title: Text('Discard the scanned pages?',
            style: TextStyle(
                color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
        content: Text(
            'You have pages that are not saved to the Knowledge Base yet. '
            'Leaving this tab discards them and you would have to photograph '
            'the document again.',
            style: TextStyle(color: sl.text3, fontSize: 12, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Stay',
                style: TextStyle(color: sl.text3, fontSize: 12)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Discard',
                style: TextStyle(
                    color: sl.redText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sl     = SL.of(context);
    final isDark = sl.isDark;

    // Tapping the SAIL badge in any tab's app bar returns to the Home tab.
    UniversalAppBar.onHome = () {
      // Through _changeTab so the badge cannot silently discard a scan either —
      // it is the one route back to Home from inside the scan tab.
      if (mounted && _tabIndex != AppTabs.home) _changeTab(AppTabs.home);
    };

    final tabs = <Widget>[
      HomeTab(
        // STABLE KEY. This was ValueKey('home_$_syncKey'), bumped when the
        // sync below finished, which destroyed and rebuilt the whole tab just to
        // repaint numbers, re-running its initState sync. (It is still rebuilt
        // on every bottom-nav switch by the AnimatedSwitcher below, so this does
        // not preserve scroll position across tabs — it removes the second sync
        // at startup; the throttle in fullSync is what makes navigation cheap.)
        // HomeTab listens to RealtimeSync.incidentsRevision and
        // AdminMasterData.revision, and SyncService.fullSync now bumps the
        // former on completion, so it refreshes itself in place.
        key: const ValueKey('home'),
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
        onTabChange: _changeTab,
      ),
      AIScanTab(
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
      ),
      NearMissTab(
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
      ),
      // Index 3 — between Near Miss and Ask AI. Adding it here shifted Ask AI to
      // 4 and Reports to 5; the onTabChange(n) call sites in home_tab.dart and
      // dashboard_tab.dart were updated to match.
      SopScanScreen(
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
        isTab: true,
      ),
      ChatTab(
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
      ),
      ReportsTab(
        user: _user,
        toggleTheme: widget.toggleTheme,
        onSignOut: _signOut,
        isDark: isDark,
      ),
    ];

    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: sl.bgGradient,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(
            key: ValueKey(_tabIndex),
            child: tabs[_tabIndex],
          ),
        ),
      ),
      bottomNavigationBar: _bottomNav(sl),
    );
  }

  Widget _bottomNav(SL sl) {
    final items = [
      _NavItem(Icons.home_outlined,             Icons.home_rounded,             'Home'),
      _NavItem(Icons.document_scanner_outlined, Icons.document_scanner_rounded, 'AI Scan'),
      _NavItem(Icons.warning_amber_outlined,    Icons.warning_amber_rounded,    'Near Miss'),
      // menu_book, not document_scanner: AI Scan already owns the scanner glyph
      // and at 22px the two are near-identical. An SOP is the rule book, so the
      // book reads correctly and stays distinct. Avoid qr_code_scanner — it
      // promises QR codes, which this does not do.
      _NavItem(Icons.menu_book_outlined,        Icons.menu_book_rounded,        'SOP Scan'),
      _NavItem(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded,    'Ask AI'),
      _NavItem(Icons.bar_chart_outlined,        Icons.bar_chart_rounded,        'Reports'),
    ];

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            // Subtle indigo wash instead of a flat neutral slab, so the nav bar
            // reads as part of the brand surface rather than a grey strip. Kept
            // very low-chroma on purpose — it must never compete with the
            // accent-coloured selected tab.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: sl.isDark
                  ? [
                      const Color(0xFF191F38).withOpacity(0.98), // indigo-tinted
                      const Color(0xFF0D1117).withOpacity(0.98), // near-black base
                    ]
                  : [
                      const Color(0xFFE9ECFB).withOpacity(0.94), // pale indigo
                      const Color(0xFFF8F9FE).withOpacity(0.94),
                    ],
            ),
            border: Border(
              // Accent-tinted hairline: separates the bar from content and
              // echoes the selected-tab colour.
              top: BorderSide(
                color: AppColors.accent.withOpacity(sl.isDark ? 0.28 : 0.20),
                width: 1),
            ),
          ),
          child: SafeArea(
            child: SizedBox(
              height: 60,
              child: Row(
                children: List.generate(items.length, (i) {
                  final sel  = _tabIndex == i;
                  final item = items[i];
                  return Expanded(
                    child: GestureDetector(
                      // _changeTab, not a bare setState: this is the path the
                      // unsaved-scan guard has to cover, and it is the one users
                      // actually tap.
                      onTap: () => _changeTab(i),
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            // Was horizontal 14, which made the selected pill
                            // 50px wide. At six tabs a 320px screen gives each
                            // tab 53px, so the pill had 3px of clearance and
                            // would overflow the moment anything else grew.
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel
                                  ? AppColors.accent.withOpacity(0.15)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              sel ? item.activeIcon : item.icon,
                              size: 22,
                              color: sel
                                  ? AppColors.accent
                                  : sl.isDark
                                      ? const Color(0xFFCBD5E1) // brighter for dark mode nav
                                      : sl.text4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            softWrap: false,
                            style: TextStyle(
                              // 9px at your request, to keep the full "SOP Scan"
                              // label on a six-tab bar. This is below the 10px
                              // floor tools/audit_contrast.py enforces, so the
                              // audit will now report 6 nav labels as failures —
                              // expected, not a regression. If it reads too small
                              // on the shop floor, the fix is to shorten this one
                              // label to "SOP" and put all six back to 10px,
                              // rather than to shrink them further.
                              fontSize: 9,
                              fontWeight: sel
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: sel
                                  ? AppColors.accent
                                  : sl.isDark
                                      ? const Color(0xFFCBD5E1) // brighter for dark mode nav
                                      : sl.text4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon, activeIcon;
  final String label;
  const _NavItem(this.icon, this.activeIcon, this.label);
}
