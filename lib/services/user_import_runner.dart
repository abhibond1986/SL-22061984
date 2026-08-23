// ═══════════════════════════════════════════════════════════════════════════
//  UserImportRunner — execute an approved [ImportPlan].
//
//  The only file in the bulk-import path that writes anything. It is separate
//  from the planner so that the preview an admin approves is produced by code
//  that cannot accidentally have written something already.
//
//  THREE RULES IT ENFORCES, none of which are negotiable
//
//  1. NEW accounts get a credential; EXISTING accounts never do.
//     They are therefore written as two separate batches. That is also a
//     PostgREST requirement — every object in one bulk upsert must carry the
//     same keys, or the request is rejected outright — so the split is both the
//     safe design and the only one that works.
//
//  2. Status is changed only by [SupabaseService.setUsersStatus], one column at
//     a time, and only for people the plan (or the admin) named. A refresh must
//     never re-enable an account somebody deliberately disabled, and must never
//     disable one because a column happened to be blank this quarter.
//
//  3. The roster is NOT mirrored into device storage. ~10,000 accounts is about
//     2.3 MB of JSON, and this app already keeps incidents and photographs in
//     the same browser origin against a ~5 MB budget. Caching the roster here
//     would evict incident reports — the actual product — to speed up a screen
//     that is used once a quarter.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart';

import 'crypto_utils.dart';
import 'supabase_service.dart';
import 'user_import.dart';

/// Progress for the import screen. [stage] is already phrased for the admin.
class ImportProgress {
  const ImportProgress({
    required this.stage,
    required this.done,
    required this.total,
  });
  final String stage;
  final int done;
  final int total;

  /// 0.0–1.0, or null when the total is not yet known (show a spinner).
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

class ImportResult {
  ImportResult({
    required this.created,
    required this.updated,
    required this.disabled,
    required this.skipped,
    required this.errors,
    required this.batchId,
  });

  final int created;
  final int updated;
  final int disabled;
  final int skipped;

  /// Empty on a clean run. Each entry is already readable by an admin.
  final List<String> errors;
  final String batchId;

  bool get ok => errors.isEmpty;

  String get summary {
    final parts = <String>[];
    if (created > 0) parts.add('$created created');
    if (updated > 0) parts.add('$updated updated');
    if (disabled > 0) parts.add('$disabled disabled');
    if (skipped > 0) parts.add('$skipped skipped');
    if (parts.isEmpty) return 'Nothing to import.';
    return parts.join(', ');
  }
}

class UserImportRunner {
  UserImportRunner._();

  /// Rows hashed between yields to the event loop.
  ///
  /// CryptoUtils.hashPassword is pure Dart SHA-256 on the main isolate, and on
  /// web there is no isolate to move it to. 10,000 hashes without yielding
  /// freezes the tab hard enough that the browser offers to kill the page — and
  /// a progress bar that cannot repaint is worse than none, because the admin
  /// cannot tell a slow import from a dead one.
  static const int hashYieldEvery = 200;

  /// Run [plan].
  ///
  /// [deactivate] is the subset of `plan.portalOnly` the admin ticked. Passing
  /// the whole list is allowed but must be an explicit choice made in the UI,
  /// never a default: someone missing from one quarter's export is at least as
  /// likely to be an export glitch as a person who has left.
  static Future<ImportResult> run(
    ImportPlan plan, {
    List<String> deactivate = const <String>[],
    void Function(ImportProgress)? onProgress,
  }) async {
    final errors = <String>[];
    final skipped = plan.invalidCount;

    if (!plan.canRun) {
      // Belt and braces. The UI disables the button, but this is the last point
      // at which a bad plan can be stopped before it touches 10,000 rows.
      return ImportResult(
        created: 0,
        updated: 0,
        disabled: 0,
        skipped: skipped,
        batchId: plan.batchId,
        errors: [
          if (plan.missingColumns.isNotEmpty)
            'The file is missing the ${plan.missingColumns.join(' and ')} '
                'column.',
          if (!plan.rosterKnown)
            'The existing user list could not be read from the server, so new '
                'and existing employees cannot be told apart. Nothing was '
                'changed.',
          if (plan.rows.isEmpty) 'The file contained no importable rows.',
        ],
      );
    }

    final now = DateTime.now().toIso8601String();

    // ── 1. New accounts ─────────────────────────────────────────────────────
    var created = 0;
    final creates = plan.creates.toList(growable: false);
    if (creates.isNotEmpty) {
      onProgress?.call(ImportProgress(
          stage: 'Preparing ${creates.length} new accounts',
          done: 0,
          total: creates.length));

      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < creates.length; i++) {
        final r = creates[i];
        final salt = CryptoUtils.generateSalt();
        rows.add(<String, dynamic>{
          ...r.user,
          // THE ONE FORMAT (see auth_service.dart): salt + sha256(salt+pw),
          // always written together. Never a hash without its salt.
          'salt': salt,
          'passwordHash': CryptoUtils.hashPassword(r.initialPassword, salt),
          // The P.no is public — printed on the ID card, listed in this very
          // spreadsheet. The account is unusable until it is replaced.
          'mustChangePassword': true,
          // Retirees are created already disabled rather than created and then
          // disabled: for a moment in between, a retired person's account would
          // otherwise be live with a password anyone holding the file knows.
          'status': r.retired ? 'disabled' : 'active',
          'isAdmin': false,
          'importedAt': now,
        });
        if (i % hashYieldEvery == hashYieldEvery - 1) {
          onProgress?.call(ImportProgress(
              stage: 'Preparing new accounts',
              done: i + 1,
              total: creates.length));
          await Future<void>.delayed(Duration.zero);
        }
      }

      created = await SupabaseService.upsertUsers(rows,
          onProgress: (done, total) => onProgress?.call(ImportProgress(
              stage: 'Creating accounts', done: done, total: total)));
      if (created < rows.length) {
        errors.add('${rows.length - created} of ${rows.length} new accounts '
            'could not be created. ${SupabaseService.usersLastError}');
      }
    }

