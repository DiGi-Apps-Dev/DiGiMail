import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db.dart';
import '../mail/imap_backend.dart';
import '../mail/ms_oauth.dart';
import '../mail/secrets.dart';
import '../mail/servers.dart';
import '../models.dart';
import '../ops.dart';
import '../push_service.dart';
import '../settings.dart';
import '../theme.dart';
import 'settings_screens.dart';
import 'widgets.dart';

/// Aggiunta di una casella: rileva i server dall'indirizzo, chiede solo
/// quello che serve e verifica l'accesso prima di salvare.
class AddAccountScreen extends StatefulWidget {
  final String? address;

  /// Solo per il primo account, quando questa è la schermata d'avvio.
  final VoidCallback? onDone;
  const AddAccountScreen({super.key, this.address, this.onDone});
  @override
  State<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  final _sender = TextEditingController();
  final _password = TextEditingController();
  final _login = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  final _msClient = TextEditingController();
  bool _imapSsl = true;
  bool _smtpSsl = true;
  ServerGuess? _guess;
  bool _detecting = false;
  bool _busy = false;
  String? _error;
  int _color = kColori.first;
  String? _msToken;
  DeviceCode? _code;
  bool _passwordShown = false;

  @override
  void initState() {
    super.initState();
    _msClient.text = Settings.i.msClientId;
    if (widget.address != null) {
      _address.text = widget.address!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _detect());
    }
  }

  @override
  void dispose() {
    _auth?.annulla();
    for (final c in [
      _address,
      _name,
      _sender,
      _password,
      _login,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
      _msClient,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _validAddress =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_address.text.trim());

  String? _guessAddr;

  Future<void> _detect() async {
    if (!_validAddress) {
      setState(() => _error = 'Scrivi un indirizzo email valido.');
      return;
    }
    setState(() {
      _detecting = true;
      _error = null;
    });
    final addr = _address.text.trim();
    final g = await detectServers(addr);
    if (!mounted) return;
    setState(() {
      _guess = g;
      _guessAddr = addr;
      _detecting = false;
      _imapHost.text = g.imapHost;
      _imapPort.text = '${g.imapPort}';
      _imapSsl = g.imapSsl;
      _smtpHost.text = g.smtpHost;
      _smtpPort.text = '${g.smtpPort}';
      _smtpSsl = g.smtpSsl;
      _color = colorFor(addr);
      if (_name.text.isEmpty) {
        final local = addr.split('@').first;
        final dom = addr.split('@').last.split('.').first;
        _name.text = g.kind == AccountKind.other
            ? _cap(dom)
            : _cap(
                g.kind.name == 'gmail'
                    ? 'Gmail $local'
                    : '${_cap(g.kind.name)} $local',
              );
      }
    });
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Uscendo dalla schermata l'attesa dell'accesso si ferma, non continua per 15 minuti.
  MsOAuth? _auth;

  Future<void> _microsoftLogin() async {
    final id = _msClient.text.trim();
    if (id.isEmpty) {
      setState(
        () => _error =
            'Per Outlook serve l\'ID applicazione Microsoft: vedi le istruzioni qui sotto.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = _auth = MsOAuth(id);
      final code = await auth.start();
      if (!mounted) return;
      setState(() => _code = code);
      await Clipboard.setData(ClipboardData(text: code.userCode));
      await launchUrl(
        Uri.parse(code.verificationUri),
        mode: LaunchMode.externalApplication,
      );
      final token = await auth.waitForToken(code);
      // Solo a accesso riuscito: un ID sbagliato restava salvato.
      Settings.i.msClientId = id;
      if (!mounted) return;
      setState(() {
        _msToken = token;
        _code = null;
      });
    } on MsAccessoAnnullato {
      return;
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final g = _guess;
    if (g == null) return;
    // Indirizzo corretto dopo la ricerca: le impostazioni trovate erano per quello di prima.
    if (_address.text.trim() != _guessAddr) {
      setState(() {
        _guess = null;
        _error = 'Hai cambiato l\'indirizzo: cerco di nuovo i server.';
      });
      await _detect();
      return;
    }
    final oauth = g.oauthMicrosoft;
    if (oauth && _msToken == null) {
      setState(() => _error = 'Fai prima l\'accesso con Microsoft.');
      return;
    }
    if (!oauth && _password.text.isEmpty) {
      setState(
        () => _error =
            'Inserisci la password${g.needsAppPassword ? ' per app' : ''}.',
      );
      return;
    }
    final acc0 = Account(
      address: _address.text.trim(),
      name: _name.text.trim(),
      senderName: _sender.text.trim(),
      color: _color,
      kind: g.kind,
      imapHost: _imapHost.text.trim(),
      imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
      imapSsl: _imapSsl,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 465,
      smtpSsl: _smtpSsl,
      authType: oauth ? 'oauth_ms' : 'password',
      loginName: _login.text.trim(),
      saveSent: g.saveSent,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    var acc = acc0;
    try {
      acc = await verifyAccountAuto(
        acc0,
        password: _password.text,
        msTokenJson: _msToken,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(e);
        });
      }
      return;
    }
    final uscita = await provaUscita(acc, password: oauth ? null : _password.text.trim());
    final id = await Db.i.saveAccount(acc);
    if (oauth) {
      await Secrets.setMsToken(id, _msToken!);
    } else {
      await Secrets.setPassword(id, _password.text.trim());
    }
    if (Settings.i.defaultAccountId == 0) Settings.i.defaultAccountId = id;
    try {
      await Ops.refresh(acc, notify: false);
    } catch (_) {}
    // La casella nuova entra subito nel controllo in tempo reale e sul NAS.
    try {
      await PushControl.restart();
    } catch (_) {}
    if (!mounted) return;
    if (uscita != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(
            'Casella aggiunta, ma la posta in uscita non ha risposto: controlla il server SMTP prima di inviare. ($uscita)',
          ),
        ),
      );
    }
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.pop(context, true);
    }
  }

  Widget _num(TextEditingController c, String label) => SizedBox(
    width: 90,
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final g = _guess;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Aggiungi account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Etichetta('Indirizzo'),
          TextField(
            controller: _address,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Indirizzo email',
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _detecting ? null : _detect,
              ),
            ),
            onSubmitted: (_) => _detect(),
          ),
          if (widget.onDone != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.restore),
                label: const Text('Ripristina da una copia'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BackupScreen()),
                  );
                  if ((await Db.i.accounts()).isNotEmpty) widget.onDone!();
                },
              ),
            ),
          if (_detecting)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          if (g != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                g.note,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Etichetta('Nome e logo'),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nome della casella (lo scegli tu)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _sender,
              decoration: const InputDecoration(
                labelText: 'Nome che vede chi riceve (facoltativo)',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in kColori)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: Color(c),
                      child: _color == c
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
            const Etichetta('Accesso'),
            if (g.oauthMicrosoft) ...[
              if (_msToken != null)
                const ListTile(
                  leading: Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
                  title: Text(
                    'Accesso Microsoft riuscito',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              else ...[
                if (_code != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: kBordo),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Nel sito Microsoft inserisci questo codice (già copiato):',
                          style: TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          _code!.userCode,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Poi torna qui: l\'app va avanti da sola.',
                          style: TextStyle(fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _msClient,
                  decoration: const InputDecoration(
                    labelText: 'ID applicazione Microsoft (una volta sola)',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _microsoftLogin,
                  icon: const Icon(Icons.login),
                  label: const Text('Accedi con Microsoft'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Una tantum, sul sito entra.microsoft.com: Applicazioni > Registrazioni app > Nuova registrazione. Tipi di account: «Account in qualsiasi directory organizzativa e account Microsoft personali». In Autenticazione attiva «Consenti flussi client pubblici». In Autorizzazioni API aggiungi Office 365 Exchange Online > IMAP.AccessAsUser.All e SMTP.Send. Copia l\'«ID applicazione (client)» qui sopra.',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ] else ...[
              if (g.needsAppPassword && g.appPasswordUrl != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(g.appPasswordUrl!),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Crea la password per app'),
                  ),
                ),
              TextField(
                controller: _password,
                obscureText: !_passwordShown,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: g.needsAppPassword
                      ? 'Password per app'
                      : 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _passwordShown ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _passwordShown = !_passwordShown),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _login,
                decoration: const InputDecoration(
                  labelText:
                      'Nome utente, se diverso dall\'indirizzo (facoltativo)',
                ),
              ),
            ],
            const Etichetta('Server'),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _imapHost,
                    decoration: const InputDecoration(
                      labelText: 'Posta in arrivo (IMAP)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _num(_imapPort, 'Porta'),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Connessione cifrata diretta (SSL/TLS)'),
              subtitle: const Text('Spento = STARTTLS'),
              value: _imapSsl,
              onChanged: (v) => setState(() => _imapSsl = v),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _smtpHost,
                    decoration: const InputDecoration(
                      labelText: 'Posta in uscita (SMTP)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _num(_smtpPort, 'Porta'),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Connessione cifrata diretta (SSL/TLS)'),
              subtitle: const Text('Spento = STARTTLS'),
              value: _smtpSsl,
              onChanged: (v) => setState(() => _smtpSsl = v),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFB3261E),
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (g != null)
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Verifica e aggiungi',
                      style: TextStyle(fontSize: 18),
                    ),
            ),
        ],
      ),
    );
  }
}
