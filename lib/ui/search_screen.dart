import 'dart:async';

import 'package:flutter/material.dart';

import '../ai.dart';
import '../db.dart';
import '../mail/backend.dart';
import '../models.dart';
import '../theme.dart';
import 'message_screen.dart';
import 'pickers.dart';
import 'widgets.dart';

/// Ricerca in una casella o in tutte. Cerca in locale subito, sul server se
/// vuoi, e con l'IA puoi scrivere a parole tue («la fattura del dentista di marzo»).
class SearchScreen extends StatefulWidget {
  final int? accountId;
  const SearchScreen({super.key, this.accountId});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctl = TextEditingController();
  List<Msg> _results = [];
  Map<int, Account> _accounts = {};
  bool _busy = false;
  String? _note;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    Db.i.accounts().then(
      (l) => setState(() => _accounts = {for (final a in l) a.id!: a}),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _typed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _local(q));
  }

  Future<void> _local(String q) async {
    q = q.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _note = null;
      });
      return;
    }
    final r = await Db.i.search(q, accountId: widget.accountId);
    if (mounted) {
      setState(() {
        _results = r;
        _note = r.isEmpty
            ? 'Nessun risultato nelle email già scaricate.'
            : null;
      });
    }
  }

  Future<void> _server() async {
    if (_busy || _accounts.isEmpty) return;
    final q = _ctl.text.trim();
    if (q.length < 2) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    final found = <Msg>[];
    final targets = widget.accountId != null
        ? [_accounts[widget.accountId]!]
        : _accounts.values.toList();
    // Le caselle (e le cartelle) che non rispondono si dicono, non si fanno passare per «nessun risultato».
    final failed = <String>[];
    for (final a in targets) {
      final label = a.name.isEmpty ? a.address : a.name;
      final folders = (await loadFolders(a))
          .where((f) => const ['inbox', 'archive', 'sent'].contains(f.role))
          .toList();
      for (final f in folders.isEmpty ? const [Folder('INBOX', 'INBOX', 'inbox')] : folders) {
        try {
          final r = await Backends.of(a)
              .searchServer(q, folder: f.path)
              .timeout(const Duration(seconds: 40));
          await Db.i.upsertMessages(r);
          found.addAll(r);
        } catch (_) {
          failed.add(folders.length > 1 ? '$label (${f.name})' : label);
        }
      }
    }
    final local = await Db.i.search(q, accountId: widget.accountId);
    final all = {
      for (final m in [...local, ...found]) m.key: m,
    }.values.toList()..sort((x, y) => y.date.compareTo(x.date));
    final silent = failed.isEmpty ? '' : ' Non hanno risposto: ${failed.join(', ')}.';
    if (mounted) {
      setState(() {
        _busy = false;
        _results = all;
        _note = all.isEmpty
            ? (failed.isEmpty
                  ? 'Nessun risultato sul server in Posta in arrivo, Archivio e Inviata (primi 30 per cartella).'
                  : 'Nessun risultato.$silent')
            : (failed.isEmpty ? null : silent.trim());
      });
    }
  }

  Future<void> _ai() async {
    final q = _ctl.text.trim();
    if (q.length < 3) return;
    if (!await Ai.configured()) {
      if (mounted)
        showSnack(
          context,
          'Inserisci prima account e chiave Cloudflare in Impostazioni > Intelligenza artificiale.',
        );
      return;
    }
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final plan = await Ai.planSearch(q);
      final base = plan.text.isNotEmpty
          ? await Db.i.search(
              plan.text.split(RegExp(r'\s+')).first,
              accountId: widget.accountId,
              limit: 400,
            )
          : await Db.i.inboxSince(
              DateTime.now().subtract(Duration(days: plan.days ?? 365)),
            );
      // la ricerca locale per la prima parola, poi i filtri dell'IA
      var res = base.where(plan.matches).toList();
      if (res.isEmpty) {
        final d = await Db.i.db;
        final rows = await d.query(
          'messages',
          orderBy: 'date DESC',
          limit: 800,
        );
        res = rows
            .map(Msg.fromRow)
            .where(plan.matches)
            .where(
              (m) =>
                  widget.accountId == null || m.accountId == widget.accountId,
            )
            .toList();
      }
      if (mounted) {
        setState(() {
          _results = res.take(100).toList();
          _note =
              'Cerco: ${plan.text.isEmpty ? 'tutto' : plan.text}${plan.from != null ? ' · da ${plan.from}' : ''}${plan.days != null ? ' · ultimi ${plan.days} giorni' : ''}${plan.unread == true ? ' · non lette' : ''}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _note = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final inOne = widget.accountId != null ? _accounts[widget.accountId] : null;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctl,
          autofocus: true,
          onChanged: _typed,
          onSubmitted: _local,
          style: const TextStyle(fontSize: 19),
          decoration: InputDecoration(
            hintText: inOne == null
                ? 'Cerca in tutte le caselle'
                : 'Cerca in ${inOne.name.isEmpty ? inOne.address : inOne.name}',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _ctl.clear();
              _results = [];
              _note = null;
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(color: kAccento),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _server,
                  icon: const Icon(Icons.cloud_outlined, size: 18),
                  label: const Text('Cerca anche sul server'),
                ),
                OutlinedButton.icon(
                  onPressed: _ai,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Cerca con IA'),
                ),
              ],
            ),
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _note!,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (c, i) {
                final m = _results[i];
                final a = _accounts[m.accountId];
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
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${a.name.isEmpty ? a.address : a.name} · ${formatDate(m.date)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
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
          ),
        ],
      ),
    );
  }
}
