import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/linkify.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
  });

  test('Programmati: Modifica e poi Indietro senza inviare, l\'email resta', () async {
    final id = await Db.i.addScheduled(1, DateTime.now().add(const Duration(hours: 1)), '{"to":[]}');
    expect(await Db.i.claimEditing(id), isTrue);
    // In modifica non parte.
    expect((await Db.i.dueScheduled()).where((r) => r['id'] == id), isEmpty);
    expect(await Ops.cancelQueued(id), isTrue, reason: 'si può ancora annullare');
    final id2 = await Db.i.addScheduled(1, DateTime.now().add(const Duration(hours: 1)), '{"to":[]}');
    expect(await Db.i.claimEditing(id2), isTrue);
    await Db.i.setScheduledStatus(id2, 'pending');
    final r = await Db.i.scheduledById(id2);
    expect(r, isNotNull, reason: 'prima spariva');
    expect(r!['status'], 'pending');
  });

  test('Programmati: in modifica da più di 2 ore torna in coda', () async {
    final id = await Db.i.addScheduled(1, DateTime.now(), '{"to":[]}');
    expect(await Db.i.claimEditing(id), isTrue);
    final d = await Db.i.db;
    await d.update('scheduled', {'claimed': DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch}, where: 'id=?', whereArgs: [id]);
    await Db.i.releaseStaleEditing();
    expect((await Db.i.scheduledById(id))!['status'], 'pending');
  });

  test('Le immagini su domini click. e links. non sono pixel spia', () {
    const html = '<img src="https://click.mail.esempio.ch/logo.png" width="200"><img src="https://links.esempio.ch/foto.jpg"><img src="https://x.ch/open.gif">';
    final r = Ops.cleanHtml(html, blockImages: false, blockTracking: true);
    expect(r.html, contains('click.mail.esempio.ch/logo.png'));
    expect(r.html, contains('links.esempio.ch/foto.jpg'));
    expect(r.blocked, 1);
  });

  test('Tutte le lettere scritte come entità HTML diventano lettere vere', () {
    expect(testoDaHtml('Gr&uuml;&szlig;e, Fran&ccedil;ois &amp; Mu&ntilde;oz &#8217;ok&#x2019; &ouml;'),
        'Grüße, François & Muñoz ’ok’ ö');
  });
}
