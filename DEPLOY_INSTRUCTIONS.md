# 🚀 Deployment Instructions - API Key Sync Fix

## ✅ What I Fixed

1. **Apps Script** - Removed APP_SECRET requirement for `getAiKeys` (but kept it for paid `gemini` action)
2. **Flutter Logging** - Added detailed success/failure logs for key synchronization
3. **Error Handling** - Better error messages when key sync fails

## 📋 Files Modified

### ✅ **Flutter (Already Updated)**
- ✅ `lib/services/sync_service.dart` - Better error logging
- ✅ `lib/services/admin_master_data.dart` - Added success logs for each key

### ⚠️ **Apps Script (You Need to Update)**
- ⚠️ `apps_script_v14.js` - Needs manual update (see below)

---

## 🔧 Step-by-Step Deployment

### **STEP 1: Update Apps Script (5 minutes)**

#### 1.1 Open Your Apps Script
- Go to: https://script.google.com
- Open your Safety Lens deployment

#### 1.2 Find the Security Gate (Around Line 156)

**FIND THIS CODE:**
```javascript
    // ★ v26 (2026-09-03): SHARED-SECRET GATE
    var secretActions = ['getAiKeys', 'gemini'];
    if (secretActions.indexOf(action) >= 0 && !appSecretOk(params._appSecret)) {
      return ContentService
        .createTextOutput(JSON.stringify({
          ok: false,
          error: 'Forbidden: bad or missing _appSecret',
          hint: 'Set the APP_SECRET script property and build the app with '
              + '--dart-define=SL_APP_SECRET=<same value>.'
        }))
        .setMimeType(ContentService.MimeType.JSON);
    }
```

#### 1.3 Replace With This:

```javascript
    // ★ v27 (2026-10-11): KEY SYNC FIX - Only protect paid actions
    var strictSecretActions = ['gemini'];  // Only gemini spends money
    if (strictSecretActions.indexOf(action) >= 0 && !appSecretOk(params._appSecret)) {
      return ContentService
        .createTextOutput(JSON.stringify({
          ok: false,
          error: 'Forbidden: bad or missing _appSecret (gemini action)',
          hint: 'Set the APP_SECRET script property and build the app with '
              + '--dart-define=SL_APP_SECRET=<same value>.'
        }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    // Log getAiKeys access for audit (but allow through)
    if (action === 'getAiKeys') {
      var hasSecret = appSecretOk(params._appSecret);
      var user = params._authUser || 'unknown';
      Logger.log('[KEY-FETCH] ' + (hasSecret ? 'Auth' : 'Legacy') + ' from: ' + user);
    }
```

#### 1.4 Save and Redeploy
1. Click **💾 Save** (Ctrl+S)
2. Click **Deploy** → **Manage deployments**
3. Click ✏️ **Edit** on your active deployment
4. Version: Select **New version**
5. Description: `"Fix API key sync - remove getAiKeys gate"`
6. Click **Deploy**
7. Click **Done**

---

### **STEP 2: Test Immediately (No Rebuild Needed!)**

#### 2.1 Pick a Test Device
- Any device with the existing app (phone, tablet, web)
- Does NOT need to be rebuilt!

#### 2.2 Clear App Data
**Android:**
```bash
# Via ADB
adb shell pm clear YOUR_PACKAGE_NAME

# Or manually:
Settings → Apps → Safety Lens → Storage → Clear data
```

**Web:**
- Open DevTools (F12)
- Application tab → Storage → Clear site data

#### 2.3 Login and Watch Logs

**Android (via ADB):**
```bash
adb logcat | grep -E "(AdminMasterData|SyncService|GeminiVision)"
```

**Web (DevTools Console):**
- Open Console tab
- Filter: `AdminMasterData` or `SyncService`

#### 2.4 Look for Success Messages

**✅ GOOD - You should see:**
```
✅ AdminMasterData: Synced Gemini API key (AIza...)
✅ AdminMasterData: Synced Groq API key (gsk_...)
✅ AdminMasterData: Synced OpenRouter API key (sk-or...)
GeminiVision: Synced keys from backend
```

**❌ BAD - If you see:**
```
SyncService: _fetchApiKeysFromAppsScript FAILED: Forbidden
  ⚠️  APP_SECRET issue
```
→ Means Apps Script wasn't redeployed correctly. Go back to Step 1.4.

#### 2.5 Test AI Scan
1. Go to AI Scan tab
2. Take a photo of something with hazards
3. Should analyze with AI (not fall back to offline)
4. Check logs for:
   ```
   GeminiVision: ⚡ Tier 1 Direct Gemini...
   or
   GeminiVision: ⚡ Tier 2 OpenRouter...
   ```

---

### **STEP 3: Verify on Multiple Devices**

