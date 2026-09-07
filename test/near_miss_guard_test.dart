import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/services/near_miss_guard.dart';

// Regression tests for NearMissGuard.
//
// The case that created this guard: "while walking inside his office he was
// singing a song" was filed as an Unsafe Act, Slip/Fall, MEDIUM severity, at 90%
// confidence, with a corrective action advising employees not to sing. The model
// supplied the entire hazard.
//
// The guard's three states carry different costs and the tests are grouped that
// way, because the temptation when this file goes red will be to add a word to
// `_hazardStems` and move on:
//
//   • a missing veto  → one bad record a supervisor rejects. Cheap.
//   • a wrong veto    → a real hazard report refused, and a worker who learns
//                       not to bother reporting. Expensive.
//   • `null`          → the model's own verdict stands, i.e. the behaviour we
//                       had before the guard existed. Always safe.
//
// So the `mustNotVeto` and `mustNotJudge` groups are the load-bearing ones. If a
// change makes a case in `mustVeto` fail, that is a regression worth arguing
// about; if it makes a case in `mustNotVeto` fail, it is simply wrong.
void main() {
  group('mustVeto — no hazard anywhere in the worker\'s words', () {
    const cases = <String>[
      // The report that prompted all of this.
      'while walking inside his office he was singing a song',
      'he was singing a song and dancing in the corridor',
      'two workers were chatting during the shift',
      'the meeting started late today in the conference room',
      'my supervisor did not greet me this morning',
      'the canteen served food late to the workers again',
    ];
    for (final text in cases) {
      test('"$text"', () {
        expect(NearMissGuard.hazardSignalInText(text), isFalse);
      });
    }
  });

  group('mustNotVeto — a real hazard is named, in English', () {
    const cases = <String>[
      // The example the prompt's own guidance is built around.
      'one person was walking and there was a slippery surface',
      'someone walked down the stairs without holding the handrail',
      'he was not wearing helmet near the furnace',
      'worker was working at 10 metre without any support',
      'crane load swung past a person standing below',
      'gas leak from the pipeline near coke oven',
      'floor was uneven and dark in the store',
      'he was using mobile phone while driving inside the plant',
      'a wagon nearly hit the person crossing the track',
      'electrical panel door was open with bare conductor',
      'employee climbed the ladder without harness',
      'hot metal splashed near the ladle',
      'housekeeping is poor, scrap lying everywhere',
      'he was sleeping on duty in the control room',
      'the guard on the conveyor belt is missing',
    ];
    for (final text in cases) {
      test('"$text"', () {
        expect(NearMissGuard.hazardSignalInText(text), isTrue);
      });
    }
  });

  group('mustNotJudge — not English, so the guard has no vocabulary for it', () {
    const cases = <String>[
      // Devanagari.
      'तेल गिरा हुआ था और फर्श फिसलन भरा था',
      'सीढ़ी पर रेलिंग नहीं है',
      // Romanised Hindi. These are the dangerous ones: they pass any
      // script check, match no English stem, and without _romanHindiMarkers
      // they were vetoed — genuine hazard reports thrown away by a guard that
      // could not read them.
      'chalte samay tel gira hua tha',
      'seedhi par railing nahi hai',
      'mazdoor helmet nahi pehen raha tha',
      'plant ke andar bahut garam tha aur koi dhyan nahi de raha tha',
      'wahan par kuch gir gaya tha',
    ];
    for (final text in cases) {
      test('"$text"', () {
        expect(NearMissGuard.hazardSignalInText(text), isNull);
      });
    }
  });

  group('mustNotJudge — too little to read', () {
    test('empty', () => expect(NearMissGuard.hazardSignalInText(''), isNull));
    test('a few characters',
        () => expect(NearMissGuard.hazardSignalInText('oil'), isNull));
    test('fewer than three words',
        () => expect(NearMissGuard.hazardSignalInText('oil spill'), isNull));
    test('digits and punctuation only',
        () => expect(NearMissGuard.hazardSignalInText('12/07 — 14:30'), isNull));
  });

  group('the Hindi markers must not switch the guard off for English', () {
    // 'log', 'logon' and 'pair' are ordinary Hindi words deliberately left out
    // of _romanHindiMarkers because they are also ordinary English in a steel
    // plant. If someone adds them, these two cases start returning null and the
    // guard quietly stops working on a slice of English input — which is a
    // silent failure, hence the explicit test.
    test('"log" is not treated as a Hindi marker', () {
      expect(
          NearMissGuard.hazardSignalInText(
              'operator did not log the reading in the log book'),
          isNotNull);
    });
    test('"pair" is not treated as a Hindi marker', () {
      expect(
          NearMissGuard.hazardSignalInText(
              'he was carrying a pair of gloves in his hand'),
          isNotNull);
    });
    test('romanised "hota hai" is read as Hindi, not as the stem "hot"', () {
      // _romanHindiMarkers is checked before _hazardStems precisely for this:
      // "hota" starts with "hot".
      expect(
          NearMissGuard.hazardSignalInText('yahan bahut hota hai kaam ka dabav'),
          isNull);
    });
  });

  group('a hazard word is evidence of vocabulary, not of an incident', () {
    // The guard may only ever veto. It reports "signal present" here, and it is
    // then the model's job — not the guard's — to decide these describe nothing.
    // A guard that could promote an answer would file both of these as hazards.
    test('negated hazard', () {
      expect(
          NearMissGuard.hazardSignalInText(
              'there was no oil on the floor today, area was clean'),
          isTrue);
    });
    test('hazard mentioned as already fixed', () {
      expect(
          NearMissGuard.hazardSignalInText(
              'the handrail that was missing last week has been repaired'),
          isTrue);
    });
  });
}
