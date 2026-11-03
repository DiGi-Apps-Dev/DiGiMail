import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:digimail/notify_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('avatar della notifica: iniziali su cerchio', () async {
    final b = await notifyAvatar('Anna Verdi', 'anna@esempio.ch', 0xFF1E88E5);
    expect(b, isNotNull);
    expect(b!.length, greaterThan(500));
    final d = Platform.environment['DIGIMAIL_SHOTS'];
    if (d != null) File('$d/notifica_avatar.png').writeAsBytesSync(b);
  });
}
