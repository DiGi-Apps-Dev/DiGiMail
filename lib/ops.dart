import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart' show friendlyError;
import 'models.dart';
import 'nas_push.dart';
import 'notify.dart';
import 'notify_pending.dart';
import 'rules.dart';
import 'settings.dart';

enum UnsubResult { done, openedLink, mailSent, notAvailable, failed }

/// Operazioni sulle email: cache locale subito, server subito dopo.
class Ops {
  Ops._();

  static String? lastError;

  // ---------- arrivo di email nuove ----------

  /// Gestisce le email appena arrivate: se il mittente è bloccato dall'utente
  /// finiscono nello spam, le altre restano e vengono restituite per la notifica.
  static Future<List<Msg>> processNew(
    Account a,
    MailBackend b,
    List<Msg> fresh,
  ) async {
    final keep = <Msg>[];
    final toSpam = <int>[];
    String? folder;
    for (final m in fresh) {
      if (m.fromAddr.isNotEmpty && await Db.i.isBlocked(a.id!, m.fromAddr)) {
        toSpam.add(m.uid);
        folder = m.folder;
      } else {
        keep.add(m);
      }
    }
    if (toSpam.isNotEmpty && folder != null) {
      try {
        await b.spam(folder, toSpam);
        await Db.i.deleteLocal(a.id!, folder, toSpam);
      } catch (e) {
        lastError = '$e';
        // Un mittente bloccato non suona mai: senza rete lo spostamento resta in coda, senza
        // cartella Spam l'email resta dov'è, in silenzio.
        if (isNetworkError(e)) {
          await Db.i.addPendingOp(a.id!, 'spam', folder, toSpam, '');
          await Db.i.deleteLocal(a.id!, folder, toSpam);
        } else {
          for (final u in toSpam) {
            await Db.i.claimNotify(a.id!, folder, u);
          }
        }
      }
    }
    return Rules.apply(a, b, keep);
  }

  /// Aggiorna una cartella. [notify] manda le notifiche per le email non lette nuove.
  static Future<List<Msg>> refresh(
    Account a, {
    String folder = 'INBOX',
    bool notify = true,
    bool flush = true,
  }) async {
    final _s = Stopwatch()..start();
    if (flush) {
      try {
        await flushQueue().timeout(const Duration(seconds: 20));
      } catch (_) {}
    }
    print('DIGIMAIL-T refresh ${a.name} flush ${_s.elapsedMilliseconds}ms');
    final b = Backends.of(a);
    final fresh = await b.sync(folder);
    print('DIGIMAIL-T refresh ${a.name} sync ${_s.elapsedMilliseconds}ms');
    final isInbox = folder.toUpperCase() == 'INBOX';
    final keep = isInbox ? await processNew(a, b, fresh) : fresh;
    // Email lette sul PC o su un altro telefono: la loro notifica non serve più.
    print('DIGIMAIL-T refresh ${a.name} processNew ${_s.elapsedMilliseconds}ms');
    if (isInbox) await Notify.cancelSeen(a);
    await Db.i.setStatus(
      a.id!,
      lastSync: DateTime.now().millisecondsSinceEpoch,
    );
    if (notify && isInbox) await notifyPending(a);
    print('DIGIMAIL-T refresh ${a.name} fine ${_s.elapsedMilliseconds}ms');
    return keep;
  }

  // ---------- azioni sui messaggi ----------

