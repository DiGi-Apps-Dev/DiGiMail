import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' show HMac, KeyParameter, SHA256Digest;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart';
import 'models.dart';
import 'notify.dart';
import 'ops.dart';
import 'push_service.dart';
import 'settings.dart';

/// Lavori in background (controllo ogni 15 minuti, invii programmati, email rimandate).
///
/// Nella versione pubblica non c'è un server di avvisi: le email nuove arrivano dalla
/// connessione IMAP «IDLE» che l'app tiene aperta (vedi push_service.dart). Gli agganci per
/// un server proprio restano spenti finché [url] è vuoto.
class NasPush {
  NasPush._();

  static const url = '';
  static const _chiave = '';
  static const _ok = 'nasPushOk';
  static const _sig = 'nasPushSig';
  static const _daRifare = 'nasPushDaRifare';

  /// All'avvio dell'app: riceve gli avvisi e prepara i controlli in background.
  static Future<void> init() async {
    try {
      await Workmanager().initialize(backgroundDispatcher);
      await AndroidAlarmManager.initialize();
    } catch (_) {}
  }

  /// Vero se il NAS ha accettato la registrazione di questo telefono.
  static Future<bool> get active async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_ok) ?? false;
  }

  /// Vero se il NAS segue questa casella: telefono registrato, casella con password
  /// e scelta «subito». Le altre (accesso Microsoft, controllo a intervalli) restano al telefono.
  static Future<bool> covers(Account a) async {
    if (!await active) return false;
    if (a.authType != 'password') return false;
    return Settings.i.syncMode(a.id!) == 'push';
  }

  /// Registrazione su un server di avvisi: nella versione pubblica non c'è.
  static Future<void> register() async {
    // Nessun server di avvisi nella versione pubblica.
  }

  /// Controllo ogni 15 minuti: invii in coda, email rimandate, e posta nuova se il NAS
  /// fosse spento.
  static Future<void> startBackground() async {
    try {
      await Workmanager().registerPeriodicTask(
        'digimail-controllo',
        'controllo',
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {}
  }

  static Future<void> stopBackground() async {
    try {
      await Workmanager().cancelByUniqueName('digimail-controllo');
    } catch (_) {}
  }

  /// Sveglia all'orario di un invio programmato o di un'email rimandata: un allarme esatto
  /// (parte anche a telefono a riposo) e, come riserva, un lavoro di Workmanager.
  static Future<void> wakeAt(DateTime at) async {
    try {
      await AndroidAlarmManager.oneShotAt(
        at.isBefore(DateTime.now()) ? DateTime.now().add(const Duration(seconds: 2)) : at,
        at.millisecondsSinceEpoch ~/ 1000 % 2000000000,
        orarioEsatto,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
      );
    } catch (_) {}
    var d = at.difference(DateTime.now());
    if (d.isNegative) d = Duration.zero;
    try {
      await Workmanager().registerOneOffTask(
        'digimail-orario-${at.millisecondsSinceEpoch}',
        'orario',
        initialDelay: d + const Duration(seconds: 5),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
    } catch (_) {}
  }

  /// Quanti avvisi sta gestendo questo processo: la connessione condivisa si chiude
  /// solo quando l'ultimo ha finito (altrimenti uno chiude la connessione all'altro).
  static int _attivi = 0;
  static bool get inUso => _attivi > 0;

  /// Avviso arrivato dal NAS: si scarica l'email e suona come sempre. Se non si
  /// riesce a scaricarla, compare lo stesso con mittente e oggetto. Di ogni avviso
  /// resta una riga in «Stato notifiche» con com'è andata.
  static Future<void> handle(Map<String, dynamic> d) async {
    final tipo = d['tipo'];
    if (tipo != 'nuova' && tipo != 'letta') return;
    _attivi++;
    try {
      if (tipo == 'letta') {
        await _letta(d);
      } else {
        await _gestisci(d);
      }
    } finally {
      _attivi--;
    }
  }

  /// Email letta (o tolta) da un altro programma, per esempio dal PC: si segna letta nel
  /// database, si toglie la sua notifica e si aggiorna il numerino sull'icona.
  static Future<void> _letta(Map<String, dynamic> d) async {
    final uid = int.tryParse('${d['uid'] ?? ''}') ?? 0;
    if (uid == 0) return;
    await _prepare();
    final address = '${d['casella'] ?? ''}'.toLowerCase();
    for (final a in await Db.i.accounts()) {
      if (a.address.toLowerCase() != address) continue;
      await Db.i.setSeen(a.id!, 'INBOX', [uid], true);
      await Notify.cancelFor(a.id!, uid);
    }
    await Notify.updateIconBadge();
  }

  static Future<void> _gestisci(Map<String, dynamic> d) async {
    final ricevuto = DateTime.now();
    final uid = int.tryParse('${d['uid'] ?? ''}') ?? 0;
    await _prepare();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_ultimoAvviso, ricevuto.millisecondsSinceEpoch);
    } catch (_) {}
    final address = '${d['casella'] ?? ''}'.toLowerCase();
    Account? a;
    for (final x in await Db.i.accounts()) {
      if (x.address.toLowerCase() == address) a = x;
    }
    if (a == null) {
      await Db.i.logPush(
        0,
        uid,
        ricevuto,
        ricevuto,
        DateTime.now(),
        result: 'casella sconosciuta',
      );
      return;
    }
    final id = a.id!;
    final soloWifi = Settings.i.syncWifiOnly(id) && !await PushControl.onWifi();
    String? motivo;
    if (soloWifi) {
      motivo = 'solo Wi-Fi';
    } else {
      try {
        final n = await checkNewMail(a).timeout(const Duration(seconds: 40));
        if (n == 0) {
          await Db.i.logPush(
            id,
            uid,
            ricevuto,
            ricevuto,
            DateTime.now(),
            result: 'avviso dal NAS: nessuna email nuova da avvisare',
          );
        }
      } catch (e) {
        motivo = '${e.runtimeType}';
      }
    }
    // Il numero dell'email vale solo nella sua cartella (un NAS vecchio non la dice: Posta in arrivo).
    final cartella = '${d['cartella'] ?? 'INBOX'}';
    // Dal Cestino non si avvisa alla cieca: quasi sempre è l'email che l'utente ha appena eliminato.
    if (motivo != null && d['ruolo'] == 'cestino') {
      await Db.i.logPush(
        id,
        uid,
        ricevuto,
        ricevuto,
        DateTime.now(),
        result: 'riserva saltata: email nel Cestino ($motivo)',
      );
    } else if (motivo != null) {
      // Senza scaricare niente: la notifica compare con quello che ha mandato il NAS.
      final m = Msg(
        accountId: id,
        folder: cartella,
        uid: uid,
        fromName: '${d['mittente'] ?? ''}',
        subject: '${d['oggetto'] ?? ''}',
        date: DateTime.now(),
      );
      // Prima si lascia la riga e la si prende in carico: senza riga il segno «avvisata» non
      // restava da nessuna parte e alla sincronizzazione la stessa email suonava di nuovo. Se la
      // presa in carico fallisce, l'ha già avvisata il controllo che intanto è arrivato in fondo.
      if (uid != 0) await Db.i.upsertMessages([m], pending: {uid});
      if (uid == 0 || await Db.i.claimNotify(id, cartella, uid)) {
        final r = await Notify.showNew(a, m);
        await Db.i.logPush(
          id,
          uid,
          ricevuto,
          ricevuto,
          DateTime.now(),
          result: 'riserva ($motivo): $r',
        );
      }
    }
    // Le operazioni rimaste in coda partono dopo l'avviso, non prima.
    try {
      await Ops.flushQueue().timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  static const _ultimoAvviso = 'nasUltimoAvviso';

  /// Quando è arrivato l'ultimo avviso dal NAS (null se mai).
  static Future<DateTime?> lastAlert() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final v = p.getInt(_ultimoAvviso);
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  /// La firma che il NAS deve saper fare con la chiave che conosce solo lui e il telefono.
  static String firma(String chiave, String testo) {
    final h = HMac(SHA256Digest(), 64)
      ..init(KeyParameter(Uint8List.fromList(utf8.encode(chiave))));
    final out = h.process(Uint8List.fromList(utf8.encode(testo)));
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Chiede al NAS di firmare un numero a caso. Né la chiave né le password partono prima.
  static Future<bool> _eIlMioNas() async {
    try {
      final rnd = Random.secure();
      final n = List.generate(
        16,
        (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final r = await http
          .get(Uri.parse('$url/prova?n=$n'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return j['firma'] == firma(_chiave, n);
    } catch (_) {
      return false;
    }
  }

  /// A casa: chiede al NAS se conosce ancora questo telefono e tutte le caselle. Se no,
  /// toglie il segno di registrazione e la ripete. Fuori casa non risponde e non cambia niente.
  static Future<String> verify() async {
    if (url.isEmpty) return 'non usato';
    try {
      if (!await _eIlMioNas()) return 'NAS non raggiungibile';
      final r = await http
          .get(Uri.parse('$url/stato'), headers: {'X-DiGiMail-Key': _chiave})
          .timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return 'il NAS ha risposto ${r.statusCode}';
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final attese = <String>{};
      for (final a in await Db.i.accounts()) {
        if (await covers(a)) attese.add(a.address);
      }
      final viste = <String>{
        for (final c in (j['caselle'] as List? ?? []))
          '${(c as Map)['casella']}',
      };
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final manca =
          (sp.getBool(_daRifare) ?? false) ||
          j['telefono'] != true ||
          !viste.containsAll(attese);
      if (manca) {
        final p = await SharedPreferences.getInstance();
        await p.remove(_ok);
        await p.remove(_sig);
        await register();
        return 'registrazione rifatta';
      }
      return 'ok';
    } catch (_) {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return (p.getBool(_daRifare) ?? false)
          ? 'da rifare: il NAS non è raggiungibile, torna a casa e apri DiGiMail'
          : 'NAS non raggiungibile';
    }
  }

  static Future<void> _prepare() async {
    Backends.factory = (a) => ImapBackend(a);
    await Settings.i.load();
    await Notify.init();
  }

  /// Il lavoro in background: quello che faceva il servizio in primo piano ogni minuto.
  static Future<void> backgroundWork(String task) async {
    await _prepare();
    await Ops.processScheduled();
    await Ops.flushQueue();
    await Ops.wakeSnoozed();
    if (task != 'controllo') return;
    final wifi = await PushControl.onWifi();
    final adesso = DateTime.now().millisecondsSinceEpoch;
    for (final a in await Db.i.accounts()) {
      final id = a.id!;
      if (Settings.i.syncWifiOnly(id) && !wifi) continue;
      // «Controllo ogni tot minuti»: questo lavoro gira ogni 15, la casella aspetta il suo turno.
      if (Settings.i.syncMode(id) == 'interval') {
        final st = await Db.i.status(id);
        final ultimo = (st?['last_sync'] ?? 0) as int;
        if (adesso - ultimo < (Settings.i.syncMinutes(id) - 1) * 60 * 1000) {
          continue;
        }
      }
      try {
        await checkNewMail(a).timeout(const Duration(seconds: 60));
      } catch (_) {}
      await Db.i.deleteOlderThan(a.id!, Settings.i.historyDays(a.id!));
    }
  }
}

/// Lavori pianificati di Android (ogni 15 minuti e agli orari programmati).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await NasPush.backgroundWork(task);
    } catch (_) {}
    try {
      await Backends.forgetAll();
    } catch (_) {}
    return true;
  });
}

/// Allarme esatto: fa quello che farebbe il lavoro in background all'orario scelto.
@pragma('vm:entry-point')
Future<void> orarioEsatto() async {
  DartPluginRegistrant.ensureInitialized();
  try {
    await NasPush.backgroundWork('orario');
  } catch (_) {}
  try {
    await Backends.forgetAll();
  } catch (_) {}
}
