import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'notify.dart';

/// Database locale: account, cache dei messaggi, mittenti bloccati, ecc.
/// Lo usano sia l'interfaccia sia il servizio in background.
class Db {
  Db._();
  static final Db i = Db._();
  Database? _db;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Si attiva a ogni modifica locale, per aggiornare le schermate.
  Stream<void> get changes => _changes.stream;
  void notifyChanged() {
    _changes.add(null);
    // Ogni email letta, cancellata o arrivata aggiorna subito il numero sull'icona.
    Notify.updateIconBadge();
  }

  /// Email che l'app sta togliendo dal server in questo momento (elimina, sposta): tolte dalla
  /// copia locale ma ancora sul server, una sincronizzazione in corso le rimetterebbe in lista.
  final Set<String> _inVolo = {};
  String _chiaveVolo(int accountId, String folder, int uid) =>
      '$accountId|$folder|$uid';
  bool inVolo(int accountId, String folder, int uid) =>
      _inVolo.contains(_chiaveVolo(accountId, folder, uid));
  void setInVolo(int accountId, String folder, List<int> uids, bool on) {
    for (final u in uids) {
      final k = _chiaveVolo(accountId, folder, u);
      on ? _inVolo.add(k) : _inVolo.remove(k);
    }
  }

  Future<Database>? _opening;

  /// Un'apertura sola, anche se la chiedono insieme schermata e servizio.
  Future<Database> get db {
    if (_db != null) return Future.value(_db!);
    return _opening ??= _openReal().whenComplete(() => _opening = null);
  }

  Future<Database> _openReal() async {
    final path = p.join(await getDatabasesPath(), 'digimail.db');
    final d = await openDatabase(
      path,
      version: 9,
      onCreate: _create,
      onUpgrade: _upgrade,
      // Una versione più vecchia dell'app si deve aprire: le aggiunte fatte finora sono solo colonne e indici.
      onDowngrade: (d, a, b) async {},
      singleInstance: false,
      onConfigure: (d) async {
        // Se il telefono non accetta queste impostazioni, il database si apre lo stesso.
        try {
          await d.rawQuery('PRAGMA busy_timeout=8000');
        } catch (_) {}
        try {
          await d.rawQuery('PRAGMA journal_mode=WAL');
        } catch (_) {}
      },
    );
    _db = d;
    return d;
  }

  /// Per i test: database in memoria.
  Future<void> openForTest() async {
    _opening = null;
    await _db?.close();
    _db = await openDatabase(
      inMemoryDatabasePath,
      version: 7,
      onCreate: _create,
      singleInstance: false,
    );
  }

  /// Per i test: applica gli aggiornamenti del database come all'apertura sul telefono.
  Future<void> upgradeForTest(Database d, int from, int to) =>
      _upgrade(d, from, to);

  /// Versione 2: segno «risposto» sulle email.
  /// Versione 3: segno «già avvisata» per email, numero di sincronizzazione per cartella
  /// (con UIDVALIDITY) e motivo registrato per ogni avviso.
  Future<void> _upgrade(Database d, int from, int to) async {
    if (from < 2) {
      await d.execute(
        'ALTER TABLE messages ADD COLUMN answered INTEGER DEFAULT 0',
      );
    }
    if (from < 3) {
      await d.execute(
        'ALTER TABLE messages ADD COLUMN notified INTEGER DEFAULT 1',
      );
      await d.execute(
        'CREATE TABLE folder_sync(account_id INTEGER, folder TEXT, uidvalidity INTEGER, last_uid INTEGER, PRIMARY KEY(account_id, folder))',
      );
      // Chi aveva già email in cache riparte da lì: nessuna notifica per quelle vecchie.
      await d.execute(
        'INSERT INTO folder_sync(account_id,folder,uidvalidity,last_uid) '
        'SELECT account_id, folder, 0, MAX(uid) FROM messages GROUP BY account_id, folder',
      );
      await d.execute('ALTER TABLE push_log ADD COLUMN result TEXT');
    }
    if (from < 4) {
      await d.execute('ALTER TABLE scheduled ADD COLUMN claimed INTEGER');
    }
    if (from < 5) await _createSpamTables(d);
    // Versione 6: Reply-To e References dell'email, per rispondere all'indirizzo giusto.
    if (from < 6) {
      await d.execute("ALTER TABLE messages ADD COLUMN reply_to TEXT DEFAULT ''");
      await d.execute("ALTER TABLE messages ADD COLUMN refs TEXT DEFAULT ''");
    }
    if (from < 7) await _createIndici(d);
    // Versione 8 (1.0.76): un corpo oltre il limite di Android (2 MB per riga) bloccava
    // l'elenco intero (09.11.2026). Si toglie: l'email si riscarica all'apertura e il
    // testo grande va in un file a parte.
    if (from < 8) {
      for (final c in ['body_html', 'body_text']) {
        try {
          await d.rawUpdate(
            'UPDATE messages SET $c=NULL WHERE length($c)>?',
            [maxCorpoInRiga],
          );
        } catch (_) {}
      }
    }
    // Versione 9 (1.0.77): le immagini attaccate «dentro il testo» ma non usate dal testo
    // ora si mostrano in fondo all'email. I testi già salvati non le hanno: si rileggono
    // dal server alla prossima apertura di ogni email.
    if (from < 9) {
      try {
        await d.rawUpdate('UPDATE messages SET body_text=NULL, body_html=NULL');
      } catch (_) {}
    }
  }

  /// Versione 7: indici per le ricerche fatte di continuo, che leggevano tutta la tabella.
  Future<void> _createIndici(Database d) async {
    await d.execute(
      'CREATE INDEX IF NOT EXISTS msg_id ON messages(account_id, message_id)',
    );
    await d.execute(
      'CREATE INDEX IF NOT EXISTS msg_snooze ON messages(snoozed_until)',
    );
    await d.execute(
      'CREATE INDEX IF NOT EXISTS msg_notified ON messages(account_id, notified)',
    );
  }