  /// Esegue [act] sui messaggi [msgs] (tutti nella stessa cartella e casella).
  /// Restituisce la funzione per annullare, o null se l'azione non si annulla.
  static Future<UndoFn?> perform(
    Act act,
    Account a,
    List<Msg> msgs, {
    String? targetPath,
    DateTime? snoozeUntil,
    bool? force,
  }) async {
    if (msgs.isEmpty) return null;
    final folder = msgs.first.folder;
    final uids = msgs.map((m) => m.uid).toList();
    final b = Backends.of(a);
    switch (act) {
      case Act.delete:
        return _moveOut(
          a,
          folder,
          uids,
          () => b.delete(folder, uids),
          'delete',
          '',
        );
      case Act.archive:
        return _moveOut(
          a,
          folder,
          uids,
          () => b.archive(folder, uids),
          'archive',
          '',
        );
      case Act.spam:
        return _moveOut(
          a,
          folder,
          uids,
          () => b.spam(folder, uids),
          'spam',
          '',
        );
      case Act.move:
        return _moveOut(
          a,
          folder,
          uids,
          () => b.moveTo(folder, uids, targetPath),
          'move',
          targetPath!,
        );
      case Act.toggleRead:
        final makeSeen = force ?? msgs.any((m) => !m.seen);
        await Db.i.setSeen(a.id!, folder, uids, makeSeen);
        if (makeSeen) {
          for (final u in uids) {
            await Notify.cancelFor(a.id!, u, folder);
          }
        }
        _queue(
          a,
          'seen',
          folder,
          uids,
          makeSeen ? '1' : '0',
          () => b.setSeen(folder, uids, makeSeen),
        );
        return () async {
          await Db.i.setSeen(a.id!, folder, uids, !makeSeen);
          _queue(
            a,
            'seen',
            folder,
            uids,
            makeSeen ? '0' : '1',
            () => b.setSeen(folder, uids, !makeSeen),
          );
        };
      case Act.flag:
        final on = force ?? msgs.any((m) => !m.flagged);
        await Db.i.setFlagged(a.id!, folder, uids, on);
        _queue(
          a,
          'flag',
          folder,
          uids,
          on ? '1' : '0',
          () => b.setFlagged(folder, uids, on),
        );
        return () async {
          await Db.i.setFlagged(a.id!, folder, uids, !on);
          _queue(
            a,
            'flag',
            folder,
            uids,
            on ? '0' : '1',
            () => b.setFlagged(folder, uids, !on),
          );
        };
      case Act.snooze:
        if (snoozeUntil == null) return null;
        for (final m in msgs) {
          await Db.i.setSnooze(a.id!, folder, m.uid, snoozeUntil);
          await Notify.cancelFor(a.id!, m.uid, folder);
        }
        await NasPush.wakeAt(snoozeUntil);
        return () async {
          for (final m in msgs) {
            await Db.i.setSnooze(a.id!, folder, m.uid, null);
          }
        };
      case Act.block:
        for (final m in msgs) {
          if (m.fromAddr.isNotEmpty) await Db.i.block(a.id!, m.fromAddr);
        }
        final torna = await _moveOut(
          a,
          folder,
          uids,
          () => b.spam(folder, uids),
          'spam',
          '',
        );
        if (torna == null) return null;
        return () async {
          // Si toglie anche il blocco: se no, alla prima sincronizzazione finirebbe di nuovo nello spam.
          for (final m in msgs) {
            if (m.fromAddr.isNotEmpty) await Db.i.unblock(a.id!, m.fromAddr);
          }
          await torna();
        };
      default:
        return null;
    }
  }

