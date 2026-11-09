import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai.dart';
import '../db.dart';
import '../linkify.dart';
import '../mail/backend.dart';
import '../mail/imap_backend.dart';
import '../models.dart';
import '../ops.dart';
import '../settings.dart';
import '../theme.dart';
import 'settings_screens.dart';
import 'compose_screen.dart';
import 'email_web.dart';
import 'pickers.dart';
import 'widgets.dart';

/// Lettura di una email. Con l'elenco da cui si è arrivati, le email stanno una
/// accanto all'altra come pagine: scorrendo a sinistra la seguente, a destra la
/// precedente, e la vicina è già pronta mentre la si trascina.
class MessageScreen extends StatefulWidget {
  final Account account;
  final Msg msg;
  final List<Folder> folders;

  /// Le email dell'elenco da cui si è arrivati.
  final List<Msg> siblings;
  const MessageScreen({
    super.key,
    required this.account,
    required this.msg,
    this.folders = const [],
    this.siblings = const [],
  });
  @override
  State<MessageScreen> createState() => _SfogliaState();
}

class _SfogliaState extends State<MessageScreen> {
  /// Le pagine: parte dall'elenco ricevuto e segue la copia locale, così un'email tolta
  /// altrove (dal PC, da una regola) non resta come pagina su cui scorrere.
  late List<Msg> _lista = List.of(widget.siblings);
  late final int _inizio = _lista.indexWhere((x) => x.key == widget.msg.key);
  late final PageController _pc = PageController(
    initialPage: _inizio < 0 ? 0 : _inizio,
  );
  late int _corrente = _inizio;
  final _chiavi = <String, GlobalKey<_LetturaState>>{};
  GlobalKey<_LetturaState> _chiave(Msg m) =>
      _chiavi.putIfAbsent(m.key, () => GlobalKey<_LetturaState>());
  _LetturaState? get _davanti => _corrente < 0 || _corrente >= _lista.length
      ? null
      : _chiavi[_lista[_corrente].key]?.currentState;
  StreamSubscription<void>? _sub;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (_inizio >= 0) {
      _sub = Db.i.changes.listen((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), _allinea);
      });
    }
  }

  /// Toglie dalle pagine le email che non sono più nella copia locale (quella davanti resta,
  /// anche se sparita: la sta leggendo).
  Future<void> _allinea() async {
    if (!mounted || _corrente < 0 || _corrente >= _lista.length) return;
    final davanti = _lista[_corrente];
    final vive = <String>{};
    for (final f in {for (final m in _lista) m.folder}) {
      for (final m in await Db.i.messages(widget.account.id!, f, limit: 5000)) {
        vive.add(m.key);
      }
    }
    if (!mounted) return;
    final nuova = [
      for (final m in _lista)
        if (m.key == davanti.key || vive.contains(m.key)) m,
    ];
    if (nuova.length == _lista.length) return;
    final i = nuova.indexWhere((m) => m.key == davanti.key);
    setState(() {
      _lista = nuova;
      _corrente = i;
    });
    if (_pc.hasClients && _pc.page?.round() != i) _pc.jumpToPage(i);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _pc.dispose();
    super.dispose();
  }

  /// Effetto «profondità»: l'email che si lascia resta ferma, si rimpicciolisce
  /// e sfuma all'indietro, mentre l'altra le scorre sopra con un'ombra.
  Widget _profondita(BuildContext context, int i, Widget child) {
    final page = _pc.hasClients && _pc.position.haveDimensions
        ? _pc.page!
        : _inizio.toDouble();
    final d = i - page;
    if (d <= -1 || d >= 1 || d == 0) return child;
    if (d < 0) {
      final t = -d;
      final w = MediaQuery.sizeOf(context).width;
      return Transform.translate(
        offset: Offset(w * t, 0),
        child: Opacity(
          opacity: 1 - 0.75 * t,
          child: Transform.scale(scale: 1 - 0.22 * t, child: child),
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 24,
            offset: Offset(-8, 0),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_inizio < 0) {
      return _Lettura(
        account: widget.account,
        msg: widget.msg,
        folders: widget.folders,
      );
    }
    final st = _davanti;
    // Al primo giro la pagina non esiste ancora: la barra in alto arriva subito dopo.
    if (st == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return Scaffold(
      appBar: st?._barraAlta() ?? AppBar(flexibleSpace: const BrandBar()),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _pagine()),
            barraAzioni((act) => _davanti?._act(act)),
          ],
        ),
      ),
    );
  }

  Widget _pagine() {
    return PageView.builder(
      controller: _pc,
      // Prepara la seguente e la precedente mentre si legge questa.
      allowImplicitScrolling: true,
      itemCount: _lista.length,
      onPageChanged: (i) => setState(() => _corrente = i),
      // Ogni email ha la sua barra: gli avvisi in basso compaiono in tutte, ma
      // l'animazione la fa solo quella davanti (altrimenti Flutter si ferma).
      itemBuilder: (_, i) => AnimatedBuilder(
        animation: _pc,
        builder: (context, child) => _profondita(context, i, child!),
        // Fondo pieno: l'email che arriva copre quella che va indietro.
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: HeroMode(
            enabled: i == _corrente,
            child: _Lettura(
              key: _chiave(_lista[i]),
              incorporata: true,
              account: widget.account,
              msg: _lista[i],
              folders: widget.folders,
              attiva: i == _corrente,
            ),
          ),
        ),
      ),
    );
  }
}

