import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/auth_service.dart';
import '../services/api_keys.dart';
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
    Future.delayed(const Duration(milliseconds: 2000), _navigate);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _navigate() async {
    if (!mounted) return;
    // Fetch API keys in background during splash (non-blocking)
    ApiKeys.init(); // fire-and-forget, cached for entire session
    var user = await LocalDB.getCurrentUser();
    // A session that still owes a password change does not restore. Sign-in
    // writes the session before the change-password gate is shown, so someone
    // who simply closed the app at that point would otherwise come straight back
    // into the dashboard on a password the whole employee list can look up.
    // Making them sign in again puts the gate back in front of them.
    if (user != null && AuthService.mustChangePassword(user)) {
      await LocalDB.signOut();
      user = null;
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
