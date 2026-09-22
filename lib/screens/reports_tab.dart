import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL, SLLayout;
import '../widgets/content_width.dart';
import '../services/i18n.dart';
import '../widgets/universal_app_bar.dart';
import 'analytics/overview_tab.dart';
import 'analytics/incident_log_tab.dart';
import 'analytics/data_analysis_tab.dart';
import 'analytics/plant_wise_tab.dart';

class ReportsTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback toggleTheme;
  final VoidCallback onSignOut;
  final bool isDark;

  static String? pendingStatusFilter;
  static String? pendingSeverityFilter;
  static String? pendingTypeFilter;     // ★ v35: 'AI_SCAN' or 'NEAR_MISS'
  static bool pendingMyReportsOnly = false; // ★ v35: filter to current user's reports
  static bool pendingGoToLog = false;   // ★ v35: auto-switch to Log tab

  const ReportsTab({
    super.key,
    required this.user,
    required this.toggleTheme,
    required this.onSignOut,
    required this.isDark,
  });

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // ★ v35: Auto-switch to Log tab if pending filters from Home
    if (ReportsTab.pendingGoToLog) {
      _tabController.index = 1;
      ReportsTab.pendingGoToLog = false;
    }
    I18n.instance.addListener(_onLocale);
  }

  void _onLocale() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    I18n.instance.removeListener(_onLocale);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            UniversalAppBar(
              title: I18n.t('reports.heading'),
              user: widget.user,
              toggleTheme: widget.toggleTheme,
              onSignOut: widget.onSignOut,
              isDark: widget.isDark,
              showExport: false,
            ),
            const SizedBox(height: 4),
            // `wide`, matching the four analytics tabs below it, so the pill bar
            // sits directly over its own content instead of four tabs each ~470px
            // wide on a desktop browser. The TabBarView itself is NOT wrapped —
            // each tab caps its own scroll view so the swipe stays full-bleed.
            ContentWidth(
              maxWidth: SLLayout.wide,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: sl.glassColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: sl.glassBorder),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      labelColor: Colors.white,
                      unselectedLabelColor: sl.text3,
                      labelStyle: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700),
                      unselectedLabelStyle: const TextStyle(fontSize: 13.5),
                      indicator: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      dividerColor: Colors.transparent,
                      isScrollable: false,
                      padding: const EdgeInsets.all(3),
                      labelPadding: const EdgeInsets.symmetric(vertical: 4),
                      tabs: [
                        Tab(text: I18n.t('reports.tab.overview')),
                        Tab(text: I18n.t('reports.tab.log')),
                        Tab(text: I18n.t('reports.tab.analysis')),
                        Tab(text: I18n.t('reports.tab.plantWise')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  OverviewTab(),
                  IncidentLogTab(),
                  DataAnalysisTab(),
                  PlantWiseTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
