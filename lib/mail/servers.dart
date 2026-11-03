import 'package:enough_mail/enough_mail.dart' as em;

import '../models.dart';

/// Impostazioni di server di una casella, rilevate dall'indirizzo.
class ServerGuess {
  final AccountKind kind;
  final String imapHost;
  final int imapPort;
  final bool imapSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpSsl;
  final bool needsAppPassword;
  final bool oauthMicrosoft;
  final bool saveSent;
  final String? appPasswordUrl;
  final String note;
  const ServerGuess({
    required this.kind,
    required this.imapHost,
    this.imapPort = 993,
    this.imapSsl = true,
    required this.smtpHost,
    this.smtpPort = 465,
    this.smtpSsl = true,
    this.needsAppPassword = false,
    this.oauthMicrosoft = false,
    this.saveSent = true,
    this.appPasswordUrl,
    this.note = '',
  });
}

const _gmail = ServerGuess(
  kind: AccountKind.gmail,
  imapHost: 'imap.gmail.com',
  smtpHost: 'smtp.gmail.com',
  needsAppPassword: true,
  saveSent: false,
  appPasswordUrl: 'https://myaccount.google.com/apppasswords',
  note:
      'Gmail: serve una «password per app» (richiede la verifica in 2 passaggi).',
);
const _outlook = ServerGuess(
  kind: AccountKind.outlook,
  imapHost: 'outlook.office365.com',
  smtpHost: 'smtp-mail.outlook.com',
  smtpPort: 587,
  smtpSsl: false,
  oauthMicrosoft: true,
  saveSent: false,
  note: 'Outlook/Hotmail: accesso con account Microsoft.',
);
const _icloud = ServerGuess(
  kind: AccountKind.icloud,
  imapHost: 'imap.mail.me.com',
  smtpHost: 'smtp.mail.me.com',
  smtpPort: 587,
  smtpSsl: false,
  needsAppPassword: true,
  appPasswordUrl: 'https://account.apple.com/account/manage',
  note: 'iCloud: serve una «password specifica per app» creata sul sito Apple.',
);
const _yahoo = ServerGuess(
  kind: AccountKind.yahoo,
  imapHost: 'imap.mail.yahoo.com',
  smtpHost: 'smtp.mail.yahoo.com',
  needsAppPassword: true,
  appPasswordUrl: 'https://login.yahoo.com/account/security',
  note: 'Yahoo: serve una «password per app» creata sul sito Yahoo.',
);
const _aol = ServerGuess(
  kind: AccountKind.other,
  imapHost: 'imap.aol.com',
  smtpHost: 'smtp.aol.com',
  needsAppPassword: true,
  note: 'AOL: serve una «password per app».',
);

const _outlookDomains = {
  'outlook.com',
  'hotmail.com',
  'live.com',
  'msn.com',
  'outlook.it',
  'hotmail.it',
  'live.it',
  'outlook.ch',
  'hotmail.ch',
  'hotmail.fr',
  'outlook.fr',
  'live.fr',
  'hotmail.de',
  'outlook.de',
};

/// Riconoscimento istantaneo dei fornitori noti, senza rete.
ServerGuess? presetFor(String address) {
  final d = address.split('@').last.toLowerCase();
  if (d == 'gmail.com' || d == 'googlemail.com') return _gmail;
  if (_outlookDomains.contains(d)) return _outlook;
  if (d == 'icloud.com' || d == 'me.com' || d == 'mac.com') return _icloud;
  if (d.startsWith('yahoo.') || d == 'ymail.com') return _yahoo;
  if (d == 'aol.com') return _aol;
  return null;
}

/// Rileva i server: prima i fornitori noti, poi il rilevamento automatico
/// (autoconfig del dominio e archivio Mozilla), infine il tentativo `imap.dominio`.
Future<ServerGuess> detectServers(String address) async {
  final known = presetFor(address);
  if (known != null) return known;
  final domain = address.split('@').last.toLowerCase();
  try {
    final cfg = await em.Discover.discover(
      address,
      isLogEnabled: false,
    ).timeout(const Duration(seconds: 15));
    if (cfg != null &&
        cfg.preferredIncomingImapServer != null &&
        cfg.preferredOutgoingSmtpServer != null) {
      final i = cfg.preferredIncomingImapServer!;
      final o = cfg.preferredOutgoingSmtpServer!;
      return ServerGuess(
        kind: AccountKind.other,
        imapHost: i.hostname,
        imapPort: i.port,
        imapSsl: _isSsl(i.socketType, i.port),
        smtpHost: o.hostname,
        smtpPort: o.port,
        smtpSsl: _isSsl(o.socketType, o.port),
        note: 'Server rilevati automaticamente.',
      );
    }
  } catch (_) {}
  return ServerGuess(
    kind: AccountKind.other,
    imapHost: 'imap.$domain',
    smtpHost: 'smtp.$domain',
    note: 'Server non rilevati: controllo imap.$domain e smtp.$domain.',
  );
}

/// Cifratura diretta (SSL) o STARTTLS. Se il server non dichiara niente, decide la porta:
/// 993 e 465 sono sempre SSL, le altre (143, 587, 25) partono in chiaro e passano a STARTTLS.
bool _isSsl(em.SocketType t, int port) {
  if (t == em.SocketType.ssl) return true;
  if (t == em.SocketType.starttls) return false;
  return port == 993 || port == 465;
}
