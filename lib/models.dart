import 'dart:convert';

enum AccountKind { gmail, outlook, icloud, yahoo, other }

class Alias {
  final String address;
  final String name;
  const Alias(this.address, this.name);
  Map<String, dynamic> toJson() => {'a': address, 'n': name};
  factory Alias.fromJson(Map<String, dynamic> j) =>
      Alias(j['a'] as String, (j['n'] ?? '') as String);
}

class Account {
  int? id;
  String address;
  String name; // nome scelto dall'utente, mostrato al posto dell'indirizzo
  String senderName;
  int color;
  String? logoPath;
  AccountKind kind;
  String imapHost;
  int imapPort;
  bool imapSsl; // true = TLS diretto, false = STARTTLS
  String smtpHost;
  int smtpPort;
  bool smtpSsl;
  String authType; // 'password' | 'oauth_ms'
  String loginName;
  String signatureHtml;
  bool bccSelf;
  bool notify;
  bool saveSent;
  int position;
  List<Alias> aliases;

  Account({
    this.id,
    required this.address,
    required this.name,
    this.senderName = '',
    this.color = 0xFF0B57D0,
    this.logoPath,
    this.kind = AccountKind.other,
    required this.imapHost,
    this.imapPort = 993,
    this.imapSsl = true,
    required this.smtpHost,
    this.smtpPort = 465,
    this.smtpSsl = true,
    this.authType = 'password',
    this.loginName = '',
    this.signatureHtml = '',
    this.bccSelf = false,
    this.notify = true,
    this.saveSent = true,
    this.position = 0,
    this.aliases = const [],
  });

  String get login => loginName.isEmpty ? address : loginName;
  String get initial =>
      (name.isNotEmpty ? name : address).substring(0, 1).toUpperCase();
  String get displaySender => senderName.isNotEmpty ? senderName : name;

  Map<String, Object?> toRow() => {
    if (id != null) 'id': id,
    'address': address,
    'name': name,
    'sender_name': senderName,
    'color': color,
    'logo_path': logoPath,
    'kind': kind.name,
    'imap_host': imapHost,
    'imap_port': imapPort,
    'imap_ssl': imapSsl ? 1 : 0,
    'smtp_host': smtpHost,
    'smtp_port': smtpPort,
    'smtp_ssl': smtpSsl ? 1 : 0,
    'auth_type': authType,
    'login_name': loginName,
    'signature_html': signatureHtml,
    'bcc_self': bccSelf ? 1 : 0,
    'notify': notify ? 1 : 0,
    'save_sent': saveSent ? 1 : 0,
    'position': position,
    'aliases': jsonEncode(aliases.map((a) => a.toJson()).toList()),
  };

  factory Account.fromRow(Map<String, Object?> r) => Account(
    id: r['id'] as int,
    address: r['address'] as String,
    name: (r['name'] ?? '') as String,
    senderName: (r['sender_name'] ?? '') as String,
    color: r['color'] as int,
    logoPath: r['logo_path'] as String?,
    kind: AccountKind.values.firstWhere(
      (k) => k.name == r['kind'],
      orElse: () => AccountKind.other,
    ),
    imapHost: r['imap_host'] as String,
    imapPort: r['imap_port'] as int,
    imapSsl: (r['imap_ssl'] as int) == 1,
    smtpHost: r['smtp_host'] as String,
    smtpPort: r['smtp_port'] as int,
    smtpSsl: (r['smtp_ssl'] as int) == 1,
    authType: (r['auth_type'] ?? 'password') as String,
    loginName: (r['login_name'] ?? '') as String,
    signatureHtml: (r['signature_html'] ?? '') as String,
    bccSelf: (r['bcc_self'] as int) == 1,
    notify: (r['notify'] as int) == 1,
    saveSent: (r['save_sent'] as int) == 1,
    position: (r['position'] ?? 0) as int,
    aliases: ((jsonDecode((r['aliases'] ?? '[]') as String) as List)
        .map((e) => Alias.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList()),
  );
}

/// Riga della cache locale di un messaggio.
class Msg {
  final int accountId;
  final String folder;
  final int uid;
  String messageId;
  String fromName;
  String fromAddr;
  String toAddrs;
  String ccAddrs;
  String subject;
  DateTime date;
  String preview;
  bool seen;
  bool flagged;
  bool answered;
  bool hasAtt;
  String listUnsub;
  bool listUnsubPost;
  String authResults;
  /// Reply-To diverso da «Da» (vuoto se non c'è) e catena References, per rispondere come si deve.
  String replyTo;
  String refs;
  String? bodyText;
  String? bodyHtml;
  DateTime? snoozedUntil;

