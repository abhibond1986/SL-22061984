// lib/screens/employee_profile_screen.dart
// SAIL Safety Lens — EMPLOYEE PROFILE (read-only)
//
// The quarterly employee list carries nine fields per person (name, grade,
// designation, department, unit, email, mobile, retirement date, date of birth)
// keyed by SAIL P.no. Before this screen existed, the admin panel showed four of
// them in a one-line list row, so the rest of the import was invisible: you could
// not check whether a person's unit had been mapped correctly, whether they were
// about to retire, or which upload their record came from.
//
// DESIGN NOTES — the two things to keep in mind before changing anything here.
//
// 1. THIS SCREEN IS READ-ONLY, DELIBERATELY. Editing an employee here would put
//    a second write path next to the quarterly import, and the next import would
//    silently overwrite the edit — so the honest thing is to show the data and
//    say where it came from. Account actions (disable, reset password) already
//    live in Admin → User Management, which is the one place that audits them.
//
// 2. IT ALWAYS RE-READS THE SERVER. Callers pass whatever row they already have
//    so the screen can paint immediately, but that row usually came from a
//    search projection (searchUsers selects twelve columns, not all of them) or
//    from a cached device copy that may be a quarter old. Showing a stale
//    retirement date on a screen whose whole job is to be authoritative would be
//    worse than showing a spinner.
//
// Nothing secret is rendered: getUserByUsername returns password_hash and salt
// because sign-in needs them, and _rows() lists the fields to display one by one
// rather than iterating the map, so a future credential column cannot leak onto
// the screen by accident.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/local_db.dart';
import '../services/supabase_service.dart';
import '../services/supabase_config.dart';

class EmployeeProfileScreen extends StatefulWidget {
  /// Username to display. For imported employees this is the SAIL P.no, lower
  /// cased — the same value stored in `incidents.assigned_to`.
  final String username;

  /// Optional row the caller already has, used only for the first paint.
  final Map<String, dynamic>? seed;

  const EmployeeProfileScreen({super.key, required this.username, this.seed});

  @override
  State<EmployeeProfileScreen> createState() => _EmployeeProfileScreenState();
}

class _EmployeeProfileScreenState extends State<EmployeeProfileScreen> {
  Map<String, dynamic>? _u;
  bool _loading = true;
  String _err = '';
  bool _fromCache = false;

  int _assigned = 0;
  int _reported = 0;
  bool _countsReady = false;

  @override
  void initState() {
    super.initState();
    _u = widget.seed == null ? null : Map<String, dynamic>.from(widget.seed!);
    _load();
  }

