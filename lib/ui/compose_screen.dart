import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource, Document, QuillController;
import 'package:image_picker/image_picker.dart';

import '../ai.dart';
import '../db.dart';
import '../linkify.dart';
import '../mail/backend.dart';
import '../mail/imap_backend.dart';
import '../models.dart';
import '../ops.dart';
import '../phone_contacts.dart';
import 'rich_editor.dart';
import '../settings.dart';
import '../signature.dart';
import '../theme.dart';
import 'widgets.dart';

/// Punto di partenza di un messaggio da scrivere.
class ComposeInit {
  /// Diventa vero quando da questa schermata è partito un invio o si è salvata una bozza: chi
  /// l'ha aperta per modificare un invio programmato sa così se quello vecchio va rimesso.
  bool consumata = false;
  int? accountId;
  String fromAddress;
  List<String> to;
  List<String> cc;
  List<String> bcc;
  String subject;
  String body;
  String delta; // il testo con i formati (grassetto…), per riaprire una bozza identica
  String quote;
  String? inReplyTo;
  String? references;

  List<String> files;
  bool useSignature;

  /// Se è una bozza riaperta: dov'è sul server, così al nuovo salvataggio o all'invio la vecchia sparisce.
  DraftRef? draft;

  ComposeInit({
    this.draft,
    this.accountId,
    this.fromAddress = '',
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.body = '',
    this.delta = '',
    this.quote = '',
    this.inReplyTo,
    this.references,
    this.files = const [],
    this.useSignature = true,
  });

