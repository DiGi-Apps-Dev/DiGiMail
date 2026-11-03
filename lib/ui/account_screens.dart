import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show ChangeSource, QuillController;
import 'package:flutter_quill/quill_delta.dart' show Delta;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db.dart';
import '../mail/backend.dart';
import '../mail/imap_backend.dart';
import '../mail/ms_oauth.dart';
import '../mail/secrets.dart';
import '../models.dart';
import '../nas_push.dart';
import '../notify.dart';
import '../ops.dart';
import '../push_service.dart';
import '../settings.dart';
import '../signature.dart';
import '../theme.dart';
import 'rich_editor.dart';
import 'widgets.dart';

/// Tutte le impostazioni di una casella.
class AccountSettingsScreen extends StatefulWidget {
  final int accountId;
  const AccountSettingsScreen({super.key, required this.accountId});
  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  Account? a;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final x = await Db.i.account(widget.accountId);
    if (mounted) setState(() => a = x);
  }

  Future<void> _save() async {
    await Db.i.saveAccount(a!);
    if (mounted) setState(() {});
  }

  Future<String?> _ask(
    String title,
    String initial, {
    bool password = false,
    String? hint,
  }) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: password,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLogo() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text(
                'Scegli una foto dalla galleria',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () => Navigator.pop(c, 'pick'),
            ),
            ListTile(
              leading: const Icon(Icons.abc),
              title: const Text(
                'Usa la lettera colorata',
                style: TextStyle(fontSize: 18),
              ),
              onTap: () => Navigator.pop(c, 'letter'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'letter') {
      a!.logoPath = null;
      await _save();
    } else if (choice == 'pick') {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (x == null) return;
      final dir = await getApplicationSupportDirectory();
      final dest = File(
        '${dir.path}/logo_${a!.id}_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await File(x.path).copy(dest.path);
      a!.logoPath = dest.path;
      await _save();
    }
  }

  Future<void> _pickColor() async {
    final c = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Colore'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in kColori)
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx, c),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: Color(c),
                      child: a!.color == c
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (c != null) {
      a!.color = c;
      await _save();
    }
  }

  Future<void> _addAlias() async {
    final addr = await _ask('Alias', '', hint: 'indirizzo@dominio.it');
    if (addr == null || !addr.contains('@')) return;
    if (!mounted) return;
    final name = await _ask('Nome mittente per questo alias', a!.displaySender);
    a!.aliases = [...a!.aliases, Alias(addr, name ?? '')];
    await _save();
    if (mounted)
      showSnack(
        context,
        'L\'alias deve essere già creato e verificato presso il fornitore (Gmail, Outlook, iCloud), altrimenti l\'invio viene rifiutato.',
      );
  }

  Future<void> _editServer({required bool incoming}) async {
    final acc = a!;
    final host = TextEditingController(
      text: incoming ? acc.imapHost : acc.smtpHost,
    );
    final port = TextEditingController(
      text: '${incoming ? acc.imapPort : acc.smtpPort}',
    );
    var ssl = incoming ? acc.imapSsl : acc.smtpSsl;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(incoming ? 'Posta in arrivo (IMAP)' : 'Posta in uscita (SMTP)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: host,
                decoration: const InputDecoration(labelText: 'Server'),
              ),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Porta'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('SSL/TLS (spento = STARTTLS)'),
                value: ssl,
                onChanged: (v) => set(() => ssl = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annulla'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final p = int.tryParse(port.text.trim()) ?? (incoming ? 993 : 465);
    if (incoming) {
      // Prima si prova: dati sbagliati lascerebbero la casella morta e il NAS registrato male.
      final prima = (acc.imapHost, acc.imapPort, acc.imapSsl);
      acc.imapHost = host.text.trim();
      acc.imapPort = p;
      acc.imapSsl = ssl;
      try {
        await verifyAccount(
          acc,
          password: await Secrets.password(acc.id!),
          msTokenJson: await Secrets.msToken(acc.id!),
        );
      } catch (e) {
        acc.imapHost = prima.$1;
        acc.imapPort = prima.$2;
        acc.imapSsl = prima.$3;
        if (mounted) showSnack(context, 'Server non cambiato: ${friendlyError(e)}');
        return;
      }
    } else {
      acc.smtpHost = host.text.trim();
      acc.smtpPort = p;
      acc.smtpSsl = ssl;
    }
    await _save();
    // La connessione già aperta usa i server di prima: va chiusa perché valgano quelli nuovi.
    await Backends.forget(acc.id!);
    await PushControl.restart();
  }

  Future<void> _relogin() async {
    final acc = a!;
    if (acc.authType == 'oauth_ms') {
      final id = Settings.i.msClientId;
      if (id.isEmpty) {
        showSnack(
          context,
          'Manca l\'ID applicazione Microsoft: aggiungilo da «Aggiungi account».',
        );
        return;
      }
      try {
        final auth = MsOAuth(id);
        final code = await auth.start();
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: const Text('Accedi con Microsoft'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Nel sito Microsoft inserisci questo codice:'),
                const SizedBox(height: 8),
                SelectableText(
                  code.userCode,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  auth.annulla();
                  Navigator.pop(c);
                },
                child: const Text('Annulla'),
              ),
            ],
          ),
        );
        await launchUrl(
          Uri.parse(code.verificationUri),
          mode: LaunchMode.externalApplication,
        );
        final token = await auth.waitForToken(code);
        await Secrets.setMsToken(acc.id!, token);
        if (mounted) Navigator.pop(context);
      } on MsAccessoAnnullato {
        return;
      } catch (e) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).maybePop();
          showSnack(context, '$e');
        }
        return;
      }
    } else {
      final pw = await _ask(
        'Nuova password',
        '',
        password: true,
        hint: 'Password (per app, se serve)',
      );
      if (pw == null || pw.isEmpty) return;
      try {
        await verifyAccount(acc, password: pw);
        await Secrets.setPassword(acc.id!, pw);
      } catch (e) {
        if (mounted) showSnack(context, friendlyError(e));
        return;
      }
    }
    await Backends.forget(acc.id!);
    await PushControl.restart();
    if (mounted) showSnack(context, 'Accesso rinnovato');
  }

  Future<void> _remove() async {
    if (!await confirm(
      context,
      'Togliere la casella?',
      'Tolgo ${a!.address} da DiGiMail e cancello le email scaricate sul telefono. Le email restano sul server.',
      yes: 'Togli',
    ))
      return;
    await Backends.forget(a!.id!);
    await Secrets.removeAccount(a!.id!);
    await Db.i.removeAccount(a!.id!);
    await Settings.i.forgetAccount(a!.id!);
    await PushControl.restart();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final x = a;
    if (x == null)
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    final s = Settings.i;
    return Scaffold(
      appBar: AppBar(title: Text(x.name.isEmpty ? x.address : x.name)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _pickLogo,
                  child: AccountAvatar(x, size: 88),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _pickLogo,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Cambia logo'),
                ),
                Text(x.address, style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
          const Etichetta('Aspetto'),
          ListTile(
            title: const Text('Nome della casella'),
            subtitle: Text(x.name),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final v = await _ask('Nome della casella', x.name);
              if (v != null && v.isNotEmpty) {
                x.name = v;
                await _save();
              }
            },
          ),
          ListTile(
            title: const Text('Colore'),
            trailing: CircleAvatar(radius: 14, backgroundColor: Color(x.color)),
            onTap: _pickColor,
          ),
          const Etichetta('Invio'),
          ListTile(
            title: const Text('Nome che vede chi riceve'),
            subtitle: Text(
              x.senderName.isEmpty
                  ? '(uso il nome della casella)'
                  : x.senderName,
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final v = await _ask('Nome mittente', x.senderName);
              if (v != null) {
                x.senderName = v;
                await _save();
              }
            },
          ),
          ListTile(
            title: const Text('Firma'),
            subtitle: Text(
              x.signatureHtml.isEmpty
                  ? 'Nessuna firma'
                  : x.signatureHtml
                        .replaceAll(RegExp(r'<[^>]+>'), ' ')
                        .replaceAll(RegExp(r'\s+'), ' ')
                        .trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SignatureScreen(accountId: x.id!),
                ),
              );
              _load();
            },
          ),
          SwitchListTile(
            title: const Text('Scrivi da questa casella di default'),
            value: s.defaultAccountId == x.id,
            onChanged: (v) =>
                setState(() => s.defaultAccountId = v ? x.id! : 0),
          ),
          SwitchListTile(
            title: const Text('Ccn sempre a me stesso'),
            subtitle: const Text(
              'Ogni email inviata ti arriva in copia nascosta',
            ),
            value: x.bccSelf,
            onChanged: (v) async {
              x.bccSelf = v;
              await _save();
            },
          ),
          SwitchListTile(
            title: const Text('Salva una copia nella cartella Inviata'),
            subtitle: const Text(
              'Spegni per Gmail e Outlook: lo fanno già da soli',
            ),
            value: x.saveSent,
            onChanged: (v) async {
              x.saveSent = v;
              await _save();
              await Backends.forget(x.id!);
            },
          ),
          const Etichetta('Alias'),
          for (final al in x.aliases)
            ListTile(
              title: Text(al.address),
              subtitle: Text(
                al.name.isEmpty ? 'Nome come la casella' : al.name,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  x.aliases = x.aliases
                      .where((e) => e.address != al.address)
                      .toList();
                  await _save();
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Aggiungi alias'),
            onTap: _addAlias,
          ),
          const Etichetta('Notifiche'),
          SwitchListTile(
            title: const Text('Avvisami per le email nuove'),
            value: x.notify,
            onChanged: (v) async {
              x.notify = v;
              await _save();
            },
          ),
          ListTile(
            title: const Text('Suono e vibrazione di questa casella'),
            subtitle: const Text('Si sceglie nella schermata di Android'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => Notify.openChannelSettings(x),
          ),
          const Etichetta('Sincronizzazione'),
          ListTile(
            title: const Text('Come arrivano le email'),
            subtitle: Text(
              s.syncMode(x.id!) == 'push'
                  ? 'Subito (connessione sempre aperta)'
                  : s.savedSyncMode(x.id!) == 'push'
                  ? 'Controllo ogni ${s.syncMinutes(x.id!)} minuti (tempo reale spento nelle Notifiche)'
                  : 'Controllo ogni ${s.syncMinutes(x.id!)} minuti',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: () async {
              final r = await pickOne<String>(
                context,
                'Come arrivano le email',
                ['push', 'interval'],
                (v) => v == 'push'
                    ? 'Subito (connessione sempre aperta)'
                    : 'Controllo a intervalli',
                s.savedSyncMode(x.id!),
              );
              if (r != null) {
                await s.setSyncMode(x.id!, r);
                await PushControl.restart();
                setState(() {});
              }
            },
          ),
          if (s.savedSyncMode(x.id!) == 'interval')
            ListTile(
              title: const Text('Ogni quanto controllare'),
              subtitle: Text(
                '${s.syncMinutes(x.id!)} minuti',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () async {
                final r = await pickOne<int>(
                  context,
                  'Ogni quanto controllare',
                  [5, 15, 30, 60],
                  (v) => '$v minuti',
                  s.syncMinutes(x.id!),
                );
                if (r != null) {
                  await s.setSyncMinutes(x.id!, r);
                  setState(() {});
                }
              },
            ),
          SwitchListTile(
            title: const Text('Solo con il Wi-Fi'),
            subtitle: const Text(
              'Con i dati mobili questa casella non si aggiorna',
            ),
            value: s.syncWifiOnly(x.id!),
            onChanged: (v) async {
              await s.setSyncWifiOnly(x.id!, v);
              await PushControl.restart();
              setState(() {});
            },
          ),
          ListTile(
            title: const Text('Storico da tenere nel telefono'),
            subtitle: Text(
              s.historyDays(x.id!) == 0
                  ? 'Tutto quello che hai aperto'
                  : 'Ultimi ${s.historyDays(x.id!)} giorni (fuori da In arrivo)',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: () async {
              final r = await pickOne<int>(
                context,
                'Storico da tenere',
                [0, 30, 90, 365],
                (v) => v == 0 ? 'Tutto' : 'Ultimi $v giorni',
                s.historyDays(x.id!),
              );
              if (r != null) {
                await s.setHistoryDays(x.id!, r);
                setState(() {});
              }
            },
          ),
          const ListTile(
            title: Text('Cartelle'),
            subtitle: Text(
              'In arrivo è sempre aggiornata; le altre cartelle si aggiornano quando le apri.',
            ),
          ),
          const Etichetta('Collegamento'),
          ListTile(
            title: const Text('Posta in arrivo'),
            subtitle: Text(
              '${x.imapHost}:${x.imapPort} ${x.imapSsl ? 'SSL/TLS' : 'STARTTLS'}',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editServer(incoming: true),
          ),
          ListTile(
            title: const Text('Posta in uscita'),
            subtitle: Text(
              '${x.smtpHost}:${x.smtpPort} ${x.smtpSsl ? 'SSL/TLS' : 'STARTTLS'}',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editServer(incoming: false),
          ),
          ListTile(
            title: const Text('Accesso'),
            subtitle: Text(
              x.authType == 'oauth_ms'
                  ? 'Account Microsoft'
                  : 'Password salvata nella memoria cifrata',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('Rifai l\'accesso o cambia la password'),
            onTap: _relogin,
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFB3261E)),
            title: const Text(
              'Togli questa casella',
              style: TextStyle(
                color: Color(0xFFB3261E),
                fontWeight: FontWeight.w800,
              ),
            ),
            onTap: _remove,
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// Firma di una casella: scritta a mano o presa da un'email già inviata.
class SignatureScreen extends StatefulWidget {
  final int accountId;
  const SignatureScreen({super.key, required this.accountId});
  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  Account? a;
  final _q = QuillController.basic();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Db.i.account(widget.accountId).then((x) {
      if (!mounted || x == null) return;
      setState(() {
        a = x;
        _setHtml(x.signatureHtml);
      });
    });
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _setHtml(String html) {
    _q.document = RichDoc.fromHtml(html);
  }

  /// La firma come sarà salvata, con formati e immagini.
  String get _current => RichDoc.toHtml(_q.document);

  /// Un'immagine dalla galleria, dove si trova il cursore.
  Future<void> _addImage() async {
    final f = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 600,
      maxHeight: 600,
    );
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    int? w;
    try {
      final img = await decodeImageFromList(bytes);
      w = img.width > 205 ? 205 : img.width;
    } catch (_) {}
    if (!mounted) return;
    final src = RegExp(
      r'src="([^"]+)"',
    ).firstMatch(SignatureTools.imgTag(bytes))!.group(1)!;
    var at = _q.selection.baseOffset;
    if (at < 0 || at > _q.document.length - 1) at = _q.document.length - 1;
    // La larghezza va nell'inserimento stesso: formatText su un'immagine dà errore e
    // la firma salvata resterebbe senza larghezza.
    _q.compose(
      Delta()
        ..retain(at)
        ..insert({'image': src}, w == null ? null : {'width': '$w'}),
      TextSelection.collapsed(offset: at + 1),
      ChangeSource.local,
    );
  }

  Future<void> _fromSent() async {
    setState(() => _busy = true);
    try {
      final b = Backends.of(a!);
      final folders = await b.folders();
      final sent = folders.firstWhere(
        (f) => f.role == 'sent',
        orElse: () => const Folder('', '', 'none'),
      );
      if (sent.role == 'none') {
        if (mounted)
          showSnack(context, 'Questa casella non ha una cartella Inviata.');
        setState(() => _busy = false);
        return;
      }
      await b.sync(sent.path, count: 25);
      final list = await Db.i.messages(a!.id!, sent.path, limit: 25);
      if (!mounted) return;
      setState(() => _busy = false);
      final chosen = await showModalBottomSheet<Msg>(
        context: context,
        isScrollControlled: true,
        builder: (c) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (c, sc) => Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'SCEGLI UN\'EMAIL INVIATA',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: sc,
                  children: [
                    for (final m in list)
                      ListTile(
                        title: Text(
                          m.subject.isEmpty ? '(senza oggetto)' : m.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'A ${m.toAddrs} · ${formatDate(m.date)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(c, m),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      if (chosen == null) return;
      setState(() => _busy = true);
      final full = await b.loadBody(chosen);
      var sig = SignatureTools.extract(
        html: full.bodyHtml,
        text: full.bodyText,
      );
      if (sig != null) {
        // I loghi della firma si salvano dentro la firma, così partono con ogni email.
        sig = await SignatureTools.embedImages(
          sig,
          cidLookup: (cid) => b.inlineImage(chosen, cid),
        );
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (sig == null) {
          showSnack(
            context,
            'Non ho trovato una firma in questa email: provane un\'altra.',
          );
        } else {
          _setHtml(sig);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, friendlyError(e));
      }
    }
  }

  Future<void> _save() async {
    a!.signatureHtml = _current;
    await Db.i.saveAccount(a!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Firma'),
        actions: [
          TextButton(
            onPressed: a == null ? null : _save,
            child: const Text('Salva'),
          ),
        ],
      ),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                FilledButton.icon(
                  onPressed: _busy ? null : _fromSent,
                  icon: const Icon(Icons.history),
                  label: const Text('Prendi la firma da un\'email inviata'),
                ),
                const Etichetta('Firma'),
                RichToolbar(controller: _q),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(minHeight: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: kBordo),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: RichEditor(
                    controller: _q,
                    fontSize: 14.67,
                    placeholder: 'Cordiali saluti\nNome Cognome',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _addImage,
                  icon: Icon(Icons.add_photo_alternate_outlined, color: fg),
                  label: const Text('Aggiungi immagine'),
                ),
              ],
            ),
    );
  }
}

/// Mittenti bloccati dall'utente. Solo questi vanno nello spam in automatico.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});
  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  List<Map<String, Object?>> _rows = [];
  Map<int, Account> _acc = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Db.i.blockedList();
    final accs = {for (final a in await Db.i.accounts()) a.id!: a};
    if (mounted) {
      setState(() {
        _rows = r;
        _acc = accs;
      });
    }
  }

  Future<void> _add() async {
    final ctl = TextEditingController();
    final pickAcc = ValueNotifier<int?>(null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Blocca un mittente'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Indirizzo o @dominio.it',
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<int?>(
              valueListenable: pickAcc,
              builder: (_, v, __) => DropdownButton<int?>(
                iconEnabledColor: Colors.black,
                isExpanded: true,
                value: v,
                hint: const Text('In quale casella?'),
                items: [
                  const DropdownMenuItem(
                    value: 0,
                    child: Text('In tutte le caselle'),
                  ),
                  for (final a in _acc.values)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(a.name.isEmpty ? a.address : a.name),
                    ),
                ],
                onChanged: (x) => pickAcc.value = x,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Blocca'),
          ),
        ],
      ),
    );
    final s = ctl.text.trim();
    if (ok != true || s.isEmpty || pickAcc.value == null) return;
    final targets = pickAcc.value == 0 ? _acc.keys.toList() : [pickAcc.value!];
    for (final id in targets) {
      await Db.i.block(id, s);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mittenti bloccati'),
        actions: [IconButton(icon: const Icon(Icons.add), onPressed: _add)],
      ),
      body: _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                  'Nessun mittente bloccato.\nSolo chi blocchi tu finisce nello spam in automatico.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            )
          : ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, i) {
                final r = _rows[i];
                final a = _acc[r['account_id'] as int];
                return ListTile(
                  title: Text(
                    '${r['sender']}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    a == null ? '' : (a.name.isEmpty ? a.address : a.name),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      await Db.i.unblock(
                        r['account_id'] as int,
                        r['sender'] as String,
                      );
                      _load();
                    },
                    child: const Text('Sblocca'),
                  ),
                );
              },
            ),
    );
  }
}

