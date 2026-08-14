# GPS Geo-Tagging & Timestamp Implementation Plan

## Overview
Add precise GPS location capture and timestamp watermarking to AI Scan photos with edit capability.

## ✅ Phase 1: Dependencies & Services (COMPLETED)

### 1. Added Dependencies to pubspec.yaml
```yaml
geolocator: ^10.1.0      # High-accuracy GPS
geocoding: ^2.1.1         # Address lookup
image: ^4.1.3             # Image watermarking
```

### 2. Created GeoService (lib/services/geo_service.dart)
**Features:**
- ✅ High-accuracy GPS capture (±5-10m typically)
- ✅ Automatic address lookup from coordinates
- ✅ Permission handling
- ✅ Image watermarking with timestamp + GPS
- ✅ Error handling

**Methods:**
- `getCurrentLocation()` - Captures GPS with high accuracy
- `addWatermarkToImage()` - Adds timestamp + GPS watermark to image
- `getDisplayAddress()` - Formats location for display
- `getGoogleMapsUrl()` - Generates Google Maps link

---

## 📋 Phase 2: Integration with AI Scan (TODO)

### Files to Modify:
1. **lib/screens/ai_scan_tab.dart**
   - Import GeoService
   - Capture GPS when taking photo
   - Add watermark to image
   - Store location data
   - Show location in review UI
   - Add edit location button

2. **lib/services/local_db.dart**
   - Add location fields to incident schema
   - Store GPS coordinates, address, accuracy

3. **lib/services/pdf_export.dart**
   - Include location data in PDF reports
   - Show GPS coordinates + address
   - Optionally embed map thumbnail

4. **lib/screens/incident_detail_screen.dart**
   - Display location with edit button
   - Allow location editing

---

## 🔧 Implementation Steps

### Step 1: Update AI Scan Tab

#### A. Add State Variables
```dart
LocationData? _capturedLocation;
bool _capturingLocation = false;
```

#### B. Modify _pickImage() Method
```dart
Future<void> _pickImage() async {
  // Show loading for GPS
  setState(() { _capturingLocation = true; });
  
  // Capture GPS FIRST (before/during photo)
  final location = await GeoService.getCurrentLocation();
  
  // Then pick image
  final XFile? file = await _picker.pickImage(
    source: ImageSource.camera,
    imageQuality: 85,
  );
  
  if (file != null && mounted) {
    final bytes = await file.readAsBytes();
    
    // Add watermark with timestamp + GPS
    final watermarked = await GeoService.addWatermarkToImage(
      bytes,
      location ?? LocationData(error: 'No GPS'),
    );
    
    setState(() {
      _pickedFile = file;
      _imageBytes = watermarked ?? bytes;
      _capturedLocation = location;
      _capturingLocation = false;
      
      // Set location text
      if (location?.isValid == true) {
        _locationController.text = GeoService.getDisplayAddress(location!);
      }
    });
  }
}
```

#### C. Add Location Display in Review UI
```dart
// In _reviewSheet(), after image display:
if (_capturedLocation != null && _capturedLocation!.isValid)
  _locationCard(sl),
```

#### D. Add _locationCard() Widget
```dart
Widget _locationCard(SL sl) {
  final loc = _capturedLocation!;
  return Container(
    margin: const EdgeInsets.all(16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: sl.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: sl.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.location_on, color: AppColors.accent, size: 20),
            const SizedBox(width: 8),
            Text('Location', style: TextStyle(
              color: sl.text1,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            )),
            const Spacer(),
            // Edit button
            IconButton(
              icon: Icon(Icons.edit, size: 18),
              onPressed: _editLocation,
              tooltip: 'Edit Location',
            ),
          ],
        ),
        const SizedBox(height: 12),
        
        // Coordinates
        if (loc.latitude != null && loc.longitude != null) ...[
          _locationRow(Icons.gps_fixed, 
            'GPS: ${loc.latitude!.toStringAsFixed(6)}, ${loc.longitude!.toStringAsFixed(6)}', sl),
          if (loc.accuracy != null)
            _locationRow(Icons.my_location, 
              'Accuracy: ±${loc.accuracy!.toStringAsFixed(1)}m', sl),
        ],
        
        // Address
        if (loc.address != null && loc.address!.isNotEmpty)
          _locationRow(Icons.place, loc.address!, sl),
        
        // Timestamp
        _locationRow(Icons.access_time, 
          'Captured: ${_formatTimestamp(loc.timestamp)}', sl),
        
        // Google Maps link
        if (loc.latitude != null && loc.longitude != null) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _openInMaps(loc.latitude!, loc.longitude!),
            child: Text('📍 View on Google Maps',
              style: TextStyle(color: AppColors.accent, fontSize: 13)),
          ),
        ],
      ],
    ),
  );
}

Widget _locationRow(IconData icon, String text, SL sl) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 16, color: sl.text3),
        const SizedBox(width: 8),
        Expanded(child: Text(text, 
          style: TextStyle(color: sl.text2, fontSize: 13))),
      ],
    ),
  );
}
```

