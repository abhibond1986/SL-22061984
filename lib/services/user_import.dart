// ═══════════════════════════════════════════════════════════════════════════
//  UserImportService — turn a parsed employee sheet into a PLAN, and nothing
//  else.
//
//  THIS FILE WRITES NOTHING. It reads the sheet, works out what would happen to
//  each of the ~10,000 rows, and hands back an [ImportPlan] for the admin to
//  look at and approve. That separation is the whole point: an import that
//  affects every account in the company must be reviewable before it runs, and
//  a preview that shares code with the writer can always drift from it.
//
//  THE FOUR DECISIONS BAKED IN HERE, and why
//
//  1. The username is the SAIL P.no, lower-cased. It is the only field in the
//     export that is unique, stable across quarters, and known to the employee
//     without being told. Names are not unique (this file has repeats), and
//     emails are missing for 202 people.
//
//  2. The initial password is the P.no exactly as written in the file. A P.no is
//     printed on an ID card and appears in this very spreadsheet, so it is a
//     bootstrap credential and NOT a secret — which is why every imported
//     account is flagged `mustChangePassword` and cannot reach the portal until
//     the person replaces it.
//
//  3. Existing accounts are NEVER given a new password by an import. Their
//     profile fields are refreshed; their credentials are not touched. A
//     quarterly refresh that reset 9,000 passwords would be indistinguishable
//     from an attack.
//
//  4. Anyone whose RETIRE_DT has passed is disabled, per the administrator's
//     decision. People in the portal who are ABSENT from a new file are NOT
//     touched automatically — they are listed for the admin to choose from.
// ═══════════════════════════════════════════════════════════════════════════

import 'tabular_reader.dart';

/// What the import would do with one row.
enum ImportAction {
  /// No account with this P.no exists yet — create one, with a credential.
  create,

  /// The account exists — refresh the profile fields only.
  update,

  /// The row cannot be imported. See [ImportRow.problems].
  invalid,
}

class ImportRow {
  ImportRow({
    required this.rowNumber,
    required this.username,
    required this.pno,
    required this.action,
    required this.user,
    this.problems = const <String>[],
    this.warnings = const <String>[],
    this.retired = false,
  });

  /// 1-based row number in the uploaded file, so a reported problem can be
  /// found in Excel without counting.
  final int rowNumber;

  final String username;
  final String pno;
  final ImportAction action;

  /// App-keyed profile fields (the keys [SupabaseService] maps to columns).
  /// Contains no credential fields — those are added by the writer.
  final Map<String, dynamic> user;

  /// Reasons this row cannot be imported. Non-empty implies [ImportAction.invalid].
  final List<String> problems;

  /// Things that were corrected or dropped. Imported anyway.
  final List<String> warnings;

  /// RETIRE_DT is in the past.
  final bool retired;

  /// The initial password for a newly created account: the P.no as written.
  String get initialPassword => pno;
}

/// Everything the preview screen needs, and everything the writer needs.
class ImportPlan {
  ImportPlan({
    required this.sheet,
    required this.batchId,
    required this.rows,
    required this.mapping,
    required this.unmappedHeaders,
    required this.missingColumns,
    required this.unitCounts,
    required this.unknownUnits,
    required this.portalOnly,
    required this.rosterKnown,
    this.notes = const <String>[],
  });

  final TabularSheet sheet;

  /// Identifies this upload in `import_batch`, so a bad quarter can be found
  /// afterwards: `<filename> <ISO timestamp>`.
  final String batchId;

  final List<ImportRow> rows;

  /// App field → the file heading it was taken from. Shown in the preview so
  /// the admin can confirm SAIL_PNO really did become the username.
  final Map<String, String> mapping;

  /// Headings in the file that no app field claimed. Not an error — but if
  /// MOBILE_NO is in this list, something has been renamed.
  final List<String> unmappedHeaders;

  /// Required app fields with no matching column. Non-empty means the import
  /// cannot run at all.
  final List<String> missingColumns;

  /// UNIT code → number of employees, highest first when iterated after sorting.
  final Map<String, int> unitCounts;

