import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/ui/email_web.dart';

void main() {
  test('pagina per il motore del browser: niente script, stili e struttura tenuti, viewport del telefono', () {
    const email =
        '<html><head><style>.x{color:red}</style><script>alert(1)</script></head>'
        '<body bgcolor="#f4f4f4" style="margin:0"><table width="600"><tr><td class="x">Ciao</td></tr></table>'
        '<script>rubaDati()</script></body></html>';
    final p = EmailWeb.pagina(email);
    expect(p, isNot(contains('alert(1)')));
    expect(p, isNot(contains('rubaDati')));
    expect(p, contains('.x{color:red}'));
    expect(p, contains('bgcolor="#f4f4f4"'));
    expect(p, contains('<table width="600">'));
    expect(p, contains('name="viewport" content="width=device-width"'));
    // La testa aggiunta sta dentro <head>, una volta sola.
    expect('width=device-width'.allMatches(p).length, 1);
    expect(p.indexOf('<meta name="viewport"'), greaterThan(p.indexOf('<head>')));
    expect(p.indexOf('<meta name="viewport"'), lessThan(p.indexOf('</head>')));
  });

  test('email senza html e body: il testo resta tutto, in una pagina intera', () {
    final p = EmailWeb.pagina('<p>Ciao</p><p>Secondo</p>');
    expect(p, contains('<p>Ciao</p><p>Secondo</p>'));
    expect(p, startsWith('<!doctype html>'));
    expect(p, contains('name="viewport"'));
  });

  test('email che vieta lo zoom: la nostra riga viene dopo la sua e vince; niente meta refresh', () {
    const email =
        '<html><head><meta name="viewport" content="width=device-width, maximum-scale=1, user-scalable=no">'
        '<meta http-equiv="refresh" content="0;url=https://x.example">'
        '</head><body>x</body></html>';
    final p = EmailWeb.pagina(email);
    expect(p, isNot(contains('http-equiv="refresh"')));
    expect(
      p.lastIndexOf('content="width=device-width">'),
      greaterThan(p.indexOf('user-scalable=no')),
    );
  });

  test('email con <html> ma senza <head>: la testa viene aggiunta', () {
    final p = EmailWeb.pagina('<html><body>x</body></html>');
    expect(p, contains('<html><head><meta charset="utf-8"><meta name="viewport"'));
  });
}
