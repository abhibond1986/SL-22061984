// lib/utils/sail_logo.dart
// Company logo — kept for existing call sites; delegates to [BrandLogo] so a
// custom logo set in Admin → Company Branding shows here too.
// Usage: SailLogo.widget(size: 48)

import 'package:flutter/material.dart';
import '../widgets/brand_logo.dart';

class SailLogo {
  /// The company logo (custom if set, else the bundled SAIL icon).
  static Widget widget({double size = 48}) =>
      BrandLogo(size: size, fallbackColor: Colors.grey);

  /// Alias kept for backward compat — same as widget().
  static Widget icon({double size = 32}) => widget(size: size);
}
