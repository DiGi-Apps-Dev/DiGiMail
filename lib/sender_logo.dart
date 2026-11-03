import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'settings.dart';

/// Logo ufficiale del mittente: l'icona del suo sito, presa direttamente dal suo dominio
/// (niente servizi di terzi) e tenuta sul telefono. Se non c'è, resta null.
class SenderLogos {
  static final Map<String, Future<Uint8List?>> _memory = {};
  static const _free = {
    'gmail.com',
    'googlemail.com',
    'outlook.com',
    'hotmail.com',
    'live.com',
    'icloud.com',
    'me.com',
    'yahoo.com',
    'yahoo.it',
    'libero.it',
    'virgilio.it',
    'tiscali.it',
    'bluewin.ch',
    'msn.com',
    'aol.com',
  };

  /// Spento nelle prove, che non devono fare chiamate di rete.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  static String? domainOf(String addr) {
    final i = addr.lastIndexOf('@');
    if (i < 0) return null;
    final d = addr.substring(i + 1).toLowerCase().trim();
    if (d.isEmpty || _free.contains(d) || !d.contains('.')) return null;
    final parts = d.split('.');
    // mail.azienda.com -> azienda.com
    if (parts.length > 2 && parts[parts.length - 2].length > 3) {
      return parts.sublist(parts.length - 2).join('.');
    }
    return d;
  }

  static Future<Uint8List?> of(String addr) {
    if (!enabled) return Future.value(null);
    final d = domainOf(addr);
    if (d == null) return Future.value(null);
    // Con «Blocca le immagini» acceso non si contatta nessun sito di mittenti: si usa solo il logo già sul telefono.
    if (Settings.i.blockRemoteImages) return _cached(d);
    final gia = _memory[d];
    if (gia != null) return gia;
    return _seConosciuto(addr, d);
  }

  /// Contattare il sito del mittente gli dice che l'email è arrivata: uno sconosciuto o lo
  /// spam non lo devono sapere. Il no non si ricorda: al prossimo disegno può essere un sì.
  static Future<Uint8List?> _seConosciuto(String addr, String d) async {
    final c = await _cached(d);
    if (c != null) return c;
    try {
      if (!await Db.i.mittenteConosciuto(addr)) return null;
    } catch (_) {
      return null;
    }
    return _memory.putIfAbsent(d, () => _load(d));
  }

  static Future<Uint8List?> _cached(String d) async {
    try {
      final f = File(
        '${(await getApplicationSupportDirectory()).path}/logos/$d.png',
      );
      if (await f.exists()) return f.readAsBytes();
    } catch (_) {}
    return null;
  }

  /// Il logo solo se è già sul telefono; altrimenti parte il download in disparte e si risponde null.
  static Future<Uint8List?> peek(String addr) async {
    if (!enabled) return null;
    final d = domainOf(addr);
    if (d == null) return null;
    try {
      final f = File(
        '${(await getApplicationSupportDirectory()).path}/logos/$d.png',
      );
      if (await f.exists()) return f.readAsBytes();
    } catch (_) {}
    return null;
  }

  static Future<Uint8List?> _load(String d) async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/logos',
      );
      final f = File('${dir.path}/$d.png');
      final miss = File('${dir.path}/$d.none');
      if (await f.exists()) return f.readAsBytes();
      if (await miss.exists()) {
        final age = DateTime.now().difference(await miss.lastModified());
        if (age.inDays < 14) return null;
      }
      await dir.create(recursive: true);
      for (final url in [
        'https://$d/apple-touch-icon.png',
        'https://www.$d/apple-touch-icon.png',
        'https://$d/favicon.ico',
        'https://www.$d/favicon.ico',
      ]) {
        try {
          final r = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 6));
          final type = (r.headers['content-type'] ?? '').toLowerCase();
          if (r.statusCode == 200 &&
              r.bodyBytes.length > 200 &&
              r.bodyBytes.length < 400 * 1024 &&
              // Solo immagini vere: Flutter non legge gli .ico e una pagina HTML restava come
              // logo rotto per sempre.
              type.contains('image') &&
              !type.contains('icon')) {
            await f.writeAsBytes(r.bodyBytes);
            return r.bodyBytes;
          }
        } catch (_) {}
      }
      await miss.writeAsString('1');
    } catch (_) {}
    return null;
  }
}
