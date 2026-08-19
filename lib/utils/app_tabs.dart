// lib/utils/app_tabs.dart
//
// Bottom-navigation tab indices, in one place.
//
// WHY THIS FILE EXISTS: the indices used to be bare integers spread across
// home_tab.dart and dashboard_tab.dart — `widget.onTabChange(4)` with, at best,
// a trailing comment saying which tab 4 was. Inserting the SOP/SMP scan tab at
// position 3 shifted Ask AI and Reports by one, which meant hunting down nine
// literals and getting every one right. A miss would not crash or fail to
// compile: the button would just open the wrong tab, and only a user would find
// out.
//
// So: no bare tab integers anywhere. If the order changes again, edit ONLY this
// file and the `items` list + `tabs` list in home_screen.dart, which sit next to
// each other for that reason.
//
// Order must match home_screen.dart's `tabs` list and `_bottomNav` items list.
class AppTabs {
  const AppTabs._();

  static const int home = 0;
  static const int aiScan = 1;
  static const int nearMiss = 2;
  static const int sopScan = 3;
  static const int askAi = 4;
  static const int reports = 5;

  /// Number of tabs — used for the bounds check in HomeScreen._changeTab, which
  /// previously hard-coded 5 and would have silently rejected this new tab.
  static const int count = 6;
}
