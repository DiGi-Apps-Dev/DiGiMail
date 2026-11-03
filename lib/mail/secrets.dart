import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Password, token e chiave IA: solo qui, nella memoria cifrata di Android.
class Secrets {
  Secrets._();
  static FlutterSecureStorage store = const FlutterSecureStorage();

  /// Una chiave che il sistema rifiuta (dopo un aggiornamento) vale come «non c'è»: si chiede di
  /// rifare l'accesso, invece di un errore incomprensibile che ferma anche la copia completa.
  static Future<String?> _leggi(String key) async {
    try {
      return await store.read(key: key);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> password(int accountId) => _leggi('pw_$accountId');
  static Future<void> setPassword(int accountId, String v) =>
      store.write(key: 'pw_$accountId', value: v);
  static Future<String?> msToken(int accountId) => _leggi('ms_$accountId');
  static Future<void> setMsToken(int accountId, String json) =>
      store.write(key: 'ms_$accountId', value: json);
  static Future<String?> aiToken() => _leggi('ai_token');
  static Future<void> setAiToken(String v) =>
      store.write(key: 'ai_token', value: v);
  static Future<void> removeAccount(int accountId) async {
    await store.delete(key: 'pw_$accountId');
    await store.delete(key: 'ms_$accountId');
  }
}
