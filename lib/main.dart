import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:local_auth/local_auth.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart';
import 'models.dart';
import 'ops.dart';
import 'notify.dart';
import 'push_service.dart';
import 'settings.dart';
import 'theme.dart';
import 'ui/add_account_screen.dart';
import 'ui/compose_screen.dart';
import 'ui/mailbox_screen.dart';
import 'ui/scheduled_screen.dart';
import 'nas_push.dart';
import 'ui/message_screen.dart';
import 'ui/pickers.dart';
import 'ui/settings_screens.dart';

/// Sostituisce l'elenco aperto: uno sopra l'altro raddoppiavano connessioni e aggiornamenti.
void _apriCasella(NavigatorState nav, Account a) {
  nav.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => MailboxScreen(account: a)),
    (_) => false,
  );
}

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('it');
  Backends.factory = (a) => ImapBackend(a);
  await Settings.i.load();
  await Notify.init();
  PushControl.init();
  await NasPush.init();
  // A casa si controlla a ogni apertura che il NAS conosca ancora il telefono; fuori casa non risponde.
  unawaited(NasPush.verify());
  await applySecureFlag();
  runApp(const DiGiMailApp());
}

class DiGiMailApp extends StatefulWidget {
  const DiGiMailApp({super.key});
  @override
  State<DiGiMailApp> createState() => _DiGiMailAppState();
}

class _DiGiMailAppState extends State<DiGiMailApp> with WidgetsBindingObserver {
  StreamSubscription<String>? _tapSub;
  bool _locked = false;
  DateTime? _leftAt;
  bool _authenticating = false;
  // Una notifica toccata mentre l'app è bloccata si apre solo dopo lo sblocco.
  String? _payloadInAttesa;
  Map? _mailtoInAttesa;
  static const _win = MethodChannel('dev.digiapps.digimail/window');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Settings.i.addListener(_changed);
    Notify.foreground = true;
    _locked = Settings.i.appLock;
    _tapSub = Notify.taps.stream.listen(_openFromNotification);
    // Un link «mailto:» toccato in un'altra app apre Scrivi con i destinatari già messi.
    _win.setMethodCallHandler((c) async {
      if (c.method == 'mailto' && c.arguments is Map) _apriMailto(c.arguments as Map);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final m = await _win.invokeMethod<Map>('mailtoIniziale');
        if (m != null) _apriMailto(m);
      } catch (_) {}
      final d = await Notify.plugin.getNotificationAppLaunchDetails();
      final p = d?.notificationResponse?.payload;
      if (d?.didNotificationLaunchApp == true && p != null)
        _openFromNotification(p);
      if (_locked) _unlock();
      if (Settings.i.notifyEnabled) await Notify.requestPermission();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Settings.i.removeListener(_changed);
    _tapSub?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Notify.foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final s = Settings.i;
      if (s.appLock && _leftAt != null && !_authenticating) {
        if (DateTime.now().difference(_leftAt!).inSeconds >=
            s.lockDelaySeconds) {
          setState(() => _locked = true);
          _unlock();
        }
      }
      _leftAt = null;
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    _authenticating = true;
    try {
      final auth = LocalAuthentication();
      // Se il telefono non ha nessun blocco schermo non si può chiedere niente: non si
      // chiude fuori l'utente. Con un blocco, qualunque errore (troppi tentativi, annullato)
      // lascia l'app chiusa.
      if (!await auth.isDeviceSupported()) {
        if (mounted) setState(() => _locked = false);
      } else {
        final ok = await auth.authenticate(localizedReason: 'Sblocca DiGiMail');
        if (ok && mounted) setState(() => _locked = false);
      }
    } catch (_) {}
    _authenticating = false;
    final p = _payloadInAttesa;
    if (!_locked && p != null) {
      _payloadInAttesa = null;
      _openFromNotification(p);
    }
    final mt = _mailtoInAttesa;
    if (!_locked && mt != null) {
      _mailtoInAttesa = null;
      _apriMailto(mt);
    }
  }

  /// Apre Scrivi con destinatari, oggetto e testo di un link «mailto:».
  void _apriMailto(Map m) {
    if (_locked) {
      _mailtoInAttesa = m;
      return;
    }
    final init = mailtoInit(m);
    navKey.currentState?.push(
      MaterialPageRoute(builder: (_) => ComposeScreen(init: init)),
    );
  }

  Future<void> _openFromNotification(String payload) async {
    try {
      final esito = await _apriDaNotifica(payload);
      Notify.logTap(payload, esito);
    } catch (e) {
      Notify.logTap(payload, 'errore ${e.runtimeType}: $e');
    }
  }

