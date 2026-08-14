import 'dart:ui';
import 'package:flutter/material.dart';
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
import '../widgets/glass_card.dart';
import 'home_screen.dart';
import 'contractor_home_screen.dart';

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
          backgroundColor: Colors.green,
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
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/app_icon.png',
                    width: 72, height: 72,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent),
                      child: const Icon(Icons.shield, color: Colors.white, size: 36)),
                  ),
                  const SizedBox(height: 14),
                  const BrandTitle(size: 22),
                  const SizedBox(height: 6),
                  Text(I18n.t('app.tagline'),
                    style: TextStyle(
                      color: sl.text4, fontSize: 12,
                      letterSpacing: 1.2)),
                  const SizedBox(height: 28),

                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    borderRadius: 20,
                    child: Column(
                      children: [
                        // Tab toggle
                        Container(
                          decoration: BoxDecoration(
                            color: sl.isDark
                                ? Colors.white.withOpacity(0.05)
                                : Colors.white.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Row(children: [
                            _tab('Login', _isLogin, () =>
                                setState(() { _isLogin = true; _err = ''; })),
                            _tab('Register', !_isLogin, () =>
                                setState(() { _isLogin = false; _err = ''; })),
                          ]),
                        ),
                        const SizedBox(height: 20),

                        if (_isLogin) ..._loginFields(sl)
                        else ..._registerFields(sl),

                        if (_err.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.crit.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.crit.withOpacity(0.4))),
                            child: Row(children: [
                              const Icon(Icons.error_outline,
                                color: AppColors.crit, size: 16),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_err,
                                style: const TextStyle(
                                  color: AppColors.crit, fontSize: 12))),
                            ])),
                        ],

                        const SizedBox(height: 20),

                        // Login/Register button
                        SizedBox(
                          width: double.infinity,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: _loading
                                ? [sl.card2, sl.card2]
                                : [AppColors.accent, AppColors.cyan]),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: _loading ? [] : [BoxShadow(
                                color: AppColors.accent.withOpacity(0.3),
                                blurRadius: 12, offset: const Offset(0, 4))]),
                            child: ElevatedButton(
                              onPressed: _loading
                                ? null
                                : (_isLogin ? _login : _register),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 15),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12))),
                              child: _loading
                                ? const SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                                : Text(
                                    _isLogin ? 'Login' : 'Create Account',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700))))),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: OutlinedButton.icon(
                          onPressed: _contractorAccess,
                          icon: const Icon(Icons.engineering_outlined, size: 18),
                          label: const Text('Contractor Access'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.cyan,
                            side: BorderSide(
                              color: AppColors.cyan.withOpacity(0.5),
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'No login required — AI Scan & Near Miss only',
                    style: TextStyle(
                      color: sl.text3,        // Improved contrast
                      fontSize: 11,           // Increased from 10
                      fontStyle: FontStyle.italic,
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Android App Download Button
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF22C55E), Color(0xFF16A34A)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF22C55E).withOpacity(0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _launchAppDownload,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.download_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'Download Android App',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                      Text(
                                        _downloadSubtitle,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.90),  // Better contrast
                                          fontSize: 11,                            // Increased from 10
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Version pill. Only shown once the real
                                  // version is known — a placeholder like
                                  // "v—" would look like a failure.
                                  if (_latestVersion.isNotEmpty) ...[
                                    const SizedBox(width: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.22),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        'v$_latestVersion',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(sl.isDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                        color: sl.text4, size: 16),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: widget.toggleTheme,
                        child: Text(
                          sl.isDark ? 'Switch to Light Mode'
                                    : 'Switch to Dark Mode',
                          style: TextStyle(
                            color: sl.text4, fontSize: 11,
                            decoration: TextDecoration.underline))),
                    ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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
    _field('Username', _userCtrl, sl,
      textInputAction: TextInputAction.next),
    const SizedBox(height: 12),
    _field('Password', _passCtrl, sl, obscure: !_showLoginPass,
      textInputAction: TextInputAction.done,
      onToggleObscure: () => setState(() => _showLoginPass = !_showLoginPass),
      obscured: !_showLoginPass,
      onSubmitted: () { if (!_loading) _login(); }),
    const SizedBox(height: 8),
    Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: _showForgotPassword,
        child: Text('Forgot Password?',
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 12,
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
              backgroundColor: AppColors.green,
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
                        const Icon(Icons.error_outline,
                            color: AppColors.crit, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(err,
                            style: const TextStyle(
                                color: AppColors.crit, fontSize: 12,
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
    _field('Full Name', _regNameCtrl, sl, hint: 'e.g. Rajesh Kumar'),
    const SizedBox(height: 12),
    _field('Username', _regUserCtrl, sl, hint: 'Choose a username'),
    const SizedBox(height: 12),
    _field('Password', _regPassCtrl, sl,
      obscure: !_showRegPass,
      hint: 'At least 6 characters',
      onToggleObscure: () => setState(() => _showRegPass = !_showRegPass),
      obscured: !_showRegPass),
    const SizedBox(height: 12),
    // Confirm field: registration is the one moment a typo is unrecoverable
    // without a reset, because the user never sees what they typed.
    _field('Confirm Password', _regConfirmCtrl, sl,
      obscure: !_showRegPass, hint: 'Re-enter your password'),
    const SizedBox(height: 12),
    _field('Designation', _regDesigCtrl, sl,
      hint: 'e.g. AGM Safety, Safety Officer'),
    const SizedBox(height: 12),
    // P.No. / mobile are no longer cosmetic: they are what the self-service
    // password reset checks against, so the copy says so.
    _field('Employee No. (P.No.)', _regPnoCtrl, sl,
      hint: 'Used to verify you if you forget your password'),
    const SizedBox(height: 12),
    _field('Mobile', _regMobileCtrl, sl,
      hint: 'Optional — also usable for password recovery',
      keyboardType: TextInputType.phone),
    const SizedBox(height: 12),

    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PLANT / UNIT',
          style: TextStyle(
            color: sl.text3, fontSize: 11,    // Improved: was text4/9px
            fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: sl.isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.white.withOpacity(0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sl.glassBorder)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedPlant,
              isExpanded: true,
              dropdownColor: sl.card,
              style: TextStyle(color: sl.text1, fontSize: 13),
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
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9)),
          child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: active ? Colors.white : sl.text3,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              fontSize: 13)))));
  }

  Widget _field(String label, TextEditingController ctrl, SL sl,
      {bool obscure = false, String? hint,
       VoidCallback? onSubmitted, TextInputAction? textInputAction,
       TextInputType? keyboardType,
       VoidCallback? onToggleObscure, bool obscured = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
          style: TextStyle(
            color: sl.text3, fontSize: 11,    // Improved: was text4/9px
            fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          textInputAction: textInputAction,
          keyboardType: keyboardType,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
          style: TextStyle(color: sl.text1, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: sl.text4, fontSize: 11),
            suffixIcon: onToggleObscure == null ? null : IconButton(
              tooltip: obscured ? 'Show password' : 'Hide password',
              icon: Icon(
                obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: sl.text3, size: 18),
              onPressed: onToggleObscure,
            ),
            filled: true,
            fillColor: sl.isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.white.withOpacity(0.5),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: sl.glassBorder)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: sl.glassBorder)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: AppColors.accent, width: 1.5)))),
      ]);
  }
}
