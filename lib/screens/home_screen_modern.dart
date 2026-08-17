// lib/screens/home_screen_modern.dart
// Enhanced home screen with modern bottom navigation
// Copy this over home_screen.dart to use the new navigation

import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/sync_service.dart';
import '../widgets/modern_bottom_nav.dart';
import 'login_screen.dart';
import 'home_tab.dart';
import 'ai_scan_tab.dart';
import 'near_miss_tab.dart';
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

  // Choose your preferred bottom nav style here!
  // Options: floating, glass, minimal, bubble, morphing
  final BottomNavStyle _navStyle = BottomNavStyle.floating;

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
    if (i >= 0 && i < 5 && i != _tabIndex) {
      setState(() => _tabIndex = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final isDark = sl.isDark;

    UniversalAppBar.onHome = () {
      if (mounted && _tabIndex != 0) setState(() => _tabIndex = 0);
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
      bottomNavigationBar: ModernBottomNav(
        currentIndex: _tabIndex,
        onTap: _changeTab,
        style: _navStyle,
        isDark: isDark,
        selectedColor: AppColors.accent,
        items: const [
          BottomNavItem(
            icon: Icons.home_outlined,
            activeIcon: Icons.home_rounded,
            label: 'Home',
          ),
          BottomNavItem(
            icon: Icons.document_scanner_outlined,
            activeIcon: Icons.document_scanner_rounded,
            label: 'AI Scan',
          ),
          BottomNavItem(
            icon: Icons.warning_amber_outlined,
            activeIcon: Icons.warning_amber_rounded,
            label: 'Near Miss',
            // Example badge (uncomment to test):
            // badgeCount: 3,
            // badgeColor: Colors.red,
          ),
          BottomNavItem(
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            label: 'Ask AI',
          ),
          BottomNavItem(
            icon: Icons.bar_chart_outlined,
            activeIcon: Icons.bar_chart_rounded,
            label: 'Reports',
          ),
        ],
      ),
    );
  }
}
