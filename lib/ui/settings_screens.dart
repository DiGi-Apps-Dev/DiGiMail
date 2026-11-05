import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ai.dart';
import '../db.dart';
import '../full_backup.dart';
import '../mail/secrets.dart';
import '../models.dart';
import '../notify.dart';
import '../push_service.dart';
import '../settings.dart';
import '../theme.dart';
import 'account_screens.dart';
import 'add_account_screen.dart';
import 'assistant_screen.dart';
import 'rules_screen.dart';
import 'widgets.dart';

export 'account_screens.dart';

const _windowChannel = MethodChannel('dev.digiapps.digimail/window');

Future<void> applySecureFlag() async {
  try {
    await _windowChannel.invokeMethod('secure', Settings.i.hideInRecents);
  } catch (_) {}
}

Widget _nav(
  BuildContext c,
  IconData icon,
  String title,
  String subtitle,
  Widget Function() page,
) => ListTile(
  leading: Icon(icon),
  title: Text(
    title,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
  ),
  subtitle: subtitle.isEmpty ? null : Text(subtitle),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => page())),
);

/// Impostazioni dell'app.
/// Da aggiornare con `version` in pubspec.yaml: dice quale versione è sul telefono.
const kVersione = '1.0.55';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Account> _acc = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Db.i.accounts();
    if (mounted) setState(() => _acc = l);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Impostazioni')),
      body: ListView(
        children: [
          const Etichetta('Caselle'),
          for (final a in _acc)
            ListTile(
              leading: AccountAvatar(a, size: 40),
              title: Text(
                a.name.isEmpty ? a.address : a.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(a.address),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AccountSettingsScreen(accountId: a.id!),
                ),
              ).then((_) => _load()),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text(
              'Aggiungi account',
              style: TextStyle(fontSize: 18),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddAccountScreen()),
            ).then((_) => _load()),
          ),
          const Etichetta('App'),
          _nav(
            context,
            Icons.tune,
            'Generale',
            'Risposta, apertura, lettura, carattere, data e ora, tema',
            () => const GeneralSettingsScreen(),
          ),
          _nav(
            context,
            Icons.swipe,
            'Gesti e barra azioni',
            'Quattro gesti e i pulsanti sotto l\'email',
            () => const GesturesScreen(),
          ),
          _nav(
            context,
            Icons.notifications_none,
            'Notifiche',
            'Avvisi, suoni, ore silenziose, batteria',
            () => const NotificationsScreen(),
          ),
          _nav(
            context,
            Icons.lock_outline,
            'Sicurezza e privacy',
            'Blocco con impronta, immagini, tracciamento',
            () => const PrivacyScreen(),
          ),
          const Etichetta('DiGiMail'),
          _nav(
            context,
            Icons.block,
            'Mittenti bloccati',
            'Solo questi vanno nello spam in automatico',
            () => const BlockedScreen(),
          ),
          _nav(
            context,
            Icons.unsubscribe_outlined,
            'Abbonamenti',
            'Newsletter a cui sei iscritto e disiscritto',
            () => const SubscriptionsScreen(),
          ),
          _nav(
            context,
            Icons.rule,
            'Regole automatiche',
            'Sposta, archivia o segna le email da sole',
            () => const RulesScreen(),
          ),
          _nav(
            context,
            Icons.contacts_outlined,
            'Rubrica suggerita',
            'Gli indirizzi che compaiono quando scrivi',
            () => const ContactsScreen(),
          ),
          const Etichetta('Intelligenza artificiale'),
          _nav(
            context,
            Icons.auto_awesome,
            'IA con Cloudflare',
            'Riassunti, bozze, ricerca a parole tue',
            () => const AiSettingsScreen(),
          ),
          const Etichetta('Strumenti'),
          _nav(
            context,
            Icons.monitor_heart_outlined,
            'Stato notifiche',
            'Servizio, ritardo misurato, errori per casella',
            () => const DiagnosticsScreen(),
          ),
          _nav(
            context,
            Icons.backup_outlined,
            'Copia e ripristino',
            'Caselle, password, firme e impostazioni in un file',
            () => const BackupScreen(),
          ),
          const ListTile(
            title: Text('DiGiMail $kVersione'),
            subtitle: Text('Lingua: italiano'),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

Widget _sw(String title, String? sub, bool v, ValueChanged<bool> f) =>
    SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      subtitle: sub == null ? null : Text(sub),
      value: v,
      onChanged: f,
    );

