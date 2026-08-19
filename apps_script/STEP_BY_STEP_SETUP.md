# 📋 Step-by-Step Apps Script Setup Guide
## For Safety Lens NaraRouter Proxy

**Your Apps Script Project:**  
https://script.google.com/home/projects/164MNqEkURNE_7t55cGoX9OkTGx-QIcEN90PrdA5wRv31pZHpiQPtw4H6/edit

---

## Step 1: Open Your Apps Script Project

1. **Click the link above** or go to https://script.google.com
2. This is the **"Nara Router"** project — the AI proxy only. It is *not* the
   app's sync backend, which is a different project entirely.

---

## Step 2: Add the Main Handler File

### 2.1 Create Main.gs

1. In your Apps Script editor, look for the **Files** section on the left
2. Click the **+** (plus) icon next to "Files"
3. Click **Script**
4. Name it: `Main`
5. It will create `Main.gs`

### 2.2 Copy the Content

1. Open the file `C:\Users\DELL\Desktop\SL-22061984\apps_script\Main.gs` on your computer
2. **Select all** (Ctrl+A) and **Copy** (Ctrl+C)
3. Go back to Apps Script editor
4. **Select all** in the `Main.gs` file (Ctrl+A)
5. **Paste** (Ctrl+V) to replace everything
6. Click **Save** (Ctrl+S or the disk icon)

---

## Step 3: Add the NaraRouter Proxy File

### 3.1 Create NaraVisionProxy.gs

1. Click the **+** icon next to "Files" again
2. Click **Script**
3. Name it: `NaraVisionProxy`
4. It will create `NaraVisionProxy.gs`

### 3.2 Copy the Content

1. Open `C:\Users\DELL\Desktop\SL-22061984\apps_script\NaraVisionProxy.gs` on your computer
2. **Select all** (Ctrl+A) and **Copy** (Ctrl+C)
3. Go back to Apps Script editor
4. **Select all** in the `NaraVisionProxy.gs` file (Ctrl+A)
5. **Paste** (Ctrl+V)
6. Click **Save** (Ctrl+S)

**Your files should now look like this:**
```
📁 Files
  ├── 📄 Main.gs            ← doPost router
  └── 📄 NaraVisionProxy.gs ← NaraRouter proxy
```

`AlertSystem.gs` belongs to the **main backend** project, not this one. Do not add
it here: two projects both defining `getMasterData` or the alert handlers is how
you end up with one of them silently shadowing the other.

---

## Step 4: Configure Script Properties (API Keys)

### 4.1 Open Project Settings

1. On the **left sidebar**, click the **⚙️ (gear icon)** labeled "Project Settings"
2. Scroll down until you see **Script Properties** section

### 4.2 Add NARA_API_KEY

1. Under Script Properties, click **"Add script property"**
2. You'll see two input fields:
   - **Property:** Enter `NARA_API_KEY`
   - **Value:** Enter your NaraRouter API key (starts with `sk-nry-`)
     - Get it from: https://router.bynara.id (if you don't have one yet)
3. Click **"Save script properties"** at the bottom

### 4.3 Verify

Your Script Properties should show:
```
Property               Value
NARA_API_KEY          sk-nry-xxxxxxxxxx... (hidden after save)
```

**Optional:** If you use SMS alerts, also add:
- Property: `SMS_API_KEY`
- Value: Your Fast2SMS/MSG91 key

---

## Step 5: Test the Setup (Before Deploying)

### 5.1 Run the Test Function

1. At the top of the editor, find the **function dropdown** (it says "Select function")
2. Click it and select **`testDeployment`**
3. Click the **▶️ Run** button next to it

### 5.2 Authorize the Script (First Time Only)

If this is your first time running the script, you'll see:
1. **"Authorization required"** popup
2. Click **"Review permissions"**
3. Choose your Google account
4. You might see **"Google hasn't verified this app"**
   - Click **"Advanced"**
   - Click **"Go to [Your Project Name] (unsafe)"** (it's safe, it's YOUR script)