  /// Versione 5: Spam e Cestino contano nel numero sull'icona e avvisano.
  /// `moved` ricorda le email spostate dall'app (per non avvisare quando le sposta l'utente);
  /// `folder_roles` ricorda quali cartelle di una casella sono Spam o Cestino.
  Future<void> _createSpamTables(Database d) async {
    await d.execute(
      'CREATE TABLE moved(account_id INTEGER, message_id TEXT, at INTEGER, PRIMARY KEY(account_id, message_id))',
    );
    await d.execute(
      'CREATE TABLE folder_roles(account_id INTEGER, folder TEXT, role TEXT, PRIMARY KEY(account_id, folder))',
    );
  }

  Future<void> _create(Database d, int v) async {
    await d.execute(
      '''CREATE TABLE accounts(
      id INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT NOT NULL, name TEXT, sender_name TEXT,
      color INTEGER, logo_path TEXT, kind TEXT, imap_host TEXT, imap_port INTEGER, imap_ssl INTEGER,
      smtp_host TEXT, smtp_port INTEGER, smtp_ssl INTEGER, auth_type TEXT, login_name TEXT,
      signature_html TEXT, bcc_self INTEGER, notify INTEGER, save_sent INTEGER, position INTEGER, aliases TEXT)''',
    );
    await d.execute(
      '''CREATE TABLE messages(
      account_id INTEGER, folder TEXT, uid INTEGER, message_id TEXT, from_name TEXT, from_addr TEXT,
      to_addrs TEXT, cc_addrs TEXT, subject TEXT, date INTEGER, preview TEXT, seen INTEGER, flagged INTEGER,
      answered INTEGER DEFAULT 0, has_att INTEGER, list_unsub TEXT, list_unsub_post INTEGER, auth_results TEXT, body_text TEXT,
      body_html TEXT, snoozed_until INTEGER, notified INTEGER DEFAULT 1, reply_to TEXT DEFAULT '', refs TEXT DEFAULT '', PRIMARY KEY(account_id, folder, uid))''',
    );
    await d.execute(
      'CREATE TABLE folder_sync(account_id INTEGER, folder TEXT, uidvalidity INTEGER, last_uid INTEGER, PRIMARY KEY(account_id, folder))',
    );
    await _createIndici(d);
    await d.execute(
      'CREATE INDEX msg_date ON messages(account_id, folder, date DESC)',
    );
    await d.execute(
      'CREATE TABLE blocked(account_id INTEGER, sender TEXT, created INTEGER, PRIMARY KEY(account_id, sender))',
    );
    await d.execute(
      'CREATE TABLE unsubs(account_id INTEGER, sender TEXT, name TEXT, method TEXT, at INTEGER, PRIMARY KEY(account_id, sender))',
    );
    await d.execute(
      'CREATE TABLE contacts(address TEXT PRIMARY KEY, name TEXT, uses INTEGER, last INTEGER)',
    );
    await d.execute(
      'CREATE TABLE scheduled(id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, send_at INTEGER, payload TEXT, status TEXT, claimed INTEGER)',
    );
    await d.execute(
      'CREATE TABLE pending_ops(id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, op TEXT, folder TEXT, uids TEXT, arg TEXT, attempts INTEGER, created INTEGER)',
    );
    await d.execute(
      'CREATE TABLE push_log(id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, uid INTEGER, msg_date INTEGER, seen_at INTEGER, notified_at INTEGER, result TEXT)',
    );
    await d.execute(
      'CREATE TABLE acc_status(account_id INTEGER PRIMARY KEY, idle_since INTEGER, last_event INTEGER, last_sync INTEGER, last_error TEXT)',
    );
    await _createSpamTables(d);
  }

  // ---------- account ----------
  Future<List<Account>> accounts() async {
    final d = await db;
    final rows = await d.query('accounts', orderBy: 'position, id');
    return rows.map(Account.fromRow).toList();
  }

  Future<Account?> account(int id) async {
    final d = await db;
    final rows = await d.query('accounts', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : Account.fromRow(rows.first);
  }

  Future<int> saveAccount(Account a) async {
    final d = await db;
    int id;
    if (a.id == null) {
      final n =
          Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM accounts'),
          ) ??
          0;
      a.position = n;
      id = await d.insert('accounts', a.toRow());
      a.id = id;
    } else {
      await d.update('accounts', a.toRow(), where: 'id=?', whereArgs: [a.id]);
      id = a.id!;
    }
    notifyChanged();
    return id;
  }

  /// Vero se questo indirizzo è già una casella di DiGiMail (maiuscole e spazi non contano).
  Future<bool> hasAddress(String address) async {
    final a = address.trim().toLowerCase();
    return (await accounts()).any((e) => e.address.trim().toLowerCase() == a);
  }

  Future<void> removeAccount(int id) async {
    final d = await db;
    // Tutto o niente: uno spegnimento a metà lasciava email di una casella che non c'è più.
    await d.transaction((t) async {
      for (final tab in [
        'messages',
        'blocked',
        'unsubs',
        'acc_status',
        'folder_sync',
        'scheduled',
        'pending_ops',
        'push_log',
        'moved',
        'folder_roles',
      ]) {
        await t.delete(tab, where: 'account_id=?', whereArgs: [id]);
      }
      await t.delete('accounts', where: 'id=?', whereArgs: [id]);
    });
    await Notify.deleteChannel(id);
    notifyChanged();
  }

  Future<void> reorderAccounts(List<int> ids) async {
    final d = await db;
    final b = d.batch();
    for (var i = 0; i < ids.length; i++) {
      b.update('accounts', {'position': i}, where: 'id=?', whereArgs: [ids[i]]);
    }
    await b.commit(noResult: true);
    notifyChanged();
  }

