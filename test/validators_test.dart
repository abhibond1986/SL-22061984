import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/services/validators.dart';

void main() {
  group('Validators.validateEmail', () {
    test('valid emails pass', () {
      expect(Validators.validateEmail('user@example.com'), null);
      expect(Validators.validateEmail('a.b@sail.in'), null);
      expect(Validators.validateEmail('test+tag@domain.co.in'), null);
    });

    test('invalid emails fail', () {
      expect(Validators.validateEmail(''), isNotNull);
      expect(Validators.validateEmail('notanemail'), isNotNull);
      expect(Validators.validateEmail('@domain.com'), isNotNull);
      expect(Validators.validateEmail('user@'), isNotNull);
      expect(Validators.validateEmail('user@.com'), isNotNull);
    });

    test('too long email fails', () {
      final longEmail = '${'a' * 90}@example.com';
      expect(Validators.validateEmail(longEmail), isNotNull);
    });
  });

  group('Validators.validatePhone', () {
    test('valid Indian phones pass', () {
      expect(Validators.validatePhone('9876543210'), null);
      expect(Validators.validatePhone('6123456789'), null);
    });

    test('invalid phones fail', () {
      expect(Validators.validatePhone('1234567890'), isNotNull); // starts with 1
      expect(Validators.validatePhone('98765'), isNotNull); // too short
      expect(Validators.validatePhone('98765432101'), isNotNull); // too long
    });

    test('empty phone is ok (optional)', () {
      expect(Validators.validatePhone(''), null);
      expect(Validators.validatePhone(null), null);
    });
  });

  group('Validators.validateName', () {
    test('valid names pass', () {
      expect(Validators.validateName('Abhishek Kumar'), null);
      expect(Validators.validateName('R.K. Sharma'), null);
    });

    test('empty name fails', () {
      expect(Validators.validateName(''), isNotNull);
      expect(Validators.validateName(' '), isNotNull);
    });

    test('name with HTML characters fails', () {
      expect(Validators.validateName('<script>alert(1)</script>'), isNotNull);
      expect(Validators.validateName('Test{name}'), isNotNull);
    });

    test('too short name fails', () {
      expect(Validators.validateName('A'), isNotNull);
    });
  });

  group('Validators.validateUsername', () {
    test('valid usernames pass', () {
      expect(Validators.validateUsername('abhishek.kumar'), null);
      expect(Validators.validateUsername('demo'), null);
      expect(Validators.validateUsername('user_123'), null);
    });

    test('invalid usernames fail', () {
      expect(Validators.validateUsername('ab'), isNotNull); // too short
      expect(Validators.validateUsername('user name'), isNotNull); // space
      expect(Validators.validateUsername('user@name'), isNotNull); // @
      expect(Validators.validateUsername(''), isNotNull);
    });
  });

  group('Validators.validatePassword', () {
    test('valid passwords pass', () {
      // This case used to assert that 'demo' (4 chars) was accepted. The
      // minimum was later raised to Validators.minPasswordLength = 6 and the
      // test was never updated, because `flutter test` had never actually been
      // run in CI — so this file has been red for as long as the stricter rule
      // has existed. Fixed by updating the expectation, NOT by lowering the
      // minimum: 6 is the weaker-of-the-two-evils floor we want to keep.
      expect(Validators.validatePassword('demo12'), null);
      expect(Validators.validatePassword('sail@123'), null);
    });

    test('a password at exactly the minimum length is accepted', () {
      // Pins the boundary so a future change to minPasswordLength has to be
      // deliberate rather than silently shifting what counts as valid.
      expect(Validators.validatePassword('a' * Validators.minPasswordLength),
          null);
      expect(
          Validators.validatePassword('a' * (Validators.minPasswordLength - 1)),
          isNotNull);
    });

    test('too short passwords fail', () {
      expect(Validators.validatePassword('abc'), isNotNull);
      expect(Validators.validatePassword(''), isNotNull);
    });
  });

  group('Validators.validateLocation', () {
    test('valid locations pass', () {
      expect(Validators.validateLocation('BF-2 Cast House'), null);
      expect(Validators.validateLocation('Near Gate 5, SMS-2'), null);
    });

    test('placeholder location fails', () {
      expect(Validators.validateLocation('To be confirmed (edit if needed)'), isNotNull);
    });

    test('empty location fails', () {
      expect(Validators.validateLocation(''), isNotNull);
    });
  });

  group('Validators.sanitize', () {
    test('strips HTML tags', () {
      expect(Validators.sanitize('<b>bold</b>'), 'bold');
    });

    test('strips script tags', () {
      expect(Validators.sanitize('<script>alert("xss")</script>hello'), 'hello');
    });

    test('strips javascript: protocol', () {
      expect(Validators.sanitize('javascript:void(0)'), 'void(0)');
    });

    test('leaves normal text unchanged', () {
      expect(Validators.sanitize('Normal safety report text'), 'Normal safety report text');
    });
  });
}
