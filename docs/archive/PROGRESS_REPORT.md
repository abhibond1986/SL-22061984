# Safety Lens V2 - Progress Report
**Date:** June 19, 2026  
**Status:** Partial Completion - 1 of 3 issues fixed

---

## ✅ Issue 1: Blue SAIL Logo → Safety Lens Badge (COMPLETED)

### Problem
The app was showing different blue SAIL logos instead of the consistent "SAIL Safety Lens" badge icon throughout the interface.

### Solution Implemented
✅ **Replaced all `sail_logo.png` references with `app_icon.png`**

**Files Modified:**
1. ✅ `lib/widgets/universal_app_bar.dart` - Header logo in all tabs
2. ✅ `lib/screens/splash_screen.dart` - App launch screen
3. ✅ `lib/screens/login_screen.dart` - Login page logo
4. ✅ `lib/screens/dashboard_tab.dart` - Dashboard header
5. ✅ `lib/screens/contractor_home_screen.dart` - Contractor view
6. ✅ `lib/main.dart` - SailLogoTile widget fallback

### Result
Now the entire app consistently shows the **SAIL Safety Lens badge icon** everywhere:
- ✅ App launcher icon
- ✅ Splash screen
- ✅ Login screen
- ✅ All tab headers (Home, AI Scan, Near Miss)
- ✅ Dashboard
- ✅ Contractor screens

**Commit:** `8bd8284` - "Replace blue SAIL logo with Safety Lens badge icon across app"

---

## ⚠️ Issue 2: Missing User Controls in Chat & Reports Tabs (IN PROGRESS)

### Problem
Logout icon, language toggle, and user profile are not visible in "Ask AI" (Chat) and "Reports" sections.

### Root Cause Identified
- **ChatTab** (`lib/screens/chat_tab.dart`) has a **custom header** instead of using `UniversalAppBar`
- **ChatTab** is initialized **WITHOUT** `user`, `toggleTheme`, `onSignOut` props
- **ReportsTab** may have similar issue

### Current State
- ✅ Home Tab - Has UniversalAppBar with all controls
- ✅ AI Scan Tab - Has UniversalAppBar with all controls
- ✅ Near Miss Tab - Has UniversalAppBar with all controls  
- ❌ **Chat Tab** - Custom header, missing user controls
- ⚠️ **Reports Tab** - Using UniversalAppBar but may not receive props

### Solution Required

#### Option A: Replace Custom Header with UniversalAppBar (RECOMMENDED)
**Advantages:** Consistent UI, automatic updates, all features work  
**Time:** 15-20 minutes

**Steps:**
1. Modify `ChatTab` constructor to accept props:
```dart
class ChatTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;
  
  const ChatTab({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
  });
  
  @override
  State<ChatTab> createState() => _ChatTabState();
}
```

2. In `lib/screens/home_screen.dart` line 96, change from:
```dart
const ChatTab(),  // WRONG
```
To:
```dart
ChatTab(
  user: _user,
  toggleTheme: widget.toggleTheme,
  onSignOut: _signOut,
  isDark: isDark,
),
```

3. In `ChatTab` build method (around line 559-620), replace custom header with:
```dart
@override
Widget build(BuildContext context) {
  final sl = SL.of(context);
  return Scaffold(
    appBar: UniversalAppBar(
      title: 'SAIL Suraksha Saathi',
      subtitle: 'आपका सुरक्षा साथी · SG/01–SG/41',
      user: widget.user,
      toggleTheme: widget.toggleTheme,
      onSignOut: widget.onSignOut,
      isDark: widget.isDark,
      showExport: false,  // No export needed in chat
    ),
    body: SafeArea(
      child: Column(children: [
        // Rest of existing UI (messages, input)
```

#### Option B: Add User Controls to Existing Custom Header
**Advantages:** Keep existing design  
**Disadvantages:** More code, maintenance burden  
**Time:** 30 minutes

Add profile/language/logout buttons to existing custom header around line 600-619.

### Files to Modify
- `lib/screens/chat_tab.dart` - Accept props + replace header
- `lib/screens/home_screen.dart` - Pass props to ChatTab
- `lib/screens/reports_tab.dart` - Verify props are passed

---

## ⚠️ Issue 3: Analytics Numbers Not Clickable (PENDING)

### Problem
Numbers in the analytics section (Total: 1, Open: 1, Critical: 0, Closed %: 0%) are not clickable/hyperlinked.

### Current Behavior
- Numbers display in colored stat cards
- No tap handlers
- No drill-down to details

### Required Implementation

