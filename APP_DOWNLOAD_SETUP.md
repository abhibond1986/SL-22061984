# App Download Link Setup Guide

## What's Been Added

1. **Website Download Button**: Added a prominent Android download button to your website (`web/index.html`)
2. **Auto-Update Link**: The download link automatically points to the latest APK release
3. **Android-Only Notice**: Clear messaging that this is for Android devices only

## How It Works

### The Download Link
```
https://github.com/YOUR_USERNAME/YOUR_REPO_NAME/releases/latest/download/app-release.apk
```

This special GitHub URL **always** redirects to the newest release, so you never need to update the website when releasing a new version.

## Setup Steps

### 1. Update the Download Link

Edit `web/index.html` line 218 and replace with your actual GitHub repository:

```html
<a href="https://github.com/YOUR_USERNAME/YOUR_REPO_NAME/releases/latest/download/app-release.apk"
```

**Example:**
If your repo is `https://github.com/sail-steel/safety-lens`, change it to:
```html
<a href="https://github.com/sail-steel/safety-lens/releases/latest/download/app-release.apk"
```

### 2. Test the Workflow

After pushing your code to GitHub:

1. The GitHub Actions workflow will automatically run
2. It builds the APK
3. Creates a new release with version tag (e.g., `v1.0.0`)
4. Uploads the APK with two names:
   - `app-release.apk` (for the auto-update link)
   - `SafetyLens-v1.0.0.apk` (for manual downloads)

### 3. Verify It Works

After the workflow completes:

1. Go to your repository's Releases page
2. You should see a new release with the APK attached
3. Test the direct link:
   ```
   https://github.com/YOUR_USERNAME/YOUR_REPO_NAME/releases/latest/download/app-release.apk
   ```
4. This should download the APK immediately

### 4. Deploy the Website

Push the updated `web/index.html` to GitHub and deploy:

```bash
git add web/index.html .github/workflows/build-apk.yml
git commit -m "Add Android app download link with auto-update"
git push
```

Then deploy the website (GitHub Pages, Netlify, etc.)

## How Users Download the App

### From Your Website
1. Visit your Safety Lens website
2. Click the green "Download Android App" button
3. APK downloads automatically
4. Open the APK on their Android device
5. Allow installation from unknown sources if prompted
6. Install completes

### Important Notes for Users
- **Android Only**: This is a native Android app (APK file)
- **iOS Not Supported**: iPhone/iPad users cannot install APK files
- **Always Updated**: The link always downloads the latest version
- **Internet Required**: Only for downloading; the app itself works 100% offline

## Automatic Version Updates

Every time you push to `main`/`master` branch:

1. GitHub Actions builds a new APK
2. Version number auto-increments (1.0.0 → 1.0.1 → 1.0.2...)
3. New release is created
4. The download link **automatically** points to this new version
5. **No website changes needed**

## Manual Version Release

You can also trigger a build manually:

1. Go to GitHub → Actions tab
2. Click "Build & Release Safety Lens APK"
3. Click "Run workflow"
4. Optionally enter a version number (e.g., `2.0.0`)
5. Click "Run workflow"

## Customizing the Button

### Change Button Color
In `web/index.html`, find the `.download-btn` CSS (around line 230):

```css
background: linear-gradient(135deg, #22C55E 0%, #16A34A 100%);
```

Change to your preferred color (currently green for download).

### Change Button Text
In `web/index.html` line 224:

```html
Download Android App
```

Change to:
- "Get the Android App"
- "Install Safety Lens"
- "Download APK"
- etc.

### Add Version Display
If you want to show the current version number, you'll need to:

1. Use the GitHub API to fetch the latest release tag
2. Display it dynamically with JavaScript

Example:
```javascript
fetch('https://api.github.com/repos/YOUR_USERNAME/YOUR_REPO/releases/latest')
  .then(res => res.json())
  .then(data => {
    document.getElementById('version').textContent = data.tag_name;
  });
```

## Troubleshooting

### Download Link Returns 404
- Check that a release exists in your GitHub repository
- Verify the repository is public (or users have access)
- Ensure the workflow completed successfully

### Button Not Showing
- Clear browser cache
- Check that you deployed the updated `index.html`
- Inspect browser console for errors

### APK Won't Install
- User needs to enable "Install from unknown sources" in Android settings
- APK might be corrupted - redownload
- Ensure Android version is 5.0+ (API 21+)

## Security Notes

- The APK is built by GitHub Actions (transparent, verifiable)
- Users should only download from your official domain
- Consider adding SHA256 checksums for extra verification
- GitHub serves files over HTTPS (encrypted)

## Next Steps

1. Update the download link with your actual repo URL
2. Test the complete flow (build → release → download)
3. Add the download link to your README.md too
4. Consider adding a QR code on the website for easy mobile access
5. Set up Google Analytics to track download clicks

---

**Need help?** Check the GitHub Actions logs if builds fail, or review the Flutter build documentation.
