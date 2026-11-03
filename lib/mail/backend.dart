import 'dart:typed_data';

import '../models.dart';

/// Messaggio in uscita (nuovo, risposta, inoltro, bozza o invio programmato).
class Outgoing {
  int accountId;
  String fromAddress;
  String fromName;
  List<String> to;
  List<String> cc;
  List<String> bcc;
  String subject;
  String text;
  String html;
  List<String> attachmentPaths;
  String? inReplyTo;
  String? references;

  Outgoing({
    required this.accountId,
    required this.fromAddress,
    this.fromName = '',
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.text = '',
    this.html = '',
    this.attachmentPaths = const [],
    this.inReplyTo,
    this.references,
  });

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'fromAddress': fromAddress,
    'fromName': fromName,
    'to': to,
    'cc': cc,
    'bcc': bcc,
    'subject': subject,
    'text': text,
    'html': html,
    'attachmentPaths': attachmentPaths,
    'inReplyTo': inReplyTo,
    'references': references,
  };

  factory Outgoing.fromJson(Map<String, dynamic> j) => Outgoing(
    accountId: j['accountId'] as int,
    fromAddress: j['fromAddress'] as String,
    fromName: (j['fromName'] ?? '') as String,
    to: List<String>.from(j['to'] as List),
    cc: List<String>.from(j['cc'] as List),
    bcc: List<String>.from(j['bcc'] as List),
    subject: (j['subject'] ?? '') as String,
    text: (j['text'] ?? '') as String,
    html: (j['html'] ?? '') as String,
    attachmentPaths: List<String>.from(j['attachmentPaths'] as List),
    inReplyTo: j['inReplyTo'] as String?,
    references: j['references'] as String?,
  );
}

/// Dove sta una bozza sul server.
class DraftRef {
  final String folder;
  final int uid;
  const DraftRef(this.folder, this.uid);
}

class AttachmentInfo {
  final String name;
  final int size;
  final String fetchId;
  final String mediaType;
  const AttachmentInfo(this.name, this.size, this.fetchId, this.mediaType);
}

typedef UndoFn = Future<void> Function();

/// Avvisi che l'invio lascia per chi lo ha chiesto, senza far fallire l'invio.
class SendNotes {
  SendNotes._();

  /// Per esempio: l'email è partita ma la copia in «Inviata» non si è salvata.
  static String? warning;
}

/// Tutto quello che l'app chiede a una casella. L'implementazione vera parla
/// IMAP/SMTP; nei test c'è una casella finta.
/// Il server SMTP non ha risposto dopo che l'email gli era già stata consegnata (o forse no):
/// non è un errore di rete da riprovare, o l'email partirebbe due volte.
class InvioIncerto implements Exception {
  final String message;
  const InvioIncerto([
    this.message =
        "Il server non ha confermato l'invio: controlla in «Inviata» e, se manca, riprova da «Programmati».",
  ]);
  @override
  String toString() => message;
}

abstract class MailBackend {
  Account get account;
  Future<List<Folder>> folders();

  /// Aggiorna la cache locale di una cartella e restituisce i messaggi nuovi.
  Future<List<Msg>> sync(String folder, {int count = 40});

  /// Carica altri messaggi più vecchi di quelli in cache.
  Future<void> loadOlder(String folder, {int count = 40});

  /// Scarica il corpo del messaggio e lo salva in cache.
  Future<Msg> loadBody(Msg m);
  Future<List<AttachmentInfo>> attachments(Msg m);
  Future<Uint8List> downloadAttachment(Msg m, AttachmentInfo a);

  /// Byte dell'immagine incorporata nel messaggio con quel Content-ID (per le firme).
  Future<Uint8List?> inlineImage(Msg m, String cid);

  Future<UndoFn> delete(String folder, List<int> uids);
  Future<UndoFn> archive(String folder, List<int> uids);
  Future<UndoFn> spam(String folder, List<int> uids);
  Future<UndoFn> notSpam(String folder, List<int> uids);
  Future<UndoFn> moveTo(String folder, List<int> uids, String targetPath);
  Future<void> setSeen(String folder, List<int> uids, bool seen);
  Future<void> setFlagged(String folder, List<int> uids, bool flagged);

  /// Rimette in [origFolder] le email con questi Message-ID che si trovano in Cestino, Spam,
  /// Archivio o [alsoIn]. Serve all'«Annulla» quando l'annullamento della libreria non basta.
  /// Non fa niente se le email sono già tornate. Restituisce quante ne ha rimesse.
  Future<int> restoreByMessageId(
    String origFolder,
    List<String> messageIds, {
    String? alsoIn,
  }) async => 0;

  /// Message-ID letti dal server per questi uid (la lista non sempre li porta).
  Future<Map<int, String>> messageIdsOf(String folder, List<int> uids) async =>
      {};

  /// I Ccn di una bozza: la lista non li porta, stanno solo nell'email salvata.
  Future<List<String>> draftBcc(Msg m) async => const [];

  /// Segno «risposto» sul server, come lo mette Edison.
  Future<void> setAnswered(String folder, List<int> uids) async {}
  Future<void> emptyTrash(String trashPath);
  Future<void> createFolder(String name);
  Future<void> send(Outgoing m);

  /// Salva la bozza e dice dov'è finita (null se il server non lo dice).
  Future<DraftRef?> saveDraft(Outgoing m);

  /// Toglie del tutto una bozza vecchia, senza passare dal cestino.
  Future<void> discardDraft(String folder, int uid);

  /// Cerca sul server nella cartella [folder]; se il server non risponde lancia l'errore.
  Future<List<Msg>> searchServer(String text, {String folder = 'INBOX'});

  /// Numero di messaggi non letti nello spam (per l'avviso).
  Future<int> junkUnseen();

  /// Ascolto in tempo reale (IDLE). [onNew] riceve i messaggi nuovi.
  Future<void> startListening(
    void Function(String folder) onNew,
    void Function(Object error) onError,
  );
  Future<void> stopListening();
  Future<void> dispose();

  /// Riapertura dell'app dopo una pausa lunga: la connessione di prima è da buttare e le
  /// richieste rimaste appese su di lei non devono far aspettare quelle nuove.
  void riparti() {}
}

/// Punto unico da cui l'app ottiene la casella di un account.
class Backends {
  Backends._();
  static final Map<int, MailBackend> _cache = {};
  static MailBackend Function(Account) factory = (a) =>
      throw StateError('Backend non configurato');

  static MailBackend of(Account a) =>
      _cache.putIfAbsent(a.id!, () => factory(a));

  static Future<void> forget(int accountId) async {
    final b = _cache.remove(accountId);
    await b?.dispose();
  }

  static Future<void> forgetAll() async {
    for (final b in _cache.values) {
      await b.dispose();
    }
    _cache.clear();
  }
}
