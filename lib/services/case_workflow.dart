// lib/services/case_workflow.dart
// SAIL Safety Lens — the closing loop for an assigned Near Miss / MAMR case.
//
// ★ 2026-10-16. Before this file, the only rule on the way to CLOSED was "the
// corrective-action box is not empty", and it applied to the final stage only.
// So, once a case was assigned:
//
//   • ANY user of the plant (not just the assignee) could drive it, stage by
//     stage, to the end;
//   • "Action Taken" and "Verified" could be reached with nothing written;
//   • the box accepted ".", "ok", "-" and "done";
//   • the person who did the work could also verify and close it;
//   • nothing recorded who moved the case, when, or what they wrote, so a
//     closed case could not be checked against its action later.
//
// The loop the user asked for (2026-10-16):
//
//   1. The case is assigned (anyone who may act on the plant's cases).
//   2. The ASSIGNEE (or the MAMR responsible person) writes the corrective
//      action, may attach a photo, and submits it ("Action Taken").
//   3. The person who REPORTED the observation verifies and closes it, or sends
//      it back with a reason. Nobody else does, apart from an admin override,
//      which the history records as such.
//
// Every move is appended to `actionLog`, the dated history the PDF prints.
//
// Pure Dart (only mamr_core, itself pure) so tools/case_workflow_test.dart can
// run on the plain VM. Stage names come from the admin's ladder; nothing here
// assumes the literal 'CLOSED'.

import 'dart:convert';

import 'mamr_core.dart';

/// Who the current user is, relative to ONE case.
class CaseActor {
  final bool isAdmin;
  final bool isAssignee;   // assignedTo, or an MAMR responsible person
  final bool isReporter;   // filed the observation
  final bool canActPlant;  // PlantScope.canActOn — same-plant user
  const CaseActor({
    this.isAdmin = false,
    this.isAssignee = false,
    this.isReporter = false,
    this.canActPlant = false,
  });

  /// The role written into the history.
  String get role => isAssignee
      ? 'Action owner'
      : isReporter
          ? 'Reporter'
          : isAdmin
              ? 'Admin'
              : 'Supervisor';
}

class CaseWorkflow {
  CaseWorkflow._();

  // ── The ladder ─────────────────────────────────────────────────────────

  static String _u(String s) => s.trim().toUpperCase();

  static int indexOf(List<String> ladder, String status) {
    final s = _u(status);
    for (var i = 0; i < ladder.length; i++) {
      if (_u(ladder[i]) == s) return i;
    }
    return -1;
  }

  /// First stage owned by the VERIFIER (the reporter). 'VERIFIED' when the
  /// admin still has it in the middle of the ladder, otherwise the final stage.
  static int verifyIndex(List<String> ladder) {
    if (ladder.isEmpty) return -1;
    final last = ladder.length - 1;
    final v = indexOf(ladder, 'VERIFIED');
    return (v > 0 && v < last) ? v : last;
  }

  /// The stage at which the assignee SUBMITS the corrective action. 'ACTION
  /// TAKEN' when present before the verify stage; otherwise the stage just
  /// before it, provided that leaves a separate investigation stage. When the
  /// ladder is too short for a submit stage this equals [verifyIndex]: the
  /// assignee then records the action with "Save" and the reporter closes.
  static int actionIndex(List<String> ladder) {
    final v = verifyIndex(ladder);
    if (v < 0) return -1;
    final a = indexOf(ladder, 'ACTION TAKEN');
    if (a > 0 && a < v) return a;
    return v - 1 >= 2 ? v - 1 : v;
  }

  static bool isFinal(List<String> ladder, String status) =>
      ladder.isNotEmpty && _u(status) == _u(ladder.last);

  /// The stage a "send back" returns the case to: the one before the submit
  /// stage (normally INVESTIGATING), never the first rung.
  static int sendBackIndex(List<String> ladder) {
    final a = actionIndex(ladder);
    if (a < 0) return -1;
    final b = a - 1;
    return b >= 1 ? b : (ladder.length > 1 ? 1 : 0);
  }

  // ── The corrective action itself ───────────────────────────────────────

  static const int minActionChars = 15;

  /// Words that are not an action. Compared after stripping punctuation.
  static const Set<String> _placeholders = {
    'na', 'n a', 'nil', 'none', 'no', 'ok', 'okay', 'done', 'closed', 'close',
    'yes', 'test', 'testing', 'action taken', 'taken', 'completed', 'complete',
    'noted', 'will do', 'tbd', 'pending', 'nothing', 'xyz', 'abc', 'asdf',
    'corrective action', 'action', 'same', 'as above', 'resolved', 'fixed',
    'work done', 'job done', 'complied', 'compliance done',
  };

