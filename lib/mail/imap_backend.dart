import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../db.dart';
import '../models.dart';
import '../settings.dart';
import '../signature.dart';
import 'backend.dart';
import 'ms_oauth.dart';
import 'secrets.dart';

/// Il Message-ID senza virgolette e barre, che romperebbero la ricerca sul server.
String idPerRicerca(String id) => id.replaceAll(RegExp(r'["\\]'), '');

String _roleOf(em.Mailbox b) {
  if (b.isInbox) return 'inbox';
  if (b.isSent) return 'sent';
  if (b.isDrafts) return 'drafts';
  if (b.isTrash) return 'trash';
  if (b.isJunk) return 'junk';
  if (b.isArchive || b.flags.contains(em.MailboxFlag.all)) return 'archive';
  return 'other';
}

String _plainFromHtml(String html) => html
    .replaceAll(
      RegExp(
        r'<(style|script)[^>]*>.*?</\1>',
        dotAll: true,
        caseSensitive: false,
      ),
      ' ',
    )
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _preview(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 240 ? t.substring(0, 240) : t;
}

/// Trasforma un messaggio enough_mail in una riga di cache.
Msg msgFromMime(int accountId, String folder, em.MimeMessage m) {
  final from = (m.from != null && m.from!.isNotEmpty) ? m.from!.first : null;
  String text = '';
  try {
    text = m.decodeTextPlainPart() ?? '';
    if (text.trim().isEmpty) {
      final h = m.decodeTextHtmlPart();
      if (h != null) text = _plainFromHtml(h);
    }
  } catch (_) {}
  final unsub = m.getHeaderValue('list-unsubscribe') ?? '';
  final unsubPost = (m.getHeaderValue('list-unsubscribe-post') ?? '')
      .toLowerCase()
      .contains('one-click');
  return Msg(
    accountId: accountId,
    folder: folder,
    uid: m.uid ?? 0,
    messageId: m.getHeaderValue('message-id') ?? '',
    fromName: from?.personalName ?? '',
    fromAddr: from?.email ?? '',
    toAddrs: (m.to ?? []).map((a) => a.email).join(', '),
    ccAddrs: (m.cc ?? []).map((a) => a.email).join(', '),
    subject: m.decodeSubject() ?? '',
    // Senza intestazione Date: la data di arrivo sul server, se no risaliva in cima a ogni aggiornamento.
    date: m.decodeDate() ??
        (m.internalDate == null ? null : em.DateCodec.decodeDate(m.internalDate!)) ??
        DateTime.now(),
    preview: _preview(text),
    seen: m.isSeen,
    flagged: m.isFlagged,
    answered: m.isAnswered,
    hasAtt: attachmentInfos(m).isNotEmpty,
    listUnsub: unsub,
    listUnsubPost: unsubPost,
    authResults: m.getHeaderValue('authentication-results') ?? '',
    replyTo: _replyToOf(m),
    refs: (m.getHeaderValue('references') ?? '').replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
}

/// L'indirizzo a cui va la risposta, se il mittente ne indica uno diverso da «Da» (Reply-To).
String _replyToOf(em.MimeMessage m) {
  try {
    final r = m.replyTo;
    if (r == null || r.isEmpty) return '';
    final from = (m.from != null && m.from!.isNotEmpty) ? m.from!.first.email.toLowerCase() : '';
    final a = r.first.email.trim();
    return a.toLowerCase() == from ? '' : a;
  } catch (_) {
    return '';
  }
}

/// Gli allegati come li mostra Edison: ogni parte con un nome di file,
/// sia «attachment» sia «inline» sia senza marcatura, tranne le immagini
/// richiamate dentro il testo (cid). Vale sia per l'email intera sia per la
/// sola struttura (BODYSTRUCTURE).
List<em.ContentInfo> attachmentInfos(em.MimeMessage m) {
  final all = <em.ContentInfo>[];
  try {
    final body = m.body;
    if (body != null) {
      body.collectContentInfo(em.ContentDisposition.attachment, all);
      body.collectContentInfo(
        em.ContentDisposition.attachment,
        all,
        reverse: true,
      );
    } else {
      m.collectContentInfo(em.ContentDisposition.attachment, all, null);
      m.collectContentInfo(
        em.ContentDisposition.attachment,
        all,
        null,
        reverse: true,
      );
    }
  } catch (_) {}
  final seen = <String>{};
  final out = <em.ContentInfo>[];
  for (final i in all) {
    final name = (i.fileName ?? '').trim();
    final isAtt =
        i.contentDisposition?.disposition == em.ContentDisposition.attachment;
    if (name.isEmpty && !isAtt) continue;
    if (i.mediaType?.top == em.MediaToptype.multipart) continue;
    if (!isAtt && i.isImage && (i.cid ?? '').isNotEmpty) continue;
    if (i.fetchId.isEmpty || !seen.add(i.fetchId)) continue;
    out.add(i);
  }
  return out;
}

class ImapBackend implements MailBackend {
  @override
  final Account account;
  em.MailClient? _client;
  Future<em.MailClient>? _connecting;
  List<em.Mailbox> _boxes = [];
  StreamSubscription? _subLoad, _subLost, _subBack;
  void Function(String)? _onNew;
  void Function(Object)? _onError;
  bool _listening = false;

  ImapBackend(this.account);

  Future<em.MailAccount> _buildAccount() async {
    final a = account;
    final inType = a.imapSsl ? em.SocketType.ssl : em.SocketType.starttls;
    final outType = a.smtpSsl ? em.SocketType.ssl : em.SocketType.starttls;
    if (a.authType == 'oauth_ms') {
      final raw = await Secrets.msToken(a.id!);
      if (raw == null)
        throw StateError(
          'Accesso Microsoft mancante: rifai l\'accesso dalle impostazioni della casella.',
        );
      final auth = em.OauthAuthentication.from(
        a.address,
        raw,
        provider: 'microsoft',
      );
      return em.MailAccount.fromManualSettingsWithAuth(
        name: a.name,
        email: a.address,
        incomingHost: a.imapHost,
        outgoingHost: a.smtpHost,
        auth: auth,
        incomingPort: a.imapPort,
        outgoingPort: a.smtpPort,
        incomingSocketType: inType,
        outgoingSocketType: outType,
      );
    }
    final pw = await Secrets.password(a.id!);
    if (pw == null) throw StateError('Password mancante per ${a.address}.');
    return em.MailAccount.fromManualSettings(
      name: a.name,
      email: a.address,
      incomingHost: a.imapHost,
      outgoingHost: a.smtpHost,
      password: pw,
      loginName: a.login,
      incomingPort: a.imapPort,
      outgoingPort: a.smtpPort,
      incomingSocketType: inType,
      outgoingSocketType: outType,
    );
  }

  DateTime _lastUse = DateTime.fromMillisecondsSinceEpoch(0);

  /// Dopo una pausa la connessione può essere morta senza che il telefono se ne accorga
  /// (Wi-Fi in sospensione): la prima richiesta aspettava due timeout da 25 secondi.
  /// Se è ferma da più di 20 secondi, prima si fa un controllo veloce; se non risponde,
  /// si ricollega subito.
  Future<em.MailClient> _c() async {
    final c = _client;
    if (c != null && c.isConnected) {
      final ferma = DateTime.now().difference(_lastUse);
      // Oltre 60 secondi Android ha già congelato l'app (circa 70 s dopo il secondo piano)
      // e la connessione è sempre morta: si ricollega subito, senza aspettare il controllo.
      if (!_listening && ferma > const Duration(seconds: 60)) {
        print('DIGIMAIL-T pausa lunga: ricollego senza noop');
        _chiudiVecchia(c);
        return _connecting ??= _connect().whenComplete(() {
          _connecting = null;
          _lastUse = DateTime.now();
        });
      }
      if (!_listening && ferma > const Duration(seconds: 20)) {
        final t = Stopwatch()..start();
        try {
          await (c.lowLevelIncomingMailClient as em.ImapClient).noop().timeout(
            const Duration(seconds: 1),
          );
          print('DIGIMAIL-T noop ok ${t.elapsedMilliseconds}ms');
        } catch (_) {
          print('DIGIMAIL-T noop KO ${t.elapsedMilliseconds}ms: ricollego');
          _chiudiVecchia(c);
          return _connecting ??= _connect().whenComplete(() {
            _connecting = null;
            _lastUse = DateTime.now();
          });
        }
      }
      _lastUse = DateTime.now();
      return c;
    }
    final r = await (_connecting ??= _connect().whenComplete(
      () => _connecting = null,
    ));
    _lastUse = DateTime.now();
    return r;
  }

  /// Toglie la connessione morta e la chiude in disparte: se si metteva solo `_client = null`
  /// il socket restava aperto sul server fino al suo timeout (una connessione persa a ogni pausa lunga).
  /// Il `disconnect()` della libreria aspetta il suo turno dietro alla richiesta in corso: se quella
  /// è appesa su una connessione morta non arriva mai. La presa IMAP si chiude a mano, subito.
  void _chiudiVecchia(em.MailClient c) {
    if (identical(_client, c)) _client = null;
    try {
      c.lowLevelIncomingMailClient.disconnect().catchError((Object _) {});
    } catch (_) {}
    c.disconnect().catchError((Object _) {});
  }

  /// Oltre questo tempo una connessione nuova si considera fallita. Il limite della libreria
  /// copre solo l'apertura della presa: se poi il server non saluta (rete a metà dopo una
  /// pausa) l'attesa non finiva mai.
  static const _limiteConnessione = Duration(seconds: 45);

  Future<em.MailClient> _connect() async {
    final epoca = _epoca;
    final vecchio = _client;
    if (vecchio != null) _chiudiVecchia(vecchio);
    final acc = await _buildAccount();
    final client = em.MailClient(
      acc,
      isLogEnabled: false,
      // Le email nuove arrivano intere fino a questa grandezza: così l'anteprima della
      // notifica ha subito il testo, anche con il logo della firma (oltre 1 MB no).
      downloadSizeLimit: 1024 * 1024,
      defaultResponseTimeout: const Duration(seconds: 25),
      refresh: account.authType == 'oauth_ms'
          ? (c, expired) async {
              final id = Settings.i.msClientId;
              final text = await MsOAuth(id).refresh(expired.refreshToken);
              await Secrets.setMsToken(account.id!, text);
              return em.OauthToken.fromText(text, provider: 'microsoft');
            }
          : null,
      // Niente `onConfigChanged`: la libreria lì passa il token col rinnovo vecchio, che
      // sovrascriveva quello nuovo salvato qui sopra. Dopo 90 giorni si doveva rifare l'accesso.
    );
    final _t0 = DateTime.now();
    try {
      await client.connect().timeout(_limiteConnessione);
    } on TimeoutException {
      print('DIGIMAIL-T connect appeso oltre ${_limiteConnessione.inSeconds}s: chiudo');
      try {
        client.lowLevelIncomingMailClient.disconnect().catchError((Object _) {});
      } catch (_) {}
      rethrow;
    }
    // Da qui il client è collegato: se qualcosa va storto si chiude, se no resta aperto sul server.
    print('DIGIMAIL-T connect ${DateTime.now().difference(_t0).inMilliseconds}ms');
    try {
      _boxes = await client.listMailboxes();
    } catch (_) {
      _chiudiVecchia(client);
      rethrow;
    }
    print('DIGIMAIL-T listMailboxes ${DateTime.now().difference(_t0).inMilliseconds}ms');
    // Nel frattempo c'è stata una ripresa o la casella è stata tolta: questa non serve più.
    if (epoca != _epoca) {
      _chiudiVecchia(client);
      throw StateError('Connessione superata');
    }
    _client = client;
    if (_listening) _attachEvents(client);
    return client;
  }

  em.Mailbox? _box(String path) {
    for (final b in _boxes) {
      if (b.path == path) return b;
    }
    return null;
  }

  em.Mailbox? _byRole(String role) {
    for (final b in _boxes) {
      if (_roleOf(b) == role) return b;
    }
    if (role == 'archive') {
      // Gmail non ha «Archivio»: archiviare = spostare in «Tutti i messaggi».
      for (final b in _boxes) {
        final n = b.path.toLowerCase();
        if (b.flags.contains(em.MailboxFlag.all) ||
            n.endsWith('/all mail') ||
            n.endsWith('/tutti i messaggi') ||
            n.contains('archiv')) {
          return b;
        }
      }
    }
    return null;
  }

  em.MessageSequence _seq(List<int> uids) =>
      em.MessageSequence.fromIds(uids, isUid: true);

  @override
  Future<List<Folder>> folders() async {
    await _c();
    return _boxes
        .where((b) => !b.isNotSelectable)
        .map(
          (b) => Folder(
            b.path,
            b.name,
            _roleOf(b),
            unseen: b.messagesUnseen,
            sep: b.pathSeparator,
          ),
        )
        .toList();
  }

  Future<void> _tail = Future.value();

  /// Cresce a ogni [riparti]: le richieste nate prima appartengono a una connessione buttata.
  int _epoca = 0;

  /// Una sola richiesta alla volta che sceglie una cartella: la connessione è una sola e
  /// la cartella scelta vale per tutti. Senza, due richieste insieme si rubano la
  /// cartella («No mailbox selected») o scaricano quella sbagliata.
  Future<T> _serial<T>(Future<T> Function() f) {
    final epoca = _epoca;
    final r = _tail.then((_) {
      // Il suo turno arriva dopo una ripresa: la coda in cui aspettava era quella della
      // connessione vecchia, si rimette in coda su quella nuova invece di partire fuori fila.
      if (epoca != _epoca) return _serial(f);
      return f();
    });
    _tail = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  /// Alla riapertura dopo una pausa lunga la connessione è morta e una richiesta rimasta
  /// appesa su di lei terrebbe in coda tutte le nuove finché il suo tempo non scade (fino a
  /// due minuti di rotella). Si butta la connessione e la coda riparte subito su quella
  /// nuova; la richiesta appesa, quando scade, si rimette in coda da sola ([_retry]).
  @override
  void riparti() {
    _epoca++;
    _connecting = null;
    final c = _client;
    if (c != null) _chiudiVecchia(c);
    _tail = Future.value();
  }

  /// Limite di tempo di una richiesta in coda. Ogni richiesta della libreria ha il suo, tranne
  /// lo scaricamento di un corpo intero (`FetchPreference.full`): se la connessione moriva
  /// a metà (telefono a riposo, Wi-Fi caduto) quella richiesta restava appesa per sempre e,
  /// con lei, tutte quelle in coda dietro: alla riapertura l'app caricava all'infinito e poi
  /// «Il server non risponde in tempo», finché non la si chiudeva. Il corpo ha un limite suo,
  /// più corto; gli altri uno di sicurezza sopra il massimo della libreria (120 s).
  static Duration limiteRichiesta = const Duration(seconds: 150);
  static Duration limiteCorpo = const Duration(seconds: 45);

  /// Se una richiesta fallisce (connessione morta, cartella persa) o supera [limite], si butta
  /// la connessione e si riprova una volta da zero: l'errore arriva all'utente solo se fallisce
  /// anche la seconda. Dopo un secondo scaduto la connessione si butta lo stesso: la richiesta
  /// appesa tiene bloccata la libreria e la prossima richiesta ci resterebbe dietro.
  Future<T> _retry<T>(Future<T> Function() f, {Duration? limite}) async {
    final lim = limite ?? limiteRichiesta;
    final epoca = _epoca;
    try {
      return await f().timeout(lim);
    } catch (_) {
      // Nel frattempo c'è stata una ripresa ([riparti]): questa richiesta era sulla connessione
      // vecchia. Non si butta quella nuova, la richiesta si rifà in coda su di essa.
      if (epoca != _epoca) return _serial(() => _retry(f, limite: limite));
      final old = _client;
      if (old != null) _chiudiVecchia(old);
      try {
        return await f().timeout(lim);
      } on TimeoutException {
        final morto = _client;
        if (morto != null && epoca == _epoca) _chiudiVecchia(morto);
        rethrow;
      }
    }
  }

  /// Le azioni sulle email (elimina, sposta, letta, stella) passano dalla stessa coda delle
  /// sincronizzazioni: scelgono una cartella sull'unica connessione e, fuori fila, un avviso
  /// del NAS in arrivo nello stesso momento poteva far spostare o scaricare la cartella
  /// sbagliata. Non si ripetono da sole come [_retry]: uno spostamento fatto due volte non
  /// è la stessa cosa. Se non riescono decide [Ops] (coda delle operazioni).
  ///
  /// Lo spostamento della libreria non ha un limite di tempo suo: su una connessione morta
  /// resterebbe appeso per sempre, con la libreria bloccata. Scaduto il limite si chiude la
  /// connessione e l'errore fa finire l'operazione in coda.
  static Duration limiteAzione = const Duration(seconds: 30);

  Future<T> _azione<T>(Future<T> Function() f) => _serial(() async {
    final epoca = _epoca;
    try {
      return await f().timeout(limiteAzione);
    } on TimeoutException {
      // Dopo una ripresa ([riparti]) la connessione di adesso è quella nuova: non si tocca.
      final morto = _client;
      if (morto != null && epoca == _epoca) _chiudiVecchia(morto);
      rethrow;
    }
  });

  @override
  Future<List<Msg>> sync(String folder, {int count = 40}) => _serial(
    () => _senzaAscolto(() => _retry(() => _sync(folder, count: count))),
  );

  /// Le richieste a basso livello di [_sync] finirebbero in fila dietro all'ascolto (IDLE), che
  /// libera il posto solo dopo minuti: la richiesta scadeva, la connessione veniva buttata e
  /// l'ascolto non ripartiva più, mentre lo stato diceva «in ascolto». Si ferma e si rifà.
  Future<T> _senzaAscolto<T>(Future<T> Function() f) async {
    if (!_listening) return f();
    try {
      await _client?.stopPolling().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      return await f();
    } finally {
      if (_listening) {
        try {
          final c = await _c();
          final inbox = _byRole('inbox');
          if (inbox != null) await c.selectMailbox(inbox);
          _attachEvents(c);
          await c.startPolling();
        } catch (e) {
          _onError?.call(e);
        }
      }
    }
  }

  /// Cresce a ogni sincronizzazione. Una scaduta continua in sottofondo: quando arriva la sua
  /// risposta non deve più scrivere nel database dati vecchi sopra quelli nuovi.
  int _giroSync = 0;

  Future<List<Msg>> _sync(String folder, {int count = 40}) async {
    final giro = ++_giroSync;
    final _s = Stopwatch()..start();
    final c = await _c();
    print('DIGIMAIL-T sync $folder client ${_s.elapsedMilliseconds}ms');
    final box = _box(folder);
    if (box == null) return [];
    final sel = await c.selectMailbox(box);
    print('DIGIMAIL-T sync $folder select ${_s.elapsedMilliseconds}ms');
    final db = Db.i;
    final accId = account.id!;
    final isInbox = folder.toUpperCase() == 'INBOX';
    final validity = sel.uidValidity ?? 0;
    final next = sel.uidNext;
    // Dove era arrivata l'ultima sincronizzazione di questa cartella. Se il server
    // ha rinumerato le email (UIDVALIDITY diverso) la copia locale non vale più.
    var st = await db.folderSync(accId, folder);
    if (st != null &&
        st.validity != 0 &&
        validity != 0 &&
        st.validity != validity) {
      await db.dropFolderCache(accId, folder);
      st = null;
    }
    if (sel.messagesExists == 0) {
      await db.pruneFolder(accId, folder, 0, {});
      // Anche con la cartella vuota si ricorda fin dove si è arrivati: la prima email
      // che arriva dopo è nuova e deve suonare.
      final last = st?.lastUid ?? 0;
      final up = next != null && next - 1 > last ? next - 1 : last;
      await db.setFolderSync(accId, folder, validity, up);
      return [];
    }
    final lastUid = st?.lastUid ?? 0;
    final fresh = <Msg>[];
    final all = <Msg>[];
    if (st == null) {
      // Prima volta: si scarica lo storico senza avvisare di niente.
      final list = await c.fetchMessages(
        mailbox: sel,
        count: count,
        fetchPreference: em.FetchPreference.fullWhenWithinSize,
      );
      var top = next != null ? next - 1 : 0;
      for (final m in list) {
        if (m.uid == null) continue;
        all.add(msgFromMime(accId, folder, m));
        if (m.uid! > top) top = m.uid!;
      }
      await db.upsertMessages(all);
      await db.setFolderSync(accId, folder, validity, top);
      return [];
    }
    if (next != null && next > lastUid + 1) {
      final seq = em.MessageSequence.fromRangeToLast(
        lastUid + 1,
        isUidSequence: true,
      );
      final list = await c.fetchMessageSequence(
        seq,
        mailbox: sel,
        fetchPreference: em.FetchPreference.fullWhenWithinSize,
      );
      for (final m in list) {
        if (m.uid == null) continue;
        all.add(msgFromMime(accId, folder, m));
      }
    }
    if (sel.messagesExists == 0) {
      await db.pruneFolder(accId, folder, 0, {});
      await db.setFolderSync(accId, folder, validity, lastUid);
      return [];
    }
    // Busta (mittente, oggetto, data) e struttura (allegati) nella stessa
    // richiesta: con la sola struttura il server non manda mittente e oggetto.
    print('DIGIMAIL-T sync $folder fetchSeq ${_s.elapsedMilliseconds}ms');
    final imap = c.lowLevelIncomingMailClient as em.ImapClient;
    // Se la connessione è stata rifatta nel frattempo, la cartella va scelta di nuovo.
    await c.selectMailbox(box);
    final recent = (await imap.fetchRecentMessages(
      messageCount: 60,
      criteria: '(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)',
      responseTimeout: const Duration(seconds: 60),
    )).messages;
    print('DIGIMAIL-T sync $folder recent ${_s.elapsedMilliseconds}ms');
    final keep = <int>{};
    var minUid = 1 << 30;
    for (final m in recent) {
      if (m.uid == null) continue;
      keep.add(m.uid!);
      if (m.uid! < minUid) minUid = m.uid!;
      if (!all.any((x) => x.uid == m.uid))
        all.add(msgFromMime(account.id!, folder, m));
    }
    // «Nuova» = numero più alto dell'ultimo già visto, da qualunque delle due richieste
    // sia arrivata: un'email che entra fra l'una e l'altra non si perde più.
    var top = lastUid;
    if (next != null && next - 1 > top) top = next - 1;
    for (final m in all) {
      if (m.uid > top) top = m.uid;
      if (m.uid > lastUid) fresh.add(m);
    }
    // Una email spostata qui da un'altra cartella (per esempio dallo Spam) non è arrivata ora.
    // Anche quelle che il server mette da solo in Spam o nel Cestino vanno avvisate, a meno
    // che le abbia spostate l'app (cancellate o segnate come spam dall'utente o da una regola).
    // Email che l'app sta togliendo da questa cartella: il server può averla ancora, ma non
    // deve tornare in lista né contare come nuova (Db.inVolo).
    all.removeWhere((m) => db.inVolo(accId, folder, m.uid));
    fresh.removeWhere((m) => db.inVolo(accId, folder, m.uid));
    final role = _roleOf(box);
    final alsoJunk = role == 'junk' || role == 'trash';
    if (alsoJunk) await db.setFolderRole(accId, folder, role);
    final pending = <int>{};
    if (isInbox || alsoJunk) {
      for (final m in fresh) {
        if (!m.seen &&
            !await db.seenElsewhere(accId, folder, m.messageId) &&
            !await db.wasMoved(accId, m.messageId)) {
          pending.add(m.uid);
        }
      }
    }
    if (giro != _giroSync) return [];
    await db.upsertMessages(all, pending: pending);
    // Quello che è ancora in coda vale più di ciò che dice il server, che non lo sa ancora.
    await db.riapplicaCoda(accId, folder);
    await db.setFolderSync(accId, folder, validity, top);
    final isSent = box.isSent;
    for (final m in all) {
      if (isSent) {
        for (final r in m.toAddrs.split(',')) {
          await db.learnContact(r.trim(), '');
        }
      } else if (m.fromAddr.isNotEmpty) {
        await db.learnContact(m.fromAddr, m.fromName);
      }
    }
    for (final f in fresh) {
      keep.add(f.uid);
    }
    if (recent.isNotEmpty && sel.messagesExists > 0) {
      await db.pruneFolder(accId, folder, minUid, keep);
      await _reconcileOlder(imap, accId, folder, minUid);
    }
    print('DIGIMAIL-T sync $folder fine ${_s.elapsedMilliseconds}ms');
    return fresh;
  }

  final Map<String, DateTime> _deepAt = {};

  /// Le email più vecchie delle ultime 60 (quelle scaricate scorrendo l'elenco) non
  /// venivano mai più controllate: cancellate, lette o spostate dal PC restavano uguali.
  /// Ogni 10 minuti per cartella si chiedono al server solo i segni (letto, stella,
  /// risposto) di quelle che il telefono ha in copia, e si allinea. Un errore qui non
  /// ferma la sincronizzazione.
  Future<void> _reconcileOlder(
    em.ImapClient imap,
    int accId,
    String folder,
    int belowUid,
  ) async {
    final last = _deepAt[folder];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    try {
      // Solo le email che il telefono ha in copia: con la gamma intera il server mandava anche
      // 30 000 righe ogni 10 minuti.
      final uids = await Db.i.cachedUidsBelow(accId, folder, belowUid);
      if (uids.isEmpty) {
        _deepAt[folder] = DateTime.now();
        return;
      }
      final res = await imap.uidFetchMessages(
        _seq(uids),
        '(UID FLAGS)',
        responseTimeout: const Duration(seconds: 60),
      );
      final server = <int, ({bool seen, bool flagged, bool answered})>{
        for (final m in res.messages)
          if (m.uid != null)
            m.uid!: (seen: m.isSeen, flagged: m.isFlagged, answered: m.isAnswered),
      };
      // Una risposta vuota non cancella niente: potrebbe essere una risposta illeggibile.
      if (server.isNotEmpty) {
        await Db.i.reconcileOlder(accId, folder, belowUid, server);
      }
      _deepAt[folder] = DateTime.now();
    } catch (_) {}
  }

  @override
  Future<void> loadOlder(String folder, {int count = 40}) =>
      _serial(() => _retry(() => _loadOlder(folder, count: count)));

  Future<void> _loadOlder(String folder, {int count = 40}) async {
    final c = await _c();
    final box = _box(folder);
    if (box == null) return;
    final sel = await c.selectMailbox(box);
    final d = await Db.i.db;
    final have =
        (await d.rawQuery(
              'SELECT COUNT(*) AS n FROM messages WHERE account_id=? AND folder=?',
              [account.id, folder],
            )).first['n']
            as int;
    if (have >= sel.messagesExists) return;
    // Solo quelle che mancano: prima si richiedevano ogni volta anche tutte le già scaricate.
    final fine = sel.messagesExists - have;
    final inizio = fine - count + 1 < 1 ? 1 : fine - count + 1;
    final list = await c.fetchMessageSequence(
      em.MessageSequence.fromRange(inizio, fine),
      mailbox: sel,
      fetchPreference: em.FetchPreference.envelope,
    );
    final msgs = <Msg>[];
    for (final m in list) {
      if (m.uid != null) msgs.add(msgFromMime(account.id!, folder, m));
    }
    await Db.i.upsertMessages(msgs);
  }


  /// L'ultima email scaricata intera: lettura, allegati e inoltro la chiedono più volte di
  /// fila e ogni volta si riscaricavano tutti gli allegati.
  String? _interaChiave;
  em.MimeMessage? _intera;

  Future<em.MimeMessage?> _full(String folder, int uid, {Duration? limite}) {
    final chiave = '$folder|$uid';
    if (_interaChiave == chiave && _intera != null) return Future.value(_intera);
    return _serial(
      () => _retry(() => _fullNow(folder, uid), limite: limite ?? limiteCorpo),
    ).then((m) {
      if (m != null) {
        _interaChiave = chiave;
        _intera = m;
      }
      return m;
    });
  }

  Future<em.MimeMessage?> _strutturaNow(String folder, int uid) async {
    final c = await _c();
    final box = _box(folder);
    if (box == null) return null;
    final sel = await c.selectMailbox(box);
    final list = await c.fetchMessageSequence(
      em.MessageSequence.fromId(uid, isUid: true),
      mailbox: sel,
      fetchPreference: em.FetchPreference.bodystructure,
    );
    return list.isEmpty ? null : list.first;
  }

  Future<em.MimeMessage?> _fullNow(String folder, int uid) async {
    final c = await _c();
    final box = _box(folder);
    if (box == null) return null;
    final sel = await c.selectMailbox(box);
    final list = await c.fetchMessageSequence(
      em.MessageSequence.fromId(uid, isUid: true),
      mailbox: sel,
      fetchPreference: em.FetchPreference.full,
    );
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<Msg> loadBody(Msg m) async {
    // Un corpo già salvato con immagini «cid:» ancora da mettere nel testo si riscarica una volta.
    final cached = m.bodyText != null || m.bodyHtml != null;
    if (cached && !_hasCidImg(m.bodyHtml)) return m;
    final mime = await _full(m.folder, m.uid);
    if (mime == null) {
      if (cached) return m;
      // Se no si vedeva «messaggio vuoto», senza capire perché.
      throw StateError('Questa email non è più sul server.');
    }
    final text = mime.decodeTextPlainPart();
    var html = mime.decodeTextHtmlPart();
    final fresh = msgFromMime(account.id!, m.folder, mime);
    // L'anteprima si assegna subito: la notifica la legge anche se le immagini non si scaricano.
    if (fresh.preview.isNotEmpty) m.preview = fresh.preview;
    if (html != null) {
      try {
        html = await SignatureTools.inlineCid(
          html,
          (cid) async => _cidPart(mime, cid),
        );
      } catch (_) {}
    }
    await Db.i.saveBody(
      account.id!,
      m.folder,
      m.uid,
      text: text ?? '',
      html: html ?? '',
      preview: fresh.preview,
      listUnsub: fresh.listUnsub,
      listUnsubPost: fresh.listUnsubPost,
      authResults: fresh.authResults,
      replyTo: fresh.replyTo,
      refs: fresh.refs,
    );
    m.bodyText = text ?? '';
    m.bodyHtml = html ?? '';
    // La lista non sempre porta il Message-ID: senza, la risposta esce fuori dalla conversazione.
    if (m.messageId.isEmpty && fresh.messageId.isNotEmpty) {
      m.messageId = fresh.messageId;
      await Db.i.setMessageId(account.id!, m.folder, m.uid, fresh.messageId);
    }
    if (fresh.listUnsub.isNotEmpty) {
      m.listUnsub = fresh.listUnsub;
      m.listUnsubPost = fresh.listUnsubPost;
    }
    if (fresh.authResults.isNotEmpty) m.authResults = fresh.authResults;
    if (fresh.replyTo.isNotEmpty) m.replyTo = fresh.replyTo;
    if (fresh.refs.isNotEmpty) m.refs = fresh.refs;
    if (fresh.preview.isNotEmpty) m.preview = fresh.preview;
    return m;
  }

  @override
  Future<List<String>> draftBcc(Msg m) async {
    final mime = await _full(m.folder, m.uid);
    return [
      for (final x in mime?.decodeHeaderMailAddressValue('bcc') ?? const <em.MailAddress>[])
        x.email,
    ];
  }

  @override
  Future<List<AttachmentInfo>> attachments(Msg m) async {
    // Basta la struttura: scaricare l'email intera a ogni apertura costava tutti gli allegati.
    // Se il server non la manda si ripiega sull'email intera.
    var mime = await _serial(
      () => _retry(() => _strutturaNow(m.folder, m.uid), limite: limiteCorpo),
    );
    if (mime == null || mime.body == null) {
      mime = await _full(m.folder, m.uid);
    }
    if (mime == null) return [];
    final infos = attachmentInfos(mime);
    if (infos.isNotEmpty && !m.hasAtt) {
      m.hasAtt = true;
      await Db.i.upsertMessages([msgFromMime(account.id!, m.folder, mime)]);
    }
    return infos
        .map(
          (i) => AttachmentInfo(
            i.fileName ?? 'allegato',
            i.size ?? 0,
            i.fetchId,
            i.mediaType?.text ?? 'application/octet-stream',
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> downloadAttachment(Msg m, AttachmentInfo a) async {
    // Un allegato grande su rete lenta: più tempo di quello concesso per leggere un'email.
    final mime = await _full(m.folder, m.uid, limite: limiteRichiesta);
    if (mime == null) throw StateError('Messaggio non trovato.');
    var data = mime.getPart(a.fetchId)?.decodeContentBinary();
    if (data == null) {
      final part = await _azione(() async {
        final c = await _select(m.folder);
        return c.fetchMessagePart(mime, a.fetchId);
      });
      data = part.decodeContentBinary();
    }
    if (data == null) throw StateError('Allegato vuoto.');
    return data;
  }

  @override
  Future<Uint8List?> inlineImage(Msg m, String cid) async {
    final mime = await _full(m.folder, m.uid);
    if (mime == null) return null;
    return _cidPart(mime, cid);
  }

  static bool _hasCidImg(String? html) =>
      html != null &&
      RegExp(
        r'''<img\b[^>]*\bsrc\s*=\s*["']\s*cid:''',
        caseSensitive: false,
      ).hasMatch(html);

  static Uint8List? _cidPart(em.MimeMessage mime, String cid) {
    final want = cid.replaceAll(RegExp(r'^<|>$'), '').trim().toLowerCase();
    for (final p in mime.allPartsFlat) {
      final id = p.getHeaderValue('content-id');
      if (id != null &&
          id.replaceAll(RegExp(r'^<|>$'), '').trim().toLowerCase() == want)
        return p.decodeContentBinary();
    }
    return null;
  }

  Future<em.MailClient> _select(String folder) async {
    final c = await _c();
    final box = _box(folder);
    if (box == null) throw StateError('Cartella non trovata: $folder');
    await c.selectMailbox(box);
    return c;
  }

  @override
  Future<Map<int, String>> messageIdsOf(String folder, List<int> uids) =>
      _azione(() async {
        final c = await _select(folder);
        final imap = c.lowLevelIncomingMailClient as em.ImapClient;
        final res = await imap.uidFetchMessages(
          _seq(uids),
          'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]',
        );
        return {
          for (final m in res.messages)
            if (m.uid != null)
              m.uid!: (m.getHeaderValue('message-id') ?? '').trim(),
        };
      });

  @override
  Future<int> restoreByMessageId(
    String origFolder,
    List<String> messageIds, {
    String? alsoIn,
  }) => _azione(() => _restoreByMessageId(origFolder, messageIds, alsoIn: alsoIn));

  Future<int> _restoreByMessageId(
    String origFolder,
    List<String> messageIds, {
    String? alsoIn,
  }) async {
    final orig = _box(origFolder);
    if (orig == null || messageIds.isEmpty) return 0;
    final c = await _c();
    final imap = c.lowLevelIncomingMailClient as em.ImapClient;
    // Quelle già nella cartella di origine sono a posto: non si cercano né si spostano altrove
    // (su Gmail «Tutti i messaggi» le contiene anche in arrivo e spostarle da lì le manderebbe nel Cestino).
    await c.selectMailbox(orig);
    final qui = <String>{};
    for (final id in messageIds) {
      final clean = idPerRicerca(id);
      final r = await imap.uidSearchMessages(
        searchCriteria: 'HEADER Message-ID "$clean"',
      );
      if ((r.matchingSequence?.toList() ?? const <int>[]).isNotEmpty) qui.add(id);
    }
    final daRimettere = [for (final id in messageIds) if (!qui.contains(id)) id];
    if (daRimettere.isEmpty) return qui.length;
    messageIds = daRimettere;
    final places = <em.Mailbox>{
      for (final r in const ['trash', 'junk', 'archive'])
        if (_byRole(r) != null) _byRole(r)!,
      if (alsoIn != null && _box(alsoIn) != null) _box(alsoIn)!,
    }..remove(orig);
    var n = 0;
    for (final box in places) {
      final found = <int>[];
      await c.selectMailbox(box);
      for (final id in messageIds) {
        final clean = idPerRicerca(id);
        final r = await imap.uidSearchMessages(
          searchCriteria: 'HEADER Message-ID "$clean"',
        );
        found.addAll(r.matchingSequence?.toList() ?? const <int>[]);
      }
      if (found.isEmpty) continue;
      await c.moveMessages(_seq(found), orig);
      n += found.length;
    }
    await c.selectMailbox(orig);
    return n + qui.length;
  }

  @override
  Future<UndoFn> delete(String folder, List<int> uids) => _azione(() async {
    // Prima ci si collega: l'elenco delle cartelle si legge alla connessione, e dal tasto
    // della notifica (processo nuovo) è ancora vuoto.
    final c = await _select(folder);
    // Senza Cestino la libreria marca soltanto: l'email ricompariva e poi spariva senza Annulla.
    if (_byRole('trash') == null) {
      throw StateError('Questa casella non ha una cartella Cestino.');
    }
    final res = await c.deleteMessages(
      _seq(uids),
      expunge: _box(folder)?.isTrash ?? false,
    );
    return () => _azione(() async {
      await c.undoDeleteMessages(res);
    });
  });

  Future<UndoFn> _moveRole(String folder, List<int> uids, String role) async {
    return _azione(() async {
      final c = await _select(folder);
      final target = _byRole(role);
      if (target == null) {
        throw StateError(
          role == 'archive'
              ? 'Questa casella non ha una cartella Archivio.'
              : 'Cartella mancante: $role',
        );
      }
      final res = await c.moveMessages(_seq(uids), target);
      return () => _azione(() async {
        await c.undoMoveMessages(res);
      });
    });
  }

  @override
  Future<UndoFn> archive(String folder, List<int> uids) =>
      _moveRole(folder, uids, 'archive');

  @override
  Future<UndoFn> spam(String folder, List<int> uids) =>
      _moveRole(folder, uids, 'junk');

  @override
  Future<UndoFn> notSpam(String folder, List<int> uids) async {
    return _azione(() async {
      final c = await _select(folder);
      final inbox = _byRole('inbox');
      if (inbox == null) throw StateError('Posta in arrivo non trovata.');
      final res = await c.moveMessages(_seq(uids), inbox);
      return () => _azione(() async {
        await c.undoMoveMessages(res);
      });
    });
  }

  @override
  Future<UndoFn> moveTo(
    String folder,
    List<int> uids,
    String targetPath,
  ) async {
    return _azione(() async {
      final c = await _select(folder);
      final target = _box(targetPath);
      if (target == null) throw StateError('Cartella non trovata.');
      final res = await c.moveMessages(_seq(uids), target);
      return () => _azione(() async {
        await c.undoMoveMessages(res);
      });
    });
  }

  @override
  Future<void> setSeen(String folder, List<int> uids, bool seen) =>
      _azione(() async {
        final c = await _select(folder);
        if (seen) {
          await c.markSeen(_seq(uids));
        } else {
          await c.store(_seq(uids), [
            em.MessageFlags.seen,
          ], action: em.StoreAction.remove);
        }
      });

  @override
  Future<void> setFlagged(String folder, List<int> uids, bool flagged) =>
      _azione(() async {
        final c = await _select(folder);
        if (flagged) {
          await c.markFlagged(_seq(uids));
        } else {
          await c.store(_seq(uids), [
            em.MessageFlags.flagged,
          ], action: em.StoreAction.remove);
        }
      });

  @override
  Future<void> setAnswered(String folder, List<int> uids) => _azione(() async {
    final c = await _select(folder);
    await c.markAnswered(_seq(uids));
  });

  @override
  Future<void> emptyTrash(String trashPath) => _serial(() async {
    final c = await _c();
    final box = _box(trashPath);
    if (box == null) return;
    await c.deleteAllMessages(box, expunge: true);
    await Db.i.pruneFolder(account.id!, trashPath, 0, {});
  }).timeout(limiteRichiesta);

  @override
  Future<void> createFolder(String name) => _azione(() async {
    final c = await _c();
    await c.createMailbox(name);
    _boxes = await c.listMailboxes();
  });

  Future<em.MimeMessage> _build(Outgoing o) => buildMime(o);

  /// Costruisce il messaggio da spedire. Le immagini della firma partono come
  /// parti in linea (multipart/related con Content-ID), non come link né allegati.
  static Future<em.MimeMessage> buildMime(Outgoing o) async {
    final b = em.MessageBuilder()
      ..from = [
        em.MailAddress(o.fromName.isEmpty ? null : o.fromName, o.fromAddress),
      ]
      ..to = o.to.map((e) => em.MailAddress(null, e)).toList()
      ..cc = o.cc.map((e) => em.MailAddress(null, e)).toList()
      ..bcc = o.bcc.map((e) => em.MailAddress(null, e)).toList()
      ..subject = o.subject;
    if (o.inReplyTo != null && o.inReplyTo!.isNotEmpty) {
      b.setHeader('In-Reply-To', o.inReplyTo!);
      b.setHeader(
        'References',
        (o.references == null || o.references!.isEmpty)
            ? o.inReplyTo!
            : '${o.references} ${o.inReplyTo}',
      );
    }
    if (o.html.isNotEmpty) {
      final sig = SignatureTools.toCid(o.html);
      if (sig.images.isEmpty) {
        b.addMultipartAlternative(plainText: o.text, htmlText: o.html);
      } else {
        final rel = b.addPart(mediaSubtype: em.MediaSubtype.multipartRelated);
        rel.addMultipartAlternative(plainText: o.text, htmlText: sig.html);
        for (final img in sig.images) {
          final ext = img.mediaType.split('/').last.split('+').first;
          final part = rel.addBinary(
            img.data,
            em.MediaType.fromText(img.mediaType),
            disposition: em.ContentDispositionHeader.from(
              em.ContentDisposition.inline,
              filename: '${img.cid.split('@').first}.$ext',
            ),
          );
          part.setHeader('Content-ID', '<${img.cid}>');
        }
      }
    } else {
      b.text = o.text;
    }
    for (final p in o.attachmentPaths) {
      final f = File(p);
      final name = p.split(RegExp(r'[\\/]')).last;
      // Un allegato sparito non si salta in silenzio: l'email uscirebbe senza.
      if (!await f.exists()) {
        throw StateError('L\'allegato «$name» non c\'è più sul telefono: aggiungilo di nuovo.');
      }
      await b.addFile(f, em.MediaType.guessFromFileName(name));
    }
    return b.buildMimeMessage();
  }

  /// Toglie l'intestazione «Bcc» dal messaggio e la restituisce (per rimetterla dopo l'invio).
  static List<em.Header> senzaCcn(em.MimeMessage mime) {
    final tolti = [
      for (final h in mime.headers ?? <em.Header>[])
        if (h.lowerCaseName == 'bcc') h,
    ];
    mime.removeHeader('bcc');
    return tolti;
  }

  @override
  Future<void> send(Outgoing m) async {
    final c = await _c();
    final mime = await _build(m);
    // L'invio e la copia in «Inviata» sono due cose: se la copia fallisce l'email è
    // partita lo stesso (e riprovare la manderebbe due volte).
    // La libreria toglie dall'SMTP solo la prima riga «Bcc:»: con più indirizzi l'intestazione va a
    // capo e il resto restava leggibile a tutti. Si toglie qui per intero e i destinatari si passano
    // a parte; la copia in «Inviata» tiene l'intestazione.
    final bccHeaders = senzaCcn(mime);
    try {
      await c.sendMessage(
        mime,
        from: em.MailAddress(null, m.fromAddress),
        appendToSent: false,
        recipients: [
          for (final e in [...m.to, ...m.cc, ...m.bcc]) em.MailAddress(null, e),
        ],
      );
    } on TimeoutException {
      // La libreria ha già passato l'email al server e aspettava la conferma: riprovare
      // la manderebbe due volte. Lo si dice e si lascia decidere all'utente.
      throw const InvioIncerto();
    } finally {
      mime.headers?.addAll(bccHeaders);
    }
    if (account.saveSent) {
      try {
        final sent = _byRole('sent');
        if (sent == null) {
          throw StateError('cartella Inviata non trovata');
        }
        await c.appendMessage(mime, sent, flags: [em.MessageFlags.seen]);
      } catch (e) {
        SendNotes.warning =
            'L\'email è partita, ma la copia in «Inviata» non si è salvata (${friendlyError(e)}).';
      }
    }
  }

  @override
  Future<DraftRef?> saveDraft(Outgoing m) async {
    final c = await _c();
    final mime = await _build(m);
    final r = await c.saveDraftMessage(mime);
    final box = _byRole('drafts');
    final ids = r?.targetSequence.toList() ?? const <int>[];
    if (box == null || ids.isEmpty) return null;
    return DraftRef(box.path, ids.first);
  }

  @override
  Future<void> discardDraft(String folder, int uid) async {
    await _azione(() async {
      final c = await _select(folder);
      await c.deleteMessages(_seq([uid]), expunge: true);
    });
    await Db.i.deleteLocal(account.id!, folder, [uid]);
  }

  @override
  Future<List<Msg>> searchServer(String text, {String folder = 'INBOX'}) =>
      _serial(() async {
        final c = await _select(folder);
        final res = await c.searchMessages(
          em.MailSearch(
            text,
            em.SearchQueryType.allTextHeaders,
            pageSize: 30,
            messageType: em.SearchMessageType.all,
          ),
        );
        final out = <Msg>[];
        for (final m in res.messages) {
          if (m.uid != null) out.add(msgFromMime(account.id!, folder, m));
        }
        return out;
      }).timeout(limiteRichiesta);

  @override
  Future<int> junkUnseen() => _azione(() async {
    final c = await _c();
    final box = _byRole('junk');
    if (box == null) return 0;
    final sel = await c.selectMailbox(box);
    return sel.messagesUnseen;
  });

  void _attachEvents(em.MailClient c) {
    _subLoad?.cancel();
    _subLost?.cancel();
    _subBack?.cancel();
    _subLoad = c.eventBus.on<em.MailLoadEvent>().listen((e) {
      _onNew?.call(c.selectedMailbox?.path ?? 'INBOX');
    });
    _subLost = c.eventBus.on<em.MailConnectionLostEvent>().listen((e) {
      _onError?.call('Connessione persa');
      Future<void>.delayed(const Duration(seconds: 8), () async {
        if (!_listening) return;
        try {
          // Ricollegarsi con reconnect() della libreria rimanda la cartella con QRESYNC,
          // che sulla nuova connessione non è attivo («QRESYNC not enabled»): si butta
          // la connessione e se ne fa una nuova da zero.
          _chiudiVecchia(e.mailClient);
          final n = await _c();
          _attachEvents(n);
          final inbox = _box('INBOX');
          if (inbox != null) await n.selectMailbox(inbox);
          await n.startPolling();
        } catch (err) {
          _onError?.call(err);
        }
      });
    });
    _subBack = c.eventBus.on<em.MailConnectionReEstablishedEvent>().listen((e) {
      // Ricollegata: «Connessione persa» non vale più, se no il servizio la crede morta.
      Db.i.setStatus(account.id!, clearError: true);
      _onNew?.call(c.selectedMailbox?.path ?? 'INBOX');
    });
  }

  @override
  Future<void> startListening(
    void Function(String folder) onNew,
    void Function(Object error) onError,
  ) async {
    _onNew = onNew;
    _onError = onError;
    _listening = true;
    final c = await _c();
    final inbox = _byRole('inbox');
    if (inbox != null) await c.selectMailbox(inbox);
    _attachEvents(c);
    await c.startPolling();
  }

  @override
  Future<void> stopListening() async {
    _listening = false;
    try {
      // Aspetta il suo turno dietro alla richiesta in corso: se quella è appesa non arriverebbe mai.
      await _client?.stopPolling().timeout(const Duration(seconds: 5));
    } catch (_) {}
    _subLoad?.cancel();
    _subLost?.cancel();
    _subBack?.cancel();
  }

  @override
  Future<void> dispose() async {
    await stopListening();
    _epoca++;
    final c = _client;
    if (c != null) _chiudiVecchia(c);
    _client = null;
  }
}

/// Prova la posta in uscita: collegamento e accesso, senza mandare niente. Restituisce l'errore,
/// o null se va bene. Non ferma l'aggiunta della casella: alcuni server rispondono solo all'invio.
Future<String?> provaUscita(Account a, {String? password}) async {
  // L'accesso Microsoft usa un token: lo prova già la posta in arrivo.
  if (a.authType == 'oauth_ms' || password == null) return null;
  final c = em.SmtpClient('digimail.local');
  Future<void> prova() async {
    await c.connectToServer(a.smtpHost, a.smtpPort, isSecure: a.smtpSsl);
    await c.ehlo();
    if (!a.smtpSsl) await c.startTls();
    try {
      await c.authenticate(a.login, password, em.AuthMechanism.plain);
    } on em.SmtpException {
      await c.authenticate(a.login, password, em.AuthMechanism.login);
    }
  }

  try {
    await prova().timeout(const Duration(seconds: 25));
    return null;
  } catch (e) {
    return friendlyError(e);
  } finally {
    try {
      await c.disconnect();
    } catch (_) {}
  }
}

/// Verifica un account appena inserito: connessione IMAP.
Future<void> verifyAccount(
  Account a, {
  String? password,
  String? msTokenJson,
}) async {
  final inType = a.imapSsl ? em.SocketType.ssl : em.SocketType.starttls;
  final outType = a.smtpSsl ? em.SocketType.ssl : em.SocketType.starttls;
  final em.MailAccount acc;
  if (a.authType == 'oauth_ms') {
    acc = em.MailAccount.fromManualSettingsWithAuth(
      name: a.name,
      email: a.address,
      incomingHost: a.imapHost,
      outgoingHost: a.smtpHost,
      auth: em.OauthAuthentication.from(
        a.address,
        msTokenJson!,
        provider: 'microsoft',
      ),
      incomingPort: a.imapPort,
      outgoingPort: a.smtpPort,
      incomingSocketType: inType,
      outgoingSocketType: outType,
    );
  } else {
    acc = em.MailAccount.fromManualSettings(
      name: a.name,
      email: a.address,
      incomingHost: a.imapHost,
      outgoingHost: a.smtpHost,
      password: password!,
      loginName: a.login,
      incomingPort: a.imapPort,
      outgoingPort: a.smtpPort,
      incomingSocketType: inType,
      outgoingSocketType: outType,
    );
  }
  final c = em.MailClient(acc, isLogEnabled: false);
  try {
    await c.connect(timeout: const Duration(seconds: 25));
    await c.listMailboxes();
  } finally {
    try {
      await c.disconnect();
    } catch (_) {}
  }
}

bool _isAuthError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('authenticationfailed') ||
      s.contains('authentication failed') ||
      s.contains('invalid credentials') ||
      s.contains('login failed');
}

Account _copyWith(Account a, {int? port, bool? ssl, String? login}) => Account(
  id: a.id,
  address: a.address,
  name: a.name,
  senderName: a.senderName,
  color: a.color,
  kind: a.kind,
  imapHost: a.imapHost,
  imapPort: port ?? a.imapPort,
  imapSsl: ssl ?? a.imapSsl,
  smtpHost: a.smtpHost,
  smtpPort: a.smtpPort,
  smtpSsl: a.smtpSsl,
  authType: a.authType,
  loginName: login ?? a.loginName,
  saveSent: a.saveSent,
);

/// Verifica l'account. Se la connessione fallisce prova le porte e l'SSL più
/// comuni; se la password viene rifiutata prova anche il nome utente senza
/// dominio (molti server di dominio propri lo vogliono così).
Future<Account> verifyAccountAuto(
  Account a, {
  String? password,
  String? msTokenJson,
}) async {
  final pw = password?.trim();
  Future<Account> tryLogins(Account b) async {
    try {
      await verifyAccount(b, password: pw, msTokenJson: msTokenJson);
      return b;
    } catch (e) {
      if (!_isAuthError(e) ||
          b.authType == 'oauth_ms' ||
          b.loginName.isNotEmpty ||
          !b.address.contains('@')) {
        rethrow;
      }
      final c = _copyWith(b, login: b.address.split('@').first);
      try {
        await verifyAccount(c, password: pw, msTokenJson: msTokenJson);
        return c;
      } catch (_) {
        throw e;
      }
    }
  }

  try {
    return await tryLogins(a);
  } catch (e) {
    if (_isAuthError(e) || a.authType == 'oauth_ms') rethrow;
    for (final c in const [
      [993, true],
      [143, false],
      [993, false],
      [143, true],
    ]) {
      if (c[0] == a.imapPort && c[1] == a.imapSsl) continue;
      try {
        return await tryLogins(_copyWith(a, port: c[0] as int, ssl: c[1] as bool));
      } catch (e2) {
        if (_isAuthError(e2)) rethrow;
      }
    }
    rethrow;
  }
}

String friendlyError(Object e) {
  if (e is InvioIncerto) return e.message;
  final s = e.toString();
  if (e is MsAuthException ||
      s.contains('AADSTS') ||
      s.contains('invalid_grant')) {
    return 'Accesso Microsoft scaduto: rifai l\'accesso dalle impostazioni della casella.';
  }
  if (s.contains('AUTHENTICATIONFAILED') ||
      s.toLowerCase().contains('authentication failed') ||
      s.contains('Invalid credentials') ||
      s.contains('LOGIN failed')) {
    return 'Accesso rifiutato: controlla indirizzo e password (Gmail, iCloud e Yahoo vogliono la «password per app»).';
  }
  if (s.contains('SocketException') || s.contains('Failed host lookup'))
    return 'Nessuna connessione o server non raggiungibile.';
  if (s.toLowerCase().contains('timeout') ||
      s.toLowerCase().contains('timed out'))
    return 'Il server non risponde in tempo.';
  if (s.contains('HandshakeException') || s.contains('CERTIFICATE'))
    return 'Certificato del server non valido.';
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

String jsonOf(Object o) => jsonEncode(o);
