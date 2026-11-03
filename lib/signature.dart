import 'dart:convert';
import 'dart:typed_data';

import 'package:html_unescape/html_unescape_small.dart';
import 'package:http/http.dart' as http;

/// Estrae la firma da un'email già inviata.
class SignatureTools {
  SignatureTools._();

  static final _esc = HtmlUnescape();

  static String escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\n', '<br>');

  static const _markers = [
    'gmail_signature',
    'moz-signature',
    'id="Signature"',
    'id="x_Signature"',
    'id="ms-outlook-mobile-signature"',
    'data-smartmail="gmail_signature"',
    'class="signature"',
    'class="Signature"',
    'name="Signature"',
  ];

  /// Cerca la firma nell'HTML (Gmail, Outlook, Thunderbird, app mobili).
  static String? fromHtml(String html) {
    for (final mk in _markers) {
      final i = html.indexOf(mk);
      if (i < 0) continue;
      final start = html.lastIndexOf('<', i);
      if (start < 0) continue;
      final tagEnd = RegExp(
        r'<\s*([a-zA-Z0-9]+)',
      ).firstMatch(html.substring(start));
      if (tagEnd == null) continue;
      final tag = tagEnd.group(1)!.toLowerCase();
      var depth = 0;
      final re = RegExp('<(/?)$tag\\b[^>]*>', caseSensitive: false);
      for (final m in re.allMatches(html, start)) {
        if (m.group(1)!.isEmpty) {
          depth++;
        } else {
          depth--;
          if (depth == 0) {
            final block = html.substring(start, m.end);
            return _cleanBlock(block);
          }
        }
      }
      return _cleanBlock(html.substring(start));
    }
    return null;
  }

  static String _cleanBlock(String b) => b
      .replaceAll(
        RegExp(
          r'<script[^>]*>.*?</script>',
          dotAll: true,
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static final _quoteStart = RegExp(
    r'^(>|Il .{5,80} ha scritto:|On .{5,80} wrote:|Da:|From:|-----Original|-----Messaggio originale)',
    caseSensitive: false,
  );
  static final _closers = RegExp(
    r'^(cordiali saluti|distinti saluti|saluti|un saluto|cordialmente|grazie|a presto|best regards|kind regards|regards|sincerely|cheers|ciao)\b',
    caseSensitive: false,
  );

  /// Cerca la firma nel testo semplice: dopo «-- » oppure dopo la formula di chiusura.
  static String? fromText(String text) {
    final lines = text.replaceAll('\r', '').split('\n');
    var cut = lines.length;
    for (var i = 0; i < lines.length; i++) {
      if (_quoteStart.hasMatch(lines[i].trim()) && i > 2) {
        cut = i;
        break;
      }
    }
    final body = lines.sublist(0, cut);
    var start = -1;
    for (var i = body.length - 1; i >= 0; i--) {
      if (body[i].trimRight() == '--' || body[i] == '-- ') {
        start = i + 1;
        break;
      }
    }
    if (start < 0) {
      for (var i = 0; i < body.length; i++) {
        if (_closers.hasMatch(body[i].trim()))
          start = i; // l'ultima formula di chiusura
      }
    }
    if (start < 0 || start >= body.length) return null;
    final sig = body.sublist(start).join('\n').trim();
    if (sig.length < 3 || sig.length > 1500) return null;
    return escapeHtml(sig);
  }

  static final _htmlQuote = RegExp(
    r'<blockquote|class="gmail_quote|id="divRplyFwdMsg|id="x_divRplyFwdMsg|class="moz-cite-prefix|<hr\b|-----Original|-----Messaggio originale|>\s*(Il|On) [^<]{5,120}(ha scritto|wrote):',
    caseSensitive: false,
  );
  static final _htmlCloser = RegExp(
    r'>\s*(cordiali saluti|distinti saluti|saluti|un saluto|cordialmente|grazie|a presto|best regards|kind regards|regards|sincerely|cheers|ciao)\b[^<]*<',
    caseSensitive: false,
  );

  /// Firma senza segno di inizio: tutto l'HTML dopo l'ultima formula di chiusura
  /// (o dopo «-- »), fino alla citazione. Tiene logo, righe e grassetti.
  static String? fromHtmlAfterCloser(String html) {
    final q = _htmlQuote.firstMatch(html);
    final own = q == null ? html : html.substring(0, q.start);
    var start = -1;
    final dash = RegExp(r'>\s*--\s*(<br\s*/?>|<)', caseSensitive: false);
    for (final m in dash.allMatches(own)) start = m.end - 1;
    if (start < 0) {
      for (final m in _htmlCloser.allMatches(own)) start = m.end - 1;
    }
    if (start < 0) return null;
    var sig = own
        .substring(start)
        .replaceFirst(RegExp(r'^(\s*(</[^>]+>|<br\s*/?>))+', caseSensitive: false), '')
        .replaceFirst(RegExp(r'(</body>|</html>)[\s\S]*$', caseSensitive: false), '');
    sig = _cleanBlock(sig);
    final hasText = sig.replaceAll(RegExp(r'<[^>]+>'), '').trim().isNotEmpty;
    if (!hasText && !sig.toLowerCase().contains('<img')) return null;
    if (sig.replaceAll(RegExp(r'<[^>]+>'), '').trim().length > 1500) return null;
    return sig;
  }

  /// Prova prima l'HTML, poi il testo.
  static String? extract({String? html, String? text}) {
    if (html != null && html.isNotEmpty) {
      final h = fromHtml(html);
      if (h != null && h.replaceAll(RegExp(r'<[^>]+>'), '').trim().isNotEmpty)
        return h;
      final c = fromHtmlAfterCloser(html);
      if (c != null) return c;
    }
    if (text != null && text.isNotEmpty) return fromText(text);
    if (html != null && html.isNotEmpty) {
      return fromText(
        _esc.convert(
          html
              .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
              .replaceAll(RegExp(r'<[^>]+>'), ' '),
        ),
      );
    }
    return null;
  }

  // ---------- immagini della firma ----------

  static final _imgSrc = RegExp(
    r'''(<img\b[^>]*?\bsrc\s*=\s*)(["'])(.*?)\2''',
    caseSensitive: false,
    dotAll: true,
  );

  /// Immagine più grande di così: resta com'è (un logo di firma pesa poco).
  static const maxImageBytes = 400 * 1024;

  static String _mimeOf(Uint8List b, [String? declared]) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
    if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49) return 'image/gif';
    return declared != null && declared.startsWith('image/')
        ? declared.split(';').first
        : 'image/png';
  }

