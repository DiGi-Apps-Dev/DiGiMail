import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/signature.dart';
import 'package:digimail/ui/rich_editor.dart';

/// Il percorso vero della firma: editor della Firma → salvata → aperta in Scrivi.
String _inScrivi(String saved) => RichDoc.fromHtml(
  SignatureTools.asBlocks(SignatureTools.forSend(saved)),
).toPlainText();

void main() {
  test('firma scritta a mano nell\'editor: salvata e riaperta resta a righe', () {
    final saved = RichDoc.toHtml(
      RichDoc.fromText('Mario Rossi\nVia Roma 1\nCell: 000 000 00 00'),
    );
    // ignore: avoid_print
    print('SALVATA: $saved');
    expect(RichDoc.fromHtml(saved).toPlainText(),
        'Mario Rossi\nVia Roma 1\nCell: 000 000 00 00\n');
    // ignore: avoid_print
    print('IN SCRIVI: ${_inScrivi(saved).replaceAll('\n', '|')}');
    expect(_inScrivi(saved),
        'Mario Rossi\nVia Roma 1\nCell: 000 000 00 00\n');
  });

  test('firma presa da un\'email (righe con <br>)', () {
    final saved = RichDoc.toHtml(
      RichDoc.fromHtml('<b>Mario Rossi</b><br>Via Roma 1<br>Cell: 000'),
    );
    // ignore: avoid_print
    print('SALVATA2: $saved');
    expect(_inScrivi(saved), 'Mario Rossi\nVia Roma 1\nCell: 000\n');
  });

  test('righe vuote e logo nella firma restano', () {
    final saved = RichDoc.toHtml(
      RichDoc.fromText('Mario Rossi\nConsulente\n\nVia Roma 1\nCell: 000'),
    );
    expect(_inScrivi(saved), 'Mario Rossi\nConsulente\n\nVia Roma 1\nCell: 000\n');
    final conLogo = RichDoc.toHtml(
      RichDoc.fromHtml(
        '<b>Mario Rossi</b><br>Consulente<br><img width="40" src="data:image/png;base64,iVBORw0KGgo="><br>Via Roma 1',
      ),
    );
    final testo = _inScrivi(conLogo);
    expect(testo, contains('Mario Rossi\nConsulente'));
    expect(testo, contains('\nVia Roma 1'));
  });

  test('firma Outlook a paragrafi', () {
    final saved = RichDoc.toHtml(
      RichDoc.fromHtml(
        '<p class=MsoNormal><b>Mario Rossi</b></p>'
        '<p class=MsoNormal>Via Roma 1</p><p class=MsoNormal>Cell: 000</p>',
      ),
    );
    // ignore: avoid_print
    print('SALVATA3: $saved');
    expect(_inScrivi(saved), 'Mario Rossi\nVia Roma 1\nCell: 000\n');
  });

  test('Firma Outlook: il logo resta di 193 px, non diventa a tutta larghezza', () {
    const outlook =
        """<p class=MsoNormal><span><img width=193 height=59 style='width:2.0069in;height:.618in' id="x" src="data:image/png;base64,iVBORw0KGgo="></span></p>""";
    final out = RichDoc.toHtml(RichDoc.fromHtml(outlook));
    expect(out, contains('width="193"'));
    const soloStile =
        '<div><img style="width:2.0069in" src="data:image/png;base64,iVBORw0KGgo="></div>';
    expect(RichDoc.toHtml(RichDoc.fromHtml(soloStile)), contains('width="193"'));
  });
}