  /// UNIT codes that are not in the admin's Plant Master.
  ///
  /// Deliberately NOT auto-created. The administrator reconciles each one — add
  /// it as a plant, map it onto an existing plant, or leave it — because the
  /// plant list drives filters and dashboards across the whole app, and codes
  /// appearing in it overnight is not something to discover after the fact.
  ///
  /// The January 2026 file carries 25 UNIT codes, of which 15 (CO, CET, RDCIS,
  /// COL-DIV, VISL, T&S, MTI, SO, EMD, KULTI, CCSO, SDTD, CMLO, RMG, GD —
  /// 803 people) are not in the 16-entry Plant Master. Most are real SAIL units
  /// that belong there; a few are almost certainly the same place under two
  /// names. Only someone at SAIL can tell which is which.
  final Set<String> unknownUnits;

  /// Accounts in the portal that this file does not mention. Candidates for
  /// deactivation — the admin ticks the ones to disable. Empty when
  /// [rosterKnown] is false.
  final List<String> portalOnly;

  /// False when the existing roster could not be read from the server.
  ///
  /// Everything that compares against "what is already there" is then unsafe:
  /// every row would look new, and [portalOnly] would look like the entire
  /// company. The UI must refuse to import while this is false.
  final bool rosterKnown;

  final List<String> notes;

  Iterable<ImportRow> get creates =>
      rows.where((r) => r.action == ImportAction.create);
  Iterable<ImportRow> get updates =>
      rows.where((r) => r.action == ImportAction.update);
  Iterable<ImportRow> get invalid =>
      rows.where((r) => r.action == ImportAction.invalid);

  int get createCount => creates.length;
  int get updateCount => updates.length;
  int get invalidCount => invalid.length;
  int get retiredCount => rows.where((r) => r.retired).length;
  int get warningCount => rows.where((r) => r.warnings.isNotEmpty).length;

  bool get canRun => missingColumns.isEmpty && rosterKnown && rows.isNotEmpty;

  /// Usernames of importable rows whose retirement date has passed, so the
  /// writer can disable them in one targeted call.
  List<String> get retiredUsernames => rows
      .where((r) => r.retired && r.action != ImportAction.invalid)
      .map((r) => r.username)
      .toList();
}

class UserImportService {
  UserImportService._();

  /// Accepted headings for each app field, normalised by
  /// [TabularSheet.normaliseKey].
  ///
  /// Aliases exist because this file is regenerated by hand every quarter and
  /// the headings have already varied. The first match in the list wins, so the
  /// canonical SAIL heading is always listed first.
  static const Map<String, List<String>> fieldAliases = {
    'pno': ['SAIL_PNO', 'SAILPNO', 'SAIL_P_NO', 'PNO', 'P_NO', 'EMP_NO',
        'EMPLOYEE_NO', 'EMP_CODE', 'EMPLOYEE_CODE'],
    'name': ['NAME', 'EMPLOYEE_NAME', 'EMP_NAME', 'FULL_NAME'],
    'grade': ['GRADE', 'PAY_GRADE'],
    'designation': ['DESIG', 'DESIGNATION', 'POST'],
    'department': ['DEPT', 'DEPARTMENT', 'SECTION'],
    'unit': ['UNIT', 'PLANT', 'LOCATION'],
    'email': ['EMAIL', 'EMAIL_ID', 'E_MAIL'],
    'mobile': ['MOBILE_NO', 'MOBILE', 'MOBILE_NUMBER', 'PHONE', 'CONTACT_NO'],
    'retireDate': ['RETIRE_DT', 'RETIREMENT_DATE', 'RETIRE_DATE', 'DOR'],
    'dob': ['DOB', 'DATE_OF_BIRTH', 'BIRTH_DATE'],
  };

  /// Without these two there is nothing to create an account from.
  static const List<String> requiredFields = ['pno', 'name'];

  /// Usernames the app itself relies on. An employee whose P.no collided with
  /// one of these would take over that account on the next upsert.
  static const Set<String> reservedUsernames = {
    'admin',
    'administrator',
    'root',
    'system',
    'test',
    'guest',
  };

