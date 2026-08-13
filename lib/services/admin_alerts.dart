// lib/services/admin_alerts.dart
// SAIL Safety Lens — Alert rules storage & delivery (v35)
//
// ★ v35: ENHANCED with real-time SMS/Email notifications triggered from backend
//
// Stores notification rules locally. Rules describe WHEN to notify
// (trigger condition) and WHO to notify (subscribers).
//
// Rule schema:
//   {
//     id          : 'rule_1718012345',
//     name        : 'All Critical → Safety Head',
//     trigger     : 'critical_incident' | 'high_incident' | 'ai_scan_hazard' |
//                   'threshold_daily' | 'daily_digest' | 'high_open_7d' | 'near_miss',
//     threshold   : 3,                              // for threshold_daily
//     plant       : 'BSP' | '' (any),
//     department  : 'BLAST FURNACE' | '' (any),     // NEW: department filter
//     section     : 'SMS' | '' (any),               // NEW: section from AI detection
//     recipients  : ['email@sail.in','9876543210'],
//     channel     : 'email' | 'sms' | 'both',
//     enabled     : true,
//     createdAt   : ISO date,
//     createdBy   : username,
//     lastFired   : ISO date (last time this rule fired),
//     fireCount   : int (total times fired),
//   }
//
// v35: Backend-triggered delivery flow:
//   1. App syncs incident/scan to Apps Script backend
//   2. Backend evaluates alert rules (synced separately)
//   3. Backend sends email via MailApp and SMS via configured gateway
//   4. Backend logs alert delivery in 'AlertLog' sheet
//   5. App can pull alert history for admin dashboard

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_master_data.dart';

class AdminAlerts {
  static const String _kKey = 'admin_alert_rules';
  static const String _kAlertHistory = 'admin_alert_history';

  // ── Trigger types ──────────────────────────────────────────────
  static const String trigCriticalIncident = 'critical_incident';
  static const String trigHighIncident     = 'high_incident';
  static const String trigAiScanHazard     = 'ai_scan_hazard';
  static const String trigNearMiss         = 'near_miss';
  static const String trigThresholdDaily   = 'threshold_daily';
  static const String trigDailyDigest      = 'daily_digest';
  static const String trigHighOpen7d       = 'high_open_7d';

  static const Map<String, String> triggerLabels = {
    trigCriticalIncident: 'Every CRITICAL incident',
    trigHighIncident    : 'Every HIGH severity incident',
    trigAiScanHazard    : 'AI Scan detects CRITICAL/HIGH hazard',
    trigNearMiss        : 'Near Miss reported',
    trigThresholdDaily  : 'Daily count above threshold',
    trigDailyDigest     : 'Daily digest (8 AM)',
    trigHighOpen7d      : 'HIGH/CRITICAL open >7 days',
  };

  static const Map<String, String> triggerDescriptions = {
    trigCriticalIncident: 'Fires immediately when a CRITICAL incident is logged & synced',
    trigHighIncident    : 'Fires immediately when a HIGH severity incident is logged & synced',
    trigAiScanHazard    : 'Fires when AI scan detects CRITICAL or HIGH hazard in a department',
    trigNearMiss        : 'Fires when any near miss is reported in the selected department',
    trigThresholdDaily  : 'Fires once if N+ incidents recorded in a single day',
    trigDailyDigest     : 'Morning summary email every day at 8 AM with previous day stats',
    trigHighOpen7d      : 'Daily check for stale HIGH/CRITICAL incidents open more than 7 days',
  };

  // ── Departments for section-based filtering ──────────────────────
  static const List<String> departments = [
    'BLAST FURNACE',
    'SMS',
    'COKE OVEN',
    'SINTER PLANT',
    'ROLLING MILL (HSM)',
    'ROLLING MILL (CRM)',
    'ROLLING MILL (Plate)',
    'ROLLING MILL (Bar & Rod)',
    'POWER PLANT',
    'ELECTRICAL',
    'GAS NETWORK',
    'MATERIAL HANDLING',
    'MAINTENANCE (Mechanical)',
    'MAINTENANCE (Electrical)',
    'MAINTENANCE (Civil)',
    'OXYGEN PLANT',
    'WATER TREATMENT',
    'TRANSPORT & RAILWAY',
    'REFRACTORY',
    'LABORATORY',
    'CIVIL & CONSTRUCTION',
    'STORES & PROCUREMENT',
    'GENERAL',
  ];

