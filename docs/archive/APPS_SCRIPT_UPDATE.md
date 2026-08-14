# Apps Script Update — v14

## What Changed (v13 → v14)

1. **Pipe vs Wire Differentiation** — 6 rules added directly to the server-side prompt
2. **Gas Cylinder Colour Codes** (IS 4379:1981) added to prompt
3. **Pipe Colour Codes** (IS 2379:1963) added to prompt  
4. **App-provided prompt support** — if the Flutter app sends a `prompt` field (>100 chars), the backend uses it instead of the server-side prompt

## How To Deploy

1. Open your Apps Script editor:  
   https://script.google.com/  
   (find the project linked to your spreadsheet)

2. **Select ALL** the existing code in `Code.gs` and **DELETE** it

3. **Copy-paste** the entire contents of `apps_script_v14.js` from this repo

4. Click **Deploy** → **Manage deployments** → **Edit** (pencil icon on your active deployment)  
   → Set version to "New version" → Click **Deploy**

5. Test: visit your web app URL with `?action=ping`  
   You should see `"version": "v14"` in the response

## Verify Pipe/Wire Fix

After deploying, run `testPromptVersion()` from the editor. You should see:
```
Has PIPE vs WIRE: true
Has IS 4379: true
Has IS 2379: true
```

## No Flutter Changes Needed

The Flutter app already sends its enhanced prompt via the `prompt` field.  
With v14 deployed, the backend will use it. Even without the app update,  
the server-side prompt now has pipe/wire rules built in.