  /// Build the plan.
  ///
  /// [existingUsernames] must come from `SupabaseService.fetchAllUsernames()`.
  /// Pass null when that call FAILED — never an empty set. Null produces a plan
  /// with `rosterKnown == false` that the UI will refuse to run; an empty set
  /// means "the roster really is empty" and every row is a create.
  ///
  /// [knownPlants] is the admin's Plant Master, used only to report unknown UNIT
  /// codes. [unitToPlant] is the admin's reconciliation from a previous quarter:
  /// UNIT code → plant name. Codes absent from it fall back to the code itself.
  static ImportPlan buildPlan({
    required TabularSheet sheet,
    required Set<String>? existingUsernames,
    Iterable<String> knownPlants = const <String>[],
    Map<String, String> unitToPlant = const <String, String>{},
    DateTime? today,
    String fileName = 'employee list',
  }) {
    final now = DateTime.now();
    final cutoff = today ?? DateTime(now.year, now.month, now.day);
    final batchId = '$fileName ${now.toIso8601String()}';
    final notes = <String>[...sheet.notes];

    // ── Column mapping ────────────────────────────────────────────────────
    final available = <String>{};
    for (final h in sheet.headers) {
      final k = TabularSheet.normaliseKey(h);
      if (k.isNotEmpty) available.add(k);
    }
    // Rows are keyed by normalised header, and an unnamed column became
    // COLUMN_n; include those so the mapping can still reach them.
    if (sheet.rows.isNotEmpty) available.addAll(sheet.rows.first.keys);

    final mapping = <String, String>{};
    final usedKeys = <String>{};
    fieldAliases.forEach((field, aliases) {
      for (final alias in aliases) {
        if (available.contains(alias) && !usedKeys.contains(alias)) {
          mapping[field] = alias;
          usedKeys.add(alias);
          return;
        }
      }
    });

    final missing =
        requiredFields.where((f) => !mapping.containsKey(f)).toList();
    final unmapped = sheet.headers
        .where((h) {
          final k = TabularSheet.normaliseKey(h);
          return k.isNotEmpty && !usedKeys.contains(k);
        })
        .toList();

    if (missing.isNotEmpty) {
      // Return early with an unrunnable plan rather than throwing: the preview
      // screen can then show WHICH column is missing next to the list of
      // headings it did find, which is what an admin needs in order to fix it.
      return ImportPlan(
        sheet: sheet,
        batchId: batchId,
        rows: const <ImportRow>[],
        mapping: mapping,
        unmappedHeaders: unmapped,
        missingColumns: missing,
        unitCounts: const <String, int>{},
        unknownUnits: const <String>{},
        portalOnly: const <String>[],
        rosterKnown: existingUsernames != null,
        notes: notes,
      );
    }

    final plantSet = knownPlants
        .map((p) => p.trim().toUpperCase())
        .where((p) => p.isNotEmpty)
        .toSet();

    final rows = <ImportRow>[];
    final unitCounts = <String, int>{};
    final unknownUnits = <String>{};
    final seenPno = <String, int>{};   // username → first row number
    final seenEmail = <String, int>{}; // email    → first row number
    final inFile = <String>{};

    String cell(Map<String, String> row, String field) {
      final key = mapping[field];
      if (key == null) return '';
      return (row[key] ?? '').trim();
    }

    for (var i = 0; i < sheet.rows.length; i++) {
      final raw = sheet.rows[i];
      // +1 for the header row, +1 because spreadsheet rows are 1-based.
      final rowNumber = sheet.headerRowNumber + 1 + i;

      final problems = <String>[];
      final warnings = <String>[];

      final pno = cell(raw, 'pno');
      final username = pno.toLowerCase();
      final name = cell(raw, 'name');

      if (pno.isEmpty) {
        problems.add('No SAIL P.no — an account cannot be created without one.');
      } else if (reservedUsernames.contains(username)) {
        problems.add('P.no "$pno" is a name the app reserves for its own '
            'accounts and would take over an existing one.');
      } else {
        final first = seenPno[username];
        if (first != null) {
          // The January 2026 file has none of these, but a hand-edited quarter
          // easily could, and the LAST row would silently win the upsert.
          problems.add('Duplicate of the P.no on row $first — only the first '
              'row with this P.no is imported.');
        } else {
          seenPno[username] = rowNumber;
        }
      }
      if (name.isEmpty) {
        // Not fatal: the account is still usable and a name can be corrected in
        // the admin panel. Refusing the row would keep someone out of the
        // portal over a blank display field.
        warnings.add('No name in the file — shown as the P.no until corrected.');
      }

      // ── Unit → plant ──
      final unit = cell(raw, 'unit');
      if (unit.isNotEmpty) {
        unitCounts[unit] = (unitCounts[unit] ?? 0) + 1;
        final mapped = unitToPlant[unit] ?? unitToPlant[unit.toUpperCase()];
        if (mapped == null && !plantSet.contains(unit.toUpperCase())) {
          unknownUnits.add(unit);
        }
      }
      final plant = unitToPlant[unit] ?? unitToPlant[unit.toUpperCase()] ?? unit;

      // ── Email ──
      // Dropped rather than kept when it is unusable, because AuthService looks
      // an account up by username OR EMAIL: two people sharing an email would
      // let the wrong one of them log in, and a malformed address can never
      // receive anything anyway.
      var email = cell(raw, 'email').toLowerCase();
      if (email.isNotEmpty && !_emailLooksValid(email)) {
        warnings.add('Email "$email" is not a valid address — left blank.');
        email = '';
      }
      if (email.isNotEmpty) {
        final first = seenEmail[email];
        if (first != null) {
          warnings.add('Email "$email" is already used on row $first — left '
              'blank here so the two accounts cannot be confused at login.');
          email = '';
        } else {
          seenEmail[email] = rowNumber;
        }
      }

      // ── Dates ──
      final dob = _isoDateOrNull(cell(raw, 'dob'));
      final rawRetire = cell(raw, 'retireDate');
      final retire = _isoDateOrNull(rawRetire);
      if (rawRetire.isNotEmpty && retire == null) {
        warnings.add('Retirement date "$rawRetire" could not be read — this '
            'person will NOT be disabled automatically.');
      }
      var retired = false;
      if (retire != null) {
        final d = DateTime.tryParse(retire);
        if (d != null && d.isBefore(cutoff)) retired = true;
      }

      final mobile = _digitsOnly(cell(raw, 'mobile'));

      final user = <String, dynamic>{
        'username': username,
        'pno': pno,
        'name': name.isEmpty ? pno : name,
        'designation': cell(raw, 'designation'),
        'department': cell(raw, 'department'),
        'grade': cell(raw, 'grade'),
        'unit': unit,
        'plant': plant,
        'email': email,
        'mobile': mobile,
        'dob': dob ?? '',
        'retireDate': retire ?? '',
        'importSource': 'bulk_import',
        'importBatch': batchId,
        'updatedAt': now.toIso8601String(),
      };

      ImportAction action;
      if (problems.isNotEmpty) {
        action = ImportAction.invalid;
      } else if (existingUsernames == null) {
        // Roster unknown. Call it an update so nothing in the preview claims
        // 10,000 new accounts; the plan is unrunnable anyway.
        action = ImportAction.update;
      } else {
        action = existingUsernames.contains(username)
            ? ImportAction.update
            : ImportAction.create;
      }
      if (action != ImportAction.invalid) inFile.add(username);

      rows.add(ImportRow(
        rowNumber: rowNumber,
        username: username,
        pno: pno,
        action: action,
        user: user,
        problems: problems,
        warnings: warnings,
        retired: retired,
      ));
    }

    // ── In the portal, absent from this file ──────────────────────────────
    // Listed, never acted on. The admin ticks who to disable, because a name
    // missing from one quarter's export is at least as likely to be an export
    // problem as a person who has left.
    final portalOnly = <String>[];
    if (existingUsernames != null) {
      for (final u in existingUsernames) {
        if (!inFile.contains(u)) portalOnly.add(u);
      }
      portalOnly.sort();
    }

    // No "unchanged" bucket on purpose: telling one apart from a real update
    // would mean downloading all ~10,000 existing rows to compare them, which
    // is the exact cost this design avoids. Every existing row is refreshed;
    // rewriting a field with the value it already holds is harmless.
    if (existingUsernames != null && existingUsernames.isEmpty) {
      notes.add('There are no user accounts on the server yet, so every row '
          'in this file will create one.');
    }

    return ImportPlan(
      sheet: sheet,
      batchId: batchId,
      rows: rows,
      mapping: mapping,
      unmappedHeaders: unmapped,
      missingColumns: missing,
      unitCounts: unitCounts,
      unknownUnits: unknownUnits,
      portalOnly: portalOnly,
      rosterKnown: existingUsernames != null,
      notes: notes,
    );
  }

