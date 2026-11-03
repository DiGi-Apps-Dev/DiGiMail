import 'dart:async';

import 'package:flutter/material.dart';

import '../categories.dart';
import '../db.dart';
import '../mail/backend.dart';
import '../mail/imap_backend.dart';
import '../models.dart';
import '../ops.dart';
import '../settings.dart';
import '../theme.dart';
import 'add_account_screen.dart';
import 'assistant_screen.dart';
import 'compose_screen.dart';
import 'message_screen.dart';
import 'pickers.dart';
import 'scheduled_screen.dart';
import 'search_screen.dart';
import 'settings_screens.dart';
import 'widgets.dart';

const _removing = {
  Act.delete,
  Act.archive,
  Act.spam,
  Act.move,
  Act.block,
  Act.snooze,
};

String _doneText(Act a, int n) {
  final many = n > 1;
  switch (a) {
    case Act.delete:
      return many ? '$n email eliminate' : 'Email eliminata';
    case Act.archive:
      return many ? '$n email archiviate' : 'Email archiviata';
    case Act.spam:
      return many ? '$n email segnalate come spam' : 'Segnalata come spam';
    case Act.block:
      return 'Mittente bloccato: le sue email andranno nello spam';
    case Act.move:
      return many ? '$n email spostate' : 'Email spostata';
    case Act.snooze:
      return many ? '$n email rimandate' : 'Email rimandata';
    case Act.toggleRead:
      return many ? '$n email aggiornate' : 'Email aggiornata';
    case Act.flag:
      return 'Stella aggiornata';
    default:
      return 'Fatto';
  }
}

/// Elenco delle email di una cartella di una casella.
class MailboxScreen extends StatefulWidget {
  final Account account;
  final String folder;
  const MailboxScreen({
    super.key,
    required this.account,
    this.folder = 'INBOX',
  });
  @override
  State<MailboxScreen> createState() => _MailboxScreenState();
}