  /// Riapre un'email messa in coda (annullata o da modificare) com'era prima.
  factory ComposeInit.fromPayload(Map<String, dynamic> j) {
    final c = (j['compose'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<String> l(String k) => List<String>.from((j[k] as List?) ?? const []);
    return ComposeInit(
      accountId: j['accountId'] as int?,
      fromAddress: (j['fromAddress'] ?? '') as String,
      to: l('to'),
      cc: l('cc'),
      bcc: l('bcc'),
      subject: (j['subject'] ?? '') as String,
      body: (c['body'] ?? j['text'] ?? '') as String,
      delta: (c['delta'] ?? '') as String,
      quote: (c['quote'] ?? '') as String,
      inReplyTo: j['inReplyTo'] as String?,
      references: j['references'] as String?,
      files: l('attachmentPaths'),
      useSignature: (c['useSig'] ?? true) as bool,
    );
  }

  /// Riapre una bozza dalla cartella Bozze: il testo c'è già con la firma e la citazione.
  factory ComposeInit.fromDraft(Account a, Msg m, {List<String> files = const []}) {
    List<String> addrs(String s) =>
        s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final body = (m.bodyText != null && m.bodyText!.trim().isNotEmpty)
        ? m.bodyText!
        : testoDaHtml(m.bodyHtml ?? '');
    return ComposeInit(
      accountId: a.id,
      fromAddress: m.fromAddr.isNotEmpty ? m.fromAddr : a.address,
      to: addrs(m.toAddrs),
      cc: addrs(m.ccAddrs),
      subject: m.subject,
      body: body,
      // Con un testo già formato la firma non si rimette una seconda volta.
      // Con l'HTML la bozza si riapre con grassetto, link e logo della firma; il solo testo li perde.
      delta: RichDoc.deltaJson(
        (m.bodyHtml ?? '').trim().isNotEmpty
            ? RichDoc.fromHtml(m.bodyHtml!)
            : RichDoc.fromText(body),
      ),
      files: files,
      draft: DraftRef(m.folder, m.uid),
      // La risposta riaperta dalle bozze resta nella conversazione: l'ultimo riferimento è
      // l'email a cui si risponde.
      references: m.refs.isEmpty ? null : m.refs,
      inReplyTo: m.refs.trim().isEmpty ? null : m.refs.trim().split(RegExp(r'\s+')).last,
    );
  }

  /// Risposta, risposta a tutti o inoltro a partire da un messaggio.
  factory ComposeInit.from(
    Account a,
    Msg m,
    Act act, {
    String body = '',
    String? draft,
  }) {
    // Dal gesto sulla lista il testo non arriva: si prende da quello salvato, se no la
    // risposta e l'inoltro partirebbero senza il messaggio citato.
    if (body.trim().isEmpty) {
      body = (m.bodyText != null && m.bodyText!.trim().isNotEmpty)
          ? m.bodyText!
          : testoDaHtml(m.bodyHtml ?? '');
    }
    final own = {
      a.address.toLowerCase(),
      ...a.aliases.map((x) => x.address.toLowerCase()),
    };
    List<String> split(String s) => s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !own.contains(e.toLowerCase()))
        .toList();
    String re(String s) =>
        RegExp(r'^\s*(re|r|rif|aw|sv)\s*:', caseSensitive: false).hasMatch(s)
        ? s
        : 'Re: $s';
    String fw(String s) =>
        RegExp(r'^\s*(fwd|fw|i|wg)\s*:', caseSensitive: false).hasMatch(s)
        ? s
        : 'Fwd: $s';
    var from = a.address;
    for (final x in [...m.toAddrs.split(','), ...m.ccAddrs.split(',')]) {
      final t = x.trim().toLowerCase();
      for (final al in a.aliases) {
        if (al.address.toLowerCase() == t) from = al.address;
      }
    }
    if (act == Act.forward) {
      return ComposeInit(
        accountId: a.id,
        fromAddress: from,
        subject: fw(m.subject),
        quote:
            '\n\n---------- Messaggio inoltrato ----------\nDa: ${m.sender} <${m.fromAddr}>\nData: ${m.date}\nOggetto: ${m.subject}\nA: ${m.toAddrs}\n\n${body.trim()}',
      );
    }
    // Se il mittente indica un Reply-To (newsletter, ticket, gruppi) la risposta va lì.
    final to = [m.replyTo.isNotEmpty ? m.replyTo : m.fromAddr];
    final visti = <String>{};
    final cc = act == Act.replyAll
        ? [
            ...split(m.toAddrs),
            ...split(m.ccAddrs),
          ].where((e) => e.toLowerCase() != m.fromAddr.toLowerCase() && e.toLowerCase() != to.first.toLowerCase() && visti.add(e.toLowerCase())).toList()
        : <String>[];
    return ComposeInit(
      accountId: a.id,
      fromAddress: from,
      to: to,
      cc: cc,
      subject: re(m.subject),
      body: draft ?? '',
      quote: Ops.quote(m, body),
      inReplyTo: m.messageId,
      references: m.refs.isEmpty ? null : m.refs,
    );
  }
}

String _esc(String s) => const HtmlEscape().convert(s).replaceAll('\n', '<br>');

/// Scrittura di un messaggio.
class ComposeScreen extends StatefulWidget {
  final ComposeInit? init;
  const ComposeScreen({super.key, this.init});
  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  List<Account> _accounts = [];
  Account? _acc;
  String _from = '';
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _bcc = TextEditingController();
  final _subject = TextEditingController();
  late final QuillController _q;
  bool _showCc = false;
  final List<String> _files = [];
  bool _sending = false;
  late bool _useSignature;
  bool _dirty = false;
  List<Map<String, Object?>> _suggest = [];
  TextEditingController? _activeField;
  late ComposeInit _init;
  DraftRef? _draft;
  int? _draftAccountId;

