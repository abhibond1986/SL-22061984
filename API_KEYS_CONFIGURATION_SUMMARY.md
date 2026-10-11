# API Keys Configuration - Quick Comparison

**All Three Vision Providers | Side-by-Side Guide**

---

## Provider Comparison Table

| Feature | **Gemini** (Tier 1) | **OpenRouter** (Tier 2) | **NaraRouter** (Tier 3) |
|---------|-------------------|----------------------|---------------------|
| **Speed** | ⚡ 7s | 🐢 15s | 🐌 20-45s |
| **Free Quota** | 1M tokens/day | ~50 requests/day | Varies by plan |
| **Configuration** | ✅ **Admin UI** | ⚠️ Apps Script | ⚠️ Apps Script |
| **Requires Card?** | ❌ No | ❌ No (free tier) | ⚠️ Depends |
| **Key Format** | `AIza...` | `sk-or-...` | `sk-nry-...` |
| **Where to Get Key** | aistudio.google.com/apikey | openrouter.ai | router.bynara.id |
| **Recommended As** | ⭐ Primary | 🔄 Backup | 🛟 Last resort |

---

## Configuration Quick Reference

### 🟢 GEMINI (Easiest - Start Here!)

```
┌─────────────────────────────────────────────┐
│  WHERE: Admin UI (in the app)              │
├─────────────────────────────────────────────┤
│  1. Get key: aistudio.google.com/apikey    │
│  2. Open app → Admin → System Health       │
│  3. Paste key in "Gemini API Key" field    │
│  4. Done! ✅                                │
└─────────────────────────────────────────────┘

Auto-syncs to all devices via Apps Script backend
```

**Storage**: `gemini_vision_api_key` in SharedPreferences  
**Validation**: Must be > 20 characters

---

### 🟡 OPENROUTER (Backup)

```
┌─────────────────────────────────────────────┐
│  WHERE: Apps Script (server-side)          │
├─────────────────────────────────────────────┤
│  1. Get key: openrouter.ai                 │
│  2. Open Apps Script backend project       │
│  3. Project Settings → Script Properties   │
│  4. Add: OPENROUTER_API_KEY = sk-or-...    │
│  5. Restart app to sync ✅                  │
└─────────────────────────────────────────────┘

Syncs to all devices on next app launch
```

**Storage**: `openrouter_api_key` in SharedPreferences  
**Validation**: Must start with `sk-or-`  
**Optional**: `OPENROUTER_API_KEY_2` for failover

---

### 🟠 NARAROUTER (Last Resort)

```
┌─────────────────────────────────────────────┐
│  WHERE: Apps Script (server-side)          │
├─────────────────────────────────────────────┤
│  1. Get key: router.bynara.id              │
│  2. Open Apps Script backend project       │
│  3. Project Settings → Script Properties   │
│  4. Add: NARA_API_KEY = sk-nry-...         │
│  5. Add: NARA_MODEL = mistral-medium-3-5   │
│  6. Restart app to sync ✅                  │
└─────────────────────────────────────────────┘

Requires separate proxy for web (already deployed)
```

**Storage**: `nara_api_key` in SharedPreferences  
**Validation**: Must start with `sk-nry-`  
**Web Path**: Goes through Apps Script proxy (CORS workaround)  
**Mobile Path**: Direct call to router.bynara.id

---

## Configuration Workflow

### Scenario 1: Quick Setup (5 minutes)

**Goal**: Get AI vision working ASAP

```
✅ Configure Gemini ONLY
   └─ Admin UI → System Health
   └─ Paste Gemini key
   └─ DONE ✅
```

**Result**: 1M tokens/day, 7-second scans, 100% free forever

---

### Scenario 2: Production Setup (15 minutes)

**Goal**: Maximum reliability with fallback

```
1️⃣ Gemini (Primary)
   └─ Admin UI → System Health → Gemini key

2️⃣ OpenRouter (Backup)  
   └─ Apps Script → OPENROUTER_API_KEY

3️⃣ NaraRouter (Final Fallback)
   └─ Apps Script → NARA_API_KEY
   
✅ Result: 3 independent quotas, 24/7 availability
```

---

## Apps Script Configuration Template

**File**: `Main.gs` → `handleGetMasterData_()` function

```javascript
function handleGetMasterData_(data) {
  const scriptProps = PropertiesService.getScriptProperties();
  
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    data: {
      // ═══════════════════════════════════════
      // AI API KEYS - Copy this entire block
      // ═══════════════════════════════════════
      
      // TIER 1: Gemini (can also be configured via Admin UI)
      geminiApiKey: scriptProps.getProperty('GEMINI_API_KEY') || '',
      geminiModel: scriptProps.getProperty('GEMINI_MODEL') || 'gemini-3.1-flash-lite',
      
      // TIER 0 (optional): Groq - fastest but limited (8000 tokens/min)
      groqApiKey: scriptProps.getProperty('GROQ_API_KEY') || '',
      groqModel: scriptProps.getProperty('GROQ_MODEL') || '',
      
      // TIER 2: OpenRouter - ~50 free requests/day
      openRouterApiKey: scriptProps.getProperty('OPENROUTER_API_KEY') || '',
      openRouterApiKey2: scriptProps.getProperty('OPENROUTER_API_KEY_2') || '',
      
      // TIER 3: NaraRouter - final fallback
      naraApiKey: scriptProps.getProperty('NARA_API_KEY') || '',
      naraModel: scriptProps.getProperty('NARA_MODEL') || 'mistral-medium-3-5',
      
      // ═══════════════════════════════════════
      // OTHER MASTER DATA (keep your existing)
      // ═══════════════════════════════════════
      plants: getAllPlants_(),
      departments: getDepartments_(),
      wsaCauses: getWsaCauses_(),
      // ... rest of your master data ...
    }
  })).setMimeType(ContentService.MimeType.JSON);
}
```