class _MailboxScreenState extends State<MailboxScreen>
    with WidgetsBindingObserver {
  late String _folder;
  List<Msg> _msgs = [];
  List<Folder> _folders = [];
  final Set<String> _sel = {};
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  StreamSubscription<void>? _sub;
  Timer? _debounce;
  final _scroll = ScrollController();

  bool _other = false;
  List<Account> _accounts = [];
  final Map<int, int> _unseen = {};
  // Non lette recenti di Spam e Cestino per casella: le stesse che il numero sull'icona conta.
  final Map<int, Map<String, int>> _alert = {};
  final Map<int, List<Folder>> _accFolders = {};
  final Set<int> _expanded = {};
  final Set<String> _openSub = {};
  // La tendina delle cartelle sta in un'altra pagina: si ridisegna a ogni setState di qui.
  final ValueNotifier<int> _menu = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    _shownCache = null;
    super.setState(fn);
    _menu.value++;
  }

  Account? _fresh;
  Account get a => _fresh ?? widget.account;

  Future<void> _refreshAccount() async {
    final x = await Db.i.account(widget.account.id!);
    if (mounted && x != null) setState(() => _fresh = x);
  }

  bool get _focus => Settings.i.focusedInbox && !_pseudo && _role == 'inbox';
  // Si calcola una volta per disegno: prima si rifiltrava tutta la lista per ogni riga.
  List<Msg>? _shownCache;
  List<Msg> get _shown => _shownCache ??=
      _focus ? _msgs.where((m) => isOther(m) == _other).toList() : _msgs;
  bool get _selecting => _sel.isNotEmpty;
  bool get _pseudo => _folder.startsWith('@');
  String get _role => roleOfPath(_folders, _folder);

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    _sub = Db.i.changes.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 200), () {
        _reload();
        _refreshAccount();
        _loadAccounts();
      });
    });
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300)
        _more();
    });
    _reload();
    _init();
    _loadAccounts();
    Settings.i.addListener(_onSettings);
    WidgetsBinding.instance.addObserver(this);
  }

  DateTime? _inPausaDa;
  int _giroSync = 0;

  /// Riaprendo l'app, le email scaricate nel frattempo dal sottofondo (altro processo, che
  /// non avvisa l'interfaccia) compaiono subito in lista e nei numeri del menu.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _inPausaDa ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed || !mounted) return;
    final pausa = _inPausaDa == null
        ? Duration.zero
        : DateTime.now().difference(_inPausaDa!);
    _inPausaDa = null;
    _reload();
    _refreshAccount();
    _loadAccounts();
    if (_pseudo) return;
    // Dopo una pausa lunga (Android congela l'app dopo circa un minuto) la connessione è morta
    // e un aggiornamento rimasto a metà non finirebbe mai: con `_loading` ancora acceso non
    // partiva niente e la rotella girava finché il suo tempo non scadeva, poi «Il server non
    // risponde in tempo» (visto sul telefono il 29.10.2026). Si butta la connessione e si
    // riparte da zero; l'aggiornamento vecchio, quando finisce, non tocca più lo schermo.
    if (pausa > const Duration(seconds: 60)) {
      Backends.of(a).riparti();
      _sync();
    } else if (!_loading) {
      _sync();
    }
  }

  Future<void> _init() async {
    final f = await loadFolders(a);
    // Le cartelle della casella si aprono nel menu solo con la freccetta, mai da sole.
    if (!mounted) return;
    setState(() => _folders = f);
    await _sync();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _menu.dispose();
    WidgetsBinding.instance.removeObserver(this);
    Settings.i.removeListener(_onSettings);
    _sub?.cancel();
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    List<Msg> list;
    if (_folder == '@snoozed') {
      list = await Db.i.snoozed(a.id!);
    } else {
      list = await Db.i.messages(a.id!, _folder, limit: _limite);
    }
    if (!mounted) return;
    setState(() {
      _msgs = list;
      _sel.removeWhere((k) => !list.any((m) => m.key == k));
    });
  }

  Future<void> _sync() async {
    if (!mounted) return;
    if (_pseudo) {
      // Un aggiornamento ancora in corso non deve scrivere il suo errore su questa schermata.
      ++_giroSync;
      setState(() => _loading = false);
      return;
    }
    final giro = ++_giroSync;
    _finita = false;
    setState(() {
      _loading = true;
      _error = null;
    });
    String? errore;
    try {
      await Ops.refresh(
        a,
        folder: _folder,
        notify: false,
      ).timeout(const Duration(seconds: 60));
    } catch (e) {
      errore = friendlyError(e);
    }
    // Superato da un aggiornamento più nuovo (ripresa dopo una pausa): il suo esito non vale più.
    if (giro != _giroSync) return;
    _error = errore;
    if (mounted) setState(() => _loading = false);
    await _reload();
  }

  /// Quante righe si leggono dalla copia locale: cresce scorrendo. Con il limite fisso di
  /// 200 la lista si fermava lì anche dopo aver scaricato le email più vecchie.
  int _limite = 200;

  /// La cartella è finita: scorrendo in fondo non si rifà un giro di rete a ogni tocco.
  bool _finita = false;

  Future<void> _more() async {
    if (_finita || _loadingMore || _pseudo || _loading || _msgs.length < 20) return;
    setState(() => _loadingMore = true);
    final prima = _msgs.length;
    var riuscito = true;
    try {
      await Backends.of(a).loadOlder(_folder);
    } catch (_) {
      riuscito = false;
    }
    if (_msgs.length + 40 > _limite) _limite = _msgs.length + 40;
    if (mounted) setState(() => _loadingMore = false);
    await _reload();
    if (riuscito && _msgs.length == prima) _finita = true;
  }

  void _openFolder(String path) {
    Navigator.pop(context);
    _showFolder(path);
  }

  void _showFolder(String path) {
    setState(() {
      _folder = path;
      _msgs = [];
      _limite = 200;
      _finita = false;
      _sel.clear();
    });
    _reload();
    _sync();
  }

  String get _title {
    if (_folder == '@snoozed') return 'Rimandate';
    for (final f in _folders) {
      if (f.path == _folder) return f.label;
    }
    return _folder.toUpperCase() == 'INBOX' ? 'Posta in arrivo' : _folder;
  }

  // ---------- azioni ----------

  Future<void> _do(
    Act act,
    List<Msg> list, {
    String? target,
    DateTime? until,
    bool silent = false,
  }) async {
    if (list.isEmpty) return;
    final byFolder = <String, List<Msg>>{};
    for (final m in list) {
      byFolder.putIfAbsent(m.folder, () => []).add(m);
    }
    final undos = <UndoFn>[];
    String? errore;
    try {
      for (final g in byFolder.values) {
        final u = await Ops.perform(
          act,
          a,
          g,
          targetPath: target,
          snoozeUntil: until,
        );
        if (u != null) undos.add(u);
      }
    } catch (e) {
      errore = friendlyError(e);
      // Niente fatto: si dice e basta. Se qualche cartella è già andata, sotto resta il suo Annulla.
      if (undos.isEmpty) {
        if (mounted) showSnack(context, errore);
        await _reload();
        return;
      }
    }
    if (!mounted || silent) return;
    setState(_sel.clear);
    showSnack(
      context,
      errore ?? _doneText(act, list.length),
      duration: Duration(seconds: Settings.i.undoSeconds),
      action: undos.isEmpty ? null : 'Annulla',
      onAction: () async {
        Object? fallita;
        for (final u in undos) {
          try {
            await u();
          } catch (e) {
            fallita = e;
          }
        }
        await _reload();
        if (fallita != null && mounted) {
          showSnack(
            context,
            'Non sono riuscito ad annullare: ${friendlyError(fallita)}',
          );
        }
      },
    );
    await _reload();
  }

  Future<void> _doMove(List<Msg> list) async {
    final f = await pickFolder(context, _folders, exclude: _folder);
    if (f == null) return;
    await _do(Act.move, list, target: f.path);
  }

  Future<void> _doSnooze(List<Msg> list) async {
    final t = await pickSnooze(context);
    if (t == null) return;
    await _do(Act.snooze, list, until: t);
  }

  Future<void> _open(Msg m) async {
    if (_selecting) {
      _toggle(m);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MessageScreen(
          account: a,
          msg: m,
          folders: _folders,
          siblings: _shown,
        ),
      ),
    );
    await _reload();
  }

  void _toggle(Msg m) {
    setState(() {
      if (!_sel.add(m.key)) _sel.remove(m.key);
    });
  }

  List<Msg> get _selected => _msgs.where((m) => _sel.contains(m.key)).toList();

  /// Gesto sulla riga. Restituisce true se la riga deve sparire dalla lista.
  Future<bool> _swipe(Msg m, DismissDirection dir, bool long) async {
    final s = Settings.i;
    final act = dir == DismissDirection.startToEnd
        ? (long ? s.swipeLongRight : s.swipeShortRight)
        : (long ? s.swipeLongLeft : s.swipeShortLeft);
    if (act == Act.none) return false;
    if (act == Act.reply || act == Act.replyAll || act == Act.forward) {
      final init = ComposeInit.from(a, m, act);
      if (act == Act.forward && m.hasAtt) {
        try {
          init.files = await Ops.forwardFiles(a, m);
        } catch (e) {
          if (mounted) {
            showSnack(
              context,
              'Gli allegati non si sono scaricati: ${friendlyError(e)}',
            );
          }
        }
      }
      if (!mounted) return false;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ComposeScreen(init: init)),
      );
      return false;
    }
    if (act == Act.unsubscribe) return false;
    if (act == Act.move) {
      final f = await pickFolder(context, _folders, exclude: _folder);
      if (f == null) return false;
      setState(() => _msgs.removeWhere((x) => x.key == m.key));
      _do(Act.move, [m], target: f.path);
      return true;
    }
    if (act == Act.snooze) {
      final t = await pickSnooze(context);
      if (t == null) return false;
      setState(() => _msgs.removeWhere((x) => x.key == m.key));
      _do(Act.snooze, [m], until: t);
      return true;
    }
    if (_removing.contains(act)) {
      setState(() => _msgs.removeWhere((x) => x.key == m.key));
      _do(act, [m]);
      return true;
    }
    _do(act, [m]);
    return false;
  }

  bool _casellaTolta = false;

  Future<void> _loadAccounts() async {
    final list = await Db.i.accounts();
    final counts = <int, int>{};
    final alert = <int, Map<String, int>>{};
    for (final x in list) {
      counts[x.id!] = await Db.i.unseenAlertCount(x.id!);
      alert[x.id!] = await Db.i.unseenAlertByFolder(x.id!);
      // Il numero di Posta in arrivo viene dalla copia locale: quello dell'elenco cartelle è
      // una fotografia di quando la cartella è stata letta, e non scendeva leggendo.
      alert[x.id!]!['INBOX'] = await Db.i.unseenCount(x.id!, 'INBOX');
    }
    if (!mounted) return;
    // La casella aperta è stata tolta: non si resta su una casella che non esiste più.
    if (!list.any((x) => x.id == widget.account.id)) {
      if (_casellaTolta) return;
      _casellaTolta = true;
      final nav = Navigator.of(context);
      void vaiAllaPrima(Account x) => nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => MailboxScreen(account: x)),
        (_) => false,
      );
      if (list.isNotEmpty) {
        vaiAllaPrima(list.first);
      } else {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => AddAccountScreen(
              onDone: () async {
                final nuove = await Db.i.accounts();
                if (nuove.isNotEmpty) vaiAllaPrima(nuove.first);
              },
            ),
          ),
          (_) => false,
        );
      }
      return;
    }
    setState(() {
      _accounts = list;
      _alert
        ..clear()
        ..addAll(alert);
      _unseen
        ..clear()
        ..addAll(counts);
    });
  }

  void _switchTo(Account other, [String folder = 'INBOX']) {
    Navigator.pop(context);
    if (other.id == a.id) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MailboxScreen(account: other, folder: folder),
      ),
    );
  }

  List<Folder> _foldersOf(Account x) =>
      x.id == a.id ? _folders : (_accFolders[x.id] ?? const []);

  Future<void> _reorderAccounts() async {
    final list = List<Account>.of(_accounts);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'TRASCINA PER ORDINARE',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              Flexible(
                child: ReorderableListView(
                  shrinkWrap: true,
                  onReorder: (o, n) {
                    if (n > o) n -= 1;
                    set(() => list.insert(n, list.removeAt(o)));
                  },
                  children: [
                    for (final x in list)
                      ListTile(
                        key: ValueKey(x.id),
                        leading: AccountAvatar(x, size: 40),
                        title: Text(
                          x.name.isEmpty ? x.address : x.name,
                          style: const TextStyle(fontSize: 17),
                        ),
                        subtitle: Text(x.address),
                        trailing: const Icon(Icons.drag_handle),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await Db.i.reorderAccounts(list.map((x) => x.id!).toList());
    await _loadAccounts();
  }

  Future<void> _toggleAccount(Account x) async {
    if (_expanded.contains(x.id)) {
      setState(() => _expanded.remove(x.id));
      return;
    }
    setState(() => _expanded.add(x.id!));
    if (x.id != a.id && !_accFolders.containsKey(x.id)) {
      final f = await loadFolders(x);
      if (mounted) setState(() => _accFolders[x.id!] = f);
    }
  }

  Widget _accountRow(Account x) {
    final cur = x.id == a.id;
    final n = _unseen[x.id] ?? 0;
    final open = _expanded.contains(x.id);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: cur
            ? (Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF4A3420)
                  : const Color(0xFFFFE9D6))
            : Colors.transparent,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(28)),
        // Tocco sul nome: Posta in arrivo di quell'account. Tocco sulla freccia: apre le cartelle.
        child: InkWell(
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(28),
          ),
          onTap: () => cur ? _openFolder('INBOX') : _switchTo(x),
          onLongPress: _reorderAccounts,
          child: SizedBox(
            height: 55,
            child: Row(
              children: [
                Container(
                  width: 2,
                  height: 37,
                  margin: const EdgeInsets.only(left: 18, right: 7),
                  color: Color(x.color),
                ),
                AccountAvatar(x, size: 37),
                const SizedBox(width: 23),
                Expanded(
                  child: Text(
                    x.name.isEmpty ? x.address : x.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: cur ? FontWeight.w800 : FontWeight.w400,
                    ),
                  ),
                ),
                if (n > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: CountBadge(n),
                  ),
                InkWell(
                  key: ValueKey('chevron-${x.id}'),
                  customBorder: const CircleBorder(),
                  onTap: () => _toggleAccount(x),
                  child: SizedBox(
                    width: 52,
                    height: 55,
                    child: Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _folderBlock(Account x) {
    final list = _foldersOf(x);
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final cur = x.id == a.id;
    final vis = _visibleFolders(x, list);
    return Column(
      children: [
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: vis.length,
          onReorder: (o, n) {
            if (n > o) n -= 1;
            setState(() {
              final moved = List<Folder>.of(vis);
              moved.insert(n, moved.removeAt(o));
              // Le sottocartelle chiuse seguono la loro madre (treeOrder le rimette sotto).
              final shown = vis.map((f) => f.path).toSet();
              final ordered = treeOrder([
                ...moved,
                ...list.where((c) => !shown.contains(c.path)),
              ]);
              list
                ..clear()
                ..addAll(ordered);
            });
            Settings.i.setFolderOrder(x.id!, list.map((f) => f.path).toList());
          },
          itemBuilder: (c, i) {
            final f = vis[i];
            final depth = folderDepth(f, list);
            final key = '${x.id}|${f.path}';
            final hasSub = list.any((s) => s.parentPath == f.path);
            final subOpen = _openSub.contains(key);
            return InkWell(
              key: ValueKey(key),
              onTap: () => cur ? _openFolder(f.path) : _switchTo(x, f.path),
              child: SizedBox(
                height: 46,
                child: Row(
                  children: [
                    SizedBox(width: 62.0 + depth * 24),
                    SizedBox(
                      width: 53,
                      child: Icon(folderIcon(f.role), size: 24),
                    ),
                    Expanded(
                      child: Text(
                        f.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    if ((_alert[x.id]?[f.path] ?? f.unseen) > 0)
                      Padding(
                        padding: EdgeInsets.only(right: hasSub ? 0 : 24),
                        child: CountBadge(_alert[x.id]?[f.path] ?? f.unseen),
                      ),
                    if (hasSub)
                      InkWell(
                        key: ValueKey('sub-$key'),
                        customBorder: const CircleBorder(),
                        onTap: () => setState(
                          () => subOpen
                              ? _openSub.remove(key)
                              : _openSub.add(key),
                        ),
                        child: SizedBox(
                          width: 52,
                          height: 46,
                          child: Icon(
                            subOpen ? Icons.expand_less : Icons.expand_more,
                            size: 26,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        InkWell(
          onTap: () => _newFolder(x),
          child: const SizedBox(
            height: 46,
            child: Row(
              children: [
                SizedBox(width: 62),
                SizedBox(
                  width: 53,
                  child: Icon(Icons.create_new_folder_outlined, size: 24),
                ),
                Text('Nuova cartella', style: TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _newFolder(Account x) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nuova cartella'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('Crea'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await Backends.of(x).createFolder(name);
      final f = await loadFolders(x);
      if (!mounted) return;
      setState(() {
        if (x.id == a.id) {
          _folders = f;
        } else {
          _accFolders[x.id!] = f;
        }
      });
    } catch (e) {
      if (mounted)
        showSnack(context, 'Cartella non creata: ${friendlyError(e)}');
    }
  }

  /// Le sottocartelle si vedono solo se tutte le cartelle sopra di loro sono aperte.
  List<Folder> _visibleFolders(Account x, List<Folder> list) {
    final paths = list.map((f) => f.path).toSet();
    return list.where((f) {
      var p = f.parentPath;
      while (p != null && paths.contains(p)) {
        if (!_openSub.contains('${x.id}|$p')) return false;
        final i = p.lastIndexOf(f.sep);
        p = i <= 0 ? null : p.substring(0, i);
      }
      return true;
    }).toList();
  }

  /// Tendina dal titolo: scende dall'alto sotto la barra e mostra le cartelle della
  /// casella esattamente come nel Mailbox (sottocartelle chiuse, si aprono con la freccia).
  Future<void> _pickFolderSheet() async {
    final top = MediaQuery.of(context).padding.top + kToolbarHeight;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Chiudi',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (c, _, _) => Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: Material(
            key: const ValueKey('tendina-cartelle'),
            color: Theme.of(context).colorScheme.surface,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(c).size.height * 0.75 - top,
              ),
              child: SingleChildScrollView(
                child: ValueListenableBuilder<int>(
                  valueListenable: _menu,
                  builder: (_, _, _) => _folderBlock(a),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (c, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, -1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    );
  }

  Widget _drawer() {
    final fg = Theme.of(context).colorScheme.onSurface;
    const label = TextStyle(fontSize: 18);
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.89,
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // Testata arancione a tutta larghezza, come la barra in alto.
            Container(
              width: double.infinity,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.transparent
                  : kBarra,
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + 20,
                16,
                14,
              ),
              child: const Text(
                'MAILBOX',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
            ),
            for (final x in _accounts) ...[
              _accountRow(x),
              if (_expanded.contains(x.id)) _folderBlock(x),
            ],
            InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddAccountScreen()),
                );
              },
              child: const SizedBox(
                height: 56,
                child: Row(
                  children: [
                    SizedBox(
                      width: 62,
                      child: Icon(Icons.add, color: kLink, size: 30),
                    ),
                    SizedBox(width: 14),
                    Text(
                      'Aggiungi account',
                      style: TextStyle(fontSize: 17, color: kLink),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              onTap: _reorderAccounts,
              child: const SizedBox(
                height: 56,
                child: Row(
                  children: [
                    SizedBox(width: 62, child: Icon(Icons.swap_vert, size: 28)),
                    SizedBox(width: 14),
                    Text('Ordina gli account', style: TextStyle(fontSize: 17)),
                  ],
                ),
              ),
            ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.snooze, color: fg),
              title: const Text('Rimandate', style: label),
              onTap: () => _openFolder('@snoozed'),
            ),
            ListTile(
              leading: Icon(Icons.schedule_send_outlined, color: fg),
              title: const Text('Programmati', style: label),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScheduledScreen()),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.auto_awesome_outlined, color: fg),
              title: const Text('Assistente', style: label),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AssistantScreen()),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.settings_outlined, color: fg),
              title: const Text('Impostazioni della casella', style: label),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AccountSettingsScreen(accountId: a.id!),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.tune, color: fg),
              title: const Text('Impostazioni dell\'app', style: label),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _bar() {
    if (_selecting) {
      final sel = _selected;
      final canSpamBack = _role == 'junk';
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(_sel.clear),
        ),
        title: Text('${_sel.length}'),
        actions: [
          IconButton(
            tooltip: 'Seleziona tutto',
            icon: const Icon(Icons.select_all),
            onPressed: () =>
                setState(() => _sel.addAll(_shown.map((m) => m.key))),
          ),
          IconButton(
            tooltip: 'Elimina',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _do(Act.delete, sel),
          ),
          IconButton(
            tooltip: 'Letta / non letta',
            icon: const Icon(Icons.mark_email_read_outlined),
            onPressed: () => _do(Act.toggleRead, sel),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'spam':
                  await _do(Act.spam, sel);
                  break;
                case 'notspam':
                  await _do(
                    Act.move,
                    sel,
                    target: _folders
                        .firstWhere(
                          (f) => f.role == 'inbox',
                          orElse: () => const Folder('INBOX', 'INBOX', 'inbox'),
                        )
                        .path,
                  );
                  break;
                case 'move':
                  await _doMove(sel);
                  break;
                case 'snooze':
                  await _doSnooze(sel);
                  break;
                case 'flag':
                  await _do(Act.flag, sel);
                  break;
                case 'block':
                  await _do(Act.block, sel);
                  break;
              }
            },
            itemBuilder: (_) => [
              if (canSpamBack)
                const PopupMenuItem(
                  value: 'notspam',
                  child: Text('Non è spam: riporta in arrivo'),
                )
              else
                const PopupMenuItem(
                  value: 'spam',
                  child: Text('Segnala come spam'),
                ),
              const PopupMenuItem(value: 'move', child: Text('Sposta in…')),
              const PopupMenuItem(value: 'snooze', child: Text('Rimanda')),
              const PopupMenuItem(
                value: 'flag',
                child: Text('Metti o togli la stella'),
              ),
              const PopupMenuItem(
                value: 'block',
                child: Text('Blocca i mittenti'),
              ),
            ],
          ),
        ],
      );
    }
    return AppBar(
      // Tocco sul titolo: elenco delle cartelle di questa casella, per cambiare senza il menu.
      title: InkWell(
        key: const ValueKey('titolo-cartelle'),
        borderRadius: BorderRadius.circular(8),
        onTap: _pickFolderSheet,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 28),
              ],
            ),
            Text(
              a.name.isEmpty ? a.address : a.name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Cerca',
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SearchScreen(accountId: a.id)),
          ),
        ),
        IconButton(
          tooltip: 'Aggiorna',
          icon: const Icon(Icons.refresh),
          onPressed: _sync,
        ),
        if (_role == 'trash')
          IconButton(
            tooltip: 'Svuota il cestino',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              if (!await confirm(
                context,
                'Svuotare il cestino?',
                'Le email nel cestino di ${a.name.isEmpty ? a.address : a.name} verranno cancellate per sempre.',
                yes: 'Svuota',
              ))
                return;
              try {
                await Ops.emptyTrash(a, _folder);
              } catch (e) {
                if (mounted) showSnack(context, friendlyError(e));
              }
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(_sel.clear);
      },
      child: Scaffold(
        appBar: _bar(),
        drawer: _drawer(),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton(
                tooltip: 'Scrivi',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ComposeScreen(init: ComposeInit(accountId: a.id!)),
                  ),
                ),
                child: const Icon(Icons.edit),
              ),
        body: Column(
          children: [
            if (_loading)
              const LinearProgressIndicator(minHeight: 3, color: kAccento),
            if (_error != null)
              Container(
                width: double.infinity,
                color: const Color(0xFFFDECEA),
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFB3261E),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (_focus)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text(
                        'Principali (${_msgs.where((m) => !isOther(m) && !m.seen).length} non lette)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      selected: !_other,
                      onSelected: (_) => setState(() => _other = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(
                        'Altro (${_msgs.where((m) => isOther(m) && !m.seen).length} non lette)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      selected: _other,
                      onSelected: (_) => setState(() => _other = true),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _sync,
                child: _shown.isEmpty && !_loading
                    ? ListView(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(40),
                            child: Center(
                              child: Text(
                                _folder == '@snoozed'
                                    ? 'Nessuna email rimandata'
                                    : 'Nessuna email',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _shown.length + 1,
                        itemBuilder: (c, i) {
                          final shown = _shown;
                          if (i == shown.length)
                            return SizedBox(
                              height: 90,
                              child: _loadingMore
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : null,
                            );
                          final m = shown[i];
                          return SwipeRow(
                            key: ValueKey(m.key),
                            onSwipe: (dir, long) => _swipe(m, dir, long),
                            enabled: !_selecting,
                            child: _MsgTile(
                              msg: m,
                              account: a,
                              selected: _sel.contains(m.key),
                              selecting: _selecting,
                              onTap: () => _open(m),
                              onLong: () => _toggle(m),
                              onAvatar: () => _toggle(m),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MsgTile extends StatelessWidget {
  final Msg msg;
  final Account account;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLong;
  final VoidCallback onAvatar;
  const _MsgTile({
    required this.msg,
    required this.account,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLong,
    required this.onAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final s = Settings.i;
    final unread = !msg.seen;
    final w = unread ? FontWeight.w800 : FontWeight.w400;
    final bg = selected
        ? (Theme.of(context).brightness == Brightness.dark
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : kSfondoLeggero)
        : Theme.of(context).colorScheme.surface;
    return Material(
      color: bg,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLong,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: kBordo, width: 0.6)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.showAvatars)
                GestureDetector(
                  onTap: onAvatar,
                  child: selected
                      ? const CircleAvatar(
                          radius: 21,
                          backgroundColor: kAccento,
                          child: Icon(Icons.check, color: Colors.white),
                        )
                      : SenderAvatar(
                          msg.sender,
                          account.color,
                          addr: msg.fromAddr,
                        ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  msg.sender.isEmpty
                                      ? '(senza mittente)'
                                      : msg.sender,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 16, fontWeight: w),
                                ),
                              ),
                              // Graffetta subito dopo il mittente, piccola e grigia come Edison.
                              if (msg.hasAtt)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.attach_file,
                                    size: 14,
                                    color: kIconaGrigia,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (msg.snoozedUntil != null)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.snooze, size: 17),
                          ),
                        if (msg.flagged)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.star,
                              size: 18,
                              color: Color(0xFFF9A825),
                            ),
                          ),
                        const SizedBox(width: 6),
                        Text(
                          formatDate(msg.date),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            msg.subject.isEmpty
                                ? '(senza oggetto)'
                                : msg.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: w),
                          ),
                        ),
                        // Freccia «risposto» a destra sotto l'ora, come Edison.
                        if (msg.answered)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.reply,
                              size: 18,
                              color: kIconaGrigia,
                            ),
                          ),
                      ],
                    ),
                    if (s.previewOn && msg.preview.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          msg.preview,
                          maxLines: s.previewLines,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                  ],
                ),
              ),
              if (unread)
                const Padding(
                  padding: EdgeInsets.only(left: 8, top: 6),
                  child: CircleAvatar(radius: 5, backgroundColor: kAccento),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Riga scorrevole con due soglie per lato: gesto corto e gesto lungo.
class SwipeRow extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Future<bool> Function(DismissDirection dir, bool long) onSwipe;
  const SwipeRow({
    super.key,
    required this.child,
    required this.onSwipe,
    this.enabled = true,
  });
  @override
  State<SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends State<SwipeRow> {
  double _progress = 0;
  DismissDirection _dir = DismissDirection.none;

  Widget _bg(DismissDirection side) {
    final s = Settings.i;
    final long = _dir == side && _progress > 0.75;
    final act = side == DismissDirection.startToEnd
        ? (long ? s.swipeLongRight : s.swipeShortRight)
        : (long ? s.swipeLongLeft : s.swipeShortLeft);
    final right = side == DismissDirection.startToEnd;
    return Container(
      color: actColor(act),
      alignment: right ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!right)
            Text(
              actLabel[act]!,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          if (!right) const SizedBox(width: 8),
          Icon(actIcon(act), color: Colors.white),
          if (right) const SizedBox(width: 8),
          if (right)
            Text(
              actLabel[act]!,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Dismissible(
      key: widget.key!,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.2,
        DismissDirection.endToStart: 0.2,
      },
      onUpdate: (d) {
        if (d.direction != _dir || (d.progress - _progress).abs() > 0.04) {
          setState(() {
            _dir = d.direction;
            _progress = d.progress;
          });
        }
      },
      background: _bg(DismissDirection.startToEnd),
      secondaryBackground: _bg(DismissDirection.endToStart),
      confirmDismiss: (dir) => widget.onSwipe(dir, _progress > 0.75),
      child: widget.child,
    );
  }
}
