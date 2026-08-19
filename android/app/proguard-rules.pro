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
# WHY -dontwarn AND NOT THE REAL DEPENDENCIES: SOP scan asks for Latin and
# Devanagari only, so Chinese, Japanese and Korean are never loaded and R8 strips
# those branches. Their artifacts would add several MB of bundled model each for
# scripts nothing requests.
#
# UPDATED 2026-08-19 — Devanagari IS now a real dependency
# (`com.google.mlkit:text-recognition-devanagari:16.0.1` in
# android/app/build.gradle) because Hindi SOP/SMP pages are read on-device. Its
# -dontwarn line is KEPT ON PURPOSE even though the class is now present: the rule
# is a no-op while the dependency is there, and it means removing that dependency
# later degrades Hindi OCR instead of breaking the release build with an error
# whose cause is three files away.
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
-keep class com.google.mlkit.vision.text.devanagari.** { *; }
-keep class com.google.mlkit.vision.text.TextRecognition { *; }
-keep class com.google.mlkit.vision.text.TextRecognizerOptionsInterface { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_commons.** { *; }
