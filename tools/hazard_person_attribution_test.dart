import 'package:safety_lens/services/hazard_quality.dart';
void main() {
  // Replay of SafetyLens_AI_SCAN_1791018635101: right worker (green) wears strap,
  // left worker (red shirt) has none; model boxed the right one.
  Map<String, dynamic> scan() => {
    'people': 2,
    'persons': [
      {'id': 1, 'where': 'on the left in a red shirt', 'headBox': {'x': 0.10, 'y': 0.12, 'w': 0.14, 'h': 0.16},
       'ppe': {'helmet': 'worn', 'chinStrap': 'not_worn', 'eyewear': 'not_worn'}},
      {'id': 2, 'where': 'on the right in a green shirt', 'headBox': {'x': 0.60, 'y': 0.10, 'w': 0.15, 'h': 0.17},
       'ppe': {'helmet': 'worn', 'chinStrap': 'worn', 'eyewear': 'not_worn'}},
    ],
    'hazards': [
      {'name': 'Unsecured chin strap on hard hat', 'description': 'Worker on the right has chin strap hanging loose.',
       'severity': 'MEDIUM', 'bbox': {'x': 0.58, 'y': 0.08, 'w': 0.19, 'h': 0.2}},
    ],
  };
  var r = scan(); final q = HazardQuality.apply(r);
  final h = (r['hazards'] as List).first as Map;
  print('A $q\n  bbox=${h['bbox']} ids=${h['personIds']}\n  desc=${h['description']}');
  // Nobody deviates -> withdrawn + LOW
  r = scan(); ((r['persons'] as List)[0] as Map)['ppe']['chinStrap'] = 'worn';
  HazardQuality.apply(r); final h2 = (r['hazards'] as List).first as Map;
  print('B sev=${h2['severity']} bbox=${h2['bbox']} rej=${h2['bboxRejected'] != null} issue=${h2['locationIssue']}');
  // Model was right -> untouched
  r = scan(); final hz = (r['hazards'] as List).first as Map; hz['bbox'] = {'x': 0.09, 'y': 0.1, 'w': 0.16, 'h': 0.2};
  HazardQuality.apply(r); print('C bbox=${hz['bbox']} note=${hz['attributionNote']}');
  // unclear -> untouched
  r = scan(); ((r['persons'] as List)[1] as Map)['ppe']['chinStrap'] = 'unclear';
  HazardQuality.apply(r); print('D bbox=${((r['hazards'] as List).first as Map)['bbox']}');
}
