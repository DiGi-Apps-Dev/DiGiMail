import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:vsc_quill_delta_to_html/vsc_quill_delta_to_html.dart';

/// Testo con grassetto, corsivo, sottolineato, evidenziato, colori, elenchi e link:
/// lo usano Scrivi e la Firma.
class RichDoc {
  RichDoc._();

  /// Dall'HTML (una firma presa da un'email) all'editor. La larghezza scritta come
  /// attributo (`width=230`, tipico di Outlook) diventa stile, se no si perde.
  static Document fromHtml(String html) {
    if (html.trim().isEmpty) return Document();
    final fixed = html.replaceAllMapped(
      RegExp(r'<img\b[^>]*>', caseSensitive: false),
      (m) {
        final tag = m.group(0)!;
        final px = _imgWidthPx(tag);
        if (px == null) return tag;
        // Via larghezza, altezza e stile di Outlook (virgolette singole o doppie):
        // resta una sola larghezza in pixel.
        final clean = tag
            .replaceAll(
              RegExp(r'''\s(width|height|style)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
                  caseSensitive: false),
              '',
            )
            .replaceFirst(RegExp(r'^<img', caseSensitive: false), '');
        return '<img style="width:${px}px"$clean';
      },
    );
    // Il convertitore unisce i <p> consecutivi in una riga sola: diventano <div>.
    final blocks = fixed
        .replaceAll(RegExp(r'<p\b', caseSensitive: false), '<div')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '</div>');
    try {
      final ops = HtmlToDelta().convert(blocks).toJson();
      for (final op in ops) {
        // La larghezza delle immagini arriva come «style»: l'editor la vuole come «width».
        final at = op['attributes'];
        if (op['insert'] is! Map || at is! Map) continue;
        final attrs = Map<String, dynamic>.from(at);
        final w = RegExp(
          r'width\s*:\s*(\d+)',
        ).firstMatch('${attrs.remove('style') ?? ''}');
        if (w != null) attrs['width'] = w.group(1);
        if (attrs.isEmpty) {
          op.remove('attributes');
        } else {
          op['attributes'] = attrs;
        }
      }
      return Document.fromJson(ops.cast<Map<String, dynamic>>());
    } catch (_) {
      return Document()..insert(0, html.replaceAll(RegExp(r'<[^>]+>'), ' '));
    }
  }

  /// Larghezza di un'immagine in pixel: dall'attributo `width=193` (Outlook) oppure
  /// dallo stile (`width:2.0069in`, pt, cm, px).
  static int? _imgWidthPx(String tag) {
    final a = RegExp(r'''\swidth\s*=\s*["']?(\d+(?:\.\d+)?)["']?''',
            caseSensitive: false)
        .firstMatch(tag);
    if (a != null) return double.parse(a.group(1)!).round();
    final s = RegExp(r'width\s*:\s*(\d+(?:\.\d+)?)\s*(px|in|pt|cm)?',
            caseSensitive: false)
        .firstMatch(tag);
    if (s == null) return null;
    final v = double.parse(s.group(1)!);
    switch ((s.group(2) ?? 'px').toLowerCase()) {
      case 'in':
        return (v * 96).round();
      case 'pt':
        return (v * 96 / 72).round();
      case 'cm':
        return (v * 96 / 2.54).round();
      default:
        return v.round();
    }
  }

  /// Il testo con la firma dopo due righe vuote, tutto un unico documento.
  static Document withSignature(Document body, Document sig) {
    // Il testo della firma è a 11 pt, quello del messaggio a 12 pt.
    final sigOps = sig.toDelta().toJson().cast<Map<String, dynamic>>().map((op) {
      if (op['insert'] is! String || (op['insert'] as String) == '\n') return op;
      final at = <String, dynamic>{
        'size': sigSize,
        ...((op['attributes'] as Map?)?.cast<String, dynamic>() ?? {}),
      };
      return <String, dynamic>{...op, 'attributes': at};
    });
    final ops = <Map<String, dynamic>>[
      ...body.toDelta().toJson().cast<Map<String, dynamic>>(),
      {'insert': '\n\n'},
      ...sigOps,
    ];
    return Document.fromJson(ops);
  }

  /// Dimensione della firma, 11 pt in pixel (11 × 4/3), come testo di tutta l'email.
  static const String sigSize = '14.67';

  static Document fromText(String text) {
    final d = Document();
    if (text.isNotEmpty) d.insert(0, text);
    return d;
  }

  /// L'editor in HTML da spedire: righe in <div>, stili scritti dentro i tag
  /// (i programmi di posta ignorano i fogli di stile).
  static String toHtml(Document d) {
    if (d.toPlainText().trim().isEmpty && !_hasEmbed(d)) return '';
    final ops = d.toDelta().toJson().cast<Map<String, dynamic>>().map((op) {
      // Link scritti senza https:// (o email, numeri): completi, se no il
      // convertitore li scarta come «unsafe:».
      final at = op['attributes'];
      if (at is Map && at['link'] is String) {
        return <String, dynamic>{
          ...op,
          'attributes': <String, dynamic>{
            ...at.cast<String, dynamic>(),
            'link': fullLink(at['link'] as String),
          },
        };
      }
      return op;
    }).toList();
    final opts = ConverterOptions.forEmail();
    opts.converterOptions.paragraphTag = 'div';
    // La dimensione scritta dall'app (pixel) esce in punti, come in Outlook.
    opts.converterOptions.inlineStyles = InlineStyles({
      'size': InlineStyleType(
        fn: (v, _) {
          final px = double.tryParse(v);
          if (px == null) return null;
          return 'font-size:${(px * 0.75).round()}pt';
        },
      ),
    });
    final html = QuillDeltaToHtmlConverter(ops, opts).convert();
    return html
        .replaceAllMapped(
          RegExp(r'width="(\d+)px"'),
          (m) => 'width="${m.group(1)}"',
        )
        .replaceAll(' target="_blank"', '');
  }

  /// Corpo e firma senza righe vuote d'avanzo ai bordi: fra l'ultima parola e la firma
  /// restano esattamente le due righe vuote volute dall'utente, non quelle in più dell'editor
  /// o della firma importata.
  static String trimBreaks(String html) {
    const vuoto =
        r'(?:<br\s*/?>|&nbsp;|\s|<(?:div|p)[^>]*>(?:<br\s*/?>|&nbsp;|\s)*</(?:div|p)>)+';
    return html
        .replaceFirst(RegExp('^$vuoto', caseSensitive: false), '')
        .replaceFirst(
          RegExp(
            r'(?:<br\s*/?>|&nbsp;|\s)+(?=</div>\s*$)',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp('$vuoto\$', caseSensitive: false), '');
  }

  /// Il link scritto a mano va bene se è un sito (anche senza https://), un'email o un numero.
  static bool linkOk(String link) {
    final l = link.trim();
    if (l.isEmpty) return false;
    if (RegExp(r'^\+?[\d .-]{6,}$').hasMatch(l)) return true;
    if (l.contains(' ')) return false;
    return l.contains('.') || l.contains('@');
  }

  /// www.sito.ch → https://www.sito.ch, un'email → mailto:, un numero → tel:.
  static String fullLink(String l) {
    final t = l.trim();
    if (RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(t))
      return t;
    if (RegExp(
      r'^[^@\s/]+@[^@\s/]+\.[a-z]{2,}$',
      caseSensitive: false,
    ).hasMatch(t)) {
      return 'mailto:$t';
    }
    if (RegExp(r'^\+?[\d .-]{6,}$').hasMatch(t)) {
      return 'tel:${t.replaceAll(RegExp(r'[^\d+]'), '')}';
    }
    return 'https://$t';
  }

  static bool _hasEmbed(Document d) =>
      d.toDelta().toList().any((op) => op.data is Map);

  static String deltaJson(Document d) => jsonEncode(d.toDelta().toJson());

  static Document fromDeltaJson(String json) => Document.fromJson(
    (jsonDecode(json) as List).cast<Map<String, dynamic>>(),
  );
}

/// Barra dei formati, sopra il testo.
class RichToolbar extends StatelessWidget {
  final QuillController controller;
  const RichToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return Theme(
      data: Theme.of(context).copyWith(
        iconTheme: IconThemeData(color: fg),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: fg),
        ),
      ),
      child: QuillSimpleToolbar(
        controller: controller,
        config: const QuillSimpleToolbarConfig(
          multiRowsDisplay: false,
          showDividers: false,
          showFontFamily: false,
          showFontSize: false,
          showSmallButton: false,
          showInlineCode: false,
          showSubscript: false,
          showSuperscript: false,
          showHeaderStyle: false,
          showListCheck: false,
          showCodeBlock: false,
          showQuote: false,
          showIndent: false,
          showSearchButton: false,
          showUndo: false,
          showRedo: false,
          showStrikeThrough: true,
          showBoldButton: true,
          showItalicButton: true,
          showUnderLineButton: true,
          showColorButton: true,
          showBackgroundColorButton: true,
          showListNumbers: true,
          showListBullets: true,
          showLink: true,
          showClearFormat: true,
          // Il link si accetta anche senza «https://» (www.sito.ch), un'email o un numero.
          buttonOptions: QuillSimpleToolbarButtonOptions(
            linkStyle: QuillToolbarLinkStyleButtonOptions(
              validateLink: RichDoc.linkOk,
            ),
          ),
        ),
      ),
    );
  }
}

/// Il riquadro del testo.
class RichEditor extends StatelessWidget {
  final QuillController controller;
  final String placeholder;
  final double fontSize;
  final bool scrollable;
  const RichEditor({
    super.key,
    required this.controller,
    this.placeholder = '',
    this.fontSize = 16,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return DefaultTextStyle.merge(
      style: TextStyle(
                fontFamily: 'RobotoLight',
                color: fg,
                fontSize: fontSize,
                height: 1.35,
              ),
      child: QuillEditor.basic(
        controller: controller,
        config: QuillEditorConfig(
          placeholder: placeholder,
          scrollable: scrollable,
          expands: false,
          padding: const EdgeInsets.symmetric(vertical: 8),
          embedBuilders: const [ImageEmbed()],
          customStyles: DefaultStyles(
            paragraph: DefaultTextBlockStyle(
              TextStyle(
                fontFamily: 'RobotoLight',
                color: fg,
                fontSize: fontSize,
                height: 1.35,
              ),
              HorizontalSpacing.zero,
              VerticalSpacing.zero,
              VerticalSpacing.zero,
              null,
            ),
            placeHolder: DefaultTextBlockStyle(
              TextStyle(
                fontFamily: 'RobotoLight',
                color: fg,
                fontSize: fontSize,
                height: 1.35,
              ),
              HorizontalSpacing.zero,
              VerticalSpacing.zero,
              VerticalSpacing.zero,
              null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Le immagini nel testo (il logo della firma): incorporate o dal web.
class ImageEmbed extends EmbedBuilder {
  const ImageEmbed();

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final src = '${embedContext.node.value.data}';
    final w = double.tryParse(
      '${embedContext.node.style.attributes['width']?.value ?? ''}'.replaceAll(
        'px',
        '',
      ),
    );
    Widget img;
    try {
      if (src.startsWith('data:')) {
        img = Image.memory(UriData.parse(src).contentAsBytes(), width: w);
      } else if (src.startsWith('http')) {
        img = Image.network(src, width: w);
      } else {
        img = const Icon(Icons.broken_image_outlined);
      }
    } catch (_) {
      img = const Icon(Icons.broken_image_outlined);
    }
    return Align(alignment: Alignment.centerLeft, child: img);
  }
}
