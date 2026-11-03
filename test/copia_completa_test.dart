import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/full_backup.dart';
import 'package:digimail/mail/secrets.dart';
import 'package:digimail/models.dart';
import 'package:digimail/rules.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Account acc(String address, {String firma = ''}) => Account(
  address: address,
  name: address.split('@').first,
  imapHost: 'imap.esempio.ch',
  smtpHost: 'smtp.esempio.ch',
  signatureHtml: firma,
);

/// Un telefono vuoto: database, impostazioni e password azzerati.
Future<void> telefonoNuovo([Map<String, Object> prefs = const {}]) async {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues(prefs);
  Settings.i.useForTest(await SharedPreferences.getInstance());
  await Db.i.openForTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('copia completa: salvata su un telefono, ripristinata su uno nuovo', () async {
    await telefonoNuovo();
    // Sul telefono vecchio la prima casella era stata tolta: le altre hanno i numeri 2 e 3.
    final via = await Db.i.saveAccount(acc('via@esempio.ch'));
    await Db.i.removeAccount(via);
    final a = await Db.i.saveAccount(
      acc('info@esempio.ch', firma: '<div>Mario<br>Rossi</div>'),
    );
    final b = await Db.i.saveAccount(acc('utente@esempio.com'));
    await Secrets.setPassword(a, 'segreta-1');
    await Secrets.setPassword(b, 'segreta-2');
    await Secrets.setAiToken('token-ia');
    await Settings.i.setSyncMode(b, 'interval');
    await Settings.i.setSyncMinutes(b, 30);
    Settings.i.defaultAccountId = b;
    Settings.i.notifyDetail = 3;
    await Settings.i.import({'nasPushOk': true});
    await Rules.save([
      Rule(id: 'r1', name: 'tutte', contains: 'x'),
      Rule(id: 'r2', name: 'gmail', accountId: b, contains: 'y'),
    ]);
    await Db.i.block(b, 'spam@male.com');
    await Db.i.addUnsub(a, 'news@shop.ch', 'Shop', 'mailto');
    await Db.i.touchContact('mario@rossi.ch', 'Mario');

    final file = FullBackup.seal(await FullBackup.collect(), 'parola-segreta');
    // Nel file non c'è niente in chiaro.
    final testo = utf8.decode(file);
    expect(testo, isNot(contains('segreta-1')));
    expect(testo, isNot(contains('esempio.ch')));

    expect(
      () => FullBackup.open(file, 'parola-sbagliata'),
      throwsA(isA<FormatException>()),
    );

    // Telefono nuovo: c'è già una casella, così i numeri non combaciano.
    await telefonoNuovo();
    final altra = await Db.i.saveAccount(acc('altra@esempio.ch'));
    final n = await FullBackup.restore(FullBackup.open(file, 'parola-segreta'));
    expect(n, 2);

    final caselle = {for (final x in await Db.i.accounts()) x.address: x};
    expect(caselle.keys, containsAll(['altra@esempio.ch', 'info@esempio.ch', 'utente@esempio.com']));
    final na = caselle['info@esempio.ch']!.id!;
    final nb = caselle['utente@esempio.com']!.id!;
    expect({na, nb}.contains(altra), isFalse);
    expect(caselle['info@esempio.ch']!.signatureHtml, '<div>Mario<br>Rossi</div>');
    expect(await Secrets.password(na), 'segreta-1');
    expect(await Secrets.password(nb), 'segreta-2');
    expect(await Secrets.aiToken(), 'token-ia');

    // Le impostazioni della casella seguono il suo numero nuovo.
    expect(Settings.i.savedSyncMode(nb), 'interval');
    expect(Settings.i.syncMinutes(nb), 30);
    expect(Settings.i.defaultAccountId, nb);
    expect(Settings.i.notifyDetail, 3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('nasPushOk'), isNull); // la registrazione sul NAS si rifà

    final regole = {for (final r in await Rules.load()) r.id: r};
    expect(regole['r1']!.accountId, 0);
    expect(regole['r2']!.accountId, nb);

    expect(await Db.i.isBlocked(nb, 'spam@male.com'), isTrue);
    expect((await Db.i.unsubList()).single['account_id'], na);
    expect((await Db.i.allContacts()).single['address'], 'mario@rossi.ch');
  });

  test('ripristinata due volte: le caselle non si doppiano', () async {
    await telefonoNuovo();
    final a = await Db.i.saveAccount(acc('info@esempio.ch'));
    await Secrets.setPassword(a, 'vecchia');
    final file = FullBackup.seal(await FullBackup.collect(), 'parola-segreta');
    await Secrets.setPassword(a, 'cambiata');
    await FullBackup.restore(FullBackup.open(file, 'parola-segreta'));
    await FullBackup.restore(FullBackup.open(file, 'parola-segreta'));
    final tutte = await Db.i.accounts();
    expect(tutte.length, 1);
    expect(tutte.single.id, a);
    expect(await Secrets.password(a), 'vecchia');
  });

  test('un file qualunque non si scambia per una copia', () {
    expect(
      () => FullBackup.open(utf8.encode('{"a":1}'), 'parola-segreta'),
      throwsA(isA<FormatException>()),
    );
  });
}
