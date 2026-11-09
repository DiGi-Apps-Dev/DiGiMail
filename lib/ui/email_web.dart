import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart'
    show HtmlWidget;

/// Il corpo di un'email mostrato dal motore del browser di Android, come fanno
/// K-9 Mail / Thunderbird e Gmail: l'email ha tutto lo spazio sotto l'intestazione,
/// scorre e si ingrandisce da sola (browser), senza misure fatte a mano.
///
/// Impostazioni prese da K-9 Mail (`MessageWebView.kt`): pagina larga e «adatta
/// alla larghezza» (una newsletter da 600 px si vede intera, rimpicciolita), zoom con
/// due dita del browser, niente JavaScript delle email, testo che va a capo.
class EmailWeb extends StatefulWidget {
  final String html;
  final Future<bool> Function(String url) onTapUrl;

  /// Chiamato quando l'email scorre: `true` se non è più in cima (l'intestazione si stringe).
  final void Function(bool scorsa)? onScorsa;
  const EmailWeb({
    super.key,
    required this.html,
    required this.onTapUrl,
    this.onScorsa,
  });

  /// La pagina che si carica: l'email com'è, con in testa la riga che dice al browser di
  /// usare la larghezza del telefono (senza, userebbe 980 px e il testo verrebbe minuscolo,
  /// come spiega K-9 Mail) e due regole che non cambiano l'aspetto: il testo lungo va a capo
  /// e le immagini non sforano.
  static String pagina(String html) {
    final h = html
        .replaceAll(
          RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false),
          '',
        )
        // Come K-9 Mail: niente «meta refresh», che aprirebbe da solo un sito.
        .replaceAll(
          RegExp(
            r'''<meta\b[^>]*http-equiv\s*=\s*["']?refresh[^>]*>''',
            caseSensitive: false,
          ),
          '',
        );
    const testa = '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width">'
        '<style>body{word-wrap:break-word;overflow-wrap:break-word}'
        'img{max-width:100%;height:auto}</style>';
    // In fondo alla testa, come K-9 Mail: fra due righe uguali vince l'ultima, così
    // un'email che vieta lo zoom («user-scalable=no») non lo blocca.
    if (RegExp(r'</head\s*>', caseSensitive: false).hasMatch(h)) {
      return h.replaceFirstMapped(
        RegExp(r'</head\s*>', caseSensitive: false),
        (m) => '$testa${m.group(0)}',
      );
    }
    if (RegExp(r'<head\b[^>]*>', caseSensitive: false).hasMatch(h)) {
      return h.replaceFirstMapped(
        RegExp(r'<head\b[^>]*>', caseSensitive: false),
        (m) => '${m.group(0)}$testa',
      );
    }
    if (RegExp(r'<html\b[^>]*>', caseSensitive: false).hasMatch(h)) {
      return h.replaceFirstMapped(
        RegExp(r'<html\b[^>]*>', caseSensitive: false),
        (m) => '${m.group(0)}<head>$testa</head>',
      );
    }
    return '<!doctype html><html><head>$testa</head><body>$h</body></html>';
  }

  @override
  State<EmailWeb> createState() => _EmailWebState();
}

class _EmailWebState extends State<EmailWeb> {
  InAppWebViewController? _c;

  /// Ingrandimento con cui l'email entra tutta nello schermo; sopra, è stata zoomata.
  double? _scalaBase;
  bool _zoomata = false;
  bool _scorsa = false;

  /// Dopo che l'intestazione cambia, lo spazio dell'email cambia e il browser sposta da
  /// sé la pagina: quello scatto non è dell'utente e si ignora per un attimo.
  DateTime _fermoFino = DateTime(0);
  bool _decidendo = false;

  /// L'intestazione si stringe (oltre 120 punti di scorrimento) solo se l'email è lunga
  /// abbastanza da restare scorsa anche con lo spazio in più; torna grande solo in cima.
  /// Senza queste regole un'email corta faceva stringere e allargare l'intestazione di
  /// continuo (lampeggio, 1.0.74).
  Future<void> _scrolla(InAppWebViewController c, int y) async {
    if (widget.onScorsa == null || _decidendo) return;
    if (DateTime.now().isBefore(_fermoFino)) return;
    if (!_scorsa && y > 120) {
      _decidendo = true;
      try {
        final altezza = (await c.getContentHeight()) ?? 0;
        final scala = (await c.getZoomScale()) ?? 1;
        if (!mounted) return;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final vista = (context.size?.height ?? 0) * dpr;
        final schermo = MediaQuery.sizeOf(context).height * dpr;
        // Quanto si può scorrere, in pixel del telefono, deve superare lo spazio che
        // l'intestazione libera (al massimo metà schermo) più un margine.
        if (altezza * scala - vista > schermo * 0.5 + 120) _cambia(true);
      } catch (_) {
      } finally {
        _decidendo = false;
      }
    } else if (_scorsa && y <= 8) {
      _cambia(false);
    }
  }

