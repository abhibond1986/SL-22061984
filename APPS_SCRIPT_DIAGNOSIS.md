# Apps Script Diagnosis Report

**Date**: 2026-10-11  
**Deployment ID**: AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg  
**URL**: https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec

---

## Test Results

### ✅ GET Request (Working)

**Request**: GET to /exec endpoint  
**Response**:
```json
{
  "ok": true,
  "time": "2026-10-11T02:43:33.392Z",
  "version": "v25",
  "primaryProvider": "google",
  "googleKeyPresent": true,
  "openrouterKeyPresent": true,
  "models": ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.0-flash-lite"]
}
```

**Status**: ✅ **Working!**
- Google key is configured ✓
- OpenRouter key is configured ✓
- Script is responding ✓

### ❌ POST Request (Failing)

**Request**: POST with `{"action":"getMasterData"}`  
**Response**: HTTP 200 but returns Google Drive "Page not found" HTML

**Status**: ❌ **Not Working**

---

## Root Cause Analysis

### Issue #1: POST Handler Not Configured

Your Apps Script's `doPost()` function is either:
1. Not properly handling the request
2. Not deployed with correct permissions
3. Returning a redirect that goes to wrong URL

### Issue #2: GET vs POST Mismatch

The app needs to **POST** to get master data, but your script might be:
- Only handling GET requests in `doGet()`
- Not implementing `doPost()` at all
- Implementing `doPost()` but not deployed correctly

---

## Required Functions

Your Apps Script MUST have these two functions:

### 1. doGet() - Status Check
```javascript
function doGet(e) {
  const scriptProps = PropertiesService.getScriptProperties();
  
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    time: new Date().toISOString(),
    version: 'v25',
    primaryProvider: 'google',
    googleKeyPresent: !!scriptProps.getProperty('GEMINI_API_KEY'),
    openrouterKeyPresent: !!scriptProps.getProperty('OPENROUTER_API_KEY'),
    models: ['gemini-2.0-flash', 'gemini-2.5-flash', 'gemini-2.0-flash-lite']
  })).setMimeType(ContentService.MimeType.JSON);
}
```
**Status**: ✅ This is working (confirmed by GET test)

### 2. doPost() - Master Data Handler
```javascript
function doPost(e) {
  try {
    // Parse the incoming request
    const data = JSON.parse(e.postData.contents);
    const action = data.action;
    
    // Handle getMasterData action
    if (action === 'getMasterData') {
      return handleGetMasterData_(data);
    }
    
    // Handle saveMasterData action
    if (action === 'saveMasterData') {
      return handleSaveMasterData_(data);
    }
    
    // Unknown action
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: 'Unknown action: ' + action
    })).setMimeType(ContentService.MimeType.JSON);
    
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: err.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

function handleGetMasterData_(data) {
  const scriptProps = PropertiesService.getScriptProperties();
  
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    data: {
      // Master data lists
      plants: getAllPlants_(),
      departments: getDepartments_(),
      wsaCauses: getWsaCauses_(),
      severities: getSeverities_(),
      statuses: getStatuses_(),
      obsTypes: getObsTypes_(),
      severityScores: getSeverityScores_(),
      
      // AI API Keys - synced to all devices
      geminiApiKey: scriptProps.getProperty('GEMINI_API_KEY') || '',
      geminiModel: scriptProps.getProperty('GEMINI_MODEL') || 'gemini-3.1-flash-lite',
      
      groqApiKey: scriptProps.getProperty('GROQ_API_KEY') || '',
      groqModel: scriptProps.getProperty('GROQ_MODEL') || '',
      
      openRouterApiKey: scriptProps.getProperty('OPENROUTER_API_KEY') || '',
      openRouterApiKey2: scriptProps.getProperty('OPENROUTER_API_KEY_2') || '',
      
      naraApiKey: scriptProps.getProperty('NARA_API_KEY') || '',
      naraModel: scriptProps.getProperty('NARA_MODEL') || 'mistral-medium-3-5',
      
      // Other settings
      branding: getBranding_(),
      spiParams: getSpiParams_(),
      spiCardVisible: getSpiCardVisible_(),
      sopScanTabVisible: getSopScanTabVisible_()
    }
  })).setMimeType(ContentService.MimeType.JSON);
}
```
**Status**: ❌ This is NOT working (POST returns error)

---

## Deployment Requirements

### Permission Settings

Your Apps Script deployment MUST have:

1. **Execute as**: Me (your@email.com)
2. **Who has access**: Anyone
3. **Deployment type**: Web app
4. **Enable POST requests**: Yes (implicit in web app)

### How to Check/Fix

1. Open your Apps Script project
2. Click **Deploy** → **Manage deployments**
3. Find deployment `AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg`
4. Click **Edit** (pencil icon)
5. Verify settings:
   - Execute as: **Me**
   - Who has access: **Anyone**
6. Click **Deploy**
7. **IMPORTANT**: Copy the **NEW** URL (it might change!)

---

## Script Properties Check

Based on the GET response, you have these configured:

| Property | Status | Value |
|----------|--------|-------|
| `GEMINI_API_KEY` | ✅ Present | (hidden) |
| `OPENROUTER_API_KEY` | ✅ Present | (hidden) |
| `OPENROUTER_API_KEY_2` | ❓ Unknown | Check Script Properties |
| `NARA_API_KEY` | ❓ Unknown | Check Script Properties |
| `GROQ_API_KEY` | ❓ Unknown | Check Script Properties |

