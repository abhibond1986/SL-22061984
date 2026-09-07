// lib/services/plant_scope.dart
//
// ONE answer to the question "which plant's data may this user see?"
//
// Why this file exists: every analytics screen answered that question its own
// way, and all of them answered "all plants". incident_log_tab defaulted its
// plant filter to 'All', data_analysis_tab used null-means-all, plant_wise_tab
// defaulted to the alphabetically-first plant FOUND IN THE DATA (not the user's
// own), home_tab and overview_tab applied no plant filter at all, and
// dashboard_tab matched plants with substring `contains()` — which mis-buckets
// "BSP" into "BSP_MINES". A plant user could see, and close, another plant's
// incidents.
//
// Every plant-scoped screen must go through PlantScope so that behaviour is
// defined in one place and stays consistent.

import 'admin_master_data.dart';
import 'local_db.dart';

/// The resolved data-visibility scope for the signed-in user.
class PlantScope {
  /// Canonical plant label ("BSP — Bhilai Steel Plant") the user is locked to.
  /// Empty when the user isn't tied to a single plant (admins, org-level users,
  /// or a profile with no usable plant).
  final String plant;

  /// True when this user may see every plant — admins and org-level users.
  final bool seesAllPlants;

  /// Set when the user *should* be locked to a plant but we couldn't work out
  /// which one. The UI must show this rather than silently falling back to
  /// showing everything: quietly widening a user's visibility is the failure
  /// mode we're removing.
  final String? problem;

  const PlantScope({
    required this.plant,
    required this.seesAllPlants,
    this.problem,
  });

  /// True when the view should be pinned to [plant] with no plant selector.
  bool get isLocked => !seesAllPlants && plant.isNotEmpty;

  /// Plant labels this user may choose between. A locked user gets exactly
  /// one — their own — so callers can build a dropdown uniformly without
  /// special-casing, and an "All" option is simply never offered to them.
  Future<List<String>> selectablePlants() async {
    if (!seesAllPlants) return plant.isEmpty ? const [] : [plant];
    return AdminMasterData.getPlantLabels();
  }

  /// Plant designations that mean "not a single operating plant". A user whose
  /// profile says one of these is org-level, so locking them to it would show
  /// an empty dashboard — e.g. the admin user's plant, or "ALL"/"OTHERS".
  static const Set<String> orgLevelPlants = {
    'ALL',
    'OTHERS',
    'OTHER',
  };

  /// Resolve the scope for [user] (defaults to the signed-in user).
  ///
  /// Admin detection reads the `isAdmin` field ONLY. It is deliberately not the
  /// designation-string heuristic dashboard_tab used
  /// (`desig.contains('manager') || contains('gm') || ...`), because that let
  /// anyone who typed "Manager" into their own registration form grant
  /// themselves org-wide visibility. isAdmin is set by the admin panel.
  ///
  /// The field is stored inconsistently across the codebase — a real bool when
  /// seeded, the STRING 'false' at registration, 'true'/'false' when toggled by
  /// an admin — so it is compared as a string.
  static Future<PlantScope> forUser([Map<String, dynamic>? user]) async {
    final u = user ?? await LocalDB.getCurrentUser();
    if (u == null) {
      return const PlantScope(
        plant: '',
        seesAllPlants: false,
        problem: 'Not signed in — no plant data available.',
      );
    }

    if (isAdminUser(u)) {
      return const PlantScope(plant: '', seesAllPlants: true);
    }

    final raw = (u['plant']?.toString() ?? '').trim();
    if (raw.isEmpty) {
      return const PlantScope(
        plant: '',
        seesAllPlants: false,
        problem: 'Your profile has no plant set, so plant data cannot be '
            'shown. Ask the safety admin to set your plant.',
      );
    }

    if (orgLevelPlants.contains(raw.toUpperCase())) {
      // Org-level, not a shop floor — show everything rather than an empty page.
      return const PlantScope(plant: '', seesAllPlants: true);
    }

    final canon = await AdminMasterData.canonicalPlant(raw);
    if (canon.isEmpty) {
      // canonicalPlant() falls back to the cleaned original, so an empty result
      // really does mean "nothing usable in the profile".
      return PlantScope(
        plant: '',
        seesAllPlants: false,
        problem: 'Your plant ("$raw") does not match any plant configured by '
            'the admin, so plant data cannot be shown.',
      );
    }
    return PlantScope(plant: canon, seesAllPlants: false);
  }

