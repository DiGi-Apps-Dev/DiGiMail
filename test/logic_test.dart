import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show Attribute, BackgroundAttribute, LinkAttribute;
import 'package:digimail/linkify.dart';
import 'package:digimail/ui/rich_editor.dart';
import 'package:digimail/ai.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/mail/servers.dart';
import 'package:digimail/models.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/rules.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/signature.dart';
import 'package:digimail/ui/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

Account acc({int? id = 1, String address = 'utente@esempio.it'}) => Account(
  id: id,
  address: address,
  name: 'Prova',
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

  group('Fornitori', () {
    test('riconosce Gmail, Outlook, iCloud, Yahoo', () {
      expect(presetFor('a@gmail.com')!.kind, AccountKind.gmail);
      expect(presetFor('a@hotmail.it')!.oauthMicrosoft, isTrue);
      expect(presetFor('a@icloud.com')!.needsAppPassword, isTrue);
      expect(presetFor('a@yahoo.it')!.kind, AccountKind.yahoo);
      expect(presetFor('a@miodominio.ch'), isNull);
    });
  });

  group('Database', () {
    test('salva account e messaggi, conta le non lette', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.upsertMessages([
        testMsg(id, 1, 'Anna', 'Uno'),
        testMsg(id, 2, 'Bruno', 'Due', seen: true),
      ]);
      expect(await Db.i.unseenCount(id, 'INBOX'), 1);
      expect((await Db.i.messages(id, 'INBOX')).length, 2);
    });

    test('email vecchie: cancellate, lette o con stella altrove si riallineano', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.upsertMessages([
        testMsg(id, 10, 'Anna', 'Cancellata dal PC'),
        testMsg(id, 11, 'Bruno', 'Letta dal PC'),
        testMsg(id, 12, 'Carla', 'Con stella dal PC', seen: true),
        testMsg(id, 13, 'Dario', 'Invariata', seen: true),
        testMsg(id, 99, 'Recente', 'Fuori dal riallineamento'),
      ]);
      expect(await Db.i.lowestCachedUid(id, 'INBOX', 50), 10);
      final r = await Db.i.reconcileOlder(id, 'INBOX', 50, {
        11: (seen: true, flagged: false, answered: false),
        12: (seen: true, flagged: true, answered: false),
        13: (seen: true, flagged: false, answered: false),
      });
      expect(r, (2, 1));
      final all = {for (final m in await Db.i.messages(id, 'INBOX')) m.uid: m};
      expect(all.containsKey(10), isFalse);
      expect(all[11]!.seen, isTrue);
      expect(all[12]!.flagged, isTrue);
      expect(all.containsKey(99), isTrue, reason: 'le recenti non si toccano');
    });

    test('un aggiornamento vuoto non cancella mittente, oggetto e data', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final orig = testMsg(id, 1, 'Anna', 'Preventivo');
      await Db.i.upsertMessages([orig]);
      await Db.i.upsertMessages([
        Msg(
          accountId: id,
          folder: 'INBOX',
          uid: 1,
          date: DateTime.now(),
          hasAtt: true,
          answered: true,
        ),
      ]);
      final m = (await Db.i.messages(id, 'INBOX')).single;
      expect(m.sender, orig.sender);
      expect(m.subject, 'Preventivo');
      expect(
        m.date.millisecondsSinceEpoch,
        orig.date.millisecondsSinceEpoch,
      );
      expect(m.hasAtt, isTrue);
      expect(m.answered, isTrue);
    });

    test('le immagini cid: diventano immagini dentro il testo', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      final html = await SignatureTools.inlineCid(
        '<p>Ciao</p><img src="cid:logo@x" width="80"><img src="https://a.b/c.png">',
        (cid) async => cid == 'logo@x' ? png : null,
      );
      expect(html, contains('src="data:image/png;base64,'));
      expect(html, isNot(contains('cid:')));
      expect(html, contains('https://a.b/c.png'));
    });

    test('firma di Outlook senza segno: presa intera con il logo', () {
      const html =
          '<html><body><div class=WordSection1><p class=MsoNormal>Se hai domande chiedimi.<o:p></o:p></p>'
          '<p class=MsoNormal>Saluti.<o:p></o:p></p><p class=MsoNormal>&nbsp;</p>'
          '<p class=MsoNormal><b>Mario Rossi</b></p><p class=MsoNormal>Consulente</p>'
          '<p class=MsoNormal><img width=230 src="cid:image001.png@01DA"></p>'
          '<p class=MsoNormal>Via Roma 1</p></div>'
          '<div id="divRplyFwdMsg"><p>Da: Andrea</p></div></body></html>';
      final sig = SignatureTools.extract(html: html)!;
      expect(sig, contains('cid:image001.png@01DA'));
      expect(sig, contains('<b>Mario Rossi</b>'));
      expect(sig, contains('Via Roma 1'));
      expect(sig, isNot(contains('Saluti')));
      expect(sig, isNot(contains('chiedimi')));
      expect(sig, isNot(contains('Andrea')));
    });

    test('link, email e numeri scritti come testo diventano cliccabili', () {
      final h = linkify(
        '<p>Vedi www.esempio.ch e https://a.b/c?x=1&amp;y=2.</p>'
        '<p>Scrivi a lavoro@azienda.example</p>'
        '<p>Cell: +41 79 000 11 22 Uff.: 091 000 33 44 il 01.12.2026</p>'
        '<a href="https://gia.ch">https://gia.ch</a><style>a@b.ch</style>',
      );
      expect(h, contains('<a href="https://www.esempio.ch">www.esempio.ch</a>'));
      expect(h, contains('<a href="https://a.b/c?x=1&y=2">https://a.b/c?x=1&amp;y=2</a>.'));
      expect(h, contains('<a href="mailto:lavoro@azienda.example">'));
      expect(h, contains('<a href="tel:+41790001122">+41 79 000 11 22</a>'));
      expect(h, contains('<a href="tel:0910003344">091 000 33 44</a>'));
      expect(h, isNot(contains('tel:01')));
      expect('<a href'.allMatches(h).length, 6); // 5 nuovi + quello che c'era
      expect('https://gia.ch">https://gia.ch</a>'.allMatches(h).length, 1);
      expect(h, contains('<style>a@b.ch</style>'));
    });

    test('testo con grassetto ed evidenziato diventa HTML per email', () {
      final d = RichDoc.fromText('Ciao Andrea\nseconda riga');
      d.format(0, 4, Attribute.bold);
      d.format(5, 6, const BackgroundAttribute('#ffff00'));
      final h = RichDoc.toHtml(d);
      expect(h, contains('<strong>Ciao</strong>'));
      expect(h, contains('background-color:#ffff00'));
      expect(h, isNot(contains('<p')));
      final back = RichDoc.fromDeltaJson(RichDoc.deltaJson(d));
      expect(back.toPlainText(), 'Ciao Andrea\nseconda riga\n');
    });

    test('firma con logo: entra nell\'editor ed esce con la sua larghezza', () {
      final d = RichDoc.fromHtml(
        '<p><b>Mario Rossi</b></p><p><img width=230 src="data:image/png;base64,AAAA"></p><p>Via Roma 1</p>',
      );
      final h = RichDoc.toHtml(d);
      expect(h, contains('Mario Rossi'));
      expect(h, contains('src="data:image/png;base64,AAAA"'));
      expect(h, contains('width="230"'));
      expect(h, contains('Via Roma 1'));
      expect(h.indexOf('Rossi'), lessThan(h.indexOf('<img')));
      expect(h, contains('<br/>'));
    });

    test('link scritti a mano anche senza https', () {
      expect(RichDoc.linkOk('www.azienda-esempio.ch'), isTrue);
      expect(RichDoc.linkOk('info@negozio.example'), isTrue);
      expect(RichDoc.linkOk('000 000 00 00'), isTrue);
      expect(RichDoc.linkOk('ciao come stai'), isFalse);
      final d = RichDoc.fromText('sito mail tel');
      d.format(0, 4, LinkAttribute('www.azienda-esempio.ch'));
      d.format(5, 4, LinkAttribute('info@negozio.example'));
      d.format(10, 3, LinkAttribute('000 000 00 00'));
      final h = RichDoc.toHtml(d);
      expect(h, contains('href="https://www.azienda-esempio.ch"'));
      expect(h, contains('href="mailto:info@negozio.example"'));
      expect(h, contains('href="tel:0000000000"'));
    });

    test('firma corretta a mano: le immagini restano dove sono', () {
      const html = '<b>Mario</b><br><img src="data:image/png;base64,AAA"><br>Via 9';
      final e = SignatureTools.toEditable(html);
      expect(e.text, 'Mario\n\n[immagine 1]\n\nVia 9');
      final back = SignatureTools.fromEditable(
        e.text.replaceFirst('Via 9', 'Via Roma 1'),
        e.images,
      );
      expect(back, contains('<img src="data:image/png;base64,AAA">'));
      expect(back.indexOf('<img'), lessThan(back.indexOf('Via Roma 1')));
    });

    test('una risposta mette il segno «risposto» sull\'originale', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final m = testMsg(id, 1, 'Anna', 'Uno')..messageId = '<abc@x>';
      await Db.i.upsertMessages([m]);
      await Db.i.markAnsweredByMessageId(id, '<abc@x>');
      expect((await Db.i.messages(id, 'INBOX')).single.answered, isTrue);
    });

    test('il rimando nasconde il messaggio finché non scade', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.upsertMessages([testMsg(id, 1, 'Anna', 'Uno')]);
      await Db.i.setSnooze(
        id,
        'INBOX',
        1,
        DateTime.now().add(const Duration(hours: 2)),
      );
      expect(await Db.i.messages(id, 'INBOX'), isEmpty);
      expect((await Db.i.snoozed(id)).length, 1);
      await Db.i.setSnooze(
        id,
        'INBOX',
        1,
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect((await Db.i.messages(id, 'INBOX')).length, 1);
      expect((await Db.i.dueSnoozed()).length, 1);
    });

    test(
      'il blocco vale per indirizzo e per dominio, solo nella casella scelta',
      () async {
        await Db.i.block(1, 'spam@cattivi.it');
        await Db.i.block(2, '@pubblicita.com');
        expect(await Db.i.isBlocked(1, 'SPAM@cattivi.it'), isTrue);
        expect(await Db.i.isBlocked(1, 'altro@cattivi.it'), isFalse);
        expect(await Db.i.isBlocked(2, 'x@pubblicita.com'), isTrue);
        expect(await Db.i.isBlocked(1, 'x@pubblicita.com'), isFalse);
      },
    );

    test(
      'pruneFolder toglie dalla cache ciò che non c\'è più sul server',
      () async {
        final id = await Db.i.saveAccount(acc(id: null));
        await Db.i.upsertMessages([
          testMsg(id, 1, 'A', 'a'),
          testMsg(id, 2, 'B', 'b'),
          testMsg(id, 3, 'C', 'c'),
        ]);
        await Db.i.pruneFolder(id, 'INBOX', 2, {3});
        final left = (await Db.i.messages(
          id,
          'INBOX',
        )).map((m) => m.uid).toSet();
        expect(left, {1, 3});
      },
    );

    test('la ricerca trova per mittente e oggetto', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.upsertMessages([
        testMsg(id, 1, 'Dentista Verdi', 'Fattura di marzo'),
        testMsg(id, 2, 'Altro', 'Ciao'),
      ]);
      expect((await Db.i.search('fattura')).length, 1);
      expect((await Db.i.search('verdi')).length, 1);
    });
  });

  group('Arrivo di email nuove', () {
    test('un mittente bloccato va nello spam, gli altri no', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final bad = testMsg(id, 10, 'Truffa', 'Vinci!');
      final ok = testMsg(id, 11, 'Amico', 'Cena?');
      b.server.addAll([bad, ok]);
      await Db.i.block(id, bad.fromAddr);
      final keep = await Ops.processNew(a, b, [bad, ok]);
      expect(keep.map((m) => m.uid), [11]);
      expect(b.log.any((l) => l.startsWith('move INBOX -> Junk')), isTrue);
    });

    test(
      'un mittente NON bloccato non finisce mai nello spam in automatico',
      () async {
        final id = await Db.i.saveAccount(acc(id: null));
        final a = (await Db.i.account(id))!;
        final b = FakeBackend(a);
        final m = testMsg(id, 5, 'Newsletter', 'Offerta');
        final keep = await Ops.processNew(a, b, [m]);
        expect(keep.length, 1);
        expect(b.log, isEmpty);
      },
    );

    test(
      'le regole agiscono e chi è segnato come letto non viene notificato',
      () async {
        final id = await Db.i.saveAccount(acc(id: null));
        final a = (await Db.i.account(id))!;
        final b = FakeBackend(a);
        Backends.factory = (_) => b;
        final m = testMsg(id, 7, 'Rumorosi', 'Avviso automatico');
        b.server.add(m);
        await Db.i.upsertMessages([m]);
        await Rules.save([
          Rule(id: '1', name: '', contains: 'rumorosi', action: 'markRead'),
        ]);
        final keep = await Rules.apply(a, b, [m]);
        expect(keep, isEmpty);
        await Ops.pendingWork;
        expect(b.log.any((l) => l.startsWith('seen true')), isTrue);
      },
    );
  });

  group('Regole', () {
    test('una regola che sposta nel cestino toglie l\'email e non suona', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final m = testMsg(id, 8, 'Rumorosi', 'Avviso');
      b.server.add(m);
      await Db.i.upsertMessages([m]);
      await Rules.save([
        Rule(id: '1', name: '', contains: 'rumorosi', action: 'delete'),
      ]);
      expect(await Rules.apply(a, b, [m]), isEmpty);
      expect(b.server.where((x) => x.folder == 'Trash'), hasLength(1));
      await Rules.save([]);
    });
  });

  group('Azioni con annulla', () {
    test('elimina e annulla', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final m = testMsg(id, 1, 'Anna', 'Uno');
      b.server.add(m);
      await Db.i.upsertMessages([m]);
      final undo = await Ops.perform(Act.delete, a, [m]);
      expect(await Db.i.messages(id, 'INBOX'), isEmpty);
      expect(b.server.where((x) => x.folder == 'Trash').length, 1);
      expect(undo, isNotNull);
      await undo!();
      expect(b.server.where((x) => x.folder == 'INBOX').length, 1);
      expect(b.server.where((x) => x.folder == 'Trash'), isEmpty);
    });

    test(
      'blocca un mittente: lo registra e sposta il messaggio nello spam',
      () async {
        final id = await Db.i.saveAccount(acc(id: null));
        final a = (await Db.i.account(id))!;
        final b = FakeBackend(a);
        Backends.factory = (_) => b;
        final m = testMsg(id, 1, 'Molesto', 'Compra');
        b.server.add(m);
        await Db.i.upsertMessages([m]);
        await Ops.perform(Act.block, a, [m]);
        expect(await Db.i.isBlocked(id, m.fromAddr), isTrue);
        expect(b.server.where((x) => x.folder == 'Junk').length, 1);
      },
    );

    test(
      'il rimando fa sparire il messaggio e lo riporta quando scade',
      () async {
        final id = await Db.i.saveAccount(acc(id: null));
        final a = (await Db.i.account(id))!;
        final b = FakeBackend(a);
        Backends.factory = (_) => b;
        final m = testMsg(id, 1, 'Anna', 'Uno', seen: true);
        b.server.add(m);
        await Db.i.upsertMessages([m]);
        await Ops.perform(
          Act.snooze,
          a,
          [m],
          snoozeUntil: DateTime.now().subtract(const Duration(seconds: 1)),
        );
        final n = await Ops.wakeSnoozed();
        expect(n, 1);
        expect((await Db.i.message(id, 'INBOX', 1))!.seen, isFalse);
      },
    );
  });

  group('Disiscrizione', () {
    test('One-Click manda la richiesta POST', () async {
      final a = acc();
      String? body;
      final client = MockClient((req) async {
        body = req.body;
        return http.Response('', 200);
      });
      final m = testMsg(1, 1, 'News', 'Offerte')
        ..listUnsub = '<https://esempio.it/u?x=1>, <mailto:u@esempio.it>'
        ..listUnsubPost = true;
      String? link;
      final r = await Ops.unsubscribe(a, m, (l) => link = l, client: client);
      expect(r, UnsubResult.done);
      expect(body, 'List-Unsubscribe=One-Click');
      expect(link, isNull);
    });

    test('solo un link: lo restituisce per aprirlo nel browser', () async {
      final a = acc();
      final m = testMsg(1, 1, 'News', 'Offerte')
        ..listUnsub = '<https://esempio.it/u?x=1>';
      String? link;
      final r = await Ops.unsubscribe(
        a,
        m,
        (l) => link = l,
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(r, UnsubResult.openedLink);
      expect(link, 'https://esempio.it/u?x=1');
    });

    test('mailto: manda un\'email di disiscrizione', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final m = testMsg(id, 1, 'News', 'Offerte')
        ..listUnsub = '<mailto:stop@esempio.it?subject=unsubscribe>';
      final r = await Ops.unsubscribe(a, m, (_) {});
      expect(r, UnsubResult.mailSent);
      expect(b.sent.single.to, ['stop@esempio.it']);
      expect(b.sent.single.subject, 'unsubscribe');
    });

    test('senza intestazione non si può', () async {
      final m = testMsg(1, 1, 'X', 'Y');
      expect(Ops.canUnsubscribe(m), isFalse);
    });
  });

  group('Invio', () {
    test(
      'Ccn a me stesso se attivo, e la rubrica impara i destinatari',
      () async {
        final id = await Db.i.saveAccount(acc(id: null)..bccSelf = true);
        final a = (await Db.i.account(id))!;
        final b = FakeBackend(a);
        Backends.factory = (_) => b;
        await Ops.send(
          Outgoing(
            accountId: id,
            fromAddress: a.address,
            to: ['amico@esempio.it'],
            subject: 'Ciao',
            text: 'x',
          ),
        );
        expect(b.sent.single.bcc, contains(a.address));
        expect((await Db.i.contacts('amico')).length, 1);
      },
    );

    test('Annulla: se il server non dice dove è finita la mail, la si ritrova per Message-ID', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a)..undoBroken = true;
      Backends.factory = (_) => b;
      final m = testMsg(id, 7, 'Procare', 'Notifiche');
      m.messageId = '<abc@procare.ch>';
      b.server.add(m);
      await Db.i.upsertMessages([m]);
      final undo = await Ops.perform(Act.delete, a, [m]);
      expect(b.server.where((x) => x.folder == 'Trash').length, 1);
      expect(b.server.where((x) => x.folder == 'INBOX'), isEmpty);
      await undo!();
      expect(b.server.where((x) => x.folder == 'Trash'), isEmpty);
      expect(b.server.where((x) => x.folder == 'INBOX').length, 1);
    });

    test('P12: lo stesso indirizzo non si aggiunge due volte', () async {
      final a = acc(id: null);
      await Db.i.saveAccount(a);
      expect(await Db.i.hasAddress(a.address), isTrue);
      expect(await Db.i.hasAddress('  ${a.address.toUpperCase()} '), isTrue);
      expect(await Db.i.hasAddress('altro@esempio.it'), isFalse);
    });

    test('C31: un invio rimasto «in invio» da oltre 10 minuti non riparte da solo (potrebbe essere già partito): diventa «non riuscito» e viene segnalato', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final vecchio = await Db.i.addScheduled(
        id,
        DateTime.now().subtract(const Duration(hours: 1)),
        '{}',
      );
      final recente = await Db.i.addScheduled(
        id,
        DateTime.now().subtract(const Duration(hours: 1)),
        '{}',
      );
      expect(await Db.i.claimScheduled(vecchio), isTrue);
      expect(await Db.i.claimScheduled(recente), isTrue);
      expect(await Db.i.claimScheduled(recente), isFalse);
      final d = await Db.i.db;
      await d.update(
        'scheduled',
        {
          'claimed': DateTime.now()
              .subtract(const Duration(minutes: 11))
              .millisecondsSinceEpoch,
        },
        where: 'id=?',
        whereArgs: [vecchio],
      );
      final fermi = (await Db.i.staleSending()).map((r) => r['id']).toList();
      expect(fermi, [vecchio]);
      expect((await Db.i.scheduledById(vecchio))?['status'], 'failed');
      expect((await Db.i.scheduledById(recente))?['status'], 'sending');
      expect(await Db.i.dueScheduled(), isEmpty, reason: 'non torna in coda da solo');
    });

    test('C32: togliendo una casella spariscono invii programmati e operazioni in coda', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      await Db.i.addScheduled(id, DateTime.now(), '{}');
      await Db.i.addPendingOp(id, 'seen', 'INBOX', [1], '');
      expect((await Db.i.pendingScheduled()).length, 1);
      expect((await Db.i.pendingOps()).length, 1);
      await Db.i.removeAccount(id);
      expect(await Db.i.pendingScheduled(), isEmpty);
      expect(await Db.i.pendingOps(), isEmpty);
    });

    test('invio programmato: parte quando scade', () async {
      final id = await Db.i.saveAccount(acc(id: null));
      final a = (await Db.i.account(id))!;
      final b = FakeBackend(a);
      Backends.factory = (_) => b;
      final o = Outgoing(
        accountId: id,
        fromAddress: a.address,
        to: ['x@esempio.it'],
        subject: 'Dopo',
        text: 'ciao',
      );
      await Db.i.addScheduled(
        id,
        DateTime.now().add(const Duration(hours: 1)),
        jsonEncode(o.toJson()),
      );
      expect(await Ops.processScheduled(), 0);
      await Db.i.addScheduled(
        id,
        DateTime.now().subtract(const Duration(minutes: 1)),
        jsonEncode(o.toJson()),
      );
      expect(await Ops.processScheduled(), 1);
      expect(b.sent.length, 1);
      expect((await Db.i.pendingScheduled()).length, 1);
    });
  });

  group('Sicurezza e privacy', () {
    test('toglie i pixel spia e le immagini remote', () {
      const html =
          '<p>Ciao</p><img src="https://t.mailchimp.com/track/open.gif" width="1" height="1"><img src="https://sito.it/foto.jpg"><img src="cid:logo">';
      final soloSpia = Ops.cleanHtml(
        html,
        blockImages: false,
        blockTracking: true,
      );
      expect(soloSpia.blocked, 1);
      expect(soloSpia.html.contains('foto.jpg'), isTrue);
      final tutte = Ops.cleanHtml(html, blockImages: true, blockTracking: true);
      expect(tutte.blocked, 2);
      expect(tutte.html.contains('cid:logo'), isTrue);
    });

    test('segnala i mittenti con SPF/DKIM/DMARC falliti', () {
      final bad = testMsg(1, 1, 'X', 'Y')
        ..authResults = 'mx.google.com; dkim=pass; spf=fail; dmarc=fail';
      final good = testMsg(1, 2, 'X', 'Y')
        ..authResults = 'mx.google.com; dkim=pass; spf=pass; dmarc=pass';
      expect(Ops.suspicion(bad), contains('SPF'));
      expect(Ops.suspicion(good), isNull);
      Settings.i.warnSuspicious = false;
      expect(Ops.suspicion(bad), isNull);
    });
  });

  group('Firma', () {
    test('trova la firma Gmail nell\'HTML', () {
      const html =
          '<div>Ciao</div><div class="gmail_signature"><div>Mario Rossi<br>Via Roma 1</div></div><div>coda</div>';
      final s = SignatureTools.fromHtml(html)!;
      expect(s, contains('Mario Rossi'));
      expect(s.contains('coda'), isFalse);
    });

    test('trova la firma dopo "-- " nel testo', () {
      final s = SignatureTools.fromText(
        'Ciao a tutti\n\n-- \nMario Rossi\nTel 081 123',
      )!;
      expect(s, contains('Mario Rossi'));
      expect(s, contains('<br>'));
    });

    test('trova la firma dopo la formula di chiusura e ignora il citato', () {
      final s = SignatureTools.fromText(
        'Grazie della risposta.\n\nCordiali saluti\nMario Rossi\nDirettore\n\nIl 12/03/2026 10:00 Anna ha scritto:\n> vecchio testo',
      )!;
      expect(s, contains('Mario Rossi'));
      expect(s.contains('vecchio'), isFalse);
    });

    test('nessuna firma: restituisce null', () {
      expect(SignatureTools.fromText('Ok, a domani.'), isNull);
    });
  });

  group('Rimanda', () {
    test('Questa sera è oggi o domani, mai nel passato', () {
      final now = DateTime(2026, 10, 26, 19, 30);
      expect(Ops.snoozeAt('evening', now: now).isAfter(now), isTrue);
      expect(Ops.snoozeAt('tomorrow', now: now), DateTime(2026, 10, 27, 8));
      expect(Ops.snoozeAt('weekend', now: now).weekday, DateTime.saturday);
      expect(Ops.snoozeAt('nextweek', now: now).weekday, DateTime.monday);
    });
  });

  group('Risposte e inoltri', () {
    test('rispondi a tutti toglie le mie caselle e il mittente dai Cc', () {
      final a = acc();
      final m = testMsg(1, 1, 'Anna', 'Riunione')
        ..toAddrs = 'utente@esempio.it, bruno@esempio.it'
        ..ccAddrs = 'carla@esempio.it, anna.anna@esempio.it';
      final init = ComposeInit.from(a, m, Act.replyAll, body: 'testo');
      expect(init.to, [m.fromAddr]);
      expect(init.cc, containsAll(['bruno@esempio.it', 'carla@esempio.it']));
      expect(init.cc.contains('utente@esempio.it'), isFalse);
      expect(init.subject, 'Re: Riunione');
    });
  });

  group('Regole', () {
    test('la regola corrisponde per mittente, oggetto e casella', () {
      final a = acc();
      final m = testMsg(1, 1, 'Banca Uno', 'Estratto conto');
      expect(
        Rule(id: '1', name: '', contains: 'banca', field: 'from').matches(a, m),
        isTrue,
      );
      expect(
        Rule(
          id: '1',
          name: '',
          contains: 'estratto',
          field: 'subject',
        ).matches(a, m),
        isTrue,
      );
      expect(
        Rule(
          id: '1',
          name: '',
          contains: 'estratto',
          field: 'subject',
          accountId: 2,
        ).matches(a, m),
        isFalse,
      );
      expect(
        Rule(
          id: '1',
          name: '',
          contains: 'estratto',
          field: 'subject',
          enabled: false,
        ).matches(a, m),
        isFalse,
      );
    });
  });

  group('IA', () {
    test(
      'chiama l\'endpoint Cloudflare compatibile OpenAI e legge la risposta',
      () async {
        SharedPreferences.setMockInitialValues({'aiAccountId': 'abc123'});
        Settings.i.useForTest(await SharedPreferences.getInstance());
        Uri? url;
        Ai.client = MockClient((req) async {
          url = req.url;
          expect(req.headers['Authorization'], 'Bearer token-prova');
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Riassunto di prova'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        // senza chiave salvata: errore chiaro
        expect(() => Ai.chat('s', 'u'), throwsA(isA<AiException>()));
        expect(url, isNull);
      },
    );

    test('il piano di ricerca si legge anche con testo intorno al JSON', () {
      final p = SearchPlan.parse(
        'Ecco: {"text":"fattura dentista","from":"Verdi","days":120,"unread":null}',
        'x',
      );
      expect(p.text, 'fattura dentista');
      expect(p.from, 'Verdi');
      expect(p.days, 120);
      final m = testMsg(
        1,
        1,
        'Studio Verdi',
        'Fattura marzo',
        date: DateTime.now().subtract(const Duration(days: 30)),
      );
      expect(p.matches(m), isTrue);
      final old = testMsg(
        1,
        2,
        'Studio Verdi',
        'Fattura marzo',
        date: DateTime.now().subtract(const Duration(days: 400)),
      );
      expect(p.matches(old), isFalse);
    });
  });
}
