import 'package:flutter_contacts/flutter_contacts.dart';

import 'settings.dart';

/// La rubrica del telefono, per i suggerimenti dei destinatari.
/// Si legge una volta sola (dopo il permesso di Android) e resta in memoria.
class PhoneContacts {
  PhoneContacts._();

  static List<({String name, String address})>? _cache;
  static Future<List<({String name, String address})>>? _loading;

  static Future<List<({String name, String address})>> all() {
    // Android non chiede niente finché l'utente non ha letto a cosa serve (vedi Scrivi).
    if (!Settings.i.rubricaOk) return Future.value(const []);
    if (_cache != null) return Future.value(_cache);
    return _loading ??= _load();
  }

  static Future<List<({String name, String address})>> _load() async {
    try {
      final st = await FlutterContacts.permissions.request(PermissionType.read);
      if (st != PermissionStatus.granted && st != PermissionStatus.limited) {
        return _cache = [];
      }
      final list = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.email},
      );
      final out = <({String name, String address})>[];
      for (final c in list) {
        for (final e in c.emails) {
          final a = e.address.trim();
          if (a.contains('@')) out.add((name: c.displayName ?? '', address: a));
        }
      }
      return _cache = out;
    } catch (_) {
      return _cache = [];
    } finally {
      _loading = null;
    }
  }

  /// Contatti il cui nome (una qualunque parola) o indirizzo comincia con [q].
  static Future<List<({String name, String address})>> search(String q) async {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return [];
    return (await all())
        .where(
          (c) =>
              c.address.toLowerCase().startsWith(s) ||
              c.name.toLowerCase().startsWith(s) ||
              c.name.toLowerCase().split(RegExp(r'\s+')).any((w) => w.startsWith(s)),
        )
        .take(8)
        .toList();
  }
}