  /// UNIT codes with their headcount, largest first — the order the
  /// reconciliation list should be shown in, so the codes that matter most are
  /// decided first.
  static List<MapEntry<String, int>> unitsByHeadcount(ImportPlan plan) {
    final entries = plan.unitCounts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return entries;
  }

  /// A human summary for the top of the preview and for the import log.
  static String describe(ImportPlan plan) {
    if (plan.missingColumns.isNotEmpty) {
      return 'This file is missing the ${plan.missingColumns.join(' and ')} '
          'column, so it cannot be imported.';
    }
    if (!plan.rosterKnown) {
      return 'The existing user list could not be read from the server, so this '
          'file cannot be compared against it yet.';
    }
    final parts = <String>[
      '${plan.createCount} new ${plan.createCount == 1 ? 'account' : 'accounts'}',
      '${plan.updateCount} existing updated',
    ];
    if (plan.retiredCount > 0) parts.add('${plan.retiredCount} retired');
    if (plan.invalidCount > 0) parts.add('${plan.invalidCount} skipped');
    return '${plan.sheet.rowCount} rows read — ${parts.join(', ')}.';
  }

  // ── Field helpers ────────────────────────────────────────────────────────

  /// Deliberately loose. This is an HR export, not a signup form: the job here
  /// is to catch the 18 entries in the January 2026 file that are plainly not
  /// addresses (and the 4 that are shared by two people), not to adjudicate
  /// RFC 5322.
  static bool _emailLooksValid(String email) {
    if (email.contains(' ') || email.contains(',')) return false;
    final at = email.indexOf('@');
    if (at <= 0 || at != email.lastIndexOf('@')) return false;
    final domain = email.substring(at + 1);
    if (!domain.contains('.')) return false;
    if (domain.startsWith('.') || domain.endsWith('.')) return false;
    return true;
  }

