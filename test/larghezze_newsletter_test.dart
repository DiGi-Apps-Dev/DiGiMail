import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:digimail/ops.dart';

const _t = 'Hai una nuova notifica da parte di un utente che ti segue';

final _casi = <String, String>{
  'tabella fissa da 1 px': '<table role="presentation" width="100%" style="table-layout:fixed"><tr><td style="width:1px;padding:0 24px">$_t</td></tr></table>',
  'riquadro inline-block da 1 px': '<div style="display:inline-block;width:100%;max-width:600px"><div style="display:inline-block;width:1px">$_t</div></div>',
  'colonne al 5%': '<table style="width:100%;max-width:600px"><tr><td style="width:5%"></td><td style="width:90%"><span>$_t</span></td><td style="width:5%"></td></tr></table>',
  'tabella da 600 px': '<table width="600" style="min-width:600px"><tr><td width="1">$_t</td></tr></table>',
};

void main() {
  for (final e in _casi.entries) {
    testWidgets('si adatta al telefono: ${e.key}', (t) async {
      t.view.physicalSize = const Size(360 * 2.625, 900);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final c = Ops.cleanHtml(e.value, blockImages: false, blockTracking: true).html;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: HtmlWidget(c, key: const Key('h')),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      final s = t.getSize(find.byKey(const Key('h')));
      expect(s.width, 328);
      expect(s.height, lessThan(200), reason: 'testo in colonna stretta');
    });
  }

  test('le immagini tengono la loro larghezza', () {
    final h = Ops.cleanHtml(
      '<table width="600"><tr><td><img src="cid:logo" width="193"></td></tr></table>',
      blockImages: false,
      blockTracking: true,
    ).html;
    expect(h, contains('width="193"'));
    expect(h, isNot(contains('width="600"')));
  });
}