/// Una email aperta.
class _Lettura extends StatefulWidget {
  final Account account;
  final Msg msg;
  final List<Folder> folders;

  /// Falsa per le vicine preparate in anticipo: non si segnano come lette e,
  /// se sono bozze, non si aprono in Scrivi finché non sono davanti.
  final bool attiva;
  const _Lettura({
    super.key,
    required this.account,
    required this.msg,
    this.folders = const [],
    this.attiva = true,
    this.incorporata = false,
  });

  /// Dentro lo sfoglia: disegna solo il contenuto, le barre restano ferme fuori.
  final bool incorporata;
  @override
  State<_Lettura> createState() => _LetturaState();
}

class _LetturaState extends State<_Lettura> {
  late Msg m;
  bool _loading = true;
  String? _error;
  List<AttachmentInfo> _atts = [];
  String? _summary;
  bool _details = false;
  bool _summarizing = false;
  bool _showImages = false;
  Timer? _readTimer;

  Account get a => widget.account;

  @override
  void initState() {
    super.initState();
    m = widget.msg;
    _open();
  }

  @override
  void didUpdateWidget(covariant _Lettura old) {
    super.didUpdateWidget(old);
    if (widget.attiva == old.attiva || _loading) return;
    if (widget.attiva) {
      _davanti();
    } else {
      _readTimer?.cancel();
      _readTimer = null;
    }
  }

  @override
  void dispose() {
    _readTimer?.cancel();
    super.dispose();
  }

  bool get _isDraft =>
      widget.folders.any((f) => f.path == m.folder && f.role == 'drafts');

