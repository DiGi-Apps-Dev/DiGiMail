import 'db.dart';
import 'mail/backend.dart';
import 'models.dart';
import 'notify.dart';
import 'settings.dart';

/// Avvisa le email della Posta in arrivo che sono arrivate ma non sono ancora state avvisate.
///
/// Chi decide se un'email è «nuova» è il segno `notified` scritto nel database quando la
/// sincronizzazione la trova (vedi `ImapBackend.sync`), non il fatto che sia entrata adesso
/// nella copia locale: se l'ha scaricata prima l'app aperta, suona lo stesso. Ogni email la
/// prende in carico un solo controllo alla volta, quindi non suona due volte. Per ognuna si
/// registra com'è andata (Impostazioni > Stato notifiche).
Future<int> notifyPending(Account a, {DateTime? seenAt}) async {
  final id = a.id!;
  final seen = seenAt ?? DateTime.now();
  final pend = await Db.i.pendingNotify(id);
  if (pend.isEmpty) return 0;
  final before = await Notify.activeCount(a);
  var n = 0;
  for (final m in pend) {
    // Letta nel frattempo (anche dal PC): niente avviso, ma non resta in sospeso.
    if (m.seen) {
      await Db.i.claimNotify(id, m.folder, m.uid);
      continue;
    }
    // L'anteprima del testo nella notifica: l'elenco porta solo le intestazioni.
    if (m.preview.isEmpty && Settings.i.notifyDetail >= 2) {
      for (var i = 0; i < 2 && m.preview.isEmpty; i++) {
        try {
          await Backends.of(
            a,
          ).loadBody(m).timeout(const Duration(seconds: 15));
        } catch (_) {
          // Connessione in stato incerto: la seconda prova riparte da una nuova. Non si butta
          // il backend: è lo stesso della schermata aperta e dell'ascolto. Si segna l'ascolto
          // come fermo, così il servizio lo rifà invece di crederlo vivo.
          Backends.of(a).riparti();
          await Db.i.setStatus(id, clearIdle: true);
        }
      }
    }
    // Si prende in carico solo adesso, a testo pronto: scaricarlo può durare 30 s e, se Android
    // chiudeva l'app in quel momento, l'email restava segnata come avvisata e non suonava più.
    if (!await Db.i.claimNotify(id, m.folder, m.uid)) continue;
    n++;
    final result = await Notify.showNew(a, m, unseen: before + n);
    await Db.i.logPush(
      id,
      m.uid,
      m.date,
      seen,
      DateTime.now(),
      result: result,
    );
  }
  return n;
}
