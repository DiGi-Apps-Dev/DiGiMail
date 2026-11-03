import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'mail/backend.dart';
import 'mail/imap_backend.dart' show friendlyError;
import 'models.dart';
import 'notify.dart';
import 'ops.dart';
import 'settings.dart';

/// Regola automatica: se [field] contiene [contains], fa [action].
class Rule {
  String id;
  String name;
  int accountId; // 0 = tutte le caselle
  String field; // from | subject | to
  String contains;
  String action; // markRead | flag | archive | delete | spam | move
  String? target; // percorso cartella, per move
  bool enabled;

  Rule({
    required this.id,
    required this.name,
    this.accountId = 0,
    this.field = 'from',
    required this.contains,
    this.action = 'markRead',
    this.target,
    this.enabled = true,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'accountId': accountId,
    'field': field,
    'contains': contains,
    'action': action,
    'target': target,
    'enabled': enabled,
  };

  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
    id: j['id'] as String,
    name: (j['name'] ?? '') as String,
    accountId: (j['accountId'] ?? 0) as int,
    field: (j['field'] ?? 'from') as String,
    contains: (j['contains'] ?? '') as String,
    action: (j['action'] ?? 'markRead') as String,
    target: j['target'] as String?,
    enabled: (j['enabled'] ?? true) as bool,
  );

  bool matches(Account a, Msg m) {
    if (!enabled || contains.trim().isEmpty) return false;
    if (accountId != 0 && accountId != a.id) return false;
    final needle = contains.toLowerCase().trim();
    switch (field) {
      case 'subject':
        return m.subject.toLowerCase().contains(needle);
      case 'to':
        return '${m.toAddrs},${m.ccAddrs}'.toLowerCase().contains(needle);
      default:
        return '${m.fromName} ${m.fromAddr}'.toLowerCase().contains(needle);
    }
  }
}

const Map<String, String> ruleFieldLabel = {
  'from': 'Il mittente contiene',
  'subject': 'L\'oggetto contiene',
  'to': 'Il destinatario contiene',
};
const Map<String, String> ruleActionLabel = {
  'markRead': 'Segna come letta',
  'flag': 'Metti la stella',
  'delete': 'Sposta nel cestino',
  'spam': 'Sposta nello spam',
  'move': 'Sposta in una cartella',
};

class Rules {
  Rules._();
  static const key = 'rules';

  static Future<List<Rule>> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Rule.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Quante email già scaricate in Posta in arrivo corrispondono a [r] (anche se è spenta).
  static Future<int> quanteCorrispondono(Rule r, List<Account> accounts) async {
    final prova = Rule.fromJson({...r.toJson(), 'enabled': true});
    var n = 0;
    for (final a in accounts) {
      for (final m in await Db.i.messages(a.id!, 'INBOX', limit: 5000)) {
        if (prova.matches(a, m)) n++;
      }
    }
    return n;
  }

  static Future<void> save(List<Rule> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(list.map((r) => r.toJson()).toList()));
    Settings.i.reload();
  }

  /// Applica le regole alle email appena arrivate. Restituisce quelle che
  /// restano in arrivo e vanno notificate (le segnate come lette non suonano).
  static Future<List<Msg>> apply(
    Account a,
    MailBackend b,
    List<Msg> fresh,
  ) async {
    final rules = await load();
    if (rules.isEmpty) return fresh;
    final keep = <Msg>[];
    for (final m in fresh) {
      Rule? hit;
      for (final r in rules) {
        if (r.matches(a, m)) {
          hit = r;
          break;
        }
      }
      if (hit == null) {
        keep.add(m);
        continue;
      }
      try {
        switch (hit.action) {
          case 'markRead':
            await Ops.perform(Act.toggleRead, a, [m], force: true);
            break;
          case 'flag':
            await Ops.perform(Act.flag, a, [m], force: true);
            keep.add(m);
            break;
          case 'archive':
            await Ops.perform(Act.archive, a, [m]);
            break;
          case 'delete':
            await Ops.perform(Act.delete, a, [m]);
            break;
          case 'spam':
            await Ops.perform(Act.spam, a, [m]);
            break;
          case 'move':
            if (hit.target != null) {
              await Ops.perform(Act.move, a, [m], targetPath: hit.target);
            } else {
              keep.add(m);
            }
            break;
          default:
            keep.add(m);
        }
      } catch (e) {
        keep.add(m);
        // Una regola che non può agire (cartella sparita) si dice, se no fallisce in silenzio a ogni email.
        if (!Ops.isNetworkError(e)) {
          try {
            await Notify.showInfo(
              'Regola non applicata',
              '${hit.name.isEmpty ? hit.contains : hit.name}: ${friendlyError(e)}',
              id: 800000500,
            );
          } catch (_) {}
        }
      }
    }
    return keep;
  }
}
