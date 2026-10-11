# API Key Sync - Troubleshooting Checklist

You mentioned you've already added API keys to Apps Script. Keys are still not syncing because one of these 3 issues:

## ✅ **Checklist (Do ALL 3)**

### **1. Verify EXACT Property Names in Apps Script**

The property names **MUST** match exactly (case-sensitive, with underscores):

Go to: **Apps Script → Project Settings → Script Properties**

| ❌ WRONG (won't work) | ✅ CORRECT (must use) | Example Value |
|---|---|---|
| `geminiApiKey` | **`GOOGLE_AI_KEY`** | `AIza...` |
| `geminiKey` | **`GOOGLE_AI_KEY`** | `AIza...` |
| `openRouterApiKey` | **`OPENROUTER_API_KEY`** | `sk-or-v1-...` |
| `openrouter_api_key` | **`OPENROUTER_API_KEY`** | `sk-or-v1-...` |
| `openRouterApiKey2` | **`OPENROUTER_API_KEY_2`** | `sk-or-v1-...` |
| `groqApiKey` | **`GROQ_API_KEY`** | `gsk_...` |
| `naraApiKey` | **`NARA_API_KEY`** | `sk-nry-...` |

**Action:** Check your Script Properties right now. If names don't match exactly, delete wrong ones and add with correct names.

---

### **2. APP_SECRET MUST Be Set (Critical!)**

Since 2026-09-03, `getAiKeys` action is **blocked** without `APP_SECRET`. This is a security gate.

**Check if you have it:**
- Go to: **Apps Script → Project Settings → Script Properties**
- Look for: **`APP_SECRET`**

**If missing, add it:**

1. Click **+ Add script property**
2. Property: `APP_SECRET`
3. Value: Any long random string (e.g., `your-secret-key-here-make-it-long-and-random`)
4. Click **Save**

**Then you MUST:**
- **Redeploy** the Apps Script (see step 3)
- **Rebuild** the Flutter app with matching secret:
  ```bash
  flutter build apk --release --dart-define=SL_APP_SECRET=your-secret-key-here-make-it-long-and-random
  ```

⚠️ **Without APP_SECRET:** All devices get `Forbidden: bad or missing _appSecret` error and fall back to offline AI.

---

### **3. Redeploy Apps Script (CRITICAL)**

**Property changes don't take effect until you redeploy!**

Your old deployment is still running the old code/properties.

**How to redeploy:**

1. **In Apps Script Editor:**
   - Click **Deploy** → **Manage deployments**
   - Click ✏️ **Edit** on your active deployment
   - Under "Version": Select **New version**
   - Add description: "Updated API keys"
   - Click **Deploy**

2. **Alternative (New Deployment):**
   - Click **Deploy** → **New deployment**
   - Type: **Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
   - Click **Deploy**
   - **Copy the new Web app URL**
   - Update `_defaultBackendUrl` in `lib/services/sync_service.dart` line 33-34

⚠️ **Until you redeploy:** The old code is still running, and your property changes are invisible to all devices.

---

## **4. Verification Steps**

After completing ALL 3 steps above:

### **A. Test from Admin Device**

1. Open the app
2. Go to admin console → Check console/logs
3. Look for:
   - ✅ **Success**: `"GeminiVision: Synced keys from backend"` 
   - ❌ **Failure**: `"Forbidden: bad or missing _appSecret"` → Go back to step 2
   - ❌ **Empty keys**: Apps Script returns `ok: true` but empty data → Check step 1

### **B. Test Apps Script Direct**

Open this URL in your browser (replace with your deployment URL):

```
https://script.google.com/macros/s/YOUR_DEPLOYMENT_ID/exec?action=health
```

Should return:
```json
{
  "ok": true,
  "version": "v25",
  "googleKeyPresent": true,     ← Should be true
  "openrouterKeyPresent": true,  ← Should be true
  "primaryProvider": "google"
}
```

If both are `false` → Go back to step 1 (property names wrong)

### **C. Force Sync on Other Device**

1. Clear app data/cache
2. Login
3. Wait 30 seconds (background sync runs)
4. Try AI scan → should work now
5. Check device logs for "groq_api_key" being saved to SharedPreferences

---

## **Common Mistakes**

| ❌ What You Might Have Done | ✅ What You Need |
|---|---|
| Added keys with camelCase names | Use UPPERCASE_WITH_UNDERSCORES |
| Set properties but didn't redeploy | Click **Deploy → Manage deployments → Edit → Deploy** |
| Forgot APP_SECRET | Must be set since 2026-09-03 |
| Saved keys in admin panel only | Admin panel saves locally only, not to Apps Script |
| Used old deployment URL | After new deployment, update Flutter code with new URL |

---

## **Quick Debug Commands**

### **Check Console Logs (Admin Device)**

Look for these in browser DevTools or `adb logcat`:

```
✅ GOOD: "GeminiVision: Synced keys from backend"
✅ GOOD: "SyncService: getAiKeys returned X keys"

❌ BAD: "Forbidden: bad or missing _appSecret"
    → APP_SECRET not set or doesn't match build

❌ BAD: "SyncService: getAiKeys returned 0 keys"  
    → Property names wrong or Apps Script not redeployed

❌ BAD: "GeminiVision: provider key missing"
    → Keys not reaching devices
```

### **Check SharedPreferences on Other Device**

If you have ADB access:

```bash
# Android
adb shell "run-as com.your.app cat /data/data/com.your.app/shared_prefs/FlutterSharedPreferences.xml" | grep api_key

# Should show:
# <string name="groq_api_key">gsk_...</string>
# <string name="openrouter_api_key">sk-or-v1-...</string>
```

---

## **Still Not Working?**

If you've verified ALL 3 steps and keys still aren't syncing:

1. **Check Apps Script logs:**
   - Apps Script Editor → **Executions**
   - Look for `getAiKeys` calls
   - Check for errors

2. **Verify Supabase is enabled:**
   - Check `lib/services/supabase_config.dart`
   - If `enabled = true`, keys fetch from Apps Script via line 598 in `sync_service.dart`

3. **Test with curl:**
   ```bash
   curl -X POST "YOUR_APPS_SCRIPT_URL" \
     -H "Content-Type: application/json" \
     -d '{"action":"getAiKeys","_appSecret":"your-secret-here"}'
   ```
   Should return keys in JSON.

---

**Most Likely Issue:** Step 3 (Apps Script not redeployed after adding properties)

**Created:** 2026-10-11
