import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/sync_service.dart';
import '../services/admin_master_data.dart';
import '../services/app_updater.dart';
import '../services/auth_token_service.dart';
import '../services/crypto_utils.dart';
import '../services/validators.dart';
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
  final _regDesigCtrl  = TextEditingController();
  final _regPnoCtrl    = TextEditingController();
  final _regOtherPlantCtrl = TextEditingController();

  String? _selectedPlant;
  bool _isOtherPlant = false;

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
    _regDesigCtrl.dispose(); _regPnoCtrl.dispose(); _regOtherPlantCtrl.dispose();
    super.dispose();
  }

  void _goHome() {
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
    final passwordErr = Validators.validatePassword(password);
    if (passwordErr != null) { setState(() => _err = passwordErr); return; }

    setState(() { _loading = true; _err = ''; });
    try {
      // 1. Try local DB first (fast, works offline)
      var user = await LocalDB.signIn(username, password);
      bool gotServerToken = false;

      // 2. If local login fails, try the remote backend (Google Sheets)
      //    This handles cross-device login (e.g. registered on web, login on mobile)
      if (user == null) {
        final passwordHash = _simpleHash(password);
        final remoteUser = await SyncService.loginOnline(username, passwordHash);
        if (remoteUser != null) {
          // Cache the user locally WITH password credentials for future offline logins
          remoteUser['username'] ??= username;
          remoteUser['status'] ??= 'active';
          // Store a proper CryptoUtils hash so LocalDB.signIn works offline
          final salt = CryptoUtils.generateSalt();
          remoteUser['salt'] = salt;
          remoteUser['passwordHash'] = CryptoUtils.hashPassword(password, salt);
          await LocalDB.upsertUser(remoteUser);
          // Set as current user (without credentials) so HomeScreen sees it
          user = Map<String, dynamic>.from(remoteUser)
            ..remove('passwordHash')..remove('password')..remove('salt');
          await LocalDB.setCurrentUser(user!);
          gotServerToken = true; // loginOnline already stored the server token
        }
      }

      if (!mounted) return;
      // Debug-only diagnostic; stripped from release builds.
      assert(() {
        print('LoginScreen._login: user=${user != null ? "found" : "null"}, gotServerToken=$gotServerToken');
        return true;
      }());
      if (user != null) {
        final Map<String, dynamic> confirmedUser = user;
        if (!gotServerToken) {
          // ✅ FIX: For local login, also obtain a server session token
          // so that API calls (addIncident, etc.) are authenticated.
          // Fire this in background — don't block login on network.
          final passwordHash = _simpleHash(password);
          // Meanwhile, store a local token as fallback
          final userId = confirmedUser['pno']?.toString() ?? confirmedUser['username']?.toString() ?? '';
          await AuthTokenService.generateToken(userId);
          // Try server login; if it fails, ensure user exists on server
          // so cross-device login works next time.
          SyncService.loginOnline(username, passwordHash).then((result) {
            if (result == null) {
              // Server doesn't know this user — push them
              final pushData = <String, dynamic>{
                'name': confirmedUser['name']?.toString() ?? '',
                'username': username,
                'designation': confirmedUser['designation']?.toString() ?? '',
                'plant': confirmedUser['plant']?.toString() ?? '',
                'pno': confirmedUser['pno']?.toString() ?? '',
                'passwordHash': passwordHash,
                'isAdmin': confirmedUser['isAdmin']?.toString() ?? 'false',
                'status': 'active',
              };
              SyncService.pushUser(pushData);
            }
          }).catchError((_) => null);
        }
        _goHome();
      } else {
        setState(() => _err = 'Invalid credentials');
      }
    } catch (e) {
      setState(() => _err = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Simple hash for online login — MUST match Apps Script's simpleHash exactly:
  /// ```js
  /// function simpleHash(str) {
  ///   var h = 0;
  ///   for (var i = 0; i < str.length; i++) {
  ///     h = ((h << 5) - h) + str.charCodeAt(i);
  ///     h = h & h;  // Convert to 32-bit signed integer
  ///   }
  ///   if (h < 0) return '-' + ((-h) >>> 0).toString(36);
  ///   return h.toString(36);
  /// }
  /// ```
  String _simpleHash(String str) {
    int h = 0;
    for (int i = 0; i < str.length; i++) {
      h = ((h << 5) - h) + str.codeUnitAt(i);
      // Emulate JavaScript's `h = h & h` (converts to 32-bit signed int)
      h = (h & 0xFFFFFFFF).toSigned(32);
    }
    if (h < 0) {
      // Emulate JS: (-h) >>> 0 converts to unsigned 32-bit
      final unsigned = (-h) & 0xFFFFFFFF;
      return '-${unsigned.toRadixString(36)}';
    }
    return h.toRadixString(36);
  }

  Future<void> _register() async {
    final name  = _regNameCtrl.text.trim();
    final user  = _regUserCtrl.text.trim();
    final pass  = _regPassCtrl.text;
    final desig = _regDesigCtrl.text.trim();
    final plant = _effectivePlant;

    // Validate all fields
    final nameErr = Validators.validateName(name);
    if (nameErr != null) { setState(() => _err = nameErr); return; }
    final userErr = Validators.validateUsername(user);
    if (userErr != null) { setState(() => _err = userErr); return; }
    final passErr = Validators.validatePassword(pass);
    if (passErr != null) { setState(() => _err = passErr); return; }
    if (desig.isEmpty) { setState(() => _err = 'Designation is required'); return; }
    if (plant.isEmpty) { setState(() => _err = 'Please select a plant'); return; }
    setState(() { _loading = true; _err = ''; });
    try {
      final userData = {
        'name': name, 'username': user, 'password': pass,
        'designation': desig, 'plant': plant,
        'pno': _regPnoCtrl.text.trim(),
        'isAdmin': 'false', 'status': 'active',
      };
      final ok = await LocalDB.register(userData);
      if (!mounted) return;
      if (ok != null) {
        // ✅ FIX: Register user on backend so other devices can login
        // Uses both register (for new users) and upsertUser (to update hash)
        final pushData = Map<String, dynamic>.from(userData);
        pushData.remove('password'); // Don't send plaintext password
        pushData['passwordHash'] = _simpleHash(pass); // Backend expects this
        // Try registration first (direct, public action); if it doesn't land,
        // push reliably (enqueues for retry) so the user reliably reaches the
        // backend — and therefore the admin panel on other devices.
        SyncService.registerOnline(pushData).then((registered) {
          if (!registered) SyncService.pushUserReliable(pushData);
        }).catchError((_) => SyncService.pushUserReliable(pushData));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${I18n.t('common.success')}! Welcome, $name'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2)));
        _goHome();
      } else {
        setState(() => _err = 'Username already taken');
      }
    } catch (e) {
      setState(() => _err = 'Registration failed: $e');
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
                      color: sl.text4,
                      fontSize: 10,
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
                                          color: Colors.white.withOpacity(0.85),
                                          fontSize: 10,
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
    _field('Password', _passCtrl, sl, obscure: true,
      textInputAction: TextInputAction.done,
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

  void _showForgotPassword() {
    final ctrl = TextEditingController();
    final sl = SL.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reset Password',
            style: TextStyle(color: sl.text1, fontSize: 16, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Enter your username to reset password.',
              style: TextStyle(color: sl.text3, fontSize: 12)),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            style: TextStyle(color: sl.text1, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Username',
              hintStyle: TextStyle(color: sl.text4),
              filled: true,
              fillColor: sl.glassColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: sl.glassBorder)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: sl.glassBorder)),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: sl.text3)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () async {
              final username = ctrl.text.trim();
              if (username.isEmpty) return;
              Navigator.pop(ctx);
              final success = await LocalDB.resetPassword(username);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(success
                    ? 'Password reset to sail@123. Please change after login.'
                    : 'Username not found. Contact your admin.',
                    style: const TextStyle(fontSize: 12)),
                backgroundColor: success ? AppColors.green : AppColors.crit,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ));
            },
            child: const Text('Reset', style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  List<Widget> _registerFields(SL sl) => [
    _field('Full Name', _regNameCtrl, sl, hint: 'e.g. Rajesh Kumar'),
    const SizedBox(height: 12),
    _field('Username', _regUserCtrl, sl, hint: 'Choose a username'),
    const SizedBox(height: 12),
    _field('Password', _regPassCtrl, sl, obscure: true),
    const SizedBox(height: 12),
    _field('Designation', _regDesigCtrl, sl,
      hint: 'e.g. AGM Safety, Safety Officer'),
    const SizedBox(height: 12),
    _field('Employee No. (P.No.)', _regPnoCtrl, sl, hint: 'Optional'),
    const SizedBox(height: 12),

    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PLANT / UNIT',
          style: TextStyle(
            color: sl.text4, fontSize: 9,
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
       VoidCallback? onSubmitted, TextInputAction? textInputAction}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
          style: TextStyle(
            color: sl.text4, fontSize: 9,
            fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
          style: TextStyle(color: sl.text1, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: sl.text4, fontSize: 11),
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