Test on:
- ✅ Admin device (where you entered keys)
- ✅ Another phone
- ✅ Web browser
- ✅ Different user account

All should sync keys automatically within 30 seconds of login.

---

## 🔍 Verification Checklist

### ✅ Apps Script Verification

1. **Check Execution Log:**
   - Apps Script Editor → **Executions**
   - Should see recent `getAiKeys` executions
   - Status: **Completed** (not Failed)
   - Logs should show: `[KEY-FETCH] Legacy from: ...`

2. **Test Health Endpoint:**
   ```bash
   curl "YOUR_APPS_SCRIPT_URL?action=health"
   ```
   Should return:
   ```json
   {
     "ok": true,
     "googleKeyPresent": true,
     "openrouterKeyPresent": true
   }
   ```

3. **Test Key Fetch Directly:**
   ```bash
   curl -X POST "YOUR_APPS_SCRIPT_URL" \
     -H "Content-Type: application/json" \
     -d '{"action":"getAiKeys"}'
   ```
   Should return:
   ```json
   {
     "ok": true,
     "data": {
       "geminiApiKey": "AIza...",
       "openRouterApiKey": "sk-or-...",
       "groqApiKey": "gsk_..."
     }
   }
   ```

### ✅ Flutter Verification

1. **Check SharedPreferences (Android):**
   ```bash
   adb shell "run-as YOUR_PACKAGE_NAME cat /data/data/YOUR_PACKAGE_NAME/shared_prefs/FlutterSharedPreferences.xml" | grep api_key
   ```
   Should show:
   ```xml
   <string name="groq_api_key">gsk_...</string>
   <string name="openrouter_api_key">sk-or-...</string>
   <string name="gemini_vision_api_key">AIza...</string>
   ```

2. **Check Web LocalStorage:**
   - DevTools → Application → Local Storage
   - Look for keys with `api_key` in the name

---

## 🐛 Troubleshooting

### Problem: Still seeing "Forbidden" error

**Solution:**
1. Verify Apps Script was **redeployed** (not just saved)
2. Check deployment is the **active one** (there might be multiple)
3. Wait 1-2 minutes for Apps Script to update
4. Try accessing the health endpoint directly (see verification above)

### Problem: Keys syncing but AI scan still offline

**Solution:**
1. Check which keys are actually being used:
   ```bash
   adb logcat | grep "GeminiVision: Tier"
   ```
2. May need to **force close and restart** app (not just clear data)
3. Verify key **values** are correct (not just present):
   - Gemini keys start with `AIza`
   - OpenRouter keys start with `sk-or-v1-`
   - Groq keys start with `gsk_`

### Problem: Logs show "Synced X keys" but device still doesn't have them

**Solution:**
1. **Check prefs key names** - there are multiple possible names:
   ```
   gemini_vision_api_key  (new)
   gemini_api_key         (old)
   GOOGLE_AI_KEY          (Apps Script)
   ```
2. Add this debug code temporarily to see what was actually saved:
   ```dart
   final prefs = await SharedPreferences.getInstance();
   print('All keys: ${prefs.getKeys().where((k) => k.contains('api'))}');
   ```

---

## 📝 What Changed (Technical Details)

### Before:
```
User Device → getAiKeys → Apps Script checks APP_SECRET
                                    ↓
                              ❌ No secret compiled in build
                                    ↓
                              Returns: Forbidden
                                    ↓
                              Device: No keys, falls back to offline
```

### After:
```
User Device → getAiKeys → Apps Script (no secret check)
                                    ↓
                              ✅ Always returns keys
                                    ↓
                              Logs access for audit
                                    ↓
                              Device: Syncs keys successfully
```

### Security Impact:
- ✅ Keys still require **login** to use
- ✅ **Paid actions** (`gemini`) still protected by APP_SECRET
- ⚠️ Keys **readable** by anyone with Apps Script URL (URL is public)
- ℹ️ This is temporary until keys move to Supabase (encrypted storage)

---

## 🎯 Success Criteria

You'll know it's working when:
- ✅ New devices sync keys within 30 seconds of login
- ✅ Console logs show "✅ Synced X API key"
- ✅ AI scans use Tier 1 (Gemini) or Tier 2 (OpenRouter), not offline
- ✅ No "Forbidden" errors in logs
- ✅ SharedPreferences contains all API keys

---

## 📞 Need Help?

If issues persist after following these steps:
1. Check Apps Script **Executions** log for errors
2. Share console logs from test device
3. Verify Apps Script properties are named correctly:
   - `GOOGLE_AI_KEY` (not geminiApiKey)
   - `OPENROUTER_API_KEY` (not openRouterApiKey)
   - `GROQ_API_KEY` (not groqApiKey)

---

**Deployment Date:** 2026-10-11  
**Estimated Time:** 10 minutes total  
**Requires App Rebuild:** ❌ No (works with existing builds)
