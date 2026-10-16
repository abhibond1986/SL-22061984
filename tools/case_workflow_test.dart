// Plain-VM tests for lib/services/case_workflow.dart (the closing loop).
//
// Run with:  dart run tools/case_workflow_test.dart

import '../lib/services/case_workflow.dart';

int _pass = 0, _fail = 0;
void ok(bool c, String what) {
  if (c) { _pass++; } else { _fail++; print('FAIL: $what'); }
}

const ladder = ['OPEN', 'INVESTIGATING', 'ACTION TAKEN', 'VERIFIED', 'CLOSED'];
const good = 'Replaced the damaged guard on conveyor 3 and re-briefed the crew.';

const assignee = CaseActor(isAssignee: true, canActPlant: true);
const reporter = CaseActor(isReporter: true, canActPlant: true);
const plantUser = CaseActor(canActPlant: true);
const admin = CaseActor(isAdmin: true);
const outsider = CaseActor();

String? g(String from, String to, CaseActor who,
        {bool assigned = true, String action = good, List<String> l = ladder}) =>
    CaseWorkflow.gate(
        ladder: l, from: from, to: to, who: who,
        hasAssignee: assigned, action: action);

void main() {
  // ── ladder indices ──
  ok(CaseWorkflow.verifyIndex(ladder) == 3, 'verify = VERIFIED');
  ok(CaseWorkflow.actionIndex(ladder) == 2, 'action = ACTION TAKEN');
  ok(CaseWorkflow.sendBackIndex(ladder) == 1, 'send back -> INVESTIGATING');
  const short = ['OPEN', 'INVESTIGATING', 'CLOSED'];
  ok(CaseWorkflow.verifyIndex(short) == 2, 'short: verify = last');
  ok(CaseWorkflow.actionIndex(short) == 2, 'short: no separate submit stage');
  const two = ['OPEN', 'CLOSED'];
  ok(CaseWorkflow.actionIndex(two) == 1 && CaseWorkflow.verifyIndex(two) == 1,
      'two-stage ladder');
  const renamed = ['NEW', 'WIP', 'FIXED', 'DONE'];
  ok(CaseWorkflow.verifyIndex(renamed) == 3, 'renamed: verify = last');
  ok(CaseWorkflow.actionIndex(renamed) == 2, 'renamed: action = stage before');

  // ── corrective action validation (the reported bug) ──
  for (final junk in ['', ' ', '.', '-', 'ok', 'OK.', 'done', 'N/A', 'na',
      'nil', 'Done!', '..........', 'aaaaaaaaaaaaaaaa', 'Action taken',
      'complied', 'fixed']) {
    ok(CaseWorkflow.validateAction(junk) != null, 'rejects "$junk"');
  }
  ok(CaseWorkflow.validateAction('Guard fixed') != null, 'rejects too short');
  ok(CaseWorkflow.validateAction(good) == null, 'accepts a real action');
  ok(CaseWorkflow.validateAction('गार्ड बदल दिया गया और टीम को बताया') == null,
      'accepts Hindi');

  // ── who may move ──
  ok(g('OPEN', 'INVESTIGATING', plantUser) == null, 'plant user may start');
  ok(g('OPEN', 'INVESTIGATING', plantUser, assigned: false) != null,
      'nobody assigned: blocked');
  ok(g('OPEN', 'INVESTIGATING', outsider) != null, 'outsider blocked');
  ok(g('INVESTIGATING', 'ACTION TAKEN', plantUser) != null,
      'plant user cannot submit the action');
  ok(g('INVESTIGATING', 'ACTION TAKEN', reporter) != null,
      'reporter cannot submit the action for the assignee');
  ok(g('INVESTIGATING', 'ACTION TAKEN', assignee, action: 'ok') != null,
      'assignee cannot submit "ok"');
  ok(g('INVESTIGATING', 'ACTION TAKEN', assignee) == null,
      'assignee submits a real action');
  ok(g('ACTION TAKEN', 'VERIFIED', assignee) != null,
      'assignee cannot verify own work');
  ok(g('ACTION TAKEN', 'VERIFIED', plantUser) != null,
      'plant user cannot verify');
  ok(g('ACTION TAKEN', 'VERIFIED', reporter) == null, 'reporter verifies');
  ok(g('VERIFIED', 'CLOSED', reporter) == null, 'reporter closes');
  ok(g('VERIFIED', 'CLOSED', assignee) != null, 'assignee cannot close');
  ok(g('VERIFIED', 'CLOSED', reporter, action: '') != null,
      'no action recorded: cannot close');
  ok(g('VERIFIED', 'CLOSED', admin) == null, 'admin override');
  ok(g('OPEN', 'CLOSED', admin) != null, 'stages cannot be skipped');
  ok(g('CLOSED', 'OPEN', admin) != null, 'no backwards via gate');
  ok(g('INVESTIGATING', 'CLOSED', reporter, l: short) == null,
      'short ladder: reporter closes');
  ok(g('INVESTIGATING', 'CLOSED', assignee, l: short) != null,
      'short ladder: assignee cannot close');

  // ── editing / send back ──
  ok(CaseWorkflow.mayEditAction(ladder, 'INVESTIGATING', assignee),
      'assignee edits before submit');
  ok(!CaseWorkflow.mayEditAction(ladder, 'ACTION TAKEN', assignee),
      'locked after submit');
  ok(!CaseWorkflow.mayEditAction(ladder, 'INVESTIGATING', reporter),
      'reporter does not write the action');
  ok(CaseWorkflow.mayEditAction(short, 'INVESTIGATING', assignee),
      'short ladder: assignee records via Save');
  ok(CaseWorkflow.maySendBack(ladder, 'ACTION TAKEN', reporter),
      'reporter may send back');
  ok(CaseWorkflow.maySendBack(ladder, 'VERIFIED', reporter),
      'reporter may send back after verifying');
  ok(!CaseWorkflow.maySendBack(ladder, 'INVESTIGATING', reporter),
      'nothing to send back yet');
  ok(!CaseWorkflow.maySendBack(ladder, 'CLOSED', reporter), 'closed is closed');
  ok(!CaseWorkflow.maySendBack(ladder, 'ACTION TAKEN', assignee),
      'assignee cannot send back');

  // ── identity ──
  final inc = <String, dynamic>{
    'assignedTo': 'a000168', 'reportedByPno': '123456', 'reportedBy': 'R Das'};
  ok(CaseWorkflow.isAssignee({'username': 'A000168'}, inc), 'assignee by username');
  ok(!CaseWorkflow.isAssignee({'username': 'x'}, inc), 'not assignee');
  ok(CaseWorkflow.isReporter({'pno': '123456'}, inc), 'reporter by pno');
  ok(!CaseWorkflow.isReporter({'pno': '999', 'name': 'R Das'}, inc),
      'pno mismatch beats name');

  // ── history ──
  final c = <String, dynamic>{};
  CaseWorkflow.log(c, user: {'username': 'u1', 'name': 'Ravi', 'pno': '42'},
      event: 'submitted', role: 'Action owner', to: 'ACTION TAKEN', note: good);
  c['actionLog'] = '[{"event":"assigned","to":"Ravi","byName":"Sita"}]';
  CaseWorkflow.log(c, user: {'username': 's'}, event: 'closed');
  final t = CaseWorkflow.trail(c);
  ok(t.length == 2, 'string form parsed and appended');
  ok(CaseWorkflow.describe(t.first) == 'Assigned to Ravi', 'describe');
  ok(CaseWorkflow.who({'byName': 'Ravi', 'byPno': '42', 'role': 'Reporter'}) ==
      'Ravi (P.No 42), Reporter', 'who');

  print('case_workflow_test: $_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail failures');
}
