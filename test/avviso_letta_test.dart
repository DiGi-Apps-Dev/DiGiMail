import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/models.dart';
import 'package:digimail/nas_push.dart';
import 'package:digimail/notify.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late int id;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Notify.sink = (a, b, c, d, e) async {};
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

  tearDown(() => Notify.sink = null);

  test('l\'avviso «letta» dal NAS segna l\'email letta e cala il numerino', () async {
    await Db.i.upsertMessages([
      testMsg(id, 1, 'Anna', 'Uno'),
      testMsg(id, 2, 'Bruno', 'Due'),
      testMsg(id, 3, 'Carla', 'Tre'),
    ]);
    expect(await Db.i.unseenAlertCount(id), 3);
    await NasPush.handle({'tipo': 'letta', 'casella': 'Utente@Esempio.it', 'uid': '2'});
    expect(await Db.i.unseenAlertCount(id), 2);
    expect((await Db.i.message(id, 'INBOX', 2))!.seen, isTrue);
    expect((await Db.i.message(id, 'INBOX', 1))!.seen, isFalse);
  });

  test('un avviso «letta» per una casella o un\'email sconosciuta non fa danni', () async {
    await Db.i.upsertMessages([testMsg(id, 1, 'Anna', 'Uno')]);
    await NasPush.handle({'tipo': 'letta', 'casella': 'altra@esempio.it', 'uid': '1'});
    await NasPush.handle({'tipo': 'letta', 'casella': 'utente@esempio.it', 'uid': '99'});
    await NasPush.handle({'tipo': 'letta', 'casella': 'utente@esempio.it'});
    expect(await Db.i.unseenAlertCount(id), 1);
  });
}
