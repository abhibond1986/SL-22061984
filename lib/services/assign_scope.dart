// lib/services/assign_scope.dart
// SAIL Safety Lens — who may be handed a given investigation.
//
// THE RULE
// A case can only be assigned to somebody from the plant that owns the case.
// A BSP hazard goes to BSP personnel whoever is doing the assigning, so
// accountability stays attached to the record rather than to whoever happened to
// open it. There is one exception: SSO Ranchi — the SAIL Safety Organisation —
// is the corporate safety body, and its cases may be assigned to anyone in the
// company.
//
// The rule is keyed to the CASE, not to the signed-in user. That is the whole
// point: a head-office admin working through a queue of other plants' cases is
// the person most likely to hand a Durgapur job to a Bhilai engineer by mistake,
// and keying off their own plant would leave that mistake possible.
//
// It is enforced where the choice is made — the employee picker cannot offer
// somebody from the wrong plant — rather than by validating after the fact. A
// dialog that lets you pick a name and then refuses it wastes the search and
// teaches nothing about why.
//
// SCOPE OF THE RULE
// New assignments only. Assignments already recorded across plants keep working
// and are not flagged: the rule is about who work is given to next, and quietly
// invalidating live investigations would strand them. The person holding such a
// case still sees it on their home screen and can still close it.
//
// A case whose plant cannot be resolved against the active plant master is
// UNRESTRICTED. Failing open is deliberate — a hazard with a mistyped plant name
// must still be assignable to somebody today, and the alternative is an empty
// picker on a case nobody can then action.

import 'admin_master_data.dart';

class AssignScope {
  /// The resolved plant entry that owns the case, or null when the case's plant
  /// could not be matched to the active plant master.
  final Map<String, String>? plant;

  /// False when anyone may be assigned: an SSO Ranchi case, or an unresolvable
  /// plant. Callers should not need to ask why — [note] says so in words.
  final bool restricted;

  /// ILIKE terms for [SupabaseService.searchUsers], narrowing the query to this
  /// plant. Empty when unrestricted.
  final List<String> terms;

  const AssignScope._({
    required this.plant,
    required this.restricted,
    required this.terms,
  });

  const AssignScope.unrestricted()
      : plant = null,
        restricted = false,
        terms = const <String>[];

  /// Plant code, for comparing plants without ever comparing spellings.
  String get code => (plant?['code'] ?? '').toUpperCase();

  /// Human label for the plant, e.g. 'Durgapur Steel Plant'.
  String get label => (plant?['name'] ?? '').trim();

  /// The line shown in the picker so the restriction is visible rather than
  /// mysterious. An empty result list with no explanation is the single most
  /// confusing thing a filter like this can do.
  String get note => restricted
      ? 'Only $label personnel can be assigned this case.'
      : '';

  /// Plant codes that may assign across the whole company.
  ///
  /// SSO is the SAIL Safety Organisation at Ranchi. Kept as a code, not a name,
  /// because the admin can rename a plant but the code is what the rest of the
  /// app joins on.
  static const Set<String> _crossPlantCodes = {'SSO'};

  /// Work out the scope for one incident.
  ///
  /// Reads the ACTIVE plant list, not the hardcoded one, so a plant the admin
  /// has renamed or added still resolves.
  static Future<AssignScope> forIncident(
      Map<String, dynamic>? incident) async {
    final raw = incident?['plant']?.toString().trim() ?? '';
    if (raw.isEmpty) return const AssignScope.unrestricted();

    List<Map<String, String>> plants;
    try {
      plants = await AdminMasterData.getPlants();
    } catch (_) {
      // Master data unreachable. Fail open rather than block all assignment.
      return const AssignScope.unrestricted();
    }
    if (plants.isEmpty) return const AssignScope.unrestricted();

    final entry = AdminMasterData.plantEntryFor(raw, plants);
    if (entry == null) return const AssignScope.unrestricted();

    final code = (entry['code'] ?? '').toUpperCase();
    // The safety organisation assigns anywhere. Also honoured by kind, so an
    // admin who adds a second safety-org entry does not have to change code —
    // but the code check comes first because admin-stored plant rows are not
    // guaranteed to carry a 'kind' at all.
    if (_crossPlantCodes.contains(code) ||
        (entry['kind'] ?? '').toUpperCase() == 'SAFETY') {
      return const AssignScope.unrestricted();
    }

    return AssignScope._(
      plant: entry,
      restricted: true,
      terms: AdminMasterData.plantMatchTerms(entry),
    );
  }

  /// Is this employee eligible?
  ///
  /// THIS is the authority, not the server-side ILIKE narrowing, which is loose
  /// on purpose: '%BSP%' also matches 'BSP Mines'. Resolving the candidate's own
  /// plant to an entry and comparing codes is the only comparison that cannot be
  /// fooled by spelling.
  ///
  /// Falls back to the employee's `unit` when `plant` is blank, because the
  /// quarterly roster carries a UNIT code and the plant is only filled in once
  /// the admin has reconciled that code.
  bool allows(Map<String, dynamic> user, List<Map<String, String>> plants) {
    if (!restricted) return true;
    final mine = code;
    if (mine.isEmpty) return true;
    for (final k in const ['plant', 'unit']) {
      final raw = user[k]?.toString().trim() ?? '';
      if (raw.isEmpty) continue;
      final e = AdminMasterData.plantEntryFor(raw, plants);
      if (e == null) continue;
      return (e['code'] ?? '').toUpperCase() == mine;
    }
    // Neither column resolves to a plant. Excluded: the whole point of the rule
    // is that an assignee's plant is known, and "we could not tell" is not the
    // same as "yes".
    return false;
  }
}