  Msg({
    required this.accountId,
    required this.folder,
    required this.uid,
    this.messageId = '',
    this.fromName = '',
    this.fromAddr = '',
    this.toAddrs = '',
    this.ccAddrs = '',
    this.subject = '',
    required this.date,
    this.preview = '',
    this.seen = false,
    this.flagged = false,
    this.answered = false,
    this.hasAtt = false,
    this.listUnsub = '',
    this.listUnsubPost = false,
    this.authResults = '',
    this.replyTo = '',
    this.refs = '',
    this.bodyText,
    this.bodyHtml,
    this.snoozedUntil,
  });

  String get sender => fromName.isNotEmpty ? fromName : fromAddr;
  String get key => '$accountId|$folder|$uid';

  Map<String, Object?> toRow() => {
    'account_id': accountId,
    'folder': folder,
    'uid': uid,
    'message_id': messageId,
    'from_name': fromName,
    'from_addr': fromAddr,
    'to_addrs': toAddrs,
    'cc_addrs': ccAddrs,
    'subject': subject,
    'date': date.millisecondsSinceEpoch,
    'preview': preview,
    'seen': seen ? 1 : 0,
    'flagged': flagged ? 1 : 0,
    'answered': answered ? 1 : 0,
    'has_att': hasAtt ? 1 : 0,
    'list_unsub': listUnsub,
    'list_unsub_post': listUnsubPost ? 1 : 0,
    'auth_results': authResults,
    'reply_to': replyTo,
    'refs': refs,
    'body_text': bodyText,
    'body_html': bodyHtml,
    'snoozed_until': snoozedUntil?.millisecondsSinceEpoch,
  };

  factory Msg.fromRow(Map<String, Object?> r) => Msg(
    accountId: r['account_id'] as int,
    folder: r['folder'] as String,
    uid: r['uid'] as int,
    messageId: (r['message_id'] ?? '') as String,
    fromName: (r['from_name'] ?? '') as String,
    fromAddr: (r['from_addr'] ?? '') as String,
    toAddrs: (r['to_addrs'] ?? '') as String,
    ccAddrs: (r['cc_addrs'] ?? '') as String,
    subject: (r['subject'] ?? '') as String,
    date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int),
    preview: (r['preview'] ?? '') as String,
    seen: (r['seen'] as int) == 1,
    flagged: (r['flagged'] as int) == 1,
    answered: (r['answered'] ?? 0) == 1,
    hasAtt: (r['has_att'] as int) == 1,
    listUnsub: (r['list_unsub'] ?? '') as String,
    listUnsubPost: (r['list_unsub_post'] ?? 0) == 1,
    authResults: (r['auth_results'] ?? '') as String,
    replyTo: (r['reply_to'] ?? '') as String,
    refs: (r['refs'] ?? '') as String,
    bodyText: r['body_text'] as String?,
    bodyHtml: r['body_html'] as String?,
    snoozedUntil: r['snoozed_until'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['snoozed_until'] as int),
  );
}

/// Cartella con ruolo (inbox, sent, ...).
class Folder {
  final String path;
  final String name;
  final String role; // inbox, sent, drafts, trash, junk, archive, other
  final int unseen;
  final String sep;
  const Folder(
    this.path,
    this.name,
    this.role, {
    this.unseen = 0,
    this.sep = '/',
  });

  /// Percorso della cartella madre, se questa è una sottocartella.
  String? get parentPath {
    if (sep.isEmpty) return null;
    final i = path.lastIndexOf(sep);
    return i <= 0 ? null : path.substring(0, i);
  }

  String get label {
    switch (role) {
      case 'inbox':
        return 'Posta in arrivo';
      case 'sent':
        return 'Inviata';
      case 'drafts':
        return 'Bozze';
      case 'trash':
        return 'Cestino';
      case 'junk':
        return 'Spam';
      case 'archive':
        return 'Archivio';
      default:
        return name;
    }
  }
}
