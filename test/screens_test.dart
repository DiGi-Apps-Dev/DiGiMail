import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:digimail/db.dart';
import 'package:digimail/mail/backend.dart';
import 'package:digimail/models.dart';
import 'package:digimail/ops.dart';
import 'package:digimail/rules.dart';
import 'package:digimail/settings.dart';
import 'package:digimail/theme.dart';
import 'package:digimail/ui/account_screens.dart';
import 'package:digimail/ui/add_account_screen.dart';
import 'package:digimail/ui/compose_screen.dart';
import 'package:digimail/ui/mailbox_screen.dart';
import 'package:digimail/ui/message_screen.dart';
import 'package:digimail/ui/rules_screen.dart';
import 'package:digimail/ui/scheduled_screen.dart';
import 'package:digimail/ui/search_screen.dart';
import 'package:digimail/ui/settings_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart';

final String outDir =
    Platform.environment['DIGIMAIL_SHOTS'] ??
    '${Directory.systemTemp.path}/digimail_shots';

Future<void> loadFonts() async {
  const base = 'C:/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['regular', 'medium', 'bold', 'black', 'italic', 'light']) {
    roboto.addFont(
      Future.value(
        ByteData.view(File('$base/roboto-$f.ttf').readAsBytesSync().buffer),
      ),
    );
  }
  await roboto.load();
  final light = FontLoader('RobotoLight')
    ..addFont(
      Future.value(
        ByteData.view(
          File('assets/fonts/RobotoLight.ttf').readAsBytesSync().buffer,
        ),
      ),
    );
  await light.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        ByteData.view(
          File('$base/materialicons-regular.otf').readAsBytesSync().buffer,
        ),
      ),
    );
  await icons.load();
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> shot(WidgetTester t, String name, GlobalKey key) async {
  await t.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.4);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = File('$outDir/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

bool isGrey(Color c) {
  final r = (c.r * 255).round(),
      g = (c.g * 255).round(),
      b = (c.b * 255).round();
  final a = c.a;
  if (a < 0.05) return false;
  if (a < 0.97) return true; // trasparenza = testo schiarito
  final neutral = (r - g).abs() < 10 && (g - b).abs() < 10;
  return neutral && r > 24 && r < 232;
}

void collect(InlineSpan s, Color inherited, List<String> out, String where) {
  if (s is TextSpan) {
    final c = s.style?.color ?? inherited;
    final txt = s.text;
    // Le icone (graffetta, risposto) grigie le ha chieste l'utente: la regola vale per il testo.
    final icon = s.style?.fontFamily == 'MaterialIcons';
    if (!icon && txt != null && txt.trim().isNotEmpty && isGrey(c))
      out.add('$where: «$txt» (${txt.codeUnits.take(12).join(',')}) colore $c');
    for (final ch in s.children ?? const <InlineSpan>[]) {
      collect(ch, c, out, where);
    }
  }
}

List<String> greyTexts(WidgetTester t, String where) {
  final out = <String>[];
  for (final w in t.widgetList<RichText>(find.byType(RichText))) {
    collect(w.text, const Color(0xFF000000), out, where);
  }
  return out;
}

Widget app(Widget home, GlobalKey key) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(dark: false).copyWith(
      textTheme: buildTheme(dark: false).textTheme.apply(fontFamily: 'Roboto'),
      appBarTheme: buildTheme(dark: false).appBarTheme.copyWith(
        titleTextStyle: buildTheme(dark: false).appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
      ),
    ),
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      FlutterQuillLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Account a1, a2, a3;
  final fakes = <int, FakeBackend>{};

  Future<void> seed(WidgetTester t) async {
    FlutterSecureStorage.setMockInitialValues({});
    await Backends.forgetAll();
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      Settings.i.useForTest(await SharedPreferences.getInstance());
      await initializeDateFormatting('it');
      await Db.i.openForTest();
      final id1 = await Db.i.saveAccount(
        Account(
          address: 'utente@esempio.com',
          name: 'Personale',
          color: 0xFF0B57D0,
          kind: AccountKind.gmail,
          imapHost: 'imap.gmail.com',
          smtpHost: 'smtp.gmail.com',
          signatureHtml:
              'Mario<br>Via Roma 1<br><a href="https://esempio.it">esempio.it</a>',
          aliases: const [Alias('info@esempio.org', 'Mario Info')],
        ),
      );
      final id2 = await Db.i.saveAccount(
        Account(
          address: 'lavoro@studio.ch',
          name: 'Studio',
          color: 0xFF2E7D32,
          imapHost: 'imap.studio.ch',
          smtpHost: 'smtp.studio.ch',
        ),
      );
      final id3 = await Db.i.saveAccount(
        Account(
          address: 'mario@outlook.example',
          name: 'Outlook',
          color: 0xFFC62828,
          kind: AccountKind.outlook,
          imapHost: 'outlook.office365.com',
          smtpHost: 'smtp-mail.outlook.com',
        ),
      );
      a1 = (await Db.i.account(id1))!;
      a2 = (await Db.i.account(id2))!;
      a3 = (await Db.i.account(id3))!;
      for (final a in [a1, a2, a3]) {
        final b = FakeBackend(a);
        fakes[a.id!] = b;
      }
      Backends.factory = (a) => fakes[a.id!]!;
      final now = DateTime.now();
      final m1 = [
        testMsg(
          id1,
          1,
          'Anna Bianchi',
          'Cena di sabato?',
          preview:
              'Ciao Mario, ti va di venire da noi sabato sera? Portiamo il vino.',
          date: now.subtract(const Duration(minutes: 12)),
        ),
        testMsg(
          id1,
          2,
          'Banca Alfa',
          'Estratto conto di ottobre',
          preview: 'Il tuo estratto conto è disponibile nell\'area riservata.',
          att: true,
          date: now.subtract(const Duration(hours: 3)),
        ),
        testMsg(
          id1,
          3,
          'Negozio Sport',
          'Sconti fino al 50%',
          preview: 'Solo per oggi, approfitta delle offerte.',
          seen: true,
          date: now.subtract(const Duration(days: 1)),
        ),
        testMsg(
          id1,
          4,
          'Marco Verdi',
          'Re: Contratto',
          preview: 'Ti rimando il contratto firmato, fammi sapere se va bene.',
          seen: true,
          flagged: true,
          date: now.subtract(const Duration(days: 4)),
        ),
        testMsg(
          id1,
          5,
          'Comune di Esempio',
          'Avviso scadenza imposte',
          preview: 'Si ricorda la scadenza del 31 ottobre.',
          seen: true,
          date: DateTime(now.year - 1, 3, 14),
        ),
      ];
      fakes[id1]!.server.addAll(m1);
      fakes[id2]!.server.addAll([
        testMsg(
          id2,
          1,
          'Cliente Rossi',
          'Richiesta preventivo',
          preview: 'Buongiorno, vorrei un preventivo per la polizza casa.',
        ),
      ]);
      fakes[id3]!.server.addAll([]);
      fakes[id1]!.junk = 3;
      await Db.i.upsertMessages(m1);
      await Db.i.upsertMessages(fakes[id2]!.server);
    });
  }

  setUpAll(() async {
    await loadFonts();
  });

  Future<void> bigScreen(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 2200);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
  }

  testWidgets('Menu: nomi degli account, nome e freccia separati', (t) async {
    await bigScreen(t);
    await seed(t);
    final key = GlobalKey();
    await t.pumpWidget(app(MailboxScreen(account: a1), key));
    await settle(t);
    final s = t.state<ScaffoldState>(find.byType(Scaffold).first);
    s.openDrawer();
    await settle(t);
    expect(find.text('Personale'), findsWidgets); // anche nel titolo
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Outlook'), findsOneWidget);
    expect(find.text('lavoro@studio.ch'), findsNothing);
    // La freccia apre le cartelle senza cambiare casella.
    await t.tap(find.byKey(ValueKey('chevron-${a2.id}')));
    await settle(t);
    expect(s.isDrawerOpen, isTrue);
    await shot(t, '01_menu', key);
    expect(greyTexts(t, 'menu'), isEmpty);
  });

  testWidgets('Menu: le cartelle della casella aperta non si aprono da sole', (
    t,
  ) async {
    await bigScreen(t);
    await seed(t);
    await t.pumpWidget(app(MailboxScreen(account: a1), GlobalKey()));
    await settle(t);
    final s = t.state<ScaffoldState>(find.byType(Scaffold).first);
    s.openDrawer();
    await settle(t);
    expect(find.text('Nuova cartella'), findsNothing);
    await t.tap(find.byKey(ValueKey('chevron-${a1.id}')));
    await settle(t);
    expect(find.text('Nuova cartella'), findsOneWidget);
    expect(s.isDrawerOpen, isTrue);
  });

  testWidgets(
    'Titolo: un tocco apre la tendina delle cartelle e si cambia cartella',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      await t.pumpWidget(app(MailboxScreen(account: a1), key));
      await settle(t);
      expect(find.text('Cena di sabato?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('titolo-cartelle')));
      await settle(t);
      final tendina = find.byKey(const ValueKey('tendina-cartelle'));
      expect(tendina, findsOneWidget);
      // Scende dall'alto: comincia subito sotto la barra.
      expect(t.getTopLeft(tendina).dy, lessThan(200));
      expect(find.text('Nuova cartella'), findsOneWidget);
      await shot(t, '24_cartelle_dal_titolo', key);
      expect(greyTexts(t, 'cartelle dal titolo'), isEmpty);
      await t.tap(find.byKey(ValueKey('${a1.id}|Trash')));
      await settle(t);
      expect(tendina, findsNothing);
      expect(find.text('Cena di sabato?'), findsNothing);
    },
  );

  testWidgets('Elenco email: gesti, selezione, nessun grigio', (t) async {
    await bigScreen(t);
    await seed(t);
    final key = GlobalKey();
    await t.pumpWidget(app(MailboxScreen(account: a1), key));
    await settle(t);
    expect(find.text('Cena di sabato?'), findsOneWidget);
    await shot(t, '02_elenco', key);
    final sc = t.firstState<ScaffoldState>(find.byType(Scaffold).first);
    sc.openDrawer();
    await settle(t);
    await shot(t, '22_menu_laterale', key);
    sc.closeDrawer();
    await settle(t);
    expect(sc.isDrawerOpen, isFalse);
    expect(greyTexts(t, 'elenco'), isEmpty);
    // selezione con pressione lunga: compaiono la barra di selezione e il tasto «Elimina»
    expect(find.byTooltip('Seleziona tutto'), findsNothing);
    await t.longPress(find.text('Cena di sabato?'));
    await settle(t);
    expect(find.byTooltip('Seleziona tutto'), findsOneWidget);
    await shot(t, '03_selezione', key);
    expect(greyTexts(t, 'selezione'), isEmpty);
  });

  testWidgets('C34: pulsanti spenti e tema scuro: nessun testo grigio', (
    t,
  ) async {
    for (final dark in [false, true]) {
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(dark: dark),
          home: Scaffold(
            body: Column(
              children: const [
                FilledButton(onPressed: null, child: Text('Invio…')),
                TextButton(onPressed: null, child: Text('Testo spento')),
                OutlinedButton(onPressed: null, child: Text('Bordo spento')),
                ElevatedButton(onPressed: null, child: Text('Rialzato spento')),
                FilledButton(onPressed: _noop, child: Text('Acceso')),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      final out = <String>[];
      for (final w in t.widgetList<RichText>(find.byType(RichText))) {
        collect(
          w.text,
          dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
          out,
          dark ? 'scuro' : 'chiaro',
        );
      }
      // Nel tema scuro il bianco puro è ammesso; il grigio no.
      expect(out, isEmpty);
    }
  });

  testWidgets('Gesto: scorri a sinistra elimina e compare Annulla', (t) async {
    await bigScreen(t);
    await seed(t);
    final key = GlobalKey();
    await t.pumpWidget(app(MailboxScreen(account: a1), key));
    await settle(t);
    await t.drag(find.text('Cena di sabato?'), const Offset(-700, 0));
    await settle(t);
    expect(find.text('Cena di sabato?'), findsNothing);
    expect(find.text('Annulla'), findsOneWidget);
    expect(fakes[a1.id!]!.server.where((m) => m.folder == 'Trash').length, 1);
    await shot(t, '04_dopo_elimina', key);
  });

  testWidgets(
    'Elimina dall\'email aperta: si chiude subito e la lista è già senza, anche con il server lento',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      final fake = fakes[a1.id!]!;
      await t.pumpWidget(app(MailboxScreen(account: a1), key));
      await settle(t);
      await t.tap(find.text('Cena di sabato?'));
      await settle(t);
      expect(find.byType(MessageScreen), findsOneWidget);
      // Il server ci mette 3 secondi: prima la schermata restava aperta fino alla risposta.
      fake.moveDelay = const Duration(seconds: 3);
      await t.tap(find.byTooltip('Elimina'));
      // Il tempo della sola animazione di chiusura: molto meno dei 3 s del server.
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(
        find.byType(MessageScreen),
        findsNothing,
        reason: 'l\'email deve chiudersi subito, senza aspettare il server',
      );
      expect(
        find.text('Cena di sabato?'),
        findsNothing,
        reason: 'la lista deve essere già senza l\'email',
      );
      expect(find.text('Annulla'), findsOneWidget);
      expect(
        fake.server.where((m) => m.folder == 'Trash').length,
        0,
        reason: 'il server non ha ancora risposto',
      );
      // Passano i tempi del server (lettura del Message-ID e spostamento, 3 s l'uno, tempo
      // finto dei test): lo spostamento arriva.
      await t.pump(const Duration(seconds: 3, milliseconds: 100));
      await settle(t);
      await t.pump(const Duration(seconds: 3, milliseconds: 100));
      await settle(t);
      expect(fake.server.where((m) => m.folder == 'Trash').length, 1);
      expect(find.text('Cena di sabato?'), findsNothing);
    },
  );

  testWidgets('Elimina dal Cestino: è definitiva, niente Annulla', (t) async {
    await bigScreen(t);
    await seed(t);
    final fake = fakes[a1.id!]!;
    await t.runAsync(() async {
      final m = testMsg(a1.id!, 77, 'Anna', 'Nel cestino', folder: 'Trash');
      fake.server.add(m);
      await Db.i.upsertMessages([m]);
      expect(await Ops.perform(Act.delete, a1, [m]), isNull);
      expect(await Db.i.message(a1.id!, 'Trash', 77), isNull);
    });
  });

  testWidgets(
    'Elimina dall\'email aperta: se il server rifiuta, l\'email torna e lo si dice',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      final fake = fakes[a1.id!]!;
      await t.pumpWidget(app(MailboxScreen(account: a1), key));
      await settle(t);
      await t.tap(find.text('Cena di sabato?'));
      await settle(t);
      fake.failMove = StateError('Rifiutato dal server');
      await t.tap(find.byTooltip('Elimina'));
      await settle(t);
      expect(find.byType(MessageScreen), findsNothing);
      expect(find.text('Cena di sabato?'), findsOneWidget);
      expect(find.textContaining('Rifiutato dal server'), findsOneWidget);
    },
  );

  testWidgets(
    'Elimina senza rete: Annulla toglie l\'operazione in coda e l\'email torna',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final fake = fakes[a1.id!]!;
      await t.runAsync(() async {
        await fake.sync('INBOX');
        final m = (await Db.i.message(a1.id!, 'INBOX', 1))!;
        fake.offline = true;
        final undo = await Ops.perform(Act.delete, a1, [m]);
        expect(await Db.i.message(a1.id!, 'INBOX', 1), isNull);
        expect((await Db.i.pendingOps()).length, 1);
        expect(undo, isNotNull, reason: 'senza rete l\'Annulla deve funzionare');
        await undo!();
        expect((await Db.i.pendingOps()), isEmpty);
        expect(await Db.i.message(a1.id!, 'INBOX', 1), isNotNull);
      });
    },
  );

  testWidgets(
    'Elimina: una sincronizzazione a metà non rimette l\'email in lista',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final fake = fakes[a1.id!]!;
      await t.runAsync(() async {
        await fake.sync('INBOX');
        final m = (await Db.i.message(a1.id!, 'INBOX', 1))!;
        fake.moveDelay = const Duration(milliseconds: 300);
        final lavoro = Ops.perform(Act.delete, a1, [m]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          await Db.i.message(a1.id!, 'INBOX', 1),
          isNull,
          reason: 'la copia locale si toglie prima di ogni attesa di rete',
        );
        // Sincronizzazione mentre il server ha ancora l'email.
        await fake.sync('INBOX');
        expect(
          await Db.i.message(a1.id!, 'INBOX', 1),
          isNull,
          reason: 'la sincronizzazione non deve rimetterla',
        );
        // Sincronizzazione partita prima, che scrive la riga vecchia fuori tempo.
        await Db.i.upsertMessages([m]);
        await lavoro;
        expect(
          await Db.i.message(a1.id!, 'INBOX', 1),
          isNull,
          reason: 'finito lo spostamento la riga rimessa si toglie',
        );
        expect(Db.i.inVolo(a1.id!, 'INBOX', 1), isFalse);
      });
    },
  );

  testWidgets(
    'Regola che elimina: prima di salvare chiede, con il numero di email che corrispondono',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      await t.pumpWidget(
        app(
          RuleEditor(
            accounts: [a1],
            rule: Rule(
              id: '1',
              name: '',
              contains: 'Cena',
              field: 'subject',
              action: 'delete',
            ),
          ),
          key,
        ),
      );
      await settle(t);
      await t.tap(find.text('Salva'));
      await settle(t);
      expect(find.text('Salvare la regola?'), findsOneWidget);
      expect(find.textContaining('ne corrispondono 1'), findsOneWidget);
    },
  );

  testWidgets('Lettura di un\'email', (t) async {
    await bigScreen(t);
    await seed(t);
    final key = GlobalKey();
    final m = (await t.runAsync(() => Db.i.message(a1.id!, 'INBOX', 2)))!;
    await t.pumpWidget(
      app(
        MessageScreen(account: a1, msg: m, folders: FakeBackend.folderList),
        key,
      ),
    );
    await settle(t);
    expect(find.text('Estratto conto di ottobre'), findsOneWidget);
    expect(find.text('contratto.pdf'), findsOneWidget);
    await shot(t, '05_lettura', key);
    expect(greyTexts(t, 'lettura'), isEmpty);
  });

  testWidgets('Scrittura di un\'email', (t) async {
    await bigScreen(t);
    await seed(t);
    final key = GlobalKey();
    await t.pumpWidget(
      app(
        ComposeScreen(
          init: ComposeInit(
            accountId: a1.id,
            to: const ['anna@esempio.it'],
            subject: 'Cena di sabato',
          ),
        ),
        key,
      ),
    );
    await settle(t);
    // La firma si vede com'è, senza «Firma:» davanti.
    expect(find.textContaining('Firma:'), findsNothing);
    expect(
      find.textContaining('Via Roma 1', findRichText: true),
      findsOneWidget,
    );
    await shot(t, '06_scrittura', key);
    expect(greyTexts(t, 'scrittura'), isEmpty);
  });

  testWidgets(
    'Bozza: si riapre in Scrivi e al salvataggio la vecchia sparisce',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final fake = fakes[a1.id!]!;
      final bozza = testMsg(
        a1.id!,
        9,
        'Mario',
        'Bozza per Anna',
        folder: 'Drafts',
      );
      fake.drafts[9] = Outgoing(accountId: a1.id!, fromAddress: a1.address);
      await t.runAsync(() => Db.i.upsertMessages([bozza]));
      final key = GlobalKey();
      await t.pumpWidget(
        app(
          MessageScreen(
            account: a1,
            msg: bozza,
            folders: FakeBackend.folderList,
          ),
          key,
        ),
      );
      await settle(t);
      // Non è una lettura: si è aperta Scrivi con oggetto e testo della bozza.
      expect(find.text('Nuova email'), findsOneWidget);
      expect(find.text('Bozza per Anna'), findsOneWidget);
      expect(
        find.textContaining(
          'Testo di prova del messaggio 9',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // Salva bozza: ne esiste una nuova e la vecchia (uid 9) non c'è più.
      await t.tap(find.byType(PopupMenuButton<String>));
      await settle(t);
      await t.tap(find.text('Salva bozza'));
      await settle(t);
      expect(fake.drafts.keys.toList(), [
        5002,
      ], reason: 'resta una sola bozza, la nuova');
      expect(fake.log, contains('discard 9'));
    },
  );

  testWidgets(
    'Scrivi: cambiando casella la firma vecchia lascia il posto alla nuova',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      await t.pumpWidget(
        app(
          ComposeScreen(
            init: ComposeInit(accountId: a1.id, to: const ['anna@esempio.it']),
          ),
          key,
        ),
      );
      await settle(t);
      expect(
        find.textContaining('Via Roma 1', findRichText: true),
        findsOneWidget,
      );
      // Passo alla casella «Studio», che non ha firma: quella di Personale deve sparire.
      await t.tap(find.byType(DropdownButton<int>));
      await settle(t);
      await t.tap(find.textContaining('lavoro@studio.ch').last);
      await settle(t);
      expect(
        find.textContaining('Via Roma 1', findRichText: true),
        findsNothing,
      );
      // Torno a «Personale»: la firma ricompare una volta sola.
      await t.tap(find.byType(DropdownButton<int>));
      await settle(t);
      await t.tap(find.textContaining('utente@esempio.com').last);
      await settle(t);
      expect(
        find.textContaining('Via Roma 1', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('Cerca sul server: dice quali caselle non hanno risposto', (
    t,
  ) async {
    await bigScreen(t);
    await seed(t);
    fakes[a2.id!]!.offline = true;
    final key = GlobalKey();
    await t.pumpWidget(app(const SearchScreen(), key));
    await settle(t);
    await t.enterText(find.byType(TextField).first, 'Cena');
    await settle(t);
    await t.tap(find.text('Cerca anche sul server'));
    await settle(t);
    expect(find.text('Cena di sabato?'), findsOneWidget);
    expect(find.textContaining('Non hanno risposto'), findsOneWidget);
    expect(find.textContaining('Studio'), findsWidgets);
    expect(
      find.textContaining('Personale ('),
      findsNothing,
      reason: 'Personale ha risposto',
    );
  });

  testWidgets('Programmati: elenco con Modifica, Invia ora, Annulla invio', (
    t,
  ) async {
    await bigScreen(t);
    await seed(t);
    final a = a1;
    await t.runAsync(
      () => Ops.queueSend(
        a,
        Outgoing(
          accountId: a.id!,
          fromAddress: a.address,
          to: const ['anna@esempio.it'],
          subject: 'Auguri',
          text: 'x',
        ),
        DateTime.now().add(const Duration(hours: 5)),
      ),
    );
    final key = GlobalKey();
    await t.pumpWidget(app(const ScheduledScreen(), key));
    await settle(t);
    expect(find.text('Auguri'), findsOneWidget);
    expect(find.text('Modifica'), findsOneWidget);
    expect(find.text('Invia ora'), findsOneWidget);
    expect(find.text('Annulla invio'), findsOneWidget);
    await shot(t, '21_programmati', key);
    expect(greyTexts(t, 'programmati'), isEmpty);
  });

  testWidgets('Impostazioni: principale, generale, gesti, notifiche, privacy', (
    t,
  ) async {
    await bigScreen(t);
    await seed(t);
    final screens = <String, Widget>{
      '07_impostazioni': const SettingsScreen(),
      '08_generale': const GeneralSettingsScreen(),
      '09_gesti': const GesturesScreen(),
      '10_notifiche': const NotificationsScreen(),
      '11_privacy': const PrivacyScreen(),
      '12_casella': AccountSettingsScreen(accountId: a1.id!),
      '13_ia': const AiSettingsScreen(),
      '14_aggiungi': const AddAccountScreen(),
      '16_regole': const RulesScreen(),
      '17_bloccati': const BlockedScreen(),
      '18_abbonamenti': const SubscriptionsScreen(),
      '19_stato': const DiagnosticsScreen(),
      '20_firma': SignatureScreen(accountId: a1.id!),
    };
    for (final e in screens.entries) {
      final key = GlobalKey();
      await t.pumpWidget(app(e.value, key));
      await settle(t);
      await shot(t, e.key, key);
      final grey = greyTexts(t, e.key);
      expect(grey, isEmpty, reason: grey.join('\n'));
    }
  });

  testWidgets(
    'Riapertura: email scaricate dal sottofondo compaiono in lista e nel menu',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      await t.pumpWidget(app(MailboxScreen(account: a2), key));
      await settle(t);
      t.firstState<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await settle(t);
      expect(find.text('1'), findsWidgets); // una non letta in Studio
      // Il sottofondo (altro processo) scrive nel database: nessun avviso all'interfaccia.
      await t.runAsync(() async {
        final d = await Db.i.db;
        await d.insert(
          'messages',
          testMsg(
            a2.id!,
            50,
            'Mittente Nuovo',
            'Email arrivata di notte',
          ).toRow(),
        );
      });
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(t);
      await shot(t, '23_dopo_riapertura', key);
      expect(
        find.text('2'),
        findsWidgets,
        reason: 'il numero nel menu non si aggiorna',
      );
      t.firstState<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
      await settle(t);
      expect(
        find.text('Email arrivata di notte'),
        findsOneWidget,
        reason: 'la lista non si aggiorna',
      );
    },
  );

  testWidgets(
    'Lettura: scorrendo a sinistra/destra si passa alla seguente/precedente',
    (t) async {
      await bigScreen(t);
      await seed(t);
      final key = GlobalKey();
      final list = (await t.runAsync(() => Db.i.messages(a1.id!, 'INBOX')))!;
      expect(list.length, greaterThan(2));
      final m = list[1];
      await t.pumpWidget(
        app(
          MessageScreen(
            account: a1,
            msg: m,
            folders: FakeBackend.folderList,
            siblings: list,
          ),
          key,
        ),
      );
      await settle(t);
      expect(find.text(m.subject), findsWidgets);
      await t.fling(find.byType(ListView).first, const Offset(-400, 0), 2000);
      await settle(t);
      expect(
        find.text(list[2].subject).hitTestable(),
        findsWidgets,
        reason: 'sinistra = seguente',
      );
      await t.fling(find.byType(ListView).first, const Offset(400, 0), 2000);
      await settle(t);
      expect(
        find.text(list[1].subject).hitTestable(),
        findsWidgets,
        reason: 'destra = precedente',
      );
    },
  );
}

void _noop() {}
