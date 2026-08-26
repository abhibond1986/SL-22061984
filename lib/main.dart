import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/local_db.dart';
import 'services/sync_service.dart';
import 'services/supabase_service.dart';
import 'services/admin_master_data.dart';
import 'services/app_updater.dart';
import 'services/image_storage.dart';
import 'services/background_sync.dart';
import 'services/realtime_sync.dart';
import 'services/gemini_vision.dart';
import 'services/ai_run_log.dart';
import 'services/visitor_service.dart';
import 'services/i18n.dart';  // ← ADDED: fixes "I18n not defined" error
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService().load();
  await LocalDB.init();
  // Supabase backend (no-op until configured + enabled in SupabaseConfig).
  await SupabaseService.init();
  await SyncService.init();
  await ImageStorage.init();
  // Migrate legacy base64 images to file storage (one-time, non-blocking)
  ImageStorage.migrateInlineImages().catchError((_) => 0);
  // ✅ FIX: Purge bloated imageBase64 from local storage to fix QuotaExceededError
  LocalDB.purgeStoredImages().catchError((_) => 0);
  SyncService.drainPendingQueue().catchError((_) => 0);
  // AI telemetry backlog. Runs recorded while the device was offline — or while
  // the `ai_runs` table did not exist yet — stay flagged unsynced locally, so
  // the admin dashboard (which reports on ALL devices via Supabase) would show
  // zero for scans that really happened. Draining here means the backlog
  // repairs itself on the next launch instead of being stranded forever.
  AiRunLog.flushUnsynced().catchError((_) => 0);
  // ★ Pull ALL shared incidents from the backend into local storage so every
  //   device shows the SAME data for a given user (desktop == mobile).
  //   Non-blocking: screens refresh when it completes / on pull-to-refresh.
  SyncService.fullSync().catchError((_) => <String, dynamic>{});
  // ★ v24: master data (plants, depts, WSA).
  //
  // This block used to `await` syncFromBackend() with a 10s timeout BEFORE
  // runApp, so on a slow or blocked network every launch stared at a blank
  // screen for up to ten seconds. Now it is cache-first: prime the snapshot from
  // local storage (fast, no network), then let the refresh land in the
  // background and re-prime via the revision listener.
  //
  // ORDER IS LOAD-BEARING. primeSnapshots() and the listener must both be in
  // place BEFORE the unawaited sync starts, otherwise a sync that completes
  // quickly would bump `revision` with no listener attached and the fresh data
  // would sit unread until the next change.
  //
  // Warms the synchronous master-data snapshot used by code paths that can't
  // await (LocalAI.processText, called inline by the near-miss form).
  await AdminMasterData.primeSnapshots();
  AdminMasterData.revision.addListener(() {
    AdminMasterData.primeSnapshots();
  });
  // Unawaited: screens refresh themselves when this lands.
  AdminMasterData.syncFromBackend()
      .timeout(const Duration(seconds: 10), onTimeout: () => false)
      .catchError((_) => false);
  // ★ v25: Pull latest Knowledge Base from backend (non-blocking)
  SyncService.syncKnowledgeBase().catchError((_) => false);
  // Any knowledge-base change must reach the AI hazard analyser immediately.
  // It caches the KB context it injects into the vision prompt, and that cache
  // used to live for the whole app session — so a document the admin uploaded
  // was ignored until the next cold start. Dropping the cache here means the
  // very next scan re-reads the knowledge base.
  LocalDB.kbRevision.addListener(GeminiVision.invalidateKbContext);
  // Silent auto-update: checks GitHub releases and installs APK in background
  AppUpdater.init();
  // ★ v25: Periodic background sync — retries pending items every 5 minutes
  BackgroundSync.start();
  // ★ Live cross-device sync: push incident/AI-hazard/near-miss add-edit-delete
  //   to every connected user in real time (no-op unless Supabase is enabled).
  RealtimeSync.start().catchError((_) {});
  // Unique-visitor counter for the admin dashboard. Fire-and-forget: it must
  // never delay first paint, and it no-ops when Supabase isn't configured.
  // Counts anonymous visitors too; the employee ID is attached here if a session
  // already exists, and again by login_screen for a fresh sign-in.
  VisitorService.recordVisit().catchError((_) {});
  runApp(const SafetyLensApp());
}

// ─── DESIGN TOKENS ────────────────────────────────────────────────────────────
class AppColors {
  static const bg     = darkBg;
  static const bg2    = darkBg2;
  static const card   = darkCard;
  static const card2  = darkCard2;
  static const card3  = darkCard3;
  static const border = darkBorder;
  static const text1  = Color(0xFFF1F5F9);
  static const text2  = Color(0xFFCBD5E1);
  static const text3  = Color(0xFF94A3B8);
  static const text4  = Color(0xFF64748B);

  // Industrial accent palette — steel-blue indigo primary, safety-amber signature.
  // Values align with the Tailwind-family colours already used across screens
  // so the whole app now reads as one cohesive enterprise system.
  static const accent     = Color(0xFF4F5BD5);   // steel indigo — primary
  static const accentDark = Color(0xFF3B45B0);   // deeper indigo (pressed)
  static const accentGlow = Color(0xFF6675E8);   // lifted indigo (glow/hover)
  static const cyan       = Color(0xFF0EA5B5);   // industrial teal-cyan
  static const purple     = Color(0xFF7C6CF0);   // muted violet (secondary)
  static const pink       = Color(0xFFE0568A);   // desaturated rose (rare accent)

  // Safety status palette — matches signage conventions used on the plant floor.
  static const crit  = Color(0xFFDC2626);   // red-600 — critical
  static const red   = Color(0xFFEF4444);   // red-500 — high
  static const amber = Color(0xFFF59E0B);   // amber-500 — medium (SAIL signature)
  static const green = Color(0xFF10B981);   // emerald-500 — safe / closed

