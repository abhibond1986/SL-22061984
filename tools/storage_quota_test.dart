// Simulates the iPhone WebKit localStorage quota (2026-10-06): once the store
// is full, every setValue throws "QuotaExceededError". Login must still work.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:safety_lens/services/auth_service.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/crypto_utils.dart';

class QuotaStore extends InMemorySharedPreferencesStore {
  QuotaStore(this.limit, Map<String, Object> data) : super.withData(data);
  final int limit;
  final Map<String, Object> mirror = {};
  int get used => mirror.entries
      .fold(0, (n, e) => n + e.key.length + jsonEncode(e.value).length);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final before = mirror[key];
    mirror[key] = value;
    if (used > limit) {
      if (before == null) { mirror.remove(key); } else { mirror[key] = before; }
      throw Exception('QuotaExceededError: The quota has been exceeded.');
    }
    return super.setValue(valueType, key, value);
  }
  @override
  Future<bool> remove(String key) async {
    mirror.remove(key);
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('login and local writes survive a full storage quota', () async {
    const salt = 'saltsalt';
    final user = {
      'username': 'tuser', 'name': 'T', 'status': 'active', 'salt': salt,
      'passwordHash': CryptoUtils.hashPassword('Secret#9', salt),
    };
    final big = 'x' * 60000; // expendable cache that fills the store
    final seed = <String, Object>{
      'flutter.users': jsonEncode([user]),
      'flutter.incidents': '[]',
      'flutter.ai_result_cache_v1': big,
    };
    SharedPreferences.setMockInitialValues({});
    final probe = QuotaStore(1 << 30, seed);
    seed.forEach((k, v) => probe.mirror[k] = v);
    // Full: only 40 chars of headroom, less than any real write needs.
    final store = QuotaStore(probe.used + 40, seed);
    seed.forEach((k, v) => store.mirror[k] = v);
    SharedPreferencesStorePlatform.instance = store;
    await LocalDB.init();

    // Before the fix this threw QuotaExceededError out of signIn.
    final res = await AuthService.signIn('tuser', 'Secret#9');
    expect(res.ok, isTrue, reason: res.message);
    // The expendable cache was given up to make room.
    expect(store.mirror.containsKey('flutter.ai_result_cache_v1'), isFalse);

    // A write that can never fit is dropped without throwing, and is still
    // readable for this session.
    await LocalDB.upsertUser({...user, 'name': 'y' * 90000});
    final u = (await LocalDB.getUsers()).firstWhere((e) => e['username'] == 'tuser');
    expect((u['name'] as String).length, 90000);
  });
}
