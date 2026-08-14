# Immediate Fixes Required - User Reported Issues

## Issues from Screenshot & User Feedback

### 1. ❌ Blue SAIL Logo in App Icon & Headers
**Problem:** App uses blue SAIL logo instead of the Safety Lens badge icon
**Locations to fix:**
- ✅ App launcher icon (already using app_icon.png)
- ❌ UniversalAppBar header (line 405 - using SailLogo.widget)
- ❌ Splash screen 
- ❌ Login screen
- ❌ Need to replace all sail_logo.png with app_icon.png

**Files to modify:**
- `lib/widgets/universal_app_bar.dart` - Line 405
- `lib/screens/splash_screen.dart`
- `lib/screens/login_screen.dart`
- `lib/screens/dashboard_tab.dart`
- `lib/screens/contractor_home_screen.dart`

**Fix:** Replace all instances of `sail_logo.png` references with `app_icon.png`

---

### 2. ❌ Missing Logout & Language Icons in Chat and Reports Tabs
**Problem:** User profile icon, language toggle, and logout not visible in "Ask AI" and "Reports" sections

**Current State:**
- ✅ Home Tab - Has UniversalAppBar with all controls
- ✅ AI Scan Tab - Has UniversalAppBar with all controls  
- ✅ Near Miss Tab - Has UniversalAppBar with all controls
- ❌ Chat Tab (Ask AI) - Custom header WITHOUT user controls
- ❌ Reports Tab - Uses UniversalAppBar but may not be receiving props

**Root Cause:**
- `lib/screens/home_screen.dart` Line 96: ChatTab initialized WITHOUT user, toggleTheme, onSignOut props
- Reports Tab may have similar issue

**Fix Required:**
1. Modify `ChatTab` constructor to accept:
   - `user` prop
   - `toggleTheme` callback
   - `onSignOut` callback  
   - `isDark` bool

2. Modify `lib/screens/home_screen.dart` line 96 to pass props to ChatTab:
```dart
const ChatTab(),  // WRONG - no props
// Should be:
ChatTab(
  user: _user,
  toggleTheme: widget.toggleTheme,
  onSignOut: _signOut,
  isDark: isDark,
),
```

3. Replace custom header in ChatTab with UniversalAppBar OR add user controls to existing header

---

### 3. ❌ Analytics Numbers Not Clickable/Hyperlinked
**Problem:** Numbers in reports section (Total: 1, Open: 1, Critical: 0, etc.) are not clickable

**Current State:**
- Numbers display in colored cards
- No tap handlers
- No drill-down functionality

**Fix Required:**
Add `onTap` handlers to number cards that:
1. Navigate to filtered incident list
2. Show detailed breakdown
3. Allow users to click through to individual incidents

**Files to modify:**
- `lib/screens/reports_tab.dart` - Add GestureDetector/InkWell to stat cards
- `lib/screens/analytics/*.dart` - Make all numbers interactive

**Implementation:**
```dart
// Current (not clickable):
Container(child: Text('1'))

// Fixed (clickable):
InkWell(
  onTap: () => _showFilteredIncidents('Total'),
  child: Container(child: Text('1')),
)
```

---

## Priority Order

### HIGH PRIORITY (User Blocking):
1. ✅ Replace blue logo with Safety Lens badge (5 files)
2. ✅ Add user controls to Chat Tab (2 files)
3. ✅ Fix Reports Tab props if missing (1 file)

### MEDIUM PRIORITY (UX Enhancement):
4. ⚠️ Make all numbers clickable in analytics (4-5 files)

---

## Implementation Plan

### Phase 1: Logo Replacement (15 min)
- [x] Find all `sail_logo.png` references
- [ ] Replace with `app_icon.png` in 5 files
- [ ] Test on web and mobile

### Phase 2: Chat Tab Controls (20 min)
- [ ] Modify ChatTab class to accept props
- [ ] Option A: Replace custom header with UniversalAppBar
- [ ] Option B: Add user/language/logout controls to existing header
- [ ] Update home_screen.dart to pass props
- [ ] Test functionality

### Phase 3: Reports Tab Verification (10 min)
- [ ] Check if ReportsTab receives all props
- [ ] Fix if needed
- [ ] Test

### Phase 4: Clickable Numbers (30 min)
- [ ] Add tap handlers to overview cards
- [ ] Implement filtered views
- [ ] Add navigation to incident details
- [ ] Test user flow

---

## Files to Modify Summary

1. **lib/widgets/universal_app_bar.dart** - Change logo
2. **lib/screens/splash_screen.dart** - Change logo
3. **lib/screens/login_screen.dart** - Change logo
4. **lib/screens/dashboard_tab.dart** - Change logo
5. **lib/screens/contractor_home_screen.dart** - Change logo  
6. **lib/screens/chat_tab.dart** - Add props + controls
7. **lib/screens/home_screen.dart** - Pass props to ChatTab
8. **lib/screens/reports_tab.dart** - Verify props + add clickability
9. **lib/screens/analytics/overview_tab.dart** - Add tap handlers
10. **lib/screens/analytics/incident_log_tab.dart** - Verify clickability
11. **lib/screens/analytics/data_analysis_tab.dart** - Add interactions
12. **lib/screens/analytics/plant_wise_tab.dart** - Add interactions

---

**Total Estimated Time:** 75 minutes
**Status:** Ready to implement
**Created:** 2026-06-19
