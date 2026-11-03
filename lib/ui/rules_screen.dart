import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../rules.dart';
import '../theme.dart';
import 'pickers.dart';
import 'widgets.dart';

/// Regole automatiche per le email che arrivano.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});
  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  List<Rule> _rules = [];
  Map<int, Account> _acc = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Rules.load();
    final a = {for (final x in await Db.i.accounts()) x.id!: x};
    if (mounted) {
      setState(() {
        _rules = r;
        _acc = a;
      });
    }
  }

  Future<void> _edit(Rule? existing) async {
    final r = await Navigator.push<Rule>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            RuleEditor(rule: existing, accounts: _acc.values.toList()),
      ),
    );
    if (r == null) return;
    final list = List.of(_rules);
    final i = list.indexWhere((x) => x.id == r.id);
    if (i >= 0) {
      list[i] = r;
    } else {
      list.add(r);
    }
    await Rules.save(list);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Regole automatiche')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Nuova regola'),
      ),
      body: _rules.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                  'Nessuna regola.\nUna regola agisce sulle email nuove appena arrivano.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 90),
              itemCount: _rules.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, i) {
                final r = _rules[i];
                final a = r.accountId == 0
                    ? 'Tutte le caselle'
                    : (_acc[r.accountId]?.name ?? '');
                return ListTile(
                  title: Text(
                    r.name.isEmpty
                        ? '${ruleFieldLabel[r.field]} «${r.contains}»'
                        : r.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${ruleFieldLabel[r.field]} «${r.contains}» → ${ruleActionLabel[r.action]}\n$a',
                  ),
                  isThreeLine: true,
                  trailing: Switch(
                    value: r.enabled,
                    onChanged: (v) async {
                      r.enabled = v;
                      await Rules.save(_rules);
                      setState(() {});
                    },
                  ),
                  onTap: () => _edit(r),
                  onLongPress: () async {
                    if (await confirm(
                      context,
                      'Eliminare la regola?',
                      r.name.isEmpty ? r.contains : r.name,
                      yes: 'Elimina',
                    )) {
                      _rules.remove(r);
                      await Rules.save(_rules);
                      _load();
                    }
                  },
                );
              },
            ),
    );
  }
}

class RuleEditor extends StatefulWidget {
  final Rule? rule;
  final List<Account> accounts;
  const RuleEditor({super.key, this.rule, required this.accounts});
  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  late Rule r;
  final _name = TextEditingController();
  final _contains = TextEditingController();
  List<Folder> _folders = [];

  @override
  void initState() {
    super.initState();
    r = widget.rule == null
        ? Rule(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: '',
            contains: '',
          )
        : Rule.fromJson(widget.rule!.toJson());
    _name.text = r.name;
    _contains.text = r.contains;
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final acc = widget.accounts.where((a) => a.id == r.accountId).firstOrNull;
    if (acc == null) return;
    final f = await loadFolders(acc);
    if (mounted) setState(() => _folders = f);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Regola'),
        actions: [
          TextButton(
            onPressed: () async {
              if (_contains.text.trim().isEmpty) {
                showSnack(context, 'Scrivi cosa cercare.');
                return;
              }
              if (r.action == 'move' && r.target == null) {
                showSnack(context, 'Scegli la cartella di destinazione.');
                return;
              }
              r.name = _name.text.trim();
              r.contains = _contains.text.trim();
              // Queste regole tolgono le email da Posta in arrivo da sole e senza Annulla.
              if (r.action == 'delete' || r.action == 'spam') {
                final n = await Rules.quanteCorrispondono(r, widget.accounts);
                if (!context.mounted) return;
                if (!await confirm(
                  context,
                  'Salvare la regola?',
                  '${ruleActionLabel[r.action]}: vale per le email che arriveranno, in automatico e senza Annulla. '
                      'Fra quelle già scaricate in Posta in arrivo ne corrispondono $n (non vengono toccate).',
                  yes: 'Salva',
                )) {
                  return;
                }
                if (!context.mounted) return;
              }
              Navigator.pop(context, r);
            },
            child: const Text('Salva'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nome (facoltativo)'),
          ),
          const Etichetta('Quando'),
          DropdownButton<String>(
            iconEnabledColor: Colors.black,
            isExpanded: true,
            value: r.field,
            items: [
              for (final e in ruleFieldLabel.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => r.field = v!),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _contains,
            decoration: const InputDecoration(labelText: 'Testo da cercare'),
          ),
          const Etichetta('In quale casella'),
          DropdownButton<int>(
            iconEnabledColor: Colors.black,
            isExpanded: true,
            value: r.accountId,
            items: [
              const DropdownMenuItem(value: 0, child: Text('Tutte le caselle')),
              for (final a in widget.accounts)
                DropdownMenuItem(
                  value: a.id,
                  child: Text(a.name.isEmpty ? a.address : a.name),
                ),
            ],
            onChanged: (v) {
              setState(() {
                r.accountId = v!;
                r.target = null;
                _folders = [];
              });
              _loadFolders();
            },
          ),
          const Etichetta('Fai'),
          DropdownButton<String>(
            iconEnabledColor: Colors.black,
            isExpanded: true,
            value: r.action,
            items: [
              for (final e in ruleActionLabel.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => r.action = v!),
          ),
          if (r.action == 'move')
            r.accountId == 0
                ? const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Per spostare in una cartella scegli una casella precisa qui sopra.',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      r.target == null
                          ? 'Scegli la cartella'
                          : 'Cartella: ${r.target}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final f = await pickFolder(context, _folders);
                      if (f != null) setState(() => r.target = f.path);
                    },
                  ),
          const SizedBox(height: 14),
          const Text(
            'La regola agisce sulle email che arrivano da ora in poi, non su quelle già nella casella. La prima regola che corrisponde vince.',
            style: TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }
}
