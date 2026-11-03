import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../sender_logo.dart';
import '../settings.dart';
import '../theme.dart';

/// Data e ora come sceglie l'utente nelle impostazioni.
String formatDate(DateTime d, {DateTime? now}) {
  final s = Settings.i;
  final n = now ?? DateTime.now();
  final timeFmt = s.use24h
      ? DateFormat('HH:mm', 'it')
      : DateFormat('h:mm a', 'it');
  switch (s.dateStyle) {
    case DateStyle.relative:
      if (d.year == n.year && d.month == n.month && d.day == n.day)
        return timeFmt.format(d);
      final y = n.subtract(const Duration(days: 1));
      if (d.year == y.year && d.month == y.month && d.day == y.day)
        return 'Ieri';
      if (d.year == n.year) return DateFormat('d MMM', 'it').format(d);
      return DateFormat('dd/MM/yy', 'it').format(d);
    case DateStyle.short:
      return DateFormat('dd/MM/yyyy', 'it').format(d);
    case DateStyle.long:
      return '${DateFormat('d MMM yyyy', 'it').format(d)} ${timeFmt.format(d)}';
  }
}

String formatFull(DateTime d) {
  final s = Settings.i;
  final timeFmt = s.use24h
      ? DateFormat('HH:mm', 'it')
      : DateFormat('h:mm a', 'it');
  return '${DateFormat('EEEE d MMMM yyyy', 'it').format(d)}, ${timeFmt.format(d)}';
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

const List<int> kColori = [
  0xFF0B57D0,
  0xFFC62828,
  0xFF2E7D32,
  0xFFEF6C00,
  0xFF6A1B9A,
  0xFF00838F,
  0xFFAD1457,
  0xFF4E342E,
  0xFF37474F,
  0xFF558B2F,
];

int colorFor(String s) =>
    kColori[s.codeUnits.fold<int>(0, (a, b) => (a + b) % kColori.length)];

/// Iniziali del mittente: true = tinta chiara con lettere scure (prova B),
/// false = cerchio pieno con lettere bianche (A, come prima ma colore per mittente).
const bool kInizialiChiare = true;

/// Sfondo e lettere delle iniziali: un colore per mittente, sempre lo stesso.
(Color, Color) coloriIniziali(String name, String addr) {
  final base = Color(colorFor((addr.isNotEmpty ? addr : name).toLowerCase()));
  if (!kInizialiChiare) return (base, Colors.white);
  return (
    Color.lerp(base, Colors.white, 0.85)!,
    Color.lerp(base, Colors.black, 0.45)!,
  );
}

/// Logo della casella: la foto scelta dall'utente, oppure la lettera su sfondo colorato.
class AccountAvatar extends StatelessWidget {
  final Account account;
  final double size;
  const AccountAvatar(this.account, {super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final path = account.logoPath;
    if (path != null && File(path).existsSync()) {
      return CircleAvatar(
        radius: size / 2,
        backgroundImage: FileImage(File(path)),
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: Color(account.color),
      child: Text(
        account.initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.46,
        ),
      ),
    );
  }
}

/// Iniziali di nome e cognome («Simone Rizzo» → SR). Se manca il nome, dall'indirizzo.
String initialsOf(String name, String addr) {
  var t = name.trim();
  if (t.isEmpty || t.contains('@')) {
    final local = addr.split('@').first;
    t = local.replaceAll(RegExp(r'[._\-+]+'), ' ').trim();
  }
  final w = t
      .split(RegExp(r'\s+'))
      .where((x) => RegExp(r'[A-Za-zÀ-ÿ0-9]').hasMatch(x))
      .toList();
  if (w.isEmpty) return '?';
  String c(String s) =>
      s.replaceFirst(RegExp(r'^[^A-Za-zÀ-ÿ0-9]+'), '')[0].toUpperCase();
  if (w.length == 1) return c(w.first);
  return c(w.first) + c(w.last);
}

/// Logo ufficiale del mittente se il suo sito ne ha uno, altrimenti le iniziali.
class SenderAvatar extends StatefulWidget {
  final String name;
  final int color;
  final double size;
  final String addr;
  const SenderAvatar(
    this.name,
    this.color, {
    super.key,
    this.size = 42,
    this.addr = '',
  });
  @override
  State<SenderAvatar> createState() => _SenderAvatarState();
}

class _SenderAvatarState extends State<SenderAvatar> {
  Uint8List? _logo;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(SenderAvatar old) {
    super.didUpdateWidget(old);
    if (old.addr != widget.addr) {
      _logo = null;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    if (widget.addr.isEmpty) return;
    final b = await SenderLogos.of(widget.addr);
    if (mounted && b != null) setState(() => _logo = b);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.size / 2;
    if (_logo != null) {
      return CircleAvatar(
        radius: r,
        backgroundColor: Colors.white,
        child: ClipOval(
          child: Image.memory(
            _logo!,
            width: widget.size * 0.8,
            height: widget.size * 0.8,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _initials(),
          ),
        ),
      );
    }
    return _initials();
  }

  Widget _initials() {
    final t = initialsOf(widget.name, widget.addr);
    final (bg, fg) = coloriIniziali(widget.name, widget.addr);
    return CircleAvatar(
      radius: widget.size / 2,
      backgroundColor: bg,
      child: Text(
        t,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: widget.size * (t.length > 1 ? 0.38 : 0.46),
        ),
      ),
    );
  }
}

/// Numero delle non lette: pallino rosso con il numero in bianco.
class CountBadge extends StatelessWidget {
  final int n;
  const CountBadge(this.n, {super.key});
  @override
  Widget build(BuildContext context) {
    if (n <= 0) return const SizedBox.shrink();
    // Cerchio e numero fissi: non seguono la grandezza del testo scelta nell'app.
    return Container(
      height: 26,
      constraints: const BoxConstraints(minWidth: 26),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBluIcone,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Text(
        n > 999 ? '999+' : '$n',
        textAlign: TextAlign.center,
        textScaler: TextScaler.noScaling,
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w900,
          fontSize: 14,
          height: 1.0,
          letterSpacing: 0,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

void showSnack(
  BuildContext context,
  String text, {
  String? action,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Text(text),
      duration: duration ?? const Duration(seconds: 4),
      action: action == null
          ? null
          : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String text, {
  String yes = 'Conferma',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Annulla'),
        ),
        TextButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
      ],
    ),
  );
  return r ?? false;
}

IconData actIcon(Act a) {
  switch (a) {
    case Act.delete:
      return Icons.delete_outline;
    case Act.archive:
      return Icons.archive_outlined;
    case Act.toggleRead:
      return Icons.mark_email_read_outlined;
    case Act.snooze:
      return Icons.snooze;
    case Act.flag:
      return Icons.star_border;
    case Act.spam:
      return Icons.report_gmailerrorred_outlined;
    case Act.move:
      return Icons.drive_file_move_outlined;
    case Act.reply:
      return Icons.reply;
    case Act.replyAll:
      return Icons.reply_all;
    case Act.forward:
      return Icons.forward;
    case Act.block:
      return Icons.block;
    case Act.unsubscribe:
      return Icons.unsubscribe_outlined;
    case Act.none:
      return Icons.not_interested;
  }
}

Color actColor(Act a) {
  switch (a) {
    case Act.delete:
    case Act.spam:
    case Act.block:
      return const Color(0xFFB3261E);
    case Act.archive:
      return const Color(0xFF2E7D32);
    case Act.snooze:
      return const Color(0xFFEF6C00);
    case Act.flag:
      return const Color(0xFFF9A825);
    default:
      return kAccento;
  }
}

/// Scelta di un'opzione fra tante, in una finestra.
Future<T?> pickOne<T>(
  BuildContext context,
  String title,
  List<T> values,
  String Function(T) label,
  T current,
) {
  return showDialog<T>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(title),
      children: [
        for (final v in values)
          RadioListTile<T>(
            value: v,
            groupValue: current,
            title: Text(label(v), style: const TextStyle(fontSize: 17)),
            onChanged: (x) => Navigator.pop(c, x),
          ),
      ],
    ),
  );
}
