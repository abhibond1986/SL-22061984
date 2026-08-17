import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/language_picker_widget.dart';
import '../main.dart';
import '../services/sync_service.dart';
import '../services/local_db.dart';

// ─────────────────────────────────────────────────────────────
//  Admin Panel URL — update after deploying to GitHub Pages
// ─────────────────────────────────────────────────────────────
const String _kAdminPanelUrl =
    'https://abhibond1986.github.io/SL-22061984/admin/';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  bool _busy       = false;
  String _status   = '';
  DateTime? _lastSync;
  int _pendingCount = 0;
  bool _backendOk  = false;

  // ── Admin panel launch state ──
  bool _adminLaunching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  // ─── LOAD SETTINGS ───────────────────────────────────────────
  Future<void> _load() async {
    final url        = await SyncService.getBackendUrl();
    final lastSync   = await SyncService.getLastSyncTime();
    final pending    = await SyncService.pendingQueueSize();
    final configured = await SyncService.isConfigured;
    if (!mounted) return;
    setState(() {
      _urlCtrl.text  = (url == 'YOUR_APPS_SCRIPT_URL_HERE') ? '' : url;
      _lastSync      = lastSync;
      _pendingCount  = pending;
      _backendOk     = configured;
    });
  }

  // ─── SAVE URL ────────────────────────────────────────────────
  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _showSnack('Please paste the Apps Script Web App URL', AppColors.red);
      return;
    }
    if (!url.startsWith('https://script.google.com/')) {
      _showSnack(
        'URL should start with https://script.google.com/',
        AppColors.red,
      );
      return;
    }
    await SyncService.setBackendUrl(url);
    await _load();
    _showSnack('Backend URL saved ✓', AppColors.green);
  }

  // ─── TEST CONNECTION ─────────────────────────────────────────
  Future<void> _testConnection() async {
    setState(() { _busy = true; _status = 'Testing connection…'; });
    final result = await SyncService.ping();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result['ok'] == true
          ? '✓ Connected! Backend responded at ${result['time']}'
          : '✗ Failed: ${result['error'] ?? 'Unknown error'}';
    });
  }

  // ─── SYNC NOW ────────────────────────────────────────────────
  Future<void> _syncNow() async {
    setState(() { _busy = true; _status = 'Syncing…'; });
    // force: the user pressed a button labelled "Sync Now" — a throttled
    // no-op would report "✓ Sync complete" without having synced, and the
    // Pushed/Pulled counts below only exist on a real run.
    final result = await SyncService.fullSync(force: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result['ok'] == true
          ? '✓ Sync complete · Pushed: ${result['pushed']} · Pulled: ${result['pulled']}'
          : '✗ ${result['error']}';
    });
    await _load();
  }

  // ─── OPEN ADMIN PANEL ────────────────────────────────────────
  Future<void> _openAdminPanel() async {
    setState(() => _adminLaunching = true);
    try {
      final uri = Uri.parse(_kAdminPanelUrl);
      final canLaunch = await canLaunchUrl(uri);
      if (canLaunch) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          _showSnack('Could not open browser. Visit:\n$_kAdminPanelUrl', AppColors.red);
        }
      }
    } catch (e) {
      if (mounted) _showSnack('Error: $e', AppColors.red);
    } finally {
      if (mounted) setState(() => _adminLaunching = false);
    }
  }

  // ─── SHOW URL INFO DIALOG ────────────────────────────────────
  void _showAdminUrlDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Row(children: [
          Icon(Icons.admin_panel_settings, color: AppColors.accent, size: 20),
          SizedBox(width: 8),
          Text('Admin Panel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The Admin Panel opens in your browser. Login with:',
              style: TextStyle(color: SL.of(context).text2, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _infoRow('URL', _kAdminPanelUrl),
            const SizedBox(height: 6),
            _infoRow('Default username', 'admin'),
            const SizedBox(height: 6),
            _infoRow('Default password', 'admin'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.amber.withOpacity(0.4)),
              ),
              child: const Text(
                '⚠️ Change the default password after first login.',
                style: TextStyle(color: AppColors.amber, fontSize: 10, height: 1.4),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: SL.of(context).text3)),
          ),
          ElevatedButton(
            onPressed: () { Navigator.pop(context); _openAdminPanel(); },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Open', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    final sl = SL.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: sl.text4, fontSize: 9,
            fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 2),
        SelectableText(value,
            style: TextStyle(color: sl.text1, fontSize: 11,
                fontWeight: FontWeight.w600, fontFamily: 'monospace')),
      ],
    );
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(
          'Settings · Sync',
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: IconThemeData(color: sl.text1),
        actions: [
          // Language picker in app bar
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: LanguagePickerWidget(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── ADMIN PANEL CARD ─────────────────────────────────
            _sectionLabel('ADMIN PANEL'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.accent.withOpacity(0.08),
                    AppColors.accent.withOpacity(0.03),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: AppColors.accent.withOpacity(0.35)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  // Top info row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.admin_panel_settings_rounded,
                            color: AppColors.accent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'User & Access Management',
                                style: TextStyle(
                                  color: sl.text1,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Manage users · Set roles · View plant-wise activity · Configure sync',
                                style: TextStyle(
                                  color: sl.text3,
                                  fontSize: 10,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Feature chips
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Wrap(
                      spacing: 6, runSpacing: 6,
                      children: [
                        _chip(Icons.people_outline, 'All Users'),
                        _chip(Icons.verified_user_outlined, 'Role Control'),
                        _chip(Icons.bar_chart_rounded, 'Activity'),
                        _chip(Icons.factory_outlined, 'Plant View'),
                        _chip(Icons.lock_outline, 'Admin Only'),
                      ],
                    ),
                  ),

                  // Divider
                  Divider(
                    height: 1,
                    color: AppColors.accent.withOpacity(0.2),
                  ),

                  // Action buttons
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        // Info button
                        OutlinedButton.icon(
                          onPressed: _showAdminUrlDialog,
                          icon: const Icon(Icons.info_outline, size: 15),
                          label: const Text('Login info'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.accent),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            textStyle: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Open button
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _adminLaunching ? null : _openAdminPanel,
                            icon: _adminLaunching
                                ? const SizedBox(
                                    width: 14, height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ))
                                : const Icon(Icons.open_in_browser,
                                    size: 16, color: Colors.white),
                            label: Text(
                              _adminLaunching ? 'Opening…' : 'Open Admin Panel',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            Divider(color: sl.border),
            const SizedBox(height: 20),

            // ── CLOUD SYNC STATUS ────────────────────────────────
            // Data now syncs through Supabase (see SupabaseConfig). The legacy
            // Google Sheets / Apps Script backend UI has been retired; the code
            // path remains as a safe fallback but is no longer user-facing.
            _sectionLabel('CLOUD SYNC'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.green.withOpacity(0.08),
                border: Border.all(color: AppColors.green),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.cloud_done, color: AppColors.green, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Connected — live sync active',
                      style: TextStyle(
                        color: AppColors.green,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'Reports, AI hazard scans and near-miss records sync '
                    'automatically across all devices in real time.',
                    style: TextStyle(color: sl.text2, fontSize: 11, height: 1.4),
                  ),
                  if (_lastSync != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Last sync: ${_lastSync!.toLocal()}',
                      style: TextStyle(color: sl.text4, fontSize: 9),
                    ),
                  ],
                  if (_pendingCount > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '$_pendingCount items waiting to sync',
                      style: const TextStyle(
                        color: AppColors.amber,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Manual refresh — pull the latest from the cloud on demand.
            ElevatedButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync, color: Colors.white, size: 18),
              label: Text(
                _busy ? 'Syncing…' : 'Sync Now',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size(double.infinity, 0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),

            // Status message
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sl.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _status.startsWith('✓')
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 14,
                      color: _status.startsWith('✓')
                          ? AppColors.green
                          : AppColors.red,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),
            Divider(color: sl.border),
            const SizedBox(height: 16),

            // ── SETUP GUIDE ──────────────────────────────────────
            _sectionLabel('SETUP GUIDE'),
            const SizedBox(height: 8),
            ..._guideStep(1,
                'Create a Google Sheet at sheets.google.com — name it "SAIL Safety Lens DB"'),
            ..._guideStep(2, 'Click Extensions → Apps Script'),
            ..._guideStep(3,
                'Delete default code, paste the code from backend/google_apps_script.gs (in the repo)'),
            ..._guideStep(4,
                'Click Deploy → New deployment → Web app → Execute as: Me → Anyone access → Deploy'),
            ..._guideStep(5,
                'Copy the /exec URL → paste in the field above → Save → Test Connection'),
            ..._guideStep(6,
                'Open Admin Panel (button at top) → login with admin/admin → manage users'),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.amber.withOpacity(0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline, color: AppColors.amber, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pilot only: "Anyone access" means anyone with the URL can read/write. '
                    'For production, restrict to your org domain and add API key auth.',
                    style: TextStyle(
                        color: AppColors.amber, fontSize: 10, height: 1.4),
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  //  HELPERS
  // ─────────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Text(
    text,
    style: TextStyle(
      color: SL.of(context).text4,
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
    ),
  );

  Widget _chip(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.accent.withOpacity(0.1),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: AppColors.accent.withOpacity(0.25)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: AppColors.accent),
      const SizedBox(width: 4),
      Text(label,
          style: const TextStyle(
              color: AppColors.accent,
              fontSize: 10,
              fontWeight: FontWeight.w600)),
    ]),
  );

  List<Widget> _guideStep(int n, String text) => [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22, height: 22,
          decoration: const BoxDecoration(
              color: AppColors.accent, shape: BoxShape.circle),
          child: Center(
            child: Text('$n',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(text,
                style: const TextStyle(
                    color: sl.text2, fontSize: 11, height: 1.4)),
          ),
        ),
      ]),
    ),
  ];
}
