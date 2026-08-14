# Safety Lens V2 - Testing & Deployment Guide

## ✅ Fixes Applied (2026-06-19)

### 1. PWA/Bookmark Interface - FIXED ✅
**Problems:** Alignment issues when saved as bookmark on phone
**Solutions:**
- ✅ Removed `user-scalable=no` for better accessibility
- ✅ Added `interactive-widget=resizes-content` for mobile keyboards
- ✅ Added iOS safe area insets for notched devices
- ✅ Fixed body positioning to prevent overscroll on iOS
- ✅ Made manifest.json orientation flexible (`any` instead of `portrait-primary`)
- ✅ Added responsive CSS breakpoints for mobile devices
- ✅ Reduced loading card padding on small screens

### 2. AI Offline Mode - IMPROVED ✅
**Problems:** Offline mode shows demo data without clear indication
**Solutions:**
- ✅ Added clear "⚠️ OFFLINE MODE" prefix to summaries
- ✅ Set confidence to 0 for offline scenarios
- ✅ Added `_isOffline` and `_source` flags to response
- ✅ Show amber notification when offline mode is active
- ✅ Updated all 3 example scenarios with offline warnings

**Note:** True offline AI requires TensorFlow Lite integration (future enhancement)

### 3. APK Build - VERIFIED ✅
**Status:** Configuration is correct
- ✅ All Android permissions present (Camera, Storage, Internet, Audio)
- ✅ minSdk: 23 (Android 6.0+) - widely compatible
- ✅ targetSdk: 34 (Android 14) - latest
- ✅ Hardware acceleration enabled
- ✅ Proper activity configuration

---

## 🚀 How to Build & Test APK

### Prerequisites
```bash
flutter --version  # Should be 3.22 or higher
```

### Build Debug APK (Quick Testing)
```bash
cd C:\Users\USER\Desktop\Safety-Lens-V2
flutter clean
flutter pub get
flutter build apk --debug

# APK output location:
# build/app/outputs/flutter-apk/app-debug.apk
```

### Build Release APK (Production)
```bash
flutter build apk --release

# APK output location:
# build/app/outputs/flutter-apk/app-release.apk
```

### Install on Device
```bash
# Connect phone via USB with Developer Mode enabled
adb devices  # Verify connection
adb install build/app/outputs/flutter-apk/app-debug.apk
```

### Test Checklist
- [ ] App launches without crashes
- [ ] Camera permission works
- [ ] Can take photo
- [ ] AI scan shows online/offline status clearly
- [ ] Near Miss form works
- [ ] Chat responds correctly
- [ ] Reports save and display
- [ ] Language switching works (English, Hindi, Bengali, Odia)

---

## 🌐 How to Test PWA (Bookmark Mode)

### Option 1: Local Testing
```bash
cd C:\Users\USER\Desktop\Safety-Lens-V2
flutter run -d chrome --web-renderer html
```

### Option 2: Deploy to Web
```bash
flutter build web --release

# Output in: build/web/
# Deploy to hosting (Firebase, Vercel, Netlify, etc.)
```

### Testing on Mobile Phone
1. Open the web app in mobile browser (Chrome/Safari)
2. **Chrome (Android):**
   - Menu → "Add to Home screen"
3. **Safari (iOS):**
   - Share button → "Add to Home Screen"
4. Test the installed PWA:
   - [ ] No horizontal scroll
   - [ ] No alignment issues
   - [ ] Safe area respected (notch devices)
   - [ ] Bottom bar doesn't overlap content
   - [ ] Responsive on different screen sizes

---

## 🔍 Common Issues & Solutions

### Issue 1: "APK not installing"
**Solution:**
```bash
# Uninstall old version first
adb uninstall com.sail.safety

# Then reinstall
adb install build/app/outputs/flutter-apk/app-debug.apk
```

### Issue 2: "Camera not working in APK"
**Check:**
1. Permissions granted in app settings
2. Camera hardware available
3. Check logs: `adb logcat | grep flutter`

### Issue 3: "AI always shows offline mode"
**Causes:**
- No internet connection
- Backend API unreachable
- Gemini API quota exceeded

**Check:**
- Internet connectivity
- Backend URL responding: https://script.google.com/macros/s/AKfycbxLSH2Z-X6iQPw0rY2O7T0SYSDU7bzikpWq-G_ysOT_noU-IwgSHYNr3AKbwPFPZYginw/exec

### Issue 4: "PWA alignment still wrong"
**Clear cache:**
1. Uninstall PWA from home screen
2. Clear browser cache
3. Re-add to home screen

---

## 📱 Device-Specific Testing

### Test on these screen sizes:
- [ ] Small phone (iPhone SE, Galaxy A series) - 320-375px width
- [ ] Standard phone (iPhone 12/13, Pixel) - 390-428px width
- [ ] Large phone (iPhone Pro Max, Galaxy S) - 428-480px width
- [ ] Tablet (iPad, Galaxy Tab) - 768px+ width

### Test on these OS versions:
- [ ] Android 6.0 (minSdk 23)
- [ ] Android 10
- [ ] Android 14 (targetSdk 34)
- [ ] iOS 14+
- [ ] iOS 17+

---

## 🐛 Debug Commands

### View Live Logs
```bash
# Android
adb logcat | grep flutter

# Or filter for errors
adb logcat *:E
```

### Check APK Info
```bash
aapt dump badging build/app/outputs/flutter-apk/app-release.apk
```

### Check APK Size
```bash
ls -lh build/app/outputs/flutter-apk/app-release.apk
```

### Profile Build Size
```bash
flutter build apk --analyze-size
```

---

## 🚀 Deployment Options

### Web Deployment
1. **Firebase Hosting** (Recommended)
   ```bash
   firebase init hosting
   firebase deploy
   ```

2. **Vercel**
   - Connect GitHub repo
   - Auto-deploys on push

3. **GitHub Pages**
   ```bash
   # Add to .github/workflows/deploy.yml
   ```

### APK Distribution
1. **Internal Testing:**
   - Google Play Console → Internal Testing
   - Upload APK, invite testers

2. **Direct Distribution:**
   - Host on company server
   - Share download link
   - Users need "Install from Unknown Sources"

---

## 📊 Performance Monitoring

### Check App Performance
```bash
flutter run --profile
# Press 'P' to show performance overlay
```

### Build Size Optimization
```bash
flutter build apk --split-per-abi
# Creates separate APKs for arm64-v8a, armeabi-v7a, x86_64
```

---

## ✨ Next Steps for Enhancement

### Priority 1: True Offline AI
- Integrate TensorFlow Lite model for PPE detection
- Train model on IS 14489 hazard categories
- Implement on-device inference

### Priority 2: Performance
- Enable image caching
- Optimize bundle size
- Add splash screen native implementation

### Priority 3: Features
- Offline data sync queue
- Export reports to Excel
- QR code scanning for equipment inspection

---

## 📞 Support

For issues during testing:
1. Check logs: `adb logcat | grep flutter`
2. Review error messages in app
3. Test with demo credentials:
   - Username: `demo`
   - Password: `demo`

---

**Last Updated:** 2026-06-19
**Version:** 1.0.0+1
**Flutter:** 3.22+