  /// Null when [text] describes an action; otherwise the reason it does not.
  static String? validateAction(String text) {
    final t = text.trim();
    if (t.isEmpty) return 'Write the corrective action that was taken.';
    final bare = t
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9ऀ-ॿ ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (bare.isEmpty || _placeholders.contains(bare)) {
      return '"$t" is not a corrective action. Say what was done, '
          'where, and by whom.';
    }
    // A run of one character ("........", "aaaaaaaa") is not text either.
    if (RegExp(r'^(.)\1*$').hasMatch(bare.replaceAll(' ', ''))) {
      return 'Write the corrective action that was taken.';
    }
    if (t.runes.length < minActionChars) {
      return 'The corrective action is too short. Describe what was done '
          '(at least $minActionChars characters).';
    }
    return null;
  }

  // ── Who may do what ────────────────────────────────────────────────────

  /// May this actor edit the corrective action / photo / target date now?
  /// Only the action owner (or admin), and only until the action is submitted.
  /// After a send-back the case is below the submit stage again, so it reopens.
  static bool mayEditAction(
      List<String> ladder, String status, CaseActor who) {
    if (!(who.isAssignee || who.isAdmin)) return false;
    final cur = _curIndex(ladder, status);
    final a = actionIndex(ladder), v = verifyIndex(ladder);
    if (a < 0) return false;
    return cur < a || (a == v && cur < v);
  }

  /// May this actor send the case back to the action owner?
  static bool maySendBack(List<String> ladder, String status, CaseActor who) {
    if (!(who.isReporter || who.isAdmin)) return false;
    if (isFinal(ladder, status)) return false;
    final cur = _curIndex(ladder, status);
    final a = actionIndex(ladder);
    return a >= 0 && cur >= a;
  }

  static int _curIndex(List<String> ladder, String status) {
    final i = indexOf(ladder, status);
    // A blank or off-ladder status is treated as the first rung, as the
    // detail screen already does.
    return i < 0 ? 0 : i;
  }

  /// Null when [who] may move the case from [from] to [to]; otherwise the
  /// reason they may not. [hasAssignee] and [action] are the case's current
  /// values (including unsaved text in the form).
  static String? gate({
    required List<String> ladder,
    required String from,
    required String to,
    required CaseActor who,
    required bool hasAssignee,
    required String action,
  }) {
    if (ladder.isEmpty) return 'No status ladder is configured.';
    final t = indexOf(ladder, to);
    if (t < 0) return '"$to" is not a stage in the status list.';
    final cur = _curIndex(ladder, from);
    if (t <= cur) return 'Use "Send back" to return a case.';
    if (t > cur + 1) return 'Stages cannot be skipped.';
    if (t >= 1 && !hasAssignee) return 'Assign a person for the corrective action first.';

    final a = actionIndex(ladder), v = verifyIndex(ladder);

    if (t >= v) {
      // Verification / closure: the reporter's call.
      if (!(who.isReporter || who.isAdmin)) {
        return 'Only the person who reported this observation can verify '
            'and close it.';
      }
      final bad = validateAction(action);
      if (bad != null) {
        return 'The action owner has not recorded a valid corrective action '
            'yet. Send it back instead.';
      }
      return null;
    }
    if (t >= a) {
      // Submitting the corrective action: the action owner's job.
      if (!(who.isAssignee || who.isAdmin)) {
        return 'Only the person assigned to this case can submit the '
            'corrective action.';
      }
      return validateAction(action);
    }
    // Early stages (e.g. Investigating): whoever may work the plant's cases.
    if (!(who.canActPlant || who.isAssignee || who.isAdmin || who.isReporter)) {
      return 'You can only update incidents of your own plant.';
    }
    return null;
  }

  /// Whether the button for [to] should be offered to [who] at all. The
  /// content checks (assignee present, action written) are left to [gate] at
  /// tap time, where they can say what is missing.
  static bool roleMayMove(
          List<String> ladder, String from, String to, CaseActor who) =>
      gate(
        ladder: ladder, from: from, to: to, who: who,
        hasAssignee: true,
        action: 'A sufficiently long corrective action text',
      ) ==
      null;

  /// Which button label the UI should show for moving into [to].
  static String verbFor(List<String> ladder, String to) {
    final t = indexOf(ladder, to);
    final a = actionIndex(ladder), v = verifyIndex(ladder);
    if (t == ladder.length - 1) return 'Verify & close';
    if (t >= v) return 'Verify action';
    if (t >= a) return 'Submit action';
    return '';
  }