  /// Trasforma le immagini della firma (cid: di un'email ricevuta, oppure link web)
  /// in immagini incorporate nel testo, così la firma si salva intera e si vede ovunque.
  /// [cidLookup] restituisce i byte della parte con quel Content-ID.
  static Future<String> embedImages(
    String html, {
    required Future<Uint8List?> Function(String cid) cidLookup,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    final out = StringBuffer();
    var last = 0;
    for (final m in _imgSrc.allMatches(html)) {
      final src = m.group(3)!.trim();
      Uint8List? data;
      String? declared;
      try {
        if (src.toLowerCase().startsWith('cid:')) {
          data = await cidLookup(
            src.substring(4).replaceAll(RegExp(r'^<|>$'), ''),
          );
        } else if (RegExp(r'^https?://', caseSensitive: false).hasMatch(src)) {
          final r = await c
              .get(Uri.parse(src))
              .timeout(const Duration(seconds: 8));
          if (r.statusCode == 200) {
            data = r.bodyBytes;
            declared = r.headers['content-type'];
          }
        }
      } catch (_) {}
      out.write(html.substring(last, m.start));
      if (data != null && data.isNotEmpty && data.length <= maxImageBytes) {
        out.write(
          '${m.group(1)}"data:${_mimeOf(data, declared)};base64,${base64.encode(data)}"',
        );
      } else {
        out.write(m.group(0));
      }
      last = m.end;
    }
    out.write(html.substring(last));
    return out.toString();
  }

  /// Un'immagine scelta dal telefono, pronta da mettere nella firma.
  static String imgTag(Uint8List data, {int? width}) =>
      '<img${width == null ? '' : ' width="$width"'} src="data:${_mimeOf(data)};base64,${base64.encode(data)}">';

  static final _imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);

