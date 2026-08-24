// lib/widgets/user_picker.dart
// ═══════════════════════════════════════════════════════════════════════════
//  Searchable employee picker — name OR SAIL P.no.
//
//  WHY IT SEARCHES ON THE SERVER
//  The roster is ~10,000 people. The old assign dialog rendered `_users` — a
//  list held in memory — which worked when there were a dozen accounts and is
//  now three things at once: about 2.3 MB of JSON on a ~5 MB browser storage
//  budget shared with incident photographs, a list nobody can scroll, and (worst)
//  SILENTLY INCOMPLETE, because PostgREST caps an unbounded select at 1,000 rows
//  without reporting it. Postgres does the matching instead, over the indexes in
//  migration_bulk_users.sql.
//
//  It falls back to the locally cached users when the cloud is off or
//  unreachable, so assigning an investigator still works on a bad connection —
//  with the limitation stated on screen rather than hidden.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/admin_master_data.dart';
import '../services/assign_scope.dart';
import '../services/local_db.dart';
import '../services/supabase_config.dart';
import '../services/supabase_service.dart';

/// What the picker returns.
///
/// A class rather than a nullable username, because "cancelled" and "chose to
/// unassign" are different answers and a null string cannot tell them apart —
/// the old dialog treated a dismissal as an instruction to clear the assignee.
class UserPickResult {
  const UserPickResult.selected(this.user) : cleared = false;
  const UserPickResult.cleared()
      : user = null,
        cleared = true;

  final Map<String, dynamic>? user;
  final bool cleared;

  String get username => user?['username']?.toString() ?? '';
  String get displayName {
    final n = user?['name']?.toString().trim() ?? '';
    return n.isEmpty ? username : n;
  }
}

/// Show the picker. Returns null if the sheet was dismissed.
///
/// [scope] restricts the list to one plant's personnel — see [AssignScope] for
/// the rule and why it is enforced here, at the point of choice, rather than
/// validated afterwards. Pass null (or an unrestricted scope) to offer everyone.
Future<UserPickResult?> showUserPicker(
  BuildContext context, {
  String title = 'Choose an employee',
  String? currentUsername,
  bool allowClear = true,
  AssignScope? scope,
}) {
  return showModalBottomSheet<UserPickResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _UserPickerSheet(
      title: title,
      currentUsername: currentUsername,
      allowClear: allowClear,
      scope: scope ?? const AssignScope.unrestricted(),
    ),
  );
}

class _UserPickerSheet extends StatefulWidget {
  const _UserPickerSheet({
    required this.title,
    required this.currentUsername,
    required this.allowClear,
    required this.scope,
  });

  final String title;
  final String? currentUsername;
  final bool allowClear;
  final AssignScope scope;

  @override
  State<_UserPickerSheet> createState() => _UserPickerSheetState();
}

