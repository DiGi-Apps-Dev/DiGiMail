import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/mail/backend.dart';

/// L'email come arriva dal server (testo completo), letta come fa la notifica.
Future<String> _anteprima(Outgoing o) async {
  final sent = await ImapBackend.buildMime(o);
  final raw = sent.renderMessage();
  final back = em.MimeMessage.parseFromText(raw);
  return msgFromMime(1, 'INBOX', back).preview;
}

void main() {
  const logo =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  test('email senza immagini: l\'anteprima ha il testo', () async {
    final p = await _anteprima(Outgoing(
      accountId: 1,
      fromAddress: 'utente@esempio.net',
      to: ['lavoro@azienda.example'],
      subject: 'cccc',
      text: 'Ciao prova\n\nMario Rossi',
      html: '<div>Ciao prova<br><br>Mario Rossi</div>',
    ));
    expect(p, contains('Ciao prova'));
  });

  test('email con il logo nella firma: l\'anteprima ha il testo', () async {
    final p = await _anteprima(Outgoing(
      accountId: 1,
      fromAddress: 'utente@esempio.net',
      to: ['lavoro@azienda.example'],
      subject: 'cccc',
      text: 'Ciao prova\n\nMario Rossi',
      html:
          '<div>Ciao prova<br><br>Mario Rossi<br><img src="data:image/png;base64,$logo"></div>',
    ));
    // ignore: avoid_print
    print('ANTEPRIMA: «$p»');
    expect(p, contains('Ciao prova'));
  });
}
