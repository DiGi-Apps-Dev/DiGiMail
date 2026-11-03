import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import 'db.dart';
import 'mail/secrets.dart';
import 'models.dart';
import 'rules.dart';
import 'settings.dart';

/// Copia completa di DiGiMail in un file solo: caselle con le password, firme,
/// loghi, impostazioni, regole, mittenti bloccati, disiscrizioni e rubrica.
/// Il file è cifrato tutto con una parola scelta dall'utente: senza quella non si apre.
/// Ripristinata su un telefono nuovo, le caselle ripartono senza rifarle a mano.
class FullBackup {
  FullBackup._();

  static const _tipo = 'digimail-copia-completa';
  static const _giri = 600000;

  /// Impostazioni che valgono solo per questo telefono: non si portano altrove.
  static const _soloQui = {'nasPushOk', 'nasPushSig', 'digestDay'};

  /// Impostazioni che hanno nel nome il numero della casella (es. syncMode_3).
  static const _perCasella = [
    'folderOrder_',
    'syncMode_',
    'syncMin_',
    'syncWifi_',
    'syncDays_',
  ];

  /// Impostazioni il cui valore è il numero di una casella.
  static const _numeroCasella = {'defaultAccountId', 'lastAccountId'};

  // ---------- raccolta ----------

  static Future<Map<String, Object?>> collect() async {
    final caselle = <Map<String, Object?>>[];
    for (final a in await Db.i.accounts()) {
      String? logo;
      final path = a.logoPath;
      if (path != null && await File(path).exists()) {
        logo = base64Encode(await File(path).readAsBytes());
      }
      caselle.add({
        'id': a.id,
        'riga': a.toRow()
          ..remove('id')
          ..remove('logo_path'),
        'password': await Secrets.password(a.id!),
        'ms': await Secrets.msToken(a.id!),
        'logo': logo,
      });
    }
    final liste = await Db.i.exportLists();
    return {
      'tipo': _tipo,
      'creata': DateTime.now().toIso8601String(),
      'caselle': caselle,
      'impostazioni': {
        for (final e in Settings.i.export(all: true).entries)
          if (!_soloQui.contains(e.key)) e.key: e.value,
      },
      'ai': await Secrets.aiToken(),
      ...liste,
    };
  }

  // ---------- ripristino ----------

  /// Rimette tutto. Una casella che c'è già (stesso indirizzo) si aggiorna, le altre
  /// si aggiungono. Restituisce quante caselle sono state ripristinate.
  static Future<int> restore(Map<String, dynamic> data) async {
    if (data['tipo'] != _tipo) throw const FormatException('non è una copia di DiGiMail');
    final esistenti = {
      for (final a in await Db.i.accounts()) a.address.toLowerCase(): a,
    };
    final nuovoId = <int, int>{};
    for (final c in (data['caselle'] as List).cast<Map>()) {
      final riga = Map<String, Object?>.from(c['riga'] as Map);
      final prima = esistenti[(riga['address'] as String).toLowerCase()];
      riga['id'] = prima?.id ?? 0;
      final a = Account.fromRow(riga);
      if (prima == null) a.id = null;
      a.logoPath = prima?.logoPath;
      final id = await Db.i.saveAccount(a);
      final logo = c['logo'] as String?;
      if (logo != null) {
        final dir = await getApplicationSupportDirectory();
        final f = File(
          '${dir.path}/logo_${id}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await f.writeAsBytes(base64Decode(logo));
        a.logoPath = f.path;
        await Db.i.saveAccount(a);
      }
      final pw = c['password'] as String?;
      if (pw != null && pw.isNotEmpty) await Secrets.setPassword(id, pw);
      final ms = c['ms'] as String?;
      if (ms != null && ms.isNotEmpty) await Secrets.setMsToken(id, ms);
      nuovoId[c['id'] as int] = id;
    }
    await Settings.i.import(
      remapSettings(
        Map<String, Object?>.from(data['impostazioni'] as Map),
        nuovoId,
      ),
    );
    final ai = data['ai'] as String?;
    if (ai != null && ai.isNotEmpty) await Secrets.setAiToken(ai);
    await Db.i.importLists(data, nuovoId);
    return nuovoId.length;
  }

  /// Sul telefono nuovo le caselle hanno altri numeri: le impostazioni e le regole
  /// legate a una casella passano al suo numero nuovo. Quelle di caselle che non
  /// ci sono più si lasciano fuori.
  static Map<String, Object?> remapSettings(
    Map<String, Object?> s,
    Map<int, int> nuovoId,
  ) {
    final out = <String, Object?>{};
    for (final e in s.entries) {
      final k = e.key;
      if (_soloQui.contains(k)) continue;
      final pre = _perCasella.where(k.startsWith).firstOrNull;
      if (pre != null) {
        final id = nuovoId[int.tryParse(k.substring(pre.length))];
        if (id != null) out['$pre$id'] = e.value;
      } else if (_numeroCasella.contains(k)) {
        final id = nuovoId[e.value];
        if (id != null) out[k] = id;
      } else if (k == Rules.key && e.value is String) {
        final regole = <Object?>[];
        for (final r in jsonDecode(e.value as String) as List) {
          final m = Map<String, dynamic>.from(r as Map);
          final vecchio = (m['accountId'] ?? 0) as int;
          if (vecchio != 0) {
            final id = nuovoId[vecchio];
            if (id == null) continue;
            m['accountId'] = id;
          }
          regole.add(m);
        }
        out[k] = jsonEncode(regole);
      } else {
        out[k] = e.value;
      }
    }
    return out;
  }

  // ---------- cifratura ----------

  /// Il file: un JSON con sale, vettore e dati cifrati (AES-256-GCM, chiave
  /// ricavata dalla parola con PBKDF2-SHA256). La parola sbagliata non apre niente.
  static Uint8List seal(Map<String, Object?> data, String parola) {
    final rnd = Random.secure();
    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
    final sale = bytes(16);
    final iv = bytes(12);
    final chiaro = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    final cifrato = _gcm(true, _chiave(parola, sale, _giri), iv, chiaro);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'tipo': _tipo,
          'versione': 1,
          'giri': _giri,
          'sale': base64Encode(sale),
          'iv': base64Encode(iv),
          'dati': base64Encode(cifrato),
        }),
      ),
    );
  }

  /// Apre il file. Parola sbagliata o file rovinato: [FormatException].
  static Map<String, dynamic> open(Uint8List file, String parola) {
    final Map<String, dynamic> f;
    try {
      f = jsonDecode(utf8.decode(file)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('non è una copia di DiGiMail');
    }
    if (f['tipo'] != _tipo) throw const FormatException('non è una copia di DiGiMail');
    try {
      final chiave = _chiave(
        parola,
        base64Decode(f['sale'] as String),
        // Un file manomesso con un numero enorme bloccherebbe l'app.
        (f['giri'] as int).clamp(1, 2000000),
      );
      final chiaro = _gcm(
        false,
        chiave,
        base64Decode(f['iv'] as String),
        base64Decode(f['dati'] as String),
      );
      return jsonDecode(utf8.decode(chiaro)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('parola sbagliata');
    }
  }

  static Uint8List _chiave(String parola, Uint8List sale, int giri) {
    final k = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(sale, giri, 32));
    return k.process(Uint8List.fromList(utf8.encode(parola)));
  }

  static Uint8List _gcm(bool cifra, Uint8List chiave, Uint8List iv, Uint8List d) {
    final c = GCMBlockCipher(AESEngine())
      ..init(cifra, AEADParameters(KeyParameter(chiave), 128, iv, Uint8List(0)));
    return c.process(d);
  }
}