class _UserPickerSheetState extends State<_UserPickerSheet> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _results = const [];
  bool _busy = false;
  bool _localOnly = false;
  String _note = '';
  int _requestSeq = 0;

  /// Active plant master, needed to decide each candidate's plant membership.
  /// Loaded once; an empty list means every candidate is let through, which is
  /// the same fail-open stance AssignScope takes when it cannot resolve a plant.
  List<Map<String, String>> _plants = const [];

  @override
  void initState() {
    super.initState();
    // Something in the list from the outset: an empty sheet reads as broken.
    _loadPlantsThenSearch();
  }

  Future<void> _loadPlantsThenSearch() async {
    if (widget.scope.restricted) {
      try {
        _plants = await AdminMasterData.getPlants();
      } catch (_) {}
      if (!mounted) return;
    }
    await _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    // 300 ms: a P.no is seven characters, and firing a query per keystroke would
    // send seven and race their replies.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    final seq = ++_requestSeq;
    setState(() {
      _busy = true;
      _note = '';
    });

    List<Map<String, dynamic>> found = const [];
    var localOnly = false;
    var note = '';

    final restricted = widget.scope.restricted;

    if (SupabaseConfig.enabled) {
      // A larger page when restricted: the plant filter is applied by the server
      // only loosely, and this list is then cut down again on the client, so
      // asking for 40 would leave far fewer than 40 on screen.
      found = await SupabaseService.searchUsers(
        q,
        limit: restricted ? 80 : 40,
        plantTerms: restricted ? widget.scope.terms : null,
      );
      if (found.isEmpty && SupabaseService.usersLastError.isNotEmpty) {
        localOnly = true;
        note = 'Showing only people saved on this device — the employee list '
            'could not be reached.';
      }
    } else {
      localOnly = true;
    }

    if (localOnly) {
      found = await _searchLocal(q);
      if (note.isEmpty) {
        note = 'Showing people saved on this device.';
      }
    }

    // The client is the authority on plant membership; the server-side ILIKE was
    // only a narrowing pass and lets through neighbouring units whose names share
    // a code fragment. Applied to the local fallback too, so the rule does not
    // quietly lapse when the connection drops.
    if (restricted) {
      found = found
          .where((u) => widget.scope.allows(u, _plants))
          .toList();
    }

    // A slow earlier query must not overwrite a newer one's results.
    if (!mounted || seq != _requestSeq) return;
    setState(() {
      _results = found;
      _busy = false;
      _localOnly = localOnly;
      _note = note;
    });
  }

  Future<List<Map<String, dynamic>>> _searchLocal(String q) async {
    final all = <Map<String, dynamic>>[
      ...await LocalDB.getUsers(),
      ...await LocalDB.getCachedUsers(),
    ];
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    final needle = q.toLowerCase();
    for (final u in all) {
      final uname = (u['username']?.toString() ?? '').toLowerCase();
      if (uname.isEmpty || !seen.add(uname)) continue;
      final status = (u['status']?.toString() ?? 'active').toLowerCase();
      if (status == 'disabled' || status == 'blocked' || status == 'inactive') {
        continue;
      }
      if (needle.isEmpty ||
          [uname, u['name'], u['pno']]
              .whereType<Object>()
              .map((e) => e.toString().toLowerCase())
              .any((s) => s.contains(needle))) {
        out.add(u);
      }
      if (out.length >= 40) break;
    }
    out.sort((a, b) => (a['name']?.toString() ?? '')
        .toLowerCase()
        .compareTo((b['name']?.toString() ?? '').toLowerCase()));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.78,
        decoration: BoxDecoration(
          color: sl.card,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border.all(color: sl.border),
        ),
        child: Column(children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: sl.border, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              Expanded(
                child: Text(widget.title,
                    style: TextStyle(
                        color: sl.text1,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
              ),
              if (widget.allowClear)
                TextButton(
                  onPressed: () => Navigator.pop(
                      context, const UserPickResult.cleared()),
                  child: const Text('Unassign'),
                ),
            ]),
          ),
          // The restriction is stated before the search box, not after an empty
          // result. Somebody typing a colleague's name and getting nothing back
          // needs to know it is a rule and not a fault.
          if (widget.scope.restricted)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: sl.accentText.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: sl.accentText.withOpacity(0.25)),
                ),
                child: Row(children: [
                  Icon(Icons.apartment_rounded,
                      size: 14, color: sl.accentText),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(widget.scope.note,
                        style: TextStyle(
                            color: sl.accentText,
                            fontSize: 11.5,
                            height: 1.35,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: _onChanged,
              style: TextStyle(color: sl.text1, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search by name or SAIL P.no',
                hintStyle: TextStyle(color: sl.text4, fontSize: 13),
                prefixIcon:
                    Icon(Icons.search_rounded, color: sl.text4, size: 20),
                suffixIcon: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
                filled: true,
                fillColor: sl.card2,
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: sl.border)),
              ),
            ),
          ),
          if (_note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                Icon(Icons.info_outline_rounded,
                    size: 14, color: _localOnly ? sl.amberText : sl.text4),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_note,
                      style: TextStyle(
                          color: _localOnly ? sl.amberText : sl.text4,
                          fontSize: 11.5,
                          height: 1.35)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Expanded(
            child: _results.isEmpty && !_busy
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _ctrl.text.trim().isEmpty
                            ? 'Start typing a name or P.no.'
                            : widget.scope.restricted
                                ? 'Nobody in ${widget.scope.label} matches '
                                    '"${_ctrl.text.trim()}". This case can only '
                                    'be assigned within its own plant. Retired '
                                    'and disabled accounts are not shown.'
                                : 'Nobody matches "${_ctrl.text.trim()}". Retired '
                                    'and disabled accounts are not shown.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: sl.text4, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) => _row(sl, _results[i]),
                  ),
          ),
        ]),
      ),
    );
  }

  /// First letter for the avatar. Plain substring rather than `.characters`, to
  /// avoid depending on a package this project does not declare.
  static String _initial(String s) {
    final t = s.trim();
    return t.isEmpty ? '?' : t.substring(0, 1).toUpperCase();
  }

  Widget _row(SL sl, Map<String, dynamic> u) {
    final uname = u['username']?.toString() ?? '';
    final name = u['name']?.toString().trim() ?? '';
    final pno = u['pno']?.toString().trim() ?? '';
    final desig = u['designation']?.toString().trim() ?? '';
    final unit = (u['unit']?.toString().trim().isNotEmpty ?? false)
        ? u['unit'].toString().trim()
        : (u['plant']?.toString().trim() ?? '');
    final isCurrent = widget.currentUsername != null &&
        widget.currentUsername!.toLowerCase() == uname.toLowerCase();

    final subtitle = [
      if (pno.isNotEmpty) pno,
      if (desig.isNotEmpty) desig,
      if (unit.isNotEmpty) unit,
    ].join(' • ');

    return Material(
      color: isCurrent ? sl.card3 : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.pop(context, UserPickResult.selected(u)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sl.card2,
                shape: BoxShape.circle,
                border: Border.all(color: sl.border),
              ),
              child: Text(
                _initial(name.isNotEmpty ? name : uname),
                style: TextStyle(
                    color: sl.text2, fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? uname : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sl.text1,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: sl.text4, fontSize: 11.5)),
                ],
              ),
            ),
            if (isCurrent)
              Icon(Icons.check_circle_rounded, size: 18, color: sl.greenText),
          ]),
        ),
      ),
    );
  }
}
