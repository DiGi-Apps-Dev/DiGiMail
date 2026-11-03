import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Azioni che si possono assegnare ai gesti e alla barra sotto l'email.
enum Act {
  none,
  delete,
  archive,
  toggleRead,
  snooze,
  flag,
  spam,
  move,
  reply,
  replyAll,
  forward,
  block,
  unsubscribe,
}

const Map<Act, String> actLabel = {
  Act.none: 'Nessuna azione',
  Act.delete: 'Elimina',
  Act.archive: 'Archivia',
  Act.toggleRead: 'Letta / non letta',
  Act.snooze: 'Rimanda',
  Act.flag: 'Stella',
  Act.spam: 'Segnala come spam',
  Act.move: 'Sposta in...',
  Act.reply: 'Rispondi',
  Act.replyAll: 'Rispondi a tutti',
  Act.forward: 'Inoltra',
  Act.block: 'Blocca mittente',
  Act.unsubscribe: 'Disiscriviti',
};

enum MarkRead { immediately, after3, after10, never }

const Map<MarkRead, String> markReadLabel = {
  MarkRead.immediately: 'Subito all\'apertura',
  MarkRead.after3: 'Dopo 3 secondi',
  MarkRead.after10: 'Dopo 10 secondi',
  MarkRead.never: 'Mai, la segno io',
};

enum DateStyle { relative, short, long }

const Map<DateStyle, String> dateStyleLabel = {
  DateStyle.relative: 'Oggi: ora. Prima: giorno e mese',
  DateStyle.short: 'Sempre giorno/mese/anno',
  DateStyle.long: 'Sempre giorno, mese e ora',
};