  Future<void> _open() async {
    try {
      final b = Backends.of(a);
      m = await b.loadBody(m);
    } catch (e) {
      _error = friendlyError(e);
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (widget.attiva) _davanti();
    // Dopo, non prima: l'elenco allegati aspetta in coda dietro alle sincronizzazioni, e il testo
    // già sul telefono non deve aspettare con lui.
    if (_error == null && !_isDraft) _caricaAllegati();
  }

  /// L'email è davanti agli occhi: si segna come letta, o se è una bozza si
  /// riapre in Scrivi.
  Future<void> _davanti() async {
    // Una bozza non si legge: si riapre in Scrivi per continuare.
    if (_error == null && _isDraft) {
      var files = <String>[];
      if (m.hasAtt) {
        try {
          files = await Ops.forwardFiles(a, m);
        } catch (e) {
          if (mounted) {
            showSnack(
              context,
              'Gli allegati della bozza non si sono scaricati: ${friendlyError(e)}',
            );
          }
        }
      }
      var ccn = <String>[];
      try {
        ccn = await Backends.of(a).draftBcc(m);
      } catch (_) {}
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ComposeScreen(
            init: ComposeInit.fromDraft(a, m, files: files)..bcc = ccn,
          ),
        ),
      );
      return;
    }
    _scheduleRead();
  }

  Future<void> _caricaAllegati() async {
    try {
      final x = await Backends.of(a).attachments(m);
      if (mounted) setState(() => _atts = x);
    } catch (_) {}
  }

  void _scheduleRead() {
    if (m.seen) return;
    switch (Settings.i.markRead) {
      case MarkRead.immediately:
        _markSeen();
        break;
      case MarkRead.after3:
        _readTimer = Timer(const Duration(seconds: 3), _markSeen);
        break;
      case MarkRead.after10:
        _readTimer = Timer(const Duration(seconds: 10), _markSeen);
        break;
      case MarkRead.never:
        break;
    }
  }

  Future<void> _markSeen() async {
    if (m.seen) return;
    m.seen = true;
    // Senza rete il «letto» resta in coda e parte appena torna la connessione.
    await Ops.markSeen(a, m.folder, [m.uid]);
    if (mounted) setState(() {});
  }

  String get _plain => (m.bodyText != null && m.bodyText!.trim().isNotEmpty)
      ? m.bodyText!
      : testoDaHtml(m.bodyHtml ?? '');

  Future<void> _act(Act act) async {
    final nav = Navigator.of(context);
    switch (act) {
      case Act.reply:
      case Act.replyAll:
      case Act.forward:
        var x = act;
        if (act == Act.reply &&
            Settings.i.replyAllDefault &&
            m.toAddrs.contains(','))
          x = Act.replyAll;
        await _compose(x);
        return;
      case Act.unsubscribe:
        await _unsubscribe();
        return;
      case Act.move:
        final f = await pickFolder(context, widget.folders, exclude: m.folder);
        if (f == null) return;
        await _runAndClose(Act.move, nav, target: f.path);
        return;
      case Act.snooze:
        final t = await pickSnooze(context);
        if (t == null) return;
        await _runAndClose(Act.snooze, nav, until: t);
        return;
      case Act.toggleRead:
        final u = await Ops.perform(Act.toggleRead, a, [m]);
        m.seen = !m.seen;
        if (mounted) setState(() {});
        if (u != null && mounted)
          showSnack(
            context,
            m.seen ? 'Segnata come letta' : 'Segnata come non letta',
          );
        return;
      case Act.flag:
        await Ops.perform(Act.flag, a, [m]);
        m.flagged = !m.flagged;
        if (mounted) setState(() {});
        return;
      case Act.block:
        if (m.fromAddr.isEmpty) return;
        if (!await confirm(
          context,
          'Bloccare ${m.fromAddr}?',
          'Le sue prossime email andranno nello spam di ${a.name.isEmpty ? a.address : a.name}. Lo decidi solo tu: nient\'altro viene bloccato.',
          yes: 'Blocca',
        ))
          return;
        await _runAndClose(Act.block, nav);
        return;
      case Act.delete:
      case Act.archive:
      case Act.spam:
        await _runAndClose(act, nav);
        return;
      case Act.none:
        return;
    }
  }

  Future<void> _runAndClose(
    Act act,
    NavigatorState nav, {
    String? target,
    DateTime? until,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final seconds = Settings.i.undoSeconds;
    // L'email sparisce dalla copia locale subito; il server si aspetta in sottofondo.
    // Prima la schermata restava aperta finché il server non rispondeva (circa 2 s,
    // visto sul telefono il 30.10.2026). Ora si chiude subito e l'«Annulla» aspetta
    // l'esito del server solo quando viene premuto.
    final lavoro = Ops.perform(
      act,
      a,
      [m],
      targetPath: target,
      snoozeUntil: until,
    );
    nav.pop();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          act == Act.delete
              ? 'Email eliminata'
              : act == Act.archive
              ? 'Email archiviata'
              : act == Act.spam
              ? 'Segnalata come spam'
              : act == Act.block
              ? 'Mittente bloccato'
              : act == Act.snooze
              ? 'Email rimandata'
              : 'Email spostata',
        ),
        duration: Duration(seconds: seconds),
        // Dal Cestino non si torna indietro: l'email è eliminata per sempre.
        action:
            act == Act.delete && roleOfPath(widget.folders, m.folder) == 'trash'
            ? null
            : SnackBarAction(
                label: 'Annulla',
                onPressed: () async {
                  UndoFn? undo;
                  try {
                    undo = await lavoro;
                  } catch (_) {
                    // Il server ha rifiutato: l'email è già tornata e l'errore lo dice il blocco qui sotto.
                    return;
                  }
                  try {
                    await undo?.call();
                  } catch (e) {
                    messenger.hideCurrentSnackBar();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          'Non sono riuscito ad annullare: ${friendlyError(e)}',
                        ),
                      ),
                    );
                  }
                },
              ),
      ),
    );
    try {
      await lavoro;
    } catch (e) {
      // Il server ha detto di no: la copia locale è già tornata com'era ([Ops._moveOut]).
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _compose(Act act) async {
    var body = _plain;
    final init = ComposeInit.from(a, m, act, body: body);
    if (act == Act.forward && m.hasAtt) {
      try {
        init.files = await Ops.forwardFiles(a, m);
      } catch (e) {
        if (mounted) {
          showSnack(
            context,
            'Gli allegati non si sono scaricati: ${friendlyError(e)}',
          );
        }
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ComposeScreen(init: init)),
    );
  }

  Future<void> _unsubscribe() async {
    if (!Ops.canUnsubscribe(m)) {
      showSnack(context, 'Questa email non ha un modo per disiscriversi.');
      return;
    }
    if (!await confirm(
      context,
      'Disiscriviti da ${m.sender}?',
      'Chiedo al mittente di non scriverti più.',
      yes: 'Disiscriviti',
    ))
      return;
    String? link;
    final r = await Ops.unsubscribe(a, m, (l) => link = l);
    if (!mounted) return;
    switch (r) {
      case UnsubResult.done:
      case UnsubResult.mailSent:
        showSnack(context, 'Disiscrizione inviata a ${m.sender}');
        _askDeleteOld();
        break;
      case UnsubResult.openedLink:
        if (link != null)
          await launchUrl(
            Uri.parse(link!),
            mode: LaunchMode.externalApplication,
          );
        if (mounted)
          showSnack(
            context,
            'Questo mittente chiede di confermare sul suo sito: ho aperto la pagina.',
          );
        break;
      case UnsubResult.notAvailable:
        showSnack(context, 'Questa email non ha un modo per disiscriversi.');
        break;
      case UnsubResult.failed:
        showSnack(
          context,
          'Disiscrizione non riuscita. ${Ops.lastError ?? ''}',
        );
        break;
    }
  }

  Future<void> _askDeleteOld() async {
    final d = await Db.i.db;
    final rows = await d.query(
      'messages',
      where: 'account_id=? AND from_addr=? AND folder=?',
      whereArgs: [a.id, m.fromAddr, m.folder],
    );
    final old = rows.map(Msg.fromRow).toList();
    if (old.length < 2 || !mounted) return;
    final yes = await confirm(
      context,
      'Cancellare le vecchie email?',
      'Ci sono ${old.length} email di ${m.sender} in questa cartella. Le sposto nel cestino?',
      yes: 'Cestina',
    );
    if (!yes || !mounted) return;
    try {
      await Ops.perform(Act.delete, a, old);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _summarize() async {
    if (!await Ai.configured()) {
      if (mounted)
        showSnack(
          context,
          'Inserisci prima account e chiave Cloudflare in Impostazioni > Intelligenza artificiale.',
        );
      return;
    }
    setState(() => _summarizing = true);
    try {
      final s = await Ai.summarize(m, _plain);
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
    if (mounted) setState(() => _summarizing = false);
  }

  Future<void> _aiReply() async {
    if (!await Ai.configured()) {
      if (mounted)
        showSnack(
          context,
          'Inserisci prima account e chiave Cloudflare in Impostazioni > Intelligenza artificiale.',
        );
      return;
    }
    final ctl = TextEditingController();
    if (!mounted) return;
    final instr = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Bozza di risposta con IA'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Cosa vuoi rispondere? (facoltativo)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('Scrivi'),
          ),
        ],
      ),
    );
    if (instr == null || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      // Il tasto Indietro non chiude l'attesa: all'arrivo della risposta si chiuderebbe la schermata.
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    String? draft;
    String? err;
    try {
      draft = await Ai.reply(m, _plain, instr);
    } catch (e) {
      err = friendlyError(e);
    }
    if (!mounted) return;
    Navigator.pop(context);
    if (err != null) {
      showSnack(context, err);
      return;
    }
    var x = Act.reply;
    if (Settings.i.replyAllDefault && m.toAddrs.contains(',')) x = Act.replyAll;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComposeScreen(
          init: ComposeInit.from(a, m, x, body: _plain, draft: draft),
        ),
      ),
    );
  }

  bool _scaricando = false;

  Future<void> _download(AttachmentInfo att) async {
    // Due tocchi non fanno due scaricamenti interi.
    if (_scaricando) return;
    _scaricando = true;
    try {
      showSnack(context, 'Scarico ${att.name}…');
      final data = await Backends.of(a).downloadAttachment(m, att);
      final dir = await getTemporaryDirectory();
      final safe = att.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final f = File('${dir.path}/$safe');
      await f.writeAsBytes(data);
      final r = await OpenFilex.open(f.path);
      if (r.type != ResultType.done && mounted) {
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      _scaricando = false;
    }
  }

  /// «a me» se l'email è per questa casella, altrimenti il primo destinatario.
  String _toLabel() {
    final t = m.toAddrs.trim();
    if (t.isEmpty || t.toLowerCase().contains(a.address.toLowerCase())) {
      return 'me';
    }
    return t;
  }

  /// Il corpo dell'email, nel motore del browser. Anche il solo testo passa da lì, così
  /// zoom e scorrimento sono gli stessi per tutte le email.
  Widget _body() {
    final s = Settings.i;
    final html = m.bodyHtml ?? '';
    if (html.trim().isEmpty) {
      if (_plain.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '(messaggio vuoto)',
            style: TextStyle(fontFamily: 'RobotoLight', fontSize: 17, height: 1.62),
          ),
        );
      }
      return EmailWeb(
        html:
            '<div style="font-family:sans-serif-light,sans-serif;font-size:17px;line-height:1.62;padding:0 16px 24px">${plainToHtml(_plain)}</div>',
        onTapUrl: _openUrl,
        onScorsa: _scorsa,
      );
    }
    final cleaned = Ops.cleanHtml(
      html,
      blockImages: s.blockRemoteImages && !_showImages,
      blockTracking: s.blockTracking,
    );
    _immaginiBloccate = s.blockRemoteImages && !_showImages && cleaned.blocked > 0;
    return EmailWeb(
      html: linkify(cleaned.html),
      onTapUrl: _openUrl,
      onScorsa: _scorsa,
    );
  }

  bool _immaginiBloccate = false;

  /// L'email è scorsa in giù: l'intestazione si stringe a oggetto e mittente, e torna
  /// intera quando si risale in cima.
  bool _compatta = false;
  void _scorsa(bool giu) {
    if (giu != _compatta && mounted) setState(() => _compatta = giu);
  }

  /// Un tocco su un link: un indirizzo email apre Scrivi, un numero la chiamata,
  /// il resto il browser.
  Future<bool> _openUrl(String url) async {
    final t = url.trim();
    if (t.toLowerCase().startsWith('mailto:')) {
      final u = Uri.tryParse(t);
      final q = u?.queryParameters ?? const <String, String>{};
      List<String> lista(String v) => [
        for (final x in v.split(','))
          if (x.trim().isNotEmpty) x.trim(),
      ];
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ComposeScreen(
            init: ComposeInit(
              accountId: a.id!,
              to: lista(Uri.decodeComponent(t.substring(7).split('?').first)),
              cc: lista(q['cc'] ?? ''),
              bcc: lista(q['bcc'] ?? ''),
              subject: q['subject'] ?? '',
              body: q['body'] ?? '',
            ),
          ),
        ),
      );
      return true;
    }
    var u = Uri.tryParse(t);
    if (u != null && !u.hasScheme) u = Uri.tryParse('https://$t');
    if (u == null) {
      if (mounted) showSnack(context, 'Collegamento non valido.');
      return true;
    }
    var ok = false;
    for (final mode in [
      LaunchMode.externalApplication,
      LaunchMode.platformDefault,
      LaunchMode.inAppBrowserView,
    ]) {
      try {
        ok = await launchUrl(u, mode: mode);
      } catch (_) {}
      if (ok) break;
    }
    if (!ok && mounted) {
      await Clipboard.setData(ClipboardData(text: u.toString()));
      showSnack(context, 'Non riesco ad aprirlo: ho copiato il collegamento.');
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.incorporata) return _corpo();
    return Scaffold(
      appBar: _barraAlta(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _corpo()),
            barraAzioni(_act),
          ],
        ),
      ),
    );
  }

  /// Barra in alto: indietro e menu dell'email.
  PreferredSizeWidget _barraAlta() {
    return AppBar(
      flexibleSpace: const BrandBar(),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'flag':
                await _act(Act.flag);
                break;
              case 'read':
                await _act(Act.toggleRead);
                break;
              case 'settings':
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
                break;
              case 'share':
                await SharePlus.instance.share(
                  ShareParams(
                    text: '${m.subject}\n\n$_plain',
                    subject: m.subject,
                  ),
                );
                break;
              case 'copy':
                await Clipboard.setData(ClipboardData(text: _plain));
                if (mounted) showSnack(context, 'Testo copiato');
                break;
              case 'ai':
                await _summarize();
                break;
              case 'aireply':
                await _aiReply();
                break;
              default:
                final act = Act.values.firstWhere((x) => x.name == v);
                await _act(act);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'flag',
              child: Text(m.flagged ? 'Togli la stella' : 'Metti la stella'),
            ),
            PopupMenuItem(
              value: 'read',
              child: Text(m.seen ? 'Segna come non letta' : 'Segna come letta'),
            ),
            const PopupMenuItem(value: 'reply', child: Text('Rispondi')),
            const PopupMenuItem(
              value: 'replyAll',
              child: Text('Rispondi a tutti'),
            ),
            const PopupMenuItem(value: 'forward', child: Text('Inoltra')),
            const PopupMenuItem(value: 'move', child: Text('Sposta in…')),
            const PopupMenuItem(value: 'snooze', child: Text('Rimanda')),
            const PopupMenuItem(
              value: 'spam',
              child: Text('Segnala come spam'),
            ),
            const PopupMenuItem(
              value: 'block',
              child: Text('Blocca il mittente'),
            ),
            if (Ops.canUnsubscribe(m))
              const PopupMenuItem(
                value: 'unsubscribe',
                child: Text('Disiscriviti'),
              ),
            const PopupMenuItem(value: 'ai', child: Text('Riassumi con IA')),
            const PopupMenuItem(
              value: 'aireply',
              child: Text('Rispondi con IA'),
            ),
            const PopupMenuItem(value: 'share', child: Text('Condividi')),
            const PopupMenuItem(value: 'settings', child: Text('Impostazioni')),
            const PopupMenuItem(value: 'copy', child: Text('Copia il testo')),
          ],
        ),
      ],
    );
  }

  /// Il contenuto dell'email: in alto oggetto, mittente, avvisi e allegati (si stringono
  /// quando l'email scorre in giù); sotto, l'email a tutto lo spazio, che scorre e si
  /// ingrandisce da sola come in Gmail e K-9 Mail.
  Widget _corpo() {
    final sus = Ops.suspicion(m);
    final altezzaMax = MediaQuery.sizeOf(context).height * 0.45;
    final corpo = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFB3261E),
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          )
        : _body();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: altezzaMax),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.subject.isEmpty ? '(senza oggetto)' : m.subject,
                    maxLines: _compatta ? 1 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  if (_compatta)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 6),
                      child: Text(
                        '${m.sender}  ${formatDate(m.date)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 8),
                    _intestazione(),
                    if (sus != null) _avvisoSospetto(sus),
                    if (_summarizing)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: LinearProgressIndicator(),
                      ),
                    if (_summary != null)
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kSfondoLeggero,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          _summary!,
                          style: const TextStyle(fontSize: 16, height: 1.35),
                        ),
                      ),
                    if (_atts.isNotEmpty) ...[
                      const Divider(height: 16),
                      for (final att in _atts) _rigaAllegato(att),
                    ],
                    if (_immaginiBloccate)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('Mostra le immagini'),
                          onPressed: () => setState(() => _showImages = true),
                        ),
                      ),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: corpo),
      ],
    );
  }

  Widget _intestazione() => InkWell(
    onTap: () => setState(() => _details = !_details),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SenderAvatar(m.sender, a.color, size: 40, addr: m.fromAddr),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: m.sender,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: '  ${formatDate(m.date)}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      'A: ${_toLabel()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  Icon(
                    _details ? Icons.expand_less : Icons.expand_more,
                    size: 24,
                  ),
                ],
              ),
              if (_details) ...[
                const SizedBox(height: 4),
                Text('Da: ${m.fromAddr}', style: const TextStyle(fontSize: 15)),
                Text(
                  'A: ${m.toAddrs.isEmpty ? a.address : m.toAddrs}',
                  style: const TextStyle(fontSize: 15),
                ),
                if (m.ccAddrs.isNotEmpty)
                  Text('Cc: ${m.ccAddrs}', style: const TextStyle(fontSize: 15)),
                Text(formatFull(m.date), style: const TextStyle(fontSize: 15)),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _avvisoSospetto(String sus) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFDECEA),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFB3261E)),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: Color(0xFFB3261E)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            sus,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );

  Widget _rigaAllegato(AttachmentInfo att) => InkWell(
    onTap: () => _download(att),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  att.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                Text(formatSize(att.size), style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          const Icon(Icons.download, size: 28),
        ],
      ),
    ),
  );
}

/// Barra in basso con le azioni scelte nelle impostazioni.
Widget barraAzioni(void Function(Act) onAct) => Container(
  decoration: BoxDecoration(
    gradient: kBarraGrad,
    border: const Border(top: BorderSide(color: kContorno, width: 3)),
  ),
  child: IconTheme.merge(
    data: const IconThemeData(color: Colors.white),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final act in Settings.i.toolbar)
          IconButton(
            iconSize: 26,
            tooltip: actLabel[act],
            icon: Icon(actIcon(act)),
            onPressed: () => onAct(act),
          ),
      ],
    ),
  ),
);
