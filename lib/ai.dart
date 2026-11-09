import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mail/secrets.dart';
import 'models.dart';
import 'settings.dart';

class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

/// IA con Cloudflare Workers AI (endpoint compatibile OpenAI).
/// Parte solo quando tocchi un tasto: l'app non manda mai email all'IA da sola.
class Ai {
  Ai._();
  static http.Client client = http.Client();

  static Future<bool> configured() async {
    final t = await Secrets.aiToken();
    return Settings.i.aiAccountId.isNotEmpty && t != null && t.isNotEmpty;
  }

  static Future<String> chat(
    String system,
    String user, {
    int maxTokens = 1200,
  }) async {
    final token = await Secrets.aiToken();
    final account = Settings.i.aiAccountId;
    if (token == null || token.isEmpty || account.isEmpty) {
      throw AiException(
        'IA non configurata: inserisci account e chiave Cloudflare in Impostazioni > Intelligenza artificiale.',
      );
    }
    final r = await client
        .post(
          Uri.parse(
            'https://api.cloudflare.com/client/v4/accounts/${Uri.encodeComponent(account)}/ai/v1/chat/completions',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': Settings.i.aiModel,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'temperature': 0.3,
            'max_tokens': maxTokens,
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) {
      throw AiException(
        'Cloudflare ha risposto ${r.statusCode}. ${r.body.length > 160 ? r.body.substring(0, 160) : r.body}',
      );
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final text = (j['choices'] as List?)?.firstOrNull?['message']?['content'];
    if (text is! String || text.trim().isEmpty)
      throw AiException('Risposta vuota dal modello.');
    return text.trim();
  }

  static String _lang() => 'Rispondi sempre in ${Settings.i.aiLanguage}.';

  static final _iban = RegExp(
    r'\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b',
  );
  static final _email = RegExp(
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}',
  );
  static final _telefono = RegExp(
    r'(?<![\w/+.,-])(?:(?:\+|00)\d{1,3}(?:[ ./-]?\d){6,12}|0\d{2}(?:[ ./-]?\d){7})(?![\w.,]?\d)',
  );

  /// IBAN, indirizzi email e telefoni non partono verso il fornitore dell'IA.
  static String anonimo(String s) => s
      .replaceAll(_iban, '[IBAN]')
      .replaceAll(_email, '[email]')
      .replaceAll(_telefono, '[telefono]');

  static String _clip(String s, [int n = 9000]) {
    final t = anonimo(s);
    return t.length > n ? '${t.substring(0, n)}\n[testo tagliato]' : t;
  }

  static Future<String> summarize(Msg m, String body) => chat(
    'Sei l\'assistente di posta dell\'utente. Riassumi l\'email in al massimo 4 punti brevi e dì cosa si aspetta il mittente dall\'utente, se qualcosa. ${_lang()} Non inventare nulla.',
    'Da: ${anonimo(m.sender)}\nOggetto: ${anonimo(m.subject)}\n\n${_clip(body)}',
    maxTokens: 500,
  );

  static Future<String> reply(Msg m, String body, String instruction) => chat(
    'Scrivi la bozza di risposta a questa email a nome dell\'utente. Tono: ${Settings.i.aiTone}. ${_lang()} Scrivi solo il testo della risposta, senza oggetto e senza firma. Non inventare fatti, date o importi che non sono nell\'email o nelle istruzioni.',
    'Email ricevuta da ${anonimo(m.sender)}:\nOggetto: ${anonimo(m.subject)}\n\n${_clip(body, 6000)}\n\nIstruzioni dell\'utente per la risposta: ${instruction.isEmpty ? 'rispondi in modo appropriato' : instruction}',
    maxTokens: 700,
  );

  static Future<String> compose(String prompt) => chat(
    'Scrivi il testo di un\'email a nome dell\'utente. Tono: ${Settings.i.aiTone}. ${_lang()} Scrivi solo il corpo, senza oggetto e senza firma. Non inventare fatti che l\'utente non ha detto.',
    prompt,
    maxTokens: 700,
  );

  /// Traduce una frase come «la fattura del dentista di marzo» in filtri di ricerca.
  static Future<SearchPlan> planSearch(String phrase) async {
    final out = await chat(
      'Trasforma la richiesta di ricerca in JSON con questi campi: "text" (parole chiave da cercare, stringa), "from" (nome o indirizzo del mittente, stringa o null), "days" (ultimi N giorni, numero o null), "unread" (true/false/null). Rispondi SOLO con il JSON.',
      'Oggi è ${DateTime.now().toIso8601String().substring(0, 10)}.\nRichiesta: $phrase',
      maxTokens: 200,
    );
    return SearchPlan.parse(out, phrase);
  }
}

class SearchPlan {
  final String text;
  final String? from;
  final int? days;
  final bool? unread;
  const SearchPlan(this.text, this.from, this.days, this.unread);

  factory SearchPlan.parse(String out, String fallback) {
    try {
      final s = out.indexOf('{');
      final e = out.lastIndexOf('}');
      final j = jsonDecode(out.substring(s, e + 1)) as Map<String, dynamic>;
      String? str(Object? v) =>
          v is String && v.trim().isNotEmpty && v.toLowerCase() != 'null'
          ? v.trim()
          : null;
      return SearchPlan(
        str(j['text']) ?? '',
        str(j['from']),
        (j['days'] is num) ? (j['days'] as num).toInt() : null,
        j['unread'] is bool ? j['unread'] as bool : null,
      );
    } catch (_) {
      return SearchPlan(fallback, null, null, null);
    }
  }

  bool matches(Msg m) {
    if (from != null) {
      final f = from!.toLowerCase();
      if (!m.fromAddr.toLowerCase().contains(f) &&
          !m.fromName.toLowerCase().contains(f))
        return false;
    }
    if (days != null &&
        m.date.isBefore(DateTime.now().subtract(Duration(days: days!))))
      return false;
    if (unread == true && m.seen) return false;
    if (text.isNotEmpty) {
      final hay =
          '${m.subject} ${m.preview} ${m.fromName} ${m.fromAddr} ${m.bodyText ?? m.bodyHead}'
              .toLowerCase();
      final words = text
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 2);
      if (!words.any(hay.contains)) return false;
    }
    return true;
  }
}
