# OpenRouter API Key Configuration Guide

**Date**: 2026-10-11  
**Project**: Safety Lens - AI Hazard Analysis System

---

## Overview

OpenRouter serves as **Tier 2** in your AI vision fallback chain. It activates when:
- Gemini (Tier 1) is not configured, OR
- Gemini has exhausted its daily quota, OR  
- Gemini returns an error (429/403)

---

## Important Notes Before You Start

### ⚠️ OpenRouter Limitations

1. **Free tier quota is SHARED** across all models (~50 requests/day per account)
2. **Not recommended as your PRIMARY provider** - use Gemini first
3. **All ':free' models share ONE quota counter** - switching models doesn't give more requests
4. **OpenRouter keys are configured server-side** (Apps Script), NOT through the admin UI

### Why OpenRouter Is Tier 2, Not Tier 1

From the codebase comments:
> "A Gemini key bills against Google instead, so it is the only path that still analyses the image when OpenRouter returns 429... and since 2026-09-03 it is also the FASTEST, so without it every scan begins on the slower shared free pool."

**Bottom line**: Configure Gemini first (see QUICK_FIX_AI_VISION.md), then add OpenRouter as backup.

---

## How OpenRouter Keys Are Stored

Unlike Gemini keys (which can be configured through the Admin UI), OpenRouter keys are:

1. ✅ Stored in **Google Apps Script** → Script Properties
2. ✅ Synced to all devices via `getMasterData` action
3. ✅ Stored locally in SharedPreferences as:
   - Primary key: `'openrouter_api_key'`
   - Secondary key (optional): `'openrouter_api_key_2'`

---

## Configuration Methods

### Method 1: Apps Script Configuration (Server-Side) ⭐ **Recommended**

This is the OFFICIAL way to configure OpenRouter keys.

#### Step 1: Get Your OpenRouter API Key

1. Go to: **https://openrouter.ai**
2. Sign up or log in
3. Navigate to **API Keys** section
4. Generate a new API key (starts with `sk-or-...`)
5. Copy the key

#### Step 2: Configure in Apps Script

1. Open your **Google Apps Script** backend project (the main sync backend, NOT the Nara Router proxy)
2. Go to **Project Settings** (gear icon)
3. Scroll down to **Script Properties**
4. Add/Update these properties:

   | Property Name | Value | Description |
   |--------------|-------|-------------|
   | `OPENROUTER_API_KEY` | `sk-or-...` | Your primary OpenRouter key |
   | `OPENROUTER_API_KEY_2` | `sk-or-...` | (Optional) Secondary key for failover |

5. Click **Save Script Properties**

#### Step 3: Update Apps Script Code

Your Apps Script's `getMasterData` function needs to return these keys. Add this to your `handleGetMasterData_()` function:

```javascript
function handleGetMasterData_(data) {
  const scriptProps = PropertiesService.getScriptProperties();
  
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    data: {
      // ... existing master data fields ...
      
      // Add OpenRouter keys
      openRouterApiKey: scriptProps.getProperty('OPENROUTER_API_KEY') || '',
      openRouterApiKey2: scriptProps.getProperty('OPENROUTER_API_KEY_2') || '',
      
      // ... rest of your master data ...
    }
  })).setMimeType(ContentService.MimeType.JSON);
}
```

#### Step 4: Sync to All Devices

Once configured in Apps Script:

1. **Restart the Safety Lens app** on any device
2. On app launch, `AdminMasterData.syncFromBackend()` runs automatically
3. OpenRouter keys are pulled and stored locally
4. All devices now have the keys! ✅

---

### Method 2: Direct Local Configuration (Device-Specific)

⚠️ **Not recommended** - this only works on ONE device and doesn't sync.

But if you need to test locally:

#### Via Flutter Dev Tools / Dart Code:

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:your_app/services/gemini_vision.dart';

Future<void> setOpenRouterKey() async {
  final prefs = await SharedPreferences.getInstance();
  
  // Primary key
  await prefs.setString(GeminiVision.kOpenRouterKey1, 'sk-or-YOUR_KEY_HERE');
  
  // Optional secondary key
  await prefs.setString(GeminiVision.kOpenRouterKey2, 'sk-or-YOUR_SECOND_KEY');
  
  print('✅ OpenRouter keys configured locally');
}
```

#### Key Validation Rules:

From the code (`gemini_vision.dart:2586-2588`):
```dart
// OpenRouter keys MUST start with 'sk-or-'
// Blank or invalid keys are silently ignored
if (v.startsWith('sk-or-') && !keys.contains(v)) keys.add(v);
```

---

## Verification

### Check if OpenRouter is Configured

**Method 1: Console Logs**

Watch the console when running an AI scan. You should see:

✅ **With OpenRouter key configured**:
```
GeminiVision: Tier 2 OpenRouter attempting: dots-3-note-preview:free
GeminiVision: ✓ Tier 2 OpenRouter success in 15.2s
```

❌ **Without OpenRouter key**:
```
GeminiVision: ⚠️ OpenRouter skipped (no key)
```

**Method 2: Admin Panel** (indirect)

1. Go to **Admin → AI Performance**
2. Look at **"Model reliability"** section
3. If you see entries for:
   - `dots-3-note-preview:free` (OpenRouter)
   - Success/failure stats
   
   Then OpenRouter is active! ✅

**Method 3: Programmatic Check**

```dart
import 'package:your_app/services/gemini_vision.dart';