    // ── 2. Existing accounts: profile refresh, no credentials ───────────────
    var updated = 0;
    final updates = plan.updates.toList(growable: false);
    if (updates.isNotEmpty) {
      // `importedAt` is set here too, so "when did we last see this person in an
      // export" is answerable for everyone and not only for new joiners.
      final rows = updates
          .map((r) => <String, dynamic>{...r.user, 'importedAt': now})
          .toList(growable: false);
      updated = await SupabaseService.upsertUsers(rows,
          onProgress: (done, total) => onProgress?.call(ImportProgress(
              stage: 'Updating existing accounts', done: done, total: total)));
      if (updated < rows.length) {
        errors.add('${rows.length - updated} of ${rows.length} existing '
            'accounts could not be updated. ${SupabaseService.usersLastError}');
      }
    }

    // ── 3. Disable retirees, then whoever the admin ticked ──────────────────
    //
    // Both go through setUsersStatus, which writes `status` and nothing else.
    // Retirees who are being created were already inserted as disabled, so only
    // existing accounts need this pass — but sending all of them is harmless and
    // makes the outcome the same whichever order the file is imported in.
    var disabled = 0;
    final toDisable = <String>{
      ...plan.retiredUsernames,
      ...deactivate.map((u) => u.trim().toLowerCase()).where((u) => u.isNotEmpty),
    }.toList();

    if (toDisable.isNotEmpty) {
      onProgress?.call(ImportProgress(
          stage: 'Disabling ${toDisable.length} accounts',
          done: 0,
          total: toDisable.length));
      disabled = await SupabaseService.setUsersStatus(toDisable, 'disabled');
      if (disabled < toDisable.length) {
        // Reported, not fatal. The profiles landed; a retirement date that did
        // not take effect is something the admin must know about, because it
        // means someone who has left can still sign in.
        errors.add('${toDisable.length - disabled} of ${toDisable.length} '
            'accounts could not be disabled — retired employees may still be '
            'able to sign in. ${SupabaseService.usersLastError}');
      }
    }

    onProgress?.call(ImportProgress(
        stage: 'Finished', done: 1, total: 1));

    debugPrint('[UserImport] batch=${plan.batchId} created=$created '
        'updated=$updated disabled=$disabled skipped=$skipped '
        'errors=${errors.length}');

    return ImportResult(
      created: created,
      updated: updated,
      disabled: disabled,
      skipped: skipped,
      errors: errors,
      batchId: plan.batchId,
    );
  }

  /// A CSV of every row the import refused or altered, for the admin to fix in
  /// the source file before next quarter.
  ///
  /// Offered as a download rather than a dialog because at 10,000 rows the
  /// interesting subset can still be dozens of lines, and a list an admin has to
  /// scroll past to dismiss gets dismissed unread.
  static String problemReportCsv(ImportPlan plan) {
    final sb = StringBuffer('Row,P.No,Name,Outcome,Details\r\n');
    for (final r in plan.rows) {
      if (r.problems.isEmpty && r.warnings.isEmpty) continue;
      final outcome = r.action == ImportAction.invalid ? 'SKIPPED' : 'IMPORTED';
      final details = [...r.problems, ...r.warnings].join(' ');
      sb.write('${r.rowNumber},'
          '${_csv(r.pno)},'
          '${_csv(r.user['name']?.toString() ?? '')},'
          '$outcome,'
          '${_csv(details)}\r\n');
    }
    return sb.toString();
  }

  /// Quote per RFC 4180. Names in this data contain commas ("KUMAR, R"), and an
  /// unquoted one would shift every following column of the report.
  static String _csv(String v) {
    const q = '"';
    if (!v.contains(',') && !v.contains(q) && !v.contains('\n')) return v;
    final escaped = v.replaceAll(q, '$q$q');
    return '$q$escaped$q';
  }
}