  // ── READ ────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getRules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_kKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── ADD / UPDATE ────────────────────────────────────────────────
  static Future<void> save(Map<String, dynamic> rule) async {
    final list = await getRules();
    final id = rule['id']?.toString();
    final idx = id == null ? -1
        : list.indexWhere((r) => r['id']?.toString() == id);

    if (idx >= 0) {
      list[idx] = Map<String, dynamic>.from(rule);
    } else {
      list.insert(0, {
        ...rule,
        'id'       : rule['id'] ?? 'rule_${DateTime.now().millisecondsSinceEpoch}',
        'createdAt': rule['createdAt'] ?? DateTime.now().toIso8601String(),
        'fireCount': 0,
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(list));
  }

  // ── DELETE ──────────────────────────────────────────────────────
  static Future<void> delete(String id) async {
    final list = await getRules();
    list.removeWhere((r) => r['id']?.toString() == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(list));
  }

  // ── TOGGLE ──────────────────────────────────────────────────────
  static Future<void> toggle(String id, bool enabled) async {
    final list = await getRules();
    final idx  = list.indexWhere((r) => r['id']?.toString() == id);
    if (idx < 0) return;
    list[idx]['enabled'] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(list));
  }

  // ── CLEAR ALL (for restore) ─────────────────────────────────────
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
    await prefs.remove(_kAlertHistory);
  }

