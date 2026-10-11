# API Key Sync Issue - Diagnosis and Fix

## **Problem Summary**

API keys added through the admin panel are **NOT syncing to other devices** (phones, other users). This is a critical synchronization issue.

## **Root Cause**

API keys are stored in **two different locations**:

### 1. **Local Storage** (SharedPreferences)
- Keys saved by admin panel: `groq_api_key`, `openrouter_api_key`, `openrouter_api_key_2`, `gemini_api_key`
- Stored on the device where admin enters them
- ❌ **Only visible on that device**

### 2. **Server Storage** (Google Apps Script Properties)
- Keys should be in Apps Script Script Properties
- Fetched by ALL devices via `_fetchApiKeysFromAppsScript()`
- ✅ **Syncs to all devices**

## **The Issue**

Looking at the code in `lib/services/sync_service.dart` (lines 592-629):

```dart
// ★ CRITICAL: AI API keys (OpenRouter/Gemini/Groq) do NOT live in the
// Supabase master_data table — they live server-side in the Apps Script
// Script Properties. Without them the device can't reach OpenRouter and
// every image scan silently falls back to OFFLINE analysis.
// So always pull the keys from Apps Script, even under Supabase.
```

**Keys are ONLY pulled from Apps Script, but the admin panel likely saves them ONLY to local SharedPreferences.**

## **How Key Sync Should Work**

```
Admin Panel → Save Key
    ↓
1. Save to local SharedPreferences ✅ (working)
    ↓
2. Push to Apps Script Properties ❌ (MISSING!)
    ↓
3. Other devices fetch from Apps Script ✅ (working, but gets empty keys)
```

## **The Fix Needed**

### **Option 1: Add Key Push to Apps Script (Recommended)**

You need to add a function in Apps Script to receive and save API keys, then call it from the admin panel.

#### **A. Update Apps Script (apps_script_v14.js or equivalent)**

Add this function:

```javascript
function saveApiKeys(requestData) {
  const props = PropertiesService.getScriptProperties();
  
  if (requestData.geminiApiKey) {
    props.setProperty('GEMINI_API_KEY', requestData.geminiApiKey);
  }
  if (requestData.openRouterApiKey) {
    props.setProperty('OPENROUTER_API_KEY', requestData.openRouterApiKey);
  }
  if (requestData.openRouterApiKey2) {
    props.setProperty('OPENROUTER_API_KEY_2', requestData.openRouterApiKey2);
  }
  if (requestData.groqApiKey) {
    props.setProperty('GROQ_API_KEY', requestData.groqApiKey);
  }
  if (requestData.naraApiKey) {
    props.setProperty('NARA_API_KEY', requestData.naraApiKey);
  }
  if (requestData.geminiModel) {
    props.setProperty('GEMINI_MODEL', requestData.geminiModel);
  }
  if (requestData.naraModel) {
    props.setProperty('NARA_MODEL', requestData.naraModel);
  }
  
  return {
    ok: true,
    message: 'API keys saved successfully'
  };
}
```

Add `'saveApiKeys'` to the appropriate action handler in Apps Script.

#### **B. Update Flutter Code**

1. **Add sync function to `lib/services/sync_service.dart`:**

```dart
/// Push API keys to Apps Script so they sync to all devices.
static Future<bool> pushApiKeys({
  String? geminiApiKey,
  String? openRouterApiKey,
  String? openRouterApiKey2,
  String? groqApiKey,
  String? naraApiKey,
  String? geminiModel,
  String? naraModel,
}) async {
  try {
    final url = await getBackendUrl();
    if (url.isEmpty || !url.startsWith('https://')) return false;
    
    final body = <String, dynamic>{
      'action': 'saveApiKeys',
    };
    
    if (geminiApiKey != null && geminiApiKey.isNotEmpty) {
      body['geminiApiKey'] = geminiApiKey;
    }
    if (openRouterApiKey != null && openRouterApiKey.isNotEmpty) {
      body['openRouterApiKey'] = openRouterApiKey;
    }
    if (openRouterApiKey2 != null && openRouterApiKey2.isNotEmpty) {
      body['openRouterApiKey2'] = openRouterApiKey2;
    }
    if (groqApiKey != null && groqApiKey.isNotEmpty) {
      body['groqApiKey'] = groqApiKey;
    }
    if (naraApiKey != null && naraApiKey.isNotEmpty) {
      body['naraApiKey'] = naraApiKey;
    }
    if (geminiModel != null && geminiModel.isNotEmpty) {
      body['geminiModel'] = geminiModel;
    }
    if (naraModel != null && naraModel.isNotEmpty) {
      body['naraModel'] = naraModel;
    }
    
    final resp = await _postWithRedirect(url, body);
    if (resp != null && resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['ok'] == true;
    }
    return false;
  } catch (e) {
    debugPrint('SyncService: pushApiKeys failed - $e');
    return false;
  }
}
```

2. **Update admin panel to push keys after saving locally:**

Find where the admin panel saves keys (likely in `lib/screens/admin_screen.dart`), and after saving to SharedPreferences, add:

```dart
// After saving to SharedPreferences
await prefs.setString('groq_api_key', groqKey);

// PUSH TO BACKEND so other devices get the key
await SyncService.pushApiKeys(
  groqApiKey: groqKey,
  // ... other keys
);
```

### **Option 2: Manual Workaround (Immediate)**

Until the code fix is deployed:

1. **Open Google Apps Script** (the deployment URL in your code)
2. **Go to Project Settings** → **Script Properties**
3. **Manually add the properties:**
   - `GEMINI_API_KEY` = your Gemini key
   - `OPENROUTER_API_KEY` = your OpenRouter key
   - `OPENROUTER_API_KEY_2` = your second OpenRouter key (if any)
   - `GROQ_API_KEY` = your Groq key
   - `NARA_API_KEY` = your Nara key
   - `GEMINI_MODEL` = your Gemini model
   - `NARA_MODEL` = your Nara model
4. **Save** and **redeploy** the Apps Script

## **Verification Steps**

After implementing the fix:

1. **On admin device:**
   - Clear app data/cache
   - Login as admin
   - Add a test API key
   - Check console logs for "pushApiKeys success"

2. **On another device:**
   - Clear app data/cache
   - Login
   - Wait 30 seconds for sync
   - Try AI scan - it should work
   - Check SharedPreferences for the synced key

3. **Check Apps Script logs:**
   - Should show "saveApiKeys" action received
   - Verify Script Properties contain the keys

## **Why This Wasn't Caught**

The code has extensive documentation about keys living in Apps Script (line 592-629 in `sync_service.dart`), but there's no matching **push** function - only pull (`_fetchApiKeysFromAppsScript`). This is a one-way sync issue.

## **Impact**

- ⚠️ **High Priority**: Without syncing keys, all non-admin devices fall back to offline AI analysis
- 🔍 **Silent Failure**: No error shown to users, just slower/missing hazard detection
- 👥 **Affects**: All users except the one admin who entered keys

## **Related Files**

- `lib/services/sync_service.dart` (lines 596-686)
- `lib/services/admin_master_data.dart` (line 857)
- `lib/services/gemini_vision.dart` (line 1402)
- `apps_script_v14.js` (or your Apps Script file)
- `lib/screens/admin_screen.dart` (admin panel UI)

---

**Created:** 2026-10-11  
**Status:** CRITICAL - Blocking multi-device deployment
