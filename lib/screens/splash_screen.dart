import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/auth_service.dart';
import '../services/api_keys.dart';
import '../services/app_logger.dart';
import '../services/startup_diagnostics.dart';
import '../widgets/glass_card.dart';
import 'login_screen.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const SplashScreen({super.key, required this.toggleTheme});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200));
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
    // Start resolving the session IMMEDIATELY, in parallel with the branding
    // animation. This used to be `Future.delayed(2000ms, _navigate)` — a fixed
    // wait that began only after initialisation had already finished, so it added
    // a flat 2 s to every single cold start regardless of how fast the device
    // was. On a healthy launch it was the largest component of time-to-login.
    _navigate();
  }

  /// Shortest time the brand mark stays on screen.
  ///
  /// Not a loading delay — session resolution runs concurrently with it and
  /// usually finishes first. It exists only so the logo does not flash past in a
  /// single frame on a fast device, which reads as a glitch. If resolution takes
  /// longer than this, there is no added wait at all.
  static const Duration _minBrandingTime = Duration(milliseconds: 450);

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _navigate() async {
    final started = DateTime.now();
    Map<String, dynamic>? user;

    // FAIL SAFE TO THE LOGIN SCREEN. Previously this method had no try/catch, so
    // if LocalDB.init() had failed during startup, `_prefs` was unset and
    // getCurrentUser() threw a LateInitializationError — Navigator was never
    // reached and the splash spinner ran forever with no way out. Treating any
    // failure as "no session" is correct on both counts: it is the safe answer
    // for access control, and it always lands the user on a screen that works.
    try {
      // Kept for compatibility; currently a no-op stub, so nothing depends on
      // its completion.
      ApiKeys.init();

      user = await LocalDB.getCurrentUser()
          .timeout(const Duration(seconds: 3), onTimeout: () => null);

      // A session that still owes a password change does not restore. Sign-in
      // writes the session before the change-password gate is shown, so someone
      // who simply closed the app at that point would otherwise come straight back
      // into the dashboard on a password the whole employee list can look up.
      // Making them sign in again puts the gate back in front of them.
      if (user != null && AuthService.mustChangePassword(user)) {
        await LocalDB.signOut();
        user = null;
      }
    } catch (e, st) {
      AppLogger.error(
        'Splash',
        'Session restore failed — continuing to login '
            '(ref ${StartupDiagnostics.sessionReference})',
        error: e,
        stack: st,
        action: 'navigate',
      );
      user = null;
    }

    final elapsed = DateTime.now().difference(started);
    if (elapsed < _minBrandingTime) {
      await Future<void>.delayed(_minBrandingTime - elapsed);
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => user != null
            ? HomeScreen(toggleTheme: widget.toggleTheme)
            : LoginScreen(toggleTheme: widget.toggleTheme),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 500)));
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: sl.bgGradient,
          ),
        ),
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassCard(
                    padding: const EdgeInsets.all(24),
                    borderRadius: 24,
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      width: 90, height: 90,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        width: 90, height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accent),
                        child: const Icon(Icons.shield, color: Colors.white, size: 45)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const BrandTitle(size: 28),
                  const SizedBox(height: 8),
                  Text('AI Safety Platform',
                    style: TextStyle(
                      color: sl.text3,
                      fontSize: 13,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w500)),
                  const SizedBox(height: 48),
                  SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.accent.withOpacity(0.7)))),
                  const SizedBox(height: 12),
                  Text('Initialising safety platform...',
                    style: TextStyle(
                      color: sl.text4, fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