5. Click **"Allow"**

### 5.3 Check the Results

1. After running, click **"View"** → **"Execution log"** (or Ctrl+Enter)
2. You should see output like:
   ```
   ════════════════════════════════════════════
   Testing SAIL Safety Lens Apps Script Setup
   ════════════════════════════════════════════

   ✓ Test 1: Script Properties
     ✅ NARA_API_KEY: sk-nry-...
     ⚠️  SMS_API_KEY: Not configured (optional)

   ✓ Test 2: Deployment URL
     📍 URL: https://script.google.com/...

   ✓ Test 3: Function Availability
     ✅ handleSyncAlertRules_
     ✅ handleFireAlert_
     ✅ handleAnalyzeImageNara_

   ✓ Test 4: Testing doPost()
     ✅ doPost() is working correctly

   ════════════════════════════════════════════
   Setup test complete!
   ════════════════════════════════════════════
   ```

✅ If you see all green checkmarks, you're ready to deploy!

---

## Step 6: Deploy as Web App

### 6.1 Check for Existing Deployment

1. Click **"Deploy"** button (top right, blue button)
2. Click **"Manage deployments"**

**Do you see an existing deployment?**

---

### Option A: You HAVE an Existing Deployment

1. Click the **✏️ (Edit/pencil icon)** next to the active deployment
2. Click **"Version"** dropdown
3. Select **"New version"**
4. Update **Description** to: `Safety Lens v35 + NaraRouter Proxy`
5. Click **"Deploy"**
6. ✅ **The Web app URL stays the same** (already configured in your app)
7. Click **"Done"**

---

### Option B: You DON'T Have an Existing Deployment (First Time)

1. Click **"Deploy"** → **"New deployment"**
2. Click the **⚙️ (gear icon)** next to "Select type"
3. Choose **"Web app"**
4. Configure the settings:
   - **Description:** `Safety Lens v35 + NaraRouter Proxy`
   - **Execute as:** **Me** (your-email@gmail.com)
   - **Who has access:** **Anyone** ⚠️ Important: Must be "Anyone" for Flutter to call it
5. Click **"Deploy"**
6. You'll see a **"Web app URL"** — **COPY THIS!**
   - It looks like: `https://script.google.com/macros/s/ABCD.../exec`
7. Click **"Done"**

---

## Step 7: Configure the URL in Safety Lens App

### ⛔ 7.0 READ THIS FIRST — there are TWO Apps Script deployments

This proxy is a **separate project** from the app's sync backend:

| Project | URL starts | Serves |
|---|---|---|
| **Main backend** | `.../AKfycbzDiT4OSvlDUxvcM9DYJ...` | Incidents, users, master data |
| **Nara Router** (this one) | `.../AKfycbx0CUXs6VZg-nIzTV...` | `analyzeImageNara` only |

**Never paste the Nara Router URL into the sync/Backend URL field.** That project
has no Incidents sheet and no user records, so every incident upload and every
login lookup would fail. This is a separate field for exactly that reason.

### 7.1 Usually there is nothing to do

The proxy URL is **compiled into the app** as
`NaraVision.defaultProxyUrl`, so every user — web and mobile, first launch,
no admin panel visit — already has it. Skip to Step 8 unless you have
re-deployed to a **new deployment ID**.

### 7.2 Only if the deployment ID changed

1. Go to https://safetylens.in and log in as an admin
2. **Admin → System Health → NaraRouter**
3. Scroll to **"AI Proxy (required for web)"**
4. Paste the `/exec` URL from Step 6 into **Apps Script AI proxy URL**
5. Click **Save Proxy URL**, then **Test**

**Test** tells you which of three things is wrong, without spending any Nara
tokens:

