import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'db.dart';
import 'models.dart';
import 'notify_actions.dart';
import 'notify_avatar.dart';
import 'settings.dart';

/// Notifiche delle email nuove: un canale per ogni casella, così il suono
/// si sceglie casella per casella dalle impostazioni di Android.
class Notify {
  Notify._();
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static final StreamController<String> taps =
      StreamController<String>.broadcast();
  static bool foreground = false;
  static bool _ready = false;

  /// Solo per le prove: se c'è, le notifiche vanno qui invece che ad Android.
  static Future<void> Function(
    int id,
    String title,
    String body,
    NotificationDetails details,
    String? payload,
  )?
  sink;

  static Future<void> _emit(
    int id,
    String title,
    String body,
    NotificationDetails details,
    String? payload,
  ) {
    final s = sink;
    if (s != null) return s(id, title, body, details, payload);
    return plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  static Future<void> init() async {
    if (_ready || sink != null) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_digimail'),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (NotifyActions.isAction(r)) {
          NotifyActions.handle(r);
          return;
        }
        final p = r.payload;
        logTap(p ?? '', 'ricevuto dall\'app${taps.hasListener ? '' : ' (schermata non pronta)'}');
        if (p != null && p.isNotEmpty) taps.add(p);
      },
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );
    _ready = true;
  }

  /// Ogni tocco su una notifica lascia una riga in «Stato notifiche»: quale email era
  /// e cosa ha aperto l'app, per vedere sul telefono dove si perde un'apertura.
  static Future<void> logTap(String payload, String esito) async {
    try {
      final parts = payload.split('|');
      final now = DateTime.now();
      await Db.i.logPush(
        int.tryParse(parts[0]) ?? 0,
        parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
        now,
        now,
        now,
        result: 'tocco: $esito',
      );
    } catch (_) {}
  }

  static String channelId(Account a) => 'acc_${a.id}_v1';

  static bool _badgeBusy = false;
  static bool _badgeAgain = false;

  /// Numero sull'icona dell'app: le non lette nella Posta in arrivo di tutti
  /// gli account, contate dal database e non dalle notifiche aperte, così
  /// cancellare una notifica non lo cambia e leggere un'email lo cala subito.
  static Future<void> updateIconBadge() async {
    if (_badgeBusy) {
      _badgeAgain = true;
      return;
    }
    _badgeBusy = true;
    try {
      do {
        _badgeAgain = false;
        var n = 0;
        if (Settings.i.badgeCount) {
          for (final a in await Db.i.accounts()) {
            n += await Db.i.unseenAlertCount(a.id!);
          }
        }
        await AppBadgePlus.updateBadge(n);
      } while (_badgeAgain);
    } catch (_) {
    } finally {
      _badgeBusy = false;
    }
  }

  static Future<void> ensureChannel(Account a) async {
    if (sink != null) return;
    final impl = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await impl?.createNotificationChannel(
      AndroidNotificationChannel(
        channelId(a),
        a.name.isEmpty ? a.address : a.name,
        description: 'Email nuove di ${a.address}',
        importance: Importance.high,
      ),
    );
  }

  /// Toglie il canale di una casella tolta dall'app (resterebbe nelle impostazioni di Android).
  static Future<void> deleteChannel(int accountId) async {
    try {
      final impl = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await impl?.deleteNotificationChannel(channelId: 'acc_${accountId}_v1');
    } catch (_) {}
  }

  /// Quante notifiche di questa casella sono ancora nella tendina (senza il riepilogo).
  static Future<int> activeCount(Account a) async {
    if (sink != null) return 0;
    try {
      final impl = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final list = await impl?.getActiveNotifications() ?? [];
      return list
          .where((n) => n.channelId == channelId(a) && n.id != 900000000 + a.id!)
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// Toglie dalla tendina le notifiche delle email che nel frattempo risultano lette.
  static Future<void> cancelSeen(Account a) async {
    if (sink != null) return;
    try {
      final impl = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final list = await impl?.getActiveNotifications() ?? [];
      for (final n in list) {
        if (n.channelId != channelId(a) || n.id == 900000000 + a.id!) continue;
        final parts = (n.payload ?? '').split('|');
        final uid = parts.length >= 3 ? int.tryParse(parts[2]) : null;
        if (uid == null || uid == 0) continue;
        final m = await Db.i.message(a.id!, parts[1], uid);
        if (m == null || m.seen) await plugin.cancel(id: n.id!);
      }
    } catch (_) {}
  }

  static Future<bool> permitted() async {
    try {
      final impl = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await impl?.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPermission() async {
    final impl = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await impl?.requestNotificationsPermission() ?? false;
  }

  /// Apre la schermata di Android dove si sceglie suono e vibrazione di questa casella.
  static Future<void> openChannelSettings(Account a) async {
    await ensureChannel(a);
    final intent = AndroidIntent(
      action: 'android.settings.CHANNEL_NOTIFICATION_SETTINGS',
      arguments: <String, dynamic>{
        'android.provider.extra.APP_PACKAGE': 'dev.digiapps.digimail',
        'android.provider.extra.CHANNEL_ID': channelId(a),
      },
    );
    await intent.launch();
  }

  static bool inQuietHours([DateTime? now]) {
    final q = Settings.i.quietHours;
    if (q.isEmpty || !q.contains('-')) return false;
    final parts = q.split('-');
    final from = int.tryParse(parts[0]);
    final to = int.tryParse(parts[1]);
    if (from == null || to == null || from == to) return false;
    final h = (now ?? DateTime.now()).hour;
    return from < to ? (h >= from && h < to) : (h >= from || h < to);
  }

  /// Testo della notifica espansa: 0 niente, 1 oggetto, 2 oggetto e inizio del testo, 3 oggetto e testo lungo.
  static String detailText(Msg m, int detail) {
    if (detail <= 0) return 'Nuova email';
    final subject = m.subject.isEmpty ? '(senza oggetto)' : m.subject;
    if (detail == 1 || m.preview.isEmpty) return subject;
    final p = m.preview.replaceAll(RegExp(r'\s+'), ' ').trim();
    final max = detail == 2 ? 120 : 600;
    return '$subject\n${p.length > max ? '${p.substring(0, max)}…' : p}';
  }

  /// Il numero di un'email vale solo nella sua cartella: lo Spam numero 5 e la Posta in arrivo
  /// numero 5 sono due email, e l'una non deve sovrascrivere la notifica dell'altra.
  static int idFor(int accountId, int uid, [String folder = 'INBOX']) {
    var f = 0;
    if (folder.toUpperCase() != 'INBOX') {
      for (final c in folder.codeUnits) {
        f = (f * 31 + c) & 0xfffff;
      }
      f = (f + 1) * 8191;
    }
    return (accountId * 100003 + uid + f) & 0x3fffffff;
  }

  /// Mostra la notifica di un'email nuova e dice com'è andata: 'ok', 'silenziosa'
  /// (ore silenziose: compare senza suono), 'spenta', 'casella spenta', 'ridotta:<errore>' (è comparsa in forma
  /// semplice) o 'errore:<errore>'. Una notifica che non riesce non ferma il resto.
  static Future<String> showNew(Account a, Msg m, {int unseen = 1}) async {
    try {
      return await _showNew(a, m, unseen: unseen);
    } catch (e) {
      try {
        await _showMinimal(a, m);
        return 'ridotta:${e.runtimeType}';
      } catch (e2) {
        return 'errore:${e2.runtimeType}';
      }
    }
  }

  /// Ultima risorsa: solo mittente e oggetto, niente logo né gruppo.
  static Future<void> _showMinimal(Account a, Msg m) async {
    await init();
    await ensureChannel(a);
    await _emit(
      idFor(a.id!, m.uid, m.folder),
      m.sender.isEmpty ? (a.name.isEmpty ? a.address : a.name) : m.sender,
      m.subject.isEmpty ? '(senza oggetto)' : m.subject,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId(a),
          a.name.isEmpty ? a.address : a.name,
          icon: 'ic_stat_digimail',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      '${a.id}|${m.folder}|${m.uid}',
    );
  }

  static Future<String> _showNew(Account a, Msg m, {int unseen = 1}) async {
    final s = Settings.i;
    // Anche con l'app aperta: l'email nuova deve suonare come ad app chiusa (deciso dall'utente).
    if (!s.notifyEnabled) return 'spenta';
    if (!a.notify) return 'casella spenta';
    // Le newsletter arrivano nel riassunto.
    // Ore silenziose: la notifica compare lo stesso, senza suono né vibrazione.
    final quiet = inQuietHours();
    await init();
    await ensureChannel(a);
    final title = s.notifyShowSender
        ? m.sender
        : (a.name.isEmpty ? a.address : a.name);
    // «Mostra l'anteprima» spento: niente inizio del testo, al massimo mittente e oggetto.
    final detail = (!s.notifyShowPreview && s.notifyDetail > 1) ? 1 : s.notifyDetail;
    final body = detailText(m, detail);
    final group = 'grp_${a.id}';
    // Subito con il logo che c'è già (o le iniziali): scaricarlo dal sito del mittente
    // farebbe aspettare la notifica e direbbe al mittente che l'email è arrivata.
    final avatar = await notifyAvatar(m.sender, m.fromAddr, a.color, fetch: false);
    await _emit(
      idFor(a.id!, m.uid, m.folder),
      title,
      detail == 0
          ? 'Nuova email'
          : (m.subject.isEmpty ? '(senza oggetto)' : m.subject),
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId(a),
          a.name.isEmpty ? a.address : a.name,
          icon: 'ic_stat_digimail',
          largeIcon: avatar == null ? null : ByteArrayAndroidBitmap(avatar),
          importance: Importance.high,
          priority: Priority.high,
          groupKey: group,
          silent: quiet,
          visibility: s.notifyHideOnLock
              ? NotificationVisibility.private
              : NotificationVisibility.public,
          channelShowBadge: s.badgeCount,
          actions: NotifyActions.forMessage(),
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: title,
            summaryText: a.name.isEmpty ? a.address : a.name,
          ),
        ),
      ),
      '${a.id}|${m.folder}|${m.uid}',
    );
    if (unseen > 1) {
      await _emit(
        900000000 + a.id!,
        a.name.isEmpty ? a.address : a.name,
        '$unseen email non lette',
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId(a),
            a.name.isEmpty ? a.address : a.name,
            icon: 'ic_stat_digimail',
            groupKey: group,
            setAsGroupSummary: true,
            // Il riepilogo non deve suonare una seconda volta: avvisano le singole email.
            groupAlertBehavior: GroupAlertBehavior.children,
            onlyAlertOnce: true,
            importance: Importance.high,
            priority: Priority.high,
            silent: quiet,
            channelShowBadge: s.badgeCount,
          ),
        ),
        '${a.id}|INBOX|0',
      );
    }
    return quiet ? 'silenziosa' : 'ok';
  }

  static Future<void> showInfo(
    String title,
    String body, {
    int id = 800000001,
    String? payload,
  }) async {
    try {
      await init();
      await plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'info_v1',
            'Avvisi di DiGiMail',
            importance: Importance.defaultImportance,
            icon: 'ic_stat_digimail',
          ),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  static Future<void> cancelFor(int accountId, int uid, [String folder = 'INBOX']) async {
    if (!_ready) return;
    try {
      await plugin.cancel(id: idFor(accountId, uid, folder));
    } catch (_) {}
  }
}
