import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/models.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/sender_logo.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/ui/pickers.dart';
import 'package:digimail/ui/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  final acc = Account(
    id: 1,
    address: 'a@b.it',
    name: 'A',
    imapHost: 'i',
    smtpHost: 's',
  );
  final raw = [
    const Folder('Privato', 'Privato', 'other'),
    const Folder('[Gmail]/Bozze', 'Bozze', 'drafts'),
    const Folder('Archive', 'Archive', 'archive'),
    const Folder('Junk', 'Junk', 'junk'),
    const Folder('Bozze', 'Bozze', 'other'),
    const Folder('Sent', 'Sent', 'sent'),
    const Folder('Trash', 'Trash', 'trash'),
    const Folder('INBOX', 'INBOX', 'inbox'),
  ];

  test('ordine di partenza: arrivo, bozze, inviati, cestino, altre, spam; niente archivio, una sola Bozze', () {
    final l = orderFolders(acc, raw).map((f) => f.path).toList();
    expect(l, ['INBOX', '[Gmail]/Bozze', 'Sent', 'Trash', 'Privato', 'Junk']);
  });

  test('l\'ordine scelto a mano resta, anche con cartelle nuove', () async {
    await Settings.i.setFolderOrder(1, ['Privato', 'INBOX', 'Junk']);
    final l = orderFolders(acc, raw).map((f) => f.path).toList();
    expect(l.take(3), ['Privato', 'INBOX', 'Junk']);
    expect(l.length, 6);
  });

  test('iniziali di nome e cognome', () {
    expect(initialsOf('Simone Rizzo', 'info@x.com'), 'SR');
    expect(initialsOf('Mario', 'm@x.com'), 'M');
    expect(initialsOf('', 'anna.verdi@x.com'), 'AV');
    expect(initialsOf('Anna Maria Verdi', 'a@x.com'), 'AV');
  });

  test('logo del mittente: solo per domini propri, non per Gmail e simili', () {
    expect(SenderLogos.domainOf('x@gmail.com'), isNull);
    expect(SenderLogos.domainOf('info@rizzoaiacademy.com'), 'rizzoaiacademy.com');
    expect(SenderLogos.domainOf('n@mail.azienda.com'), 'azienda.com');
  });

  test('testo sempre nero, sinistra e senza sfondi del mittente', () {
    const html =
        '<div style="color:#999;background-color:#eee;text-align:center;line-height:40px;font-size:14px">Ciao</div><font color="red">x</font><td bgcolor="#000" align="center">y</td>';
    final out = Ops.cleanHtml(html, blockImages: false, blockTracking: true).html;
    expect(out, isNot(contains('color')));
    expect(out, isNot(contains('text-align')));
    expect(out, isNot(contains('line-height')));
    expect(out, isNot(contains('align=')));
    expect(out, contains('font-size:14px'));
  });

  test('i gesti non danno mai «archivia»', () async {
    final s = Settings.i;
    s.swipeLongRight = Act.archive;
    expect(s.swipeLongRight, Act.toggleRead);
    expect(s.toolbar.contains(Act.archive), isFalse);
  });
}
