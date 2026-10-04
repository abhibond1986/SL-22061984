// lib/services/incident_assign.dart
// SAIL Safety Lens — assign (or hand over) the person responsible for
// implementing the corrective action on an incident.
//
// ★ 2026-10-04. Assignment used to live only inside IncidentDetailScreen, so a
// supervisor working down the Log had to open every case to put a name on it,
// and nothing stopped a case being moved to "Investigating"/"Action taken" with
// nobody responsible. This file is the single implementation used by BOTH the
// log row's "Assign" button and the detail screen, so the plant rule
// (AssignScope), the permission gate (PlantScope.canActOn), the stored fields
// and the audit entry can never differ between the two entry points.
//
// Stored fields are unchanged (assignedTo / assignedToName / assignedAt), so
// AssignmentInbox keeps notifying the assignee with no migration.

import 'package:flutter/material.dart';

import '../widgets/user_picker.dart';
import 'admin_audit.dart';
import 'assign_scope.dart';
import 'local_db.dart';
import 'plant_scope.dart';
import 'sync_service.dart';

enum AssignOutcome { assigned, cleared, cancelled, denied, failed }

class AssignResult {
  final AssignOutcome outcome;
  final String message;
  const AssignResult(this.outcome, this.message);
  bool get changed =>
      outcome == AssignOutcome.assigned || outcome == AssignOutcome.cleared;
}

class IncidentAssign {
  IncidentAssign._();

  /// True when [inc] has somebody responsible for the corrective action.
  static bool hasAssignee(Map<String, dynamic> inc) =>
      (inc['assignedTo']?.toString().trim() ?? '').isNotEmpty;

  /// Display name of the assignee, or '' when unassigned.
  static String assigneeName(Map<String, dynamic> inc) {
    final n = inc['assignedToName']?.toString().trim() ?? '';
    if (n.isNotEmpty) return n;
    return inc['assignedTo']?.toString().trim() ?? '';
  }

  /// Open the employee picker and save the choice onto [inc] (mutated in
  /// place), locally and to the server, with an audit entry.
  ///
  /// [beforeSave] lets the caller copy un-saved form fields onto [inc] first,
  /// so assigning never discards a half-written corrective action.
  /// [allowClear] is false when the caller REQUIRES an assignee (advancing a
  /// case into corrective action) — "unassign" is then not a valid answer.
  static Future<AssignResult> pickAndSave(
    BuildContext context,
    Map<String, dynamic> inc, {
    String? title,
    bool allowClear = true,
    VoidCallback? beforeSave,
  }) async {
    final scopeUser = await PlantScope.forUser();
    if (!await scopeUser.canActOn(inc)) {
      return const AssignResult(AssignOutcome.denied,
          'You can only assign incidents of your own plant.');
    }
    if (!context.mounted) {
      return const AssignResult(AssignOutcome.cancelled, '');
    }

    final current = inc['assignedTo']?.toString().trim() ?? '';
    // Who is eligible is a property of the CASE — see AssignScope.
    final scope = await AssignScope.forIncident(inc);
    if (!context.mounted) {
      return const AssignResult(AssignOutcome.cancelled, '');
    }
    final picked = await showUserPicker(
      context,
      title: title ??
          (current.isEmpty
              ? 'Assign corrective action to'
              : 'Transfer corrective action'),
      currentUsername: current.isEmpty ? null : current,
      allowClear: allowClear && current.isNotEmpty,
      scope: scope,
    );
    if (picked == null) {
      return const AssignResult(AssignOutcome.cancelled, '');
    }

    if (picked.cleared) {
      inc.remove('assignedTo');
      inc.remove('assignedToName');
      inc.remove('assignedAt');
    } else {
      if (picked.username.isEmpty) {
        return const AssignResult(
            AssignOutcome.failed, 'That employee has no username on file.');
      }
      inc['assignedTo'] = picked.username;
      // Stored so the log row / card can show a name offline.
      inc['assignedToName'] = picked.displayName;
      inc['assignedAt'] = DateTime.now().toIso8601String();
    }

    beforeSave?.call();
    try {
      await LocalDB.saveIncident(inc);
    } catch (e) {
      return AssignResult(AssignOutcome.failed, 'Could not save: $e');
    }
    SyncService.pushIncident(inc).catchError((_) => false);

    try {
      final actor = (await LocalDB.getCurrentUser())?['username']?.toString() ??
          'unknown';
      await AdminAudit.log(
        action: AdminAudit.actIncAssign,
        actor: actor,
        target: inc['id']?.toString(),
        targetName: inc['title']?.toString(),
        meta: {
          'from': current.isEmpty ? '(unassigned)' : current,
          'to': picked.cleared ? '(unassigned)' : picked.username,
        },
      );
    } catch (_) {
      // The assignment is saved; a failed audit write must not undo it.
    }

    return picked.cleared
        ? const AssignResult(AssignOutcome.cleared, 'Assignment removed')
        : AssignResult(
            AssignOutcome.assigned, 'Assigned to ${picked.displayName}');
  }
}
