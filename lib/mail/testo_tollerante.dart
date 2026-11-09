import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

/// Testo (semplice o HTML) di un'email anche quando il mittente l'ha codificato male.
///
/// La libreria di posta decodifica il base64 in modo rigido: se l'ultimo gruppo ha bit
/// avanzati diversi da zero (es. «Cm==» invece di «Cg==», email Proton del 09.11.2026)
/// si ferma con `FormatException` e l'email non si legge. Gmail e K-9 Mail ignorano
/// quei bit: qui si fa lo stesso, solo quando la decodifica normale fallisce.
String? testoParte(em.MimeMessage mime, {required bool html}) {
  try {
    return html ? mime.decodeTextHtmlPart() : mime.decodeTextPlainPart();
  } on FormatException {
    final sub = html ? em.MediaSubtype.textHtml : em.MediaSubtype.textPlain;
    final part = mime.mediaType.sub == sub
        ? mime
        : mime.getPartWithMediaSubtype(sub);
    if (part == null) return null;
    return _decodificaTollerante(part);
  }
}

String? _decodificaTollerante(em.MimePart part) {
  final enc = (part.getHeaderValue('content-transfer-encoding') ?? '')
      .trim()
      .toLowerCase();
  final corpo = _corpoGrezzo(part);
  if (corpo == null) return null;
  final Uint8List byte;
  if (enc == 'base64' || enc == 'b' || enc == 'base-64') {
    byte = base64Tollerante(corpo);
  } else {
    byte = Uint8List.fromList(latin1.encode(corpo));
  }
  final cs = part.getHeaderContentType()?.charset?.toLowerCase().trim();
  final codifica = cs == null ? null : Encoding.getByName(cs);
  if (codifica == null || codifica == utf8) {
    return utf8.decode(byte, allowMalformed: true);
  }
  try {
    return codifica.decode(byte);
  } catch (_) {
    return utf8.decode(byte, allowMalformed: true);
  }
}

/// Il corpo così com'è arrivato (ancora codificato), senza le intestazioni della parte.
String? _corpoGrezzo(em.MimePart part) {
  final d = part.mimeData;
  if (d is em.TextMimeData) {
    try {
      return d.body;
    } catch (_) {
      return _senzaIntestazioni(d.text, d.containsHeader);
    }
  }
  if (d is em.BinaryMimeData) {
    return _senzaIntestazioni(latin1.decode(d.data, allowInvalid: true), d.containsHeader);
  }
  return null;
}

String _senzaIntestazioni(String t, bool conIntestazioni) {
  if (!conIntestazioni) return t;
  if (t.startsWith('\r\n')) return t.substring(2);
  final i = t.indexOf('\r\n\r\n');
  return i < 0 ? t : t.substring(i + 4);
}

/// Base64 letto come Gmail e K-9: si tengono solo i caratteri validi, si ignorano
/// il segno «=» e i bit avanzati dell'ultimo gruppo.
Uint8List base64Tollerante(String s) {
  const alfabeto =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final valori = List<int>.filled(128, -1);
  for (var i = 0; i < alfabeto.length; i++) {
    valori[alfabeto.codeUnitAt(i)] = i;
  }
  valori['-'.codeUnitAt(0)] = 62;
  valori['_'.codeUnitAt(0)] = 63;
  final out = BytesBuilder(copy: false);
  var acc = 0;
  var bit = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 128) continue;
    final v = valori[c];
    if (v < 0) continue;
    acc = (acc << 6) | v;
    bit += 6;
    if (bit >= 8) {
      bit -= 8;
      out.addByte((acc >> bit) & 0xFF);
      acc &= (1 << bit) - 1;
    }
  }
  return out.takeBytes();
}