  static Future<UndoFn?> _moveOut(
    Account a,
    String folder,
    List<int> uids,
    Future<UndoFn> Function() server,
    String op,
    String arg,
  ) async {
    // Prima la cache locale, così la lista si aggiorna subito: niente rete prima di questo punto.
    final backup = <Msg>[];
    for (final u in uids) {
      final m = await Db.i.message(a.id!, folder, u);
      if (m != null) backup.add(m);
      await Notify.cancelFor(a.id!, u, folder);
    }
    Db.i.setInVolo(a.id!, folder, uids, true);
    await Db.i.markMoved(a.id!, [for (final m in backup) m.messageId]);
    await Db.i.deleteLocal(a.id!, folder, uids);
    final _t = Stopwatch()..start();
    print('DIGIMAIL-T $op ${a.name} $folder ${uids.join(',')}: tolta in locale');
    // La lista non sempre porta il Message-ID: senza, l'«Annulla» non ritrova l'email nel Cestino.
    final senzaId = [for (final m in backup) if (m.messageId.isEmpty) m.uid];
    if (senzaId.isNotEmpty) {
      try {
        final letti = await Backends.of(a).messageIdsOf(folder, senzaId);
        for (final m in backup) {
          final id = letti[m.uid];
          if (id != null && id.isNotEmpty) m.messageId = id;
        }
        await Db.i.markMoved(a.id!, [for (final m in backup) m.messageId]);
      } catch (_) {}
    }
    try {
      final undo = await server();
      print('DIGIMAIL-T $op ${a.name} $folder: server ok ${_t.elapsedMilliseconds}ms');
      // Una sincronizzazione partita prima può averla rimessa: ora sul server non c'è più.
      await Db.i.deleteLocal(a.id!, folder, uids);
      Db.i.setInVolo(a.id!, folder, uids, false);
      // Dal Cestino l'eliminazione è definitiva: un «Annulla» rimetterebbe in lista un'email
      // che sul server non esiste più.
      if (op == 'delete' && await eCestino(a, folder)) return null;
      return () async {
        Object? libError;
        try {
          await undo();
        } catch (e) {
          libError = e;
        }
        // L'annullamento della libreria non basta sempre (il server può non dire dove
        // è finita l'email): si cerca per Message-ID nel Cestino, Spam e Archivio.
        // Si controlla sempre, anche se la libreria dice di aver annullato: su alcuni server 
        // non dà errore ma non sposta niente. Le email già tornate al loro posto non si toccano.
        final ids = [for (final m in backup) if (m.messageId.isNotEmpty) m.messageId];
        var rimesse = 0;
        try {
          rimesse = await Backends.of(a).restoreByMessageId(
            folder,
            ids,
            alsoIn: op == 'move' ? arg : null,
          );
        } catch (e) {
          if (libError != null) throw libError;
        }
        if (libError != null && rimesse == 0) throw libError;
        await Db.i.upsertMessages(backup);
        // Rilegge senza notifiche: la posizione e l'identificativo possono essere cambiati.
        try {
          await refresh(a, folder: folder, notify: false);
        } catch (_) {}
      };
    } catch (e) {
      lastError = '$e';
      print('DIGIMAIL-T $op ${a.name} $folder: server KO ${_t.elapsedMilliseconds}ms $e');
      Db.i.setInVolo(a.id!, folder, uids, false);
      if (isNetworkError(e)) {
        // Senza rete: l'email sparisce subito dalla lista e lo spostamento parte appena torna la connessione.
        final id = await Db.i.addPendingOp(a.id!, op, folder, uids, arg);
        return () async {
          // Ancora in coda: basta toglierla, sul server non è successo niente.
          if ((await Db.i.pendingOps()).any((r) => r['id'] == id)) {
            await Db.i.deletePendingOp(id);
            await Db.i.upsertMessages(backup);
            return;
          }
          // Nel frattempo è tornata la rete ed è partita: si riporta indietro dal server.
          await Backends.of(a).restoreByMessageId(
            folder,
            [for (final m in backup) if (m.messageId.isNotEmpty) m.messageId],
            alsoIn: op == 'move' ? arg : null,
          );
          await Db.i.upsertMessages(backup);
          try {
            await refresh(a, folder: folder, notify: false);
          } catch (_) {}
        };
      }
      await Db.i.upsertMessages(backup);
      rethrow;
    }
  }

  static Future<bool> eCestino(Account a, String folder) async {
    try {
      for (final f in await Backends.of(a).folders()) {
        if (f.path == folder) return f.role == 'trash';
      }
    } catch (_) {}
    return false;
  }

  /// Gli ultimi lavori lanciati in sottofondo (serve ai test per aspettarli).
  static Future<void> pendingWork = Future.value();

  static bool isNetworkError(Object e) {
    // Un certificato non valido non si aggiusta da solo: non resta in coda per giorni.
    if (e is HandshakeException) return false;
    if (e is SocketException || e is TimeoutException) return true;
    final s = '$e'.toLowerCase();
    return s.contains('socketexception') ||
        s.contains('timeout') ||
        s.contains('connessione') ||
        s.contains('connection') ||
        s.contains('network') ||
        s.contains('host lookup') ||
        s.contains('not connected');
  }

