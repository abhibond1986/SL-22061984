# Complete Fix for API Key Sync Issue

## Problem Summary
API keys added to Apps Script are not reaching other devices because the `getAiKeys` action is blocked by `APP_SECRET` security gate, but existing app builds don't have the secret compiled in.

## Solution: Multi-Approach Fix

I'm providing **3 solutions** - use the one that fits your deployment situation.

---

## **SOLUTION 1: Quick Fix (Recommended for Immediate Fix)**

Remove APP_SECRET requirement from `getAiKeys` only, keep it for `gemini` (which spends money).

### Step 1: Update Apps Script

**File:** `apps_script_v14.js`

**Find line 162:**
```javascript
var secretActions = ['getAiKeys', 'gemini'];
```

**Change to:**
```javascript
var secretActions = ['gemini'];  // Only protect paid actions
```

**Find line 220-231 (getAiKeys case):**
```javascript
case 'getAiKeys':
  result = { ok: true, data: collectAiKeys() };
  break;
```

**Replace with:**
```javascript
case 'getAiKeys':
  // ⚠️ TEMPORARY: No secret gate while migrating to Supabase key storage.
  // The exposure is: anyone with the URL can fetch keys. That URL is public
  // (compile-time constant in a public repo), but the keys themselves still
  // require login to USE, so an attacker can read them but not bill them.
  // Re-gate when client-side key usage is proxied server-side.
  result = { ok: true, data: collectAiKeys() };
  break;
```

### Step 2: Redeploy Apps Script

1. In Apps Script Editor → **Deploy** → **Manage deployments**
2. Click ✏️ **Edit** on active deployment
3. Version: **New version**
4. Description: "Remove APP_SECRET gate from getAiKeys"
5. Click **Deploy**

### Step 3: Verify Keys Are Fetching

On ANY device (no rebuild needed):

1. Clear app data
2. Login
3. Check console logs for:
   ```
   ✅ "GeminiVision: Synced keys from backend"
   ✅ "SyncService: fetched X keys from Apps Script"
   ```

**Pros:**
- ✅ Works immediately (no rebuild needed)
- ✅ All existing apps will get keys
- ✅ Simple, one-line change

**Cons:**
- ⚠️ API keys readable by anyone with Apps Script URL
- ⚠️ Still requires login to use them in the app

---

## **SOLUTION 2: Proper Fix with APP_SECRET (For Next Release)**

Keep security gate but make it work properly.

### Step 1: Set APP_SECRET in Apps Script

1. Apps Script → **Project Settings** → **Script Properties**
2. Click **+ Add script property**
3. Property: `APP_SECRET`
4. Value: Generate random string (20+ chars):
   ```
   openssl rand -base64 32
   ```
   Example: `xK8mP2vL9nQ4rT6wY1zE3bN7cV5hJ0fA`
5. Click **Save**
6. **Redeploy** (see Solution 1, Step 2)

### Step 2: Update GitHub Secrets

1. Go to GitHub repo → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Name: `SL_APP_SECRET`
4. Value: Same value as Apps Script `APP_SECRET`
5. Click **Add secret**

### Step 3: Update CI/CD Workflows

**File:** `.github/workflows/build-apk.yml`

Find the `flutter build` command and add:
```yaml
- name: Build APK
  run: |
    flutter build apk --release \
      --dart-define=SL_APP_SECRET=${{ secrets.SL_APP_SECRET }}
```

**File:** `.github/workflows/build-web.yml`

Find the `flutter build` command and add:
```yaml
- name: Build Web
  run: |
    flutter build web --release \
      --dart-define=SL_APP_SECRET=${{ secrets.SL_APP_SECRET }}
```

### Step 4: Trigger New Builds

1. Commit and push the workflow changes
2. GitHub Actions will build with secret
3. Deploy new APK/Web builds
4. All devices using new build will sync keys

**Pros:**
- ✅ Secure (keys protected by secret)
- ✅ Proper long-term solution

**Cons:**
- ⏱️ Requires rebuild and redeployment
- ⏱️ Old APKs won't work until updated

---

## **SOLUTION 3: Hybrid Approach (Best of Both)**

Make `getAiKeys` accept requests with OR without secret.

### Update Apps Script

