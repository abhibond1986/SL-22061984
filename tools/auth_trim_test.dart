import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/auth_service.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/crypto_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('login password tolerates a stray keyboard space, not other typos', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalDB.init();
    const salt = 'abc123salt';
    await LocalDB.upsertUser({
      'username': 'tuser', 'name': 'T', 'status': 'active',
      'salt': salt, 'passwordHash': CryptoUtils.hashPassword('Secret#9', salt),
    });
    expect((await AuthService.signIn('tuser', 'Secret#9')).ok, isTrue);
    expect((await AuthService.signIn('tuser', 'Secret#9 ')).ok, isTrue);
    expect((await AuthService.signIn('tuser', 'secret#9')).ok, isFalse);
    expect((await AuthService.signIn('tuser', 'Secret#')).ok, isFalse);
  });
}
