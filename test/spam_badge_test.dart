import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late int id;

  setUp(() async {
    await Db.i.openForTest();
    id = await Db.i.saveAccount(
      Account(
        address: 'utente@esempio.it',
        name: 'Prova',
        imapHost: 'imap.esempio.it',
        smtpHost: 'smtp.esempio.it',
      ),
    );
  });

  test('il numero sull\'icona conta anche le non lette recenti di Spam e Cestino', () async {
    await Db.i.upsertMessages([
      testMsg(id, 1, 'Anna', 'In arrivo'),
      testMsg(id, 2, 'Bot', 'Nello spam', folder: 'Junk'),
      testMsg(id, 3, 'Bot', 'Nel cestino', folder: 'Trash'),
      testMsg(id, 4, 'Bot', 'Spam vecchio', folder: 'Junk', date: DateTime.now().subtract(const Duration(days: 9))),
      testMsg(id, 5, 'Bot', 'Spam letto', folder: 'Junk', seen: true),
      testMsg(id, 6, 'Bot', 'Altra cartella', folder: 'Altro'),
    ]);
    // Prima che le cartelle siano note, conta solo la Posta in arrivo.
    expect(await Db.i.unseenAlertCount(id), 1);
    await Db.i.setFolderRole(id, 'Junk', 'junk');
    await Db.i.setFolderRole(id, 'Trash', 'trash');
    expect(await Db.i.unseenAlertCount(id), 3);
    // Il menu mostra il numero sulla cartella giusta, uguale a quello dell'icona.
    expect(await Db.i.unseenAlertByFolder(id), {'Junk': 1, 'Trash': 1});
  });

  test('un\'email spostata dall\'app non risulta arrivata nel Cestino', () async {
    final m = testMsg(id, 7, 'Anna', 'Da cancellare')..messageId = '<x@y>';
    await Db.i.upsertMessages([m]);
    expect(await Db.i.wasMoved(id, '<x@y>'), isFalse);
    await Db.i.deleteLocal(id, 'INBOX', [7]);
    expect(await Db.i.wasMoved(id, '<x@y>'), isTrue);
    expect(await Db.i.wasMoved(id, '<altra@y>'), isFalse);
  });

  test('le email in attesa di avviso si trovano in qualunque cartella', () async {
    await Db.i.upsertMessages([
      testMsg(id, 8, 'Bot', 'Nello spam', folder: 'Junk'),
    ], pending: {8});
    final p = await Db.i.pendingNotify(id);
    expect(p.map((m) => m.uid), [8]);
  });
}
