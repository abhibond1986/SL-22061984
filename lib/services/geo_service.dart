// lib/services/geo_service.dart
// GPS location capture and image watermarking service
// ★ v32: Added EXIF GPS extraction from uploaded images

import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'device_permissions.dart';

class GeoService {
  /// Captures current GPS location with high accuracy
  static Future<LocationData?> getCurrentLocation() async {
    // ★ 2026-10-30: the user turned location off in My Profile - no GPS
    // prompt, no fix; reports simply carry no coordinates (EXIF still works).
    if (!DevicePermissions.isEnabled(DeviceFeature.location)) {
      return LocationData(error: 'Location is turned off in My Profile');
    }
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return LocationData(
          error: 'Location services are disabled. Please enable GPS.',
        );
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return LocationData(
            error: 'Location permission denied',
          );
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return LocationData(
          error: 'Location permissions are permanently denied. Please enable in settings.',
        );
      }

      // Get high-accuracy position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      // Get address from coordinates
      String address = '';
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          Placemark place = placemarks[0];
          address = [
            place.street,
            place.subLocality,
            place.locality,
            place.administrativeArea,
            place.postalCode,
            place.country,
          ].where((e) => e != null && e.isNotEmpty).join(', ');
        }
      } catch (e) {
        // Address lookup failed, continue with coordinates only
        address = '';
      }

      return LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        altitude: position.altitude,
        timestamp: position.timestamp,
        address: address,
      );
    } catch (e) {
      return LocationData(
        error: 'Failed to get location: ${e.toString()}',
      );
    }
  }

  /// ★ v32: Extract GPS coordinates from image EXIF metadata
  /// Returns LocationData if GPS found in EXIF, null otherwise.
  /// Works with JPEG/TIFF images that have GPS tags (original camera photos).
  /// Will NOT work with screenshots, WhatsApp-forwarded images, or edited photos.
  static Future<LocationData?> getLocationFromExif(Uint8List imageBytes) async {
    try {
      final tags = await readExifFromBytes(imageBytes);
      if (tags.isEmpty) return null;

      // Extract GPS latitude
      final latTag = tags['GPS GPSLatitude'];
      final latRef = tags['GPS GPSLatitudeRef'];
      final lonTag = tags['GPS GPSLongitude'];
      final lonRef = tags['GPS GPSLongitudeRef'];

      if (latTag == null || lonTag == null) return null;

      final lat = _exifGpsToDouble(latTag.values, latRef?.toString() ?? 'N');
      final lon = _exifGpsToDouble(lonTag.values, lonRef?.toString() ?? 'E');

      if (lat == null || lon == null) return null;
      if (lat == 0.0 && lon == 0.0) return null; // Invalid/default coords

      // Try to extract timestamp from EXIF
      DateTime? photoTime;
      final dateTag = tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'];
      if (dateTag != null) {
        try {
          // EXIF date format: "2026:07:09 14:30:00"
          final s = dateTag.toString().replaceFirst(':', '-').replaceFirst(':', '-');
          photoTime = DateTime.tryParse(s.replaceFirst(' ', 'T'));
        } catch (_) {}
      }

      // Reverse geocode to get address
      String address = '';
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(lat, lon);
        if (placemarks.isNotEmpty) {
          Placemark place = placemarks[0];
          address = [
            place.street,
            place.subLocality,
            place.locality,
            place.administrativeArea,
            place.postalCode,
          ].where((e) => e != null && e.isNotEmpty).join(', ');
        }
      } catch (_) {
        // Reverse geocoding failed — return coords without address
      }

      return LocationData(
        latitude: lat,
        longitude: lon,
        accuracy: null, // EXIF doesn't store accuracy
        timestamp: photoTime ?? DateTime.now(),
        address: address,
      );
    } catch (e) {
      // EXIF parsing failed — image may not have EXIF or format unsupported
      return null;
    }
  }

  /// Convert EXIF GPS rational values to decimal degrees
  static double? _exifGpsToDouble(dynamic values, String ref) {
    try {
      if (values == null) return null;
      final rationals = values.toList();
      if (rationals.length < 3) return null;

      final deg = _rationalToDouble(rationals[0]);
      final min = _rationalToDouble(rationals[1]);
      final sec = _rationalToDouble(rationals[2]);

      if (deg == null || min == null || sec == null) return null;

      double result = deg + (min / 60.0) + (sec / 3600.0);
      if (ref == 'S' || ref == 'W') result = -result;
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Convert a Rational EXIF value to double
  /// The `exif` package returns Ratio objects with numerator/denominator
  static double? _rationalToDouble(dynamic rational) {
    try {
      if (rational is Ratio) {
        if (rational.denominator == 0) return null;
        return rational.numerator.toDouble() / rational.denominator.toDouble();
      }
      // Fallback: try as num
      if (rational is num) return rational.toDouble();
      // Some EXIF implementations return string "23/1"
      if (rational is String && rational.contains('/')) {
        final parts = rational.split('/');
        if (parts.length == 2) {
          final n = double.tryParse(parts[0]);
          final d = double.tryParse(parts[1]);
          if (n != null && d != null && d != 0) return n / d;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Adds timestamp and location watermark to image
  static Future<Uint8List?> addWatermarkToImage(
    Uint8List imageBytes,
    LocationData location,
  ) async {
    try {
      // Decode image
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) return imageBytes;

      // Create timestamp text
      String timestamp = _formatTimestamp(location.timestamp);

      // Create location text
      String locationText = '';
      if (location.latitude != null && location.longitude != null) {
        locationText = 'GPS: ${location.latitude!.toStringAsFixed(6)}, ${location.longitude!.toStringAsFixed(6)}';
        if (location.accuracy != null) {
          locationText += ' (±${location.accuracy!.toStringAsFixed(1)}m)';
        }
      }

      // Draw semi-transparent black background bar at bottom
      final barHeight = 80;
      img.fillRect(
        image,
        x1: 0,
        y1: image.height - barHeight,
        x2: image.width,
        y2: image.height,
        color: img.ColorRgba8(0, 0, 0, 180), // Semi-transparent black
      );

      // Draw timestamp (white text)
      img.drawString(
        image,
        timestamp,
        font: img.arial48,
        x: 20,
        y: image.height - barHeight + 10,
        color: img.ColorRgba8(255, 255, 255, 255),
      );

      // Draw location (white text)
      if (locationText.isNotEmpty) {
        img.drawString(
          image,
          locationText,
          font: img.arial24,
          x: 20,
          y: image.height - barHeight + 50,
          color: img.ColorRgba8(255, 255, 255, 255),
        );
      }

      // Encode back to bytes
      return Uint8List.fromList(img.encodeJpg(image, quality: 95));
    } catch (e) {
      // If watermarking fails, return original image
      return imageBytes;
    }
  }

  /// Formats timestamp for watermark
  static String _formatTimestamp(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// Gets formatted address string for display
  static String getDisplayAddress(LocationData location) {
    if (location.error != null) return location.error!;
    if (location.address != null && location.address!.isNotEmpty) {
      return location.address!;
    }
    if (location.latitude != null && location.longitude != null) {
      return '${location.latitude!.toStringAsFixed(6)}, ${location.longitude!.toStringAsFixed(6)}';
    }
    return 'Location not available';
  }

  /// Gets Google Maps URL for location
  static String getGoogleMapsUrl(double lat, double lon) {
    return 'https://www.google.com/maps?q=$lat,$lon';
  }
}

/// Location data model
class LocationData {
  final double? latitude;
  final double? longitude;
  final double? accuracy; // meters
  final double? altitude; // meters
  final DateTime timestamp;
  final String? address;
  final String? error;

  LocationData({
    this.latitude,
    this.longitude,
    this.accuracy,
    this.altitude,
    DateTime? timestamp,
    this.address,
    this.error,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'timestamp': timestamp.toIso8601String(),
        'address': address,
      };

  factory LocationData.fromJson(Map<String, dynamic> json) => LocationData(
        latitude: json['latitude'] as double?,
        longitude: json['longitude'] as double?,
        accuracy: json['accuracy'] as double?,
        altitude: json['altitude'] as double?,
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'])
            : DateTime.now(),
        address: json['address'] as String?,
      );

  bool get isValid => latitude != null && longitude != null && error == null;
}