  /// Whether [user] is an administrator. Single definition — see [forUser].
  static bool isAdminUser(Map<String, dynamic> user) =>
      (user['isAdmin']?.toString().toLowerCase() ?? 'false') == 'true';

  /// Keep only the incidents this scope may see.
  ///
  /// Uses [AdminMasterData.canonicalPlantFrom] rather than string equality or
  /// `contains`, because the same plant appears in stored records as "DSP",
  /// "DSP Durgapur" and "Durgapur Steel Plant". The plant list is fetched once
  /// and reused for the whole list — canonicalising per record would re-read
  /// SharedPreferences thousands of times.
  /// ★ 2026-09-07: a record whose plant cannot be resolved is now shown to
  /// everyone in scope instead of to nobody.
  ///
  /// Two rows in the live table carry `plant: ""`. Under the old rule they were
  /// visible only to admins — so a report could sync correctly to every device
  /// and still be invisible on all of them, including to the person who filed
  /// it. Hiding a safety report is the worse error of the two available: the
  /// cost of showing it slightly too widely is that someone reads a report from
  /// another plant, while the cost of hiding it is that a hazard goes unread.
  ///
  /// This is a bridge for existing data, not a permanent policy. New records get
  /// the reporter's plant stamped at save time in `LocalDB.saveIncident`, so the
  /// unresolved set can only shrink; [countUnscoped] is what the admin panel
  /// uses to say how many are left to fix.
  ///
  /// Note the deliberate asymmetry with [canActOn], which is NOT relaxed: seeing
  /// an unscoped report is harmless, whereas being able to close another plant's
  /// report is the authorisation hole this class was written to remove.
  /// ★ 2026-09-07 (second half of the same bug): plants are compared by CODE,
  /// not by canonical label.
  ///
  /// `canonicalPlantFrom` returns 'SSO Ranchi' for the name and 'SSO — SSO
  /// Ranchi' for the code — two different strings for ONE plant, as
  /// [AdminMasterData.plantEntryFor]'s own doc comment warns. This method
  /// compared those strings, so a user whose profile says "SSO" could not see a
  /// report stored as "SSO Ranchi". The live table contains both spellings, and
  /// this is the failure that looks exactly like "my report didn't sync": the row
  /// is on the device and on the server, and the filter drops it on the way to
  /// the screen. Resolving both sides to a plant ENTRY and comparing codes is
  /// what that helper exists for.
  Future<List<Map<String, dynamic>>> filterIncidents(
      List<Map<String, dynamic>> incidents) async {
    if (seesAllPlants) return incidents;
    final plants = await AdminMasterData.getPlants();
    final mine = AdminMasterData.plantEntryFor(plant, plants);
    final myCode = (mine?['code'] ?? '').toUpperCase();
    // An unresolved viewer scope (no plant on the profile, or one that matches
    // no configured plant) used to show nothing at all. It now shows the
    // unscoped records, which is the honest intersection of "we don't know where
    // this user belongs" and "we don't know where this record belongs" — and the
    // UI already surfaces [problem] telling them to get their profile fixed.
    return incidents.where((i) {
      final raw = i['plant']?.toString() ?? '';
      final entry = AdminMasterData.plantEntryFor(raw, plants);
      if (entry == null) {
        // Either genuinely blank, or a spelling no configured plant matches.
        // Both are unresolved records and both are now visible to everyone —
        // see countUnscoped for how the admin gets told to fix them.
        return true;
      }
      if (myCode.isNotEmpty) {
        return (entry['code'] ?? '').toUpperCase() == myCode;
      }
      // Viewer's own plant didn't resolve to a configured entry. Fall back to
      // the label comparison rather than showing everything: a scope we can't
      // resolve must not silently widen, which is this class's whole purpose.
      return plant.isNotEmpty &&
          AdminMasterData.canonicalPlantFrom(raw, plants) == plant;
    }).toList();
  }

