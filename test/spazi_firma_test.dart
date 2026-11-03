import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/signature.dart';
import 'package:digimail/ui/rich_editor.dart';

void main() {
  test('fra ultima parola e firma restano solo le due righe vuote', () {
    final corpo = RichDoc.trimBreaks(
      RichDoc.toHtml(RichDoc.fromText('Mi mandi\nGrazieee\n\n\n')),
    );
    expect(corpo, '<div>Mi mandi<br/>Grazieee</div>');
    final firma = RichDoc.trimBreaks('<br><p>&nbsp;</p><div><br></div><div>Mario</div><br>');
    expect(firma, '<div>Mario</div>');
    expect('<div>$corpo</div><br><br><div>$firma</div>',
        '<div><div>Mi mandi<br/>Grazieee</div></div><br><br><div><div>Mario</div></div>');
  });

  test('firma di Outlook: righe vicine e niente </p> scritto come testo', () {
    final h = SignatureTools.forSend(
      '<p class=MsoNormal><b>Mario Rossi</b><o:p></o:p></p>'
      '<p class=MsoNormal>Consulente</p><p class=MsoNormal>&nbsp;</p>'
      '<p class=MsoNormal>&lt; /p&gt;</p><p class=MsoNormal>Via Roma 1</p>',
    );
    expect(h, isNot(contains('<p')));
    expect(h, isNot(contains('/p')));
    expect(h, '<b>Mario Rossi</b><br>Consulente<br><br>Via Roma 1');
  });
}
