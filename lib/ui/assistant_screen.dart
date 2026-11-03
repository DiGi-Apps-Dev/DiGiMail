import 'package:flutter/material.dart';

import '../categories.dart';
import '../db.dart';
import '../models.dart';
import 'message_screen.dart';
import 'pickers.dart';
import 'widgets.dart';

/// Assistente: le email raggruppate per tipo (viaggi, pacchi, fatture...) in tutte le caselle.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final Map<Cat, List<Msg>> _by = {};
  Map<int, Account> _acc = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accs = {for (final a in await Db.i.accounts()) a.id!: a};
    final msgs = await Db.i.inboxSince(
      DateTime.now().subtract(const Duration(days: 120)),
      limit: 2000,
    );
    final by = {for (final c in Cat.values) c: <Msg>[]};
    for (final m in msgs) {
      for (final c in categoriesOf(m)) {
        by[c]!.add(m);
      }
    }
    if (!mounted) return;
    setState(() {
      _acc = accs;
      _by
        ..clear()
        ..addAll(by);
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assistente')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'Le email degli ultimi 4 mesi, raggruppate per tipo. Il tipo si riconosce da parole nell\'oggetto e dal mittente: è un\'approssimazione.',
                    style: TextStyle(fontSize: 15),
                  ),
                ),
                for (final c in Cat.values)
                  ListTile(
                    leading: Icon(_icon(c), size: 28),
                    title: Text(
                      catLabel[c]!,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if ((_by[c] ?? []).any((m) => !m.seen))
                          CountBadge(
                            (_by[c] ?? []).where((m) => !m.seen).length,
                          ),
                        const SizedBox(width: 8),
                        Text(
                          '${_by[c]?.length ?? 0}',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _CatList(
                          cat: c,
                          msgs: _by[c] ?? [],
                          accounts: _acc,
                        ),
                      ),
                    ).then((_) => _load()),
                  ),
              ],
            ),
    );
  }

  IconData _icon(Cat c) {
    switch (c) {
      case Cat.viaggi:
        return Icons.flight_outlined;
      case Cat.pacchi:
        return Icons.local_shipping_outlined;
      case Cat.fatture:
        return Icons.receipt_long_outlined;
      case Cat.intrattenimento:
        return Icons.theaters_outlined;
      case Cat.coupon:
        return Icons.local_offer_outlined;
      case Cat.abbonamenti:
        return Icons.unsubscribe_outlined;
    }
  }
}

class _CatList extends StatelessWidget {
  final Cat cat;
  final List<Msg> msgs;
  final Map<int, Account> accounts;
  const _CatList({
    required this.cat,
    required this.msgs,
    required this.accounts,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(catLabel[cat]!)),
      body: msgs.isEmpty
          ? const Center(
              child: Text(
                'Nessuna email',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            )
          : ListView.separated(
              itemCount: msgs.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, i) {
                final m = msgs[i];
                final a = accounts[m.accountId];
                if (a == null) return const SizedBox.shrink();
                return ListTile(
                  leading: SenderAvatar(m.sender, a.color),
                  title: Text(
                    m.sender,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: m.seen ? FontWeight.w500 : FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    '${m.subject}\n${a.name.isEmpty ? a.address : a.name} · ${formatDate(m.date)}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () async {
                    final folders = await loadFolders(a);
                    if (!context.mounted) return;
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            MessageScreen(account: a, msg: m, folders: folders),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// Indirizzi suggeriti quando scrivi: puoi toglierli.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Map<String, Object?>> _rows = [];
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Db.i.allContacts();
    final q = _q.text.trim().toLowerCase();
    if (!mounted) return;
    setState(
      () => _rows = q.isEmpty
          ? all
          : all
                .where(
                  (r) =>
                      '${r['address']} ${r['name']}'.toLowerCase().contains(q),
                )
                .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rubrica suggerita')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              onChanged: (_) => _load(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Cerca un indirizzo',
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, i) {
                final r = _rows[i];
                return ListTile(
                  title: Text(
                    '${r['address']}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: ((r['name'] as String?) ?? '').isEmpty
                      ? null
                      : Text('${r['name']}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final d = await Db.i.db;
                      await d.delete(
                        'contacts',
                        where: 'address=?',
                        whereArgs: [r['address']],
                      );
                      _load();
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