| Result | Meaning |
|---|---|
| ✓ Proxy reachable and NARA_API_KEY is set | Done. |
| NARA_API_KEY is missing | Go back to Step 4.2, then redeploy. |
| WRONG deployment | You pasted the main backend URL. Use the Nara Router one. |
| Did not return JSON | Deployment is archived, or "Who has access" is not **Anyone**. |

Note this override is **per device** (it lives in that browser's local storage).
For a permanent change, update `defaultProxyUrl` in
`lib/services/nara_vision.dart` and rebuild.

---

## Step 8: Verify NaraRouter is Working

### 8.1 Check System Health

1. In Safety Lens app, go to **Admin** → **System Health**
2. In the integrations list, **NaraRouter (Extra scan allowance)** should be green
   - on web: `active via Apps Script proxy` — **this is correct even with no key
     entered in the app.** The key lives in the proxy's Script Properties and is
     never sent to a browser.
   - on mobile: `active — <model>`, which does require a local key

### 8.2 You do NOT need to enter a key for web

A blank key field on web is the normal, intended state. Entering one is optional
and only matters if you later want the app to call Nara directly.

On **mobile**, a key IS required, because phones call `router.bynara.id` directly
(no CORS there, and no reason to add a proxy hop).

⚠ **The key has to be in two places, and this is the easiest thing to get wrong.**
Devices pull keys via `getMasterData`, and that request goes to the **main
backend** — never to this proxy project. So:

| Where | Property | Used by |
|---|---|---|
| **This** (Nara Router) project | `NARA_API_KEY`, `NARA_MODEL` | web scans, server-side |
| **Main backend** project | `NARA_API_KEY`, `NARA_MODEL` in its `getMasterData` | mobile devices |

Putting the key only here makes web work and leaves every phone skipping Tier 1b.
Putting it only in the main backend does the exact reverse. Keep both in step, and
use the **same** model string in both so a scan does not cost 30x more depending
on which device ran it.

### 8.3 Test an AI Scan

1. Go to the **AI Scan** tab, upload a photo, click **Analyze**
2. Open the browser console (F12 → Console)

**✅ Working:**
```
GeminiVision: ▶ NaraRouter mimo-v2.5-free (separate allowance)...
NaraVision: proxy chose mimo-v2.5-free (this device has no model preference — the server default applies)
GeminiVision: ✓ NaraRouter SUCCESS in 3421ms on mimo-v2.5-free
```

Note NaraRouter is **Tier 1b**: it only runs after the OpenRouter models fail or
hit their daily 429. On a scan that OpenRouter serves, you will correctly see
nothing from Nara at all.

**❌ Wrong deployment:**
```
NaraVision: ⚠ Apps Script proxy error: Unknown action: analyzeImageNara
NaraVision: ✗ WRONG DEPLOYMENT. <url> answered but does not handle analyzeImageNara.
```
→ the proxy URL points at the main sync backend. Fix it in Step 7.2.

**⏭ Skipped:**
```
GeminiVision: ⏭ NaraRouter skipped (AI proxy URL is blank — see Admin → NaraRouter)
```
→ someone cleared the override. Clear the field and save to fall back to the
built-in default.

---

## Step 9: Troubleshooting

### ❌ "AI proxy URL is blank"
**Fix:** Admin → System Health → NaraRouter → clear the **Apps Script AI proxy
URL** field and press Save. Blank means "use the built-in default".

---

### ❌ "NaraRouter skipped (...)" on web
The message now names the actual cause — read it rather than guessing. As of
2026-08-19 a **missing app-side key is no longer a cause on web**; the key lives
in Script Properties. If you see an older build still printing
`(no key configured)` on web, that build predates the proxy and the real cause is
CORS, not the key.

Verify the server side with Step 4.2 (`NARA_API_KEY`, case-sensitive, underscore)
and the **Test** button in Step 7.2.

---

### ⚠ Quota draining much faster than expected
Nara meters **tokens per day**, not requests, and the model matters enormously:
`mistral-medium-3-5` is roughly 30x the cost of `mimo-v2.5-free` against the same
allowance.

Two silent traps, both now defended against but worth knowing:

- The app discards a `NARA_MODEL` value that is not one of
  `mistral-medium-3-5`, `stepfun-3.7-flash`, `agnes-2.0-flash`,
  `agnes-2.5-flash`, `mimo-v2.5-free` — and then falls back to
  `mistral-medium-3-5`, the most expensive one. A typo does not error; it just
  costs 30x.
- Run `testDeployment` in Main.gs; it validates the model string for exactly this.

---

### ❌ Console shows: "Apps Script proxy error: NaraRouter API key not configured"
**Fix:** 
- The key is missing from Script Properties (Step 4.2)
- Go to Apps Script → Project Settings → Script Properties
- Add `NARA_API_KEY` with your `sk-nry-...` key

---

### ❌ "CORS error" still appears on web
**This shouldn't happen if the proxy is working. Check:**

1. **Make sure you're on the latest deployment:**
   - Go to Apps Script → Deploy → Manage deployments
   - Verify the active deployment has "v35 + NaraRouter Proxy" description

2. **Check the Apps Script URL ends with `/exec`:**
   - Settings → Apps Script URL
   - Must end with `/exec` not `/dev`

3. **Verify Main.gs has the analyzeImageNara action:**
   - Open Main.gs in Apps Script
   - Search for: `if (action === 'analyzeImageNara')`
   - It should be there

---

### ❌ "Unknown action: analyzeImageNara"
**Fix:**
- Main.gs is missing the NaraRouter handler
- Go back to Step 2 and verify Main.gs has this line:
  ```javascript
  if (action === 'analyzeImageNara') return handleAnalyzeImageNara_(data);
  ```

---

## Step 10: Test on Mobile (Optional)

On **mobile/desktop**, NaraRouter calls directly (no proxy):
1. Open Safety Lens mobile app
2. Go to AI Scan
3. Take a photo and analyze
4. It should work without the Apps Script proxy

**Why?** Mobile doesn't have CORS restrictions, so it can call `router.bynara.id` directly.

---

## 🎉 Success Checklist

✅ Main.gs file created and saved  
✅ NaraVisionProxy.gs file created and saved  
✅ NARA_API_KEY added to Script Properties  
✅ Test function ran successfully  
✅ Web app deployed (or updated)  
✅ Apps Script URL configured in Safety Lens Settings  
✅ NaraRouter shows "Connected" in System Health  
✅ AI Scan works with NaraRouter logs in console

---

## 📞 Need Help?

**Check these logs:**

1. **Apps Script Logs:**
   - Apps Script editor → View → Execution log
   - Run `testDeployment` function to see diagnostics

2. **Browser Console (Web):**
   - Safety Lens web app → F12 → Console tab
   - Try an AI Scan and watch for "NaraVision:" logs

3. **Common Issues:**
   - API key has wrong prefix (must start with `sk-nry-`)
   - Apps Script URL has `/dev` instead of `/exec`
   - Script Properties not saved (click "Save script properties")
   - Old deployment still active (update to new version)

---

## 🔗 Quick Links

- **Your Apps Script Project:** https://script.google.com/home/projects/164MNqEkURNE_7t55cGoX9OkTGx-QIcEN90PrdA5wRv31pZHpiQPtw4H6/edit
- **NaraRouter Dashboard:** https://router.bynara.id
- **Safety Lens Web App:** https://safetylens.in
- **File Locations on Your PC:**
  - Main.gs: `C:\Users\DELL\Desktop\SL-22061984\apps_script\Main.gs`
  - NaraVisionProxy.gs: `C:\Users\DELL\Desktop\SL-22061984\apps_script\NaraVisionProxy.gs`
  - This guide: `C:\Users\DELL\Desktop\SL-22061984\apps_script\STEP_BY_STEP_SETUP.md`

---

**Last updated:** 2026-08-19  
**Version:** 1.0