/// Tutte le impostazioni dell'app, salvate in SharedPreferences.
/// Lo stesso oggetto serve alle schermate e al servizio in background.
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings i = Settings._();
  SharedPreferences? _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    await _p!.reload();
    notifyListeners();
  }

  /// Rilegge dal disco (il servizio in background può avere cambiato qualcosa).
  Future<void> reload() async {
    await _p?.reload();
    notifyListeners();
  }

  @visibleForTesting
  void useForTest(SharedPreferences p) => _p = p;

  T _get<T>(String k, T def) {
    final v = _p?.get(k);
    return v is T ? v : def;
  }

  Future<void> _set(String k, Object v) async {
    final p = _p!;
    if (v is bool) {
      await p.setBool(k, v);
    } else if (v is int) {
      await p.setInt(k, v);
    } else if (v is double) {
      await p.setDouble(k, v);
    } else if (v is String) {
      await p.setString(k, v);
    } else if (v is List<String>) {
      await p.setStringList(k, v);
    }
    notifyListeners();
  }

  // ----- Generale -----
  bool get replyAllDefault => _get('replyAllDefault', false);
  set replyAllDefault(bool v) => _set('replyAllDefault', v);

  /// Toglie le scelte di una casella rimossa, così non restano legate a un numero che non esiste.
  Future<void> forgetAccount(int id) async {
    final p = _p!;
    for (final k in ['syncMode_', 'syncMin_', 'syncWifi_', 'syncDays_', 'folderOrder_']) {
      await p.remove('$k$id');
    }
    if (defaultAccountId == id) await p.remove('defaultAccountId');
    if (lastAccountId == id) await p.remove('lastAccountId');
    notifyListeners();
  }

  /// Rubrica del telefono: chiesta una volta, con la spiegazione, e la risposta dell'utente.
  bool get rubricaChiesta => _get('rubricaChiesta', false);
  set rubricaChiesta(bool v) => _set('rubricaChiesta', v);
  bool get rubricaOk => _get('rubricaOk', false);
  set rubricaOk(bool v) => _set('rubricaOk', v);

  int get defaultAccountId => _get('defaultAccountId', 0);
  set defaultAccountId(int v) => _set('defaultAccountId', v);

  int get lastAccountId => _get('lastAccountId', 0);
  set lastAccountId(int v) => _set('lastAccountId', v);
  String get lastFolder => _get('lastFolder', 'INBOX');
  set lastFolder(String v) => _set('lastFolder', v);

  MarkRead get markRead => MarkRead.values[_get('markRead', 0).clamp(0, 3)];
  set markRead(MarkRead v) => _set('markRead', v.index);

  int get undoSeconds => _get('undoSeconds', 5);
  set undoSeconds(int v) => _set('undoSeconds', v);

  bool get previewOn => _get('previewOn', true) && _get('previewLines', 2) > 0;
  set previewOn(bool v) => _set('previewOn', v);
  int get previewLines {
    final n = _get('previewLines', 2);
    return n < 1 ? 2 : n;
  }

  set previewLines(int v) => _set('previewLines', v);

  double get fontScale => _get('fontScale', 1.0);
  set fontScale(double v) => _set('fontScale', v);

  DateStyle get dateStyle => DateStyle.values[_get('dateStyle', 0).clamp(0, 2)];
  set dateStyle(DateStyle v) => _set('dateStyle', v.index);

  bool get use24h => _get('use24h', true);
  set use24h(bool v) => _set('use24h', v);

  /// 'light' | 'dark' | 'system'
  String get themeMode => _get('themeMode', 'light');
  set themeMode(String v) => _set('themeMode', v);

  bool get showAvatars => _get('showAvatars', true);
  set showAvatars(bool v) => _set('showAvatars', v);

  /// «DiGiMail Focus»: in arrivo diviso fra Principali e Altro. Spento di default.
  bool get focusedInbox => _get('focusedInbox', false);
  set focusedInbox(bool v) => _set('focusedInbox', v);

  // ----- Gesti: 4 (corto/lungo, sinistra/destra) -----
  Act _act(String k, Act def) => _noArchive(
    Act.values[_get(k, def.index).clamp(0, Act.values.length - 1)],
    def,
  );
  Act _noArchive(Act a, Act def) =>
      a == Act.archive ? (def == Act.archive ? Act.none : def) : a;
  Act get swipeShortLeft => swipeLongLeft;
  set swipeShortLeft(Act v) => swipeLongLeft = v;
  Act get swipeLongLeft => _act('swLongLeft', Act.delete);
  set swipeLongLeft(Act v) => _set('swLongLeft', v.index);
  Act get swipeShortRight => swipeLongRight;
  set swipeShortRight(Act v) => swipeLongRight = v;
  Act get swipeLongRight => _act('swLongRight', Act.toggleRead);
  set swipeLongRight(Act v) => _set('swLongRight', v.index);

  // ----- Ordine delle cartelle, per casella (lo decide l'utente) -----
  List<String> folderOrder(int accountId) =>
      _p?.getStringList('folderOrder_$accountId') ?? const [];
  Future<void> setFolderOrder(int accountId, List<String> paths) =>
      _set('folderOrder_$accountId', paths);
  // ----- Barra sotto l'email -----
  List<Act> get toolbar {
    final l = _p?.getStringList('toolbar');
    if (l == null) return [Act.move, Act.delete, Act.reply, Act.forward];
    return l
        .map(
          (s) =>
              Act.values.firstWhere((a) => a.name == s, orElse: () => Act.none),
        )
        .where((a) => a != Act.none && a != Act.archive)
        .toList();
  }

  set toolbar(List<Act> v) => _set('toolbar', v.map((a) => a.name).toList());

  // ----- Rimanda: orari -----
  int get snoozeMorningHour => _get('snoozeMorning', 8);
  set snoozeMorningHour(int v) => _set('snoozeMorning', v);
  int get snoozeEveningHour => _get('snoozeEvening', 18);
  set snoozeEveningHour(int v) => _set('snoozeEvening', v);
  int get snoozeLaterHours => _get('snoozeLater', 3);
  set snoozeLaterHours(int v) => _set('snoozeLater', v);

  // ----- Notifiche -----
  bool get notifyEnabled => _get('notifyEnabled', true);
  set notifyEnabled(bool v) => _set('notifyEnabled', v);
  bool get notifyShowSender => _get('notifyShowSender', true);
  set notifyShowSender(bool v) => _set('notifyShowSender', v);
  bool get notifyShowPreview => _get('notifyShowPreview', true);
  set notifyShowPreview(bool v) => _set('notifyShowPreview', v);
  bool get notifyVibrate => _get('notifyVibrate', true);
  set notifyVibrate(bool v) => _set('notifyVibrate', v);
  bool get badgeCount => _get('badgeCount', true);
  set badgeCount(bool v) => _set('badgeCount', v);
  bool get pushService => _get('pushService', true);
  set pushService(bool v) => _set('pushService', v);
  bool get notifyOnlyInbox => _get('notifyOnlyInbox', true);
  set notifyOnlyInbox(bool v) => _set('notifyOnlyInbox', v);

  /// Quanto mostrare nella notifica: 0 solo mittente, 1 mittente e oggetto,
  /// 2 anche l'inizio del testo, 3 anche un testo lungo.
  int get notifyDetail => _get('notifyDetail', 2).clamp(0, 3);
  set notifyDetail(int v) => _set('notifyDetail', v);

  /// Sulla schermata di blocco compare solo «Nuova email».
  bool get notifyHideOnLock => _get('notifyHideOnLock', false);
  set notifyHideOnLock(bool v) => _set('notifyHideOnLock', v);

  /// Suono quando un'email è stata inviata.
  bool get sendSound => _get('sendSound', false);
  set sendSound(bool v) => _set('sendSound', v);

  // ----- Sincronizzazione per casella -----
  /// 'push' = connessione sempre aperta; 'interval' = controllo ogni tot minuti.
  String syncMode(int accountId) =>
      pushService ? _get('syncMode_$accountId', 'push') : 'interval';
  String savedSyncMode(int accountId) => _get('syncMode_$accountId', 'push');
  Future<void> setSyncMode(int accountId, String v) =>
      _set('syncMode_$accountId', v);
  int syncMinutes(int accountId) => _get('syncMin_$accountId', 15);
  Future<void> setSyncMinutes(int accountId, int v) =>
      _set('syncMin_$accountId', v);
  bool syncWifiOnly(int accountId) => _get('syncWifi_$accountId', false);
  Future<void> setSyncWifiOnly(int accountId, bool v) =>
      _set('syncWifi_$accountId', v);

  /// Giorni di storico da tenere fuori da In arrivo (0 = tutto).
  int historyDays(int accountId) => _get('syncDays_$accountId', 0);
  Future<void> setHistoryDays(int accountId, int v) =>
      _set('syncDays_$accountId', v);

  /// Ore silenziose (0 = spente). Formato 'HH-HH'.
  String get quietHours => _get('quietHours', '');
  set quietHours(String v) => _set('quietHours', v);

  // ----- Sicurezza e privacy -----
  bool get appLock => _get('appLock', false);
  set appLock(bool v) => _set('appLock', v);
  int get lockDelaySeconds => _get('lockDelay', 0);
  set lockDelaySeconds(int v) => _set('lockDelay', v);
  bool get blockRemoteImages => _get('blockRemoteImages', false);
  set blockRemoteImages(bool v) => _set('blockRemoteImages', v);
  bool get blockTracking => _get('blockTracking', true);
  set blockTracking(bool v) => _set('blockTracking', v);
  bool get warnSuspicious => _get('warnSuspicious', true);
  set warnSuspicious(bool v) => _set('warnSuspicious', v);
  bool get hideInRecents => _get('hideInRecents', false);
  set hideInRecents(bool v) => _set('hideInRecents', v);

  // ----- IA (Cloudflare Workers AI) -----
  String get aiAccountId => _get('aiAccountId', '');
  set aiAccountId(String v) => _set('aiAccountId', v);
  String get aiModel => _get('aiModel', '@cf/openai/gpt-oss-120b');
  set aiModel(String v) => _set('aiModel', v);
  String get aiLanguage => _get('aiLanguage', 'italiano');
  set aiLanguage(String v) => _set('aiLanguage', v);
  String get aiTone => _get('aiTone', 'cordiale e chiaro');
  set aiTone(String v) => _set('aiTone', v);

  // ----- Accesso Microsoft (Outlook/Hotmail) -----
  String get msClientId => _get('msClientId', '');
  set msClientId(String v) => _set('msClientId', v);

  // ----- Riassunto newsletter -----
  // Il riassunto newsletter non c'è più (richiesta dell'utente): sempre spento.

  /// Esporta tutte le impostazioni (non le password) come testo.
  /// [all]: anche il codice dell'account IA, per la copia completa cifrata.
  Map<String, Object?> export({bool all = false}) {
    final p = _p!;
    return {
      for (final k in p.getKeys())
        if (all || k != 'aiAccountId') k: p.get(k),
    };
  }

  /// Valgono solo per il telefono che le ha scritte (registrazione sul NAS, ultimo avviso).
  static const _soloQuesto = {'nasPushOk', 'nasPushSig', 'nasUltimoAvviso', 'nasPushDaRifare', 'digestDay'};

  Future<void> import(Map<String, Object?> m) async {
    for (final e in m.entries) {
      if (_soloQuesto.contains(e.key)) continue;
      final v = e.value;
      if (v is bool) {
        await _p!.setBool(e.key, v);
      } else if (v is int) {
        await _p!.setInt(e.key, v);
      } else if (v is double) {
        await _p!.setDouble(e.key, v);
      } else if (v is String) {
        await _p!.setString(e.key, v);
      } else if (v is List) {
        await _p!.setStringList(e.key, v.map((x) => '$x').toList());
      }
    }
    notifyListeners();
  }
}
