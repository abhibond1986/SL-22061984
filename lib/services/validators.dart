// lib/services/validators.dart
// ★ v25: Input validation utilities for form fields.
// Provides consistent validation across all screens.

class Validators {
  // ── Field length limits ──────────────────────────────────────────
  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 2000;
  static const int maxLocationLength = 300;
  static const int maxNameLength = 100;
  static const int maxEmailLength = 100;
  static const int maxPhoneLength = 15;
  // Raised from 4. `app_users` password hashes are readable with the anon key
  // (see auth_service.dart), and a 4-character password is trivially recovered
  // from a salted SHA-256 by brute force. This is only enforced where a
  // password is CHOSEN — login does not check strength, so nobody with an
  // existing shorter password is locked out of their own account.
  static const int minPasswordLength = 6;
  static const int maxPasswordLength = 50;

  // ── Email validation ─────────────────────────────────────────────
  static final RegExp _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  );

  static String? validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) return 'Email is required';
    if (value.length > maxEmailLength) return 'Email too long (max $maxEmailLength chars)';
    if (!_emailRegex.hasMatch(value.trim())) return 'Invalid email format';
    return null;
  }

  // ── Phone validation (Indian format) ─────────────────────────────
  static final RegExp _phoneRegex = RegExp(r'^[6-9]\d{9}$');

  static String? validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) return null; // Optional field
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 10) return 'Phone must be 10 digits';
    if (!_phoneRegex.hasMatch(digits)) return 'Invalid Indian phone number';
    return null;
  }

  // ── Name validation ──────────────────────────────────────────────
  static String? validateName(String? value) {
    if (value == null || value.trim().isEmpty) return 'Name is required';
    if (value.trim().length < 2) return 'Name too short';
    if (value.length > maxNameLength) return 'Name too long (max $maxNameLength chars)';
    if (RegExp(r'[<>{}()\[\]]').hasMatch(value)) return 'Name contains invalid characters';
    return null;
  }

  // ── Username validation ──────────────────────────────────────────
  static final RegExp _usernameRegex = RegExp(r'^[a-zA-Z0-9._-]{3,30}$');

  static String? validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) return 'Username is required';
    if (!_usernameRegex.hasMatch(value.trim())) {
      return 'Username: 3-30 chars, letters/numbers/._- only';
    }
    return null;
  }

  // ── Password validation ──────────────────────────────────────────
  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < minPasswordLength) return 'Password must be at least $minPasswordLength characters';
    if (value.length > maxPasswordLength) return 'Password too long';
    return null;
  }

  // ── Location validation ──────────────────────────────────────────
  static String? validateLocation(String? value) {
    if (value == null || value.trim().isEmpty) return 'Location is required';
    if (value.trim() == 'To be confirmed (edit if needed)') return 'Please enter actual location';
    if (value.trim().length < 3) return 'Location too short';
    if (value.length > maxLocationLength) return 'Location too long (max $maxLocationLength chars)';
    return null;
  }

  // ── Description / text area ──────────────────────────────────────
  static String? validateDescription(String? value, {bool required = false}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'Description is required' : null;
    }
    if (value.length > maxDescriptionLength) {
      return 'Too long (max $maxDescriptionLength chars)';
    }
    return null;
  }

  // ── Generic required field ───────────────────────────────────────
  static String? validateRequired(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) return '$fieldName is required';
    return null;
  }

  // ── PNO (Personnel Number) validation ────────────────────────────
  static String? validatePno(String? value) {
    if (value == null || value.trim().isEmpty) return null; // Optional
    if (value.trim().length < 3) return 'PNO too short';
    if (value.length > 30) return 'PNO too long';
    return null;
  }

  // ── Sanitize input (strip dangerous chars for XSS prevention) ────
  static String sanitize(String input) {
    return input
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<[^>]+>'), '') // Strip HTML tags
        .replaceAll(RegExp(r'javascript:', caseSensitive: false), '')
        .trim();
  }

  /// Truncate to max length (with ellipsis indicator)
  static String truncate(String input, int maxLen) {
    if (input.length <= maxLen) return input;
    return '${input.substring(0, maxLen - 3)}...';
  }
}