  /// Keep digits only, but preserve a leading `+` country code.
  ///
  /// The export stores mobiles as `918986875493` — country code, no plus. Excel
  /// sometimes hands them back with a stray space or a `.0`; neither belongs in
  /// a number someone is going to dial in an emergency.
  static String _digitsOnly(String s) {
    final t = s.trim();
    if (t.isEmpty) return '';
    final plus = t.startsWith('+');
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    return plus ? '+$digits' : digits;
  }

  /// Accept `yyyy-MM-dd` (what TabularReader produces) and the two written
  /// forms that turn up when a column was stored as text: `dd/MM/yyyy` and
  /// `dd-MMM-yyyy`.
  ///
  /// Day-first, NOT month-first: this is an Indian HR system, and reading
  /// 03/08/1978 as the 8th of March would put a retirement date months out.
  /// Anything else returns null and is reported rather than guessed.
  static String? _isoDateOrNull(String value) {
    final s = value.trim();
    if (s.isEmpty) return null;

    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
    if (iso != null) {
      return _validDate(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
          int.parse(iso.group(3)!));
    }

    final slash = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$').firstMatch(s);
    if (slash != null) {
      var year = int.parse(slash.group(3)!);
      if (year < 100) {
        // Two-digit years in this data are dates of birth and retirement dates,
        // so the window has to span both sides of 2000. 30 is arbitrary but
        // safe: nobody in service was born after 2030 and nobody retires
        // before 1930.
        year += year < 30 ? 2000 : 1900;
      }
      return _validDate(year, int.parse(slash.group(2)!),
          int.parse(slash.group(1)!));
    }

    final named =
        RegExp(r'^(\d{1,2})[-\s]([A-Za-z]{3,})[-\s](\d{2,4})$').firstMatch(s);
    if (named != null) {
      final month = _monthNumber(named.group(2)!);
      if (month == null) return null;
      var year = int.parse(named.group(3)!);
      if (year < 100) year += year < 30 ? 2000 : 1900;
      return _validDate(year, month, int.parse(named.group(1)!));
    }

    return null;
  }

  /// Reject impossible dates instead of letting DateTime roll them over —
  /// 2026-02-31 would otherwise become the 3rd of March and be stored as fact.
  static String? _validDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (year < 1900 || year > 2100) return null;
    final dt = DateTime(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) return null;
    final mm = month.toString().padLeft(2, '0');
    final dd = day.toString().padLeft(2, '0');
    return '$year-$mm-$dd';
  }

  static int? _monthNumber(String name) {
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun',
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    final key = name.toLowerCase();
    for (var i = 0; i < months.length; i++) {
      if (key.startsWith(months[i])) return i + 1;
    }
    return null;
  }
}
