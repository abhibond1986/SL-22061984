// Factories Act 1948 coverage of the citable regulation table (2026-10-06).
//
// The owner reported that almost every hazard was cited as FA 1948 S21 or S32.
// Cause: the table the AI may cite from held only 12 FA sections, so dust,
// heat, lighting, housekeeping, storage, manual handling and worker-conduct
// findings had no correct section. These tests pin the widened table.
//
// Run: copy to test/ and `flutter test test/regulation_catalog_test.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/services/regulation_catalog.dart';

void main() {
  test('every catalogue citation has a unique signature', () {
    final seen = <String, String>{};
    for (final e in RegulationCatalog.entries) {
      final sig = RegulationCatalog.signature(e.citation);
      expect(sig, isNotEmpty, reason: e.citation);
      expect(seen.containsKey(sig), isFalse,
          reason: '${e.citation} collides with ${seen[sig]}');
      seen[sig] = e.citation;
    }
  });

  test('Factories Act sections relevant to plant hazards are citable', () {
    const required = [
      'S7A', 'S11', 'S12', 'S13', 'S14', 'S17', 'S21', 'S22', 'S24', 'S28',
      'S29', 'S30', 'S31', 'S32', 'S33', 'S34', 'S35', 'S36', 'S36A', 'S37',
      'S38', 'S40', 'S41C', 'S41F', 'S111',
    ];
    for (final s in required) {
      expect(RegulationCatalog.lookup('FA 1948 $s'), isNotNull, reason: s);
    }
  });

  test('sub-clause and long-form citations resolve to the right section', () {
    String? c(String raw) => RegulationCatalog.lookup(raw)?.citation;
    expect(c('FA 1948 S7A(2)(b)'), 'FA 1948 S7A');
    expect(c('Factories Act, 1948 – Section 7A(2)(d)'), 'FA 1948 S7A');
    expect(c('FA 1948 S32(c)'), 'FA 1948 S32');
    expect(c('FA 1948 S111(1)(c)'), 'FA 1948 S111');
    expect(c('Factories Act 1948 Sec. 14'), 'FA 1948 S14');
    expect(c('FA 1948 S36A'), 'FA 1948 S36A');
    expect(c('FA 1948 S36'), 'FA 1948 S36');
    expect(c('FA 1948 S41F'), 'FA 1948 S41F');
    // Still not in the table → not vouched for.
    expect(c('FA 1948 S45'), isNull);
    expect(c('FA 1948 S39'), isNull);
  });

  test('hard rules still catch the classic misapplications', () {
    final s21 = RegulationCatalog.lookup('FA 1948 S21')!;
    final s36 = RegulationCatalog.lookup('FA 1948 S36')!;
    expect(RegulationCatalog.misapplication(s21, 'unchained gas cylinder'),
        isNotNull);
    expect(RegulationCatalog.misapplication(s36, 'work at height no harness'),
        isNotNull);
  });

  test('new sections fit the hazards they are meant for', () {
    bool fits(String cite, String text) =>
        RegulationCatalog.topicalFit(RegulationCatalog.lookup(cite)!, text)!;
    expect(fits('FA 1948 S14', 'visible dust plume at transfer point'), isTrue);
    expect(fits('FA 1948 S11', 'scrap and spillage on the shop floor'), isTrue);
    expect(fits('FA 1948 S13', 'radiant heat near the furnace tap hole'), isTrue);
    expect(fits('FA 1948 S17', 'dark stairway, poor lighting'), isTrue);
    expect(fits('FA 1948 S7A', 'coils stored without chocks'), isTrue);
    expect(fits('FA 1948 S40', 'corroded gallery members'), isTrue);
    expect(fits('FA 1948 S111', 'worker not wearing the helmet provided'), isTrue);
  });

  test('prompt table lists the new groups and sections', () {
    final t = RegulationCatalog.promptTable();
    for (final g in [
      'Working Environment', 'Housekeeping', 'Structures & Buildings',
      'Worker Conduct', 'Material Handling & Storage',
      'General Duties & Systems of Work',
    ]) {
      expect(t, contains('── $g ──'));
    }
    for (final s in ['S7A', 'S11', 'S13', 'S14', 'S17', 'S24', 'S30', 'S34',
        'S40', 'S111']) {
      expect(t, contains('FA 1948 $s ='), reason: s);
    }
    // Housekeeping now leads with S11, not S32.
    final hk = t.substring(t.indexOf('── Housekeeping ──'));
    expect(hk.indexOf('S11'), lessThan(hk.indexOf('S32')));
  });
}
