# AI Hazard Analysis Troubleshooting Guide

**Issue**: "Could not analyse this photo: the AI service rejected the key"

**Date**: 2026-10-11

---

## Problem Summary

The Safety Lens AI hazard analysis system uses a **multi-tier fallback architecture** with 3 separate AI vision providers. Currently, **all three providers are unavailable**, causing image analysis to fail completely.

### Current Status (from console logs):

| Tier | Provider | Status | Issue |
|------|----------|--------|-------|
| **Tier 0** | Groq | ⚠️ Skipped | No key configured (optional) |
| **Tier 1** | Direct Gemini | ❌ Failed | **NO API KEY CONFIGURED** |
| **Tier 2** | OpenRouter | ⚠️ Skipped | No key configured |
| **Tier 3** | NaraRouter | ❌ Failed | **Insufficient credits (HTTP 402)** |

### Why This Architecture Exists

Each provider has its own **free daily quota**:
- **Gemini**: 15 requests/min, 1M tokens/day (FREE, fastest)
- **OpenRouter**: ~50 free requests/day shared across all models
- **NaraRouter**: Separate account with 10M+ token allowance

When one runs out, the system automatically falls back to the next. But if **all** are unavailable, analysis fails completely.

---

## ✅ **RECOMMENDED SOLUTION: Configure Gemini API Key**

This is the **fastest, easiest, and completely free** solution.

### Why Gemini First?
- ✅ Completely **FREE** (no credit card required)
- ✅ **FASTEST** tier (~7 seconds vs 19+ seconds for others)
- ✅ Highest daily quota (1M tokens/day)
- ✅ Most reliable uptime
- ✅ Takes 2 minutes to set up

### Step-by-Step Instructions:

#### 1. Get a Free Gemini API Key

1. Go to: **https://aistudio.google.com/apikey**
2. Sign in with your Google account
3. Click **"Create API Key"**
4. Copy the key (starts with `AIza...`)

#### 2. Configure in Safety Lens App

**Web/Mobile App:**
1. Open the Safety Lens app
2. Navigate to **Admin** section (bottom navigation)
3. Login with admin credentials:
   - Username: `admin`
   - Password: `admin`
4. Click on **"System Health"** module (heart monitor icon)
5. Scroll to find **"Gemini Vision API"** card
6. Paste your API key in the **"Gemini API Key"** field
7. The key auto-saves when you type (look for the checkmark)
8. Select your preferred model (default: `gemini-3.1-flash-lite` - recommended for speed)

#### 3. Test It

1. Go back to the **"AI Scan"** tab
2. Take or upload a photo
3. The analysis should now work! ✅

---

## Alternative Solutions

### Option 2: Top Up NaraRouter Balance

**Current Issue**: Your NaraRouter account shows "Insufficient credits"

**Steps:**
1. Go to: **https://router.bynara.id**
2. Sign in to your account
3. Navigate to **Billing** section
4. Add credits to your balance
5. Return to the app - NaraRouter (Tier 3) will work again

**Note**: This requires payment and is the slowest tier (~10-20 seconds per scan)

---

### Option 3: Configure OpenRouter (Free Tier)

**Steps:**
1. Get a free API key from: **https://openrouter.ai**
2. In Safety Lens Admin → System Health
3. Find the OpenRouter configuration section
4. Paste your key (starts with `sk-or-...`)

**Limitations**:
- Shared ~50 requests/day across all free models
- Runs out quickly with multiple users
- Not recommended as the only provider

---

### Option 4: Configure Multiple Keys (Best for Production)

For **maximum reliability**, configure **ALL THREE** providers:

1. ✅ **Gemini** (Tier 1) - your primary, fastest provider
2. ✅ **OpenRouter** (Tier 2) - backup when Gemini quota exhausted  
3. ✅ **NaraRouter** (Tier 3) - final fallback

This ensures 24/7 availability even if one provider is down or quota-exhausted.

---

## Understanding the Error Messages

### Console Log Breakdown:

```
GeminiVision: ⚠️ Tier 1 Direct Gemini skipped (no key configured)
```
**Meaning**: No Gemini API key found. This is your fastest tier.  
**Fix**: Configure Gemini API key (see Solution 1)