  // ---------- messaggi ----------
  Future<List<Msg>> messages(
    int accountId,
    String folder, {
    int limit = 200,
    int offset = 0,
  }) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where:
          'account_id=? AND folder=? AND (snoozed_until IS NULL OR snoozed_until<=?)',
      whereArgs: [accountId, folder, now],
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Msg.fromRow).toList();
  }

  Future<List<Msg>> snoozed(int accountId) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'account_id=? AND snoozed_until IS NOT NULL AND snoozed_until>?',
      whereArgs: [accountId, now],
      orderBy: 'snoozed_until',
    );
    return rows.map(Msg.fromRow).toList();
  }

  Future<Msg?> message(int accountId, String folder, int uid) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'account_id=? AND folder=? AND uid=?',
      whereArgs: [accountId, folder, uid],
    );
    return rows.isEmpty ? null : conCorpo(Msg.fromRow(rows.first));
  }

  // ---------- corpo delle email ----------
  //
  // Come K-9 Mail: gli elenchi non leggono mai il testo delle email (una sola email
  // pesante oltre i 2 MB per riga di Android svuotava la Posta in entrata,
  // 09.11.2026). Il testo si legge solo quando si apre l'email, una colonna alla volta;
  // quelli più grandi di [maxCorpoInRiga] caratteri stanno in un file a parte.

  /// Colonne degli elenchi: tutto tranne i testi, più «ha già il testo» e un pezzo
  /// iniziale del testo semplice per la ricerca dell'assistente.
  static const colonneElenco = [
    'account_id', 'folder', 'uid', 'message_id', 'from_name', 'from_addr',
    'to_addrs', 'cc_addrs', 'subject', 'date', 'preview', 'seen', 'flagged',
    'answered', 'has_att', 'list_unsub', 'list_unsub_post', 'auth_results',
    'snoozed_until', 'notified', 'reply_to', 'refs',
    '(body_text IS NOT NULL OR body_html IS NOT NULL) AS has_body',
    'substr(body_text, 1, 4000) AS body_head',
  ];

  static const maxCorpoInRiga = 300000;
  static const segnoCorpoInFile = '@@DIGIMAIL-CORPO-IN-FILE@@';

  /// Solo per i test: cartella dei testi grandi (sul telefono è quella dell'app).
  static Directory? cartellaCorpiPerTest;

  Future<Directory> _cartellaCorpi() async {
    final base = cartellaCorpiPerTest ??
        Directory(p.join((await getApplicationDocumentsDirectory()).path, 'corpi'));
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  String _nomeFile(int accountId, String folder, int uid, String tipo) =>
      '${accountId}_${base64Url.encode(utf8.encode(folder)).replaceAll('=', '')}_$uid.$tipo';

  Future<String> _inRigaOFile(
    int accountId,
    String folder,
    int uid,
    String tipo,
    String testo,
  ) async {
    if (testo.length <= maxCorpoInRiga) return testo;
    final f = File(
      p.join((await _cartellaCorpi()).path, _nomeFile(accountId, folder, uid, tipo)),
    );
    await f.writeAsString(testo, flush: true);
    return segnoCorpoInFile;
  }

  /// Aggiunge al messaggio il testo già salvato (dal database o dal file). Se il testo
  /// non si trova più, il messaggio risulta senza testo e l'app lo riscarica.
  Future<Msg> conCorpo(Msg m) async {
    if (!m.hasBody || m.bodyText != null || m.bodyHtml != null) return m;
    final d = await db;
    for (final c in ['body_text', 'body_html']) {
      String? v;
      try {
        final r = await d.query(
          'messages',
          columns: [c],
          where: 'account_id=? AND folder=? AND uid=?',
          whereArgs: [m.accountId, m.folder, m.uid],
        );
        v = r.isEmpty ? null : r.first[c] as String?;
      } catch (_) {
        // Riga ancora troppo grande: si toglie, l'email si riscarica.
        try {
          await d.rawUpdate(
            'UPDATE messages SET $c=NULL WHERE account_id=? AND folder=? AND uid=?',
            [m.accountId, m.folder, m.uid],
          );
        } catch (_) {}
        v = null;
      }
      if (v == segnoCorpoInFile) {
        final f = File(
          p.join(
            (await _cartellaCorpi()).path,
            _nomeFile(m.accountId, m.folder, m.uid, c == 'body_html' ? 'html' : 'txt'),
          ),
        );
        v = await f.exists() ? await f.readAsString() : null;
      }
      if (c == 'body_text') {
        m.bodyText = v;
      } else {
        m.bodyHtml = v;
      }
    }
    if (m.bodyText == null && m.bodyHtml == null) m.hasBody = false;
    return m;
  }

  /// Inserisce o aggiorna mantenendo corpo e rimando già salvati.
  /// [pending]: gli identificativi delle email nuove ancora da avvisare (il segno si
  /// scrive nella stessa operazione, così un'interruzione non le perde).
  Future<void> upsertMessages(List<Msg> list, {Set<int>? pending}) async {
    if (list.isEmpty) return;
    final d = await db;
    final b = d.batch();
    for (final m in list) {
      final row = m.toRow();
      b.rawInsert(
        'INSERT INTO messages(account_id,folder,uid,message_id,from_name,from_addr,to_addrs,cc_addrs,subject,date,preview,seen,flagged,answered,has_att,list_unsub,list_unsub_post,auth_results,body_text,body_html,snoozed_until,notified,reply_to,refs) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(account_id,folder,uid) DO UPDATE SET '
        // Un dato vuoto non cancella mai quello già salvato (mittente, oggetto, data).
        'message_id=CASE WHEN excluded.message_id<>\'\' THEN excluded.message_id ELSE messages.message_id END, '
        'from_name=CASE WHEN excluded.from_addr<>\'\' THEN excluded.from_name ELSE messages.from_name END, '
        'from_addr=CASE WHEN excluded.from_addr<>\'\' THEN excluded.from_addr ELSE messages.from_addr END, '
        'to_addrs=CASE WHEN excluded.to_addrs<>\'\' THEN excluded.to_addrs ELSE messages.to_addrs END, '
        'cc_addrs=CASE WHEN excluded.cc_addrs<>\'\' THEN excluded.cc_addrs ELSE messages.cc_addrs END, '
        'subject=CASE WHEN excluded.subject<>\'\' OR excluded.from_addr<>\'\' THEN excluded.subject ELSE messages.subject END, '
        'date=CASE WHEN excluded.from_addr<>\'\' THEN excluded.date ELSE messages.date END, '
        'preview=CASE WHEN excluded.preview<>\'\' THEN excluded.preview ELSE messages.preview END, '
        'seen=excluded.seen, flagged=excluded.flagged, answered=excluded.answered, has_att=MAX(excluded.has_att, messages.has_att), '
        'list_unsub=CASE WHEN excluded.list_unsub<>\'\' THEN excluded.list_unsub ELSE messages.list_unsub END, '
        'list_unsub_post=MAX(excluded.list_unsub_post, messages.list_unsub_post), '
        'auth_results=CASE WHEN excluded.auth_results<>\'\' THEN excluded.auth_results ELSE messages.auth_results END, '
        'reply_to=CASE WHEN excluded.reply_to<>\'\' THEN excluded.reply_to ELSE messages.reply_to END, '
        'refs=CASE WHEN excluded.refs<>\'\' THEN excluded.refs ELSE messages.refs END',
        [
          row['account_id'],
          row['folder'],
          row['uid'],
          row['message_id'],
          row['from_name'],
          row['from_addr'],
          row['to_addrs'],
          row['cc_addrs'],
          row['subject'],
          row['date'],
          row['preview'],
          row['seen'],
          row['flagged'],
          row['answered'],
          row['has_att'],
          row['list_unsub'],
          row['list_unsub_post'],
          row['auth_results'],
          row['body_text'],
          row['body_html'],
          row['snoozed_until'],
          (pending != null && pending.contains(m.uid) && !m.seen) ? 0 : 1,
          row['reply_to'],
          row['refs'],
        ],
      );
    }
    await b.commit(noResult: true);
    notifyChanged();
  }

  // ---------- email nuove da avvisare ----------

  /// Dove era arrivata la sincronizzazione di una cartella: null se non è mai stata scaricata.
  Future<({int validity, int lastUid})?> folderSync(
    int accountId,
    String folder,
  ) async {
    final d = await db;
    final r = await d.query(
      'folder_sync',
      where: 'account_id=? AND folder=?',
      whereArgs: [accountId, folder],
    );
    if (r.isEmpty) return null;
    return (
      validity: (r.first['uidvalidity'] as int?) ?? 0,
      lastUid: (r.first['last_uid'] as int?) ?? 0,
    );
  }

  Future<void> setFolderSync(
    int accountId,
    String folder,
    int validity,
    int lastUid,
  ) async {
    final d = await db;
    await d.insert('folder_sync', {
      'account_id': accountId,
      'folder': folder,
      'uidvalidity': validity,
      'last_uid': lastUid,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Il server ha rinumerato la cartella (UIDVALIDITY cambiato): la copia locale non vale più.
  Future<void> dropFolderCache(int accountId, String folder) async {
    final d = await db;
    await d.delete(
      'messages',
      where: 'account_id=? AND folder=?',
      whereArgs: [accountId, folder],
    );
    await d.delete(
      'folder_sync',
      where: 'account_id=? AND folder=?',
      whereArgs: [accountId, folder],
    );
    notifyChanged();
  }

  /// Email arrivate (in Posta in arrivo, Spam o Cestino) e non ancora avvisate, dalla più vecchia.
  Future<List<Msg>> pendingNotify(int accountId) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'account_id=? AND notified=0',
      whereArgs: [accountId],
      orderBy: 'uid',
    );
    return rows.map(Msg.fromRow).toList();
  }

  /// Prende in carico l'avviso di un'email: vero solo per il primo che la chiede,
  /// così due controlli insieme non la fanno suonare due volte.
  Future<bool> claimNotify(int accountId, String folder, int uid) async {
    final d = await db;
    final n = await d.update(
      'messages',
      {'notified': 1},
      where: 'account_id=? AND folder=? AND uid=? AND notified=0',
      whereArgs: [accountId, folder, uid],
    );
    return n == 1;
  }

  /// Vero se la stessa email (stesso Message-ID) è già in un'altra cartella: spostata, non arrivata.
  Future<bool> seenElsewhere(
    int accountId,
    String folder,
    String messageId,
  ) async {
    if (messageId.isEmpty) return false;
    final d = await db;
    return (Sqflite.firstIntValue(
              await d.rawQuery(
                'SELECT COUNT(*) FROM messages WHERE account_id=? AND message_id=? AND folder<>?',
                [accountId, messageId, folder],
              ),
            ) ??
            0) >
        0;
  }

  Future<void> setMessageId(int accountId, String folder, int uid, String id) async {
    final d = await db;
    await d.update(
      'messages',
      {'message_id': id},
      where: 'account_id=? AND folder=? AND uid=?',
      whereArgs: [accountId, folder, uid],
    );
  }

  Future<void> saveBody(
    int accountId,
    String folder,
    int uid, {
    String? text,
    String? html,
    String? preview,
    String? listUnsub,
    bool? listUnsubPost,
    String? authResults,
    String? replyTo,
    String? refs,
    bool vuotaOk = false,
  }) async {
    final d = await db;
    // Un secondo scaricamento decodificato male non azzera il corpo già salvato.
    final v = <String, Object?>{
      if (text != null && text.isNotEmpty)
        'body_text': await _inRigaOFile(accountId, folder, uid, 'txt', text),
      if (html != null && html.isNotEmpty)
        'body_html': await _inRigaOFile(accountId, folder, uid, 'html', html),
    };
    // Email senza testo né HTML: si scrive un corpo vuoto, così «già scaricata» vale anche per lei.
    if (vuotaOk && v.isEmpty) {
      final r = await d.query(
        'messages',
        columns: ['body_text', 'body_html'],
        where: 'account_id=? AND folder=? AND uid=?',
        whereArgs: [accountId, folder, uid],
      );
      if (r.isNotEmpty && r.first['body_text'] == null && r.first['body_html'] == null) {
        v['body_text'] = '';
      }
    }
    if (replyTo != null && replyTo.isNotEmpty) v['reply_to'] = replyTo;
    if (refs != null && refs.isNotEmpty) v['refs'] = refs;
    if (preview != null && preview.isNotEmpty) v['preview'] = preview;
    if (listUnsub != null && listUnsub.isNotEmpty) v['list_unsub'] = listUnsub;
    if (listUnsubPost == true) v['list_unsub_post'] = 1;
    if (authResults != null && authResults.isNotEmpty)
      v['auth_results'] = authResults;
    if (v.isEmpty) return;
    await d.update(
      'messages',
      v,
      where: 'account_id=? AND folder=? AND uid=?',
      whereArgs: [accountId, folder, uid],
    );
  }

  Future<void> setSeen(
    int accountId,
    String folder,
    List<int> uids,
    bool seen,
  ) async {
    final d = await db;
    final b = d.batch();
    for (final u in uids) {
      b.update(
        'messages',
        {'seen': seen ? 1 : 0},
        where: 'account_id=? AND folder=? AND uid=?',
        whereArgs: [accountId, folder, u],
      );
    }
    await b.commit(noResult: true);
    notifyChanged();
  }

  /// Segna come «risposta» l'email con quel Message-ID; restituisce cartella e uid trovati.
  Future<List<Msg>> markAnsweredByMessageId(
    int accountId,
    String messageId,
  ) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'account_id=? AND message_id=?',
      whereArgs: [accountId, messageId],
    );
    if (rows.isEmpty) return const [];
    await d.update(
      'messages',
      {'answered': 1},
      where: 'account_id=? AND message_id=?',
      whereArgs: [accountId, messageId],
    );
    notifyChanged();
    return rows.map(Msg.fromRow).toList();
  }

  Future<void> setFlagged(
    int accountId,
    String folder,
    List<int> uids,
    bool flagged,
  ) async {
    final d = await db;
    final b = d.batch();
    for (final u in uids) {
      b.update(
        'messages',
        {'flagged': flagged ? 1 : 0},
        where: 'account_id=? AND folder=? AND uid=?',
        whereArgs: [accountId, folder, u],
      );
    }
    await b.commit(noResult: true);
    notifyChanged();
  }

  Future<void> setSnooze(
    int accountId,
    String folder,
    int uid,
    DateTime? until,
  ) async {
    final d = await db;
    await d.update(
      'messages',
      {'snoozed_until': until?.millisecondsSinceEpoch},
      where: 'account_id=? AND folder=? AND uid=?',
      whereArgs: [accountId, folder, uid],
    );
    notifyChanged();
  }

  /// Ricorda i Message-ID di email che l'app sta spostando, per non avvisarle quando
  /// compaiono nel Cestino o nello Spam.
  Future<void> markMoved(int accountId, Iterable<String> ids) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = d.batch();
    for (final id in ids) {
      if (id.isEmpty) continue;
      b.insert('moved', {
        'account_id': accountId,
        'message_id': id,
        'at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    b.delete(
      'moved',
      where: 'at<?',
      whereArgs: [now - const Duration(days: 3).inMilliseconds],
    );
    await b.commit(noResult: true);
  }

  Future<bool> wasMoved(int accountId, String messageId) async {
    if (messageId.isEmpty) return false;
    final d = await db;
    return (Sqflite.firstIntValue(
              await d.rawQuery(
                'SELECT COUNT(*) FROM moved WHERE account_id=? AND message_id=?',
                [accountId, messageId],
              ),
            ) ??
            0) >
        0;
  }

  Future<void> setFolderRole(int accountId, String folder, String role) async {
    final d = await db;
    await d.insert('folder_roles', {
      'account_id': accountId,
      'folder': folder,
      'role': role,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Non lette che contano nel numero sull'icona: Posta in arrivo, più quelle arrivate
  /// negli ultimi 2 giorni in Spam e Cestino (le vecchie dello Spam non fanno rumore).
  Future<int> unseenAlertCount(int accountId) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final inbox = await unseenCount(accountId, 'INBOX');
    final extra =
        Sqflite.firstIntValue(
          await d.rawQuery(
            'SELECT COUNT(*) FROM messages WHERE account_id=? AND seen=0 AND date>=? '
            'AND (snoozed_until IS NULL OR snoozed_until<=?) '
            'AND folder IN (SELECT folder FROM folder_roles WHERE account_id=? )',
            [
              accountId,
              now - const Duration(days: 2).inMilliseconds,
              now,
              accountId,
            ],
          ),
        ) ??
        0;
    return inbox + extra;
  }

  /// Non lette recenti (ultimi 2 giorni) di Spam e Cestino, cartella per cartella:
  /// sono quelle che contano nel numero sull'icona oltre a Posta in arrivo.
  Future<Map<String, int>> unseenAlertByFolder(int accountId) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await d.rawQuery(
      'SELECT folder, COUNT(*) AS n FROM messages WHERE account_id=? AND seen=0 AND date>=? '
      'AND (snoozed_until IS NULL OR snoozed_until<=?) '
      'AND folder IN (SELECT folder FROM folder_roles WHERE account_id=?) GROUP BY folder',
      [accountId, now - const Duration(days: 2).inMilliseconds, now, accountId],
    );
    return {for (final r in rows) r['folder'] as String: (r['n'] as int)};
  }

  Future<void> deleteLocal(int accountId, String folder, List<int> uids) async {
    if (uids.isEmpty) return;
    final d = await db;
    final posti = List.filled(uids.length, '?').join(',');
    final args = <Object>[accountId, folder, ...uids];
    final r = await d.rawQuery(
      'SELECT message_id FROM messages WHERE account_id=? AND folder=? AND uid IN ($posti)',
      args,
    );
    await markMoved(accountId, [for (final x in r) (x['message_id'] ?? '') as String]);
    await d.rawDelete(
      'DELETE FROM messages WHERE account_id=? AND folder=? AND uid IN ($posti)',
      args,
    );
    notifyChanged();
  }

  /// Toglie dalla cache i messaggi di una cartella che non esistono più sul server.
  Future<void> pruneFolder(
    int accountId,
    String folder,
    int minUid,
    Set<int> keep,
  ) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: ['uid'],
      where: 'account_id=? AND folder=? AND uid>=?',
      whereArgs: [accountId, folder, minUid],
    );
    final b = d.batch();
    var any = false;
    for (final r in rows) {
      final u = r['uid'] as int;
      if (!keep.contains(u)) {
        b.delete(
          'messages',
          where: 'account_id=? AND folder=? AND uid=?',
          whereArgs: [accountId, folder, u],
        );
        any = true;
      }
    }
    if (any) {
      await b.commit(noResult: true);
      notifyChanged();
    }
  }

  /// Vero se questo mittente ha scritto già prima di oggi, fuori dallo Spam.
  Future<bool> mittenteConosciuto(String addr) async {
    final d = await db;
    return (Sqflite.firstIntValue(
              await d.rawQuery(
                'SELECT COUNT(*) FROM messages WHERE LOWER(from_addr)=LOWER(?) AND date<? '
                "AND folder NOT IN (SELECT folder FROM folder_roles WHERE role='junk' "
                'AND account_id=messages.account_id)',
                [
                  addr.trim(),
                  DateTime.now()
                      .subtract(const Duration(days: 1))
                      .millisecondsSinceEpoch,
                ],
              ),
            ) ??
            0) >
        0;
  }

  /// I numeri in copia locale sotto [belowUid].
  Future<List<int>> cachedUidsBelow(int accountId, String folder, int belowUid) async {
    final d = await db;
    final r = await d.query(
      'messages',
      columns: ['uid'],
      where: 'account_id=? AND folder=? AND uid<?',
      whereArgs: [accountId, folder, belowUid],
    );
    return [for (final x in r) x['uid'] as int];
  }

  /// Il numero più basso in copia locale sotto [belowUid], o null se non ce ne sono.
  Future<int?> lowestCachedUid(int accountId, String folder, int belowUid) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT MIN(uid) AS u FROM messages WHERE account_id=? AND folder=? AND uid<?',
      [accountId, folder, belowUid],
    );
    return r.isEmpty ? null : r.first['u'] as int?;
  }

  /// Riallinea le email vecchie (sotto [belowUid]) a quello che dice il server:
  /// [server] ha, per ogni numero ancora presente, letto/stella/risposto.
  /// Le email in copia locale che il server non ha più vengono tolte; quelle cambiate
  /// altrove (lette, con stella) vengono aggiornate. Restituisce (aggiornate, tolte).
  Future<(int, int)> reconcileOlder(
    int accountId,
    String folder,
    int belowUid,
    Map<int, ({bool seen, bool flagged, bool answered})> server,
  ) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: ['uid', 'seen', 'flagged', 'answered'],
      where: 'account_id=? AND folder=? AND uid<?',
      whereArgs: [accountId, folder, belowUid],
    );
    final b = d.batch();
    var changed = 0, removed = 0;
    for (final r in rows) {
      final u = r['uid'] as int;
      final s = server[u];
      if (s == null) {
        b.delete(
          'messages',
          where: 'account_id=? AND folder=? AND uid=?',
          whereArgs: [accountId, folder, u],
        );
        removed++;
      } else if ((r['seen'] == 1) != s.seen ||
          (r['flagged'] == 1) != s.flagged ||
          (r['answered'] == 1) != s.answered) {
        b.update(
          'messages',
          {
            'seen': s.seen ? 1 : 0,
            'flagged': s.flagged ? 1 : 0,
            'answered': s.answered ? 1 : 0,
          },
          where: 'account_id=? AND folder=? AND uid=?',
          whereArgs: [accountId, folder, u],
        );
        changed++;
      }
    }
    if (changed + removed > 0) {
      await b.commit(noResult: true);
      notifyChanged();
    }
    return (changed, removed);
  }

  Future<int> unseenCount(int accountId, String folder) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    return Sqflite.firstIntValue(
          await d.rawQuery(
            'SELECT COUNT(*) FROM messages WHERE account_id=? AND folder=? AND seen=0 AND (snoozed_until IS NULL OR snoozed_until<=?)',
            [accountId, folder, now],
          ),
        ) ??
        0;
  }

  Future<List<Msg>> search(String q, {int? accountId, int limit = 100}) async {
    final d = await db;
    final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where:
          '(subject LIKE ? OR from_name LIKE ? OR from_addr LIKE ? OR preview LIKE ? OR body_text LIKE ?)${accountId != null ? ' AND account_id=?' : ''}',
      whereArgs: [
        like,
        like,
        like,
        like,
        like,
        if (accountId != null) accountId,
      ],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(Msg.fromRow).toList();
  }

  /// Messaggi ricevuti dopo [t] nelle cartelle «Posta in arrivo» di tutte le caselle.
  Future<List<Msg>> inboxSince(DateTime t, {int limit = 300}) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'date>=? AND UPPER(folder)=\'INBOX\'',
      whereArgs: [t.millisecondsSinceEpoch],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(Msg.fromRow).toList();
  }

  /// Messaggi rimandati il cui momento è arrivato.
  Future<List<Msg>> dueSnoozed() async {
    final d = await db;
    final rows = await d.query(
      'messages',
      columns: colonneElenco,
      where: 'snoozed_until IS NOT NULL AND snoozed_until<=?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch],
    );
    return rows.map(Msg.fromRow).toList();
  }

  // ---------- bloccati e disiscritti ----------
  Future<void> block(int accountId, String sender) async {
    final d = await db;
    await d.insert('blocked', {
      'account_id': accountId,
      'sender': sender.toLowerCase(),
      'created': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyChanged();
  }

  Future<void> unblock(int accountId, String sender) async {
    final d = await db;
    await d.delete(
      'blocked',
      where: 'account_id=? AND sender=?',
      whereArgs: [accountId, sender.toLowerCase()],
    );
    notifyChanged();
  }

  Future<List<Map<String, Object?>>> blockedList() async {
    final d = await db;
    return d.query('blocked', orderBy: 'created DESC');
  }

  /// Vero se l'indirizzo (o il suo dominio) è bloccato per questo account.
  Future<bool> isBlocked(int accountId, String address) async {
    final d = await db;
    final a = address.toLowerCase();
    final dom = a.contains('@') ? '@${a.split('@').last}' : a;
    final rows = await d.query(
      'blocked',
      where: 'account_id=? AND sender IN (?,?)',
      whereArgs: [accountId, a, dom],
    );
    return rows.isNotEmpty;
  }

  Future<void> addUnsub(
    int accountId,
    String sender,
    String name,
    String method,
  ) async {
    final d = await db;
    await d.insert('unsubs', {
      'account_id': accountId,
      'sender': sender.toLowerCase(),
      'name': name,
      'method': method,
      'at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyChanged();
  }

  Future<void> removeUnsub(int accountId, String sender) async {
    final d = await db;
    await d.delete(
      'unsubs',
      where: 'account_id=? AND sender=?',
      whereArgs: [accountId, sender.toLowerCase()],
    );
    notifyChanged();
  }

  Future<List<Map<String, Object?>>> unsubList() async {
    final d = await db;
    return d.query('unsubs', orderBy: 'at DESC');
  }

  /// Mittenti che hanno il rimando "List-Unsubscribe" nella cache (le newsletter).
  Future<List<Map<String, Object?>>> subscriptionSenders() async {
    final d = await db;
    return d.rawQuery(
      'SELECT account_id, from_addr, MAX(from_name) AS from_name, COUNT(*) AS n, MAX(date) AS last, MAX(list_unsub) AS list_unsub '
      'FROM messages WHERE list_unsub<>\'\' GROUP BY account_id, from_addr ORDER BY last DESC',
    );
  }

  /// Bloccati, disiscrizioni e rubrica, per la copia completa.
  Future<Map<String, Object?>> exportLists() async {
    final d = await db;
    return {
      'bloccati': await d.query('blocked'),
      'disiscrizioni': await d.query('unsubs'),
      'rubrica': await d.query('contacts'),
      // Gli invii ancora da fare; quelli con allegati no, i file stanno solo su questo telefono.
      'programmati': [
        for (final r in await d.query('scheduled', where: "status='pending'"))
          if (!((r['payload'] ?? '') as String).contains('/outbox/')) r,
      ],
    };
  }

  /// Rimette le liste di una copia completa; [newId] porta i numeri delle caselle
  /// della copia a quelli di questo telefono. La rubrica già presente non si tocca.
  Future<void> importLists(Map<String, dynamic> m, Map<int, int> newId) async {
    final d = await db;
    for (final r in (m['programmati'] as List? ?? const [])) {
      final x = Map<String, Object?>.from(r as Map);
      final id = newId[x['account_id']];
      if (id == null) continue;
      final p = jsonDecode(x['payload'] as String) as Map<String, dynamic>;
      p['accountId'] = id;
      await addScheduled(
        id,
        DateTime.fromMillisecondsSinceEpoch(x['send_at'] as int),
        jsonEncode(p),
      );
    }
    final b = d.batch();
    for (final t in const {'bloccati': 'blocked', 'disiscrizioni': 'unsubs'}.entries) {
      for (final r in ((m[t.key] ?? const []) as List).cast<Map>()) {
        final id = newId[r['account_id']];
        if (id == null) continue;
        b.insert(t.value, {
          ...Map<String, Object?>.from(r),
          'account_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    for (final r in ((m['rubrica'] ?? const []) as List).cast<Map>()) {
      b.insert(
        'contacts',
        Map<String, Object?>.from(r),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await b.commit(noResult: true);
    notifyChanged();
  }

  // ---------- rubrica ----------
  Future<void> touchContact(String address, String name) async {
    final d = await db;
    final a = address.toLowerCase();
    await d.rawInsert(
      'INSERT INTO contacts(address,name,uses,last) VALUES(?,?,1,?) ON CONFLICT(address) DO UPDATE SET uses=uses+1, last=excluded.last, name=CASE WHEN excluded.name<>\'\' THEN excluded.name ELSE contacts.name END',
      [a, name, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Impara un indirizzo senza contarlo come «usato» (dalle email ricevute e inviate).
  Future<void> learnContact(String address, String name) async {
    if (!address.contains('@')) return;
    final d = await db;
    await d.rawInsert(
      'INSERT OR IGNORE INTO contacts(address,name,uses,last) VALUES(?,?,0,?)',
      [address.toLowerCase(), name, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<List<Map<String, Object?>>> contacts(String q) async {
    final d = await db;
    final like = '%${q.toLowerCase()}%';
    return d.query(
      'contacts',
      where: 'address LIKE ? OR LOWER(name) LIKE ?',
      whereArgs: [like, like],
      orderBy: 'uses DESC, last DESC',
      limit: 8,
    );
  }

  Future<List<Map<String, Object?>>> allContacts() async {
    final d = await db;
    return d.query('contacts', orderBy: 'uses DESC');
  }

  // ---------- invii programmati ----------
  Future<int> addScheduled(int accountId, DateTime at, String payload) async {
    final d = await db;
    final id = await d.insert('scheduled', {
      'account_id': accountId,
      'send_at': at.millisecondsSinceEpoch,
      'payload': payload,
      'status': 'pending',
    });
    notifyChanged();
    return id;
  }

  /// Invii rimasti «in invio» da oltre 10 minuti (app chiusa a metà): l'email può essere
  /// partita o no, quindi non tornano in coda da soli (partirebbe due volte); diventano
  /// «non riusciti» e vengono restituiti perché l'app avvisi l'utente.
  Future<List<Map<String, Object?>>> staleSending() async {
    final d = await db;
    final limite =
        DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
    final rows = await d.query(
      'scheduled',
      where: "status='sending' AND (claimed IS NULL OR claimed<?)",
      whereArgs: [limite],
    );
    if (rows.isNotEmpty) {
      await d.update(
        'scheduled',
        {'status': 'failed'},
        where: "status='sending' AND (claimed IS NULL OR claimed<?)",
        whereArgs: [limite],
      );
    }
    return rows;
  }

  Future<List<Map<String, Object?>>> dueScheduled() async {
    final d = await db;
    return d.query(
      'scheduled',
      where: 'status=? AND send_at<=?',
      whereArgs: ['pending', DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<List<Map<String, Object?>>> pendingScheduled() async {
    final d = await db;
    return d.query(
      'scheduled',
      where: 'status=?',
      whereArgs: ['pending'],
      orderBy: 'send_at',
    );
  }

  Future<void> setScheduledStatus(int id, String status) async {
    final d = await db;
    if (status == 'sent' || status == 'cancelled') {
      await d.delete('scheduled', where: 'id=?', whereArgs: [id]);
    } else {
      await d.update(
        'scheduled',
        {'status': status},
        where: 'id=?',
        whereArgs: [id],
      );
    }
    notifyChanged();
  }

  /// Tutto ciò che è in coda: da spedire, in invio, o non riuscito.
  Future<List<Map<String, Object?>>> scheduledList() async {
    final d = await db;
    return d.query(
      'scheduled',
      where: "status IN ('pending','sending','failed','editing')",
      orderBy: 'send_at',
    );
  }

  Future<Map<String, Object?>?> scheduledById(int id) async {
    final d = await db;
    final r = await d.query('scheduled', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> rescheduleNow(int id) async {
    final d = await db;
    await d.update(
      'scheduled',
      {'send_at': DateTime.now().millisecondsSinceEpoch, 'status': 'pending'},
      where: 'id=?',
      whereArgs: [id],
    );
    notifyChanged();
  }

  /// Mette un invio programmato «in modifica» (Scrivi aperto su di lui): non parte finché non
  /// torna «pending». False se nel frattempo è già partito.
  Future<bool> claimEditing(int id) async {
    final d = await db;
    final n = await d.update(
      'scheduled',
      {'status': 'editing', 'claimed': DateTime.now().millisecondsSinceEpoch},
      where: "id=? AND status IN ('pending','failed')",
      whereArgs: [id],
    );
    if (n == 1) notifyChanged();
    return n == 1;
  }

  /// Un invio rimasto «in modifica» da oltre 2 ore (app chiusa con Scrivi aperto) torna in coda.
  Future<void> releaseStaleEditing() async {
    final d = await db;
    final limite =
        DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    final n = await d.update(
      'scheduled',
      {'status': 'pending'},
      where: "status='editing' AND (claimed IS NULL OR claimed<?)",
      whereArgs: [limite],
    );
    if (n > 0) notifyChanged();
  }

  /// Prende in carico un invio: restituisce false se un altro processo l'ha già preso.
  Future<bool> claimScheduled(int id) async {
    final d = await db;
    final n = await d.update(
      'scheduled',
      {'status': 'sending', 'claimed': DateTime.now().millisecondsSinceEpoch},
      where: "id=? AND status='pending'",
      whereArgs: [id],
    );
    return n == 1;
  }

  // ---------- operazioni in attesa di rete ----------
  Future<int> addPendingOp(
    int accountId,
    String op,
    String folder,
    List<int> uids,
    String arg,
  ) async {
    final d = await db;
    final id = await d.insert('pending_ops', {
      'account_id': accountId,
      'op': op,
      'folder': folder,
      'uids': jsonEncode(uids),
      'arg': arg,
      'attempts': 0,
      'created': DateTime.now().millisecondsSinceEpoch,
    });
    notifyChanged();
    return id;
  }

  /// Riporta nella copia locale le operazioni ancora in coda di una cartella (letta, stella,
  /// email tolte), che una sincronizzazione ha appena sovrascritto con lo stato del server.
  Future<void> riapplicaCoda(int accountId, String folder) async {
    final d = await db;
    final rows = await d.query(
      'pending_ops',
      where: 'account_id=? AND folder=?',
      whereArgs: [accountId, folder],
      orderBy: 'id',
    );
    for (final r in rows) {
      final uids = (jsonDecode(r['uids'] as String) as List).cast<int>();
      final on = r['arg'] == '1';
      switch (r['op']) {
        case 'seen':
          await setSeen(accountId, folder, uids, on);
        case 'flag':
          await setFlagged(accountId, folder, uids, on);
        case 'delete' || 'archive' || 'spam' || 'move':
          await deleteLocal(accountId, folder, uids);
      }
    }
  }

  Future<List<Map<String, Object?>>> pendingOps() async {
    final d = await db;
    return d.query('pending_ops', orderBy: 'id');
  }

  Future<void> deletePendingOp(int id) async {
    final d = await db;
    await d.delete('pending_ops', where: 'id=?', whereArgs: [id]);
    notifyChanged();
  }

  Future<void> bumpPendingOp(int id) async {
    final d = await db;
    await d.rawUpdate('UPDATE pending_ops SET attempts=attempts+1 WHERE id=?', [
      id,
    ]);
  }

  /// Toglie dalla cache le email più vecchie di [days] giorni (solo fuori da In arrivo).
  Future<void> deleteOlderThan(int accountId, int days) async {
    if (days <= 0) return;
    final d = await db;
    final limit = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    await d.delete(
      'messages',
      // Le rimandate esistono solo sul telefono e la stella è una scelta dell'utente: non si toccano.
      where:
          "account_id=? AND date<? AND UPPER(folder)<>'INBOX' AND snoozed_until IS NULL AND flagged=0",
      whereArgs: [accountId, limit],
    );
    notifyChanged();
  }

  // ---------- strumenti di misura delle notifiche ----------
  Future<void> logPush(
    int accountId,
    int uid,
    DateTime msgDate,
    DateTime seenAt,
    DateTime notifiedAt, {
    String result = 'ok',
  }) async {
    final d = await db;
    await d.insert('push_log', {
      'account_id': accountId,
      'uid': uid,
      'msg_date': msgDate.millisecondsSinceEpoch,
      'seen_at': seenAt.millisecondsSinceEpoch,
      'notified_at': notifiedAt.millisecondsSinceEpoch,
      'result': result,
    });
    await d.execute(
      'DELETE FROM push_log WHERE id NOT IN (SELECT id FROM push_log ORDER BY id DESC LIMIT 500)',
    );
  }

  Future<List<Map<String, Object?>>> pushLog({
    int? accountId,
    int limit = 100,
  }) async {
    final d = await db;
    return d.query(
      'push_log',
      where: accountId != null ? 'account_id=?' : null,
      whereArgs: accountId != null ? [accountId] : null,
      orderBy: 'id DESC',
      limit: limit,
    );
  }

  Future<void> setStatus(
    int accountId, {
    int? idleSince,
    bool clearIdle = false,
    int? lastEvent,
    int? lastSync,
    String? error,
    bool clearError = false,
  }) async {
    final d = await db;
    // Si scrive solo ciò che è cambiato: rileggere e riscrivere tutta la riga cancellava
    // quello che l'altro processo (servizio, schermata) aveva appena scritto.
    final v = <String, Object?>{
      if (clearIdle) 'idle_since': null else if (idleSince != null) 'idle_since': idleSince,
      if (lastEvent != null) 'last_event': lastEvent,
      if (lastSync != null) 'last_sync': lastSync,
      if (clearError) 'last_error': null else if (error != null) 'last_error': error,
    };
    await d.transaction((t) async {
      await t.insert(
        'acc_status',
        {'account_id': accountId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (v.isNotEmpty) {
        await t.update(
          'acc_status',
          v,
          where: 'account_id=?',
          whereArgs: [accountId],
        );
      }
    });
  }

  Future<Map<String, Object?>?> status(int accountId) async {
    final d = await db;
    final r = await d.query(
      'acc_status',
      where: 'account_id=?',
      whereArgs: [accountId],
    );
    return r.isEmpty ? null : r.first;
  }

  Future<void> wipeCache() async {
    final d = await db;
    // Le email «Rimandate» esistono solo sul telefono: restano. Il segno di dove era arrivata la
    // sincronizzazione resta, così la prima email che arriva dopo suona (C1).
    await d.delete('messages', where: 'snoozed_until IS NULL');
    await d.delete('push_log');
    notifyChanged();
  }
}
