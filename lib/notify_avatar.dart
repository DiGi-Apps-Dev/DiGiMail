import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'sender_logo.dart';
import 'ui/widgets.dart' show initialsOf, coloriIniziali;

/// Immagine tonda del mittente per la notifica (a destra, come in Email): il logo
/// ufficiale se il suo sito ne ha uno, altrimenti le iniziali su cerchio colorato,
/// uguali a quelle dell'elenco.
Future<Uint8List?> notifyAvatar(
  String name,
  String addr,
  int color, {
  bool fetch = true,
}) async {
  try {
    const size = 192.0;
    Uint8List? logo;
    if (addr.isNotEmpty) {
      // Con [fetch] spento si usa solo il logo già sul telefono: la notifica non aspetta e
      // non dice al sito del mittente che l'email è arrivata.
      logo = fetch
          ? await SenderLogos.of(
              addr,
            ).timeout(const Duration(seconds: 5), onTimeout: () => null)
          : await SenderLogos.peek(addr);
    }
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, size, size));
    const mid = Offset(size / 2, size / 2);
    ui.Image? img;
    if (logo != null) {
      try {
        final codec = await ui.instantiateImageCodec(
          logo,
          targetWidth: (size * 0.8).round(),
        );
        img = (await codec.getNextFrame()).image;
      } catch (_) {}
    }
    if (img != null) {
      c.drawCircle(mid, size / 2, Paint()..color = const Color(0xFFFFFFFF));
      final w = img.width.toDouble(), h = img.height.toDouble();
      final k = (size * 0.8) / (w > h ? w : h);
      final dst = Rect.fromCenter(center: mid, width: w * k, height: h * k);
      c.save();
      c.clipPath(Path()..addOval(const Rect.fromLTWH(0, 0, size, size)));
      c.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, w, h),
        dst,
        Paint()..filterQuality = FilterQuality.high,
      );
      c.restore();
    } else {
      final (bg, fg) = coloriIniziali(name, addr);
      c.drawCircle(mid, size / 2, Paint()..color = bg);
      final t = initialsOf(name, addr);
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w800,
            fontSize: size * (t.length > 1 ? 0.38 : 0.46),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, mid - Offset(tp.width / 2, tp.height / 2));
    }
    final out = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
