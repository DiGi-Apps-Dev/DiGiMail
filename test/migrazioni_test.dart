import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/ai.dart';
import 'package:digimail/db.dart';
import 'package:digimail/linkify.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/nas_push.dart';
import 'package:digimail/mail/ms_oauth.dart';
import 'package:digimail/models.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Le colonne di ogni tabella, per confrontare un database aggiornato con uno nuovo.
Future<Map<String, Set<String>>> schema(Database d) async {
  final out = <String, Set<String>>{};
  final tabelle = await d.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
  );
  for (final t in tabelle) {
    final n = t['name'] as String;
    final col = await d.rawQuery('PRAGMA table_info($n)');
    out[n] = {for (final c in col) c['name'] as String};
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('Annulla: il Message-ID si pulisce senza errori (la regola era scritta male)', () {
    expect(idPerRicerca('<a"b\\c@x.it>'), '<abc@x.it>');
  });

  test('rimanda al weekend, di sabato sera: il sabato dopo, non subito', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    final sabato = DateTime(2026, 10, 31, 19, 30);
    final t = Ops.snoozeAt('weekend', now: sabato);
    expect(t.isAfter(sabato), isTrue);
    expect(t.weekday, DateTime.saturday);
    expect(t.day, 7);
  });

  test('coda: una sincronizzazione non riporta indietro letta e email tolte', () async {
    await Db.i.openForTest();
    final m = Msg(
      accountId: 1,
      folder: 'INBOX',
      uid: 5,
      fromAddr: 'a@b.it',
      date: DateTime.now(),
    );
    final m2 = Msg(
      accountId: 1,
      folder: 'INBOX',
      uid: 6,
      fromAddr: 'a@b.it',
      date: DateTime.now(),
    );
    await Db.i.upsertMessages([m, m2]);
    await Db.i.addPendingOp(1, 'seen', 'INBOX', [5], '1');
    await Db.i.addPendingOp(1, 'delete', 'INBOX', [6], '');
    await Db.i.riapplicaCoda(1, 'INBOX');
    expect((await Db.i.message(1, 'INBOX', 5))!.seen, isTrue);
    expect(await Db.i.message(1, 'INBOX', 6), isNull);
  });

  test('testo di un\'email solo HTML: senza stili e con le lettere vere', () {
    expect(
      testoDaHtml(
        '<style>p{color:red}</style><p>Perch&egrave; R&amp;D &#8364; 5</p><div>due</div>',
      ),
      'Perchè R&D € 5\ndue',
    );
  });

  test('link: un <a> non chiuso non spegne i link successivi', () {
    expect(
      linkify('<a href="x">uno <a href="y">due</a> www.esempio.it'),
      contains('href="https://www.esempio.it"'),
    );
  });

  test('NAS: la firma è la stessa del programma sul NAS', () {
    expect(
      NasPush.firma('key', 'The quick brown fox jumps over the lazy dog'),
      'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
    );
  });

  test('IA: IBAN, email e telefoni non partono', () {
    final t = Ai.anonimo(
      'Scrivi a mario.rossi@esempio.ch o chiama +41 79 123 45 67. '
      'Conto CH93 0076 2011 6238 5295 7, fattura 2026 del 12.10.2026.',
    );
    expect(t, isNot(contains('mario.rossi')));
    expect(t, isNot(contains('123 45 67')));
    expect(t, isNot(contains('6238')));
    expect(t, contains('fattura 2026 del 12.10.2026'));
  });

  test('logo: solo per chi ha scritto prima di oggi e mai dallo Spam', () async {
    await Db.i.openForTest();
    final vecchia = DateTime.now().subtract(const Duration(days: 5));
    await Db.i.setFolderRole(1, 'Junk', 'junk');
    await Db.i.upsertMessages([
      Msg(accountId: 1, folder: 'INBOX', uid: 1, fromAddr: 'Noto@a.it', date: vecchia),
      Msg(accountId: 1, folder: 'Junk', uid: 2, fromAddr: 'spam@b.it', date: vecchia),
      Msg(accountId: 1, folder: 'INBOX', uid: 3, fromAddr: 'nuovo@c.it', date: DateTime.now()),
    ]);
    expect(await Db.i.mittenteConosciuto('noto@a.it'), isTrue);
    expect(await Db.i.mittenteConosciuto('spam@b.it'), isFalse);
    expect(await Db.i.mittenteConosciuto('nuovo@c.it'), isFalse);
  });

  test('posta in uscita: un server che non risponde si dice, senza bloccare', () async {
    final e = await provaUscita(
      Account(
        name: 'Prova',
        address: 'a@b.it',
        imapHost: '127.0.0.1',
        smtpHost: '127.0.0.1',
        smtpPort: 1,
        smtpSsl: false,
      ),
      password: 'x',
    );
    expect(e, isNotNull);
  });

  test('Accesso Microsoft: Annulla ferma subito l\'attesa', () async {
    final auth = MsOAuth('id');
    final attesa = auth.waitForToken(
      const DeviceCode(
        deviceCode: 'd',
        userCode: 'u',
        verificationUri: 'https://esempio.it',
        expiresIn: 900,
        interval: 60,
      ),
    );
    auth.annulla();
    await expectLater(
      attesa.timeout(const Duration(seconds: 2)),
      throwsA(isA<MsAccessoAnnullato>()),
    );
  });

  test('un database della prima versione arriva alla 7 uguale a uno nuovo e tiene le email', () async {
    await Db.i.openForTest();
    final d = await Db.i.db;
    final nuovo = await schema(d);
    // Si riporta il database com'era nella versione 1.
    for (final i in ['msg_id', 'msg_snooze', 'msg_notified']) {
      await d.execute('DROP INDEX $i');
    }
    for (final c in ['answered', 'notified', 'reply_to', 'refs']) {
      await d.execute('ALTER TABLE messages DROP COLUMN $c');
    }
    await d.execute('ALTER TABLE scheduled DROP COLUMN claimed');
    await d.execute('ALTER TABLE push_log DROP COLUMN result');
    for (final t in ['folder_sync', 'moved', 'folder_roles']) {
      await d.execute('DROP TABLE $t');
    }
    await d.insert('messages', {
      'account_id': 1,
      'folder': 'INBOX',
      'uid': 7,
      'subject': 'Vecchia',
      'date': 1,
      'seen': 0,
    });
    await Db.i.upgradeForTest(d, 1, 7);
    expect(await schema(d), nuovo);
    final m = await d.query('messages');
    expect(m.single['subject'], 'Vecchia');
    expect(m.single['notified'], 1, reason: 'le email vecchie non devono suonare');
    final fs = await d.query('folder_sync');
    expect(fs.single['last_uid'], 7, reason: 'si riparte da dove si era arrivati');
  });
}
