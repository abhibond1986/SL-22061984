// lib/screens/bulk_user_import_screen.dart
// ═══════════════════════════════════════════════════════════════════════════
//  Bulk employee import — pick file → PREVIEW → confirm → progress → summary.
//
//  A separate screen rather than another section of admin_screen.dart, which is
//  already ~9,000 lines. This flow has its own five-stage state machine and
//  nothing else in the admin panel needs to know about it.
//
//  THE PREVIEW IS THE POINT. This operation touches every account in the
//  company, so nothing is written until the admin has seen: which column became
//  which field, how many accounts would be created versus refreshed, which UNIT
//  codes are not in the Plant Master and what to do about each, and exactly who
//  would be deactivated. There is no "just import it" path, and the
//  deactivation list starts with nothing ticked.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../widgets/content_width.dart';
import '../services/admin_master_data.dart';
import '../services/supabase_config.dart';
import '../services/supabase_service.dart';
import '../services/tabular_reader.dart';
import '../services/user_import.dart';
import '../services/user_import_runner.dart';
// Same web/mobile download shim the rest of the app uses.
import '../services/pdf_export_stub.dart'
    if (dart.library.html) '../services/pdf_export_web.dart' as html; // ignore: avoid_web_libraries_in_flutter

enum _Stage { idle, reading, preview, running, done }

/// Sentinel for the unit-reconciliation dropdown: add this code to the Plant
/// Master as a new entry. Not a plant name, so it cannot collide with one.
const String _kAddAsPlant = '::ADD::';

class BulkUserImportScreen extends StatefulWidget {
  const BulkUserImportScreen({super.key});

  @override
  State<BulkUserImportScreen> createState() => _BulkUserImportScreenState();
}

class _BulkUserImportScreenState extends State<BulkUserImportScreen> {
  /// Remembers last quarter's UNIT → plant decisions so the same 15 unknown
  /// codes do not have to be reconciled again every three months.
  static const String _kUnitMapPref = 'bulk_import_unit_map';

  _Stage _stage = _Stage.idle;
  String _error = '';
  String _fileName = '';

  TabularSheet? _sheet;
  ImportPlan? _plan;
  ImportResult? _result;
  ImportProgress? _progress;

  /// Cached so changing a unit decision re-plans without another round trip.
  Set<String>? _existing;

  List<Map<String, String>> _plants = const [];
  Map<String, String> _unitDecision = <String, String>{};
  final Set<String> _deactivate = <String>{};

  bool _busy = false;

