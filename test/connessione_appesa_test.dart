import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/mail/imap_backend.dart';
import 'package:digimail/mail/secrets.dart';
import 'package:digimail/models.dart';
import 'package:digimail/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Server IMAP finto sulla porta locale: risponde a saluto, LOGIN, CAPABILITY, LIST e
/// SELECT (cartella vuota). Alla prima richiesta di un corpo (`BODY.PEEK[]`) resta muto
/// per sempre, come una connessione morta che il telefono non si è accorto di aver perso.
class ServerMuto {
  late ServerSocket _srv;
  int get porta => _srv.port;
  int connessioni = 0;
  int fetchMuti = 0;
  final List<Socket> _aperte = [];

  Future<void> avvia() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((s) {
      connessioni++;
      _aperte.add(s);
      s.write('* OK Server di prova pronto\r\n');
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((riga) {
            final parti = riga.split(' ');
            if (parti.length < 2) return;
            final tag = parti[0];
            final cmd = parti[1].toUpperCase();
            final resto = riga.toUpperCase();
            if (cmd == 'LOGIN') {
              s.write('$tag OK LOGIN completato\r\n');
            } else if (cmd == 'CAPABILITY') {
              s.write('* CAPABILITY IMAP4rev1 UIDPLUS\r\n$tag OK fatto\r\n');
            } else if (cmd == 'LIST' || cmd == 'LSUB') {
              s.write('* $cmd (\\HasNoChildren) "/" "INBOX"\r\n$tag OK fatto\r\n');
            } else if (cmd == 'SELECT' || cmd == 'EXAMINE') {
              s.write(
                '* 0 EXISTS\r\n* 0 RECENT\r\n* FLAGS (\\Seen)\r\n'
                '* OK [UIDVALIDITY 1] ok\r\n* OK [UIDNEXT 1] ok\r\n'
                '$tag OK [READ-WRITE] SELECT completato\r\n',
              );
            } else if (resto.contains('BODY.PEEK[]') || resto.contains('BODY[]')) {
              fetchMuti++; // connessione morta: nessuna risposta, mai.
            } else if (cmd == 'LOGOUT') {
              s.write('* BYE\r\n$tag OK fatto\r\n');
              s.close();
            } else {
              s.write('$tag OK fatto\r\n');
            }
          }, onError: (_) {}, onDone: () {});
    });
  }

  Future<void> chiudi() async {
    for (final s in _aperte) {
      try {
        s.destroy();
      } catch (_) {}
    }
    await _srv.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late ServerMuto srv;
  late Account a;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    Settings.i.useForTest(await SharedPreferences.getInstance());
    await Db.i.openForTest();
    await Backends.forgetAll();
    srv = ServerMuto();
    await srv.avvia();
    final id = await Db.i.saveAccount(
      Account(
        address: 'utente@esempio.it',
        name: 'Prova',
        imapHost: '127.0.0.1',
        imapPort: srv.porta,
        imapSsl: false,
        smtpHost: '127.0.0.1',
      ),
    );
    await Secrets.setPassword(id, 'segreta');
    a = (await Db.i.account(id))!;
  });

  tearDown(() async {
    await Backends.forgetAll();
    await srv.chiudi();
  });

  test(
    'una richiesta a cui il server non risponde mai non blocca per sempre quelle dopo',
    () async {
      ImapBackend.limiteCorpo = const Duration(seconds: 2);
      final b = ImapBackend(a);
      // l'utente apre un'email: il corpo si chiede al server, che non risponde più
      // (connessione morta). La libreria aspetta questa risposta senza limite di tempo.
      final corpo = b.loadBody(
        Msg(accountId: a.id!, folder: 'INBOX', uid: 1, subject: 'x', date: DateTime.now()),
      );
      Object? errore;
      corpo.catchError((Object e) {
        errore = e;
        return Msg(accountId: a.id!, folder: 'INBOX', uid: 1, date: DateTime.now());
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(srv.fetchMuti, 1, reason: 'il server ha ricevuto la richiesta e tace');

      // l'utente riapre l'app: l'aggiornamento deve finire, non caricare all'infinito.
      final t = Stopwatch()..start();
      await b.sync('INBOX').timeout(const Duration(seconds: 15));
      expect(t.elapsed, lessThan(const Duration(seconds: 10)));
      // La richiesta appesa è stata abbandonata con un errore, non lasciata in sospeso.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(errore, isA<TimeoutException>());
      // La connessione morta è stata buttata e se n'è aperta una nuova.
      expect(srv.connessioni, greaterThanOrEqualTo(2));
      await b.dispose();
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'ripresa dopo la pausa: l\'aggiornamento parte subito, la richiesta appesa si rifà dopo',
    () async {
      ImapBackend.limiteCorpo = const Duration(seconds: 3);
      final b = ImapBackend(a);
      Object? errore;
      b.loadBody(
        Msg(accountId: a.id!, folder: 'INBOX', uid: 1, subject: 'x', date: DateTime.now()),
      ).catchError((Object e) {
        errore = e;
        return Msg(accountId: a.id!, folder: 'INBOX', uid: 1, date: DateTime.now());
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(srv.fetchMuti, 1);

      // Riapertura dell'app dopo una pausa lunga: non si aspetta che la richiesta appesa scada.
      b.riparti();
      final t = Stopwatch()..start();
      await b.sync('INBOX').timeout(const Duration(seconds: 5));
      expect(t.elapsed, lessThan(const Duration(seconds: 2)));
      expect(srv.connessioni, 2);

      // La richiesta appesa, scaduta, si rimette in coda sulla connessione nuova (e riprova
      // una volta): fallisce solo dopo, con un errore chiaro, senza buttare la connessione buona.
      // (3 s di limite, poi riprova: altri 3 s; con un margine.)
      await Future<void>.delayed(const Duration(seconds: 11));
      expect(srv.fetchMuti, 3);
      expect(errore, isA<TimeoutException>());
      final t2 = Stopwatch()..start();
      await b.sync('INBOX').timeout(const Duration(seconds: 5));
      expect(t2.elapsed, lessThan(const Duration(seconds: 2)));
      await b.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'senza limite (com\'era prima) l\'aggiornamento resta in coda per sempre',
    () async {
      ImapBackend.limiteCorpo = const Duration(hours: 1);
      final b = ImapBackend(a);
      b.loadBody(
        Msg(accountId: a.id!, folder: 'INBOX', uid: 1, subject: 'x', date: DateTime.now()),
      ).catchError((Object _) => Msg(accountId: a.id!, folder: 'INBOX', uid: 1, date: DateTime.now()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await expectLater(
        b.sync('INBOX').timeout(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
      ImapBackend.limiteCorpo = const Duration(seconds: 45);
      // Niente dispose: la richiesta appesa terrebbe fermo anche quello (è il difetto).
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
