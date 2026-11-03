/// Rende cliccabili, nel testo di un'email, i link, gli indirizzi email e i
/// numeri di telefono scritti come testo semplice. Non tocca i link che ci sono già.

final _skip = RegExp(r'^<(a|style|script|head|title|textarea)\b', caseSensitive: false);
final _close = RegExp(r'^</(a|style|script|head|title|textarea)\s*>', caseSensitive: false);
final _token = RegExp(r'<!--[\s\S]*?-->|<[^>]*>|[^<]+');

final _found = RegExp(
  r'((?:https?://|www\.)[^\s<>"]+)'
  r'|([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})'
  r'|((?<![\w/+.,-])(?:(?:\+|00)\d{1,3}(?:[ ./-]?\d){6,12}|0\d{2}(?:[ ./-]?\d){7})(?![\w.,]?\d))',
);

String _href(String shown) =>
    shown.replaceAll('&amp;', '&').replaceAll('"', '%22');

String _linkText(String t) => t.replaceAllMapped(_found, (m) {
  if (m.group(1) != null) {
    var url = m.group(1)!;
    var tail = '';
    while (url.isNotEmpty && '.,;:!?)\''.contains(url[url.length - 1])) {
      tail = url[url.length - 1] + tail;
      url = url.substring(0, url.length - 1);
    }
    final href = url.toLowerCase().startsWith('www.') ? 'https://$url' : url;
    return '<a href="${_href(href)}">$url</a>$tail';
  }
  if (m.group(2) != null) {
    return '<a href="mailto:${m.group(2)}">${m.group(2)}</a>';
  }
  final tel = m.group(3)!;
  final digits = tel.replaceAll(RegExp(r'[^\d+]'), '').replaceFirst(RegExp(r'^00'), '+');
  return '<a href="tel:$digits">$tel</a>';
});

String linkify(String html) {
  final out = StringBuffer();
  var inside = 0; // dentro <a>, <style>… non si tocca niente
  for (final m in _token.allMatches(html)) {
    final t = m.group(0)!;
    if (t.startsWith('<')) {
      // Un <a> nuovo vuol dire che il precedente non è stato chiuso (capita nelle newsletter):
      // se no da lì in poi niente diventerebbe più cliccabile.
      if (RegExp(r'^<a\b', caseSensitive: false).hasMatch(t)) inside = 0;
      if (_skip.hasMatch(t) && !t.endsWith('/>')) inside++;
      if (_close.hasMatch(t) && inside > 0) inside--;
      out.write(t);
    } else {
      out.write(inside > 0 ? t : _linkText(t));
    }
  }
  return out.toString();
}

/// Un'email di solo testo diventa HTML (con i link cliccabili).
String plainToHtml(String text) => linkify(
  text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\r', '')
      .replaceAll('\n', '<br>'),
);

const _entita = {
  'nbsp': ' ', 'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
  'agrave': 'à', 'egrave': 'è', 'eacute': 'é', 'igrave': 'ì', 'ograve': 'ò', 'ugrave': 'ù',
  'Agrave': 'À', 'Egrave': 'È', 'Eacute': 'É', 'Igrave': 'Ì', 'Ograve': 'Ò', 'Ugrave': 'Ù',
  'euro': '€', 'laquo': '«', 'raquo': '»', 'rsquo': '’', 'lsquo': '‘', 'ldquo': '“',
  'rdquo': '”', 'ndash': '–', 'mdash': '—', 'hellip': '…', 'copy': '©',
};

/// Il testo di un'email solo HTML, per citarla, copiarla o mandarla all'IA: senza stili e script,
/// a capo dove il testo va a capo, e con le lettere vere al posto di `&amp;` ed `&egrave;`.
String testoDaHtml(String html) => html
    .replaceAll(
      RegExp(r'<(style|script|head)\b[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false),
      '',
    )
    .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
    .replaceAll(
      RegExp(r'<(br\s*/?|/p|/div|/li|/tr|/h[1-6])[^>]*>', caseSensitive: false),
      '\n',
    )
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAllMapped(RegExp(r'&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#')) {
        final n = e.startsWith('#x')
            ? int.tryParse(e.substring(2), radix: 16)
            : int.tryParse(e.substring(1));
        return n == null || n > 0x10FFFF ? m[0]! : String.fromCharCode(n);
      }
      return _entita[e] ?? m[0]!;
    })
    .replaceAll(' ', ' ')
    .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
    .replaceAll(RegExp(r' ?\n ?'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();