  /// How many of [incidents] have no resolvable plant.
  ///
  /// Surfaced in the admin panel so the blank-plant rows get corrected rather
  /// than living forever behind the tolerance above.
  /// Must use the SAME test as [filterIncidents] — `plantEntryFor` returning
  /// null — not `canonicalPlantFrom(...).isEmpty`. Those differ: canonicalisation
  /// falls back to the cleaned original, so a row reading "Foobar Plant" produces
  /// a non-empty label and would be counted as scoped while the filter treats it
  /// as unresolved and shows it to everyone. The count exists to tell the admin
  /// how many rows are leaking across plants, so it has to count exactly those.
  static Future<int> countUnscoped(
      List<Map<String, dynamic>> incidents) async {
    final plants = await AdminMasterData.getPlants();
    return incidents
        .where((i) =>
            AdminMasterData.plantEntryFor(i['plant']?.toString() ?? '', plants) ==
            null)
        .length;
  }

  /// Departments actually present in [incidents], intersected with the admin's
  /// configured department list and ordered to match it.
  ///
  /// Departments in AdminMasterData are GLOBAL — there is no plant→department
  /// mapping in the data — so "departments of this plant" can only be derived
  /// from what that plant has actually reported. A department the admin has
  /// deleted is excluded even if old records still reference it, because the
  /// admin panel is authoritative; and if the admin has deleted every
  /// department the result is empty, which callers must render as empty rather
  /// than falling back to a built-in list.
  static Future<List<String>> departmentsIn(
      List<Map<String, dynamic>> incidents) async {
    final configured = await AdminMasterData.getDepartments();
    if (configured.isEmpty) return const [];
    final present = incidents
        .map((i) => (i['dept']?.toString() ?? '').trim().toUpperCase())
        .where((d) => d.isNotEmpty)
        .toSet();
    return configured
        .where((d) => present.contains(d.trim().toUpperCase()))
        .toList();
  }

  /// Filter by department. [dept] empty (or null) means "all departments in
  /// scope" — the department drill-down is a refinement, not a lock.
  static List<Map<String, dynamic>> filterByDepartment(
      List<Map<String, dynamic>> incidents, String? dept) {
    final d = (dept ?? '').trim().toUpperCase();
    if (d.isEmpty) return incidents;
    return incidents
        .where((i) => (i['dept']?.toString() ?? '').trim().toUpperCase() == d)
        .toList();
  }

  /// True if this scope permits acting on (editing / closing) [incident].
  ///
  /// incident_detail_screen previously had NO authorisation check at all —
  /// anyone who could open a record could advance it to CLOSED, including for
  /// another plant.
  /// ★ 2026-09-07: compares by CODE, for the same reason as [filterIncidents] —
  /// 'SSO Ranchi' and 'SSO — SSO Ranchi' are one plant under two labels, and the
  /// old string equality denied a plant user the right to close their OWN plant's
  /// report whenever the two sides had been spelled differently.
  ///
  /// The tolerance added to [filterIncidents] is deliberately NOT mirrored here:
  /// a record with no resolvable plant stays un-actionable. Reading a report from
  /// elsewhere is harmless; closing one is not.
  Future<bool> canActOn(Map<String, dynamic> incident) async {
    if (seesAllPlants) return true;
    if (plant.isEmpty) return false;
    final plants = await AdminMasterData.getPlants();
    final theirs =
        AdminMasterData.plantEntryFor(incident['plant']?.toString() ?? '', plants);
    if (theirs == null) return false;
    final mine = AdminMasterData.plantEntryFor(plant, plants);
    final myCode = (mine?['code'] ?? '').toUpperCase();
    if (myCode.isNotEmpty) {
      return (theirs['code'] ?? '').toUpperCase() == myCode;
    }
    return AdminMasterData.canonicalPlantFrom(
            incident['plant']?.toString() ?? '', plants) ==
        plant;
  }

  /// Short label for the scope banner, e.g. "BSP — Bhilai Steel Plant".
  String get label => seesAllPlants
      ? 'All plants'
      : (plant.isEmpty ? 'No plant assigned' : plant);
}