  @override
  void initState() {
    super.initState();
    _init = widget.init ?? ComposeInit();
    _draft = _init.draft;
    _draftAccountId = _init.accountId;
    _to.text = _init.to.join(', ');
    _cc.text = _init.cc.join(', ');
    _bcc.text = _init.bcc.join(', ');
    _subject.text = _init.subject;
    Document doc;
    try {
      doc = _init.delta.isNotEmpty
          ? RichDoc.fromDeltaJson(_init.delta)
          : RichDoc.fromText(_init.body);
    } catch (_) {
      doc = RichDoc.fromText(_init.body);
    }
    _q = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _ascoltaModifiche();
    _showCc = _init.cc.isNotEmpty || _init.bcc.isNotEmpty;
    _files.addAll(_init.files);
    _useSignature = _init.useSignature;
    for (final c in [_to, _cc, _bcc, _subject]) {
      c.addListener(() => _dirty = true);
    }
    _load();
  }

  Future<void> _load() async {
    final list = await Db.i.accounts();
    if (!mounted || list.isEmpty) return;
    Account pick = list.first;
    final want =
        _init.accountId ??
        (Settings.i.defaultAccountId != 0 ? Settings.i.defaultAccountId : null);
    if (want != null) {
      for (final a in list) {
        if (a.id == want) pick = a;
      }
    }
    setState(() {
      _accounts = list;
      _acc = pick;
      _from = _init.fromAddress.isNotEmpty ? _init.fromAddress : pick.address;
    });
    // Una bozza riaperta ha già la firma nel testo; un messaggio nuovo la riceve ora.
    if (_useSignature && _init.delta.isEmpty) {
      _putSignature(pick);
      _dirty = false;
    }
  }

  /// La firma sta dentro il testo, dopo due righe vuote: si sposta e si cancella come
  /// qualunque altra riga.
  /// Il segno «testo modificato» sta sul documento: quando la firma lo sostituisce
  /// (`_q.document = …`) va riagganciato, altrimenti Indietro usciva senza chiedere
  /// e il testo scritto andava perso.
  void _ascoltaModifiche() {
    _q.document.changes.listen((_) => _dirty = true);
  }

  void _putSignature(Account a) {
    final html = SignatureTools.forSend(a.signatureHtml);
    if (html.trim().isEmpty) return;
    final sig = RichDoc.fromHtml(SignatureTools.asBlocks(html));
    final keep = _q.selection;
    _q.document = RichDoc.withSignature(_q.document, sig);
    _ascoltaModifiche();
    _q.updateSelection(
      TextSelection.collapsed(
        offset: keep.baseOffset.clamp(0, _q.document.length - 1),
      ),
      ChangeSource.local,
    );
  }

  @override
  void dispose() {
    for (final c in [_to, _cc, _bcc, _subject]) {
      c.dispose();
    }
    _q.dispose();
    super.dispose();
  }

  List<String> _split(String s) => s
      .split(RegExp(r'[,;\n]'))
      .map((e) {
        // Incollato da un altro programma: «Mario Rossi <m@x.ch>».
        final t = e.trim();
        return RegExp(r'<([^<>\s]+@[^<>\s]+)>\s*$').firstMatch(t)?.group(1) ?? t;
      })
      .where((e) => e.isNotEmpty)
      .toList();
  bool _validMail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

  /// La prima volta si spiega a cosa serve la rubrica, poi Android chiede il permesso.
  Future<void> _chiediRubrica() async {
    if (!Settings.i.rubricaChiesta) {
      Settings.i.rubricaChiesta = true;
      Settings.i.rubricaOk = await confirm(
        context,
        'Usare la rubrica del telefono?',
        'DiGiMail legge nomi e indirizzi email per suggerirti i destinatari mentre scrivi. Restano sul telefono, non vanno da nessuna parte.',
        yes: 'Usa la rubrica',
      );
    }
    await PhoneContacts.all();
  }