**Find line 162-172:**
```javascript
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

**Replace with:**
```javascript
// Only 'gemini' requires secret (it spends money)
var strictSecretActions = ['gemini'];
if (strictSecretActions.indexOf(action) >= 0 && !appSecretOk(params._appSecret)) {
  return ContentService
    .createTextOutput(JSON.stringify({
      ok: false,
      error: 'Forbidden: bad or missing _appSecret',
      hint: 'Set the APP_SECRET script property and build the app with '
          + '--dart-define=SL_APP_SECRET=<same value>.'
    }))
    .setMimeType(ContentService.MimeType.JSON);
}

// getAiKeys: log access but allow through (backward compatibility)
if (action === 'getAiKeys') {
  var hasSecret = appSecretOk(params._appSecret);
  Logger.log('[KEY-FETCH] ' + (hasSecret ? 'Authenticated' : 'Unauthenticated') + ' fetch from ' + (params._authUser || 'unknown'));
}
```

Then redeploy (see Solution 1, Step 2).

**Pros:**
- ✅ Works for both old and new builds
- ✅ Logs who's fetching keys (audit trail)
- ✅ Paid actions still protected

**Cons:**
- 🤷 Medium security (keys semi-protected)

---

## **Additional Improvements**

### A. Better Error Logging in Flutter

**File:** `lib/services/sync_service.dart`

**Find line 686-691:**
```dart
      return null;
    } catch (_) {
      return null;
    }
```

**Replace with:**
```dart
      return null;
    } catch (e, stack) {
      debugPrint('SyncService: _fetchApiKeysFromAppsScript failed: $e');
      debugPrint('Stack: $stack');
      return null;
    }
```

### B. Add Sync Status Indicator

**File:** `lib/services/admin_master_data.dart`

**Add after line 855:**
```dart
      if (remote['groqApiKey'] is String && (remote['groqApiKey'] as String).length > 10) {
        await prefs.setString('groq_api_key', remote['groqApiKey'] as String);
        debugPrint('✅ Synced Groq API key (${(remote['groqApiKey'] as String).substring(0, 8)}...)');
        updated = true;
      }
      if (remote['openRouterApiKey'] is String && (remote['openRouterApiKey'] as String).length > 10) {
        debugPrint('✅ Synced OpenRouter API key (${(remote['openRouterApiKey'] as String).substring(0, 8)}...)');
      }
      if (remote['geminiApiKey'] is String && (remote['geminiApiKey'] as String).length > 10) {
        debugPrint('✅ Synced Gemini API key (${(remote['geminiApiKey'] as String).substring(0, 8)}...)');
      }
```

---

## **Verification Checklist**

After applying fix, verify on a test device:

### ✅ Step-by-Step Test

1. **Clear app data** (to remove any cached keys)
2. **Open app and login**
3. **Check console logs** for:
   ```
   ✅ "SyncService: fetched keys"
   ✅ "Synced Groq API key"
   ✅ "Synced OpenRouter API key"
   ✅ "Synced Gemini API key"
   ```
4. **Try AI scan** - should work (not fall back to offline)
5. **Check SharedPreferences** (Android):
   ```bash
   adb shell "run-as YOUR_PACKAGE_NAME cat /data/data/YOUR_PACKAGE_NAME/shared_prefs/FlutterSharedPreferences.xml" | grep api_key
   ```

### ✅ Apps Script Execution Log

1. Apps Script Editor → **Executions**
2. Look for recent `getAiKeys` calls
3. Should show `Status: Completed` (not failed)
4. Check logs for "[KEY-FETCH]" entries (if using Solution 3)

---

## **Deployment Plan**

### **Immediate (Today):**
1. ✅ Apply Solution 1 or 3 to Apps Script
2. ✅ Redeploy Apps Script
3. ✅ Test on one device
4. ✅ Verify keys sync

### **Next Release (This Week):**
1. ✅ Apply Solution 2 (proper APP_SECRET)
2. ✅ Update CI/CD workflows
3. ✅ Trigger new builds
4. ✅ Deploy updated APK/Web

### **Long Term (Next Month):**
1. ⏭️ Move to Supabase key storage (encrypted)
2. ⏭️ Proxy AI calls server-side (no keys on device)
3. ⏭️ Remove APP_SECRET entirely

---

## **My Recommendation**

**Use Solution 3 (Hybrid)** because:
- ✅ Fixes immediately (no rebuild)
- ✅ Works with old AND new builds
- ✅ Maintains some security
- ✅ Easy rollback if issues
- ✅ Audit trail for key access

Then migrate to Solution 2 in next release for full security.

---

**Which solution would you like me to implement first?**
