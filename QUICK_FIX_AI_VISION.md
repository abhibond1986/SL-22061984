# ⚡ QUICK FIX: AI Vision Not Working

**Problem**: Photos aren't being analyzed - getting "AI service rejected the key" error

**Root Cause**: No API keys configured for the AI vision system

---

## 🎯 **5-Minute Fix (Completely FREE)**

### 1️⃣ Get Free Gemini API Key

Visit: **https://aistudio.google.com/apikey**

- Click "Create API Key"  
- Copy the key (looks like `AIzaSy...`)
- ✅ No credit card needed
- ✅ Completely free forever
- ✅ 1 million tokens per day

### 2️⃣ Configure in Safety Lens

**On Web (safetylens.in):**
```
1. Click "Admin" (bottom navigation)
2. Login: admin / admin
3. Click "System Health" (heart icon)
4. Scroll to "Gemini Vision API" card
5. Paste your API key
6. Done! ✅
```

**On Mobile App:**
```
Same steps as web version above
```

### 3️⃣ Test It

- Go to "AI Scan" tab
- Upload/take a photo
- Analysis should complete in 5-10 seconds ✅

---

## 🏗️ Architecture (Why This Happened)

Your app has a **multi-tier fallback system**:

```
┌────────────────────────────────────────────────┐
│  TIER 1: Direct Gemini (FASTEST - 7s)         │
│  Status: ❌ NO KEY                             │
│  Solution: Configure Gemini API key above     │
└────────────────────────────────────────────────┘
          ⬇️ Falls back if Tier 1 fails
┌────────────────────────────────────────────────┐
│  TIER 2: OpenRouter (BACKUP - 15s)            │
│  Status: ❌ NO KEY                             │
│  Solution: Optional, get key from             │
│            openrouter.ai                       │
└────────────────────────────────────────────────┘
          ⬇️ Falls back if Tier 2 fails
┌────────────────────────────────────────────────┐
│  TIER 3: NaraRouter (LAST RESORT - 20s)       │
│  Status: ❌ OUT OF CREDITS                     │
│  Solution: Top up at router.bynara.id         │
│            OR just use Gemini instead          │
└────────────────────────────────────────────────┘
          ⬇️ Falls back if Tier 3 fails
┌────────────────────────────────────────────────┐
│  TIER 4: OFFLINE FALLBACK                     │
│  Returns: "No hazards found" + error logged   │
│  Status: ⚠️ CURRENTLY HERE                    │
└────────────────────────────────────────────────┘
```

**Current State**: ALL 3 tiers are unavailable, so every scan fails.

**Fix**: Configure just **ONE** tier (Gemini recommended) and it works!

---

## 📊 Provider Comparison

| Provider | Speed | Free Quota | Card Required? | Setup Time |
|----------|-------|-----------|----------------|------------|
| **Gemini** ⭐ | 7s | 1M tokens/day | ❌ No | 2 min |
| OpenRouter | 15s | ~50 req/day | ❌ No | 5 min |
| NaraRouter | 20s | Varies | ⚠️ Maybe | 10 min |

**⭐ Recommendation**: Start with Gemini (fastest, most generous quota, no payment ever)

---

## 🔍 What You Saw in the Console

```
GeminiVision: ⚠️ Tier 1 Direct Gemini skipped (no key configured)
```
☝️ Your fastest option (7s) is not set up

```
GeminiVision: ⚠️ OpenRouter skipped (no key)
```
☝️ Your backup option is not set up

```
NaraVision: {"error":{"type":"payment_required","message":"Insufficient credits..."}}
```
☝️ Your last resort ran out of money

```
GeminiVision: ❌ All vision providers unavailable.
```
☝️ **This is why analysis fails** - nowhere left to try!

---

## ✅ After You Fix It

You should see in console:
```
✅ GeminiVision: Tier 1 Direct Gemini - gemini-3.1-flash-lite
✅ Analysis complete: 3 hazards identified in 7.2s
```

And in the app:
- Photos analyze in 5-10 seconds
- Hazards identified with bounding boxes
- Risk scores calculated
- Mitigation suggestions provided

---

## 💡 Pro Tips

### For Maximum Reliability:

Configure **all three** providers so you have true 24/7 coverage:

1. **Gemini** - your daily workhorse (1M tokens = ~500+ scans/day)
2. **OpenRouter** - kicks in if Gemini quota exhausted (~50 more scans)  
3. **NaraRouter** - final safety net

This way, even if one provider has an outage or you hit quota, analysis continues seamlessly.

### Check Your Usage:

**Admin → AI Performance** shows:
- Which provider is handling your scans
- Success/failure rates per model
- Average response times
- Daily quota consumption

---

## 🆘 Still Having Issues?

### Key Not Working?
- Verify it starts with `AIza`
- Check for extra spaces when pasting
- Wait 30 seconds after configuring
- Refresh the page

### Slow Analysis (>30s)?
- Gemini (Tier 1) probably not configured
- You're falling back to slower tiers
- Add Gemini key to speed it up

### Works on One Device, Not Another?
- Keys are stored per-device
- Configure on each device separately
- OR enable Apps Script sync (Admin → System Health)

---

## 📋 Quick Reference

**Gemini API Key Page**: https://aistudio.google.com/apikey  
**Configuration Path**: Admin → System Health → Gemini Vision API  
**Test Location**: AI Scan tab  
**Monitor Performance**: Admin → AI Performance  

**Support**: See full guide in `HAZARD_AI_TROUBLESHOOTING_GUIDE.md`

---

**Last Updated**: 2026-10-11  
**Status**: Issue identified and solution provided ✅