  /// Apre quello che la notifica indica e dice cosa ha aperto (per «Stato notifiche»).
  Future<String> _apriDaNotifica(String payload) async {
    if (_locked) {
      _payloadInAttesa = payload;
      return 'app bloccata, si apre dopo lo sblocco';
    }
    if (payload == 'scheduled') {
      navKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const ScheduledScreen()),
      );
      return 'aperti i Programmati';
    }
    final parts = payload.split('|');
    if (parts.length < 3) return 'NON aperto: notifica senza indirizzo ($payload)';
    final id = int.tryParse(parts[0]);
    final uid = int.tryParse(parts[2]);
    if (id == null) return 'NON aperto: casella illeggibile ($payload)';
    final a = await Db.i.account(id);
    final nav = navKey.currentState;
    if (a == null) return 'NON aperto: casella $id non trovata';
    if (nav == null) return 'NON aperto: schermata non pronta';
    if (uid == null || uid == 0) {
      _apriCasella(nav, a);
      return 'aperta la casella (notifica di gruppo)';
    }
    final m = await Db.i.message(id, parts[1], uid);
    if (m == null) {
      _apriCasella(nav, a);
      return 'aperta la casella: email ${parts[1]} $uid non ancora nel telefono';
    }
    final folders = await loadFolders(a);
    nav.push(
      MaterialPageRoute(
        builder: (_) => MessageScreen(account: a, msg: m, folders: folders),
      ),
    );
    return 'aperta l\'email';
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.i;
    final mode = s.themeMode == 'dark'
        ? ThemeMode.dark
        : s.themeMode == 'system'
        ? ThemeMode.system
        : ThemeMode.light;
    return MaterialApp(
      navigatorKey: navKey,
      title: 'DiGiMail',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(dark: false),
      darkTheme: buildTheme(dark: true),
      themeMode: mode,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(s.fontScale)),
          // Il blocco sta sopra a tutto, anche alle schermate già aperte: tolto l'accesso
          // a quello che c'è sotto finché non si sblocca.
          child: Stack(
            children: [
              Positioned.fill(
                child: ExcludeSemantics(
                  excluding: _locked,
                  child: IgnorePointer(
                    ignoring: _locked,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
              if (_locked)
                Positioned.fill(child: _LockScreen(onUnlock: _unlock)),
            ],
          ),
        );
      },
      home: const _Start(),
    );
  }
}

/// All'apertura va dritto nella Posta in arrivo dell'account principale
/// (scelto in Impostazioni > Generale, altrimenti il primo dell'elenco).
/// Senza account mostra la schermata per aggiungerne uno.
class _Start extends StatefulWidget {
  const _Start();
  @override
  State<_Start> createState() => _StartState();
}

class _StartState extends State<_Start> with WidgetsBindingObserver {
  Account? _acc;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load().then((_) => PushControl.syncWithSettings());
    Notify.updateIconBadge();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Settings.i.reload();
      Ops.processScheduled();
      // Se non era ancora registrato sul NAS (fuori casa), riprova adesso.
      PushControl.syncWithSettings();
    }
  }

  Future<void> _load() async {
    Account? pick;
    try {
      final list = await Db.i.accounts();
      final def = Settings.i.defaultAccountId;
      pick = list.where((a) => a.id == def).firstOrNull ?? list.firstOrNull;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _acc = pick;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: SizedBox.shrink());
    final a = _acc;
    if (a == null) return AddAccountScreen(onDone: _load);
    return MailboxScreen(key: ValueKey(a.id), account: a);
  }
}

/// Dal link «mailto:» (e dai dati extra che manda Android) ai campi di Scrivi.
ComposeInit mailtoInit(Map m) {
  final u = Uri.tryParse('${m['uri'] ?? ''}');
  List<String> split(String s) => s
      .split(RegExp(r'[,;]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  List<String> extra(Object? v) => v is List ? [for (final e in v) '$e'] : <String>[];
  String path = '';
  try {
    path = u == null ? '' : Uri.decodeComponent(u.path);
  } catch (_) {}
  final q = u?.queryParameters ?? const <String, String>{};
  List<String> uniq(List<String> l) {
    final seen = <String>{};
    return [for (final a in l) if (seen.add(a.toLowerCase())) a];
  }
  final def = Settings.i.defaultAccountId;
  return ComposeInit(
    accountId: def == 0 ? null : def,
    to: uniq([...split(path), ...split(q['to'] ?? ''), ...extra(m['to'])]),
    cc: uniq([...split(q['cc'] ?? ''), ...extra(m['cc'])]),
    bcc: uniq([...split(q['bcc'] ?? ''), ...extra(m['bcc'])]),
    subject: q['subject'] ?? (m['subject'] as String?) ?? '',
    body: q['body'] ?? (m['body'] as String?) ?? '',
  );
}

class _LockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  const _LockScreen({required this.onUnlock});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 72),
            const SizedBox(height: 16),
            const Text(
              'DiGiMail è bloccata',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Sblocca'),
            ),
          ],
        ),
      ),
    );
  }
}