  // Light mode variants with better contrast (WCAG AA compliant)
  static const critLight  = Color(0xFFC22626);   // 5.83:1 on white
  static const amberLight = Color(0xFFB45309);   // 5.02:1 on white
  static const greenLight = Color(0xFF047857);   // 5.48:1 on white
  static const cyanInk    = Color(0xFF0E7490);   // cyan-700 — cyan is 2.97:1 on
                                                 // white, unusable as text there

  // ── Foreground variants for DARK surfaces ────────────────────────────────
  // Needed because no single hex can serve both themes as TEXT. Measured on
  // darkCard (#171F2C) with tools/audit_contrast.py:
  //   crit 3.43:1 and red 4.40:1 both miss AA on dark, so text needs these.
  //   amber (7.71:1), green (6.52:1) and cyan (5.57:1) already pass on dark
  //   and are reused as-is by the SL getters below.
  static const redBeacon    = Color(0xFFF87171);  // 5.98:1 on darkCard
  static const accentBeacon = Color(0xFF818CF8);  // 5.55:1 on darkCard
                                                  // (accent itself is 2.99:1)

  // Dark mode — graphite steel base (not purple). Cool, industrial, high-legibility.
  static const darkBg     = Color(0xFF0D1117);   // graphite black
  static const darkBg2    = Color(0xFF141B26);   // raised panel
  static const darkCard   = Color(0xFF171F2C);   // glass card base
  static const darkCard2  = Color(0xFF1F2937);   // elevated surface
  static const darkCard3  = Color(0xFF283449);   // top-most surface
  static const darkBorder = Color(0xFF2C3646);   // subtle steel separator

  // Light mode — cool neutral white with a faint steel tint
  static const lightBg     = Color(0xFFF5F7FA);  // steel-tinted near-white
  static const lightBg2    = Color(0xFFEAEEF3);  // very light cool grey
  static const lightCard   = Color(0xFFFFFFFF);  // pure white cards
  static const lightCard2  = Color(0xFFF1F4F8);  // input field bg
  static const lightBorder = Color(0xFFDCE1E9);  // clear cool-grey border
}

// ─── THEME HELPER ─────────────────────────────────────────────────────────────
class SL {
  final bool isDark;
  const SL(this.isDark);

  static SL of(BuildContext context) =>
      SL(Theme.of(context).brightness == Brightness.dark);

  Color get bg     => isDark ? AppColors.darkBg    : AppColors.lightBg;
  Color get bg2    => isDark ? AppColors.darkBg2   : AppColors.lightBg2;
  Color get card   => isDark ? AppColors.darkCard   : AppColors.lightCard;
  Color get card2  => isDark ? AppColors.darkCard2  : AppColors.lightCard2;
  Color get card3  => isDark ? AppColors.darkCard3  : const Color(0xFFECEBFF);
  Color get border => isDark ? AppColors.darkBorder : AppColors.lightBorder;
  Color get text1  => isDark ? const Color(0xFFF1F5F9) : const Color(0xFF111111);
  Color get text2  => isDark ? const Color(0xFFCBD5E1) : const Color(0xFF333333);
  Color get text3  => isDark ? const Color(0xFFA8B3C7) : const Color(0xFF444444);  // Improved contrast: 7.2:1 dark, 8.5:1 light
  Color get text4  => isDark ? const Color(0xFF7A8BA3) : const Color(0xFF666666);  // Improved contrast: 5.1:1 dark, 5.8:1 light
  Color get surface => isDark ? AppColors.darkCard  : Colors.white;

  // ── Status / accent colours FOR TEXT AND ICONS ───────────────────────────
  // Use these — never a bare `AppColors.amber`/`red`/`green`/`accent` — whenever
  // a status colour is the FOREGROUND.
  //
  // Why: those bare tokens were tuned as FILLS (chip backgrounds) and reused as
  // text, where amber lands at 2.15:1 on white and green at 2.54:1 — well below
  // the 4.5:1 AA floor and genuinely unreadable. The values cannot simply be
  // "fixed" in place either: a hex dark enough for white text-on-light is too
  // dark on the graphite dark background and vice versa, which is why this is a
  // theme-aware getter rather than a new constant.
  //
  // Bare AppColors status tokens are left deliberately failing so that
  // tools/audit_contrast.py keeps flagging any reintroduction as foreground.
  Color get critText   => isDark ? AppColors.redBeacon    : AppColors.critLight;
  Color get redText    => isDark ? AppColors.redBeacon    : AppColors.critLight;
  Color get amberText  => isDark ? AppColors.amber        : AppColors.amberLight;
  Color get greenText  => isDark ? AppColors.green        : AppColors.greenLight;
  Color get accentText => isDark ? AppColors.accentBeacon : AppColors.accent;
  Color get cyanText   => isDark ? AppColors.cyan         : AppColors.cyanInk;

  /// Foreground for an arbitrary severity/status colour, mapped to the nearest
  /// safe token for the current theme. Use at call sites that receive a colour
  /// as a parameter and cannot know which status it represents.
  Color textOn(Color fill) {
    if (fill == AppColors.crit || fill == AppColors.red ||
        fill == AppColors.critLight) return critText;
    if (fill == AppColors.amber || fill == AppColors.amberLight) return amberText;
    if (fill == AppColors.green || fill == AppColors.greenLight) return greenText;
    if (fill == AppColors.cyan) return cyanText;
    if (fill == AppColors.accent || fill == AppColors.accentDark ||
        fill == AppColors.accentGlow) return accentText;
    return fill;
  }