  // ── EVALUATE — figure out which rules WOULD fire right now ──────
  // Pure function over current state — does not actually send.
  // ★ v35: Enhanced with AI scan and near-miss triggers + department matching
  ///
  /// [openStatuses] and [plants] come from AdminMasterData. They are passed in
  /// rather than fetched because this stays a synchronous pure function; callers
  /// await them. When omitted, the shared const defaults are used — never a
  /// re-typed literal list.
  static List<Map<String, dynamic>> evaluate(
      List<Map<String, dynamic>> rules,
      List<Map<String, dynamic>> incidents,
      {Map<String, dynamic>? latestAiScan,
       Map<String, dynamic>? latestNearMiss,
       Set<String>? openStatuses,
       List<Map<String, String>>? plants}) {
    final openSet = openStatuses ??
        AdminMasterData.openStatusesFrom(AdminMasterData.defaultStatuses);
    final plantDefs = plants ?? AdminMasterData.sailPlants;
    final firing = <Map<String, dynamic>>[];
    final today = DateTime.now();
    final todayKey = '${today.year}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    for (final r in rules) {
      if (r['enabled'] != true) continue;
      final trigger = r['trigger']?.toString();
      final plant   = r['plant']?.toString() ?? '';
      final dept    = r['department']?.toString() ?? '';

      // Canonicalise both sides: a rule scoped to "BSP" was compared with raw
      // string equality, so it never matched records stored as "BSP Bhilai" and
      // the rule silently never fired.
      final rulePlant = plant.isEmpty
          ? ''
          : AdminMasterData.canonicalPlantFrom(plant, plantDefs);
      bool incPlantMatch(Map<String, dynamic> i) {
        if (plant.isEmpty) return true;
        if (rulePlant.isEmpty) return i['plant']?.toString() == plant;
        return AdminMasterData.canonicalPlantFrom(
                i['plant']?.toString() ?? '', plantDefs) ==
            rulePlant;
      }

      bool incDeptMatch(Map<String, dynamic> i) {
        if (dept.isEmpty) return true;
        final incDept = i['dept']?.toString() ?? i['department']?.toString() ?? '';
        final incSection = i['detectedSection']?.toString() ?? '';
        return incDept.toUpperCase().contains(dept.toUpperCase()) ||
               incSection.toUpperCase().contains(dept.toUpperCase());
      }

      switch (trigger) {
        case trigCriticalIncident:
          final criticals = incidents.where((i) =>
              (i['severity']?.toString().toUpperCase() == 'CRITICAL') &&
              incPlantMatch(i) && incDeptMatch(i)).toList();
          if (criticals.isNotEmpty) {
            firing.add({
              ...r, 'reason': '${criticals.length} CRITICAL incident(s)',
              'matchedIncidents': criticals.take(5).toList(),
            });
          }
          break;

        case trigHighIncident:
          final highs = incidents.where((i) =>
              (i['severity']?.toString().toUpperCase() == 'HIGH') &&
              incPlantMatch(i) && incDeptMatch(i)).toList();
          if (highs.isNotEmpty) {
            firing.add({
              ...r, 'reason': '${highs.length} HIGH incident(s)',
              'matchedIncidents': highs.take(5).toList(),
            });
          }
          break;

        case trigAiScanHazard:
          if (latestAiScan != null) {
            final scanRisk = latestAiScan['overallRisk']?.toString().toUpperCase() ?? '';
            final scanSection = latestAiScan['detectedSection']?.toString() ?? '';
            final scanPlant = latestAiScan['plant']?.toString() ?? '';

            final plantOk = plant.isEmpty || scanPlant == plant;
            final deptOk = dept.isEmpty ||
                scanSection.toUpperCase().contains(dept.toUpperCase());

            if ((scanRisk == 'CRITICAL' || scanRisk == 'HIGH') && plantOk && deptOk) {
              final hazardCount = (latestAiScan['hazards'] as List?)?.length ?? 0;
              firing.add({
                ...r,
                'reason': 'AI Scan: $scanRisk risk detected in $scanSection ($hazardCount hazards)',
                'scanData': {
                  'riskScore': latestAiScan['riskScore'],
                  'section': scanSection,
                  'summary': latestAiScan['summary'],
                  'hazardCount': hazardCount,
                  'topHazards': (latestAiScan['hazards'] as List?)
                      ?.take(3)
                      .map((h) => '${h['name']} (${h['severity']})')
                      .toList() ?? [],
                },
              });
            }
          }
          break;

        case trigNearMiss:
          if (latestNearMiss != null) {
            final nmPlant = latestNearMiss['plant']?.toString() ?? '';
            final nmDept = latestNearMiss['dept']?.toString() ?? '';

            final plantOk = plant.isEmpty || nmPlant == plant;
            final deptOk = dept.isEmpty ||
                nmDept.toUpperCase().contains(dept.toUpperCase());

            if (plantOk && deptOk) {
              firing.add({
                ...r,
                'reason': 'Near Miss reported in ${nmDept.isNotEmpty ? nmDept : "unspecified dept"}',
                'nearMissData': {
                  'title': latestNearMiss['title'] ?? latestNearMiss['desc'] ?? '',
                  'severity': latestNearMiss['severity'] ?? 'MEDIUM',
                  'dept': nmDept,
                  'date': latestNearMiss['date'] ?? '',
                  'reportedBy': latestNearMiss['reportedBy'] ?? '',
                },
              });
            }
          }
          break;

        case trigThresholdDaily:
          final threshold = (r['threshold'] is int)
              ? r['threshold'] as int
              : int.tryParse('${r['threshold']}') ?? 3;
          final todayCount = incidents.where((i) =>
              (i['date']?.toString() ?? '').startsWith(todayKey) &&
              incPlantMatch(i) && incDeptMatch(i)).length;
          if (todayCount >= threshold) {
            firing.add({...r, 'reason': '$todayCount incidents today (≥ $threshold)'});
          }
          break;

        case trigHighOpen7d:
          final cutoff = today.subtract(const Duration(days: 7));
          final stale = incidents.where((i) {
            final sev = i['severity']?.toString().toUpperCase() ?? '';
            final st  = i['status']?.toString().toUpperCase() ?? '';
            if (!(sev == 'CRITICAL' || sev == 'HIGH')) return false;
            // "Still open" per the admin's ladder. Testing `st == 'CLOSED'`
            // meant renaming the final stage made every closed case look open,
            // and this rule then fired on work that was already finished.
            // A blank status counts as open: nothing has closed it.
            if (st.isNotEmpty && !openSet.contains(st)) return false;
            if (!incPlantMatch(i) || !incDeptMatch(i)) return false;
            final d = DateTime.tryParse(i['date']?.toString() ?? '');
            return d != null && d.isBefore(cutoff);
          }).length;
          if (stale > 0) {
            firing.add({...r, 'reason': '$stale HIGH/CRITICAL open >7d'});
          }
          break;

        case trigDailyDigest:
          firing.add({...r, 'reason': 'Daily digest (would send at 8 AM)'});
          break;
      }
    }
    return firing;
  }

  // ── DELIVER — actually send alerts via Apps Script backend ────
  // ★ v35: Enhanced with department/section info and SMS support
  // Call this after evaluate() returns firing rules.
  // Returns a list of delivery results.
  static Future<List<Map<String, dynamic>>> deliver(
    List<Map<String, dynamic>> firingRules,
    List<Map<String, dynamic>> incidents,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString('apps_script_url') ??
        prefs.getString('sync_backend_url') ?? '';
    if (baseUrl.isEmpty) {
      return [{'ok': false, 'error': 'Apps Script URL not configured'}];
    }

    final results = <Map<String, dynamic>>[];

    for (final rule in firingRules) {
      try {
        // Build incident summary (send only key fields, not full data)
        final matchingIncidents = (rule['matchedIncidents'] as List?)
            ?? incidents
                .where((i) {
                  final plant = rule['plant']?.toString() ?? '';
                  final dept = rule['department']?.toString() ?? '';
                  final plantOk = plant.isEmpty || i['plant']?.toString() == plant;
                  final deptOk = dept.isEmpty ||
                      (i['dept']?.toString() ?? '').toUpperCase().contains(dept.toUpperCase());
                  return plantOk && deptOk;
                })
                .take(10)
                .toList();

        final incidentSummaries = (matchingIncidents as List)
            .take(10)
            .map((i) => <String, dynamic>{
              'date': i['date'] ?? '',
              'title': i['title'] ?? i['desc'] ?? '',
              'severity': i['severity'] ?? '',
              'plant': i['plant'] ?? '',
              'dept': i['dept'] ?? i['department'] ?? '',
              'status': i['status'] ?? '',
              'detectedSection': i['detectedSection'] ?? '',
            })
            .toList();

        final response = await http.post(
          Uri.parse(baseUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'action': 'fireAlert',
            'rule': {
              'id': rule['id'],
              'name': rule['name'],
              'trigger': rule['trigger'],
              'plant': rule['plant'] ?? '',
              'department': rule['department'] ?? '',
              'recipients': rule['recipients'] ?? [],
              'channel': rule['channel'] ?? 'email',
            },
            'reason': rule['reason'] ?? '',
            'incidents': incidentSummaries,
            'scanData': rule['scanData'],
            'nearMissData': rule['nearMissData'],
            'timestamp': DateTime.now().toIso8601String(),
          }),
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200 || response.statusCode == 302) {
          final data = response.statusCode == 200
              ? jsonDecode(response.body)
              : {'ok': true, 'message': 'Delivered (redirect)'};
          results.add(data is Map<String, dynamic> ? data : {'ok': true});

          // Update fire count and last fired time locally
          await _updateFireStats(rule['id']?.toString() ?? '');
        } else {
          results.add({'ok': false, 'error': 'HTTP ${response.statusCode}'});
        }
      } catch (e) {
        results.add({'ok': false, 'error': e.toString()});
      }
    }

    // Save to alert history
    if (results.isNotEmpty) {
      await _saveAlertHistory(firingRules, results);
    }

    return results;
  }

  // ── Update fire statistics for a rule ──────────────────────────
  static Future<void> _updateFireStats(String ruleId) async {
    if (ruleId.isEmpty) return;
    final list = await getRules();
    final idx = list.indexWhere((r) => r['id']?.toString() == ruleId);
    if (idx < 0) return;
    list[idx]['lastFired'] = DateTime.now().toIso8601String();
    list[idx]['fireCount'] = ((list[idx]['fireCount'] ?? 0) as int) + 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(list));
  }

  // ── Save alert history for admin dashboard ──────────────────────
  static Future<void> _saveAlertHistory(
      List<Map<String, dynamic>> firingRules,
      List<Map<String, dynamic>> results) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAlertHistory);
    List<Map<String, dynamic>> history = [];
    if (raw != null) {
      try {
        history = (jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {}
    }

    for (int i = 0; i < firingRules.length && i < results.length; i++) {
      history.insert(0, {
        'ruleId': firingRules[i]['id'],
        'ruleName': firingRules[i]['name'],
        'trigger': firingRules[i]['trigger'],
        'reason': firingRules[i]['reason'],
        'channel': firingRules[i]['channel'],
        'recipients': firingRules[i]['recipients'],
        'department': firingRules[i]['department'] ?? '',
        'success': results[i]['ok'] == true,
        'error': results[i]['error'],
        'timestamp': DateTime.now().toIso8601String(),
      });
    }

    // Keep only last 200 entries
    if (history.length > 200) {
      history = history.sublist(0, 200);
    }

    await prefs.setString(_kAlertHistory, jsonEncode(history));
  }

  // ── GET ALERT HISTORY — for admin dashboard ─────────────────────
  static Future<List<Map<String, dynamic>>> getAlertHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAlertHistory);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── SYNC RULES to backend (for time-based & backend triggers) ──
  // ★ v35: Enhanced to sync all rules including AI scan and near-miss triggers
  // Backend evaluates these rules whenever new data arrives
  static Future<bool> syncToBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString('apps_script_url') ??
        prefs.getString('sync_backend_url') ?? '';
    if (baseUrl.isEmpty) return false;

    final rules = await getRules();
    // Sync ALL enabled rules to backend — backend evaluates on data arrival
    final enabledRules = rules.where((r) => r['enabled'] == true).toList();

    try {
      final response = await http.post(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'action': 'syncAlertRules',
          'rules': enabledRules,
        }),
      ).timeout(const Duration(seconds: 15));

      return response.statusCode == 200 || response.statusCode == 302;
    } catch (e) {
      print('[AdminAlerts] Sync failed: $e');
      return false;
    }
  }

  // ── FIRE IMMEDIATE ALERT — for real-time notification on data sync ──
  // ★ v35: Called by SyncService after successful incident/scan push
  // This is the BACKEND-TRIGGERED flow:
  //   1. Device syncs data to backend
  //   2. Backend receives data and evaluates rules
  //   3. Backend sends SMS/email immediately
  //   4. This method tells the backend to evaluate NOW for the given data
  static Future<Map<String, dynamic>> fireImmediateAlert({
    required String type, // 'ai_scan' | 'near_miss' | 'incident'
    required Map<String, dynamic> data,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString('apps_script_url') ??
        prefs.getString('sync_backend_url') ?? '';
    if (baseUrl.isEmpty) {
      return {'ok': false, 'error': 'Backend URL not configured'};
    }

    try {
      final response = await http.post(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'action': 'evaluateAndAlert',
          'type': type,
          'data': data,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        try {
          return jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          return {'ok': true, 'message': 'Alert evaluation triggered'};
        }
      } else if (response.statusCode == 302) {
        return {'ok': true, 'message': 'Alert evaluation triggered (redirect)'};
      } else {
        return {'ok': false, 'error': 'HTTP ${response.statusCode}'};
      }
    } catch (e) {
      print('[AdminAlerts] Immediate alert failed: $e');
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── DEFAULT RULES — pre-configured for typical steel plant use ──
  // ★ v35: Sensible defaults that admin can customize
  static List<Map<String, dynamic>> getDefaultRules(String createdBy) {
    final now = DateTime.now().toIso8601String();
    return [
      {
        'id': 'rule_default_critical',
        'name': 'CRITICAL → Safety Head + HOD (Immediate)',
        'trigger': trigCriticalIncident,
        'threshold': 1,
        'plant': '',
        'department': '',
        'recipients': [],
        'channel': 'both',
        'enabled': false,
        'createdAt': now,
        'createdBy': createdBy,
        'fireCount': 0,
      },
      {
        'id': 'rule_default_ai_scan',
        'name': 'AI Scan HIGH/CRITICAL → Department Safety Officer',
        'trigger': trigAiScanHazard,
        'threshold': 1,
        'plant': '',
        'department': '',
        'recipients': [],
        'channel': 'email',
        'enabled': false,
        'createdAt': now,
        'createdBy': createdBy,
        'fireCount': 0,
      },
      {
        'id': 'rule_default_near_miss',
        'name': 'Near Miss → Section In-Charge + Safety',
        'trigger': trigNearMiss,
        'threshold': 1,
        'plant': '',
        'department': '',
        'recipients': [],
        'channel': 'email',
        'enabled': false,
        'createdAt': now,
        'createdBy': createdBy,
        'fireCount': 0,
      },
      {
        'id': 'rule_default_digest',
        'name': 'Daily Safety Digest → GM Safety',
        'trigger': trigDailyDigest,
        'threshold': 0,
        'plant': '',
        'department': '',
        'recipients': [],
        'channel': 'email',
        'enabled': false,
        'createdAt': now,
        'createdBy': createdBy,
        'fireCount': 0,
      },
      {
        'id': 'rule_default_stale',
        'name': 'Stale HIGH/CRITICAL (>7d) → Escalation',
        'trigger': trigHighOpen7d,
        'threshold': 0,
        'plant': '',
        'department': '',
        'recipients': [],
        'channel': 'both',
        'enabled': false,
        'createdAt': now,
        'createdBy': createdBy,
        'fireCount': 0,
      },
    ];
  }
}
