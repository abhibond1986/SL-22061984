import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../services/admin_master_data.dart';
import '../services/app_updater.dart';
// Every credential operation on this screen goes through AuthService — one
// hashing scheme, one place that talks to Supabase. See auth_service.dart for
// why the previous per-screen hashing was broken.
import '../services/auth_service.dart';
import '../services/validators.dart';
import '../services/visitor_service.dart';
import '../services/i18n.dart';
import 'home_screen.dart';
import 'contractor_home_screen.dart';
import 'force_password_change_screen.dart';
import '../widgets/brand_logo.dart';
import '../widgets/plant_backdrop.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const LoginScreen({super.key, required this.toggleTheme});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLogin = true;
  bool _loading = false;
  String _err = '';

  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  final _regNameCtrl   = TextEditingController();
  final _regUserCtrl   = TextEditingController();
  final _regPassCtrl   = TextEditingController();
  final _regConfirmCtrl = TextEditingController();
  final _regDesigCtrl  = TextEditingController();
  final _regPnoCtrl    = TextEditingController();
  final _regMobileCtrl = TextEditingController();
  final _regOtherPlantCtrl = TextEditingController();

  String? _selectedPlant;
  bool _isOtherPlant = false;

  /// Reveal state for the password fields. A hidden password field on a phone
  /// held in a gloved hand is how people end up locked out by a typo they
  /// cannot see.
  bool _showLoginPass = false;
  bool _showRegPass = false;

  /// Latest released version shown on the download button. Fetched from the
  /// GitHub Releases API rather than hardcoded, because the CI workflow bumps
  /// the version on every push to main — a literal here would be wrong within
  /// a day, and pubspec.yaml is already stale (1.0.98 while releases are at
  /// 1.0.166) precisely because it has to be updated by hand.
  String _latestVersion = '';
  int _latestSizeBytes = 0;

  // SINGLE SOURCE OF TRUTH: AdminMasterData. Seeded from the shared const via
  // the shared label formatter so the first frame matches what _loadPlants()
  // will install — no re-typed copy that can drift from the master list.
  List<String> _sailPlants = AdminMasterData.sailPlants
      .map(AdminMasterData.plantLabel)
      .where((s) => s.isNotEmpty)
      .toList();

  String get _effectivePlant {
    if (_isOtherPlant) return _regOtherPlantCtrl.text.trim();
    return _selectedPlant ?? '';
  }

  @override
  void initState() {
    super.initState();
    _loadPlants();
    AdminMasterData.revision.addListener(_loadPlants);
    _loadLatestVersion();
  }

  /// Non-blocking: the button renders immediately with a generic subtitle and
  /// gains the version when (or if) the call returns. Login must never wait on
  /// GitHub being reachable.
  Future<void> _loadLatestVersion() async {
    final rel = await AppUpdater.getLatestRelease();
    if (rel == null || !mounted) return;
    setState(() {
      _latestVersion = rel.version;
      _latestSizeBytes = rel.sizeBytes;
    });
  }

  /// Subtitle for the download button. Falls back to the original wording when
  /// the version isn't known, so an offline or rate-limited device sees no
  /// error text and no empty gap.
  String get _downloadSubtitle {
    if (_latestVersion.isEmpty) return 'Android only · Always updated';
    final mb = _latestSizeBytes > 0
        ? ' · ${(_latestSizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB'
        : '';
    return 'Android · v$_latestVersion$mb · Latest';
  }

  Future<void> _loadPlants() async {
    try {
      // getPlantLabels() already de-duplicates and includes the master
      // list's own catch-all entry, so nothing is appended here — the old
      // code added a second 'Others' on top of the one in the master list.
      final list = await AdminMasterData.getPlantLabels();
      if (!mounted) return;
      setState(() {
        _sailPlants = list;
        // Drop a stale selection that the admin has since deleted.
        if (_selectedPlant != null && !list.contains(_selectedPlant)) {
          _selectedPlant = null;
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    AdminMasterData.revision.removeListener(_loadPlants);
    _userCtrl.dispose(); _passCtrl.dispose();
    _regNameCtrl.dispose(); _regUserCtrl.dispose(); _regPassCtrl.dispose();
    _regConfirmCtrl.dispose(); _regMobileCtrl.dispose();
    _regDesigCtrl.dispose(); _regPnoCtrl.dispose(); _regOtherPlantCtrl.dispose();
    super.dispose();
  }

  void _goHome() {
    // Attach the now-known employee ID to this device's visitor row, so the
    // admin panel can report unique SIGNED-IN staff as well as unique devices.
    // _goHome is the single funnel both sign-in and registration pass through,
    // and AuthService has already written the session by this point.
    // (Contractor entry navigates directly to ContractorHomeScreen and so is
    // intentionally not counted here — contractors have no employee ID.)
    VisitorService.recordLogin().catchError((_) {});
    Navigator.pushReplacement(context, PageRouteBuilder(
      pageBuilder: (_, a, __) =>
          HomeScreen(toggleTheme: widget.toggleTheme),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
      transitionDuration: const Duration(milliseconds: 400)));
  }

  Future<void> _login() async {
    final username = _userCtrl.text.trim();
    final password = _passCtrl.text;

    // Validate inputs
    final usernameErr = Validators.validateRequired(username, 'Username');
    if (usernameErr != null) { setState(() => _err = usernameErr); return; }
    if (password.isEmpty) {
      setState(() => _err = 'Enter your password'); return;
    }
    // NOTE: no strength check on LOGIN. The old code ran
    // Validators.validatePassword() here, so anyone whose existing password
    // predated the current rules was told their own valid password was
    // "too short" and could never get in. Strength is enforced where a
    // password is CHOSEN (register / reset), which is the only place it means
    // anything.

    setState(() { _loading = true; _err = ''; });
    try {
      // One call. AuthService tries local → Supabase → legacy backend, upgrades
      // legacy credential formats on the way through, caches the account for
      // offline use, and reports WHY it failed.
      final res = await AuthService.signIn(username, password);
      if (!mounted) return;
      if (res.ok) {
        // Bulk-imported employees, and anyone whose password an admin has just
        // reset, must choose their own before the app opens. The gate returns
        // false if they backed out — it has already signed the session out, so
        // we simply stay on this screen.
        if (AuthService.mustChangePassword(res.user)) {
          final changed = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                  builder: (_) => ForcePasswordChangeScreen(
                        username: res.user?['username']?.toString() ??
                            username.toLowerCase(),
                        currentPassword: password,
                        name: res.user?['name']?.toString() ?? '',
                      )));
          if (!mounted) return;
          if (changed != true) {
            setState(() => _err =
                'Please set your own password to finish signing in.');
            return;
          }
        }
        _goHome();
      } else {
        setState(() => _err = res.message);
      }
    } catch (e) {
      if (mounted) setState(() => _err = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _register() async {
    final name  = _regNameCtrl.text.trim();
    final user  = _regUserCtrl.text.trim();
    final pass  = _regPassCtrl.text;
    final confirm = _regConfirmCtrl.text;
    final desig = _regDesigCtrl.text.trim();
    final plant = _effectivePlant;

    // Validate all fields
    final nameErr = Validators.validateName(name);
    if (nameErr != null) { setState(() => _err = nameErr); return; }
    final userErr = Validators.validateUsername(user);
    if (userErr != null) { setState(() => _err = userErr); return; }
    final passErr = Validators.validatePassword(pass);
    if (passErr != null) { setState(() => _err = passErr); return; }
    if (confirm != pass) {
      setState(() => _err = 'Passwords do not match'); return;
    }
    if (desig.isEmpty) { setState(() => _err = 'Designation is required'); return; }
    if (plant.isEmpty) { setState(() => _err = 'Please select a plant'); return; }
    setState(() { _loading = true; _err = ''; });
    try {
      // Profile fields only — the password travels as its own argument so a
      // plaintext value never sits in a map that could be logged or persisted.
      final userData = <String, dynamic>{
        'name': name,
        'username': user.toLowerCase(),
        'designation': desig,
        'plant': plant,
        'pno': _regPnoCtrl.text.trim(),
        'mobile': _regMobileCtrl.text.trim(),
        'isAdmin': 'false',
        'status': 'active',
      };
      // AuthService checks the username against the SERVER as well as locally
      // and writes the account to Supabase before creating it locally — so an
      // account can no longer exist on one device only, invisible to the admin
      // panel and unable to log in anywhere else.
      final res = await AuthService.register(userData, pass);
      if (!mounted) return;
      if (res.ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${I18n.t('common.success')}! Welcome, $name'),
          // Colors.green gives white snackbar text 2.5:1. greenLight is 5.48:1.
          backgroundColor: AppColors.greenLight,
          duration: const Duration(seconds: 2)));
        _goHome();
      } else {
        setState(() => _err = res.message);
      }
    } catch (e) {
      if (mounted) setState(() => _err = 'Registration failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _contractorAccess() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) =>
            ContractorHomeScreen(toggleTheme: widget.toggleTheme),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  // ─── LAYOUT (2026-10-05 glassmorphism redesign) ─────────────────────────────
  //
  // One frosted card floats over a "lens" backdrop: the brand indigo → teal
  // field, three soft colour glows (indigo, teal, and a molten-amber glow from
  // the furnace end of the plant) and a set of faint concentric rings, like an
  // aperture, centred behind the card. The rings are the one decorative idea.
  // Everything else is plain and quiet.
  //
  // Performance: there is exactly ONE BackdropFilter (the card). The glows are
  // painted with MaskFilter.blur inside a CustomPainter, which is cheap on
  // Flutter web, unlike stacked BackdropFilters (UI_UX_AUDIT.md §A).
  //
  // ≥ 960px wide: two columns, with the brand statement on the left and the
  // card on the right. Narrower than that: one centred column.
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Scaffold(
      backgroundColor: _LoginGlass.base(sl),
      body: Stack(children: [
        Positioned.fill(
          child: PlantBackdrop(isDark: sl.isDark),
        ),
        SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 960;
            // The single page-load moment: the content rises 12px and fades
            // in. Skipped when the OS asks for reduced motion.
            Widget entrance(Widget child) => TweenAnimationBuilder<double>(
                  tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 520),
                  curve: Curves.easeOutCubic,
                  builder: (_, t, c) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                        offset: Offset(0, 12 * (1 - t)), child: c),
                  ),
                  child: child,
                );
            if (wide) {
              // Two columns. Only the form column scrolls (user, 2026-10-05:
              // the tall Register form scrolled the whole page and took the
              // brand text with it). The brand statement is fixed, centred
              // in the viewport; the form is centred while it fits and
              // scrolls on its own once it is taller than the window.
              return entrance(Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080 + 96),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Row(children: [
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            // Only scrolls on a very short window.
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: _brandStatement(sl),
                          ),
                        ),
                      ),
                      const SizedBox(width: 56),
                      SizedBox(
                        width: SLLayout.form,
                        child: LayoutBuilder(
                          builder: (context, col) => SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  minHeight:
                                      math.max(0, col.maxHeight - 56)),
                              child: Center(child: _formColumn(sl)),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ));
            }
            return Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                child: entrance(ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: SLLayout.form),
                  child: Column(children: [
                    _compactHeader(sl),
                    const SizedBox(height: 24),
                    _formColumn(sl),
                  ]),
                )),
              ),
            );
          }),
        ),
      ]),
    );
  }

  /// Phone / narrow header: emblem, wordmark and tagline, centred.
  Widget _compactHeader(SL sl) => Column(children: [
        _logoMark(sl, 92),
        const SizedBox(height: 18),
        const BrandTitle(size: 27),
        const SizedBox(height: 6),
        _tagline(sl, 13.5),
      ]);

  /// Desktop left column, centred: emblem, wordmark, tagline, one plain
  /// sentence about the product and three features.
  ///
  /// It sits on a borderless "reading plate": one large, very soft shadow in
  /// the sky's navy (pale veil in light mode). The plate quietly darkens the
  /// busy part of the illustration (HUD lines, lit structures) directly behind
  /// the text and has no visible edge. The pour, lower right, stays bright.
  /// 2026-10-05: the user found the text over the raw illustration unreadable.
  Widget _brandStatement(SL sl) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(220),
          boxShadow: [
            BoxShadow(
              color: sl.isDark
                  ? const Color(0xFF020A2E).withOpacity(0.84)
                  : const Color(0xFFF2F4FF).withOpacity(0.92),
              blurRadius: 110,
              spreadRadius: 24,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: _brandContent(sl),
        ),
      );

  /// Soft legibility shadow for text drawn over the photo (dark mode only).
  static List<Shadow>? _ink(SL sl) => sl.isDark
      ? const [Shadow(color: Color(0xB3000418), blurRadius: 10)]
      : null;

  Widget _brandContent(SL sl) => Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _logoMark(sl, 132),
          const SizedBox(height: 26),
          const BrandTitle(size: 42),
          const SizedBox(height: 10),
          _tagline(sl, 16),
          const SizedBox(height: 30),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Text(
              'Photograph a work area, see its hazards marked within seconds, '
              'and follow every corrective action through to closure.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: sl.isDark ? const Color(0xFFEDF1F8) : sl.text2,
                  fontSize: 18,
                  height: 1.5,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.1,
                  shadows: _ink(sl)),
            ),
          ),
          const SizedBox(height: 28),
          // Left-aligned list, centred as a block, so the icons line up.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _feature(sl, Icons.center_focus_strong_rounded,
                  'AI hazard scan from a single photo'),
              _feature(sl, Icons.assignment_turned_in_outlined,
                  'Incidents assigned and tracked to closure'),
              _feature(sl, Icons.picture_as_pdf_outlined,
                  'Shareable PDF reports with location'),
            ],
          ),
        ],
      );

  /// Tagline set in the wordmark's family, slightly tracked, so the pair
  /// reads as one lock-up.
  Widget _tagline(SL sl, double size) => Text(I18n.t('app.tagline'),
      textAlign: TextAlign.center,
      style: GoogleFonts.plusJakartaSans(
          color: sl.isDark ? const Color(0xFFC9D3E6) : sl.text3,
          fontSize: size,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.04 * size,
          shadows: _ink(sl)));

  Widget _feature(SL sl, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 19, color: sl.accentText),
          const SizedBox(width: 12),
          Text(text,
              style: TextStyle(
                  color: sl.isDark ? const Color(0xFFE2E8F2) : sl.text2,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  shadows: _ink(sl))),
        ]),
      );

  /// The bare brand emblem, with no tile or backing. 2026-10-05: the user found
  /// three nested rounded frames around the logo cluttered (see [BrandMark]).
  /// A soft glow behind it keeps it anchored on the gradient.
  Widget _logoMark(SL sl, double size) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (sl.isDark ? const Color(0xFF6D7BFF) : Colors.white)
                  .withOpacity(sl.isDark ? 0.22 : 0.85),
              blurRadius: size * 0.6,
              spreadRadius: size * 0.05,
            ),
          ],
        ),
        child: BrandMark(size: size, onDark: sl.isDark),
      );

  /// The card, then the two secondary ways in, then the theme switch.
  Widget _formColumn(SL sl) => Column(children: [
        _glassCard(sl),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, box) {
          final contractor = _secondaryTile(
            sl,
            icon: Icons.engineering_outlined,
            iconColor: sl.cyanText,
            title: 'Contractor access',
            subtitle: 'No login. AI scan and near miss only',
            onTap: _contractorAccess,
          );
          final android = _secondaryTile(
            sl,
            icon: Icons.android_rounded,
            iconColor: sl.greenText,
            title: 'Get the Android app',
            subtitle: _downloadSubtitle,
            onTap: _launchAppDownload,
          );
          if (box.maxWidth < 360) {
            return Column(children: [
              contractor,
              const SizedBox(height: 10),
              android,
            ]);
          }
          return IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: contractor),
              const SizedBox(width: 10),
              Expanded(child: android),
            ]),
          );
        }),
        const SizedBox(height: 14),
        // TextButton, not a GestureDetector around 11px text: this is the only
        // theme switch before sign-in, so it has to be a real 48px target.
        TextButton.icon(
          onPressed: widget.toggleTheme,
          icon: Icon(
              sl.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: sl.text3,
              size: 18),
          label: Text(sl.isDark ? 'Switch to light mode' : 'Switch to dark mode',
              style: TextStyle(color: sl.text3, fontSize: SLText.minLabel)),
          style: TextButton.styleFrom(
              minimumSize: const Size(0, SLSpace.tapTarget),
              padding: const EdgeInsets.symmetric(horizontal: SLSpace.lg),
              shape: const RoundedRectangleBorder(borderRadius: SLRadius.rSm)),
        ),
      ]);

  /// The frosted card holding the toggle, fields, error and primary button.
  Widget _glassCard(SL sl) => DecoratedBox(
        // Shadow sits OUTSIDE the clip, otherwise ClipRRect would cut it off.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: (sl.isDark ? Colors.black : const Color(0xFF3B47B8))
                  .withOpacity(sl.isDark ? 0.40 : 0.16),
              blurRadius: 48,
              offset: const Offset(0, 22),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                // Brighter at the top-left like light catching a glass edge.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _LoginGlass.cardFill(sl),
                ),
                // Hairline molten-amber edge (user, 2026-10-05: "boundary of
                // sign in section a little orange, very less thickness").
                border: Border.all(color: _LoginGlass.edge(sl), width: 0.8),
              ),
              // AutofillGroup, not just autofillHints on the fields: only a group
              // tells the platform these fields are one form, which is what makes
              // "save this password?" appear after a successful sign-in.
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_isLogin ? 'Sign in' : 'Create your account',
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3)),
                    const SizedBox(height: 4),
                    Text(
                        _isLogin
                            ? 'Use your Safety Lens username and password.'
                            : 'Your P.No. or mobile lets you reset a forgotten password.',
                        style: TextStyle(
                            color: sl.text3, fontSize: 12.5, height: 1.4)),
                    const SizedBox(height: 18),
                    _segmented(sl),
                    const SizedBox(height: 20),
                    if (_isLogin) ..._loginFields(sl) else ..._registerFields(sl),
                    if (_err.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: AppColors.crit.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.crit.withOpacity(0.4))),
                        child: Row(children: [
                          Icon(Icons.error_outline, color: sl.critText, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(_err,
                                  style: TextStyle(
                                      color: sl.critText, fontSize: 12))),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 18),
                    _primaryButton(sl),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// Login / Register as a segmented control with a sliding white pill.
  Widget _segmented(SL sl) => Container(
        height: 46,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _LoginGlass.well(sl),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _LoginGlass.wellEdge(sl)),
        ),
        child: Stack(children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: _isLogin ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: _LoginGlass.pill(sl),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(sl.isDark ? 0.30 : 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 3)),
                  ],
                ),
              ),
            ),
          ),
          Row(children: [
            _tab('Login', _isLogin,
                () => setState(() { _isLogin = true; _err = ''; })),
            _tab('Register', !_isLogin,
                () => setState(() { _isLogin = false; _err = ''; })),
          ]),
        ]),
      );

  Widget _primaryButton(SL sl) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        decoration: BoxDecoration(
          // Indigo → deep teal: the header's gradient, so the action reads as
          // the brand. White label stays above 4.5:1 across the whole band.
          gradient: LinearGradient(
            colors: _loading
                ? [sl.card2, sl.card2]
                : const [Color(0xFF4F5BD5), Color(0xFF0E7C8A)],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: _loading
              ? []
              : [
                  BoxShadow(
                      color: const Color(0xFF4F5BD5).withOpacity(0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 8)),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _loading ? null : (_isLogin ? _login : _register),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_isLogin ? 'Sign in' : 'Create account',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2)),
            ),
          ),
        ),
      );

  /// Small glass tile for the two secondary entry points.
  Widget _secondaryTile(SL sl,
          {required IconData icon,
          required Color iconColor,
          required String title,
          required String subtitle,
          required VoidCallback onTap}) =>
      Material(
        color: _LoginGlass.tile(sl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _LoginGlass.tileEdge(sl)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(sl.isDark ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: iconColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: sl.text1,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: sl.text3, fontSize: 11, height: 1.3)),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      );

  Future<void> _launchAppDownload() async {
    const url = 'https://github.com/abhibond1986/SL-22061984/releases/latest/download/app-release.apk';
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not open download link. Please visit GitHub releases manually.',
              style: TextStyle(fontSize: 12),
            ),
            backgroundColor: AppColors.crit,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Error: $e',
            style: const TextStyle(fontSize: 12),
          ),
          backgroundColor: AppColors.crit,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  List<Widget> _loginFields(SL sl) => [
    _field('Username', _userCtrl, sl, icon: Icons.person_outline_rounded,
      autofillHints: const [AutofillHints.username],
      textInputAction: TextInputAction.next),
    const SizedBox(height: 12),
    _field('Password', _passCtrl, sl, obscure: !_showLoginPass,
      icon: Icons.lock_outline_rounded,
      autofillHints: const [AutofillHints.password],
      textInputAction: TextInputAction.done,
      onToggleObscure: () => setState(() => _showLoginPass = !_showLoginPass),
      obscured: !_showLoginPass,
      onSubmitted: () { if (!_loading) _login(); }),
    const SizedBox(height: 8),
    Align(
      alignment: Alignment.centerRight,
      // TextButton, not a GestureDetector on 12px text pushed into the corner:
      // that gave a ~16px-tall target with no ripple. And sl.accentText, not
      // bare accent, which is 2.99:1 on the dark theme's surface.
      child: TextButton(
        onPressed: _showForgotPassword,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, SLSpace.tapTarget),
          padding: const EdgeInsets.symmetric(horizontal: SLSpace.md),
          shape: const RoundedRectangleBorder(borderRadius: SLRadius.rSm)),
        child: Text('Forgot password?',
            style: TextStyle(
              color: sl.accentText,
              fontSize: SLText.minLabel,
              fontWeight: FontWeight.w600)),
      ),
    ),
  ];

  /// Self-service password reset.
  ///
  /// Replaces a dialog that asked only for a username and then set the account
  /// to the hardcoded string `sail@123`, on the local device only. That meant:
  /// anyone could reset anyone's password by guessing their username; the "new"
  /// password was a value printed in the source code; and because it never
  /// reached Supabase, the user still could not log in on any other device —
  /// including the web app they were most likely using.
  ///
  /// Now: the user proves identity with a detail already on their record, picks
  /// their OWN password, and it is written to Supabase before we claim success.
  void _showForgotPassword() {
    final userCtrl = TextEditingController(text: _userCtrl.text.trim());
    final proofCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    // These four controllers are owned by the dialog, not by the State, so
    // they are not covered by dispose(). Released when the dialog closes —
    // otherwise every visit to "Forgot password" leaked four of them, along
    // with the text the user had typed into them.
    void release() {
      userCtrl.dispose();
      proofCtrl.dispose();
      passCtrl.dispose();
      confirmCtrl.dispose();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final sl = SL.of(ctx);
        var busy = false;
        var err = '';
        var reveal = false;

        InputDecoration deco(String hint, {Widget? suffix}) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: sl.text4, fontSize: 12),
          isDense: true,
          suffixIcon: suffix,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          filled: true,
          // Opaque, not sl.glassColor: this sits inside an AlertDialog, where a
          // translucent fill leaves the typed text competing with whatever is
          // behind the dialog.
          fillColor:
              sl.isDark ? const Color(0xFF252840) : const Color(0xFFF4F5FA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: sl.border)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: sl.border)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
        );

        return StatefulBuilder(builder: (ctx, setSt) {
          Future<void> submit() async {
            final username = userCtrl.text.trim();
            final proof = proofCtrl.text.trim();
            final pass = passCtrl.text;

            if (username.isEmpty) {
              setSt(() => err = 'Enter your username.'); return;
            }
            if (proof.isEmpty) {
              setSt(() => err =
                  'Enter your employee number, mobile, or email.'); return;
            }
            final passErr = Validators.validatePassword(pass);
            if (passErr != null) { setSt(() => err = passErr); return; }
            if (pass != confirmCtrl.text) {
              setSt(() => err = 'Passwords do not match.'); return;
            }

            setSt(() { busy = true; err = ''; });
            final res = await AuthService.resetPasswordWithProof(
              username: username, proof: proof, newPassword: pass);
            if (!ctx.mounted) return;

            if (!res.ok) {
              setSt(() { busy = false; err = res.message; });
              return;
            }
            Navigator.pop(ctx);
            if (!mounted) return;
            // Pre-fill the username so they can log straight in.
            setState(() {
              _userCtrl.text = username;
              _passCtrl.clear();
              _err = '';
            });
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text(
                'Password updated. You can now log in on any device.',
                style: TextStyle(fontSize: 12)),
              // green is a FILL for chips; as a snackbar behind white text it is
              // 2.54:1. greenLight is 5.48:1.
              backgroundColor: AppColors.greenLight,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ));
          }

          return AlertDialog(
            backgroundColor: sl.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Reset your password',
                style: TextStyle(
                    color: sl.text1, fontSize: 16,
                    fontWeight: FontWeight.w700)),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    'Confirm who you are, then choose a new password. '
                    'It will apply on every device.',
                    style:
                        TextStyle(color: sl.text3, fontSize: 12, height: 1.4)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: userCtrl,
                    enabled: !busy,
                    style: TextStyle(color: sl.text1, fontSize: 13),
                    decoration: deco('Username')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: proofCtrl,
                    enabled: !busy,
                    style: TextStyle(color: sl.text1, fontSize: 13),
                    decoration: deco('Employee No., mobile, or email')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    enabled: !busy,
                    obscureText: !reveal,
                    style: TextStyle(color: sl.text1, fontSize: 13),
                    decoration: deco('New password',
                      suffix: IconButton(
                        tooltip: reveal ? 'Hide password' : 'Show password',
                        icon: Icon(
                          reveal
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: sl.text3, size: 18),
                        onPressed: () => setSt(() => reveal = !reveal)))),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmCtrl,
                    enabled: !busy,
                    obscureText: !reveal,
                    onSubmitted: busy ? null : (_) => submit(),
                    style: TextStyle(color: sl.text1, fontSize: 13),
                    decoration: deco('Confirm new password')),
                  if (err.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.crit.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: AppColors.crit.withOpacity(0.4))),
                      child: Row(children: [
                        Icon(Icons.error_outline,
                            color: sl.critText, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(err,
                            style: TextStyle(
                                color: sl.critText, fontSize: 12,
                                height: 1.35))),
                      ])),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'No employee number on file? Ask your safety admin to '
                    'reset it from the Admin panel.',
                    style:
                        TextStyle(color: sl.text4, fontSize: 11, height: 1.35)),
                ]),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: sl.text3))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  disabledBackgroundColor: sl.card2,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8))),
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Update password',
                        style: TextStyle(color: Colors.white, fontSize: 13))),
            ],
          );
        });
      },
      // Runs whichever way the dialog closed — Cancel, a successful reset, or
      // the system back button. Safe here and nowhere else: after this future
      // completes the dialog's widgets are gone, so nothing can read the
      // controllers again.
    ).then((_) => release());
  }

  List<Widget> _registerFields(SL sl) => [
    _field('Full name', _regNameCtrl, sl, icon: Icons.person_outline_rounded, hint: 'e.g. Rajesh Kumar',
      autofillHints: const [AutofillHints.name]),
    const SizedBox(height: 12),
    _field('Username', _regUserCtrl, sl, icon: Icons.alternate_email_rounded, hint: 'Choose a username',
      autofillHints: const [AutofillHints.newUsername]),
    const SizedBox(height: 12),
    _field('Password', _regPassCtrl, sl, icon: Icons.lock_outline_rounded,
      obscure: !_showRegPass,
      hint: 'At least 6 characters',
      // newPassword, not password: this tells a password manager to OFFER to
      // generate and save one rather than to fill an existing credential.
      autofillHints: const [AutofillHints.newPassword],
      onToggleObscure: () => setState(() => _showRegPass = !_showRegPass),
      obscured: !_showRegPass),
    const SizedBox(height: 12),
    // Confirm field: registration is the one moment a typo is unrecoverable
    // without a reset, because the user never sees what they typed.
    _field('Confirm password', _regConfirmCtrl, sl, icon: Icons.lock_outline_rounded,
      obscure: !_showRegPass, hint: 'Re-enter your password',
      autofillHints: const [AutofillHints.newPassword]),
    const SizedBox(height: 12),
    _field('Designation', _regDesigCtrl, sl, icon: Icons.work_outline_rounded,
      hint: 'e.g. AGM Safety, Safety Officer',
      autofillHints: const [AutofillHints.jobTitle]),
    const SizedBox(height: 12),
    // P.No. / mobile are no longer cosmetic: they are what the self-service
    // password reset checks against, so the copy says so.
    _field('Employee No. (P.No.)', _regPnoCtrl, sl, icon: Icons.badge_outlined,
      hint: 'Used to verify you if you forget your password'),
    const SizedBox(height: 12),
    _field('Mobile', _regMobileCtrl, sl, icon: Icons.phone_iphone_rounded,
      hint: 'Optional — also usable for password recovery',
      autofillHints: const [AutofillHints.telephoneNumber],
      keyboardType: TextInputType.phone),
    const SizedBox(height: 12),

    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Plant / unit',
          style: TextStyle(
            color: sl.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: _LoginGlass.input(sl),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _LoginGlass.wellEdge(sl))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedPlant,
              isExpanded: true,
              dropdownColor: sl.card,
              borderRadius: BorderRadius.circular(12),
              // From the theme, not a bare TextStyle: DropdownButton.style
              // REPLACES the inherited style, so a bare one dropped the app
              // font (Inter) from the hint and the selected value.
              style: (Theme.of(context).textTheme.bodyMedium ??
                      const TextStyle())
                  .copyWith(color: sl.text1, fontSize: 13),
              hint: Text('Select your plant / unit',
                style: TextStyle(color: sl.text4, fontSize: 12)),
              icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: sl.text3),
              items: _sailPlants.map((p) => DropdownMenuItem(
                value: p,
                child: Text(p,
                  style: TextStyle(color: sl.text1, fontSize: 12),
                  overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (val) => setState(() {
                _selectedPlant = val;
                _isOtherPlant = val == 'Others';
                if (!_isOtherPlant) _regOtherPlantCtrl.clear();
              }),
            ),
          )),

        if (_isOtherPlant) ...[
          const SizedBox(height: 8),
          _field('Specify your plant / unit',
            _regOtherPlantCtrl, sl,
            hint: 'Enter plant or unit name'),
        ],
      ]),
  ];

  Widget _tab(String label, bool active, VoidCallback onTap) {
    final sl = SL.of(context);
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Center(
            // Plain Text, so it inherits the theme font (Inter).
            // AnimatedDefaultTextStyle would REPLACE the inherited style.
            child: Text(label,
                style: TextStyle(
                    color: active ? _LoginGlass.pillText(sl) : sl.text3,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13.5)),
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl, SL sl,
      {bool obscure = false, String? hint,
       VoidCallback? onSubmitted, TextInputAction? textInputAction,
       TextInputType? keyboardType,
       // Lets the browser's / Android's password manager fill this field.
       List<String>? autofillHints,
       VoidCallback? onToggleObscure, bool obscured = true,
       IconData? icon}) {
    final radius = BorderRadius.circular(12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sentence case, not tracked-out caps: easier to read at a glance.
        Text(label,
          style: TextStyle(
            color: sl.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          textInputAction: textInputAction,
          keyboardType: keyboardType,
          autofillHints: autofillHints,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
          style: TextStyle(color: sl.text1, fontSize: 14),
          cursorColor: sl.accentText,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: sl.text4, fontSize: 12.5),
            prefixIcon: icon == null
                ? null
                : Icon(icon, size: 19, color: sl.text3),
            suffixIcon: onToggleObscure == null ? null : IconButton(
              tooltip: obscured ? 'Show password' : 'Hide password',
              icon: Icon(
                obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: sl.text3, size: 19),
              onPressed: onToggleObscure,
            ),
            filled: true,
            fillColor: _LoginGlass.input(sl),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: _LoginGlass.wellEdge(sl))),
            enabledBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: _LoginGlass.wellEdge(sl))),
            focusedBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: sl.accentText, width: 1.6)))),
      ]);
  }
}