  /// Segna come lette: subito in locale (e toglie le notifiche), sul server in coda se manca la rete.
  static Future<void> markSeen(Account a, String folder, List<int> uids) async {
    await Db.i.setSeen(a.id!, folder, uids, true);
    for (final u in uids) {
      await Notify.cancelFor(a.id!, u, folder);
    }
    _queue(
      a,
      'seen',
      folder,
      uids,
      '1',
      () => Backends.of(a).setSeen(folder, uids, true),
    );
  }

  /// Esegue [run] sul server; se manca la rete l'operazione resta in coda e riparte da sola.
  static void _queue(
    Account a,
    String op,
    String folder,
    List<int> uids,
    String arg,
    Future<void> Function() run,
  ) {
    // Si scrive in coda prima di provare, non dopo il fallimento (che arriva anche dopo decine di
    // secondi): nel frattempo una sincronizzazione riporterebbe indietro «letta» o la stella.
    Future<void> lavoro() async {
      final id = await Db.i.addPendingOp(a.id!, op, folder, uids, arg);
      try {
        await run();
        await Db.i.deletePendingOp(id);
      } catch (e) {
        lastError = '$e';
        if (isNetworkError(e)) return;
        // Il server ha detto di no: il telefono torna com'è il server, e lo si dice.
        await Db.i.deletePendingOp(id);
        if (op == 'seen') await Db.i.setSeen(a.id!, folder, uids, arg != '1');
        if (op == 'flag') await Db.i.setFlagged(a.id!, folder, uids, arg != '1');
        try {
          await Notify.showInfo(
            'Operazione non riuscita',
            '${_nomeOp(op)} su ${uids.length} email di ${a.address} non è andata a buon fine: ${friendlyError(e)}',
            id: 800000300 + id,
          );
        } catch (_) {}
      }
    }

    final f = lavoro();
    pendingWork = Future.wait([pendingWork, f]);
  }

  static Future<int>? _flushInCorso;

  /// Rimanda al server le operazioni fatte senza rete. Restituisce quante sono riuscite.
  /// Se ne è già in corso una si aspetta quella: tornare subito faceva partire una
  /// sincronizzazione che riportava indietro quello che era ancora in coda.
  static Future<int> flushQueue({int? accountId}) {
    final c = _flushInCorso;
    if (c != null) return c;
    final f = _flush(accountId).whenComplete(() => _flushInCorso = null);
    _flushInCorso = f;
    return f;
  }

  static Future<int> _flush(int? accountId) async {
    var done = 0;
    try {
      for (final row in await Db.i.pendingOps()) {
        if (accountId != null && row['account_id'] != accountId) continue;
        final id = row['id'] as int;
        final a = await Db.i.account(row['account_id'] as int);
        if (a == null) {
          await Db.i.deletePendingOp(id);
          continue;
        }
        final folder = row['folder'] as String;
        final uids = (jsonDecode(row['uids'] as String) as List).cast<int>();
        final arg = (row['arg'] ?? '') as String;
        final b = Backends.of(a);
        try {
          switch (row['op']) {
            case 'seen':
              await b.setSeen(folder, uids, arg == '1');
            case 'flag':
              await b.setFlagged(folder, uids, arg == '1');
            case 'delete':
              await b.delete(folder, uids);
            case 'archive':
              await b.archive(folder, uids);
            case 'spam':
              await b.spam(folder, uids);
            case 'move':
              await b.moveTo(folder, uids, arg);
          }
          await Db.i.deletePendingOp(id);
          done++;
        } catch (e) {
          lastError = '$e';
          // Si rinuncia solo dopo 3 giorni di tentativi (o se l'errore non è di rete), e lo si dice.
          final eta = DateTime.now().millisecondsSinceEpoch -
              ((row['created'] ?? 0) as int);
          final troppoVecchia = eta > 3 * 24 * 3600 * 1000;
          if (!isNetworkError(e) || troppoVecchia) {
            await Db.i.deletePendingOp(id);
            final n = uids.length;
            await Notify.showInfo(
              'Operazione non riuscita',
              '${_nomeOp(row['op'] as String)} su $n email di ${a.address} non è andata a buon fine: ${friendlyError(e)}',
              id: 800000300 + id,
            );
          } else {
            await Db.i.bumpPendingOp(id);
          }
        }
      }
    } finally {
      // niente da liberare: lo fa flushQueue
    }
    return done;
  }

