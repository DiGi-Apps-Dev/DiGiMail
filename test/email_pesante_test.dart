import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/mail/testo_tollerante.dart';
import 'package:digimail/models.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory cartella;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
    cartella = await Directory.systemTemp.createTemp('corpi');
    Db.cartellaCorpiPerTest = cartella;
  });
  tearDownAll(() async {
    Db.cartellaCorpiPerTest = null;
    await cartella.delete(recursive: true);
  });

  test('email da 3 MB: l\'elenco non legge il testo, il testo va in un file e si riapre intero', () async {
    final m = Msg(accountId: 1, folder: 'INBOX', uid: 9001, subject: 'Pesante', fromAddr: 'a@b.ch', date: DateTime.now());
    await Db.i.upsertMessages([m]);
    final grande = '<p>${'x' * 3000000}</p>';
    await Db.i.saveBody(1, 'INBOX', 9001, html: grande, text: 'corto');
    final elenco = await Db.i.messages(1, 'INBOX');
    final r = elenco.firstWhere((e) => e.uid == 9001);
    expect(r.bodyHtml, isNull, reason: 'l\'elenco non porta il testo');
    expect(r.bodyText, isNull);
    expect(r.hasBody, isTrue);
    expect(r.bodyHead, 'corto');
    final d = await Db.i.db;
    final riga = await d.rawQuery('SELECT length(body_html) AS n FROM messages WHERE uid=9001');
    expect(riga.first['n'] as int, lessThan(100), reason: 'nella riga resta solo il segno');
    expect(cartella.listSync(), isNotEmpty);
    await Db.i.conCorpo(r);
    expect(r.bodyHtml, grande);
    expect(r.bodyText, 'corto');
    final uno = await Db.i.message(1, 'INBOX', 9001);
    expect(uno!.bodyHtml!.length, grande.length, reason: 'aprendo una sola email il testo c\'è');
  });

  test('file del testo sparito: l\'email risulta da riscaricare', () async {
    final m = Msg(accountId: 1, folder: 'INBOX', uid: 9002, date: DateTime.now());
    await Db.i.upsertMessages([m]);
    await Db.i.saveBody(1, 'INBOX', 9002, html: 'y' * 400000);
    for (final f in cartella.listSync()) {
      if (f.path.endsWith('_9002.html')) f.deleteSync();
    }
    final r = (await Db.i.messages(1, 'INBOX')).firstWhere((e) => e.uid == 9002);
    await Db.i.conCorpo(r);
    expect(r.hasBody, isFalse);
  });

  test('base64 con bit avanzati («Cm==», email Proton) si legge come in Gmail e K-9', () {
    expect(() => base64.decode('QUJDCm=='), throwsFormatException);
    expect(utf8.decode(base64Tollerante('QUJDCm==')), 'ABC\n');
    expect(utf8.decode(base64Tollerante('QUJD\r\nCg==')), 'ABC\n');
  });

  test('email HTML codificata male: il testo si legge, senza errore', () {
    final html = base64.encode(utf8.encode('<p>Black Friday è arrivato</p>\n'));
    final rotto = '${html.substring(0, html.length - 3)}m==';
    final grezzo = 'From: a@b.ch\r\nSubject: x\r\nMIME-Version: 1.0\r\n'
        'Content-Type: multipart/alternative; boundary="b1"\r\n\r\n'
        '--b1\r\nContent-Type: text/html; charset=utf-8\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n$rotto\r\n--b1--\r\n';
    final mime = em.MimeMessage.parseFromText(grezzo);
    final t = testoParte(mime, html: true);
    expect(t, contains('Black Friday è arrivato'));
  });

  test('foto attaccata «dentro il testo» ma non usata: si trova', () {
    final foto = base64.encode(List<int>.generate(300, (i) => i % 256));
    final grezzo = 'From: a@b.ch\r\nSubject: x\r\nMIME-Version: 1.0\r\n'
        'Content-Type: multipart/related; boundary="r1"\r\n\r\n'
        '--r1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nGrazie. [image0.jpeg]\r\n'
        '--r1\r\nContent-Type: image/jpeg; name="image0.jpeg"\r\n'
        'Content-Disposition: inline; filename="image0.jpeg"\r\n'
        'Content-ID: <ABC123@x>\r\nContent-Transfer-Encoding: base64\r\n\r\n$foto\r\n--r1--\r\n';
    final mime = em.MimeMessage.parseFromText(grezzo);
    final orfane = immaginiNonUsate(mime, cidUsati(null));
    expect(orfane, hasLength(1));
    expect(orfane.first.tipo, 'image/jpeg');
    expect(orfane.first.dati.length, 300);
    // Usata dal testo: resta dentro il testo, non si aggiunge in fondo.
    expect(immaginiNonUsate(mime, cidUsati('<img src="cid:ABC123@x">')), isEmpty);
    // Fra gli allegati solo quando è stata messa in fondo.
    final senza = attachmentInfos(mime);
    final con = attachmentInfos(mime, mostraCid: cidMessiInFondo('<img data-digimail-allegato="abc123@x" src="data:,">'));
    expect(senza.where((i) => i.fileName == 'image0.jpeg'), isEmpty);
    expect(con.where((i) => i.fileName == 'image0.jpeg'), hasLength(1));
  });
}
