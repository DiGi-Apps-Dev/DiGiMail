import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/models.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/ui/compose_screen.dart';

import 'fake_backend.dart';

void main() {
  final a = Account(
    id: 1,
    address: 'utente@esempio.it',
    name: 'Prova',
    imapHost: 'imap.esempio.it',
    smtpHost: 'smtp.esempio.it',
  );
  final righe = [for (var i = 1; i <= 30; i++) 'Riga $i del messaggio'];

  test('risposta e inoltro citano tutto il messaggio, anche da gesto sulla lista', () {
    final m = testMsg(1, 7, 'Anna', 'Preventivo')..bodyText = righe.join('\n');
    for (final act in [Act.reply, Act.replyAll, Act.forward]) {
      // Senza testo passato (gesto sulla lista) lo prende da quello salvato.
      final q = ComposeInit.from(a, m, act).quote;
      expect(q.contains('Riga 1 del messaggio'), isTrue, reason: '$act');
      expect(q.contains('Riga 30 del messaggio'), isTrue, reason: '$act');
    }
  });
}
