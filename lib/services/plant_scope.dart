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
  /// an empty dashboard — the seeded admin user's plant is literally
  /// 'SAIL Safety Organisation', and near_miss_tab defaults to the same value.
  static const Set<String> orgLevelPlants = {
    'SAIL SAFETY ORGANISATION',
    'SAIL SAFETY ORGANIZATION',
    'SSO',
    'CORPORATE',
    'CORP',
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
  Future<List<Map<String, dynamic>>> filterIncidents(
      List<Map<String, dynamic>> incidents) async {
    if (seesAllPlants) return incidents;
    if (plant.isEmpty) return const []; // unresolved scope shows nothing
    final plants = await AdminMasterData.getPlants();
    return incidents.where((i) {
      final p = AdminMasterData.canonicalPlantFrom(
          i['plant']?.toString() ?? '', plants);
      return p == plant;
    }).toList();
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
  Future<bool> canActOn(Map<String, dynamic> incident) async {
    if (seesAllPlants) return true;
    if (plant.isEmpty) return false;
    final canon = await AdminMasterData.canonicalPlant(
        incident['plant']?.toString() ?? '');
    return canon == plant;
  }

  /// Short label for the scope banner, e.g. "BSP — Bhilai Steel Plant".
  String get label => seesAllPlants
      ? 'All plants'
      : (plant.isEmpty ? 'No plant assigned' : plant);
}