class GeneralSettingsScreen extends StatefulWidget {
  const GeneralSettingsScreen({super.key});
  @override
  State<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends State<GeneralSettingsScreen> {
  List<Account> _acc = [];
  Settings get s => Settings.i;

  @override
  void initState() {
    super.initState();
    Db.i.accounts().then((l) => setState(() => _acc = l));
  }

  Widget _choice<T>(
    String title,
    String value,
    List<T> values,
    String Function(T) label,
    T current,
    void Function(T) set,
  ) => ListTile(
    title: Text(title, style: const TextStyle(fontSize: 17)),
    subtitle: Text(
      value,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    onTap: () async {
      final r = await pickOne<T>(context, title, values, label, current);
      if (r != null) setState(() => set(r));
    },
  );

  @override
  Widget build(BuildContext context) {
    final defAcc = _acc.where((a) => a.id == s.defaultAccountId).firstOrNull;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Generale')),
      body: ListView(
        children: [
          const Etichetta('Scrittura'),
          _choice<bool>(
            'Risposta predefinita',
            s.replyAllDefault ? 'Rispondi a tutti' : 'Rispondi',
            [false, true],
            (v) => v ? 'Rispondi a tutti' : 'Rispondi',
            s.replyAllDefault,
            (v) => s.replyAllDefault = v,
          ),
          _choice<int>(
            'Scrivi le nuove email da',
            defAcc == null
                ? 'Il primo account'
                : (defAcc.name.isEmpty ? defAcc.address : defAcc.name),
            [0, ..._acc.map((a) => a.id!)],
            (v) {
              if (v == 0) return 'Il primo account';
              final a = _acc.firstWhere((x) => x.id == v);
              return a.name.isEmpty ? a.address : a.name;
            },
            s.defaultAccountId,
            (v) => s.defaultAccountId = v,
          ),
          _choice<int>(
            'Tempo per annullare un\'azione e l\'invio',
            s.undoSeconds == 0
                ? 'Nessuno: invio subito'
                : '${s.undoSeconds} secondi',
            [0, 3, 5, 7, 10, 15],
            (v) => v == 0 ? 'Nessuno: invio subito' : '$v secondi',
            s.undoSeconds,
            (v) => s.undoSeconds = v,
          ),
          SwitchListTile(
            title: const Text('Suono quando l\'email è partita'),
            value: s.sendSound,
            onChanged: (v) => setState(() => s.sendSound = v),
          ),
          const Etichetta('Apertura e lettura'),
          _choice<MarkRead>(
            'Segna come letta',
            markReadLabel[s.markRead]!,
            MarkRead.values,
            (v) => markReadLabel[v]!,
            s.markRead,
            (v) => s.markRead = v,
          ),
          _sw(
            'Anteprima del testo nell\'elenco',
            'Sotto l\'oggetto compaiono le prime righe dell\'email',
            s.previewOn,
            (v) => setState(() => s.previewOn = v),
          ),
          if (s.previewOn)
            _choice<int>(
              'Righe di anteprima',
              '${s.previewLines}',
              [1, 2, 3, 4, 5, 6],
              (v) => '$v',
              s.previewLines,
              (v) => s.previewLines = v,
            ),
          _sw(
            'Iniziale del mittente nell\'elenco',
            null,
            s.showAvatars,
            (v) => setState(() => s.showAvatars = v),
          ),
          _sw(
            'DiGiMail Focus',
            'Posta in arrivo divisa fra Principali e Altro (newsletter e comunicazioni automatiche)',
            s.focusedInbox,
            (v) => setState(() => s.focusedInbox = v),
          ),
          const Etichetta('Aspetto'),
          _choice<String>(
            'Tema',
            s.themeMode == 'light'
                ? 'Chiaro'
                : s.themeMode == 'dark'
                ? 'Scuro'
                : 'Come il telefono',
            ['light', 'dark', 'system'],
            (v) => v == 'light'
                ? 'Chiaro'
                : v == 'dark'
                ? 'Scuro'
                : 'Come il telefono',
            s.themeMode,
            (v) => s.themeMode = v,
          ),
          ListTile(
            title: const Text(
              'Dimensione del carattere',
              style: TextStyle(fontSize: 17),
            ),
            subtitle: Slider(
              value: s.fontScale,
              min: 0.85,
              max: 1.5,
              divisions: 13,
              label: '${(s.fontScale * 100).round()}%',
              onChanged: (v) => setState(
                () => s.fontScale = double.parse(v.toStringAsFixed(2)),
              ),
            ),
            trailing: Text(
              '${(s.fontScale * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const Etichetta('Data e ora'),
          _choice<DateStyle>(
            'Come mostrare la data',
            dateStyleLabel[s.dateStyle]!,
            DateStyle.values,
            (v) => dateStyleLabel[v]!,
            s.dateStyle,
            (v) => s.dateStyle = v,
          ),
          _sw(
            'Ora a 24 ore',
            'Spento = 12 ore con AM/PM',
            s.use24h,
            (v) => setState(() => s.use24h = v),
          ),
          ListTile(
            title: const Text('Esempio', style: TextStyle(fontSize: 17)),
            subtitle: Text(
              '${formatDate(DateTime.now())}   ·   ${formatDate(DateTime.now().subtract(const Duration(days: 3)))}   ·   ${formatDate(DateTime(2024, 3, 14, 9, 5))}',
            ),
          ),
          const Etichetta('Rimanda'),
          _choice<int>(
            '«Domani mattina» e «Nel weekend»',
            '${s.snoozeMorningHour}:00',
            [6, 7, 8, 9, 10],
            (v) => '$v:00',
            s.snoozeMorningHour,
            (v) => s.snoozeMorningHour = v,
          ),
          _choice<int>(
            '«Questa sera»',
            '${s.snoozeEveningHour}:00',
            [17, 18, 19, 20, 21],
            (v) => '$v:00',
            s.snoozeEveningHour,
            (v) => s.snoozeEveningHour = v,
          ),
          _choice<int>(
            '«Più tardi»',
            'tra ${s.snoozeLaterHours} ore',
            [1, 2, 3, 4, 6],
            (v) => 'tra $v ore',
            s.snoozeLaterHours,
            (v) => s.snoozeLaterHours = v,
          ),
          const Etichetta('Lingua'),
          const ListTile(
            title: Text('Italiano', style: TextStyle(fontSize: 17)),
            subtitle: Text('L\'app è tutta in italiano'),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class GesturesScreen extends StatefulWidget {
  const GesturesScreen({super.key});
  @override
  State<GesturesScreen> createState() => _GesturesScreenState();
}

class _GesturesScreenState extends State<GesturesScreen> {
  Settings get s => Settings.i;
  static const _swipeActs = [
    Act.none,
    Act.delete,
    Act.toggleRead,
    Act.snooze,
    Act.flag,
    Act.spam,
    Act.move,
    Act.reply,
    Act.replyAll,
    Act.forward,
  ];
  static const _barActs = [
    Act.reply,
    Act.replyAll,
    Act.forward,
    Act.delete,
    Act.snooze,
    Act.spam,
    Act.move,
    Act.flag,
    Act.toggleRead,
    Act.block,
    Act.unsubscribe,
  ];

  Widget _g(String title, Act cur, void Function(Act) set) => ListTile(
    leading: Icon(actIcon(cur), color: actColor(cur)),
    title: Text(title, style: const TextStyle(fontSize: 17)),
    subtitle: Text(
      actLabel[cur]!,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    onTap: () async {
      final r = await pickOne<Act>(
        context,
        title,
        _swipeActs,
        (a) => actLabel[a]!,
        cur,
      );
      if (r != null) setState(() => set(r));
    },
  );

  @override
  Widget build(BuildContext context) {
    final tb = s.toolbar;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Gesti e barra azioni')),
      body: ListView(
        children: [
          const Etichetta('Scorri a destra'),
          _g('Gesto', s.swipeLongRight, (a) => s.swipeLongRight = a),
          const Etichetta('Scorri a sinistra'),
          _g('Gesto', s.swipeLongLeft, (a) => s.swipeLongLeft = a),
          const Etichetta('Barra sotto l\'email'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Trascina per cambiare l\'ordine. Massimo 6 pulsanti: gli altri restano nel menu.',
              style: TextStyle(fontSize: 15),
            ),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorder: (o, n) {
              final l = List.of(tb);
              if (n > o) n--;
              l.insert(n, l.removeAt(o));
              setState(() => s.toolbar = l);
            },
            children: [
              for (final a in tb)
                ListTile(
                  key: ValueKey(a),
                  leading: Icon(actIcon(a)),
                  title: Text(
                    actLabel[a]!,
                    style: const TextStyle(fontSize: 17),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(
                      () => s.toolbar = tb.where((x) => x != a).toList(),
                    ),
                  ),
                ),
            ],
          ),
          if (tb.length < 6)
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text(
                'Aggiungi un pulsante',
                style: TextStyle(fontSize: 17),
              ),
              onTap: () async {
                final avail = _barActs.where((a) => !tb.contains(a)).toList();
                final r = await pickOne<Act>(
                  context,
                  'Aggiungi',
                  avail,
                  (a) => actLabel[a]!,
                  avail.first,
                );
                if (r != null) setState(() => s.toolbar = [...tb, r]);
              },
            ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

const _detailLabel = [
  'Solo il mittente',
  'Mittente e oggetto',
  'Mittente, oggetto e inizio del testo',
  'Mittente, oggetto e testo lungo',
];

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Account> _acc = [];
  bool _battery = true;
  Settings get s => Settings.i;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Db.i.accounts();
    final b = await PushControl.batteryOk();
    if (mounted) {
      setState(() {
        _acc = l;
        _battery = b;
      });
    }
  }

  Future<void> _pickQuiet() async {
    final from = await showTimePicker(
      context: context,
      helpText: 'Silenzio DA',
      initialTime: const TimeOfDay(hour: 22, minute: 0),
    );
    if (from == null || !mounted) return;
    final to = await showTimePicker(
      context: context,
      helpText: 'Silenzio FINO A',
      initialTime: const TimeOfDay(hour: 7, minute: 0),
    );
    if (to == null) return;
    setState(() => s.quietHours = '${from.hour}-${to.hour}');
  }

  @override
  Widget build(BuildContext context) {
    final q = s.quietHours;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Notifiche')),
      body: ListView(
        children: [
          const Etichetta('Avvisi'),
          _sw('Notifiche attive', null, s.notifyEnabled, (v) async {
            setState(() => s.notifyEnabled = v);
            if (v) await Notify.requestPermission();
          }),
          _sw(
            'Avvisi in tempo reale',
            'L\'app resta collegata alle caselle e avvisa appena arriva un\'email, con un\'icona fissa nella tendina. Spento = controllo ogni tot minuti, scelto per ogni casella.',
            s.pushService,
            (v) async {
              setState(() => s.pushService = v);
              await PushControl.syncWithSettings();
            },
          ),
          ListTile(
            title: const Text(
              'Cosa mostra la notifica',
              style: TextStyle(fontSize: 17),
            ),
            subtitle: Text(
              _detailLabel[s.notifyDetail],
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            onTap: () async {
              final r = await pickOne<int>(
                context,
                'Cosa mostra la notifica',
                [0, 1, 2, 3],
                (v) => _detailLabel[v],
                s.notifyDetail,
              );
              if (r != null) setState(() => s.notifyDetail = r);
            },
          ),
          _sw(
            'Nascondi il contenuto sulla schermata di blocco',
            'Sul blocco schermo compare solo «Nuova email». L\'ultima parola è dell\'impostazione di Android.',
            s.notifyHideOnLock,
            (v) => setState(() => s.notifyHideOnLock = v),
          ),
          _sw(
            'Mostra il nome del mittente',
            null,
            s.notifyShowSender,
            (v) => setState(() => s.notifyShowSender = v),
          ),
          _sw(
            'Mostra l\'anteprima del testo',
            null,
            s.notifyShowPreview,
            (v) => setState(() => s.notifyShowPreview = v),
          ),
          _sw(
            'Numero sull\'icona',
            null,
            s.badgeCount,
            (v) {
              setState(() => s.badgeCount = v);
              Notify.updateIconBadge();
            },
          ),
          ListTile(
            title: const Text('Ore silenziose', style: TextStyle(fontSize: 17)),
            subtitle: Text(
              q.isEmpty
                  ? 'Nessuna'
                  : 'Dalle ${q.split('-')[0]}:00 alle ${q.split('-')[1]}:00',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            trailing: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => s.quietHours = ''),
                  ),
            onTap: _pickQuiet,
          ),
          const Etichetta('Per casella'),
          for (final a in _acc)
            ListTile(
              leading: AccountAvatar(a, size: 40),
              title: Text(
                a.name.isEmpty ? a.address : a.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text('Tocca per scegliere suono e vibrazione'),
              trailing: Switch(
                value: a.notify,
                onChanged: (v) async {
                  a.notify = v;
                  await Db.i.saveAccount(a);
                  setState(() {});
                },
              ),
              onTap: () => Notify.openChannelSettings(a),
            ),
          const Etichetta('Batteria'),
          ListTile(
            leading: Icon(
              _battery ? Icons.check_circle : Icons.warning_amber_rounded,
              color: _battery
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFB3261E),
            ),
            title: Text(
              _battery
                  ? 'DiGiMail è esclusa dal risparmio batteria'
                  : 'Il risparmio batteria può fermare le notifiche',
              style: const TextStyle(fontWeight: FontWeight.w800),
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
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});
  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  Settings get s => Settings.i;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Sicurezza e privacy')),
      body: ListView(
        children: [
          const Etichetta('Blocco dell\'app'),
          _sw(
            'Sblocca con impronta o PIN del telefono',
            null,
            s.appLock,
            (v) => setState(() => s.appLock = v),
          ),
          if (s.appLock)
            ListTile(
              title: const Text(
                'Richiedi lo sblocco',
                style: TextStyle(fontSize: 17),
              ),
              subtitle: Text(
                s.lockDelaySeconds == 0
                    ? 'Ogni volta che apri DiGiMail'
                    : 'Dopo ${s.lockDelaySeconds >= 60 ? '${s.lockDelaySeconds ~/ 60} min' : '${s.lockDelaySeconds} s'} fuori dall\'app',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () async {
                final r = await pickOne<int>(
                  context,
                  'Richiedi lo sblocco',
                  [0, 30, 60, 300],
                  (v) => v == 0
                      ? 'Ogni volta'
                      : v < 60
                      ? 'Dopo $v secondi'
                      : 'Dopo ${v ~/ 60} minuti',
                  s.lockDelaySeconds,
                );
                if (r != null) setState(() => s.lockDelaySeconds = r);
              },
            ),
          _sw(
            'Nascondi DiGiMail dalle app recenti',
            'Lo schermo diventa vuoto e non si può fotografare',
            s.hideInRecents,
            (v) async {
              setState(() => s.hideInRecents = v);
              await applySecureFlag();
            },
          ),
          const Etichetta('Email'),
          _sw(
            'Blocca il tracciamento',
            'Toglie i pixel spia che dicono al mittente che hai aperto l\'email',
            s.blockTracking,
            (v) => setState(() => s.blockTracking = v),
          ),
          _sw(
            'Blocca le immagini delle email',
            'Le immagini si caricano solo se tocchi «Mostra le immagini» nell\'email',
            s.blockRemoteImages,
            (v) => setState(() => s.blockRemoteImages = v),
          ),
          _sw(
            'Avvisa dei mittenti sospetti',
            'Se il server segnala che il mittente non è autentico',
            s.warnSuspicious,
            (v) => setState(() => s.warnSuspicious = v),
          ),
          const Etichetta('I tuoi dati'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Le email restano sul telefono e le password nella memoria cifrata di Android. DiGiMail non ha un server suo e non manda statistiche a nessuno. Un\'eccezione: quando tocchi un tasto IA il testo dell\'email va a Cloudflare, con la tua chiave.',
              style: TextStyle(fontSize: 16, height: 1.35),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(
              Icons.delete_sweep_outlined,
              color: Color(0xFFB3261E),
            ),
            title: const Text(
              'Cancella le email scaricate sul telefono',
              style: TextStyle(
                color: Color(0xFFB3261E),
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: const Text('Restano sui server e si riscaricano'),
            onTap: () async {
              if (!await confirm(
                context,
                'Cancellare la copia sul telefono?',
                'Le email non vengono toccate sul server.',
                yes: 'Cancella',
              ))
                return;
              await Db.i.wipeCache();
              if (context.mounted)
                showSnack(context, 'Copia locale cancellata');
            },
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _account = TextEditingController(text: Settings.i.aiAccountId);
  final _token = TextEditingController();
  final _model = TextEditingController(text: Settings.i.aiModel);
  final _lang = TextEditingController(text: Settings.i.aiLanguage);
  final _tone = TextEditingController(text: Settings.i.aiTone);
  bool _hasToken = false;
  String? _test;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Secrets.aiToken().then(
      (t) => setState(() => _hasToken = t != null && t.isNotEmpty),
    );
  }

  Future<void> _save() async {
    final s = Settings.i;
    s.aiAccountId = _account.text.trim();
    s.aiModel = _model.text.trim().isEmpty
        ? '@cf/openai/gpt-oss-120b'
        : _model.text.trim();
    s.aiLanguage = _lang.text.trim().isEmpty ? 'italiano' : _lang.text.trim();
    s.aiTone = _tone.text.trim().isEmpty
        ? 'cordiale e chiaro'
        : _tone.text.trim();
    if (_token.text.trim().isNotEmpty) {
      await Secrets.setAiToken(_token.text.trim());
      _token.clear();
      _hasToken = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _try() async {
    await _save();
    setState(() {
      _busy = true;
      _test = null;
    });
    try {
      final r = await Ai.chat(
        'Rispondi solo con la parola: ok',
        'Test',
        maxTokens: 20,
      );
      _test = 'Funziona. Risposta: $r';
    } catch (e) {
      _test = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('IA con Cloudflare')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'L\'IA parte solo quando tocchi un tasto (Riassumi, Rispondi con IA, Scrivi con IA, Cerca con IA). Il testo di quell\'email va a Cloudflare Workers AI con la tua chiave, che non è nel programma ma solo nella memoria cifrata del telefono.',
            style: TextStyle(fontSize: 16, height: 1.35),
          ),
          const Etichetta('Collegamento'),
          TextField(
            controller: _account,
            decoration: const InputDecoration(
              labelText: 'ID account Cloudflare',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _hasToken
                  ? 'Chiave salvata (scrivine una nuova per cambiarla)'
                  : 'Chiave API Cloudflare (permesso Workers AI)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: 'Modello'),
          ),
          const Etichetta('Come scrive'),
          TextField(
            controller: _lang,
            decoration: const InputDecoration(
              labelText: 'Lingua delle risposte',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tone,
            decoration: const InputDecoration(labelText: 'Tono delle bozze'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Salva'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _try,
                  child: Text(_busy ? 'Provo…' : 'Salva e prova'),
                ),
              ),
            ],
          ),
          if (_test != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _test!,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

/// Chiede la parola della copia completa; con [twice] la fa scrivere due volte.
Future<String?> _askWord(BuildContext context, {required bool twice}) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(twice ? 'Scegli una parola' : 'Parola della copia'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (twice)
              const Text(
                'Serve per riaprire la copia. Senza questa parola il file non si apre: scrivila da qualche parte.',
                style: TextStyle(fontSize: 16, height: 1.35),
              ),
            TextField(
              controller: a,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Parola'),
            ),
            if (twice)
              TextField(
                controller: b,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Ripeti la parola'),
              ),
            if (err != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  err!,
                  style: const TextStyle(
                    color: Color(0xFFB3261E),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () {
              if (a.text.length < 8) {
                set(() => err = 'Almeno 8 caratteri.');
              } else if (twice && a.text != b.text) {
                set(() => err = 'Le due parole non sono uguali.');
              } else {
                Navigator.pop(c, a.text);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
}

Uint8List _sealJob(List<Object?> x) =>
    FullBackup.seal(x[0] as Map<String, Object?>, x[1] as String);
Map<String, dynamic> _openJob(List<Object?> x) =>
    FullBackup.open(x[0] as Uint8List, x[1] as String);

class _BackupScreenState extends State<BackupScreen> {
  final _ctl = TextEditingController();
  String? _msg;
  String? _fullMsg;
  bool _busy = false;

  Future<void> _saveFull() async {
    final word = await _askWord(context, twice: true);
    if (word == null) return;
    setState(() {
      _busy = true;
      _fullMsg = null;
    });
    try {
      final data = await FullBackup.collect();
      final bytes = await compute(_sealJob, [data, word]);
      final now = DateTime.now();
      final name =
          'digimail-copia-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.digimail';
      final f = File('${(await getTemporaryDirectory()).path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      final n = (data['caselle'] as List).length;
      setState(() => _fullMsg = 'Copia pronta: $n caselle. Scegli dove salvarla (per esempio Drive).');
      await SharePlus.instance.share(
        ShareParams(files: [XFile(f.path)], subject: 'Copia completa di DiGiMail'),
      );
    } catch (e) {
      setState(() => _fullMsg = 'Copia non riuscita: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFull() async {
    final r = await FilePicker.pickFiles();
    final path = r?.paths.firstOrNull;
    if (path == null || !mounted) return;
    final word = await _askWord(context, twice: false);
    if (word == null || !mounted) return;
    setState(() {
      _busy = true;
      _fullMsg = null;
    });
    try {
      final data = await compute(_openJob, [await File(path).readAsBytes(), word]);
      final addrs = [
        for (final c in (data['caselle'] as List).cast<Map>())
          (c['riga'] as Map)['address'],
      ];
      if (!mounted) return;
      final ok = await confirm(
        context,
        'Ripristino',
        'Rimetto ${addrs.length} caselle con password, firme e impostazioni:\n\n${addrs.join('\n')}\n\nLe caselle che ci sono già si aggiornano.',
        yes: 'Ripristina',
      );
      if (!ok) return;
      final n = await FullBackup.restore(data);
      await PushControl.restart();
      setState(() => _fullMsg = 'Ripristinate $n caselle.');
    } on FormatException catch (e) {
      setState(
        () => _fullMsg = e.message == 'parola sbagliata'
            ? 'La parola non è giusta.'
            : 'Questo file non è una copia di DiGiMail.',
      );
    } catch (e) {
      setState(() => _fullMsg = 'Ripristino non riuscito: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Copia e ripristino')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Etichetta('Copia completa'),
          const Text(
            'Un file solo con tutte le caselle e le loro password, le firme, i loghi, le impostazioni, le regole, i mittenti bloccati e la rubrica. È cifrato con una parola che scegli tu. Su un telefono nuovo: installa DiGiMail, apri qui e premi «Ripristina da una copia».',
            style: TextStyle(fontSize: 16, height: 1.35),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _saveFull,
            icon: const Icon(Icons.save_alt),
            label: const Text('Salva copia completa'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _restoreFull,
            icon: const Icon(Icons.restore),
            label: const Text('Ripristina da una copia'),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_fullMsg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _fullMsg!,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          const Etichetta('Solo le impostazioni'),
          const Text(
            'Le impostazioni (gesti, barra, carattere, notifiche...) come testo da copiare. Password e caselle non sono incluse: per quelle serve la copia completa.',
            style: TextStyle(fontSize: 16, height: 1.35),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final text = const JsonEncoder.withIndent(
                '  ',
              ).convert(Settings.i.export());
              await SharePlus.instance.share(
                ShareParams(text: text, subject: 'Impostazioni di DiGiMail'),
              );
            },
            icon: const Icon(Icons.ios_share),
            label: const Text('Esporta le impostazioni'),
          ),
          const Etichetta('Ripristina'),
          TextField(
            controller: _ctl,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: 'Incolla qui il testo esportato',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () async {
              try {
                final m = jsonDecode(_ctl.text) as Map<String, dynamic>;
                // Regole e scelte per casella portano i numeri delle caselle dell'altro telefono:
                // qui finirebbero sulla casella sbagliata. Le porta la copia completa.
                final perCasella = RegExp(
                  r'^(syncMode|syncMin|syncWifi|syncDays|folderOrder)_\d+$',
                );
                await Settings.i.import({
                  for (final e in m.entries)
                    if (!perCasella.hasMatch(e.key) &&
                        e.key != 'rules' &&
                        e.key != 'defaultAccountId' &&
                        e.key != 'lastAccountId')
                      e.key: e.value,
                });
                setState(() => _msg = 'Impostazioni ripristinate.');
              } catch (_) {
                setState(() => _msg = 'Il testo non è valido.');
              }
            },
            child: const Text('Ripristina'),
          ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _msg!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }
}