  static String _nomeOp(String op) => switch (op) {
    'seen' => 'Segnare come letta',
    'flag' => 'Mettere la stella',
    'delete' => 'Eliminare',
    'archive' => 'Archiviare',
    'spam' => 'Spostare nello spam',
    'move' => 'Spostare',
    _ => 'L\'operazione',
  };

  static Future<void> emptyTrash(Account a, String trashPath) async {
    final tolte = await Db.i.messages(a.id!, trashPath, limit: 5000);
    await Backends.of(a).emptyTrash(trashPath);
    for (final m in tolte) {
      await Notify.cancelFor(a.id!, m.uid, trashPath);
    }
    await Db.i.pruneFolder(a.id!, trashPath, 0, {});
  }

  /// Riporta in vita le email rimandate il cui momento è arrivato.
  static Future<int> wakeSnoozed() async {
    final due = await Db.i.dueSnoozed();
    for (final m in due) {
      final a = await Db.i.account(m.accountId);
      if (a == null) continue;
      await Db.i.setSnooze(m.accountId, m.folder, m.uid, null);
      await Db.i.setSeen(m.accountId, m.folder, [m.uid], false);
      _queue(
        a,
        'seen',
        m.folder,
        [m.uid],
        '0',
        () => Backends.of(a).setSeen(m.folder, [m.uid], false),
      );
      await Notify.showNew(a, m..seen = false);
    }
    return due.length;
  }

  // ---------- blocco e disiscrizione ----------

  static List<String> _unsubParts(String header) => RegExp(
    r'<([^>]+)>',
  ).allMatches(header).map((m) => m.group(1)!.trim()).toList();

  static bool canUnsubscribe(Msg m) =>
      m.listUnsub.isNotEmpty && _unsubParts(m.listUnsub).isNotEmpty;

  /// Disiscrizione con un tocco quando il mittente lo permette (One-Click o mailto).
  /// Se c'è solo un link, restituisce [UnsubResult.openedLink] e [linkOut] contiene il link da aprire.
  static Future<UnsubResult> unsubscribe(
    Account a,
    Msg m,
    void Function(String link) linkOut, {
    http.Client? client,
  }) async {
    final parts = _unsubParts(m.listUnsub);
    if (parts.isEmpty) return UnsubResult.notAvailable;
    final https = parts
        .where((p) => p.toLowerCase().startsWith('https://'))
        .toList();
    final mail = parts
        .where((p) => p.toLowerCase().startsWith('mailto:'))
        .toList();
    final c = client ?? http.Client();
    if (m.listUnsubPost && https.isNotEmpty) {
      try {
        final r = await c
            .post(
              Uri.parse(https.first),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'List-Unsubscribe=One-Click',
            )
            .timeout(const Duration(seconds: 20));
        if (r.statusCode >= 200 && r.statusCode < 400) {
          await Db.i.addUnsub(a.id!, m.fromAddr, m.fromName, 'one-click');
          return UnsubResult.done;
        }
      } catch (_) {}
    }
    if (mail.isNotEmpty) {
      try {
        final uri = Uri.parse(mail.first);
        final to = uri.path;
        final subject = uri.queryParameters['subject'] ?? 'unsubscribe';
        final body = uri.queryParameters['body'] ?? 'unsubscribe';
        await Backends.of(a).send(
          Outgoing(
            accountId: a.id!,
            fromAddress: a.address,
            fromName: a.displaySender,
            to: [to],
            subject: subject,
            text: body,
          ),
        );
        await Db.i.addUnsub(a.id!, m.fromAddr, m.fromName, 'mailto');
        return UnsubResult.mailSent;
      } catch (e) {
        lastError = '$e';
      }
    }
    if (https.isNotEmpty) {
      linkOut(https.first);
      await Db.i.addUnsub(a.id!, m.fromAddr, m.fromName, 'link');
      return UnsubResult.openedLink;
    }
    return UnsubResult.failed;
  }

  // ---------- invio ----------

  /// Cosa è rimasto da dire dopo l'ultimo invio riuscito (per esempio la copia in «Inviata» non salvata).
  static String? lastSendWarning;

