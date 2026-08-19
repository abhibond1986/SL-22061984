# Apps Script Deployment Guide

## NaraRouter Vision Proxy Setup

This guide explains how to deploy the NaraRouter vision proxy to enable AI hazard scanning on the web version of Safety Lens.

### Problem
`router.bynara.id` does not send CORS headers, so browsers block all responses from it. This makes NaraRouter completely unusable on web, even when a valid API key is configured.

### Solution
Apps Script runs server-side and bypasses CORS restrictions. It acts as a proxy between the Flutter web app and NaraRouter.

---

## Deployment Steps

### 1. Open Your Apps Script Project

1. Go to [Google Apps Script](https://script.google.com)
2. Open your existing Safety Lens Apps Script project (the one containing AlertSystem.gs)

### 2. Add the New Proxy File

1. Click the **+** button next to **Files**
2. Name it: `NaraVisionProxy`
3. Paste the contents of `NaraVisionProxy.gs` into the new file
4. Click **Save** (Ctrl+S)

### 3. Update Your Main doPost() Function

Find your main `doPost()` function and add this line with your other action handlers:

```javascript
function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const action = data.action;

    // ... your existing actions (syncAlertRules, fireAlert, etc.) ...

    // NaraRouter vision proxy — ADD THIS LINE
    if (action === 'analyzeImageNara') return handleAnalyzeImageNara_(data);

    // ... rest of your doPost() ...
  } catch (e) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}
```

### 4. Configure Script Properties

1. In Apps Script, click **Project Settings** (⚙️ icon on the left)
2. Scroll down to **Script Properties**
3. Click **Add script property**
4. Add the following property:
   - **Property**: `NARA_API_KEY`
   - **Value**: Your NaraRouter API key (starts with `sk-nry-`)
5. Click **Save script properties**

### 5. Deploy the Web App

#### If this is your first deployment:
1. Click **Deploy** → **New deployment**
2. Click the gear icon ⚙️ next to **Select type**
3. Choose **Web app**
4. Configure:
   - **Description**: "Safety Lens Backend v35 + NaraRouter Proxy"
   - **Execute as**: Me (your account)
   - **Who has access**: Anyone (required for the Flutter app to call it)
5. Click **Deploy**
6. Copy the **Web app URL** — you'll need this in the Safety Lens app

#### If you already have a deployment:
1. Click **Deploy** → **Manage deployments**
2. Click the ✏️ (Edit) icon next to your active deployment
3. Click **Version** → **New version**
4. Update the description: "Safety Lens Backend v35 + NaraRouter Proxy"
5. Click **Deploy**
6. The Web app URL stays the same

### 6. Test the Proxy (Optional)

1. In Apps Script, open `NaraVisionProxy.gs`
2. Click the function dropdown (next to "Debug")
3. Select `testNaraVisionProxy`
4. Click **Run**
5. Click **View** → **Execution log** to see the test result

---

## Verification in Safety Lens App

After deployment:

1. Open Safety Lens web app at https://safetylens.in
2. Go to **Admin → System Health**
3. Verify:
   - ✅ **NaraRouter Connected** (green checkmark)
   - The API key shows as configured
4. Try an AI Hazard Scan
5. Open browser DevTools (F12) → **Console**
6. Look for logs like:
   ```
   GeminiVision: ▶ NaraRouter mistral-medium-3-5 (separate allowance)...
   GeminiVision: ✓ NaraRouter SUCCESS in XXXXms
   ```

---

## Troubleshooting

### "Apps Script URL not configured"
- In Safety Lens, go to **Settings** → enter your Apps Script Web app URL
- Make sure it ends with `/exec` (not `/dev`)

### "NaraRouter API key not configured in Script Properties"
- Double-check Script Properties in Apps Script project
- Make sure the key starts with `sk-nry-`
- Re-deploy after adding the property

### "⏭ NaraRouter skipped (no key configured)"
- In Safety Lens app, go to **Admin → System Health**
- Enter your NaraRouter API key in the **NaraRouter** section
- Wait for sync (happens automatically on app launch)

### Still getting CORS errors on web
- Make sure you're using the Apps Script proxy (check console logs)
- Verify the proxy is deployed and the URL is configured in Settings
- Check that `action === 'analyzeImageNara'` is in your `doPost()` function

---

## Architecture

```
┌─────────────────┐
│  Flutter Web    │
│  (Browser)      │
└────────┬────────┘
         │ HTTP POST (no CORS issues)
         │ { action: "analyzeImageNara", imageBase64, prompt, model }
         ▼
┌─────────────────┐
│  Apps Script    │
│  (Server-side)  │
└────────┬────────┘
         │ HTTP POST (CORS-free)
         │ Authorization: Bearer sk-nry-...
         ▼
┌─────────────────┐
│  NaraRouter     │
│  router.bynara  │
│      .id        │
└─────────────────┘
```

**Benefits:**
- ✅ NaraRouter works on web (bypasses CORS)
- ✅ API key stays secure in Apps Script (never sent to client)
- ✅ Mobile/desktop apps still call NaraRouter directly (no proxy overhead)
- ✅ Adds ~200-500ms latency on web, but that's negligible vs 10-20s model inference

---

## Cost

**Apps Script:**
- ✅ FREE up to 20,000 URL Fetch calls per day
- Each hazard scan = 1 call
- Well within limits for typical usage

**NaraRouter:**
- Uses your existing NaraRouter quota (token-based, not request-based)
- No additional cost from using the proxy

---

## Support

If you encounter issues:
1. Check the Apps Script **Execution log** for errors
2. Check the browser **Console** (F12) for client-side errors
3. Verify all Script Properties are set correctly
4. Make sure the deployment is active (not archived)
