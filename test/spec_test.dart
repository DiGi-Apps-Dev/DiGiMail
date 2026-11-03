import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/models.dart';
import 'package:digimail/notify.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/signature.dart';
import 'package:digimail/ui/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

final Uint8List png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Account acc({int? id = 1}) => Account(
  id: id,
  address: 'utente@esempio.it',
  name: 'SDL',
  imapHost: 'imap.esempio.it',
  smtpHost: 'smtp.esempio.it',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await Backends.forgetAll();
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
  });

  group('R19/R20 firma con immagini', () {
    test(
      'le immagini cid: della firma presa da un\'inviata diventano incorporate',
      () async {
        const html = '<div>Mario<br><img src="cid:logo123@x" width="80"></div>';
        final out = await SignatureTools.embedImages(
          html,
          cidLookup: (cid) async => cid == 'logo123@x' ? png : null,
        );
        expect(out, contains('src="data:image/png;base64,'));
        expect(out, isNot(contains('cid:')));
      },
    );

    test('se l\'immagine non si trova la firma resta com\'è', () async {
      const html = '<img src="cid:mancante">';
      expect(
        await SignatureTools.embedImages(html, cidLookup: (_) async => null),
        html,
      );
    });

    test(
      'nell\'email spedita il logo è una parte in linea con Content-ID dentro multipart/related',
      () async {
        final sig = await SignatureTools.embedImages(
          '<p>Ciao</p><img src="cid:a">',
          cidLookup: (_) async => png,
        );
        final o = Outgoing(
          accountId: 1,
          fromAddress: 'utente@esempio.it',
          to: ['x@y.it'],
          subject: 'Prova',
          text: 'Ciao',
          html: '<div>Ciao</div><div>-- <br>$sig</div>',
        );
        final mime = await ImapBackend.buildMime(o);
        final text = mime.renderMessage();
        expect(text, contains('multipart/related'));
        expect(text, contains('multipart/alternative'));
        expect(
          text.toLowerCase(),
          contains('content-id: <img1-${png.length}@digimail>'),
        );
        expect(text, contains('src="cid:img1-${png.length}@digimail"'));
        expect(text, isNot(contains('data:image')));
        expect(text.toLowerCase(), contains('content-disposition: inline'));
      },
    );

    test('senza immagini il messaggio resta semplice (alternative)', () async {
      final o = Outgoing(
        accountId: 1,
        fromAddress: 'utente@esempio.it',
        to: ['x@y.it'],
        subject: 'Prova',
        text: 'Ciao',
        html: '<div>Ciao</div>',
      );
      final text = (await ImapBackend.buildMime(o)).renderMessage();
      expect(text, isNot(contains('multipart/related')));
    });
  });

  group('R17/R22/R23 coda di invio', () {
    Future<(int, FakeBackend)> setup() async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      return (id, b);
    }

    Outgoing out(int id) => Outgoing(accountId: id, fromAddress: 'utente@esempio.it', to: ['x@y.it'], subject: 'Ciao', text: 'testo');

    test('annulla invio: se annulli prima della scadenza la mail non parte mai', () async {
      final (id, b) = await setup();
      final a = (await Db.i.account(id))!;
      final q = await Ops.queueSend(a, out(id), DateTime.now().add(const Duration(seconds: 5)));
      expect(await Ops.cancelQueued(q), isTrue);
      expect(await Ops.processScheduled(), 0);
      expect(b.sent, isEmpty);
      expect(await Db.i.scheduledList(), isEmpty);
    });

    test('non parte prima dell\'ora, parte dopo, una sola volta', () async {
      final (id, b) = await setup();
      final a = (await Db.i.account(id))!;
      await Ops.queueSend(a, out(id), DateTime.now().add(const Duration(minutes: 5)));
      expect(await Ops.processScheduled(), 0);
      expect(await Db.i.scheduledList(), hasLength(1));
      await Ops.queueSend(a, out(id), DateTime.now().subtract(const Duration(seconds: 1)));
      expect(await Ops.processScheduled(), 1);
      expect(await Ops.processScheduled(), 0);
      expect(b.sent, hasLength(1));
    });

    test('senza rete la mail resta in coda e parte appena la rete torna', () async {
      final (id, b) = await setup();
      final a = (await Db.i.account(id))!;
      await Ops.queueSend(a, out(id), DateTime.now().subtract(const Duration(minutes: 1)));
      b.offline = true;
      expect(await Ops.processScheduled(), 0);
      expect((await Db.i.scheduledList()).single['status'], 'pending');
      b.offline = false;
      expect(await Ops.processScheduled(), 1);
      expect(b.sent, hasLength(1));
      expect(await Db.i.scheduledList(), isEmpty);
    });

    test('un errore vero (non di rete) la segna «non riuscita» e resta in elenco per riprovare', () async {
      final (id, b) = await setup();
      final a = (await Db.i.account(id))!;
      b.sendError = StateError('Accesso rifiutato');
      await Ops.queueSend(a, out(id), DateTime.now().subtract(const Duration(minutes: 1)));
      expect(await Ops.processScheduled(), 0);
      expect((await Db.i.scheduledList()).single['status'], 'failed');
      b.sendError = null;
      final row = (await Db.i.scheduledList()).single;
      await Db.i.rescheduleNow(row['id'] as int);
      expect(await Ops.processScheduled(), 1);
    });

    test('riaprire una mail annullata ridà testo, citazione, allegati e firma come prima', () {
      final init = ComposeInit.fromPayload({
        'accountId': 1,
        'fromAddress': 'utente@esempio.it',
        'to': ['x@y.it'],
        'cc': <String>[],
        'bcc': <String>[],
        'subject': 'Re: Ciao',
        'text': 'testo + firma',
        'attachmentPaths': ['/a/b.pdf'],
        'compose': {'body': 'testo', 'quote': '\n> citato', 'useSig': false},
      });
      expect(init.body, 'testo');
      expect(init.quote, '\n> citato');
      expect(init.files, ['/a/b.pdf']);
      expect(init.useSignature, isFalse);
    });
  });

  group('R26 operazioni fatte senza rete', () {
    Future<(int, Account, FakeBackend, Msg)> setup() async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final m = testMsg(id, 1, 'Anna', 'Uno');
      b.server.add(m);
      await Db.i.upsertMessages([m]);
      return (id, a, b, m);
    }

    test('segna come letta senza rete: resta in coda e arriva al server dopo', () async {
      final (id, a, b, m) = await setup();
      b.offline = true;
      await Ops.perform(Act.toggleRead, a, [m]);
      await Ops.pendingWork;
      expect(await Db.i.pendingOps(), hasLength(1));
      expect((await Db.i.message(id, 'INBOX', 1))!.seen, isTrue);
      expect(b.server.single.seen, isFalse);
      b.offline = false;
      expect(await Ops.flushQueue(), 1);
      expect(b.server.single.seen, isTrue);
      expect(await Db.i.pendingOps(), isEmpty);
    });

    test('elimina senza rete: sparisce subito dalla lista e parte quando torna la rete', () async {
      final (id, a, b, m) = await setup();
      b.offline = true;
      final undo = await Ops.perform(Act.delete, a, [m]);
      expect(undo, isNotNull, reason: 'senza rete l\'Annulla toglie l\'operazione in coda');
      expect(await Db.i.message(id, 'INBOX', 1), isNull);
      expect(await Db.i.pendingOps(), hasLength(1));
      b.offline = false;
      await Ops.flushQueue();
      expect(b.server.where((x) => x.folder == 'Trash'), hasLength(1));
      expect(b.server.where((x) => x.folder == 'INBOX'), isEmpty);
    });

    test('un errore che non è di rete non resta in coda: l\'email torna in lista', () async {
      final (id, a, b, m) = await setup();
      b.failMove = StateError('Questa casella non ha una cartella Archivio.');
      await expectLater(Ops.perform(Act.archive, a, [m]), throwsA(isA<StateError>()));
      expect(await Db.i.message(id, 'INBOX', 1), isNotNull);
      expect(await Db.i.pendingOps(), isEmpty);
    });
  });

  group('R10 contenuto della notifica', () {
    final m = testMsg(1, 1, 'Anna', 'Fattura di marzo', preview: 'Gentile Mario, in allegato trovi la fattura. ' * 20);
    test('solo mittente: nessun oggetto', () => expect(Notify.detailText(m, 0), 'Nuova email'));
    test('mittente e oggetto', () => expect(Notify.detailText(m, 1), 'Fattura di marzo'));
    test('anteprima breve e lunga', () {
      final short = Notify.detailText(m, 2);
      final long = Notify.detailText(m, 3);
      expect(short.startsWith('Fattura di marzo\nGentile Mario'), isTrue);
      expect(short.length, lessThan(160));
      expect(long.length, greaterThan(short.length));
    });
  });

  group('R25 sincronizzazione per casella', () {
    test('ogni casella ha le sue impostazioni; senza tempo reale tutte vanno a intervallo', () async {
      final s = Settings.i;
      await s.setSyncMode(1, 'interval');
      await s.setSyncMinutes(1, 30);
      await s.setSyncWifiOnly(2, true);
      expect(s.syncMode(1), 'interval');
      expect(s.syncMode(2), 'push');
      expect(s.syncMinutes(1), 30);
      expect(s.syncWifiOnly(2), isTrue);
      expect(s.syncWifiOnly(1), isFalse);
      s.pushService = false;
      await Future<void>.delayed(Duration.zero);
      expect(s.syncMode(2), 'interval');
      expect(s.savedSyncMode(2), 'push');
    });

    test('lo storico tiene fuori solo le email vecchie fuori da In arrivo', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.upsertMessages([
        testMsg(id, 1, 'A', 'vecchia in arrivo', date: DateTime.now().subtract(const Duration(days: 400))),
        testMsg(id, 2, 'B', 'vecchia inviata', folder: 'Sent', date: DateTime.now().subtract(const Duration(days: 400))),
        testMsg(id, 3, 'C', 'recente inviata', folder: 'Sent', date: DateTime.now().subtract(const Duration(days: 2))),
      ]);
      await Db.i.deleteOlderThan(id, 90);
      expect(await Db.i.message(id, 'INBOX', 1), isNotNull);
      expect(await Db.i.message(id, 'Sent', 2), isNull);
      expect(await Db.i.message(id, 'Sent', 3), isNotNull);
      await Db.i.deleteOlderThan(id, 0);
      expect(await Db.i.message(id, 'Sent', 3), isNotNull);
    });
  });
}
