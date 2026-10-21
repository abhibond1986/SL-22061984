// Regression tests for report 17925586 (2026-10-21): the "Missing eye
// protection" box printed in the top-left corner while the worker stood in the
// bottom-right of the photograph.
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/services/hazard_quality.dart';

void main() {
  group('HazardQuality.drawableBox', () {
    test('a clean 0-1 box is returned unchanged', () {
      final b = HazardQuality.drawableBox({
        'bbox': {'x': 0.77, 'y': 0.77, 'w': 0.04, 'h': 0.06},
      })!;
      expect(b['x'], closeTo(0.77, 1e-9));
      expect(b['y'], closeTo(0.77, 1e-9));
    });

    test('a 0-1000 map is scaled down instead of clamped to the corner', () {
      final b = HazardQuality.drawableBox({
        'bbox': {'x': 770, 'y': 770, 'w': 40, 'h': 60},
      })!;
      expect(b['x'], closeTo(0.77, 1e-9));
      expect(b['h'], closeTo(0.06, 1e-9));
    });

    test('Gemini [yMin, xMin, yMax, xMax] list on 0-1000', () {
      final b = HazardQuality.drawableBox({
        'bbox': [770, 760, 830, 800],
      })!;
      expect(b['x'], closeTo(0.76, 1e-9));
      expect(b['y'], closeTo(0.77, 1e-9));
      expect(b['w'], closeTo(0.04, 1e-9));
    });

    test('the stored 17925586 box falls back to the model\'s own box', () {
      // Exactly what Supabase holds for that hazard.
      final b = HazardQuality.drawableBox({
        'bbox': {
          'h': 0.000060000000000004494,
          'w': 0.000039999999999999996,
          'x': 0.0007700000000000001,
          'y': 0.077,
        },
        'bboxBeforeAttribution': {'h': 0.06, 'w': 0.04, 'x': 0.77, 'y': 0.77},
      })!;
      expect(b['x'], closeTo(0.77, 1e-9));
      expect(b['y'], closeTo(0.77, 1e-9));
    });

    test('mixed scales are rejected', () {
      expect(
          HazardQuality.drawableBox({
            'bbox': {'x': 0.77, 'y': 77, 'w': 0.04, 'h': 0.06},
          }),
          isNull);
    });

    test('a box outside the frame is rejected', () {
      expect(
          HazardQuality.drawableBox({
            'bbox': {'x': 0.9, 'y': 0.5, 'w': 0.5, 'h': 0.2},
          }),
          isNull);
    });

    test('no bbox key → nothing drawn, even with a stored earlier box', () {
      expect(
          HazardQuality.drawableBox({
            'bboxBeforeAttribution': {'x': 0.1, 'y': 0.1, 'w': 0.1, 'h': 0.1},
          }),
          isNull);
    });
  });

  group('HazardQuality.apply — malformed headBox', () {
    test('a typo in persons[].headBox no longer drags the box to the corner',
        () {
      final result = <String, dynamic>{
        'people': 1,
        'viewType': 'WORKING_DISTANCE',
        'persons': [
          {
            'id': 1,
            'where': 'lower right, yellow helmet',
            // The reply that broke report 17925586: y on the wrong scale.
            'headBox': {'x': 0.77, 'y': 77, 'w': 0.04, 'h': 0.06},
            'ppe': {'helmet': 'worn', 'chinStrap': 'unclear', 'eyewear': 'not_worn'},
          }
        ],
        'hazards': [
          {
            'name': 'Missing eye protection',
            'description': 'Visible: Worker in the lower right is not wearing '
                'safety goggles in a high-dust industrial environment.',
            'severity': 'MEDIUM',
            'personIds': [1],
            'bbox': {'x': 0.77, 'y': 0.77, 'w': 0.04, 'h': 0.06},
          }
        ],
      };
      HazardQuality.apply(result);
      final h = (result['hazards'] as List).first as Map;
      final b = h['bbox'] as Map;
      expect((b['x'] as num).toDouble(), closeTo(0.77, 1e-9));
      expect((b['y'] as num).toDouble(), closeTo(0.77, 1e-9));
    });
  });
}