  // ── Identity ───────────────────────────────────────────────────────────

  static Set<String> _ids(Map<String, dynamic>? user) {
    if (user == null) return {};
    return {
      for (final k in const ['username', 'pno'])
        if ((user[k]?.toString().trim() ?? '').isNotEmpty)
          user[k].toString().trim().toLowerCase(),
    };
  }

  static bool isAssignee(Map<String, dynamic>? user, Map<String, dynamic> inc) {
    if (user == null) return false;
    final ids = _ids(user);
    final a = inc['assignedTo']?.toString().trim().toLowerCase() ?? '';
    if (a.isNotEmpty && ids.contains(a)) return true;
    return MamrObs.isMamr(inc) &&
        MamrObs.isResponsible(inc, ids, user['mobile']?.toString() ?? '');
  }

  static bool isReporter(Map<String, dynamic>? user, Map<String, dynamic> inc) =>
      MamrObs.isReporter(user, inc);

  // ── History ────────────────────────────────────────────────────────────

  /// The stored history, oldest first. Tolerates the JSON-string form that a
  /// round trip through SharedPreferences or Sheets leaves.
  static List<Map<String, dynamic>> trail(Map<String, dynamic> inc) {
    var v = inc['actionLog'];
    if (v is String && v.trim().isNotEmpty) {
      try { v = jsonDecode(v); } catch (_) { return []; }
    }
    if (v is! List) return [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Append one entry to `inc['actionLog']` (in place).
  static void log(
    Map<String, dynamic> inc, {
    required Map<String, dynamic>? user,
    required String event,
    String role = '',
    String from = '',
    String to = '',
    String note = '',
    DateTime? at,
  }) {
    final list = trail(inc);
    final name = user?['name']?.toString().trim() ?? '';
    final pno = user?['pno']?.toString().trim() ?? '';
    final desig = user?['designation']?.toString().trim() ?? '';
    list.add({
      'at': (at ?? DateTime.now()).toIso8601String(),
      'event': event,
      'by': user?['username']?.toString().trim() ?? '',
      'byName': name.isEmpty ? (user?['username']?.toString() ?? '') : name,
      if (pno.isNotEmpty) 'byPno': pno,
      if (desig.isNotEmpty) 'byDesignation': desig,
      if (role.isNotEmpty) 'role': role,
      if (from.isNotEmpty) 'from': from,
      if (to.isNotEmpty) 'to': to,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    });
    inc['actionLog'] = list;
  }

  /// One line for a history entry, as printed in the app and the PDF.
  static String describe(Map<String, dynamic> e) {
    final ev = e['event']?.toString() ?? '';
    final to = e['to']?.toString() ?? '';
    final from = e['from']?.toString() ?? '';
    switch (ev) {
      case 'assigned':   return 'Assigned to $to';
      case 'transferred':return 'Transferred from $from to $to';
      case 'unassigned': return 'Assignment removed';
      case 'stage':      return 'Moved to $to';
      case 'submitted':  return 'Corrective action submitted';
      case 'verified':   return 'Action verified';
      case 'closed':     return 'Verified and closed';
      case 'sent_back':  return 'Sent back to the action owner';
      case 'photo':      return 'Photo of the action attached';
      case 'saved':      return 'Corrective action updated';
      case 'closed_on_spot': return 'Closed on the spot by the reporter';
      case 'bulk_closed':return 'Closed by admin (bulk)';
      default:           return to.isEmpty ? ev : '$ev: $to';
    }
  }

  /// Who made an entry, e.g. "R. Sharma (P.No 123456), Action owner".
  static String who(Map<String, dynamic> e) {
    final n = e['byName']?.toString().trim() ?? '';
    final p = e['byPno']?.toString().trim() ?? '';
    final r = e['role']?.toString().trim() ?? '';
    final base = p.isEmpty ? n : '$n (P.No $p)';
    return r.isEmpty ? base : '$base, $r';
  }

  /// "Name (P.No x)" for the verifier fields.
  static String signature(Map<String, dynamic>? user) {
    final n = user?['name']?.toString().trim() ?? '';
    final p = user?['pno']?.toString().trim() ?? '';
    final d = user?['designation']?.toString().trim() ?? '';
    final head = n.isEmpty ? (user?['username']?.toString() ?? '') : n;
    return [
      p.isEmpty ? head : '$head (P.No $p)',
      if (d.isNotEmpty) d,
    ].join(', ');
  }
}
