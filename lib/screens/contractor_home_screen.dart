// lib/screens/contractor_home_screen.dart
//
// Limited home screen for contractual employees.
// Only provides access to AI Scan and Near Miss sections.
// No login required. No LanguageFab (language is in UniversalAppBar).

import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sync_service.dart';
import '../services/background_sync.dart';
import 'login_screen.dart';
import 'ai_scan_tab.dart';
import 'near_miss_tab.dart';

class ContractorHomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const ContractorHomeScreen({super.key, required this.toggleTheme});

  @override
  State<ContractorHomeScreen> createState() => _ContractorHomeScreenState();
}

class _ContractorHomeScreenState extends State<ContractorHomeScreen> {
  int _tabIndex = 0;

  // Contractor user placeholder (no real login)
  final Map<String, dynamic> _contractorUser = {
    'name': 'Contractor',
    'username': 'contractor',
    'designation': 'Contractual Employee',
    'plant': '',
    'role': 'contractor',
  };

  void _exitToLogin() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) =>
            LoginScreen(toggleTheme: widget.toggleTheme),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final isDark = sl.isDark;

    final tabs = <Widget>[
      // 0 — AI Scan
      AIScanTab(
        user: _contractorUser,
        toggleTheme: widget.toggleTheme,
        onSignOut: _exitToLogin,
        isDark: isDark,
        showAppBar: false, // Contractor screen has its own AppBar
      ),
      // 1 — Near Miss
      NearMissTab(
        user: _contractorUser,
        toggleTheme: widget.toggleTheme,
        onSignOut: _exitToLogin,
        isDark: isDark,
        showAppBar: false, // Contractor screen has its own AppBar
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
        child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: sl.text1),
          onPressed: _exitToLogin,
          tooltip: 'Back to Login',
        ),
        title: Row(
          children: [
            Image.asset(
              'assets/images/app_icon.png',
              width: 28,
              height: 28,
              errorBuilder: (_, __, ___) => Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent),
                child: const Icon(Icons.shield, color: Colors.white, size: 14)),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SAIL Safety Lens',
                  style: TextStyle(
                    color: sl.text1,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Contractor Access',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // ★ Sync to Google Sheets button
          IconButton(
            icon: Icon(Icons.cloud_upload_outlined, color: sl.text3, size: 20),
            tooltip: 'Sync to Sheets',
            onPressed: () async {
              final count = await SyncService.getPendingCount();
              if (count == 0) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All reports already synced ✓'), duration: Duration(seconds: 2)));
                }
                return;
              }
              final synced = await BackgroundSync.syncNow();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Synced $synced report(s) to Google Sheets'), duration: const Duration(seconds: 2)));
              }
            },
          ),
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: sl.text3,
              size: 20,
            ),
            onPressed: widget.toggleTheme,
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(
          key: ValueKey(_tabIndex),
          child: tabs[_tabIndex],
        ),
      ),
      bottomNavigationBar: _bottomNav(sl),
    ),
      ),
    );
  }

  Widget _bottomNav(SL sl) {
    final items = [
      _NavItem(Icons.document_scanner_outlined,
          Icons.document_scanner_rounded, 'AI Scan'),
      _NavItem(Icons.warning_amber_outlined,
          Icons.warning_amber_rounded, 'Near Miss'),
    ];

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
      decoration: BoxDecoration(
        // Matches the employee shell's nav bar (home_screen.dart) so the two
        // shells don't look like two different apps.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: sl.isDark
              ? [
                  const Color(0xFF191F38).withOpacity(0.98),
                  const Color(0xFF0D1117).withOpacity(0.98),
                ]
              : [
                  const Color(0xFFE9ECFB).withOpacity(0.94),
                  const Color(0xFFF8F9FE).withOpacity(0.94),
                ],
        ),
        border: Border(
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
              final sel = _tabIndex == i;
              final item = items[i];
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tabIndex = i),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
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
                                    ? const Color(0xFFCBD5E1)
                                    : sl.text4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel
                              ? AppColors.accent
                              : sl.isDark
                                  ? const Color(0xFFCBD5E1)
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
