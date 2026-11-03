import 'dart:io';
import 'dart:typed_data';

import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/models.dart';

/// Casella finta per i test: tiene tutto in memoria, scrive nella cache locale.
class FakeBackend implements MailBackend {
  @override
  final Account account;
  final List<Msg> server = [];
  final List<Outgoing> sent = [];
  final List<String> log = [];
  int junk = 0;
  bool listening = false;
  bool offline = false;
  Object? failMove;
  Object? sendError;

  /// Simula un server che non dice dove è finita l'email: l'annullamento della libreria fallisce.
  bool undoBroken = false;
  void _net() {
    if (offline) throw const SocketException('offline');
  }

  FakeBackend(this.account);

  static const folderList = [
    Folder('INBOX', 'INBOX', 'inbox'),
    Folder('Sent', 'Sent', 'sent'),
    Folder('Drafts', 'Drafts', 'drafts'),
    Folder('Trash', 'Trash', 'trash'),
    Folder('Junk', 'Junk', 'junk'),
    Folder('Archive', 'Archive', 'archive'),
  ];

  @override
  void riparti() {}

  @override
  Future<List<Folder>> folders() async => folderList;

  @override
  Future<List<Msg>> sync(String folder, {int count = 40}) async {
    // Stessa regola della casella vera: «nuova» = numero più alto dell'ultimo già visto.
    final inFolder = server
        .where(
          (m) =>
              m.folder == folder && !Db.i.inVolo(account.id!, folder, m.uid),
        )
        .toList();
    var st = await Db.i.folderSync(account.id!, folder);
    if (st == null) {
      final cached = await Db.i.messages(account.id!, folder, limit: 1000);
      if (cached.isNotEmpty) {
        st = (
          validity: 1,
          lastUid: cached.map((m) => m.uid).reduce((a, b) => a > b ? a : b),
        );
      }
    }
    final last = st?.lastUid ?? 0;
    final fresh = st == null
        ? <Msg>[]
        : inFolder.where((m) => m.uid > last).toList();
    final pending = folder == 'INBOX'
        ? {for (final m in fresh) if (!m.seen) m.uid}
        : <int>{};
    await Db.i.upsertMessages(inFolder, pending: pending);
    var top = last;
    for (final m in inFolder) {
      if (m.uid > top) top = m.uid;
    }
    await Db.i.setFolderSync(account.id!, folder, 1, top);
    return fresh;
  }

  @override
  Future<void> loadOlder(String folder, {int count = 40}) async {}

  @override
  Future<Msg> loadBody(Msg m) async {
    m.bodyText ??=
        'Testo di prova del messaggio ${m.uid}.\n\nCordiali saluti\nMario Rossi';
    m.bodyHtml ??= '';
    await Db.i.saveBody(
      account.id!,
      m.folder,
      m.uid,
      text: m.bodyText,
      html: m.bodyHtml,
    );
    return m;
  }

  @override
  Future<List<AttachmentInfo>> attachments(Msg m) async => m.hasAtt
      ? [const AttachmentInfo('contratto.pdf', 183000, '2', 'application/pdf')]
      : [];

  @override
  Future<Uint8List> downloadAttachment(Msg m, AttachmentInfo a) async =>
      Uint8List.fromList([1, 2, 3]);

  final Map<String, Uint8List> inlineImages = {};
  @override
  Future<Uint8List?> inlineImage(Msg m, String cid) async => inlineImages[cid];

  /// Simula un server lento a spostare (la schermata non deve aspettarlo).
  Duration moveDelay = Duration.zero;

  Future<UndoFn> _move(String from, List<int> uids, String to) async {
    _net();
    if (moveDelay > Duration.zero) await Future<void>.delayed(moveDelay);
    if (failMove != null) throw failMove!;
    final moved = server
        .where((m) => m.folder == from && uids.contains(m.uid))
        .toList();
    server.removeWhere((m) => m.folder == from && uids.contains(m.uid));
    for (final m in moved) {
      server.add(
        Msg(
          accountId: m.accountId,
          folder: to,
          uid: m.uid + 1000,
          messageId: m.messageId,
          fromName: m.fromName,
          fromAddr: m.fromAddr,
          subject: m.subject,
          date: m.date,
          seen: m.seen,
        ),
      );
    }
    log.add('move $from -> $to ${uids.join(',')}');
    return () async {
      if (undoBroken) throw StateError('Unable to undo: no target sequence');
      server.removeWhere(
        (m) => m.folder == to && uids.map((u) => u + 1000).contains(m.uid),
      );
      server.addAll(moved);
    };
  }

