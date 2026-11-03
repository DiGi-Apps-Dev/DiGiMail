import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart';
import 'models.dart';
import 'nas_push.dart';
import 'notify.dart';
import 'notify_pending.dart';
import 'ops.dart';
import 'settings.dart';

/// Punto d'ingresso del servizio in primo piano (gira in un processo a parte).
@pragma('vm:entry-point')
void pushStartCallback() {
  FlutterForegroundTask.setTaskHandler(PushHandler());
}

/// Tiene aperta una connessione IMAP «IDLE» per ogni casella e avvisa subito
/// quando arriva una email. Ogni minuto invia i messaggi in coda; ogni 5 controlla che le connessioni siano
/// vive, fa un controllo di sicurezza, invia i messaggi programmati e fa
/// ricomparire quelli rimandati.
class PushHandler extends TaskHandler {
  final Set<int> _busy = {};
  final Set<int> _again = {};
  bool _starting = false;
  bool _ticking = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    Backends.factory = (a) => ImapBackend(a);
    await Settings.i.load();
    await Notify.init();
    await _startAll();
  }

  Future<void> _startAll() async {
    if (_starting) return;
    _starting = true;
    try {
      final accounts = await Db.i.accounts();
      var ok = 0;
      for (final a in accounts) {
        if (await _wanted(a) && await _listen(a)) ok++;
      }
      await _updateText(ok, accounts.length);
    } finally {
      _starting = false;
    }
  }

  /// Vero se questa casella deve tenere la connessione aperta adesso.
  Future<bool> _wanted(Account a) async {
    final s = Settings.i;
    if (s.syncMode(a.id!) != 'push') return false;
    if (s.syncWifiOnly(a.id!) && !await PushControl.onWifi()) return false;
    // Le caselle che segue già il NAS non hanno bisogno di una seconda connessione.
    if (await NasPush.covers(a)) return false;
    return true;
  }

  Future<bool> _listen(Account a) async {
    try {
      final b = Backends.of(a);
      await b.startListening(
        (folder) => _onNew(a, folder),
        (err) => Db.i.setStatus(a.id!, error: '$err'),
      );
      await Db.i.setStatus(
        a.id!,
        idleSince: DateTime.now().millisecondsSinceEpoch,
        clearError: true,
      );
      await checkNewMail(a);
      return true;
    } catch (e) {
      await Db.i.setStatus(a.id!, clearIdle: true, error: friendlyError(e));
      await Backends.forget(a.id!);
      return false;
    }
  }

  Future<void> _onNew(Account a, String folder) async {
    final id = a.id!;
    // Se un controllo è già in corso, ne parte un altro subito dopo: l'email non aspetta i 5 minuti.
    if (_busy.contains(id)) {
      _again.add(id);
      return;
    }
    _busy.add(id);
    try {
      do {
        _again.remove(id);
        await checkNewMail(a);
      } while (_again.contains(id));
    } catch (e) {
      await Db.i.setStatus(id, error: friendlyError(e));
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _updateText(int ok, int total) async {
    final text = total == 0
        ? 'Nessuna casella configurata'
        : '$ok di $total caselle in ascolto';
    await FlutterForegroundTask.updateService(
      notificationTitle: 'DiGiMail',
      notificationText: text,
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_ticking) return;
    _ticking = true;
    _tick().whenComplete(() => _ticking = false);
  }

  int _n = 0;

  /// Ogni minuto: invii in coda, operazioni in attesa e email rimandate.
  /// Ogni 5 minuti: controllo delle connessioni, caselle a intervallo e pulizia.
  Future<void> _tick() async {
    try {
      await Settings.i.reload();
      await Ops.processScheduled();
      await Ops.flushQueue();
      await Ops.wakeSnoozed();
      _n++;
      final accounts = await Db.i.accounts();
      final wifi = await PushControl.onWifi();
      final now = DateTime.now().millisecondsSinceEpoch;
      var ok = 0;
      for (final a in accounts) {
        final s = Settings.i;
        final id = a.id!;
        final blockedByWifi = s.syncWifiOnly(id) && !wifi;
        final st = await Db.i.status(id);
        // Seguita dal NAS: nessun ascolto anche qui, sarebbe una seconda connessione per niente.
        if (s.syncMode(id) == 'push' && !blockedByWifi && !await _wanted(a)) {
          if (st != null && st['idle_since'] != null) {
            await Backends.forget(id);
            await Db.i.setStatus(id, clearIdle: true);
          }
          continue;
        }
        if (s.syncMode(id) != 'push' || blockedByWifi) {
          // Niente connessione aperta: se c'era, si chiude.
          if (st != null && st['idle_since'] != null) {
            await Backends.forget(id);
            await Db.i.setStatus(id, clearIdle: true);
          }
          if (!blockedByWifi && s.syncMode(id) == 'interval') {
            final last = (st?['last_sync'] ?? 0) as int;
            if (now - last >= s.syncMinutes(id) * 60 * 1000 &&
                !_busy.contains(id))
              await _onNew(a, 'INBOX');
            ok++;
          }
          continue;
        }
        if (_n % 5 != 1) {
          ok++;
          continue;
        }
        final alive =
            st != null && st['idle_since'] != null && st['last_error'] == null;
        if (!alive) {
          await Backends.forget(id);
          if (await _listen(a)) ok++;
        } else {
          ok++;
          // Controllo di sicurezza: se l'IDLE avesse perso un avviso, la lista si riallinea.
          if (!_busy.contains(id)) await _onNew(a, 'INBOX');
        }
      }
      if (_n % 5 == 1) {
        for (final a in accounts) {
          await Db.i.deleteOlderThan(a.id!, Settings.i.historyDays(a.id!));
        }
        await _updateText(ok, accounts.length);
      }
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await Backends.forgetAll();
  }
}

final Map<int, Future<int>> _controlli = {};

/// Scarica la Posta in arrivo e fa suonare le email nuove non lette.
/// La usano il servizio in primo piano, gli avvisi del NAS e il controllo in background.
/// Per ogni casella un controllo alla volta: se ne arriva un altro mentre il primo lavora,
/// parte subito dopo (due controlli insieme si chiuderebbero a vicenda la connessione).
/// Restituisce quante email ha avvisato.
Future<int> checkNewMail(Account a) {
  final id = a.id!;
  final prima = _controlli[id] ?? Future<int>.value(0);
  final dopo = prima.catchError((_) => 0).then((_) => _controllaOra(a));
  _controlli[id] = dopo;
  dopo.catchError((_) => 0).then((_) {
    if (identical(_controlli[id], dopo)) _controlli.remove(id);
  });
  return dopo;
}

Future<int> _controllaOra(Account a) async {
  final id = a.id!;
  final seenAt = DateTime.now();
  await Db.i.setStatus(id, lastEvent: seenAt.millisecondsSinceEpoch);
  await Settings.i.reload();
  // Le operazioni di questa casella rimaste in coda (per esempio un «letto» senza rete)
  // partono prima, o la sincronizzazione le cancellerebbe con lo stato vecchio del server.
  // Se non ce ne sono non costa niente; quelle delle altre caselle aspettano.
  if ((await Db.i.pendingOps()).any((r) => r['account_id'] == id)) {
    try {
      await Ops.flushQueue(accountId: id).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
  await Ops.refresh(a, notify: false, flush: false);
  // Subito, senza aspettare le altre cartelle: il tempo concesso a un avviso dal NAS è poco e
  // finire fuori tempo dava la notifica senza testo.
  var avvisate = await notifyPending(a, seenAt: seenAt);
  // Spam e Cestino: se il server vi mette un'email, deve contare e avvisare come le altre.
  try {
    for (final f in await Backends.of(a).folders()) {
      if (f.role == 'junk' || f.role == 'trash') {
        await Ops.refresh(a, folder: f.path, notify: false, flush: false);
      }
    }
  } catch (_) {}
  avvisate += await notifyPending(a, seenAt: seenAt);
  return avvisate;
}

/// Comandi dell'interfaccia verso il servizio.
class PushControl {
  PushControl._();

  static void init() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'digimail_ascolto_min',
        channelName: 'DiGiMail in ascolto',
        channelDescription: 'Tiene collegate le caselle per avvisarti subito.',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        visibility: NotificationVisibility.VISIBILITY_SECRET,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60 * 1000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> get running async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  static Future<void> start() async {
    try {
      if (await running) return;
      await FlutterForegroundTask.startService(
        serviceId: 4711,
        serviceTypes: [ForegroundServiceTypes.specialUse],
        notificationTitle: 'DiGiMail',
        notificationText: 'Collego le caselle…',
        callback: pushStartCallback,
      );
    } catch (_) {}
  }

  static Future<void> restart() async {
    await NasPush.register();
    if (await NasPush.active) return syncWithSettings();
    try {
      if (await running) {
        await FlutterForegroundTask.restartService();
      } else {
        await start();
      }
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  /// Accende il servizio se c'è almeno una casella e l'utente non ha spento le notifiche in tempo reale.
  static Future<void> syncWithSettings() async {
    final accounts = await Db.i.accounts();
    // Il servizio resta acceso anche senza «tempo reale»: serve a spedire le email in coda e a controllare a intervalli.
    if (accounts.isEmpty) {
      if (await running) await stop();
      await NasPush.stopBackground();
      return;
    }
    // Il NAS avvisa lui delle caselle con password che sono in «subito». Il servizio in
    // primo piano (e il suo avviso fisso) resta solo se c'è una casella che il NAS non segue.
    await NasPush.register();
    if (await NasPush.active) {
      var serve = false;
      for (final a in accounts) {
        if (Settings.i.syncMode(a.id!) == 'push' && !await NasPush.covers(a)) {
          serve = true;
        }
      }
      await NasPush.startBackground();
      if (serve) {
        await start();
      } else if (await running) {
        await stop();
      }
      return;
    }
    // Il controllo in sottofondo resta anche qui: se Android chiude il servizio è l'unica riserva.
    await NasPush.startBackground();
    await start();
  }

  /// Vero se il telefono è su Wi-Fi (o rete cablata). Se non si riesce a capire, si considera di sì.
  static Future<bool> onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  static Future<bool> batteryOk() async {
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  static Future<void> askBattery() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
  }
}
