import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../mail/backend.dart';
import '../models.dart';
import '../ops.dart';
import '../settings.dart';

/// Quando far ricomparire un'email: scelte rapide oppure data e ora a piacere.
Future<DateTime?> pickSnooze(BuildContext context) async {
  final s = Settings.i;
  final now = DateTime.now();
  final options = <(String, String, DateTime)>[
    (
      'Più tardi',
      '${DateFormat('HH:mm', 'it').format(Ops.snoozeAt('later'))}',
      Ops.snoozeAt('later'),
    ),
    ('Questa sera', '${s.snoozeEveningHour}:00', Ops.snoozeAt('evening')),
    (
      'Domani mattina',
      '${DateFormat('EEE', 'it').format(Ops.snoozeAt('tomorrow'))} ${s.snoozeMorningHour}:00',
      Ops.snoozeAt('tomorrow'),
    ),
    (
      'Nel weekend',
      'sabato ${s.snoozeMorningHour}:00',
      Ops.snoozeAt('weekend'),
    ),
    ('Lunedì', 'lunedì ${s.snoozeMorningHour}:00', Ops.snoozeAt('nextweek')),
  ];
  final r = await showModalBottomSheet<DateTime?>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'RIMANDA A…',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          for (final o in options)
            ListTile(
              leading: const Icon(Icons.snooze),
              title: Text(o.$1, style: const TextStyle(fontSize: 18)),
              trailing: Text(o.$2, style: const TextStyle(fontSize: 16)),
              onTap: () => Navigator.pop(c, o.$3),
            ),
          ListTile(
            leading: const Icon(Icons.event),
            title: const Text(
              'Scegli data e ora',
              style: TextStyle(fontSize: 18),
            ),
            onTap: () async {
              final d = await showDatePicker(
                context: c,
                initialDate: now.add(const Duration(days: 1)),
                firstDate: now,
                lastDate: now.add(const Duration(days: 730)),
              );
              if (d == null || !c.mounted) return;
              final t = await showTimePicker(
                context: c,
                initialTime: const TimeOfDay(hour: 8, minute: 0),
              );
              if (t == null || !c.mounted) return;
              Navigator.pop(
                c,
                DateTime(d.year, d.month, d.day, t.hour, t.minute),
              );
            },
          ),
        ],
      ),
    ),
  );
  return r;
}

IconData folderIcon(String role) {
  switch (role) {
    case 'inbox':
      return Icons.inbox;
    case 'sent':
      return Icons.send;
    case 'drafts':
      return Icons.description;
    case 'trash':
      return Icons.delete;
    case 'junk':
      return Icons.error;
    case 'archive':
      return Icons.archive_outlined;
    default:
      return Icons.folder;
  }
}

/// Sceglie la cartella di destinazione.
Future<Folder?> pickFolder(
  BuildContext context,
  List<Folder> folders, {
  String? exclude,
}) {
  final list = folders.where((f) => f.path != exclude).toList();
  return showModalBottomSheet<Folder>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (c, sc) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SPOSTA IN…',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: sc,
              children: [
                for (final f in list)
                  ListTile(
                    leading: Icon(folderIcon(f.role)),
                    title: Text(f.label, style: const TextStyle(fontSize: 18)),
                    onTap: () => Navigator.pop(c, f),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Ruolo della cartella a partire dal percorso, usando l'elenco già letto.
String roleOfPath(List<Folder> folders, String path) {
  for (final f in folders) {
    if (f.path == path) return f.role;
  }
  return path.toUpperCase() == 'INBOX' ? 'inbox' : 'other';
}

/// Ordine di partenza: Posta in arrivo, Bozze, Inviati, Cestino, le altre, Spam.
/// Archivio non si mostra. Se due cartelle hanno lo stesso nome (due «Bozze»)
/// ne resta una sola, quella col ruolo vero. Se l'utente ha scelto un ordine suo, vince quello.
List<Folder> orderFolders(Account a, List<Folder> raw) {
  const first = ['inbox', 'drafts', 'sent', 'trash'];
  final byLabel = <String, Folder>{};
  for (final f in raw) {
    if (f.role == 'archive') continue;
    // Le sottocartelle con lo stesso nome in madri diverse restano tutte.
    final k = f.parentPath != null && f.role == 'other'
        ? f.path
        : f.label.toLowerCase();
    final old = byLabel[k];
    if (old == null || (old.role == 'other' && f.role != 'other')) {
      byLabel[k] = f;
    }
  }
  final all = byLabel.values.toList();
  int rank(Folder f) {
    final i = first.indexOf(f.role);
    if (i >= 0) return i;
    if (f.role == 'junk') return 1000;
    return 100;
  }

  final defaults = [...all]
    ..sort((x, y) {
      final c = rank(x).compareTo(rank(y));
      return c != 0
          ? c
          : x.label.toLowerCase().compareTo(y.label.toLowerCase());
    });
  final saved = a.id == null ? const <String>[] : Settings.i.folderOrder(a.id!);
  if (saved.isEmpty) return treeOrder(defaults);
  final out = <Folder>[];
  for (final p in saved) {
    final f = defaults.where((x) => x.path == p);
    if (f.isNotEmpty) out.add(f.first);
  }
  for (final f in defaults) {
    if (!out.any((x) => x.path == f.path)) out.add(f);
  }
  return treeOrder(out);
}

/// Le sottocartelle seguono la loro cartella madre; le altre restano nell'ordine dato.
List<Folder> treeOrder(List<Folder> l) {
  final paths = l.map((f) => f.path).toSet();
  bool isRoot(Folder f) =>
      f.parentPath == null || !paths.contains(f.parentPath);
  final out = <Folder>[];
  void add(Folder f) {
    out.add(f);
    for (final c in l.where((x) => x.parentPath == f.path)) {
      add(c);
    }
  }

  for (final f in l.where(isRoot)) {
    add(f);
  }
  return out;
}

int folderDepth(Folder f, List<Folder> all) {
  var d = 0;
  var p = f.parentPath;
  final paths = all.map((x) => x.path).toSet();
  while (p != null && paths.contains(p)) {
    d++;
    final i = p.lastIndexOf(f.sep);
    p = i <= 0 ? null : p.substring(0, i);
  }
  return d;
}

Future<List<Folder>> loadFolders(Account a) async {
  // Se la prima richiesta fallisce (connessione morta) si riprova una volta da una connessione nuova.
  for (var i = 0; i < 2; i++) {
    try {
      return orderFolders(a, await Backends.of(a).folders());
    } catch (_) {
      await Backends.forget(a.id!);
    }
  }
  return const [Folder('INBOX', 'INBOX', 'inbox')];
}
