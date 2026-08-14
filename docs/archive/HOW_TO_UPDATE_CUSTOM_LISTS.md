# 📝 How to Update Custom Lists (WSA-13, Departments, etc.)

## ⚠️ IMPORTANT: Current Limitation

**Admin panel changes DO NOT automatically sync to the Flutter app!**

### Why?
- **Admin Panel** stores data in **browser localStorage** (web only)
- **Flutter App** stores data in **SharedPreferences** (device storage)
- These are **separate storage systems** and don't communicate

---

## 🔄 Current Workaround: Manual Update in Code

### To Update WSA-13 Causes:

1. **Open the file:**
   ```
   lib/services/admin_master_data.dart
   ```

2. **Find the `defaultWsaCauses` list** (around line 44):
   ```dart
   static const List<String> defaultWsaCauses = [
     '1. Failure to follow procedure',
     '2. Lack of hazard awareness',
     '3. Improper PPE use',
     '4. Unsafe body positioning',
     '5. Equipment failure',
     '6. Communication failure',
     '7. Human error',
     '8. Poor housekeeping',
     '9. Lack of supervision',
     '10. Fatigue / time pressure',
     '11. Unauthorized operation',
     '12. Inadequate isolation (LOTO/PTW)',
     '13. Environmental conditions',
   ];
   ```

3. **Edit the items** you want to change. For example:
   ```dart
   static const List<String> defaultWsaCauses = [
     '1. Failure to follow procedure',
     '2. Lack of hazard awareness',
     '3. Improper PPE use',
     '4. Unsafe body positioning',
     '5. Equipment failure',
     '6. Communication failure',
     '7. Human error - Updated',  // ← Changed
     '8. Poor housekeeping',
     '9. Lack of supervision',
     '10. Fatigue / time pressure',
     '11. Unauthorized operation',
     '12. Inadequate isolation (LOTO/PTW)',
     '13. Environmental conditions - New description',  // ← Changed
   ];
   ```

4. **Save the file**

5. **Rebuild the app:**
   ```bash
   flutter run
   # or
   flutter build apk --release
   ```

---

## 📋 Other Lists You Can Update

### Departments (line 61):
```dart
static const List<String> defaultDepartments = [
  'Blast Furnace', 
  'Steel Melting Shop', 
  'Coke Ovens',
  // ... add or modify
];
```

### Severities (line 75):
```dart
static const List<String> defaultSeverities = [
  'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'
];
```

### Statuses (line 78):
```dart
static const List<String> defaultStatuses = [
  'OPEN', 'INVESTIGATING', 'ACTION TAKEN', 'VERIFIED', 'CLOSED',
];
```

### Observation Types (line 83):
```dart
static const List<String> defaultObservationTypes = [
  'Unsafe Act', 'Unsafe Condition', 'Near Miss', 'First Aid Case',
];
```

---

## 🚀 Better Solution: Coming Soon

### Planned Feature: Google Sheets Master Data Sync

**How it will work:**
```
┌──────────────┐         
│ Admin Panel  │ ─────> Save to Google Sheets
└──────────────┘              ↓
                    ┌──────────────────┐
                    │ Google Sheets    │  ← Single source of truth
                    └──────────────────┘
                               ↓
┌──────────────┐         
│ Flutter App  │ <───── Auto-fetch from Sheets
└──────────────┘         
```

**Features:**
- ✅ Admin updates WSA-13 in web panel
- ✅ Saves to Google Sheets automatically
- ✅ App fetches updates on start
- ✅ "Refresh Master Data" button in app
- ✅ Works across all devices
- ✅ No code changes needed

**Status:** 📋 Planned for next update

---

## 🔧 Current Admin Panel Behavior

### What the Admin Panel IS for:
- ✅ User management (add/edit/delete users)
- ✅ Incident reporting interface
- ✅ Analytics dashboard
- ✅ Google Sheets integration for incidents

### What the Admin Panel CANNOT do (yet):
- ❌ Update master data lists for the app
- ❌ Sync WSA causes to app
- ❌ Sync departments to app
- ❌ Configure app dropdowns

### Workaround:
- Use the admin panel to view/manage data
- Update code manually in `admin_master_data.dart`
- Rebuild app to reflect changes

---

## 📖 Step-by-Step Example: Updating WSA-13

### Scenario: You want to change item 13 from "Environmental conditions" to "Extreme weather conditions"

1. **Open file:**
   ```
   C:\Users\DELL\Desktop\Safety-Lens-V2\lib\services\admin_master_data.dart
   ```

2. **Find line 57:**
   ```dart
   '13. Environmental conditions',
   ```

3. **Change to:**
   ```dart
   '13. Extreme weather conditions',
   ```

4. **Save file** (Ctrl + S)

5. **Rebuild app:**
   ```bash
   cd C:\Users\DELL\Desktop\Safety-Lens-V2
   flutter run
   ```

6. **Test:**
   - Open app → AI Scan → Take photo
   - In review screen, check WSA cause dropdown
   - Item 13 should show "Extreme weather conditions"

---

## 🛠️ Alternative: Reset to Defaults

If you want to clear all custom changes and go back to default lists:

### In the App:
Currently, there's no UI button. You need to:

1. Clear app data (Android Settings → Apps → Safety Lens → Clear Data)
2. Or uninstall and reinstall the app

### In Code:
```dart
// Call this function to reset all lists to defaults
await AdminMasterData.resetAllToDefaults();
```

---

## ⚠️ Known Issues

### Issue #1: Admin Panel Custom Lists Not Used
- **Status:** Known limitation
- **Workaround:** Edit code manually
- **Fix:** Planned Google Sheets sync

### Issue #2: Changes Lost on App Reinstall
- **Status:** By design (uses defaults)
- **Workaround:** Edit defaults in code
- **Fix:** Planned Google Sheets sync

### Issue #3: Multiple Users Can't Share Custom Lists
- **Status:** Known limitation
- **Workaround:** Each user edits their code
- **Fix:** Planned Google Sheets sync

---

## 📞 Need Help?

### Quick Reference:
- **File to edit:** `lib/services/admin_master_data.dart`
- **Lists available:** WSA causes, Departments, Severities, Statuses, Observation Types
- **After editing:** Rebuild app with `flutter run`

### Common Mistakes:
- ❌ Don't forget commas after each item
- ❌ Don't remove the square brackets `[ ]`
- ❌ Don't forget quotes around strings `'...'`
- ❌ Don't use special characters without escaping

### Correct Format:
```dart
static const List<String> defaultWsaCauses = [
  '1. Item one',    // ← comma
  '2. Item two',    // ← comma
  '3. Item three',  // ← comma optional on last item
];  // ← semicolon at end
```

---

Generated: 2026-06-21
Status: Workaround documented, proper fix planned
File: lib/services/admin_master_data.dart