  // ── Stage 1 : choose a file ─────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() => _error = '');
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: TabularReader.pickerExtensions,
        withData: true,
      );
    } catch (e) {
      setState(() => _error = 'Could not open the file picker: $e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      setState(() => _error =
          'That file could not be read. Try copying it to your Desktop and '
          'choosing it again.');
      return;
    }

    setState(() {
      _stage = _Stage.reading;
      _fileName = f.name;
      _sheet = null;
      _plan = null;
      _result = null;
      _deactivate.clear();
    });

    try {
      final sheet = await TabularReader.read(
          fileName: f.name, bytes: Uint8List.fromList(bytes));
      _sheet = sheet;
      await _loadContextAndPlan(sheet);
    } on TabularException catch (e) {
      setState(() {
        _stage = _Stage.idle;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.idle;
        _error = 'That file could not be read: $e';
      });
    }
  }

  /// Load the Plant Master, the remembered unit mapping and the existing roster,
  /// then build the plan.
  Future<void> _loadContextAndPlan(TabularSheet sheet) async {
    try {
      _plants = await AdminMasterData.getPlants();

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUnitMapPref);
      if (raw != null) {
        try {
          _unitDecision = (jsonDecode(raw) as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()));
        } catch (_) {
          _unitDecision = <String, String>{};
        }
      }

      // The roster comparison. null means the call FAILED — never "empty" —
      // because an empty set would make every one of the 10,000 rows look new
      // and every existing account look absent from the file.
      if (SupabaseConfig.enabled) {
        _existing = await SupabaseService.fetchAllUsernames();
      } else {
        _existing = null;
      }

      _replan();
    } catch (e) {
      setState(() {
        _stage = _Stage.idle;
        _error = 'Could not prepare the import: $e';
      });
    }
  }

  /// Rebuild the plan from the already-parsed sheet. Cheap — no network — so it
  /// is safe to call every time a unit decision changes.
  void _replan() {
    final sheet = _sheet;
    if (sheet == null) return;

    // Only real plant mappings go into the planner. A code the admin chose to
    // ADD to the Plant Master keeps its own name as the plant, and a code left
    // undecided falls through to itself too.
    final mapping = <String, String>{};
    _unitDecision.forEach((code, choice) {
      if (choice.isNotEmpty && choice != _kAddAsPlant) mapping[code] = choice;
    });

    final plan = UserImportService.buildPlan(
      sheet: sheet,
      existingUsernames: _existing,
      knownPlants: [
        for (final p in _plants) ...[p['code'] ?? '', p['name'] ?? ''],
      ],
      unitToPlant: mapping,
      fileName: _fileName,
    );

    setState(() {
      _plan = plan;
      _stage = _Stage.preview;
    });
  }

  // ── Stage 3 : run ───────────────────────────────────────────────────────

  Future<void> _confirmAndRun() async {
    final plan = _plan;
    if (plan == null || !plan.canRun) return;

    final sl = SL.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: sl.card,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Import ${plan.sheet.rowCount} employees?',
            style: TextStyle(color: sl.text1, fontWeight: FontWeight.w800)),
        content: Text(
          '${plan.createCount} new accounts will be created with the SAIL P.no '
          'as the initial password. Each person must change it before they can '
          'use the portal.\n\n'
          '${plan.updateCount} existing accounts will have their profile '
          'refreshed. Their passwords are not changed.\n\n'
          '${plan.retiredCount + _deactivate.length} accounts will be '
          'disabled.',
          style: TextStyle(color: sl.text2, height: 1.45),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _stage = _Stage.running;
      _progress = const ImportProgress(stage: 'Starting', done: 0, total: 0);
      _busy = true;
    });

    try {
      await _applyUnitDecisions();

      final result = await UserImportRunner.run(
        plan,
        deactivate: _deactivate.toList(),
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _busy = false;
        _result = ImportResult(
          created: 0,
          updated: 0,
          disabled: 0,
          skipped: plan.invalidCount,
          batchId: plan.batchId,
          errors: ['The import stopped with an error: $e'],
        );
      });
    }
  }

  /// Persist the admin's unit decisions, and add the codes they chose to add.
  ///
  /// Runs BEFORE the rows are written so that a plant referenced by an imported
  /// user already exists in the master list; otherwise the first dashboard load
  /// after an import shows employees filed under a plant the filters do not
  /// know about.
  Future<void> _applyUnitDecisions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUnitMapPref, jsonEncode(_unitDecision));

    final toAdd = _unitDecision.entries
        .where((e) => e.value == _kAddAsPlant)
        .map((e) => e.key)
        .toList();
    if (toAdd.isEmpty) return;

    final existingCodes =
        _plants.map((p) => (p['code'] ?? '').toUpperCase()).toSet();
    final next = _plants.map((p) => Map<String, String>.from(p)).toList();
    for (final code in toAdd) {
      if (existingCodes.contains(code.toUpperCase())) continue;
      next.add(<String, String>{
        'code': code,
        // The file gives a code and nothing else, so the name starts as the
        // code. An admin can rename it in Plant Master; inventing a full name
        // here would put a guess in front of every user.
        'name': code,
        'state': '—',
        'kind': 'Unit',
      });
    }
    await AdminMasterData.savePlants(next);
    _plants = next;
  }

  // ── Downloads ───────────────────────────────────────────────────────────

  void _download(String content, String filename, {String mime = 'text/csv'}) {
    try {
      final blob = html.Blob([content], '$mime;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      // ignore: unused_local_variable
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();
      html.Url.revokeObjectUrl(url);
      return;
    } catch (_) {}
    Clipboard.setData(ClipboardData(text: content));
    _toast('Download is not available here — copied to the clipboard instead.');
  }

  void _downloadTemplate() {
    // Header order matches the SAIL export so a file built from this template
    // is interchangeable with the real one.
    const header =
        'NAME,GRADE,DESIG,DEPT,UNIT,EMAIL,MOBILE_NO,RETIRE_DT,DOB,SAIL_PNO';
    const example =
        'SUBBARAJ S,E9,EXEC DIRECTOR,ASP,ASP,s.subbaraj@sail.in,918986875493,'
        '2029-03-31,1969-03-12,A000168';
    _download('$header\r\n$example\r\n', 'SafetyLens_employee_template.csv');
  }

  void _toast(String msg, [Color? c]) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: c,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Scaffold(
      backgroundColor: sl.bg,
      appBar: AppBar(
        backgroundColor: sl.card,
        foregroundColor: sl.text1,
        elevation: 0,
        title: const Text('Bulk employee upload'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: slGutter(context, base: const EdgeInsets.all(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error.isNotEmpty) _errorCard(sl, _error),
              if (_stage == _Stage.idle) ..._idleView(sl),
              if (_stage == _Stage.reading) _readingView(sl),
              if (_stage == _Stage.preview) ..._previewView(sl),
              if (_stage == _Stage.running) _runningView(sl),
              if (_stage == _Stage.done) ..._doneView(sl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(SL sl, {required Widget child, Color? tint}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tint ?? sl.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sl.border),
        ),
        child: child,
      );

  Widget _errorCard(SL sl, String msg) => _card(
        sl,
        tint: sl.isDark ? const Color(0xFF3A1F22) : const Color(0xFFFDECEE),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline_rounded, color: sl.critText),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(msg,
                style: TextStyle(color: sl.text1, height: 1.5)),
          ),
        ]),
      );

  List<Widget> _idleView(SL sl) => [
        _card(sl,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Upload the quarterly employee list',
                  style: TextStyle(
                      color: sl.text1,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                'Every employee in the file gets a Safety Lens account. Their '
                'username is their SAIL P.no, and their first password is the '
                'P.no as well — the app then makes them choose a new one before '
                'they can use the portal.\n\n'
                'Nothing is saved until you have seen a summary and pressed '
                'Import.',
                style: TextStyle(color: sl.text2, height: 1.5),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Choose file'),
                ),
                OutlinedButton.icon(
                  onPressed: _downloadTemplate,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download template'),
                ),
              ]),
              const SizedBox(height: 14),
              Text(
                'Accepts .xlsx and .csv. If your file is an older .xls, open it '
                'in Excel and use File → Save As → Excel Workbook (*.xlsx) '
                'first.',
                style: TextStyle(color: sl.text4, fontSize: 12.5, height: 1.45),
              ),
            ])),
      ];

  Widget _readingView(SL sl) => _card(sl,
      child: Row(children: [
        const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(width: 14),
        Expanded(
          child: Text('Reading $_fileName and comparing it with the accounts '
              'already in the portal…',
              style: TextStyle(color: sl.text2)),
        ),
      ]));

  // ── Preview ─────────────────────────────────────────────────────────────

  List<Widget> _previewView(SL sl) {
    final plan = _plan!;
    final out = <Widget>[];

    out.add(_card(sl,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.table_chart_rounded, color: sl.accentText),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$_fileName  •  ${plan.sheet.sheetName}',
                  style: TextStyle(
                      color: sl.text1, fontWeight: FontWeight.w700)),
            ),
            TextButton(onPressed: _pickFile, child: const Text('Change file')),
          ]),
          const SizedBox(height: 8),
          Text(UserImportService.describe(plan),
              style: TextStyle(color: sl.text2, height: 1.5)),
        ])));

    if (plan.missingColumns.isNotEmpty) {
      out.add(_errorCard(
          sl,
          'This file has no ${plan.missingColumns.join(' or ')} column, so no '
          'accounts can be created from it. Headings found: '
          '${plan.sheet.headers.join(', ')}'));
      return out;
    }
    if (!plan.rosterKnown) {
      out.add(_errorCard(
          sl,
          'The list of existing accounts could not be read from the server, so '
          'new and existing employees cannot be told apart. Nothing has been '
          'changed. Check the connection and choose the file again.\n\n'
          '${SupabaseService.usersLastError}'));
      return out;
    }

    // Counts.
    out.add(_card(sl,
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          _stat(sl, '${plan.createCount}', 'new accounts', sl.greenText),
          _stat(sl, '${plan.updateCount}', 'profiles refreshed', sl.accentText),
          _stat(sl, '${plan.retiredCount}', 'retired → disabled', sl.amberText),
          _stat(sl, '${plan.invalidCount}', 'rows skipped',
              plan.invalidCount > 0 ? sl.critText : sl.text4),
          _stat(sl, '${plan.warningCount}', 'rows with warnings', sl.text3),
        ])));

    // Column mapping.
    out.add(_card(sl,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionTitle(sl, 'Columns'),
          const SizedBox(height: 8),
          ...plan.mapping.entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${e.value}  →  ${_fieldLabel(e.key)}',
                    style: TextStyle(color: sl.text2, fontSize: 13)),
              )),
          if (plan.unmappedHeaders.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Not imported: ${plan.unmappedHeaders.join(', ')}',
                style: TextStyle(color: sl.text4, fontSize: 12.5)),
          ],
        ])));

    // Unit reconciliation — the admin decides, nothing is created silently.
    final units = UserImportService.unitsByHeadcount(plan)
        .where((e) => plan.unknownUnits.contains(e.key))
        .toList();
    if (units.isNotEmpty) {
      out.add(_card(sl,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(sl, '${units.length} unit codes are not in Plant '
                'Master'),
            const SizedBox(height: 6),
            Text(
              'These codes appear in the file but not in your plant list. '
              'Decide each one: add it as a new plant, point it at a plant you '
              'already have, or leave it alone (the code is still stored on '
              'each employee either way). Your choices are remembered for next '
              'quarter.',
              style: TextStyle(color: sl.text3, fontSize: 12.5, height: 1.45),
            ),
            const SizedBox(height: 12),
            ...units.map((e) => _unitRow(sl, e.key, e.value)),
          ])));
    }

    // Portal accounts absent from the file.
    if (plan.portalOnly.isNotEmpty) {
      out.add(_card(sl,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(sl,
                '${plan.portalOnly.length} accounts are not in this file'),
            const SizedBox(height: 6),
            Text(
              'Nothing happens to these unless you tick them. Someone missing '
              'from one quarter\'s export is often an export problem rather '
              'than a person who has left — and this list also includes any '
              'accounts you created by hand, such as your own.',
              style: TextStyle(color: sl.text3, fontSize: 12.5, height: 1.45),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Text('${_deactivate.length} selected',
                  style: TextStyle(color: sl.text2, fontSize: 12.5)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  if (_deactivate.length == plan.portalOnly.length) {
                    _deactivate.clear();
                  } else {
                    _deactivate
                      ..clear()
                      ..addAll(plan.portalOnly);
                  }
                }),
                child: Text(_deactivate.length == plan.portalOnly.length
                    ? 'Clear all'
                    : 'Select all'),
              ),
            ]),
            SizedBox(
              // Bounded on purpose: this list can be long, and an unbounded
              // one would push the Import button off the end of the page.
              height: plan.portalOnly.length > 6 ? 260 : null,
              child: ListView.builder(
                shrinkWrap: true,
                physics: plan.portalOnly.length > 6
                    ? null
                    : const NeverScrollableScrollPhysics(),
                itemCount: plan.portalOnly.length,
                itemBuilder: (_, i) {
                  final u = plan.portalOnly[i];
                  return CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _deactivate.contains(u),
                    title: Text(u, style: TextStyle(color: sl.text2)),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _deactivate.add(u);
                      } else {
                        _deactivate.remove(u);
                      }
                    }),
                  );
                },
              ),
            ),
          ])));
    }

    // Row problems.
    if (plan.invalidCount > 0 || plan.warningCount > 0) {
      out.add(_card(sl,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(sl, 'Rows that need attention'),
            const SizedBox(height: 6),
            ...plan.rows
                .where((r) => r.problems.isNotEmpty)
                .take(8)
                .map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                          'Row ${r.rowNumber} (${r.pno}) skipped — '
                          '${r.problems.join(' ')}',
                          style: TextStyle(color: sl.critText, fontSize: 12.5)),
                    )),
            ...plan.rows
                .where((r) => r.problems.isEmpty && r.warnings.isNotEmpty)
                .take(8)
                .map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                          'Row ${r.rowNumber} (${r.pno}) — '
                          '${r.warnings.join(' ')}',
                          style: TextStyle(color: sl.amberText, fontSize: 12.5)),
                    )),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => _download(
                  UserImportRunner.problemReportCsv(plan),
                  'SafetyLens_import_problems.csv'),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download the full list'),
            ),
          ])));
    }

    if (plan.notes.isNotEmpty) {
      out.add(_card(sl,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final n in plan.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(n,
                    style: TextStyle(color: sl.text3, fontSize: 12.5)),
              ),
          ])));
    }

    out.add(Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: FilledButton.icon(
        onPressed: _busy || !plan.canRun ? null : _confirmAndRun,
        icon: const Icon(Icons.cloud_upload_rounded),
        label: Text('Import ${plan.createCount + plan.updateCount} employees'),
        style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16)),
      ),
    ));

    return out;
  }

  Widget _unitRow(SL sl, String code, int headcount) {
    final choice = _unitDecision[code] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        SizedBox(
          width: 130,
          child: Text('$code',
              style: TextStyle(color: sl.text1, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          width: 62,
          child: Text('$headcount',
              style: TextStyle(color: sl.text4, fontSize: 12.5)),
        ),
        Expanded(
          child: DropdownButtonFormField<String>(
            value: choice,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: sl.card2,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: sl.border)),
            ),
            style: TextStyle(color: sl.text1, fontSize: 13),
            items: [
              const DropdownMenuItem(value: '', child: Text('Leave as it is')),
              const DropdownMenuItem(
                  value: _kAddAsPlant, child: Text('Add as a new plant')),
              ...(_plants
                  .map((p) => p['name'] ?? '')
                  .where((n) => n.isNotEmpty)
                  .map((n) => DropdownMenuItem(
                      value: n, child: Text('Map to $n')))),
            ],
            onChanged: (v) {
              setState(() {
                if (v == null || v.isEmpty) {
                  _unitDecision.remove(code);
                } else {
                  _unitDecision[code] = v;
                }
              });
              // Re-plan so the preview shows the plant each employee would
              // actually be filed under, rather than the decision alone.
              _replan();
            },
          ),
        ),
      ]),
    );
  }

  Widget _stat(SL sl, String value, String label, Color colour) => Container(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: sl.card2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sl.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: TextStyle(
                  color: colour, fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: TextStyle(color: sl.text3, fontSize: 12)),
        ]),
      );

  Widget _sectionTitle(SL sl, String t) => Text(t,
      style:
          TextStyle(color: sl.text1, fontSize: 15, fontWeight: FontWeight.w800));

  static String _fieldLabel(String field) {
    switch (field) {
      case 'pno':
        return 'SAIL P.no (username and first password)';
      case 'name':
        return 'Name';
      case 'grade':
        return 'Grade';
      case 'designation':
        return 'Designation';
      case 'department':
        return 'Department';
      case 'unit':
        return 'Unit';
      case 'email':
        return 'Email';
      case 'mobile':
        return 'Mobile';
      case 'retireDate':
        return 'Retirement date (disables the account once passed)';
      case 'dob':
        return 'Date of birth';
      default:
        return field;
    }
  }

  // ── Running / done ──────────────────────────────────────────────────────

  Widget _runningView(SL sl) {
    final p = _progress;
    return _card(sl,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p?.stage ?? 'Working…',
              style:
                  TextStyle(color: sl.text1, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: p?.fraction,
              minHeight: 10,
              backgroundColor: sl.card2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
              p == null || p.total <= 0
                  ? 'Please keep this page open.'
                  : '${p.done} of ${p.total} — please keep this page open.',
              style: TextStyle(color: sl.text3, fontSize: 12.5)),
        ]));
  }

  List<Widget> _doneView(SL sl) {
    final r = _result!;
    return [
      _card(sl,
          tint: r.ok
              ? (sl.isDark ? const Color(0xFF17301F) : const Color(0xFFE9F7EE))
              : (sl.isDark ? const Color(0xFF3A2A16) : const Color(0xFFFFF6E5)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  r.ok
                      ? Icons.check_circle_rounded
                      : Icons.warning_amber_rounded,
                  color: r.ok ? sl.greenText : sl.amberText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(r.ok ? 'Import finished' : 'Import finished with problems',
                    style: TextStyle(
                        color: sl.text1,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(r.summary, style: TextStyle(color: sl.text2, height: 1.5)),
            if (r.created > 0) ...[
              const SizedBox(height: 10),
              Text(
                'The ${r.created} new accounts sign in with their SAIL P.no as '
                'both username and password, and must choose a new password '
                'immediately.',
                style: TextStyle(color: sl.text3, fontSize: 12.5, height: 1.45),
              ),
            ],
            for (final e in r.errors) ...[
              const SizedBox(height: 10),
              SelectableText(e,
                  style: TextStyle(color: sl.critText, fontSize: 12.5)),
            ],
          ])),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() {
              _stage = _Stage.idle;
              _plan = null;
              _sheet = null;
              _result = null;
              _error = '';
              _deactivate.clear();
            }),
            child: const Text('Import another file'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Done'),
          ),
        ),
      ]),
      const SizedBox(height: 24),
    ];
  }
}