  // Glassmorphism properties - improved opacity for better contrast
  Color get glassColor => isDark
      ? Colors.white.withOpacity(0.08)      // Increased from 0.06
      : Colors.white.withOpacity(0.45);     // Decreased from 0.55 for better text visibility
  Color get glassBorder => isDark
      ? Colors.white.withOpacity(0.18)      // Increased from 0.12 for better definition
      : Colors.white.withOpacity(0.70);     // Increased from 0.6 for better visibility
  LinearGradient get meshGradient => isDark
      ? const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF1A2436), Color(0xFF12181F)])
      : const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFFF5F7FA), Color(0xFFEAEEF3), Color(0xFFEEF1F6)]);

  List<Color> get bgGradient => isDark
      ? [const Color(0xFF0D1117), const Color(0xFF1A2436), const Color(0xFF12181F)]
      : [const Color(0xFFF5F7FA), const Color(0xFFEAEEF3), const Color(0xFFEEF1F6)];

  Gradient get cardGradient => isDark
      ? LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.08), Colors.white.withOpacity(0.03)])
      : LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.7), Colors.white.withOpacity(0.4)]);

  BoxShadow get cardShadow => BoxShadow(
      color: isDark
          ? Colors.black.withOpacity(0.4)
          : AppColors.accent.withOpacity(0.08),
      blurRadius: 20,
      offset: const Offset(0, 4));

  BoxShadow get glowShadow => BoxShadow(
      color: AppColors.accent.withOpacity(isDark ? 0.2 : 0.12),
      blurRadius: 24,
      spreadRadius: 0);
}

// ─── TEXT STYLE HELPERS (WCAG AA Compliant Minimum Sizes) ────────────────────
/// Standardized text styles with enforced minimum font sizes for accessibility.
/// All sizes meet WCAG 2.1 Level AA requirements when paired with proper contrast colors.
class SLText {
  // Minimum font sizes (WCAG AA compliant) - Industrial context (45+ age workers, outdoor visibility)
  static const double minLabel = 12.0;    // Form labels, section headers (increased for older workers)
  static const double minBody = 13.0;     // Body text, descriptions (increased for readability)
  static const double minHint = 11.0;     // Placeholder text, hints
  static const double minBadge = 11.0;    // Compact badges (increased from 10.0 for outdoor visibility)
  static const double minButton = 13.0;   // Button labels

  /// Form field label (uppercase)
  static TextStyle label(SL sl) => TextStyle(
    fontSize: minLabel,
    color: sl.text3,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );

  /// Body text
  static TextStyle body(SL sl) => TextStyle(
    fontSize: minBody,
    color: sl.text2,
    height: 1.5,
  );

  /// Secondary body text
  static TextStyle bodySmall(SL sl) => TextStyle(
    fontSize: minBody,
    color: sl.text3,
    height: 1.4,
  );

  /// Hint/placeholder text
  static TextStyle hint(SL sl) => TextStyle(
    fontSize: minHint,
    color: sl.text3,
  );

  /// Compact badge (must be bold for visibility)
  static TextStyle badge(SL sl, Color color) => TextStyle(
    fontSize: minBadge,
    color: color,
    fontWeight: FontWeight.w900,
    letterSpacing: 0.3,
  );

  /// Button text
  static TextStyle button(SL sl) => TextStyle(
    fontSize: minButton,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
  );
}

// ─── APP ──────────────────────────────────────────────────────────────────────
class SafetyLensApp extends StatefulWidget {
  const SafetyLensApp({super.key});
  @override
  State<SafetyLensApp> createState() => _SafetyLensAppState();
}

class _SafetyLensAppState extends State<SafetyLensApp> with WidgetsBindingObserver {
  // ✅ FIX: Default to LIGHT mode instead of dark
  ThemeMode _mode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    I18n.instance.addListener(_onLocaleChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    I18n.instance.removeListener(_onLocaleChanged);
    AppUpdater.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Check for updates every time app comes to foreground
      AppUpdater.onAppResumed();
    }
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  void toggleTheme() =>
      setState(() => _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);

  ThemeData _buildTheme(bool dark) {
    final base = dark ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
      colorScheme: (dark
              ? const ColorScheme.dark(
                  primary: AppColors.accent, surface: AppColors.darkCard)
              : const ColorScheme.light(
                  primary: AppColors.accent, surface: Colors.white))
          .copyWith(secondary: AppColors.cyan),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: dark ? const Color(0xFFCBD5E1) : const Color(0xFF3A3A6A),
        displayColor: dark ? const Color(0xFFF1F5F9) : const Color(0xFF1A1A3E),
      ),
      cardColor: dark ? AppColors.darkCard : Colors.white,
      dividerColor: dark ? AppColors.darkBorder : AppColors.lightBorder,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? AppColors.darkBg2 : AppColors.lightBg2,
        elevation: 0,
        titleTextStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: dark ? const Color(0xFFF1F5F9) : const Color(0xFF1A1A3E)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: dark ? AppColors.darkBg2 : AppColors.lightBg,
        selectedItemColor: AppColors.accent,
        unselectedItemColor:
            dark ? const Color(0xFF64748B) : const Color(0xFF7070A0),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? AppColors.darkCard2 : const Color(0xFFF5F4FF),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: dark ? AppColors.darkBorder : AppColors.lightBorder)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: dark ? AppColors.darkBorder : AppColors.lightBorder)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: dark ? const Color(0xFF6B7CF5) : const Color(0xFF3B45B0),  // Better contrast: 3.5:1 dark, 4.2:1 light
                width: 2.5)),  // Slightly thicker for visibility
        labelStyle: TextStyle(
            color: dark ? const Color(0xFF94A3B8) : const Color(0xFF555555)),
        hintStyle: TextStyle(
            color: dark ? const Color(0xFF64748B) : const Color(0xFF7070A0)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
        textStyle:
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      )),
      snackBarTheme: SnackBarThemeData(
          backgroundColor: dark ? AppColors.darkCard2 : Colors.white,
          contentTextStyle: TextStyle(
              color: dark
                  ? const Color(0xFFF1F5F9)
                  : const Color(0xFF1A1A3E))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LocaleService(),
      builder: (context, _) {
        return MaterialApp(
          title: 'SAIL Safety Lens',
          debugShowCheckedModeBanner: false,
          locale: LocaleService().locale,
          supportedLocales: LocaleService.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: _mode,
          theme: _buildTheme(false),
          darkTheme: _buildTheme(true),
          // ✅ On web, skip Flutter splash — HTML splash (index.html) already
          // shows branding while Flutter loads. Going straight to login/home
          // avoids the double-splash (blue logo → badge logo → app).
          home: kIsWeb
              ? _WebEntry(toggleTheme: toggleTheme)
              : SplashScreen(toggleTheme: toggleTheme),
        );
      },
    );
  }
}