Future<void> checkOpenRouterKeys() async {
  final keys = await GeminiVision.openRouterKeys();
  
  if (keys.isEmpty) {
    print('❌ No OpenRouter keys configured');
  } else {
    print('✅ OpenRouter configured with ${keys.length} key(s)');
    print('   Primary: ${keys[0].substring(0,10)}...');
    if (keys.length > 1) {
      print('   Secondary: ${keys[1].substring(0,10)}...');
    }
  }
}
```

---

## Understanding Dual OpenRouter Keys

Your system supports **TWO** OpenRouter keys for failover.

### Why Two Keys?

From the code comments (`gemini_vision.dart:2567-2578`):

> "⚠️ READ THIS BEFORE ASSUMING A SECOND KEY RAISES YOUR QUOTA. It does not, if both keys belong to the same OpenRouter account. The free allowance (`free-models-per-day`) is metered per ACCOUNT, not per key..."

**What a second key GENUINELY buys:**
- ✅ Failover if the primary is revoked/rotated/mistyped (401/403)
- ✅ A paid/org account as backup once personal free tier is spent
- ❌ **NOT** doubled quota if both keys are from the same account

### Best Practice

**Option A**: Single key (most common)
- Just configure `OPENROUTER_API_KEY` in Script Properties
- Simpler setup, works fine for testing

**Option B**: Dual keys (production)
- Primary: Your personal free account (`sk-or-...`)
- Secondary: Paid/organization account (`sk-or-...`)
- Provides true redundancy across different quotas

---

## Current OpenRouter Model (Tier 2)

As of 2026-09-08, OpenRouter Tier 2 uses **ONE model**:

### `dots-3-note-preview:free`

**Specs**:
- Provider: AtlasCloud
- Architecture: Mixture-of-Experts (16B active of 280B total)
- Context: 512k tokens
- Uptime: 99.99%
- Average latency: 10-20 seconds

**Why only one model?**

From codebase comments:
> "minimax/minimax-m3:free led this tier and was WITHDRAWN from OpenRouter on 2026-09-08... Only ten free image-capable models remain and eight are ruled out... so this tier has no admissible second model."

Other free models were excluded because they:
- Use reasoning mode by default (wastes tokens)
- Have poor uptime (<90%)
- Share the same upstream as Tier 1 (no real fallback)

---

## Troubleshooting

### Issue: "OpenRouter skipped (no key)"

**Causes:**
1. No key in Apps Script Script Properties
2. Key doesn't start with `sk-or-`
3. App hasn't synced since you added the key
4. Wrong Apps Script project (main backend vs Nara proxy)

**Fix:**
1. Verify key in Script Properties of **main backend**
2. Restart the app to trigger sync
3. Check console for sync confirmation

---

### Issue: "HTTP 429 from OpenRouter"

**Meaning**: Free quota exhausted (~50 requests/day)

**Solutions:**
1. ✅ **Add Gemini key** (Tier 1) - it has its own quota
2. ⏸️ Wait for daily reset (midnight UTC)
3. 💳 Add credits to OpenRouter account ($10 = 1000 requests/day)
4. ⚠️ Check if another service is using same account (SOP scanner, etc.)

From code:
> "one SOP scan can spend twenty requests in a minute. Without [tracking] the admin panel would show a nearly untouched quota while hazard scanning started returning 429"

---

### Issue: "Slow analysis (>30 seconds)"

**Meaning**: You're hitting OpenRouter without Gemini configured

**Why it's slow**:
- Gemini (Tier 1): ~7 seconds
- OpenRouter (Tier 2): ~15-20 seconds
- NaraRouter (Tier 3): ~20-45 seconds (includes Apps Script cold start)

**Fix**: Configure Gemini as Tier 1 (see QUICK_FIX_AI_VISION.md)

---

## Production Recommendation

### Ideal Setup (Maximum Reliability):

```
TIER 1: Gemini Direct
  ├─ gemini-3.1-flash-lite (7s, 1M tokens/day)
  ├─ gemini-3.6-flash (fallback #1)
  └─ gemini-2.5-flash (fallback #2)

TIER 2: OpenRouter
  └─ dots-3-note-preview:free (15s, ~50 req/day)

TIER 3: NaraRouter  
  └─ mistral-medium-3-5 (20s, separate quota)
```

**Configuration checklist**:
- [x] Gemini API key in Admin UI → System Health
- [x] OpenRouter key in Apps Script → Script Properties → `OPENROUTER_API_KEY`
- [x] NaraRouter key in Apps Script → Script Properties → `NARA_API_KEY`

This gives you **three independent quotas** from three providers, ensuring 24/7 availability.

---

## Sample Apps Script Configuration

Complete `getMasterData` response with API keys:

```javascript
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

---

## Quick Reference

| Task | Method |
|------|--------|
| **Get OpenRouter key** | https://openrouter.ai → API Keys |
| **Configure key** | Apps Script → Script Properties → `OPENROUTER_API_KEY` |
| **Verify configured** | Console logs: "Tier 2 OpenRouter..." OR Admin → AI Performance |
| **Check quota** | Admin → AI Performance → Free quota section |
| **Free quota** | ~50 requests/day (shared across all free models) |
| **Increase quota** | Add $10 credits = 1000 requests/day |
| **Key format** | Must start with `sk-or-` |
| **Storage keys** | `GeminiVision.kOpenRouterKey1`, `kOpenRouterKey2` |

---

## Need Both Gemini AND OpenRouter?

**Gemini**: Get key → Admin UI → System Health → Paste  
**OpenRouter**: Get key → Apps Script → Script Properties → `OPENROUTER_API_KEY`

Two different configuration paths because:
- Gemini = client-side calls with your key
- OpenRouter = server-side calls through Apps Script proxy (for security)

---

**Last Updated**: 2026-10-11  
**Status**: OpenRouter configuration via Apps Script (server-side)  
**See Also**: QUICK_FIX_AI_VISION.md, HAZARD_AI_TROUBLESHOOTING_GUIDE.md
