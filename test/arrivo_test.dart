import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/models.dart';
import 'package:digimail/notify.dart';
import 'package:digimail/notify_pending.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/push_service.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

Account casella() => Account(
  address: 'utente@esempio.it',
  name: 'Prova',
  imapHost: 'imap.esempio.it',
  smtpHost: 'smtp.esempio.it',
);

/// Quali email sono finite nel registro degli avvisi, con l'esito.
Future<Map<int, String>> registro(int id) async => {
  for (final r in await Db.i.pushLog(accountId: id))
    r['uid'] as int: (r['result'] ?? '') as String,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late int id;
  late FakeBackend fake;
  // Le notifiche che l'app avrebbe mostrato: (id, titolo, corpo, senza suono?).
  final mostrate = <(int, String, String, bool)>[];

  setUp(() async {
    mostrate.clear();
    Notify.sink = (nid, titolo, corpo, d, payload) async {
      mostrate.add((nid, titolo, corpo, d.android?.silent ?? false));
    };
    FlutterSecureStorage.setMockInitialValues({});
    await Backends.forgetAll();
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
    id = await Db.i.saveAccount(casella());
    final a = (await Db.i.account(id))!;
    fake = FakeBackend(a);
    Backends.factory = (_) => fake;
  });

  test('C1: Posta in arrivo vuota, la prima email che arriva viene avvisata', () async {
    final a = (await Db.i.account(id))!;
    await Ops.refresh(a, notify: false); // casella vuota: prima sincronizzazione
    expect(await Db.i.pendingNotify(id), isEmpty);
    fake.server.add(testMsg(id, 1, 'Anna', 'Prima'));
    expect(await checkNewMail(a), 1);
    expect(await registro(id), {1: 'ok'});
    expect(await Db.i.pendingNotify(id), isEmpty);
    expect(mostrate.where((n) => n.$1 == Notify.idFor(id, 1)).length, 1);
  });

  test('C1: dopo «Cancella le email scaricate» la prima che arriva suona', () async {
    final a = (await Db.i.account(id))!;
    fake.server.add(testMsg(id, 1, 'Anna', 'Vecchia', seen: true));
    await Ops.refresh(a, notify: false);
    await Db.i.wipeCache();
    fake.server.add(testMsg(id, 2, 'Bruno', 'Nuova'));
    expect(await checkNewMail(a), 1);
    expect((await registro(id)).keys, [2]);
  });

  test('C2: scaricata prima dall\'app aperta, suona lo stesso quando arriva l\'avviso', () async {
    final a = (await Db.i.account(id))!;
    fake.server.add(testMsg(id, 1, 'Anna', 'Vecchia', seen: true));
    await Ops.refresh(a, notify: false);
    fake.server.add(testMsg(id, 2, 'Bruno', 'Nuova'));
    // L'app aperta aggiorna la lista senza avvisare: l'email è già nella copia locale.
    await Ops.refresh(a, notify: false);
    expect((await Db.i.pendingNotify(id)).map((m) => m.uid), [2]);
    // Poi arriva l'avviso del NAS.
    expect(await checkNewMail(a), 1);
    expect((await registro(id)).keys, [2]);
  });

  test('un\'email avvisata non suona due volte, nemmeno con due controlli insieme', () async {
    final a = (await Db.i.account(id))!;
    await Ops.refresh(a, notify: false);
    fake.server.add(testMsg(id, 1, 'Anna', 'Una'));
    final r = await Future.wait([checkNewMail(a), checkNewMail(a), notifyPending(a)]);
    expect(r.fold<int>(0, (x, y) => x + y), 1);
    expect((await Db.i.pushLog(accountId: id)).length, 1);
  });

  test('un\'email letta prima dell\'avviso non suona e non resta in sospeso', () async {
    final a = (await Db.i.account(id))!;
    await Ops.refresh(a, notify: false);
    fake.server.add(testMsg(id, 1, 'Anna', 'Una'));
    await Ops.refresh(a, notify: false);
    fake.server.first.seen = true; // letta altrove: il server lo dice
    await Db.i.setSeen(id, 'INBOX', [1], true);
    expect(await checkNewMail(a), 0);
    expect(mostrate, isEmpty);
    expect(await Db.i.pendingNotify(id), isEmpty);
  });

  test('la prima scaricata di una casella nuova non avvisa delle vecchie', () async {
    final a = (await Db.i.account(id))!;
    fake.server
      ..add(testMsg(id, 1, 'Anna', 'Vecchia'))
      ..add(testMsg(id, 2, 'Bruno', 'Vecchia due'));
    expect(await checkNewMail(a), 0);
    expect(await Db.i.pendingNotify(id), isEmpty);
  });

  test('C17: nelle ore silenziose la notifica compare lo stesso, senza suono', () async {
    final a = (await Db.i.account(id))!;
    await Ops.refresh(a, notify: false);
    final adesso = DateTime.now().hour;
    Settings.i.quietHours = '$adesso-${(adesso + 2) % 24}';
    expect(Notify.inQuietHours(), isTrue);
    fake.server.add(testMsg(id, 1, 'Anna', 'Di notte'));
    await checkNewMail(a);
    expect(await registro(id), {1: 'silenziosa'});
    expect(mostrate.single.$4, isTrue); // compare, ma senza suono
  });

  test('C24: ogni esito è nel registro, anche quando la notifica è spenta', () async {
    final a = (await Db.i.account(id))!;
    await Ops.refresh(a, notify: false);
    Settings.i.notifyEnabled = false;
    fake.server.add(testMsg(id, 1, 'Anna', 'Spenta'));
    await checkNewMail(a);
    expect(await registro(id), {1: 'spenta'});
    expect(mostrate, isEmpty);
  });

  test('C32: togliendo la casella spariscono invii, coda e registro', () async {
    await Db.i.addScheduled(id, DateTime.now(), '{}');
    await Db.i.addPendingOp(id, 'seen', 'INBOX', [1], '1');
    await Db.i.logPush(id, 1, DateTime.now(), DateTime.now(), DateTime.now());
    await Db.i.setFolderSync(id, 'INBOX', 5, 10);
    await Db.i.removeAccount(id);
    expect(await Db.i.scheduledList(), isEmpty);
    expect(await Db.i.pendingOps(), isEmpty);
    expect(await Db.i.pushLog(), isEmpty);
    expect(await Db.i.folderSync(id, 'INBOX'), isNull);
  });

  test('P9: un\'email rimessa in arrivo dallo Spam non suona come nuova', () async {
    final a = (await Db.i.account(id))!;
    final d = await Db.i.db;
    await Db.i.upsertMessages([
      testMsg(id, 7, 'Anna', 'Scambiata', folder: 'Junk')..messageId = '<x@y>',
    ]);
    expect(await Db.i.seenElsewhere(id, 'INBOX', '<x@y>'), isTrue);
    expect(await Db.i.seenElsewhere(id, 'INBOX', '<altro@y>'), isFalse);
    expect(d.isOpen, isTrue);
    expect(a.id, id);
  });
}
