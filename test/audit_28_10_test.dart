import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/main.dart' show mailtoInit;
import 'package:digimail/models.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/ui/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Account _acc() => Account(
  id: 1,
  address: 'utente@esempio.it',
  name: 'Prova',
  imapHost: 'imap.esempio.it',
  smtpHost: 'smtp.esempio.it',
);

Msg _msg({String replyTo = '', String refs = ''}) => Msg(
  accountId: 1,
  folder: 'INBOX',
  uid: 7,
  messageId: '<m3@x.it>',
  fromName: 'Newsletter',
  fromAddr: 'no-reply@lista.it',
  toAddrs: 'utente@esempio.it',
  subject: 'Novità',
  date: DateTime(2026, 10, 28),
  replyTo: replyTo,
  refs: refs,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
  });

  group('Ccn', () {
    test('con molti Ccn nessun indirizzo resta nel messaggio che parte', () async {
      final bcc = [
        for (var i = 0; i < 8; i++) 'segreto$i@dominio-lungo-di-prova.example.org',
      ];
      final mime = await ImapBackend.buildMime(
        Outgoing(
          accountId: 1,
          fromAddress: 'utente@esempio.it',
          to: ['cliente@esempio.it'],
          bcc: bcc,
          subject: 'prova',
          text: 'ciao',
        ),
      );
      final tolti = ImapBackend.senzaCcn(mime);
      // Quello che la libreria manda all'SMTP, dopo la sua rimozione della riga «Bcc:».
      final sulFilo = mime
          .renderMessage()
          .replaceAll(RegExp('^Bcc:.*\r\n', multiLine: true), '');
      expect(sulFilo.contains('segreto'), isFalse);
      // La copia in «Inviata» tiene l'intestazione.
      mime.headers!.addAll(tolti);
      expect(mime.renderMessage().contains('segreto7@'), isTrue);
    });

    test('la prova senza la correzione fallisce: la libreria da sola lascia gli indirizzi', () async {
      final mime = await ImapBackend.buildMime(
        Outgoing(
          accountId: 1,
          fromAddress: 'utente@esempio.it',
          to: ['cliente@esempio.it'],
          bcc: [for (var i = 0; i < 8; i++) 'segreto$i@dominio-lungo-di-prova.example.org'],
          subject: 'prova',
          text: 'ciao',
        ),
      );
      final sulFilo = mime
          .renderMessage()
          .replaceAll(RegExp('^Bcc:.*\r\n', multiLine: true), '');
      expect(sulFilo.contains('segreto'), isTrue);
    });
  });

  group('Reply-To e References', () {
    test('Rispondi va al Reply-To se c\'è', () {
      final i = ComposeInit.from(_acc(), _msg(replyTo: 'assistenza@lista.it'), Act.reply);
      expect(i.to, ['assistenza@lista.it']);
    });

    test('senza Reply-To va al mittente', () {
      final i = ComposeInit.from(_acc(), _msg(), Act.reply);
      expect(i.to, ['no-reply@lista.it']);
    });

    test('Rispondi a tutti non ripete il Reply-To in Cc', () {
      final m = _msg(replyTo: 'assistenza@lista.it')
        ..ccAddrs = 'assistenza@lista.it, altro@esempio.it';
      final i = ComposeInit.from(_acc(), m, Act.replyAll);
      expect(i.to, ['assistenza@lista.it']);
      expect(i.cc, ['altro@esempio.it']);
    });

    test('la catena References passa alla risposta', () {
      final i = ComposeInit.from(_acc(), _msg(refs: '<a@x.it> <b@x.it>'), Act.reply);
      expect(i.references, '<a@x.it> <b@x.it>');
    });

    test('Reply-To e References si salvano e si rileggono dal database', () async {
      final id = await Db.i.saveAccount(
        Account(address: 'x@y.it', name: 'X', imapHost: 'h', smtpHost: 's'),
      );
      final m = Msg(
        accountId: id,
        folder: 'INBOX',
        uid: 1,
        date: DateTime(2026, 10, 28),
        replyTo: 'r@y.it',
        refs: '<1@y.it>',
      );
      await Db.i.upsertMessages([m]);
      // Un aggiornamento senza i due campi non li cancella.
      await Db.i.upsertMessages([
        Msg(accountId: id, folder: 'INBOX', uid: 1, date: DateTime(2026, 10, 28)),
      ]);
      final r = (await Db.i.message(id, 'INBOX', 1))!;
      expect(r.replyTo, 'r@y.it');
      expect(r.refs, '<1@y.it>');
    });
  });

  group('mailto', () {
    test('destinatari, oggetto e testo dal link', () {
      final i = mailtoInit({
        'uri': 'mailto:anna@esempio.it?cc=b@esempio.it&subject=Ciao%20Anna&body=Testo',
      });
      expect(i.to, ['anna@esempio.it']);
      expect(i.cc, ['b@esempio.it']);
      expect(i.subject, 'Ciao Anna');
      expect(i.body, 'Testo');
    });

    test('più destinatari e dati extra di Android senza doppioni', () {
      final i = mailtoInit({
        'uri': 'mailto:a@x.it,b@x.it',
        'to': ['A@x.it', 'c@x.it'],
        'subject': 'Oggetto',
      });
      expect(i.to, ['a@x.it', 'b@x.it', 'c@x.it']);
      expect(i.subject, 'Oggetto');
    });
  });

  group('Cancella le email scaricate', () {
    test('le Rimandate restano, il resto si cancella e il segno di sincronizzazione resta', () async {
      final id = await Db.i.saveAccount(
        Account(address: 'x@y.it', name: 'X', imapHost: 'h', smtpHost: 's'),
      );
      await Db.i.upsertMessages([
        Msg(accountId: id, folder: 'INBOX', uid: 1, date: DateTime(2026, 10, 28)),
        Msg(accountId: id, folder: 'INBOX', uid: 2, date: DateTime(2026, 10, 28)),
      ]);
      await Db.i.setSnooze(id, 'INBOX', 2, DateTime.now().add(const Duration(days: 1)));
      await Db.i.setFolderSync(id, 'INBOX', 1, 2);
      await Db.i.wipeCache();
      expect(await Db.i.message(id, 'INBOX', 1), isNull);
      expect(await Db.i.message(id, 'INBOX', 2), isNotNull);
      expect(await Db.i.folderSync(id, 'INBOX'), isNotNull);
    });

    test('importare le impostazioni non porta la registrazione NAS di un altro telefono', () async {
      await Settings.i.import({'nasPushOk': true, 'fontScale': 1.2});
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('nasPushOk'), isNull);
      expect(p.getDouble('fontScale'), 1.2);
    });
  });

  test('l\'intestazione Bcc di un messaggio senza Ccn non dà errori', () {
    final m = em.MimeMessage()..headers = [];
    expect(ImapBackend.senzaCcn(m), isEmpty);
  });
}