// ─── WEB ENTRY (skips splash on web) ──────────────────────────────────────────
class _WebEntry extends StatefulWidget {
  final VoidCallback toggleTheme;
  const _WebEntry({required this.toggleTheme});
  @override
  State<_WebEntry> createState() => _WebEntryState();
}

class _WebEntryState extends State<_WebEntry> {
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _resolveDestination();
  }

  Future<void> _resolveDestination() async {
    final user = await LocalDB.getCurrentUser();
    if (!mounted) return;
    setState(() {
      _destination = user != null
          ? HomeScreen(toggleTheme: widget.toggleTheme)
          : LoginScreen(toggleTheme: widget.toggleTheme);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Show a minimal container (same bg as HTML splash) until DB check finishes
    if (_destination == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0E1A),
        body: SizedBox.shrink(),
      );
    }
    return _destination!;
  }
}

// ─── SHARED WIDGETS ───────────────────────────────────────────────────────────
class BrandTitle extends StatelessWidget {
  final double size;
  const BrandTitle({super.key, this.size = 19});
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('SAIL ',
              style: GoogleFonts.poppins(
                  fontSize: size,
                  fontWeight: FontWeight.w900,
                  color: sl.isDark ? Colors.white : const Color(0xFF1A1A3E))),
          ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                      colors: [AppColors.accent, AppColors.cyan])
                  .createShader(b),
              child: Text('Safety',
                  style: GoogleFonts.poppins(
                      fontSize: size,
                      fontWeight: FontWeight.w800,
                      color: Colors.white))),
          ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                      colors: [AppColors.pink, AppColors.amber])
                  .createShader(b),
              child: Text(' Lens',
                  style: GoogleFonts.poppins(
                      fontSize: size,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontStyle: FontStyle.italic))),
        ]),
      ],
    );
  }
}

class BrandTagline extends StatelessWidget {
  const BrandTagline({super.key});
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Safety Starts with Me',
          style: TextStyle(
              color: sl.text3,
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5)),
      Text(' · powered by ', style: TextStyle(color: sl.text4, fontSize: 9)),
      ShaderMask(
          shaderCallback: (b) => const LinearGradient(
                  colors: [AppColors.accent, AppColors.cyan])
              .createShader(b),
          child: const Text('AI',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800))),
    ]);
  }
}

class SailLogoTile extends StatelessWidget {
  final double size;
  const SailLogoTile({super.key, this.size = 40});
  @override
  Widget build(BuildContext context) => SizedBox(
      width: size,
      height: size,
      child: Image.asset('assets/images/app_icon.png', fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent),
          child: Icon(Icons.shield, color: Colors.white, size: size * 0.5))));
}


// ─── SEVERITY BADGE ───────────────────────────────────────────────────────────
class SeverityBadge extends StatelessWidget {
  final String severity;
  final bool small;
  const SeverityBadge(this.severity, {super.key, this.small = false});
  static Color color(String s) {
    switch (s.toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.amber;
      default:         return AppColors.green;
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = color(severity);
    final label = severity.toUpperCase();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 6 : 10, vertical: small ? 2 : 4),
      decoration: BoxDecoration(
          color: c.withOpacity(0.15),
          border: Border.all(color: c.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(20)),
      child: Text(
          small && label.length > 4 ? label.substring(0, 4) : label,
          style: TextStyle(
              color: SL.of(context).textOn(c),
              fontSize: small ? 8 : 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
    );
  }
}

// ─── GRADIENT BUTTON ──────────────────────────────────────────────────────────
class GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final List<Color> colors;
  final bool loading;
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.colors = const [AppColors.accent, AppColors.cyan],
    this.loading = false,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
            gradient: onTap == null
                ? null
                : LinearGradient(colors: colors),
            color: onTap == null
                ? (SL.of(context).isDark
                    ? AppColors.darkCard2
                    : AppColors.lightBorder)
                : null,
            borderRadius: BorderRadius.circular(14),
            boxShadow: onTap == null
                ? []
                : [
                    BoxShadow(
                        color: colors.first.withOpacity(0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 6))
                  ]),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (loading)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
          else if (icon != null) ...[
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 8),
          ],
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3)),
        ]),
      ),
    );
  }
}

// ─── NEON DIVIDER ─────────────────────────────────────────────────────────────
class NeonDivider extends StatelessWidget {
  final Color color;
  const NeonDivider({super.key, this.color = AppColors.accent});
  @override
  Widget build(BuildContext context) => Container(
      height: 1,
      decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
        Colors.transparent,
        color.withOpacity(0.6),
        Colors.transparent
      ])));
}

// ─── LOCALE SERVICE ─────────────────────────────────────────────────────────
class LocaleService extends ChangeNotifier {
  static const String _key = 'selected_locale';
  Locale _locale = const Locale('en');
  Locale get locale => _locale;

  static final LocaleService _instance = LocaleService._internal();
  factory LocaleService() => _instance;
  LocaleService._internal();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_key) ?? 'en';
    _locale = Locale(code);
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    if (_locale == locale) return;
    _locale = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, locale.languageCode);
    notifyListeners();
  }

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('hi'),
  ];

  static const List<Map<String, String>> languages = [
    {'code': 'en', 'name': 'English', 'native': 'English', 'flag': '🇬🇧'},
    {'code': 'hi', 'name': 'Hindi',   'native': 'हिंदी',    'flag': '🇮🇳'},
  ];
}