```
GeminiVision: ⚠️ OpenRouter skipped (no key)
```
**Meaning**: No OpenRouter key configured (optional backup)  
**Fix**: Get key from openrouter.ai

```
NaraVision: NaraRouter said: {"error":{"type":"payment_required","message":"Insufficient credits..."}}
```
**Meaning**: NaraRouter account is out of credits  
**Fix**: Top up at router.bynara.id OR configure Gemini/OpenRouter

```
GeminiVision: ❌ All vision providers unavailable.
```
**Meaning**: All 3 tiers failed. Analysis cannot proceed.  
**Fix**: Configure at least ONE provider

---

## Free Tier Quotas Summary

| Provider | Free Quota | Reset Period | Requires Card? |
|----------|-----------|--------------|----------------|
| **Gemini** | 1M tokens/day<br/>15 req/min | Daily | ❌ No |
| **OpenRouter** | ~50 requests/day<br/>(account-wide) | Daily | ❌ No |
| **NaraRouter** | Varies by plan<br/>(free plan available) | Daily | ⚠️ Depends on plan |

**Recommendation**: Start with Gemini (completely free, no card needed)

---

## Testing Your Fix

### After configuring an API key:

1. **Check Configuration**:
   - Admin → System Health
   - Look for green checkmark: ✅ "Gemini Vision Connected"

2. **Test Analysis**:
   - Go to AI Scan tab
   - Upload this industrial test image (or take a photo)
   - Click "Analyze"
   - Should see hazards identified within 5-10 seconds

3. **Monitor Performance**:
   - Admin → AI Performance
   - Check "Model reliability" section
   - Verify your configured provider shows successful runs

---

## Additional Technical Details

### Model Chain Priority (from fastest to slowest):

**TIER 0** (Optional):
- Groq + qwen/qwen3.6-27b
- Requires Groq API key
- Self-skips if request >8000 tokens
- ~3-5 seconds when it runs

**TIER 1** (Primary):
- Direct Google Gemini
- Model: `gemini-3.1-flash-lite` (default)
- ~7 seconds average
- ⚠️ **CURRENTLY NOT CONFIGURED**

**TIER 2** (Backup):
- OpenRouter free models
- Single model: `dots-3-note-preview:free`
- ~10-20 seconds
- ⚠️ **CURRENTLY NOT CONFIGURED**

**TIER 3** (Final fallback):
- NaraRouter via Apps Script proxy
- Default model: `mistral-medium-3-5`
- ~10-20+ seconds (includes Apps Script cold start)
- ❌ **CURRENTLY OUT OF CREDITS**

**TIER 4** (Offline):
- Returns "No hazards" and logs error

---

## Prevention: Setting Up Auto-Sync

Your app supports automatic API key synchronization across devices using Google Apps Script. This means:

1. Configure keys once in Admin panel
2. Keys sync to all devices automatically
3. Team members don't need to configure individually

**Setup location**: Admin → System Health → Apps Script Configuration

---

## Need Help?

### Common Issues:

**Q: I configured Gemini but still getting errors**
- A: Wait 30 seconds and refresh the page
- Check that key starts with `AIza`
- Verify key has no extra spaces
- Check API quota at: https://aistudio.google.com/app/apikey

**Q: Analysis is slow (>30 seconds)**
- A: Tier 1 (Gemini) not configured - you're falling back to slower tiers
- Solution: Add Gemini API key

**Q: Works on one device but not another**
- A: Keys are stored per-device in SharedPreferences
- Solution: Enable Apps Script sync OR configure on each device

**Q: Getting "payment_required" error**
- A: NaraRouter out of credits
- Solution: Configure Gemini (free) instead of topping up

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────┐
│  SAFETY LENS AI VISION - QUICK FIX              │
├─────────────────────────────────────────────────┤
│                                                 │
│  1. Go to: aistudio.google.com/apikey          │
│  2. Create API Key (FREE)                       │
│  3. Copy key (starts with AIza...)              │
│  4. Open Safety Lens → Admin → System Health   │
│  5. Paste into "Gemini API Key" field          │
│  6. Test with AI Scan                           │
│                                                 │
│  ✅ Done! Analysis should work in 5-10 seconds │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

**Generated**: 2026-10-11  
**App Version**: Safety Lens v3.22  
**For**: Steel Authority of India Limited (SAIL)