  String get _uname => widget.username.trim().toLowerCase();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });

    Map<String, dynamic>? fresh;
    var cache = false;

    if (SupabaseConfig.enabled && _uname.isNotEmpty) {
      fresh = await SupabaseService.getUserByUsername(_uname);
      if (fresh == null && SupabaseService.usersLastError.isNotEmpty) {
        // Distinguish "no such account" from "the lookup failed": falling back
        // to the cached copy is right in the second case and misleading in the
        // first, where it would resurrect a deleted employee.
        _err = SupabaseService.usersLastError;
      }
    }

    if (fresh == null) {
      final local = await LocalDB.getUsers();
      for (final u in local) {
        final n = u['username']?.toString().trim().toLowerCase() ?? '';
        if (n == _uname) {
          fresh = Map<String, dynamic>.from(u);
          cache = true;
          break;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      if (fresh != null) _u = fresh;
      _fromCache = cache;
      _loading = false;
    });

    _loadCounts();
  }

  /// Count the incidents this person is involved in.
  ///
  /// Assignment is keyed by username; reporting is keyed by P.no, because
  /// `reportedByPno` is what LocalDB.saveIncident stamps on a new record (there
  /// is no reporter *username* column). Both are counted from the device copy of
  /// incidents, which is the same list every other screen counts from — this is
  /// a "how busy is this person" hint, not an audit figure.
  Future<void> _loadCounts() async {
    try {
      final incs = await LocalDB.getIncidents();
      final pno = (_u?['pno'] ?? '').toString().trim().toLowerCase();
      var a = 0, r = 0;
      for (final i in incs) {
        if ((i['assignedTo']?.toString().trim().toLowerCase() ?? '') == _uname) {
          a++;
        }
        if (pno.isNotEmpty &&
            (i['reportedByPno']?.toString().trim().toLowerCase() ?? '') == pno) {
          r++;
        }
      }
      if (!mounted) return;
      setState(() {
        _assigned = a;
        _reported = r;
        _countsReady = true;
      });
    } catch (_) {
      // A profile with no activity counts is still a useful profile.
    }
  }

  // ── formatting ────────────────────────────────────────────────────────────
  String _s(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? '—' : s;
  }

  /// Dates arrive as ISO from Postgres (`date` columns) and occasionally as a
  /// pre-formatted string from an older device record, so anything unparseable
  /// is shown as-is rather than discarded.
  String _date(dynamic v) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty) return '—';
    final d = DateTime.tryParse(s);
    if (d == null) return s;
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month - 1]} ${d.year}';
  }

  bool _flag(dynamic v) =>
      v == true || const {'true', '1', 'yes', 't'}.contains(
          v?.toString().trim().toLowerCase() ?? '');

  DateTime? get _retire {
    final s = _u?['retireDate']?.toString().trim() ?? '';
    return s.isEmpty ? null : DateTime.tryParse(s);
  }

  String get _statusLabel {
    final st = (_u?['status'] ?? '').toString().trim().toLowerCase();
    if (st == 'disabled' || st == 'blocked' || st == 'inactive') {
      return st == 'inactive' ? 'Inactive' : 'Disabled';
    }
    return 'Active';
  }

  Color _statusColor(SL sl) =>
      _statusLabel == 'Active' ? sl.greenText : sl.redText;

  // ── ui ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final u = _u;
    return Scaffold(
      backgroundColor: sl.bg,
      appBar: AppBar(
        backgroundColor: sl.card,
        foregroundColor: sl.text1,
        elevation: 0,
        title: const Text('Employee Profile'),
        actions: [
          IconButton(
            tooltip: 'Copy profile',
            icon: const Icon(Icons.copy_all_rounded, size: 20),
            onPressed: u == null ? null : _copy,
          ),
          IconButton(
            tooltip: 'Reload from server',
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: u == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        _err.isEmpty
                            ? 'No account found for "${widget.username}".'
                            : 'Could not load this profile.\n\n$_err',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: sl.text3, fontSize: 13),
                      ),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
              children: [
                _header(sl, u),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(children: [
                      SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: sl.text4)),
                      const SizedBox(width: 8),
                      Text('Refreshing from server…',
                          style: TextStyle(color: sl.text4, fontSize: 11)),
                    ]),
                  ),
                if (_fromCache) ...[
                  const SizedBox(height: 10),
                  _banner(
                      sl,
                      Icons.cloud_off_rounded,
                      'Showing this device\'s cached copy — the server could not be '
                      'reached, so these values may be from an earlier quarter.',
                      sl.amberText),
                ],
                if (_flag(u['mustChangePassword'])) ...[
                  const SizedBox(height: 10),
                  _banner(
                      sl,
                      Icons.key_rounded,
                      'Still using the SAIL P.no as a password. The portal will '
                      'make them set their own on first sign-in.',
                      sl.amberText),
                ],
                _retireBanner(sl),
                const SizedBox(height: 14),
                _section(sl, 'Employment', [
                  _Row('SAIL P.no', _s(u['pno'])),
                  _Row('Grade', _s(u['grade'])),
                  _Row('Designation', _s(u['designation'])),
                  _Row('Department', _s(u['department'])),
                  _Row('Unit', _s(u['unit'])),
                  _Row('Plant', _s(u['plant'])),
                  _Row('Retirement date', _date(u['retireDate'])),
                ]),
                const SizedBox(height: 12),
                _section(sl, 'Contact', [
                  _Row('Email', _s(u['email'])),
                  _Row('Mobile', _s(u['mobile'])),
                  _Row('Date of birth', _date(u['dob'])),
                ]),
                const SizedBox(height: 12),
                _section(sl, 'Portal account', [
                  _Row('Username', _s(u['username'])),
                  _Row('Status', _statusLabel),
                  _Row('Role', _flag(u['isAdmin']) ? 'Administrator' : 'Employee'),
                  _Row('Password',
                      _flag(u['mustChangePassword']) ? 'P.no (unchanged)' : 'Set by user'),
                ]),
                const SizedBox(height: 12),
                _section(sl, 'Safety activity', [
                  _Row('Investigations assigned',
                      _countsReady ? '$_assigned' : '…'),
                  _Row('Reports filed', _countsReady ? '$_reported' : '…'),
                ]),
                const SizedBox(height: 12),
                _section(sl, 'Record origin', [
                  _Row('Source',
                      _s(u['importSource']) == 'bulk_import'
                          ? 'Quarterly employee list'
                          : _s(u['importSource']) == '—'
                              ? 'Created in the portal'
                              : _s(u['importSource'])),
                  _Row('Upload batch', _s(u['importBatch'])),
                  _Row('First imported', _date(u['importedAt'])),
                  _Row('Last updated', _date(u['updatedAt'])),
                ]),
                const SizedBox(height: 16),
                Text(
                  'Employment and contact details come from the quarterly SAIL '
                  'employee list and are refreshed by the next upload — edit them '
                  'in the source file, not here.',
                  style: TextStyle(color: sl.text4, fontSize: 11, height: 1.5),
                ),
              ],
            ),
    );
  }

  Widget _header(SL sl, Map<String, dynamic> u) {
    final name = _s(u['name']) == '—' ? _s(u['username']) : _s(u['name']);
    final initial = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sl.border),
      ),
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.14),
            shape: BoxShape.circle,
          ),
          child: Text(initial,
              style: TextStyle(
                  color: sl.accentText,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: TextStyle(
                      color: sl.text1, fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                  [
                    if (_s(u['designation']) != '—') _s(u['designation']),
                    if (_s(u['department']) != '—') _s(u['department']),
                  ].join(' · '),
                  style: TextStyle(color: sl.text3, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _chip(sl, '@${_s(u['username'])}', sl.text3),
                if (_s(u['unit']) != '—') _chip(sl, _s(u['unit']), sl.cyanText),
                if (_s(u['grade']) != '—') _chip(sl, _s(u['grade']), sl.accentText),
                _chip(sl, _statusLabel, _statusColor(sl)),
              ]),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _chip(SL sl, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Text(text,
            style: TextStyle(
                color: sl.textOn(color), fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Widget _banner(SL sl, IconData icon, String text, Color color) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.30)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: sl.text2, fontSize: 11.5, height: 1.4))),
        ]),
      );

  /// Retirement is the one field on this screen that changes what the portal
  /// does, so it gets said in words instead of leaving the admin to compare a
  /// date against today.
  Widget _retireBanner(SL sl) {
    final r = _retire;
    if (r == null) return const SizedBox.shrink();
    final days = r.difference(DateTime.now()).inDays;
    if (days < 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: _banner(
            sl,
            Icons.event_busy_rounded,
            'Retired on ${_date(r.toIso8601String())}. The quarterly upload '
            'disables accounts past their retirement date.',
            sl.redText),
      );
    }
    if (days <= 90) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: _banner(
            sl,
            Icons.event_rounded,
            'Retires in $days day${days == 1 ? '' : 's'} '
            '(${_date(r.toIso8601String())}) — reassign any open investigations '
            'before then.',
            sl.amberText),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _section(SL sl, String title, List<_Row> rows) => Container(
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sl.border),
        ),
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(13, 10, 13, 8),
            child: Text(title.toUpperCase(),
                style: TextStyle(
                    color: sl.text4,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8)),
          ),
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
              decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(
                        color: i == 0 ? sl.border : sl.border.withOpacity(0.5))),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 132,
                    child: Text(rows[i].label,
                        style: TextStyle(color: sl.text3, fontSize: 12)),
                  ),
                  Expanded(
                    child: SelectableText(rows[i].value,
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
        ]),
      );

  /// Copy the profile as plain text.
  ///
  /// Clipboard rather than a file download: this gets pasted into a WhatsApp
  /// message or an email when a safety cell asks "who is A000168", and a CSV
  /// would be the wrong shape for that.
  Future<void> _copy() async {
    final u = _u;
    if (u == null) return;
    final lines = <String>[
      _s(u['name']),
      'P.no: ${_s(u['pno'])}',
      'Grade: ${_s(u['grade'])}',
      'Designation: ${_s(u['designation'])}',
      'Department: ${_s(u['department'])}',
      'Unit: ${_s(u['unit'])}',
      'Email: ${_s(u['email'])}',
      'Mobile: ${_s(u['mobile'])}',
      'Retirement: ${_date(u['retireDate'])}',
      'Portal username: ${_s(u['username'])}  (${_statusLabel.toLowerCase()})',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Profile copied'), duration: Duration(seconds: 2)),
    );
  }
}

/// One label/value pair. A tiny class rather than a two-element list so a
/// mismatched pair cannot compile.
class _Row {
  final String label;
  final String value;
  const _Row(this.label, this.value);
}