  static Future<void> send(Outgoing o) async {
    final a = await Db.i.account(o.accountId);
    if (a == null) throw StateError('Casella non trovata.');
    final b = Backends.of(a);
    if (a.bccSelf && !o.bcc.contains(a.address)) o.bcc = [...o.bcc, a.address];
    SendNotes.warning = null;
    await b.send(o);
    lastSendWarning = SendNotes.warning;
    final orig = o.inReplyTo ?? '';
    if (orig.isNotEmpty) {
      try {
        for (final m in await Db.i.markAnsweredByMessageId(a.id!, orig)) {
          await b.setAnswered(m.folder, [m.uid]);
        }
      } catch (_) {}
    }
    for (final r in [...o.to, ...o.cc, ...o.bcc]) {
      if (r.toLowerCase() != a.address.toLowerCase())
        await Db.i.touchContact(r, '');
    }
  }

  /// Suono a invio riuscito, se l'utente lo vuole.
  static void playSent() => _sentSound();

  static void _sentSound() {
    if (!Settings.i.sendSound) return;
    try {
      SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  /// Mette l'email in coda per l'orario [at]. Serve sia per «Programma» sia per i secondi di «Annulla».
  static Future<int> queueSend(
    Account a,
    Outgoing o,
    DateTime at, {
    Map<String, Object?>? compose,
  }) async {
    // Gli allegati si copiano in una cartella dell'app: quelli scelti con il selettore
    // stanno nella cartella temporanea, che Android può svuotare prima dell'orario.
    o.attachmentPaths = await keepFiles(
      o.attachmentPaths,
      'q${DateTime.now().microsecondsSinceEpoch}',
    );
    final payload = {...o.toJson(), if (compose != null) 'compose': compose};
    final id = await Db.i.addScheduled(a.id!, at, jsonEncode(payload));
    await NasPush.wakeAt(at);
    return id;
  }

  /// Toglie dalla coda un invio non ancora partito. False se è già partito.
  static Future<bool> cancelQueued(int id) async {
    final row = await Db.i.scheduledById(id);
    final st = row?['status'];
    if (row == null || st == 'sending' || st == 'sent') return false;
    await Db.i.setScheduledStatus(id, 'cancelled');
    return true;
  }

  /// Invia gli invii in coda arrivati a scadenza. Senza rete restano in coda e riprovano al giro dopo.
  static Future<int> processScheduled() async {
    await cleanOutbox();
    await Db.i.releaseStaleEditing();
    for (final row in await Db.i.staleSending()) {
      await Notify.showInfo(
        'Invio interrotto',
        'Un invio è rimasto a metà (app chiusa): controlla in «Inviata» e, se manca, riprova da «Programmati».',
        id: 800000100 + (row['id'] as int),
        payload: 'scheduled',
      );
    }
    final due = await Db.i.dueScheduled();
    var n = 0;
    for (final row in due) {
      final id = row['id'] as int;
      if (!await Db.i.claimScheduled(id)) continue;
      try {
        final o = Outgoing.fromJson(
          jsonDecode(row['payload'] as String) as Map<String, dynamic>,
        );
        await send(o);
        await Db.i.setScheduledStatus(id, 'sent');
        await dropFiles(o.attachmentPaths);
        _sentSound();
        final w = lastSendWarning;
        if (w != null) {
          await Notify.showInfo('Email inviata', w, id: 800000100 + id);
        }
        n++;
      } catch (e) {
        lastError = '$e';
        if (isNetworkError(e)) {
          await Db.i.setScheduledStatus(id, 'pending');
          final late =
              DateTime.now().millisecondsSinceEpoch - (row['send_at'] as int) >
              15 * 60 * 1000;
          if (late)
            await Notify.showInfo(
              'Email in attesa di rete',
              'Un\'email non è ancora partita: parte appena torna la connessione.',
              id: 800000100 + id,
            );
        } else {
          await Db.i.setScheduledStatus(id, 'failed');
          await Notify.showInfo(
            'Invio non riuscito',
            '${friendlyError(e)} Apri «Programmati» per riprovare.',
            id: 800000100 + id,
            payload: 'scheduled',
          );
        }
      }
    }
    return n;
  }

  // ---------- allegati in coda ----------

  /// Copia gli allegati in `outbox/<nome>/<n>/<file>` nella memoria dell'app. Se la copia non
  /// riesce restano i percorsi di prima (l'invio dirà chiaro se un file manca).
  static Future<List<String>> keepFiles(List<String> paths, String name) async {
    if (paths.isEmpty) return paths;
    try {
      final base = await getApplicationSupportDirectory();
      final out = <String>[];
      for (var i = 0; i < paths.length; i++) {
        final p = paths[i];
        if (p.replaceAll('\\', '/').contains('/outbox/')) {
          out.add(p);
          continue;
        }
        final file = p.split(RegExp(r'[\\/]')).last;
        final dir = Directory('${base.path}/outbox/$name/$i');
        await dir.create(recursive: true);
        await File(p).copy('${dir.path}/$file');
        out.add('${dir.path}/$file');
      }
      return out;
    } catch (_) {
      return paths;
    }
  }

  /// Toglie le copie degli allegati di un invio partito.
  static Future<void> dropFiles(List<String> paths) async {
    for (final p in paths) {
      final q = p.replaceAll('\\', '/');
      if (!q.contains('/outbox/')) continue;
      try {
        final f = File(p);
        final slot = f.parent; // outbox/<nome>/<n>
        final job = slot.parent; // outbox/<nome>
        if (await f.exists()) await f.delete();
        if (await slot.exists() && (await slot.list().isEmpty)) {
          await slot.delete();
        }
        if (await job.exists() && (await job.list().isEmpty)) {
          await job.delete();
        }
      } catch (_) {}
    }
  }

  static DateTime _lastClean = DateTime.fromMillisecondsSinceEpoch(0);

  /// Una volta al giorno toglie le copie rimaste (invii annullati) che nessun invio in coda usa più.
  static Future<void> cleanOutbox() async {
    if (DateTime.now().difference(_lastClean).inHours < 24) return;
    _lastClean = DateTime.now();
    try {
      final base = await getApplicationSupportDirectory();
      final root = Directory('${base.path}/outbox');
      if (!await root.exists()) return;
      final usate = <String>{};
      for (final r in await Db.i.scheduledList()) {
        usate.add('${r['payload']}');
      }
      final testo = usate.join('\n').replaceAll('\\\\', '/');
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final age = DateTime.now().difference((await e.stat()).modified);
        final nome = e.path.replaceAll('\\', '/').split('/').last;
        // Gli allegati di un inoltro servono finché Scrivi è aperto o la bozza è in sospeso.
        final limite = nome.startsWith('fwd') ? 24 * 7 : 24;
        if (age.inHours >= limite && !testo.contains('/outbox/$nome/')) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  /// Scarica gli allegati di un'email per inoltrarli.
  static Future<List<String>> forwardFiles(Account a, Msg m) async {
    if (!m.hasAtt) return [];
    final b = Backends.of(a);
    final base = await getApplicationSupportDirectory();
    final job = 'fwd${m.accountId}_${m.uid}_${DateTime.now().microsecondsSinceEpoch}';
    final out = <String>[];
    final list = await b.attachments(m);
    for (var i = 0; i < list.length; i++) {
      final bytes = await b.downloadAttachment(m, list[i]);
      final dir = Directory('${base.path}/outbox/$job/$i');
      await dir.create(recursive: true);
      final f = File('${dir.path}/${list[i].name}');
      await f.writeAsBytes(bytes);
      out.add(f.path);
    }
    return out;
  }

  // ---------- sicurezza ----------

  /// Se il server ha segnalato che l'autenticazione del mittente è fallita.
  static String? suspicion(Msg m) {
    if (!Settings.i.warnSuspicious) return null;
    final r = m.authResults.toLowerCase();
    if (r.isEmpty) return null;
    final bad = <String>[];
    if (RegExp(r'dmarc=(fail|reject|quarantine)').hasMatch(r)) bad.add('DMARC');
    if (RegExp(r'spf=(fail|softfail)').hasMatch(r)) bad.add('SPF');
    if (RegExp(r'dkim=(fail|permerror)').hasMatch(r)) bad.add('DKIM');
    if (bad.isEmpty) return null;
    return 'Attenzione: il server ha segnalato che questo mittente potrebbe non essere chi dice di essere (controllo ${bad.join(', ')} fallito).';
  }

  static final _trackerHosts = RegExp(
    // «click.» e «links.» non ci sono più: sono i domini da cui molte newsletter servono le
    // immagini vere, non pixel spia (sparivano loghi e foto).
    r'(doubleclick|googleadservices|mailchimp\.com/track|list-manage\.com/track|sendgrid\.net/(wf|trk)|mandrillapp\.com/track|hubspot(email)?\.com|hs-analytics|mixpanel|segment\.io|pixel\.|/pixel|/track(ing)?/|open\.gif|/open\?|beacon|emltrk|mailtrack|bl\.io|ct\.sendgrid|e\.customeriomail|t\.sidekickopen|sp\.mail)',
    caseSensitive: false,
  );

  /// Toglie dall'HTML i pixel spia e, se richiesto, tutte le immagini remote.
  static ({String html, int blocked}) cleanHtml(
    String html, {
    required bool blockImages,
    required bool blockTracking,
  }) {
    var blocked = 0;
    final out = html.replaceAllMapped(
      RegExp(r'<img\b[^>]*>', caseSensitive: false, dotAll: true),
      (m) {
        final tag = m.group(0)!;
        final src =
            RegExp(
              r'''src\s*=\s*["']?([^"'\s>]+)''',
              caseSensitive: false,
            ).firstMatch(tag)?.group(1) ??
            '';
        final isRemote = src.toLowerCase().startsWith('http');
        if (!isRemote) return tag;
        final tiny =
            RegExp(
              r'''(width|height)\s*=\s*["']?\s*[01]\s*(px)?["']?[\s/>]''',
              caseSensitive: false,
            ).hasMatch(tag) ||
            RegExp(
              r'width\s*:\s*[01]px|height\s*:\s*[01]px',
              caseSensitive: false,
            ).hasMatch(tag);
        if (blockTracking && (tiny || _trackerHosts.hasMatch(src))) {
          blocked++;
          return '';
        }
        if (blockImages) {
          blocked++;
          return '';
        }
        return tag;
      },
    );
    return (html: out, blocked: blocked);
  }

  /// Citazione per risposte e inoltri.
  static String quote(Msg m, String body) {
    final when =
        '${m.date.day.toString().padLeft(2, '0')}/${m.date.month.toString().padLeft(2, '0')}/${m.date.year} ${m.date.hour.toString().padLeft(2, '0')}:${m.date.minute.toString().padLeft(2, '0')}';
    final lines = body.trim().split('\n').map((l) => '> $l').join('\n');
    return '\n\nIl $when ${m.sender} ha scritto:\n$lines';
  }

  /// Quando far ricomparire un'email rimandata, per le scelte rapide.
  static DateTime snoozeAt(String choice, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final s = Settings.i;
    switch (choice) {
      case 'later':
        return n.add(Duration(hours: s.snoozeLaterHours));
      case 'evening':
        final t = DateTime(n.year, n.month, n.day, s.snoozeEveningHour);
        return t.isAfter(n) ? t : t.add(const Duration(days: 1));
      case 'tomorrow':
        final d = n.add(const Duration(days: 1));
        return DateTime(d.year, d.month, d.day, s.snoozeMorningHour);
      case 'weekend':
        var d = n;
        while (d.weekday != DateTime.saturday) {
          d = d.add(const Duration(days: 1));
        }
        final t = DateTime(d.year, d.month, d.day, s.snoozeMorningHour);
        // Sabato dopo quell'ora: il prossimo sabato, se no l'email tornerebbe subito.
        return t.isAfter(n) ? t : t.add(const Duration(days: 7));
      case 'nextweek':
        var d = n.add(const Duration(days: 1));
        while (d.weekday != DateTime.monday) {
          d = d.add(const Duration(days: 1));
        }
        return DateTime(d.year, d.month, d.day, s.snoozeMorningHour);
      default:
        return n.add(const Duration(hours: 1));
    }
  }
}