// ─── APP LOCALIZATIONS ──────────────────────────────────────────────────────
//
// Hand-written localizations — NO code generation required.
// No flutter_gen, no build_runner.
class AppLocalizations {
  final Locale locale;
  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)
        ?? AppLocalizations(const Locale('en'));
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  // ── All strings ────────────────────────────────────────────────────────
  String get appName          => _t('appName');
  String get selectLanguage   => _t('selectLanguage');
  String get languageSaved    => _t('languageSaved');
  // Auth
  String get login            => _t('login');
  String get register         => _t('register');
  String get logout           => _t('logout');
  String get username         => _t('username');
  String get password         => _t('password');
  String get name             => _t('name');
  String get designation      => _t('designation');
  String get plant            => _t('plant');
  String get employeeNo       => _t('employeeNo');
  String get loginBtn         => _t('loginBtn');
  String get registerBtn      => _t('registerBtn');
  String get loginFailed      => _t('loginFailed');
  String get fillAllFields    => _t('fillAllFields');
  // Dashboard
  String get dashboard        => _t('dashboard');
  String get safetyScore      => _t('safetyScore');
  String get totalIncidents   => _t('totalIncidents');
  String get openIncidents    => _t('openIncidents');
  String get criticalIncidents => _t('criticalIncidents');
  String get aiScans          => _t('aiScans');
  String get quickActions     => _t('quickActions');
  String get reportNearMiss   => _t('reportNearMiss');
  String get startAiScan      => _t('startAiScan');
  String get viewReports      => _t('viewReports');
  String get askAi            => _t('askAi');
  String get plantSummary     => _t('plantSummary');
  String get recentActivity   => _t('recentActivity');
  String get noRecentActivity => _t('noRecentActivity');
  String get good             => _t('good');
  String get needsAttention   => _t('needsAttention');
  String get critical         => _t('critical');
  // Near Miss
  String get nearMissTitle        => _t('nearMissTitle');
  String get nearMissSubtitle     => _t('nearMissSubtitle');
  String get incidentDate         => _t('incidentDate');
  String get incidentTime         => _t('incidentTime');
  String get location             => _t('location');
  String get department           => _t('department');
  String get incidentDescription  => _t('incidentDescription');
  String get incidentDescHint     => _t('incidentDescHint');
  String get immediateAction      => _t('immediateAction');
  String get immediateActionHint  => _t('immediateActionHint');
  String get injuryOccurred       => _t('injuryOccurred');
  String get yes                  => _t('yes');
  String get no                   => _t('no');
  String get injuryDetails        => _t('injuryDetails');
  String get injuryDetailsHint    => _t('injuryDetailsHint');
  String get witnesses            => _t('witnesses');
  String get witnessesHint        => _t('witnessesHint');
  String get submitReport         => _t('submitReport');
  String get reportSubmitted      => _t('reportSubmitted');
  String get reportFailed         => _t('reportFailed');
  String get voiceInput           => _t('voiceInput');
  String get listening            => _t('listening');
  String get tapToSpeak           => _t('tapToSpeak');
  String get severityLevel        => _t('severityLevel');
  String get selectSeverity       => _t('selectSeverity');
  String get wsaCause             => _t('wsaCause');
  String get selectWsa            => _t('selectWsa');
  String get attachPhoto          => _t('attachPhoto');
  String get photoAttached        => _t('photoAttached');
  String get rootCause            => _t('rootCause');
  String get rootCauseHint        => _t('rootCauseHint');
  String get correctiveAction     => _t('correctiveAction');
  String get correctiveActionHint => _t('correctiveActionHint');
  // AI Scan
  String get aiScanTitle       => _t('aiScanTitle');
  String get aiScanSubtitle    => _t('aiScanSubtitle');
  String get takePhoto         => _t('takePhoto');
  String get uploadPhoto       => _t('uploadPhoto');
  String get analysing         => _t('analysing');
  String get analysisComplete  => _t('analysisComplete');
  String get hazardsFound      => _t('hazardsFound');
  String get noHazardsFound    => _t('noHazardsFound');
  String get riskScore         => _t('riskScore');
  String get confidence        => _t('confidence');
  String get hazardType        => _t('hazardType');
  String get summary           => _t('summary');
  String get hazards           => _t('hazards');
  String get correctiveActions => _t('correctiveActions');
  String get preventiveActions => _t('preventiveActions');
  String get regulations       => _t('regulations');
  String get exportPdf         => _t('exportPdf');
  String get shareReport       => _t('shareReport');
  String get scanAnother       => _t('scanAnother');
  // Reports
  String get reportsTitle   => _t('reportsTitle');
  String get filterAll      => _t('filterAll');
  String get filterCritical => _t('filterCritical');
  String get filterHigh     => _t('filterHigh');
  String get filterMedium   => _t('filterMedium');
  String get filterLow      => _t('filterLow');
  String get filterOpen     => _t('filterOpen');
  String get filterClosed   => _t('filterClosed');
  String get noReports      => _t('noReports');
  String get reportDate     => _t('reportDate');
  String get reportSeverity => _t('reportSeverity');
  String get reportStatus   => _t('reportStatus');
  String get reportType     => _t('reportType');
  String get viewDetail     => _t('viewDetail');
  String get markClosed     => _t('markClosed');
  String get deleteReport   => _t('deleteReport');
  String get confirmDelete  => _t('confirmDelete');
  String get deleteWarning  => _t('deleteWarning');
  String get cancel         => _t('cancel');
  String get confirm        => _t('confirm');
  // Chat
  String get chatTitle    => _t('chatTitle');
  String get chatHint     => _t('chatHint');
  String get chatSend     => _t('chatSend');
  String get chatWelcome  => _t('chatWelcome');
  String get chatOffline  => _t('chatOffline');
  String get chatThinking => _t('chatThinking');
  String get chatNoAnswer => _t('chatNoAnswer');
  // Settings
  String get settingsTitle       => _t('settingsTitle');
  String get settingsBackend     => _t('settingsBackend');
  String get settingsSyncNow     => _t('settingsSyncNow');
  String get settingsTheme       => _t('settingsTheme');
  String get settingsLanguage    => _t('settingsLanguage');
  String get settingsDark        => _t('settingsDark');
  String get settingsLight       => _t('settingsLight');
  String get settingsVersion     => _t('settingsVersion');
  String get settingsSyncSuccess => _t('settingsSyncSuccess');
  String get settingsSyncFail    => _t('settingsSyncFail');
  // Admin
  String get adminTitle        => _t('adminTitle');
  String get adminKnowledge    => _t('adminKnowledge');
  String get adminUsers        => _t('adminUsers');
  String get adminAnalytics    => _t('adminAnalytics');
  String get adminAddText      => _t('adminAddText');
  String get adminSyncCloud    => _t('adminSyncCloud');
  String get adminEbook        => _t('adminEbook');
  String get adminEbookSubtitle => _t('adminEbookSubtitle');
  String get adminSelectPdf    => _t('adminSelectPdf');
  String get adminGenerateKb   => _t('adminGenerateKb');
  String get adminKbGenerated  => _t('adminKbGenerated');
  String get adminCopyCode     => _t('adminCopyCode');
  String get adminCopied       => _t('adminCopied');
  String get adminProcessing   => _t('adminProcessing');
  String get adminNoDocuments  => _t('adminNoDocuments');
  String get adminNoUsers      => _t('adminNoUsers');
  // Severity / Status
  String get severityCritical  => _t('severity_critical');
  String get severityHigh      => _t('severity_high');
  String get severityMedium    => _t('severity_medium');
  String get severityLow       => _t('severity_low');
  String get statusOpen        => _t('status_open');
  String get statusClosed      => _t('status_closed');
  String get statusInProgress  => _t('status_inprogress');
  // Common
  String get loading  => _t('loading');
  String get retry    => _t('retry');
  String get save     => _t('save');
  String get update   => _t('update');
  String get delete   => _t('delete');
  String get edit     => _t('edit');
  String get close    => _t('close');
  String get back     => _t('back');
  String get next     => _t('next');
  String get submit   => _t('submit');
  String get reset    => _t('reset');
  String get search   => _t('search');
  String get noData   => _t('noData');
  String get error    => _t('error');
  String get success  => _t('success');
  String get warning  => _t('warning');
  String get info     => _t('info');

  // ── Translation lookup ─────────────────────────────────────────────────
  String _t(String key) {
    final lang = locale.languageCode;
    if (lang == 'hi') return _hi[key] ?? _en[key] ?? key;
    return _en[key] ?? key;
  }

  // ── English ───────────────────────────────────────────────────────────
  static const Map<String, String> _en = {
    'appName': 'SAIL Safety Lens',
    'selectLanguage': 'Select Language', 'languageSaved': 'Language updated',
    'login': 'Login', 'register': 'Register', 'logout': 'Logout',
    'username': 'Username', 'password': 'Password', 'name': 'Name',
    'designation': 'Designation', 'plant': 'Plant / Unit', 'employeeNo': 'Employee No.',
    'loginBtn': 'Login', 'registerBtn': 'Create Account',
    'loginFailed': 'Invalid credentials', 'fillAllFields': 'Please fill all fields',
    'dashboard': 'Dashboard', 'safetyScore': 'Safety Score',
    'totalIncidents': 'Total Incidents', 'openIncidents': 'Open',
    'criticalIncidents': 'Critical', 'aiScans': 'AI Scans',
    'quickActions': 'Quick Actions', 'reportNearMiss': 'Report Near Miss',
    'startAiScan': 'Start AI Scan', 'viewReports': 'View Reports',
    'askAi': 'Ask AI', 'plantSummary': 'Plant Summary',
    'recentActivity': 'Recent Activity', 'noRecentActivity': 'No recent activity',
    'good': 'Good', 'needsAttention': 'Needs Attention', 'critical': 'Critical',
    'nearMissTitle': 'Near Miss Report',
    'nearMissSubtitle': 'Report unsafe conditions or near miss incidents',
    'incidentDate': 'Incident Date', 'incidentTime': 'Incident Time',
    'location': 'Location / Area', 'department': 'Department',
    'incidentDescription': 'Incident Description',
    'incidentDescHint': 'Describe what happened, what you saw, or what could have gone wrong...',
    'immediateAction': 'Immediate Action Taken',
    'immediateActionHint': 'What was done immediately after the incident?',
    'injuryOccurred': 'Did any injury occur?', 'yes': 'Yes', 'no': 'No',
    'injuryDetails': 'Injury Details',
    'injuryDetailsHint': 'Describe the nature and extent of injury...',
    'witnesses': 'Witnesses (if any)', 'witnessesHint': 'Names of witnesses present...',
    'submitReport': 'Submit Report', 'reportSubmitted': 'Report submitted successfully',
    'reportFailed': 'Failed to submit report. Try again.',
    'voiceInput': 'Tap mic to speak', 'listening': 'Listening...', 'tapToSpeak': 'Tap to speak',
    'severityLevel': 'Severity Level', 'selectSeverity': 'Select Severity',
    'wsaCause': 'WSA Cause Category', 'selectWsa': 'Select WSA Cause',
    'attachPhoto': 'Attach Photo', 'photoAttached': 'Photo attached',
    'rootCause': 'Root Cause', 'rootCauseHint': 'What was the underlying cause?',
    'correctiveAction': 'Corrective Action',
    'correctiveActionHint': 'What action is recommended to prevent recurrence?',
    'aiScanTitle': 'AI Hazard Scan',
    'aiScanSubtitle': 'Take or upload a photo for AI hazard analysis',
    'takePhoto': 'Take Photo', 'uploadPhoto': 'Upload from Gallery',
    'analysing': 'Analysing image...', 'analysisComplete': 'Analysis Complete',
    'hazardsFound': 'Hazard(s) Found', 'noHazardsFound': 'No hazards detected',
    'riskScore': 'Risk Score', 'confidence': 'Confidence', 'hazardType': 'Hazard Type',
    'summary': 'Summary', 'hazards': 'Hazards',
    'correctiveActions': 'Corrective Actions', 'preventiveActions': 'Preventive Actions',
    'regulations': 'Applicable Regulations', 'exportPdf': 'Export PDF Report',
    'shareReport': 'Share Report', 'scanAnother': 'Scan Another',
    'reportsTitle': 'Incident Reports', 'filterAll': 'All',
    'filterCritical': 'Critical', 'filterHigh': 'High',
    'filterMedium': 'Medium', 'filterLow': 'Low',
    'filterOpen': 'Open', 'filterClosed': 'Closed',
    'noReports': 'No reports found', 'reportDate': 'Date',
    'reportSeverity': 'Severity', 'reportStatus': 'Status', 'reportType': 'Type',
    'viewDetail': 'View Detail', 'markClosed': 'Mark as Closed',
    'deleteReport': 'Delete', 'confirmDelete': 'Confirm Delete',
    'deleteWarning': 'This action cannot be undone.',
    'cancel': 'Cancel', 'confirm': 'Confirm',
    'chatTitle': 'Ask AI', 'chatHint': 'Ask about safety procedures, regulations...',
    'chatSend': 'Send',
    'chatWelcome': 'Hello! Ask me about PPE, LOTO, working at height, fire safety, gas hazards, or any SAIL safety topic.',
    'chatOffline': 'Offline Mode — Using local knowledge base',
    'chatThinking': 'Thinking...',
    'chatNoAnswer': 'Ask me about: PPE, LOTO, confined space, working at height, hot work, electrical, gas safety.',
    'settingsTitle': 'Settings', 'settingsBackend': 'Backend URL',
    'settingsSyncNow': 'Sync Now', 'settingsTheme': 'Theme',
    'settingsLanguage': 'Language', 'settingsDark': 'Dark', 'settingsLight': 'Light',
    'settingsVersion': 'Version', 'settingsSyncSuccess': 'Sync complete',
    'settingsSyncFail': 'Sync failed',
    'adminTitle': 'Admin Control Panel', 'adminKnowledge': 'Knowledge Base',
    'adminUsers': 'Users', 'adminAnalytics': 'Analytics',
    'adminAddText': 'Add Text Entry', 'adminSyncCloud': 'Sync from Cloud',
    'adminEbook': 'eBook → Local AI KB',
    'adminEbookSubtitle': 'Upload a safety PDF to auto-generate KB entries',
    'adminSelectPdf': 'Tap to select PDF eBook...',
    'adminGenerateKb': 'Generate KB', 'adminKbGenerated': 'KB Code Generated!',
    'adminCopyCode': 'Copy Code', 'adminCopied': 'Copied!',
    'adminProcessing': 'Processing...', 'adminNoDocuments': 'No knowledge documents yet',
    'adminNoUsers': 'No registered users',
    'severity_critical': 'CRITICAL', 'severity_high': 'HIGH',
    'severity_medium': 'MEDIUM', 'severity_low': 'LOW',
    'status_open': 'OPEN', 'status_closed': 'CLOSED', 'status_inprogress': 'IN PROGRESS',
    'loading': 'Loading...', 'retry': 'Retry', 'save': 'Save', 'update': 'Update',
    'delete': 'Delete', 'edit': 'Edit', 'close': 'Close', 'back': 'Back',
    'next': 'Next', 'submit': 'Submit', 'reset': 'Reset', 'search': 'Search',
    'noData': 'No data available', 'error': 'Error', 'success': 'Success',
    'warning': 'Warning', 'info': 'Info',
  };

  // ── Hindi ─────────────────────────────────────────────────────────────
  static const Map<String, String> _hi = {
    'appName': 'SAIL सेफ्टी लेंस',
    'selectLanguage': 'भाषा चुनें', 'languageSaved': 'भाषा अपडेट हो गई',
    'login': 'लॉगिन', 'register': 'पंजीकरण', 'logout': 'लॉगआउट',
    'username': 'उपयोगकर्ता नाम', 'password': 'पासवर्ड', 'name': 'नाम',
    'designation': 'पदनाम', 'plant': 'प्लांट / यूनिट', 'employeeNo': 'कर्मचारी संख्या',
    'loginBtn': 'लॉगिन करें', 'registerBtn': 'खाता बनाएं',
    'loginFailed': 'गलत क्रेडेंशियल', 'fillAllFields': 'कृपया सभी फ़ील्ड भरें',
    'dashboard': 'डैशबोर्ड', 'safetyScore': 'सुरक्षा स्कोर',
    'totalIncidents': 'कुल घटनाएं', 'openIncidents': 'खुली',
    'criticalIncidents': 'गंभीर', 'aiScans': 'AI स्कैन',
    'quickActions': 'त्वरित कार्य', 'reportNearMiss': 'नियर मिस रिपोर्ट करें',
    'startAiScan': 'AI स्कैन शुरू करें', 'viewReports': 'रिपोर्ट देखें',
    'askAi': 'AI से पूछें', 'plantSummary': 'प्लांट सारांश',
    'recentActivity': 'हालिया गतिविधि', 'noRecentActivity': 'कोई हालिया गतिविधि नहीं',
    'good': 'अच्छा', 'needsAttention': 'ध्यान चाहिए', 'critical': 'गंभीर',
    'nearMissTitle': 'नियर मिस रिपोर्ट',
    'nearMissSubtitle': 'असुरक्षित स्थिति या नियर मिस घटना की रिपोर्ट करें',
    'incidentDate': 'घटना की तारीख', 'incidentTime': 'घटना का समय',
    'location': 'स्थान / क्षेत्र', 'department': 'विभाग',
    'incidentDescription': 'घटना का विवरण',
    'incidentDescHint': 'बताएं क्या हुआ, क्या देखा, या क्या गलत हो सकता था...',
    'immediateAction': 'तत्काल की गई कार्रवाई',
    'immediateActionHint': 'घटना के बाद तुरंत क्या किया गया?',
    'injuryOccurred': 'क्या कोई चोट लगी?', 'yes': 'हाँ', 'no': 'नहीं',
    'injuryDetails': 'चोट का विवरण',
    'injuryDetailsHint': 'चोट की प्रकृति और सीमा बताएं...',
    'witnesses': 'गवाह (यदि कोई हो)', 'witnessesHint': 'उपस्थित गवाहों के नाम...',
    'submitReport': 'रिपोर्ट जमा करें', 'reportSubmitted': 'रिपोर्ट सफलतापूर्वक जमा हो गई',
    'reportFailed': 'रिपोर्ट जमा नहीं हो सकी। पुनः प्रयास करें।',
    'voiceInput': 'बोलने के लिए माइक दबाएं', 'listening': 'सुन रहा है...',
    'tapToSpeak': 'बोलने के लिए दबाएं',
    'severityLevel': 'गंभीरता स्तर', 'selectSeverity': 'गंभीरता चुनें',
    'wsaCause': 'WSA कारण श्रेणी', 'selectWsa': 'WSA कारण चुनें',
    'attachPhoto': 'फ़ोटो संलग्न करें', 'photoAttached': 'फ़ोटो संलग्न हो गई',
    'rootCause': 'मूल कारण', 'rootCauseHint': 'मूल कारण क्या था?',
    'correctiveAction': 'सुधारात्मक कार्रवाई',
    'correctiveActionHint': 'पुनरावृत्ति रोकने के लिए क्या कदम उठाए जाएं?',
    'aiScanTitle': 'AI हजार्ड स्कैन',
    'aiScanSubtitle': 'AI हजार्ड विश्लेषण के लिए फ़ोटो लें या अपलोड करें',
    'takePhoto': 'फ़ोटो लें', 'uploadPhoto': 'गैलरी से अपलोड करें',
    'analysing': 'छवि का विश्लेषण हो रहा है...', 'analysisComplete': 'विश्लेषण पूर्ण',
    'hazardsFound': 'खतरा मिला', 'noHazardsFound': 'कोई खतरा नहीं मिला',
    'riskScore': 'जोखिम स्कोर', 'confidence': 'विश्वसनीयता', 'hazardType': 'खतरे का प्रकार',
    'summary': 'सारांश', 'hazards': 'खतरे',
    'correctiveActions': 'सुधारात्मक कार्रवाइयां', 'preventiveActions': 'निवारक कार्रवाइयां',
    'regulations': 'लागू विनियम', 'exportPdf': 'PDF रिपोर्ट निर्यात करें',
    'shareReport': 'रिपोर्ट शेयर करें', 'scanAnother': 'दूसरा स्कैन करें',
    'reportsTitle': 'घटना रिपोर्ट', 'filterAll': 'सभी',
    'filterCritical': 'गंभीर', 'filterHigh': 'उच्च',
    'filterMedium': 'मध्यम', 'filterLow': 'कम',
    'filterOpen': 'खुली', 'filterClosed': 'बंद',
    'noReports': 'कोई रिपोर्ट नहीं मिली', 'reportDate': 'तारीख',
    'reportSeverity': 'गंभीरता', 'reportStatus': 'स्थिति', 'reportType': 'प्रकार',
    'viewDetail': 'विवरण देखें', 'markClosed': 'बंद के रूप में चिह्नित करें',
    'deleteReport': 'हटाएं', 'confirmDelete': 'हटाने की पुष्टि करें',
    'deleteWarning': 'यह क्रिया पूर्ववत नहीं की जा सकती।',
    'cancel': 'रद्द करें', 'confirm': 'पुष्टि करें',
    'chatTitle': 'AI से पूछें', 'chatHint': 'सुरक्षा प्रक्रियाओं के बारे में पूछें...',
    'chatSend': 'भेजें',
    'chatWelcome': 'नमस्ते! PPE, LOTO, ऊंचाई पर काम, अग्नि सुरक्षा के बारे में पूछें।',
    'chatOffline': 'ऑफलाइन मोड — स्थानीय ज्ञान आधार',
    'chatThinking': 'सोच रहा है...', 'chatNoAnswer': 'PPE, LOTO, सुरक्षा विषय पूछें।',
    'settingsTitle': 'सेटिंग्स', 'settingsBackend': 'बैकएंड URL',
    'settingsSyncNow': 'अभी सिंक करें', 'settingsTheme': 'थीम',
    'settingsLanguage': 'भाषा', 'settingsDark': 'डार्क', 'settingsLight': 'लाइट',
    'settingsVersion': 'संस्करण', 'settingsSyncSuccess': 'सिंक पूर्ण', 'settingsSyncFail': 'सिंक विफल',
    'adminTitle': 'एडमिन कंट्रोल पैनल', 'adminKnowledge': 'ज्ञान आधार',
    'adminUsers': 'उपयोगकर्ता', 'adminAnalytics': 'विश्लेषण',
    'adminAddText': 'टेक्स्ट एंट्री जोड़ें', 'adminSyncCloud': 'क्लाउड से सिंक करें',
    'adminEbook': 'ई-बुक → लोकल AI KB', 'adminEbookSubtitle': 'KB एंट्री बनाने के लिए PDF अपलोड करें',
    'adminSelectPdf': 'PDF ई-बुक चुनने के लिए दबाएं...',
    'adminGenerateKb': 'KB बनाएं', 'adminKbGenerated': 'KB कोड तैयार!',
    'adminCopyCode': 'कोड कॉपी करें', 'adminCopied': 'कॉपी हो गया!',
    'adminProcessing': 'प्रक्रिया हो रही है...', 'adminNoDocuments': 'अभी तक कोई दस्तावेज़ नहीं',
    'adminNoUsers': 'कोई पंजीकृत उपयोगकर्ता नहीं',
    'severity_critical': 'गंभीर', 'severity_high': 'उच्च',
    'severity_medium': 'मध्यम', 'severity_low': 'कम',
    'status_open': 'खुली', 'status_closed': 'बंद', 'status_inprogress': 'प्रगति में',
    'loading': 'लोड हो रहा है...', 'retry': 'पुनः प्रयास', 'save': 'सहेजें',
    'update': 'अपडेट करें', 'delete': 'हटाएं', 'edit': 'संपादित करें',
    'close': 'बंद करें', 'back': 'वापस', 'next': 'अगला', 'submit': 'जमा करें',
    'reset': 'रीसेट', 'search': 'खोजें', 'noData': 'कोई डेटा उपलब्ध नहीं',
    'error': 'त्रुटि', 'success': 'सफल', 'warning': 'चेतावनी', 'info': 'जानकारी',
  };
}

// ── Delegate ──────────────────────────────────────────────────────────────────
class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      ['en', 'hi'].contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

