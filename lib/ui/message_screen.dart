import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart'
    show HtmlWidget;
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
import 'pickers.dart';
import 'widgets.dart';

/// Lettura di una email.
class MessageScreen extends StatefulWidget {
  final Account account;
  final Msg msg;
  final List<Folder> folders;

  /// Le email dell'elenco da cui si è arrivati: scorrendo a destra o a sinistra
  /// si passa alla precedente o alla seguente.
  final List<Msg> siblings;
  const MessageScreen({
    super.key,
    required this.account,
    required this.msg,
    this.folders = const [],
    this.siblings = const [],
  });
  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen> {
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
  void dispose() {
    _readTimer?.cancel();
    super.dispose();
  }

  /// Scorrimento orizzontale: a sinistra l'email seguente (sotto nell'elenco), a destra la precedente.
  void _swipeNav(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() < 500 || widget.siblings.isEmpty) return;
    final i = widget.siblings.indexWhere((x) => x.key == m.key);
    if (i < 0) return;
    final j = v < 0 ? i + 1 : i - 1;
    if (j < 0 || j >= widget.siblings.length) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MessageScreen(
          account: a,
          msg: widget.siblings[j],
          folders: widget.folders,
          siblings: widget.siblings,
        ),
      ),
    );
  }

  bool get _isDraft => widget.folders.any(
    (f) => f.path == m.folder && f.role == 'drafts',
  );

  Future<void> _open() async {
    try {
      final b = Backends.of(a);
      m = await b.loadBody(m);
    } catch (e) {
      _error = friendlyError(e);
    }
    if (!mounted) return;
    // Una bozza non si legge: si riapre in Scrivi per continuare.
    if (_error == null && _isDraft) {
      var files = <String>[];
      if (m.hasAtt) {
        try {
          files = await Ops.forwardFiles(a, m);
        } catch (e) {
          if (mounted) {
            showSnack(context, 'Gli allegati della bozza non si sono scaricati: ${friendlyError(e)}');
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
    setState(() => _loading = false);
    _scheduleRead();
    // Dopo, non prima: l'elenco allegati aspetta in coda dietro alle sincronizzazioni, e il testo
    // già sul telefono non deve aspettare con lui.
    if (_error == null) _caricaAllegati();
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
        action: act == Act.delete && roleOfPath(widget.folders, m.folder) == 'trash'
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
          showSnack(context, 'Gli allegati non si sono scaricati: ${friendlyError(e)}');
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

  Widget _body() {
    final fg = Theme.of(context).colorScheme.onSurface;
    final s = Settings.i;
    final html = m.bodyHtml ?? '';
    if (html.trim().isNotEmpty) {
      final cleaned = Ops.cleanHtml(
        html,
        blockImages: s.blockRemoteImages && !_showImages,
        blockTracking: s.blockTracking,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.blockRemoteImages && !_showImages && cleaned.blocked > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined),
                label: const Text('Mostra le immagini'),
                onPressed: () => setState(() => _showImages = true),
              ),
            ),
          HtmlWidget(
            linkify(cleaned.html),
            textStyle: TextStyle(
          fontFamily: 'RobotoLight',
          fontSize: 17,
          color: fg,
          height: 1.62,
        ),
            // Outlook toglie lo spazio fra i paragrafi con un suo stile: qui va rifatto.
            customStylesBuilder: (e) =>
                e.localName == 'p' && e.classes.contains('MsoNormal')
                ? {'margin': '0'}
                : null,
            onTapUrl: _openUrl,
          ),
        ],
      );
    }
    if (_plain.isEmpty) {
      return Text(
        '(messaggio vuoto)',
        style: TextStyle(
          fontFamily: 'RobotoLight',
          fontSize: 17,
          color: fg,
          height: 1.62,
        ),
      );
    }
    return SelectionArea(
      child: HtmlWidget(
        plainToHtml(_plain),
        textStyle: TextStyle(
          fontFamily: 'RobotoLight',
          fontSize: 17,
          color: fg,
          height: 1.62,
        ),
        onTapUrl: _openUrl,
      ),
    );
  }

  /// Un tocco su un link: un indirizzo email apre Scrivi, un numero la chiamata,
  /// il resto il browser.
  Future<bool> _openUrl(String url) async {
    final t = url.trim();
    if (t.toLowerCase().startsWith('mailto:')) {
      final u = Uri.tryParse(t);
      final q = u?.queryParameters ?? const <String, String>{};
      List<String> lista(String v) => [
        for (final x in v.split(',')) if (x.trim().isNotEmpty) x.trim(),
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
    final s = Settings.i;
    final tb = s.toolbar;
    final sus = Ops.suspicion(m);
    final canUnsub = Ops.canUnsubscribe(m);
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), 
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
                child: Text(
                  m.seen ? 'Segna come non letta' : 'Segna come letta',
                ),
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
              if (canUnsub)
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
              const PopupMenuItem(
                value: 'settings',
                child: Text('Impostazioni'),
              ),
              const PopupMenuItem(value: 'copy', child: Text('Copia il testo')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: _swipeNav,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    Text(
                      m.subject.isEmpty ? '(senza oggetto)' : m.subject,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => setState(() => _details = !_details),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SenderAvatar(
                            m.sender,
                            a.color,
                            size: 40,
                            addr: m.fromAddr,
                          ),
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
                                      _details
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 24,
                                    ),
                                  ],
                                ),
                                if (_details) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Da: ${m.fromAddr}',
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                  Text(
                                    'A: ${m.toAddrs.isEmpty ? a.address : m.toAddrs}',
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                  if (m.ccAddrs.isNotEmpty)
                                    Text(
                                      'Cc: ${m.ccAddrs}',
                                      style: const TextStyle(fontSize: 15),
                                    ),
                                  Text(
                                    formatFull(m.date),
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (sus != null)
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDECEA),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFB3261E)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Color(0xFFB3261E),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                sus,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
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
                      const Divider(height: 24),
                      for (final att in _atts)
                        InkWell(
                          onTap: () => _download(att),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.description_outlined,
                                  size: 30,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        att.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 17),
                                      ),
                                      Text(
                                        formatSize(att.size),
                                        style: const TextStyle(fontSize: 15),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.download, size: 30),
                              ],
                            ),
                          ),
                        ),
                    ],
                    const Divider(height: 28),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(30),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_error != null)
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFB3261E),
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      )
                    else
                      _body(),
                  ],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: kBarraGrad,
                border: const Border(top: BorderSide(color: kContorno, width: 3)),
              ),
              child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final act in tb)
                    IconButton(
                      iconSize: 26,
                      tooltip: actLabel[act],
                      icon: Icon(actIcon(act)),
                      onPressed: () => _act(act),
                    ),
                ],
              )),
            ),
          ],
        ),
      ),
    );
  }
}