/// Colour tokens for the login glass. Kept here because nothing else in the
/// app sits on the lens backdrop.
///
/// Light: a pale indigo-to-mint field, white glass at ~62→42%, and the app's
/// normal dark text. Dark: deep indigo-to-petrol, white glass at ~10→5%, and
/// light text. Text contrast is measured against the glass over the PALEST and
/// DARKEST parts of the backdrop, which is why the fills are not more transparent.
class _LoginGlass {
  _LoginGlass._();

  static Color base(SL sl) =>
      sl.isDark ? const Color(0xFF0F1438) : const Color(0xFFEEF0FF);

  static List<Color> cardFill(SL sl) => sl.isDark
      ? [Colors.white.withOpacity(0.11), Colors.white.withOpacity(0.05)]
      : [Colors.white.withOpacity(0.66), Colors.white.withOpacity(0.44)];

  /// Sign-in card edge: a hairline of molten amber.
  static Color edge(SL sl) =>
      const Color(0xFFF59E0B).withOpacity(sl.isDark ? 0.62 : 0.70);

  /// Secondary tiles keep the neutral glass edge.
  static Color tileEdge(SL sl) => sl.isDark
      ? Colors.white.withOpacity(0.16)
      : Colors.white.withOpacity(0.85);

  // Tiles sit over the bright pour in the illustration on phones, so they are
  // a solid-ish glass rather than a 7% tint (text was lost in the glow).
  static Color tile(SL sl) => sl.isDark
      ? const Color(0xFF0B1240).withOpacity(0.78)
      : Colors.white.withOpacity(0.80);

  /// Recessed background of the segmented control and of the inputs' outline.
  static Color well(SL sl) => sl.isDark
      ? Colors.black.withOpacity(0.22)
      : const Color(0xFF4F5BD5).withOpacity(0.07);
  static Color wellEdge(SL sl) => sl.isDark
      ? Colors.white.withOpacity(0.12)
      : const Color(0xFF4F5BD5).withOpacity(0.16);

  static Color input(SL sl) => sl.isDark
      ? Colors.white.withOpacity(0.06)
      : Colors.white.withOpacity(0.78);

  static Color pill(SL sl) =>
      sl.isDark ? Colors.white.withOpacity(0.16) : Colors.white;
  static Color pillText(SL sl) =>
      sl.isDark ? Colors.white : const Color(0xFF3B47B8);
}