  void _cambia(bool scorsa) {
    _scorsa = scorsa;
    _fermoFino = DateTime.now().add(const Duration(milliseconds: 500));
    widget.onScorsa?.call(scorsa);
  }

  /// Nelle prove automatiche (su PC) il motore del browser non c'è.
  bool get _disponibile => !kIsWeb && Platform.isAndroid;

  @override
  void didUpdateWidget(covariant EmailWeb old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _scalaBase = null;
      _c?.loadData(data: EmailWeb.pagina(widget.html));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_disponibile) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: HtmlWidget(widget.html, onTapUrl: widget.onTapUrl),
      );
    }
    return InAppWebView(
      initialData: InAppWebViewInitialData(data: EmailWeb.pagina(widget.html)),
      initialSettings: InAppWebViewSettings(
        // Come K-9 Mail: pagina larga adattata allo schermo, zoom del browser, niente JavaScript.
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        javaScriptEnabled: false,
        useShouldOverrideUrlLoading: true,
        overScrollMode: OverScrollMode.NEVER,
        // Il browser si disegna dentro la pagina dell'app (texture), non sopra: si muove
        // con lei quando si esce dall'email e quando si sfoglia, senza restare indietro.
        // Sicuro perché la vista è alta quanto lo schermo, non quanto l'email.
        useHybridComposition: false,
        verticalScrollBarEnabled: true,
        horizontalScrollBarEnabled: false,
        // Il contenuto disegnato si legge dal PC (chrome://inspect) solo nella versione di prova.
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (c) => _c = c,
      onLoadStop: (c, _) async {
        try {
          _scalaBase ??= await c.getZoomScale();
        } catch (_) {}
      },
      onZoomScaleChanged: (c, vecchia, nuova) {
        final base = _scalaBase ?? vecchia;
        _scalaBase ??= vecchia;
        final z = nuova > base * 1.05;
        if (z != _zoomata && mounted) setState(() => _zoomata = z);
      },
      onScrollChanged: (c, x, y) => _scrolla(c, y),
      shouldOverrideUrlLoading: (c, azione) async {
        final u = azione.request.url?.toString() ?? '';
        if (u.isEmpty || u.startsWith('about:') || u.startsWith('data:')) {
          return NavigationActionPolicy.ALLOW;
        }
        widget.onTapUrl(u);
        return NavigationActionPolicy.CANCEL;
      },
      // L'email scorre da sé (su e giù) e si seleziona con la pressione lunga. Il
      // trascinamento orizzontale va all'email solo quando è ingrandita: altrimenti
      // passa allo sfoglia, che porta all'email seguente.
      gestureRecognizers: {
        // Due dita sull'email: il gesto è dell'email (zoom del browser), subito, prima
        // che lo sfoglia lo prenda per un trascinamento di lato.
        Factory<_DueDita>(_DueDita.new),
        // Un dito che non va chiaramente di lato fa scorrere l'email: lo sfoglia parte
        // solo se il movimento è almeno il doppio di lato che in su o giù (come Gmail).
        Factory<_NonDiLato>(_NonDiLato.new),
        Factory<LongPressGestureRecognizer>(LongPressGestureRecognizer.new),
        Factory<ScaleGestureRecognizer>(ScaleGestureRecognizer.new),
        if (_zoomata)
          Factory<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
          ),
      },
    );
  }
}

/// Vince il gesto appena sull'email ci sono due dita: così il pizzico arriva al
/// browser (che ingrandisce dove sono le dita) e non allo sfoglia fra le email.
class _DueDita extends OneSequenceGestureRecognizer {
  final _dita = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _dita.add(event.pointer);
    if (_dita.length >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      _dita.remove(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    _dita.remove(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _dita.clear();

  @override
  String get debugDescription => 'due dita';
}

/// Decide presto (dopo 8 punti di movimento) a chi va un dito sull'email: se non va
/// chiaramente di lato (di lato meno del doppio che in su o giù) il gesto è dell'email,
/// che scorre; altrimenti lo lascia allo sfoglia fra le email, che parte dopo 18 punti.
class _NonDiLato extends OneSequenceGestureRecognizer {
  static const _decidi = 8.0;
  final _inizio = <int, Offset>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _inizio[event.pointer] = event.position;
  }

  @override
  void handleEvent(PointerEvent event) {
    final da = _inizio[event.pointer];
    if (event is PointerMoveEvent && da != null) {
      final d = event.position - da;
      if (d.distance >= _decidi) {
        _inizio.remove(event.pointer);
        if (d.dx.abs() < 2 * d.dy.abs()) {
          resolve(GestureDisposition.accepted);
        } else {
          stopTrackingPointer(event.pointer);
          resolvePointer(event.pointer, GestureDisposition.rejected);
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _inizio.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _inizio.clear();

  @override
  String get debugDescription => 'non di lato';
}
