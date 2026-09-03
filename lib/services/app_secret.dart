/// Shared secret sent to the Apps Script backend on the two actions that either
/// hand out vendor API keys (`getAiKeys`) or spend money on the script owner's
/// keys (`gemini`).
///
/// WHY THIS EXISTS
/// The Apps Script deployment URL is a compile-time constant in
/// `SyncService._defaultBackendUrl`, and this repository is public. Until
/// 2026-09-03 an unauthenticated POST of `{"action":"getMasterData"}` to that
/// URL returned every AI key in plaintext to anyone on the internet, and
/// `{"action":"diagnose"}` spent real money on the owner's Google quota. The
/// server-side session-token gate could not be used for this, because it has
/// never actually worked in a live build — see the long comment above
/// `publicActions` in `apps_script_v14.js`.
///
/// WHAT IT IS WORTH, HONESTLY
/// This stops an anonymous request against the URL, which is the exposure that
/// mattered. It does NOT hide the secret from a user of the web build: the value
/// is compiled into the JavaScript the browser downloads, so anyone who can load
/// safetylens.in can read it out, exactly as they can read the keys themselves
/// out of DevTools. No client-held credential can do better than this. The only
/// real fix is to stop shipping keys to devices at all and proxy the vendor
/// calls server-side, the way `doc_qa_service.dart` already does through
/// `DocQaProxy.gs`. Treat this class as a stopgap with a deletion date.
///
/// HOW IT IS SET
/// Never committed. Builds pass `--dart-define=SL_APP_SECRET=<value>`, wired to
/// a repository secret in `.github/workflows/build-web.yml` and
/// `build-apk.yml`. The same value goes in the Apps Script `APP_SECRET` script
/// property. Both sides must change together — the server has no grace period
/// for an old secret, so a rotation is: set the property, then rebuild, and
/// expect AI to be down for whatever gap there is between the two.
///
/// A LOCAL `flutter run` WITHOUT THE DEFINE gets an empty string, so AI features
/// that need a key will fail with `Forbidden: bad or missing _appSecret` in the
/// console. That is deliberate and is the same thing a misconfigured release
/// would do, rather than something that works locally and breaks in production.
class AppSecret {
  AppSecret._();

  static const String value =
      String.fromEnvironment('SL_APP_SECRET', defaultValue: '');

  static bool get isSet => value.isNotEmpty;

  /// Adds `_appSecret` to a request body, but only when a secret was actually
  /// compiled in. An absent field and an empty field are treated identically by
  /// the server, so this keeps the payload honest rather than sending
  /// `_appSecret: ''` and inviting a future reader to think it was checked.
  static void apply(Map<String, dynamic> body) {
    if (value.isNotEmpty) body['_appSecret'] = value;
  }
}