/// Newsletter: quelle a cui sei iscritto e quelle da cui sei uscito.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  List<Map<String, Object?>> _subs = [];
  List<Map<String, Object?>> _unsubs = [];
  Map<int, Account> _acc = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final subs = await Db.i.subscriptionSenders();
    final un = await Db.i.unsubList();
    final accs = {for (final a in await Db.i.accounts()) a.id!: a};
    final gone = un.map((e) => '${e['sender']}').toSet();
    if (mounted) {
      setState(() {
        _subs = subs
            .where((s) => !gone.contains(('${s['from_addr']}').toLowerCase()))
            .toList();
        _unsubs = un;
        _acc = accs;
      });
    }
  }

  Future<void> _unsub(Map<String, Object?> s) async {
    final a = _acc[s['account_id'] as int];
    if (a == null) return;
    final d = await Db.i.db;
    final rows = await d.query(
      'messages',
      where: 'account_id=? AND from_addr=? AND list_unsub<>\'\'',
      whereArgs: [a.id, s['from_addr']],
      orderBy: 'date DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final m = Msg.fromRow(rows.first);
    String? link;
    final r = await Ops.unsubscribe(a, m, (l) => link = l);
    if (!mounted) return;
    if (r == UnsubResult.openedLink && link != null) {
      await launchUrl(Uri.parse(link!), mode: LaunchMode.externalApplication);
    }
    showSnack(
      context,
      r == UnsubResult.failed || r == UnsubResult.notAvailable
          ? 'Disiscrizione non riuscita.'
          : r == UnsubResult.openedLink
          ? 'Conferma sul sito del mittente.'
          : 'Disiscrizione inviata.',
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Abbonamenti'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Iscritto'),
              Tab(text: 'Disiscritto'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _subs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Nessuna newsletter trovata. Compaiono man mano che apri le email.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _subs.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (c, i) {
                      final s = _subs[i];
                      final a = _acc[s['account_id'] as int];
                      return ListTile(
                        title: Text(
                          ((s['from_name'] as String?) ?? '').isEmpty
                              ? '${s['from_addr']}'
                              : '${s['from_name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${s['from_addr']} · ${s['n']} email${a == null ? '' : ' · ${a.name.isEmpty ? a.address : a.name}'}',
                        ),
                        trailing: TextButton(
                          onPressed: () => _unsub(s),
                          child: const Text('Disiscriviti'),
                        ),
                      );
                    },
                  ),
            _unsubs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Nessuna disiscrizione fatta.',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _unsubs.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (c, i) {
                      final u = _unsubs[i];
                      return ListTile(
                        title: Text(
                          '${u['sender']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${formatDate(DateTime.fromMillisecondsSinceEpoch(u['at'] as int))} · ${u['method']}\nPer riscriverti si fa sul sito del mittente.',
                        ),
                        isThreeLine: true,
                        trailing: TextButton(
                          onPressed: () async {
                            await Db.i.removeUnsub(
                              u['account_id'] as int,
                              '${u['sender']}',
                            );
                            _load();
                          },
                          child: const Text('Togli dall\'elenco'),
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}

/// Stato delle notifiche: la misura vera di ritardo e consumo.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<Account> _acc = [];
  final Map<int, Map<String, Object?>?> _st = {};
  List<Map<String, Object?>> _log = [];
  bool _running = false;
  bool _nas = false;
  bool _battery = false;
  bool _perm = true;
  DateTime? _ultimoNas;
  String _verifica = 'controllo in corso…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Chiede al NAS se conosce ancora il telefono e tutte le caselle (a casa risponde).
  Future<void> _controllaNas() async {
    final r = await NasPush.verify();
    final u = await NasPush.lastAlert();
    if (mounted) {
      setState(() {
        _verifica = r;
        _ultimoNas = u;
      });
    }
  }

  static String _esito(Object? r) {
    final t = '${r ?? 'ok'}';
    if (t == 'ok') return 'notifica mostrata';
    if (t == 'silenziosa') return 'mostrata senza suono (ore silenziose)';
    if (t == 'spenta') return 'NON mostrata: notifiche spente nell\'app';
    if (t == 'casella spenta') return 'NON mostrata: avvisi spenti per questa casella';
    if (t.startsWith('ridotta')) return 'mostrata in forma semplice (${t.substring(7)})';
    if (t.startsWith('errore')) return 'NON mostrata: ${t.substring(6)}';
    if (t.startsWith('riserva')) return 'mostrata senza testo ${t.substring(7)}';
    return t;
  }

  static bool _mostrata(Object? r) {
    final t = '${r ?? 'ok'}';
    return t == 'ok' || t == 'silenziosa' || t.startsWith('ridotta');
  }

  Future<void> _load() async {
    final acc = await Db.i.accounts();
    for (final a in acc) {
      _st[a.id!] = await Db.i.status(a.id!);
    }
    final log = await Db.i.pushLog();
    final run = await PushControl.running;
    final nas = await NasPush.active;
    final bat = await PushControl.batteryOk();
    var perm = true;
    try {
      await Notify.init();
      perm = await Notify.permitted();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _perm = perm;
        _acc = acc;
        _log = log;
        _running = run;
        _nas = nas;
        _battery = bat;
      });
    }
    _controllaNas();
  }

  String _ago(Object? ms) {
    if (ms == null) return '—';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms as int),
    );
    if (d.inMinutes < 1) return 'pochi secondi fa';
    if (d.inHours < 1) return '${d.inMinutes} min fa';
    if (d.inDays < 1) return '${d.inHours} h ${d.inMinutes % 60} min fa';
    return '${d.inDays} giorni fa';
  }

  @override
  Widget build(BuildContext context) {
    // Il ritardo si misura solo sulle notifiche che sono davvero comparse.
    final vere = _log.where((r) => _mostrata(r['result'])).toList();
    final delays = vere
        .map((r) => (r['notified_at'] as int) - (r['seen_at'] as int))
        .toList();
    final totals = vere
        .map((r) => (r['notified_at'] as int) - (r['msg_date'] as int))
        .where((x) => x >= 0)
        .toList();
    String stat(List<int> l) {
      if (l.isEmpty) return 'nessuna misura ancora';
      final avg = l.reduce((a, b) => a + b) / l.length / 1000;
      final mx = l.reduce((a, b) => a > b ? a : b) / 1000;
      return 'media ${avg.toStringAsFixed(1)} s · massimo ${mx.toStringAsFixed(1)} s · ${l.length} email';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stato notifiche'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: ListView(
        children: [
          const Etichetta('Servizio'),
          ListTile(
            leading: Icon(
              _running || _nas ? Icons.check_circle : Icons.cancel,
              color: _running || _nas
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFB3261E),
            ),
            title: Text(
              _nas
                  ? 'Avvisi dal NAS'
                  : _running
                  ? 'In ascolto'
                  : 'Fermo',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              _nas
                  ? 'Il NAS resta collegato alle caselle e avvisa il telefono: nessun avviso fisso'
                  : 'Il servizio tiene aperte le connessioni alle caselle',
            ),
          ),
          if (_nas)
            ListTile(
              title: const Text(
                'Avvisi dal NAS',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                'Ultimo avviso arrivato: ${_ultimoNas == null ? 'mai' : formatDate(_ultimoNas!)}\nRegistrazione sul NAS: $_verifica',
              ),
              isThreeLine: true,
            ),
          ListTile(
            leading: Icon(
              _perm ? Icons.check_circle : Icons.cancel,
              color: _perm ? const Color(0xFF2E7D32) : const Color(0xFFB3261E),
            ),
            title: Text(
              _perm
                  ? 'Notifiche consentite da Android'
                  : 'Notifiche BLOCCATE da Android',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text(
              'Se bloccate, nessuna email suona o compare',
            ),
            trailing: _perm
                ? null
                : TextButton(
                    onPressed: () async {
                      await Notify.requestPermission();
                      _load();
                    },
                    child: const Text('Consenti'),
                  ),
          ),
          ListTile(
            leading: Icon(
              _battery ? Icons.battery_full : Icons.battery_alert,
              color: _battery
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFB3261E),
            ),
            title: Text(
              _battery
                  ? 'Risparmio batteria escluso'
                  : 'Risparmio batteria attivo su DiGiMail',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text(
              'Se è attivo, Samsung può fermare il servizio e le notifiche arrivano in ritardo',
            ),
            trailing: _battery
                ? null
                : TextButton(
                    onPressed: () async {
                      await PushControl.askBattery();
                      _load();
                    },
                    child: const Text('Escludi'),
                  ),
          ),
          Wrap(
            spacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: OutlinedButton(
                  onPressed: () async {
                    await PushControl.restart();
                    await Future<void>.delayed(const Duration(seconds: 3));
                    _load();
                  },
                  child: const Text('Riavvia il servizio'),
                ),
              ),
              OutlinedButton(
                onPressed: () => Notify.showInfo(
                  'Prova',
                  'Se vedi questo avviso, le notifiche funzionano.',
                ),
                child: const Text('Notifica di prova'),
              ),
            ],
          ),
          const Etichetta('Caselle'),
          for (final a in _acc)
            Builder(
              builder: (_) {
                final s = _st[a.id];
                final err = s?['last_error'] as String?;
                final idle = s?['idle_since'] != null;
                return ListTile(
                  leading: AccountAvatar(a, size: 40),
                  title: Text(
                    a.name.isEmpty ? a.address : a.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${idle ? 'In ascolto da ${_ago(s?['idle_since'])}' : 'Non in ascolto'}\nUltimo avviso: ${_ago(s?['last_event'])}\nUltimo controllo: ${_ago(s?['last_sync'])}${err == null ? '' : '\nErrore: $err'}',
                  ),
                  isThreeLine: true,
                );
              },
            ),
          const Etichetta('Ritardo misurato'),
          ListTile(
            title: const Text('Dall\'avviso del server alla notifica'),
            subtitle: Text(stat(delays)),
          ),
          ListTile(
            title: const Text('Dall\'invio dell\'email alla notifica'),
            subtitle: Text(stat(totals)),
          ),
          const Etichetta('Ultime email arrivate e come sono andate'),
          for (final r in _log.take(25))
            Builder(
              builder: (_) {
                final a = _acc
                    .where((x) => x.id == r['account_id'])
                    .firstOrNull;
                final d =
                    ((r['notified_at'] as int) - (r['msg_date'] as int)) / 1000;
                final ok = _mostrata(r['result']);
                return ListTile(
                  dense: true,
                  title: Text(
                    a == null ? '' : (a.name.isEmpty ? a.address : a.name),
                  ),
                  subtitle: Text(
                    '${formatDate(DateTime.fromMillisecondsSinceEpoch(r['notified_at'] as int))} · ${_esito(r['result'])}${ok ? ' · ritardo ${d < 0 ? '0' : d.toStringAsFixed(1)} s' : ''}',
                    style: TextStyle(
                      fontWeight: ok ? FontWeight.w400 : FontWeight.w800,
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
