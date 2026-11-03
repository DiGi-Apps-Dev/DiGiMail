import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart';
import 'models.dart';
import 'notify.dart';
import 'ops.dart';
import 'settings.dart';
import 'signature.dart';
import 'ui/compose_screen.dart';

/// I tasti «Elimina» e «Rispondi» della notifica di un'email: funzionano con l'app chiusa,
/// passano dalle stesse operazioni dell'app (cache, coda senza rete, server) e alla fine
/// la notifica sparisce sempre, con l'esito detto in una riga.
class NotifyActions {
  NotifyActions._();

  static const delete = 'elimina';
  static const reply = 'rispondi';

  static List<AndroidNotificationAction> forMessage() => const [
    AndroidNotificationAction(
      reply,
      'Rispondi',
      inputs: [AndroidNotificationActionInput(label: 'Scrivi la risposta')],
      showsUserInterface: false,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      delete,
      'Elimina',
      showsUserInterface: false,
      cancelNotification: true,
    ),
  ];

  /// Vero se la risposta di Android è un tasto di azione e non il tocco sulla notifica.
  static bool isAction(NotificationResponse r) =>
      r.actionId == delete || r.actionId == reply;

  static Future<void> handle(NotificationResponse r) async {
    final parts = (r.payload ?? '').split('|');
    if (parts.length < 3) return;
    final accId = int.tryParse(parts[0]);
    final uid = int.tryParse(parts[2]);
    if (accId == null || uid == null || uid == 0) return;
    final folder = parts[1];
    final a = await Db.i.account(accId);
    if (a == null) {
      await Notify.cancelFor(accId, uid, folder);
      return;
    }
    final m = await Db.i.message(accId, folder, uid);
    if (r.actionId == delete) {
      await _delete(a, folder, uid, m);
    } else if (r.actionId == reply) {
      await _reply(a, folder, uid, m, (r.input ?? '').trim());
    }
    await Notify.updateIconBadge();
  }

  static Future<void> _delete(Account a, String folder, int uid, Msg? m) async {
    try {
      if (m != null) {
        await Ops.perform(Act.delete, a, [m]);
        await Ops.pendingWork;
      }
      await Notify.cancelFor(a.id!, uid, folder);
    } catch (e) {
      await Notify.cancelFor(a.id!, uid, folder);
      await Notify.showInfo(
        'Email non eliminata',
        'Non sono riuscito a eliminarla da ${a.address}: ${friendlyError(e)}',
        id: 800000400 + (uid & 0xffff),
      );
    }
  }

  static Future<void> _reply(
    Account a,
    String folder,
    int uid,
    Msg? m,
    String testo,
  ) async {
    if (m == null || testo.isEmpty) {
      // Niente da inviare: la notifica torna com'era, senza girare a vuoto.
      if (m != null) await Notify.showNew(a, m);
      return;
    }
    try {
      final init = ComposeInit.from(a, m, Act.reply);
      final alias = a.aliases.where(
        (x) => x.address.toLowerCase() == init.fromAddress.toLowerCase(),
      );
      final firma = SignatureTools.forSend(a.signatureHtml);
      final esc = const HtmlEscape();
      final html =
          '<div style="font-family:\'Roboto Light\',sans-serif;font-size:12pt;color:#000">${esc.convert(testo).replaceAll('\n', '<br>')}</div>'
          '${firma.trim().isEmpty ? '' : '<br><br>$firma'}'
          '${init.quote.isEmpty ? '' : '<br><blockquote style="margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex">${esc.convert(init.quote.trim()).replaceAll('\n', '<br>')}</blockquote>'}';
      final o = Outgoing(
        accountId: a.id!,
        fromAddress: init.fromAddress,
        fromName: alias.isNotEmpty && alias.first.name.isNotEmpty
            ? alias.first.name
            : a.displaySender,
        to: init.to,
        cc: init.cc,
        subject: init.subject,
        text: '$testo${init.quote}',
        html: html,
        inReplyTo: init.inReplyTo,
        references: init.references,
      );
      var inviata = true;
      try {
        await Ops.send(o);
      } catch (e) {
        if (!Ops.isNetworkError(e)) rethrow;
        // Senza rete parte da sola appena torna la connessione.
        await Ops.queueSend(a, o, DateTime.now());
        inviata = false;
      }
      await Ops.markSeen(a, folder, [uid]);
      await Ops.pendingWork;
      await Notify.cancelFor(a.id!, uid, folder);
      await Notify.showInfo(
        inviata ? 'Risposta inviata' : 'Risposta in coda',
        inviata
            ? 'A ${init.to.join(', ')}'
            : 'Senza rete: parte appena torna la connessione.',
        id: 800000500 + (uid & 0xffff),
      );
    } catch (e) {
      // Il testo scritto non va perso: la notifica resta e dice cosa è successo.
      await Notify.cancelFor(a.id!, uid, folder);
      await Notify.showInfo(
        'Risposta non inviata',
        'Il tuo testo: «$testo». ${friendlyError(e)}',
        id: 800000500 + (uid & 0xffff),
      );
    }
  }
}

/// Tasti della notifica quando l'app è chiusa: Android li consegna a un processo a parte.
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  Backends.factory = (a) => ImapBackend(a);
  await Settings.i.load();
  await Notify.init();
  await NotifyActions.handle(r);
}