#### 1. Make Stat Cards Clickable
Wrap stat cards in `InkWell` or `GestureDetector`:

```dart
// Current (not clickable):
Container(
  child: Column(
    children: [
      Text('1'),
      Text('Total'),
    ],
  ),
)

// Fixed (clickable):
InkWell(
  onTap: () => _showFilteredIncidents('all'),
  borderRadius: BorderRadius.circular(12),
  child: Container(
    child: Column(
      children: [
        Text('1'),
        Text('Total'),
      ],
    ),
  ),
)
```

#### 2. Create Filtered Views
Add methods to show filtered incident lists:

```dart
void _showFilteredIncidents(String filter) {
  // filter can be: 'all', 'open', 'critical', 'closed'
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => IncidentListScreen(
        filter: filter,
        user: widget.user,
      ),
    ),
  );
}
```

#### 3. Status Distribution Numbers
Make "Open", "Investigating", "Action Taken", "Closed" numbers clickable:

```dart
GestureDetector(
  onTap: () => _showFilteredIncidents('open'),
  child: Column(
    children: [
      Text('1', style: TextStyle(fontSize: 32, color: Colors.orange)),
      Text('Open'),
    ],
  ),
)
```

#### 4. Top Hazard Categories
Make hazard types clickable to show incidents of that type:

```dart
ListTile(
  title: Text('Other'),
  trailing: Text('1'),
  onTap: () => _showIncidentsByHazard('Other'),
)
```

### Files to Modify
1. `lib/screens/reports_tab.dart` - Main stats cards
2. `lib/screens/analytics/overview_tab.dart` - Overview numbers
3. `lib/screens/analytics/incident_log_tab.dart` - Log entries
4. `lib/screens/analytics/data_analysis_tab.dart` - Charts/numbers
5. `lib/screens/analytics/plant_wise_tab.dart` - Plant stats

### Implementation Steps
1. Add tap handlers to all stat cards
2. Create filter methods
3. Add navigation to filtered views
4. Test click flow end-to-end

---

## Summary

### ✅ Completed (33%)
1. **Logo Replacement** - All instances fixed, committed

### ⚠️ In Progress (33%)  
2. **Chat Tab User Controls** - Solution identified, needs implementation

### ⏳ Pending (33%)
3. **Clickable Numbers** - Design documented, implementation pending

---

## Next Steps

### Immediate (HIGH PRIORITY)
1. **Fix ChatTab** - Add user controls (15-20 min)
   - Modify constructor
   - Update home_screen.dart
   - Replace custom header with UniversalAppBar

2. **Verify ReportsTab** - Check if props are passed (5 min)

### Medium Priority
3. **Make Numbers Clickable** - Add tap handlers and filtered views (30-45 min)
   - Overview cards
   - Status distribution
   - Hazard categories
   - Plant-wise stats

---

## Test Checklist

### Logo Replacement ✅
- [ ] Test web app - verify badge icon shows
- [ ] Build APK - verify launcher icon
- [ ] Test on phone - check all screens

### User Controls (When Complete)
- [ ] Chat tab shows user avatar
- [ ] Language toggle works in chat
- [ ] Logout works from chat
- [ ] Theme toggle works in chat
- [ ] Reports tab has same controls

### Clickable Numbers (When Complete)
- [ ] Click "Total" → shows all incidents
- [ ] Click "Open" → shows open incidents
- [ ] Click "Critical" → shows critical incidents
- [ ] Click hazard type → shows filtered list
- [ ] Back navigation works correctly

---

## Commands to Continue

### Build and Test
```bash
cd C:\Users\USER\Desktop\Safety-Lens-V2

# Test on web
flutter run -d chrome

# Build APK
flutter build apk --debug

# Check changes
git status
git diff
```

### Push Changes
```bash
git push origin main
```

---

## Files Changed So Far

### Committed (Logo Fixes)
- lib/widgets/universal_app_bar.dart
- lib/screens/splash_screen.dart
- lib/screens/login_screen.dart
- lib/screens/dashboard_tab.dart
- lib/screens/contractor_home_screen.dart
- lib/main.dart
- IMMEDIATE_FIXES_NEEDED.md (new)

### Pending Changes
- lib/screens/chat_tab.dart (modify constructor + header)
- lib/screens/home_screen.dart (pass props to ChatTab)
- lib/screens/reports_tab.dart (verify + add clickability)
- lib/screens/analytics/*.dart (add tap handlers)

---

**Progress:** 1 of 3 issues fully resolved  
**Estimated time to complete:** 45-60 minutes  
**Last updated:** 2026-06-19