### Script Properties to Add

```
GEMINI_API_KEY          = AIzaSy...                (from aistudio.google.com)
GEMINI_MODEL            = gemini-3.1-flash-lite

GROQ_API_KEY            = gsk_...                  (optional)
GROQ_MODEL              = qwen/qwen3.6-27b         (optional)

OPENROUTER_API_KEY      = sk-or-...                (from openrouter.ai)
OPENROUTER_API_KEY_2    = sk-or-...                (optional secondary)

NARA_API_KEY            = sk-nry-...               (from router.bynara.id)
NARA_MODEL              = mistral-medium-3-5
```

---

## Verification Commands

### Check All Configured Keys

Look for these console logs on app launch:

```bash
# Gemini
✅ GeminiDirectVision: key configured (38 chars)

# OpenRouter  
✅ GeminiVision: 2 OpenRouter key(s) configured

# NaraRouter
✅ NaraVision: key configured (starts with sk-nry-)
```

### During AI Scan

```bash
# SUCCESS - Full chain working
GeminiVision: ✓ Tier 1 Direct Gemini success in 7.2s
   └─ Model: gemini-3.1-flash-lite
   └─ 3 hazards identified

# FALLBACK - Tier 1 failed, Tier 2 took over  
GeminiVision: ⚠️ Tier 1 quota exhausted (1M tokens/day limit hit)
GeminiVision: ✓ Tier 2 OpenRouter success in 15.1s
   └─ Model: dots-3-note-preview:free

# LAST RESORT - Tiers 1-2 failed
GeminiVision: ⚠️ Tier 1 skipped (no key)
GeminiVision: ⚠️ Tier 2 OpenRouter quota exhausted
NaraVision: ✓ Tier 3 NaraRouter success in 21.3s
   └─ Model: mistral-medium-3-5
```

### Admin Panel Check

```
Admin → AI Performance → Model Reliability

Should show entries for:
✅ gemini-3.1-flash-lite (if Gemini configured)
✅ dots-3-note-preview:free (if OpenRouter configured)  
✅ mistral-medium-3-5 (if NaraRouter configured)
```

---

## Common Issues & Quick Fixes

| Problem | Likely Cause | Solution |
|---------|--------------|----------|
| "All vision providers unavailable" | No keys configured | Add Gemini key via Admin UI |
| "OpenRouter skipped (no key)" | Key not in Apps Script | Add to Script Properties |
| "Key needs renewing" | Wrong key format | Check starts with correct prefix |
| Analysis takes >30s | Using slow tier | Add Gemini (Tier 1) for 7s scans |
| Works on one device only | No Apps Script sync | Configure in Script Properties, not locally |
| "HTTP 429" from OpenRouter | Quota exhausted | Add Gemini key OR wait for reset |

---

## Decision Tree

```
START: Need AI hazard analysis working
   │
   ├─ Want FASTEST setup (5 min)?
   │  └─> Configure GEMINI via Admin UI ✅
   │
   ├─ Want MAXIMUM reliability?
   │  └─> Configure all three: Gemini + OpenRouter + NaraRouter ✅
   │
   ├─ Have an existing Apps Script backend?
   │  └─> Add all keys to Script Properties
   │     └─> Sync on app launch ✅
   │
   └─ Just testing locally on one device?
      └─> Use Admin UI for Gemini (syncs to backend anyway) ✅
```

---

## Cost Comparison

| Provider | Free Tier | With $10 USD | Best For |
|----------|-----------|--------------|----------|
| **Gemini** | 1M tokens/day<br/>~500+ scans | Still free! | Primary use |
| **OpenRouter** | ~50 scans/day | ~1000 scans/day | Backup |
| **NaraRouter** | Varies | Varies | Failover |

**Recommendation**: Start with 100% free Gemini. Only add paid if you need >500 scans/day.

---

## Summary Card

```
╔═══════════════════════════════════════════════════════╗
║  RECOMMENDED SETUP FOR PRODUCTION                     ║
╠═══════════════════════════════════════════════════════╣
║                                                       ║
║  ✅ TIER 1: Gemini (Admin UI)                         ║
║     • Free forever                                    ║
║     • 1M tokens/day                                   ║
║     • 7 seconds/scan                                  ║
║     • Configure in: Admin → System Health             ║
║                                                       ║
║  🔄 TIER 2: OpenRouter (Apps Script)                  ║
║     • ~50 free scans/day                              ║
║     • 15 seconds/scan                                 ║
║     • Configure in: Script Properties                 ║
║                                                       ║
║  🛟 TIER 3: NaraRouter (Apps Script)                  ║
║     • Last resort backup                              ║
║     • 20-45 seconds/scan                              ║
║     • Configure in: Script Properties                 ║
║                                                       ║
║  TOTAL COST: $0 (all free tiers)                      ║
║  DAILY CAPACITY: 500+ scans                           ║
║  UPTIME: 99.9%+ with all three                        ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
```

---

## Next Steps

1. **Get Gemini key**: https://aistudio.google.com/apikey
2. **Configure**: Admin → System Health → Paste key
3. **Test**: AI Scan tab → Upload photo → Verify <10s analysis
4. **(Optional) Add backups**: Configure OpenRouter + NaraRouter in Apps Script

---

**See Detailed Guides**:
- `QUICK_FIX_AI_VISION.md` - Gemini setup (5 min)
- `OPENROUTER_CONFIGURATION_GUIDE.md` - OpenRouter setup (15 min)
- `HAZARD_AI_TROUBLESHOOTING_GUIDE.md` - Full troubleshooting

**Last Updated**: 2026-10-11