  /// La firma come testo da correggere a mano: ogni immagine diventa una riga
  /// «[immagine N]», così si vede dov'è e si può spostare.
  static ({String text, List<String> images}) toEditable(String html) {
    final images = <String>[];
    final withMarks = html.replaceAllMapped(_imgTag, (m) {
      images.add(m.group(0)!);
      return '\n[immagine ${images.length}]\n';
    });
    final text = _esc
        .convert(
          withMarks
              .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
              .replaceAll(
                RegExp(r'</(p|div|tr|li|h[1-6]|table)>', caseSensitive: false),
                '\n',
              )
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll('\r', ''),
        )
        .replaceAll(' ', ' ')
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return (text: text, images: images);
  }

  /// Dal testo corretto a mano torna alla firma, rimettendo le immagini al loro posto.
  static String fromEditable(String text, List<String> images) {
    var html = escapeHtml(text.trim());
    for (var i = 0; i < images.length; i++) {
      html = html.replaceAll('[immagine ${i + 1}]', images[i]);
    }
    return html;
  }

  /// La firma come va spedita: una riga per riga, senza i margini dei paragrafi
  /// di Outlook (che le distanziano) e senza «</p>» scritti come testo.
  /// Una riga vuota nella firma resta una riga vuota.
  static String forSend(String html) {
    var s = html
        .replaceAll(RegExp(r'<o:p>\s*(&nbsp;)?\s*</o:p>', caseSensitive: false), '')
        .replaceAll(RegExp(r'&lt;\s*/?\s*p\s*&gt;', caseSensitive: false), '')
        .replaceAll(RegExp(r'<p\b[^>]*>\s*(&nbsp;|\s)*\s*</p>', caseSensitive: false), '<br>')
        .replaceAll(RegExp(r'<p\b[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '<br>');
    s = s.replaceAll(RegExp(r'(<br\s*/?>\s*){3,}', caseSensitive: false), '<br><br>');
    return s.replaceFirst(RegExp(r'(<br\s*/?>\s*)+$', caseSensitive: false), '');
  }

  /// La firma pronta per l'editor: ogni riga un blocco (le righe vuote restano).
  static String asBlocks(String html) => '<div>$html</div>';

  /// Per la lettura: le immagini «cid:» (loghi delle firme, immagini nel testo)
  /// diventano immagini incorporate, così si vedono nel testo come le emoticon.
  static Future<String> inlineCid(
    String html,
    Future<Uint8List?> Function(String cid) lookup,
  ) async {
    if (!html.toLowerCase().contains('cid:')) return html;
    final out = StringBuffer();
    var last = 0;
    for (final m in _imgSrc.allMatches(html)) {
      final src = m.group(3)!.trim();
      if (!src.toLowerCase().startsWith('cid:')) continue;
      Uint8List? data;
      try {
        data = await lookup(src.substring(4).replaceAll(RegExp(r'^<|>$'), ''));
      } catch (_) {}
      if (data == null || data.isEmpty) continue;
      out.write(html.substring(last, m.start));
      out.write(
        '${m.group(1)}"data:${_mimeOf(data, null)};base64,${base64.encode(data)}"',
      );
      last = m.end;
    }
    out.write(html.substring(last));
    return out.toString();
  }

  /// Per l'invio: le immagini incorporate diventano parti «cid:» da allegare in linea.
  static ({String html, List<InlineImage> images}) toCid(String html) {
    final images = <InlineImage>[];
    final out = StringBuffer();
    var last = 0;
    final re = RegExp(
      r'''(<img\b[^>]*?\bsrc\s*=\s*)(["'])data:(image/[a-z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)\2''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final m in re.allMatches(html)) {
      final bytes = base64.decode(m.group(4)!.replaceAll(RegExp(r'\s'), ''));
      final cid = 'img${images.length + 1}-${bytes.length}@digimail';
      images.add(
        InlineImage(cid, m.group(3)!.toLowerCase(), Uint8List.fromList(bytes)),
      );
      out.write(html.substring(last, m.start));
      out.write('${m.group(1)}"cid:$cid"');
      last = m.end;
    }
    out.write(html.substring(last));
    return (html: out.toString(), images: images);
  }
}

class InlineImage {
  final String cid;
  final String mediaType;
  final Uint8List data;
  const InlineImage(this.cid, this.mediaType, this.data);
}