#### E. Add Edit Location Dialog
```dart
void _editLocation() {
  final latCtrl = TextEditingController(
    text: _capturedLocation?.latitude?.toString() ?? '',
  );
  final lonCtrl = TextEditingController(
    text: _capturedLocation?.longitude?.toString() ?? '',
  );
  final addrCtrl = TextEditingController(
    text: _capturedLocation?.address ?? '',
  );

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit Location'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: latCtrl,
            decoration: const InputDecoration(labelText: 'Latitude'),
            keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
          ),
          TextField(
            controller: lonCtrl,
            decoration: const InputDecoration(labelText: 'Longitude'),
            keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
          ),
          TextField(
            controller: addrCtrl,
            decoration: const InputDecoration(labelText: 'Address (optional)'),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final lat = double.tryParse(latCtrl.text);
            final lon = double.tryParse(lonCtrl.text);
            if (lat != null && lon != null) {
              setState(() {
                _capturedLocation = LocationData(
                  latitude: lat,
                  longitude: lon,
                  address: addrCtrl.text.isEmpty ? null : addrCtrl.text,
                  accuracy: _capturedLocation?.accuracy,
                  timestamp: _capturedLocation?.timestamp ?? DateTime.now(),
                );
                _locationController.text = GeoService.getDisplayAddress(_capturedLocation!);
              });
            }
            Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
```

---

### Step 2: Update Database Schema

**lib/services/local_db.dart**

Add location fields to incident model:
```dart
{
  'id': '...',
  'date': '...',
  'location': '...', // Text description
  'latitude': 12.345678, // GPS lat
  'longitude': 78.123456, // GPS lon
  'locationAccuracy': 8.5, // meters
  'locationAddress': '...', // Full address
  'locationTimestamp': '2024-06-21T10:30:45Z',
  // ... existing fields
}
```

---

### Step 3: Update PDF Export

**lib/services/pdf_export.dart**

Add location section:
```dart
// GPS Location Section
if (incident['latitude'] != null) {
  pdf.addParagraph('GPS Location:');
  pdf.addParagraph(
    'Coordinates: ${incident['latitude']}, ${incident['longitude']}',
    fontSize: 10,
  );
  if (incident['locationAccuracy'] != null) {
    pdf.addParagraph(
      'Accuracy: ±${incident['locationAccuracy']}m',
      fontSize: 10,
    );
  }
  if (incident['locationAddress'] != null) {
    pdf.addParagraph(
      'Address: ${incident['locationAddress']}',
      fontSize: 10,
    );
  }
  
  // Google Maps link
  final mapsUrl = 'https://www.google.com/maps?q=${incident['latitude']},${incident['longitude']}';
  pdf.addParagraph('View on Maps: $mapsUrl', fontSize: 10);
}
```

---

## 🔐 Permissions Required

### Android (android/app/src/main/AndroidManifest.xml)
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

### iOS (ios/Runner/Info.plist)
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Safety Lens needs your location to tag incident photos with precise GPS coordinates for accurate reporting.</string>
<key>NSLocationAlwaysUsageDescription</key>
<string>Safety Lens needs your location to tag incident photos with precise GPS coordinates.</string>
```

---

## 🧪 Testing Checklist

- [ ] GPS captures correctly on photo capture
- [ ] Watermark shows timestamp + coordinates
- [ ] Location editable in review screen
- [ ] PDF includes location data
- [ ] Works without GPS (shows error gracefully)
- [ ] Accuracy indicator shows correctly
- [ ] Google Maps link opens correctly
- [ ] Address lookup works (online mode)
- [ ] Offline mode handles GPS correctly

---

## 📱 User Flow

1. User taps camera icon in AI Scan
2. **GPS auto-captures** (shows loading indicator)
3. Camera opens
4. User takes photo
5. **Watermark automatically added** with timestamp + GPS
6. Review screen shows:
   - Photo with watermark
   - GPS coordinates
   - Accuracy (±Xm)
   - Address (if available)
   - Edit location button
7. User can edit location if needed
8. Save includes all location data
9. PDF report shows location with maps link

---

## ⚡ Performance Notes

- GPS capture: 2-10 seconds (high accuracy)
- Watermarking: <1 second
- Address lookup: 1-3 seconds (requires internet)
- Fallback to coordinates if address unavailable

---

## 🚀 Next Steps

**To complete implementation:**

1. Run `flutter pub get` to install new dependencies
2. Update permission files (AndroidManifest.xml, Info.plist)
3. Integrate code changes into ai_scan_tab.dart
4. Update local_db.dart schema
5. Update pdf_export.dart
6. Test on real device (GPS doesn't work in emulator)
7. Deploy APK

**After current session:**
User should run:
```bash
cd C:\Users\DELL\Desktop\Safety-Lens-V2
flutter pub get
flutter build apk --debug
```

---

## 📝 Files Modified/Created

1. ✅ **pubspec.yaml** - Added dependencies
2. ✅ **lib/services/geo_service.dart** - NEW service file
3. ⏳ **lib/screens/ai_scan_tab.dart** - Integration (TODO)
4. ⏳ **lib/services/local_db.dart** - Schema update (TODO)
5. ⏳ **lib/services/pdf_export.dart** - Location in PDF (TODO)
6. ⏳ **android/app/src/main/AndroidManifest.xml** - Permissions (TODO)
7. ⏳ **ios/Runner/Info.plist** - Permissions (TODO)

---

Generated: 2024-06-21
