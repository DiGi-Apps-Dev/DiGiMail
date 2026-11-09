import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../db.dart';
import '../ops.dart';
import '../theme.dart';
import 'compose_screen.dart';
import 'widgets.dart';

/// Email in coda: programmate per più tardi, in attesa di rete o non riuscite.
class ScheduledScreen extends StatefulWidget {
  const ScheduledScreen({super.key});
  @override
  State<ScheduledScreen> createState() => _ScheduledScreenState();
}

class _ScheduledScreenState extends State<ScheduledScreen> {
  List<Map<String, Object?>> _rows = [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = Db.i.changes.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Db.i.scheduledList();
    if (mounted) setState(() => _rows = r);
  }

  Map<String, dynamic> _payload(Map<String, Object?> r) =>
      jsonDecode(r['payload'] as String) as Map<String, dynamic>;

  Future<void> _edit(Map<String, Object?> r) async {
    final id = r['id'] as int;
    final p = _payload(r);
    // Mentre si modifica, l'invio è «in modifica»: non parte e non sparisce. Prima passava
    // da «annullato», che cancella la riga: uscendo senza inviare l'email era persa.
    if (!await Db.i.claimEditing(id)) {
      if (mounted) showSnack(context, 'È già in invio.');
      return;
    }
    if (!mounted) return;
    final init = ComposeInit.fromPayload(p);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ComposeScreen(init: init)),
    );
    if (init.consumata) {
      // Inviata, riprogrammata o salvata come bozza da Scrivi: quella vecchia non serve più.
      await Db.i.setScheduledStatus(id, 'cancelled');
    } else {
      // Uscita senza inviare né salvare: l'invio programmato resta com'era, non sparisce.
      await Db.i.setScheduledStatus(id, 'pending');
      if (mounted) showSnack(context, 'L\'invio programmato è rimasto com\'era.');
    }
  }

  Future<void> _sendNow(Map<String, Object?> r) async {
    await Db.i.rescheduleNow(r['id'] as int);
    final n = await Ops.processScheduled();
    if (mounted)
      showSnack(
        context,
        n > 0
            ? 'Inviata.'
            : 'Non è partita: ${Ops.lastError ?? 'riprovo tra poco'}',
      );
  }

  Future<void> _cancel(Map<String, Object?> r) async {
    if (!await confirm(
      context,
      'Annullare l\'invio?',
      'L\'email non partirà e andrà persa.',
      yes: 'Annulla invio',
    ))
      return;
    await Ops.cancelQueued(r['id'] as int);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const BrandBar(), title: const Text('Programmati')),
      body: _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nessuna email in coda.',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [for (final r in _rows) _card(r)],
            ),
    );
  }

  Widget _card(Map<String, Object?> r) {
    final p = _payload(r);
    final at = DateTime.fromMillisecondsSinceEpoch(r['send_at'] as int);
    final status = r['status'] as String;
    final to = (p['to'] as List).join(', ');
    final subject = (p['subject'] as String).isEmpty
        ? '(senza oggetto)'
        : p['subject'] as String;
    final late = status == 'pending' && at.isBefore(DateTime.now());
    final label = status == 'failed'
        ? 'NON RIUSCITA'
        : status == 'editing'
        ? 'IN MODIFICA'
        : status == 'sending'
        ? 'IN INVIO'
        : late
        ? 'IN ATTESA DI RETE'
        : 'PROGRAMMATA PER ${formatDate(at).toUpperCase()}';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: kBordo),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: status == 'failed' ? const Color(0xFFB3261E) : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subject,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text('A: $to', style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: status == 'sending' || status == 'editing' ? null : () => _edit(r),
                  child: const Text('Modifica'),
                ),
                OutlinedButton(
                  onPressed: status == 'sending' || status == 'editing' ? null : () => _sendNow(r),
                  child: Text(status == 'failed' ? 'Riprova' : 'Invia ora'),
                ),
                OutlinedButton(
                  onPressed: status == 'sending' ? null : () => _cancel(r),
                  child: const Text('Annulla invio'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
