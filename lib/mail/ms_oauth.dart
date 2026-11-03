import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Accesso Microsoft (Outlook, Hotmail, Live) con il «flusso con codice»:
/// l'app mostra un codice, tu lo inserisci sul sito Microsoft. Non servono
/// indirizzi di ritorno. Serve un «ID applicazione» registrato una volta
/// su Microsoft Entra (conti personali abilitati, flussi client pubblici attivi).
class MsOAuth {
  static const _base =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0';
  static const scope =
      'https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access';

  final String clientId;
  final http.Client _http;
  MsOAuth(this.clientId, {http.Client? client})
    : _http = client ?? http.Client();

  final Completer<void> _stop = Completer<void>();

  /// Ferma subito l'attesa di [waitForToken], che finisce con [MsAccessoAnnullato].
  void annulla() {
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<DeviceCode> start() async {
    final r = await _http.post(
      Uri.parse('$_base/devicecode'),
      body: {'client_id': clientId, 'scope': scope},
    );
    final j = _leggi(r);
    if (r.statusCode != 200)
      throw MsAuthException(
        j['error_description']?.toString() ?? 'Errore ${r.statusCode}',
      );
    return DeviceCode(
      deviceCode: j['device_code'] as String,
      userCode: j['user_code'] as String,
      verificationUri: j['verification_uri'] as String,
      expiresIn: (j['expires_in'] as num).toInt(),
      interval: ((j['interval'] ?? 5) as num).toInt(),
    );
  }

  /// Attende che l'utente confermi nel browser. Restituisce il testo JSON del token.
  Future<String> waitForToken(DeviceCode c) async {
    final end = DateTime.now().add(Duration(seconds: c.expiresIn));
    var wait = c.interval;
    while (DateTime.now().isBefore(end)) {
      await Future.any([
        Future<void>.delayed(Duration(seconds: wait)),
        _stop.future,
      ]);
      if (_stop.isCompleted) throw const MsAccessoAnnullato();
      final r = await _http.post(
        Uri.parse('$_base/token'),
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': clientId,
          'device_code': c.deviceCode,
        },
      );
      final j = _leggi(r);
      if (r.statusCode == 200) return _normalize(j, null);
      final err = j['error'];
      if (err == 'authorization_pending') continue;
      if (err == 'slow_down') {
        wait += 5;
        continue;
      }
      throw MsAuthException(switch (err) {
        'expired_token' => 'Il codice è scaduto: ripeti l\'accesso.',
        'authorization_declined' => 'Accesso rifiutato su Microsoft.',
        'invalid_client' || 'unauthorized_client' =>
          'L\'ID applicazione Microsoft non è valido.',
        'invalid_grant' => 'Accesso Microsoft scaduto: ripeti l\'accesso.',
        _ => j['error_description']?.toString() ?? '$err',
      });
    }
    throw MsAuthException('Tempo scaduto: ripeti l\'accesso.');
  }

  /// Rinnova l'accesso con il token di aggiornamento.
  Future<String> refresh(String refreshToken) async {
    final r = await _http.post(
      Uri.parse('$_base/token'),
      body: {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': refreshToken,
        'scope': scope,
      },
    );
    final j = _leggi(r);
    if (r.statusCode != 200)
      throw MsAuthException(
        j['error_description']?.toString() ?? 'Errore ${r.statusCode}',
      );
    return _normalize(j, refreshToken);
  }

  /// Una risposta che non è JSON (proxy, pagina d'errore) si dice in italiano.
  Map<String, dynamic> _leggi(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw MsAuthException('Risposta non valida da Microsoft (${r.statusCode}).');
    }
  }

  String _normalize(Map<String, dynamic> j, String? oldRefresh) {
    return jsonEncode({
      'access_token': j['access_token'],
      'expires_in': j['expires_in'] is String
          ? int.parse(j['expires_in'] as String)
          : j['expires_in'],
      'refresh_token': j['refresh_token'] ?? oldRefresh ?? '',
      'scope': (j['scope'] ?? scope).toString(),
      'token_type': (j['token_type'] ?? 'Bearer').toString(),
      'created': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

/// l'utente ha premuto Annulla durante l'accesso: non è un errore da mostrare.
class MsAccessoAnnullato implements Exception {
  const MsAccessoAnnullato();
}

class DeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

class MsAuthException implements Exception {
  final String message;
  MsAuthException(this.message);
  @override
  String toString() => message;
}
