# Flutter-specific ProGuard rules
# Keep Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep Dart native methods
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Keep http client (needed for API calls)
-keep class org.apache.http.** { *; }
-dontwarn org.apache.http.**
-dontwarn android.net.**

# Keep Gson / JSON serialization if used
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Geolocator
-keep class com.baseflow.geolocator.** { *; }

# Image picker
-keep class io.flutter.plugins.imagepicker.** { *; }

# Connectivity plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Don't warn about missing classes from optional dependencies
-dontwarn com.google.android.play.core.**
-dontwarn com.google.firebase.**

# ML Kit text recognition (google_mlkit_text_recognition 0.13.x)
#
# WHY THIS IS NEEDED: the plugin's TextRecognizer.initialize(MethodCall) has a
# branch for every script ML Kit supports — Latin, Chinese, Devanagari, Japanese,
# Korean — so that a Dart caller can ask for any of them. Only the Latin bundle
# (text-recognition) is a transitive dependency of this app; the other four
# artifacts are separate, several-MB downloads that are not declared. R8 sees the
# four dangling references and, in a release build, treats them as errors, so
# `flutter build apk --release` fails at :app:minifyReleaseWithR8 even though the
# code paths are unreachable.
#
# WHY -dontwarn AND NOT THE REAL DEPENDENCIES: SOP scan calls
# TextRecognitionScript.latin only (sop_ocr_device_mlkit.dart:29), so the
# four classes are never loaded and R8 strips the branches. Adding the real
# artifacts would grow the APK by several MB per script for code nothing asks
# for. If Hindi SOPs ever need to be read on-device that is a deliberate feature
# decision: add
# `implementation 'com.google.android.gms:play-services-mlkit-text-recognition-devanagari'`
# to android/app/build.gradle AND pass the Devanagari script from Dart. Removing
# a line here without doing both just brings the build failure back.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep the Latin recognizer and the plugin itself. ML Kit resolves its options
# and recognizer implementations reflectively through the OptionalModuleUtils /
# Wrappers indirection, so a name R8 renames or drops is only discovered at
# runtime, as a ClassNotFoundException on the first scan — in a release build
# that would ship.
-keep class com.google.mlkit.vision.text.latin.** { *; }
-keep class com.google.mlkit.vision.text.TextRecognition { *; }
-keep class com.google.mlkit.vision.text.TextRecognizerOptionsInterface { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_commons.** { *; }