  Future<void> _suggestFor(TextEditingController c) async {
    _activeField = c;
    final last = c.text.split(RegExp(r'[,;]')).last.trim();
    if (last.isEmpty) {
      if (_suggest.isNotEmpty) setState(() => _suggest = []);
      return;
    }
    // Prima chi è già passato dalla posta, poi la rubrica del telefono.
    final r = [...await Db.i.contacts(last)];
    final seen = {for (final x in r) '${x['address']}'.toLowerCase()};
    for (final p in await PhoneContacts.search(last)) {
      if (seen.add(p.address.toLowerCase())) {
        r.add({'name': p.name, 'address': p.address});
      }
    }
    if (mounted && _activeField == c) {
      setState(() => _suggest = r.take(8).toList());
    }
  }

  void _pickSuggestion(String address) {
    final c = _activeField;
    if (c == null) return;
    final parts = c.text.split(RegExp(r'[,;]'));
    parts.removeLast();
    parts.add(' $address');
    c.text =
        '${parts.map((e) => e.trim()).where((e) => e.isNotEmpty).join(', ')}, ';
    c.selection = TextSelection.collapsed(offset: c.text.length);
    setState(() => _suggest = []);
  }

  Widget _recipientField(String label, TextEditingController c) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: c,
      keyboardType: TextInputType.emailAddress,
      decoration: InputDecoration(labelText: label, isDense: true),
      onTap: _chiediRubrica,
      onChanged: (_) => _suggestFor(c),
    ),
  );

  /// Il testo scritto, senza formati.
  String get _bodyText =>
      _q.document.toPlainText().replaceFirst(RegExp(r'\n$'), '');

  /// Fra l'ultima parola e la firma: due righe vuote (deciso dall'utente).
  Outgoing _build() {
    final acc = _acc!;
    final text = '$_bodyText${_init.quote}';
    final html =
        '<div style="font-family:\'Roboto Light\',sans-serif;font-size:12pt;color:#000">${RichDoc.trimBreaks(RichDoc.toHtml(_q.document))}</div>${_init.quote.isEmpty ? '' : '<br><blockquote style="margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex">${_esc(_init.quote.trim())}</blockquote>'}';
    final alias = acc.aliases.where(
      (x) => x.address.toLowerCase() == _from.toLowerCase(),
    );
    return Outgoing(
      accountId: acc.id!,
      fromAddress: _from,
      fromName: alias.isNotEmpty && alias.first.name.isNotEmpty
          ? alias.first.name
          : acc.displaySender,
      to: _split(_to.text),
      cc: _split(_cc.text),
      bcc: _split(_bcc.text),
      subject: _subject.text.trim(),
      text: text,
      html: html,
      attachmentPaths: List.of(_files),
      inReplyTo: _init.inReplyTo,
      references: _init.references,
    );
  }

  String? _check() {
    final all = [
      ..._split(_to.text),
      ..._split(_cc.text),
      ..._split(_bcc.text),
    ];
    if (all.isEmpty) return 'Scrivi almeno un destinatario.';
    final bad = all.where((e) => !_validMail(e));
    if (bad.isNotEmpty) return 'Indirizzo non valido: ${bad.first}';
    return null;
  }

  /// Il messaggio com'è adesso, più ciò che serve per riaprirlo identico (testo senza firma, citazione, firma sì/no).
  Map<String, Object?> _compose() => {
    'body': _bodyText,
    'delta': RichDoc.deltaJson(_q.document),
    'quote': _init.quote,
    'useSig': _useSignature,
  };

  bool get _sigInText {
    final a = _acc;
    if (a == null) return false;
    final sig = _sigPlain(a);
    // Non per forza in fondo: l'utente può aver scritto anche sotto la firma.
    return sig.isNotEmpty && _bodyText.contains(sig);
  }

  String _sigPlain(Account a) {
    final h = SignatureTools.forSend(a.signatureHtml);
    if (h.trim().isEmpty) return '';
    return RichDoc.fromHtml(SignatureTools.asBlocks(h))
        .toPlainText()
        .trimRight();
  }

  /// Toglie dal testo la firma di [a] (con le righe vuote che la precedono).
  void _removeSignature(Account a) {
    final sig = _sigPlain(a);
    final text = _q.document.toPlainText();
    final at = text.lastIndexOf(sig);
    var from = at;
    while (from > 0 && text[from - 1] == '\n') {
      from--;
    }
    // Solo la firma: quello che l'utente ha scritto sotto resta.
    _q.document.delete(from, at + sig.length - from);
  }

  /// Cambio di casella mittente: la firma della vecchia lascia il posto a quella della nuova.
  void _switchAccount(Account next) {
    final old = _acc;
    if (old == null || old.id == next.id) return;
    final had = _sigInText;
    final oldHadNone = _sigPlain(old).isEmpty;
    if (had) _removeSignature(old);
    _acc = next;
    _from = next.address;
    if (had || (_useSignature && oldHadNone)) _putSignature(next);
  }

  void _toggleSignature() {
    final a = _acc;
    if (a == null) return;
    if (_sigInText) {
      _removeSignature(a);
    } else {
      _putSignature(a);
    }
    setState(() => _useSignature = _sigInText);
  }

  Future<void> _send() async {
    if (_acc == null) return;
    final err = _check();
    if (err != null) {
      showSnack(context, err);
      return;
    }
    if (_subject.text.trim().isEmpty &&
        !await confirm(
          context,
          'Senza oggetto',
          'Vuoi inviare l\'email senza oggetto?',
          yes: 'Invia',
        ))
      return;
    final tooBig = await _attachmentsSize();
    if (tooBig > 20 * 1024 * 1024 && mounted) {
      if (!await confirm(
        context,
        'Allegati grandi',
        'Gli allegati pesano ${formatSize(tooBig)}: molti server rifiutano oltre 20-25 MB. Provo lo stesso?',
        yes: 'Invia',
      ))
        return;
    }
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final undo = Settings.i.undoSeconds;
    if (undo > 0) {
      // L'email va in coda per i secondi di «Annulla»: se si chiude l'app parte lo stesso.
      // «Invia» si spegne subito: la coda e la bozza vecchia prendono qualche secondo e un
      // secondo tocco mandava l'email due volte.
      setState(() => _sending = true);
      final o = _build();
      final id = await Ops.queueSend(
        _acc!,
        o,
        DateTime.now().add(Duration(seconds: undo)),
        compose: _compose(),
      );
      _dirty = false;
      _init.consumata = true;
      await _dropOldDraft(_acc!);
      nav.pop();
      Timer(Duration(seconds: undo + 1), () => Ops.processScheduled());
      messenger.showSnackBar(
        SnackBar(
          duration: Duration(seconds: undo),
          content: const Text('Invio in corso…'),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () async {
              if (!await Ops.cancelQueued(id)) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Era già partita.')),
                );
                return;
              }
              final payload = {...o.toJson(), 'compose': _compose()};
              nav.push(
                MaterialPageRoute(
                  builder: (_) =>
                      ComposeScreen(init: ComposeInit.fromPayload(payload)),
                ),
              );
            },
          ),
        ),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await Ops.send(_build());
      Ops.playSent();
      _dirty = false;
      _init.consumata = true;
      await _dropOldDraft(_acc!);
      nav.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(Ops.lastSendWarning ?? 'Email inviata')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showSnack(context, 'Invio non riuscito: ${friendlyError(e)}');
      }
    }
  }

  Future<int> _attachmentsSize() async {
    var n = 0;
    for (final p in _files) {
      try {
        n += await File(p).length();
      } catch (_) {}
    }
    return n;
  }

  Future<void> _schedule() async {
    if (_acc == null) return;
    final err = _check();
    if (err != null) {
      showSnack(context, err);
      return;
    }
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (t == null || !mounted) return;
    final at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    if (!at.isAfter(now)) {
      showSnack(context, 'Scegli un momento nel futuro.');
      return;
    }
    setState(() => _sending = true);
    await Ops.queueSend(_acc!, _build(), at, compose: _compose());
    _dirty = false;
    _init.consumata = true;
    await _dropOldDraft(_acc!);
    if (!mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    nav.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Programmata per le ${formatDate(at)}. La trovi in «Programmati».',
        ),
      ),
    );
  }

  /// Toglie dal server la bozza da cui si è partiti (o l'ultima salvata): ormai esiste la versione nuova.
  Future<void> _dropOldDraft(Account a) async {
    final old = _draft;
    if (old == null) return;
    _draft = null;
    // La bozza sta nella casella in cui è stata salvata, anche se poi il mittente è cambiato.
    final owner = _accounts.where((x) => x.id == _draftAccountId);
    try {
      await Backends.of(owner.isNotEmpty ? owner.first : a)
          .discardDraft(old.folder, old.uid);
    } catch (_) {}
  }

  Future<void> _saveDraft({bool close = true}) async {
    if (_acc == null) return;
    try {
      final acc = _acc!;
      final ref = await Backends.of(acc).saveDraft(_build());
      final old = _draft;
      final oldOwner = _draftAccountId;
      _draft = ref;
      _draftAccountId = acc.id;
      if (old != null) {
        final owner = _accounts.where((x) => x.id == oldOwner);
        try {
          await Backends.of(owner.isNotEmpty ? owner.first : acc)
              .discardDraft(old.folder, old.uid);
        } catch (_) {}
      }
      _dirty = false;
      _init.consumata = true;
      if (close && mounted) {
        final m = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        m.showSnackBar(const SnackBar(content: Text('Bozza salvata')));
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Bozza non salvata: ${friendlyError(e)}');
    }
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File o Drive', style: TextStyle(fontSize: 18)),
              onTap: () => Navigator.pop(c, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text(
                'Foto dalla galleria',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () => Navigator.pop(c, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text(
                'Scatta una foto',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == 'file') {
        final r = await FilePicker.pickFiles(allowMultiple: true);
        if (r != null)
          setState(() => _files.addAll(r.paths.whereType<String>()));
      } else if (choice == 'photo') {
        final r = await ImagePicker().pickMultiImage();
        setState(() => _files.addAll(r.map((x) => x.path)));
      } else {
        final r = await ImagePicker().pickImage(source: ImageSource.camera);
        if (r != null) setState(() => _files.add(r.path));
      }
      _dirty = true;
    } catch (e) {
      if (mounted) showSnack(context, 'Allegato non aggiunto: $e');
    }
  }

  Future<void> _ai() async {
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
    final prompt = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Scrivi con IA'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Cosa vuoi scrivere?'),
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
    if (prompt == null || prompt.isEmpty || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      // Il tasto Indietro non chiude l'attesa: all'arrivo della risposta si chiuderebbe Scrivi,
      // con il testo scritto.
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    String? text;
    String? err;
    try {
      text = await Ai.compose(prompt);
    } catch (e) {
      err = friendlyError(e);
    }
    if (!mounted) return;
    Navigator.pop(context);
    if (err != null) {
      showSnack(context, err);
      return;
    }
    setState(
      () => _q.document.insert(
        _q.document.length - 1,
        _bodyText.trim().isEmpty ? text! : '\n\n$text',
      ),
    );
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty ||
        (_bodyText.trim().isEmpty &&
            _subject.text.trim().isEmpty &&
            _to.text.trim().isEmpty))
      return true;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Uscire senza inviare?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'keep'),
            child: const Text('Continua a scrivere'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'draft'),
            child: const Text('Salva bozza'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'drop'),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (r == 'draft') {
      await _saveDraft();
      return false;
    }
    return r == 'drop';
  }

  @override
  Widget build(BuildContext context) {
    final acc = _acc;
    final fromChoices = <DropdownMenuItem<String>>[];
    if (acc != null) {
      fromChoices.add(
        DropdownMenuItem(
          value: acc.address,
          child: Text(acc.address, overflow: TextOverflow.ellipsis),
        ),
      );
      for (final al in acc.aliases) {
        fromChoices.add(
          DropdownMenuItem(
            value: al.address,
            child: Text(
              '${al.address} (alias)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Nuova email'),
          actions: [
            IconButton(
              tooltip: 'Allega',
              icon: const Icon(Icons.attach_file),
              onPressed: _attach,
            ),
            IconButton(
              tooltip: 'Scrivi con IA',
              icon: const Icon(Icons.auto_awesome),
              onPressed: _ai,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'schedule') _schedule();
                if (v == 'draft') _saveDraft();
                if (v == 'cc') setState(() => _showCc = !_showCc);
                if (v == 'sig') _toggleSignature();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'schedule',
                  child: Text('Programma l\'invio'),
                ),
                const PopupMenuItem(value: 'draft', child: Text('Salva bozza')),
                PopupMenuItem(
                  value: 'cc',
                  child: Text(
                    _showCc ? 'Nascondi Cc e Ccn' : 'Mostra Cc e Ccn',
                  ),
                ),
                PopupMenuItem(
                  value: 'sig',
                  child: Text(
                    _sigInText ? 'Togli la firma' : 'Metti la firma',
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                // Sulla barra arancione il tasto è bianco con scritta nera.
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                onPressed: _sending || acc == null ? null : _send,
                icon: const Icon(Icons.send, size: 18),
                label: Text(_sending ? 'Invio…' : 'Invia'),
              ),
            ),
          ],
        ),
        body: acc == null
            ? const Center(
                child: Text(
                  'Aggiungi prima una casella.',
                  style: TextStyle(fontSize: 18),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  if (_sending) const LinearProgressIndicator(color: kAccento),
                  Row(
                    children: [
                      const Text(
                        'Da',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<int>(
                          iconEnabledColor: Colors.black,
                          isExpanded: true,
                          value: acc.id,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final a in _accounts)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.name.isEmpty
                                      ? a.address
                                      : '${a.name} · ${a.address}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => _switchAccount(
                              _accounts.firstWhere((a) => a.id == v),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (acc.aliases.isNotEmpty)
                    DropdownButton<String>(
                      iconEnabledColor: Colors.black,
                      isExpanded: true,
                      value: fromChoices.any((x) => x.value == _from)
                          ? _from
                          : acc.address,
                      items: fromChoices,
                      onChanged: (v) =>
                          setState(() => _from = v ?? acc.address),
                    ),
                  const SizedBox(height: 6),
                  _recipientField('A', _to),
                  if (_showCc) ...[
                    _recipientField('Cc', _cc),
                    _recipientField('Ccn', _bcc),
                  ],
                  if (_suggest.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final s in _suggest)
                          ActionChip(
                            label: Text(
                              ((s['name'] as String?) ?? '').isNotEmpty
                                  ? '${s['name']} <${s['address']}>'
                                  : '${s['address']}',
                            ),
                            onPressed: () =>
                                _pickSuggestion(s['address'] as String),
                          ),
                      ],
                    ),
                  TextField(
                    controller: _subject,
                    decoration: const InputDecoration(
                      labelText: 'Oggetto',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_files.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final f in _files)
                          InputChip(
                            avatar: const Icon(Icons.attach_file, size: 18),
                            label: Text(
                              f.split(RegExp(r'[\\/]')).last,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onDeleted: () => setState(() => _files.remove(f)),
                          ),
                      ],
                    ),
                  RichToolbar(controller: _q),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 220),
                    child: RichEditor(
                      controller: _q,
                      placeholder: 'Scrivi qui il messaggio',
                    ),
                  ),
                  if (_init.quote.isNotEmpty) ...[
                    const Divider(),
                    Text(
                      _init.quote.trim(),
                      style: const TextStyle(fontSize: 15, fontFamily: 'RobotoLight'),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