  @override
  Future<UndoFn> delete(String folder, List<int> uids) =>
      _move(folder, uids, 'Trash');
  @override
  Future<UndoFn> archive(String folder, List<int> uids) =>
      _move(folder, uids, 'Archive');
  @override
  Future<UndoFn> spam(String folder, List<int> uids) =>
      _move(folder, uids, 'Junk');
  @override
  Future<UndoFn> notSpam(String folder, List<int> uids) =>
      _move(folder, uids, 'INBOX');
  @override
  Future<UndoFn> moveTo(String folder, List<int> uids, String targetPath) =>
      _move(folder, uids, targetPath);

  @override
  Future<Map<int, String>> messageIdsOf(String folder, List<int> uids) async {
    if (moveDelay > Duration.zero) await Future<void>.delayed(moveDelay);
    return {};
  }

  @override
  Future<int> restoreByMessageId(
    String origFolder,
    List<String> messageIds, {
    String? alsoIn,
  }) async {
    _net();
    var n = 0;
    for (final f in ['Trash', 'Junk', 'Archive', if (alsoIn != null) alsoIn]) {
      final back = server
          .where((m) => m.folder == f && messageIds.contains(m.messageId))
          .toList();
      server.removeWhere((m) => back.contains(m));
      for (final m in back) {
        server.add(
          Msg(
            accountId: m.accountId,
            folder: origFolder,
            uid: m.uid + 2000,
            messageId: m.messageId,
            fromName: m.fromName,
            fromAddr: m.fromAddr,
            subject: m.subject,
            date: m.date,
            seen: m.seen,
          ),
        );
        n++;
      }
    }
    log.add('restore $origFolder $n');
    return n;
  }

  @override
  Future<void> setSeen(String folder, List<int> uids, bool seen) async {
    _net();
    for (final m in server) {
      if (m.folder == folder && uids.contains(m.uid)) m.seen = seen;
    }
    log.add('seen $seen ${uids.join(',')}');
  }

  @override
  Future<List<String>> draftBcc(Msg m) async => const [];

  @override
  Future<void> setAnswered(String folder, List<int> uids) async {}

  @override
  Future<void> setFlagged(String folder, List<int> uids, bool flagged) async {
    _net();
    for (final m in server) {
      if (m.folder == folder && uids.contains(m.uid)) m.flagged = flagged;
    }
  }

  @override
  Future<void> emptyTrash(String trashPath) async =>
      server.removeWhere((m) => m.folder == trashPath);

  @override
  Future<void> createFolder(String name) async {}

  @override
  Future<void> send(Outgoing m) async {
    _net();
    if (sendError != null) throw sendError!;
    sent.add(m);
  }

  @override
  Future<DraftRef?> saveDraft(Outgoing m) async {
    _net();
    log.add('draft');
    final uid = 5000 + drafts.length + 1;
    drafts[uid] = m;
    return DraftRef('Drafts', uid);
  }

  /// Le bozze che stanno sul finto server (uid → contenuto).
  final Map<int, Outgoing> drafts = {};

  @override
  Future<void> discardDraft(String folder, int uid) async {
    _net();
    drafts.remove(uid);
    server.removeWhere((x) => x.folder == folder && x.uid == uid);
    await Db.i.deleteLocal(account.id!, folder, [uid]);
    log.add('discard $uid');
  }

  @override
  Future<List<Msg>> searchServer(
    String text, {
    String folder = 'INBOX',
  }) async {
    _net();
    return server.where((m) => m.subject.contains(text)).toList();
  }

  @override
  Future<int> junkUnseen() async => junk;

  @override
  Future<void> startListening(
    void Function(String folder) onNew,
    void Function(Object error) onError,
  ) async => listening = true;

  @override
  Future<void> stopListening() async => listening = false;

  @override
  Future<void> dispose() async {}
}

Msg testMsg(
  int accountId,
  int uid,
  String from,
  String subject, {
  bool seen = false,
  DateTime? date,
  String folder = 'INBOX',
  String preview = '',
  bool att = false,
  bool flagged = false,
}) => Msg(
  accountId: accountId,
  folder: folder,
  uid: uid,
  fromName: from,
  fromAddr: '${from.toLowerCase().replaceAll(' ', '.')}@esempio.it',
  toAddrs: 'utente@esempio.it',
  subject: subject,
  date: date ?? DateTime.now().subtract(Duration(minutes: uid * 37)),
  preview: preview,
  seen: seen,
  hasAtt: att,
  flagged: flagged,
);