### How to Check

1. Open your Apps Script
2. Click **Project Settings** (gear icon)
3. Scroll to **Script Properties**
4. Verify these are set:
   - `GEMINI_API_KEY`
   - `OPENROUTER_API_KEY`
   - `OPENROUTER_API_KEY_2` (optional)
   - `NARA_API_KEY` (optional)
   - `GROQ_API_KEY` (optional)

---

## Fix Steps

### Step 1: Verify doPost() Function Exists

Open your Apps Script and check if `doPost()` function exists. If not, add it:

```javascript
function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const action = data.action;
    
    if (action === 'getMasterData') {
      const scriptProps = PropertiesService.getScriptProperties();
      
      return ContentService.createTextOutput(JSON.stringify({
        ok: true,
        data: {
          geminiApiKey: scriptProps.getProperty('GEMINI_API_KEY') || '',
          geminiModel: scriptProps.getProperty('GEMINI_MODEL') || 'gemini-3.1-flash-lite',
          groqApiKey: scriptProps.getProperty('GROQ_API_KEY') || '',
          openRouterApiKey: scriptProps.getProperty('OPENROUTER_API_KEY') || '',
          openRouterApiKey2: scriptProps.getProperty('OPENROUTER_API_KEY_2') || '',
          naraApiKey: scriptProps.getProperty('NARA_API_KEY') || '',
          naraModel: scriptProps.getProperty('NARA_MODEL') || 'mistral-medium-3-5',
          
          // Add your other master data here
          plants: [],
          departments: [],
          wsaCauses: [],
          severities: [],
          statuses: [],
          obsTypes: []
        }
      })).setMimeType(ContentService.MimeType.JSON);
    }
    
    if (action === 'saveMasterData') {
      const scriptProps = PropertiesService.getScriptProperties();
      
      // Save keys to Script Properties
      if (data.geminiApiKey) {
        scriptProps.setProperty('GEMINI_API_KEY', data.geminiApiKey);
      }
      if (data.openRouterApiKey) {
        scriptProps.setProperty('OPENROUTER_API_KEY', data.openRouterApiKey);
      }
      if (data.openRouterApiKey2) {
        scriptProps.setProperty('OPENROUTER_API_KEY_2', data.openRouterApiKey2);
      }
      if (data.naraApiKey) {
        scriptProps.setProperty('NARA_API_KEY', data.naraApiKey);
      }
      
      return ContentService.createTextOutput(JSON.stringify({
        ok: true,
        message: 'Master data saved'
      })).setMimeType(ContentService.MimeType.JSON);
    }
    
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: 'Unknown action: ' + action
    })).setMimeType(ContentService.MimeType.JSON);
    
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: err.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}
```

### Step 2: Redeploy

1. Click **Deploy** → **New deployment**
2. Type: **Web app**
3. Description: "v26 - Added doPost handler"
4. Execute as: **Me**
5. Who has access: **Anyone**
6. Click **Deploy**
7. **Copy the new URL**

### Step 3: Update App

If the URL changed, update it in your app's configuration.

### Step 4: Test

Test the new deployment:
```bash
curl -L -X POST "YOUR_NEW_URL_HERE" \
  -H "Content-Type: text/plain;charset=utf-8" \
  -d '{"action":"getMasterData"}'
```

Should return JSON with your keys.

---

## Quick Test Script

Save this as `test_apps_script.html` and open in browser:

```html
<!DOCTYPE html>
<html>
<head>
    <title>Apps Script Test</title>
</head>
<body>
    <h1>Apps Script Tester</h1>
    <button onclick="testGet()">Test GET</button>
    <button onclick="testPost()">Test POST</button>
    <pre id="result"></pre>
    
    <script>
    const SCRIPT_URL = 'https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec';
    
    async function testGet() {
        const result = document.getElementById('result');
        result.textContent = 'Testing GET...';
        
        try {
            const response = await fetch(SCRIPT_URL);
            const data = await response.json();
            result.textContent = 'GET Result:\n' + JSON.stringify(data, null, 2);
        } catch (err) {
            result.textContent = 'GET Error:\n' + err.toString();
        }
    }
    
    async function testPost() {
        const result = document.getElementById('result');
        result.textContent = 'Testing POST...';
        
        try {
            const response = await fetch(SCRIPT_URL, {
                method: 'POST',
                headers: {
                    'Content-Type': 'text/plain;charset=utf-8'
                },
                body: JSON.stringify({action: 'getMasterData'})
            });
            const data = await response.json();
            result.textContent = 'POST Result:\n' + JSON.stringify(data, null, 2);
        } catch (err) {
            result.textContent = 'POST Error:\n' + err.toString();
        }
    }
    </script>
</body>
</html>
```

---

## Summary

### What's Working ✅
- Apps Script is deployed and accessible
- GET requests return status
- Google (Gemini) key is present
- OpenRouter key is present

### What's NOT Working ❌
- POST requests fail (return Google Drive error page)
- `doPost()` function not properly handling requests
- Master data sync not working

### Next Steps
1. Add/fix `doPost()` function in your Apps Script
2. Redeploy the script
3. Test POST requests work
4. Update app with new URL (if changed)
5. Verify keys sync to devices

---

**Need Help?** Share your Apps Script code and I can help fix it!
