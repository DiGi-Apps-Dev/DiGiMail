import 'package:flutter/material.dart';

/// Tutto il testo è nero (o bianco nel tema scuro): la gerarchia si fa con
/// grandezza e peso. Il grigio si usa solo per bordi e sfondi.
const Color kNero = Color(0xFF000000);
const Color kBordo = Color(0xFFBDBDBD);
const Color kSfondoLeggero = Color(0xFFF1F3F4);
/// Arancione di Posta (stesso dell'icona): parti attive, pallini, barre.
const Color kAccento = Color(0xFFE8590C);

/// Grigio solo per le piccole icone di stato nell'elenco (graffetta, risposto), come Edison.
const Color kIconaGrigia = Color(0xFF8A8A8A);

/// Arancione dell icona di Posta (misurato sull icona): barra in alto, testata del menu, tasto Scrivi.
const Color kBluIcone = Color(0xFFFFA042);

/// Arancione più morbido della barra in alto e della testata del menu (scelto dall'utente).
const Color kBarra = Color(0xFFFFC78F);

ThemeData buildTheme({required bool dark}) {
  final fg = dark ? Colors.white : kNero;
  final bg = dark ? const Color(0xFF000000) : Colors.white;
  final box = dark ? const Color(0xFF1C1C1E) : kSfondoLeggero;
  final accent = dark ? const Color(0xFF8AB4F8) : kAccento;
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: accent,
    onPrimary: dark ? Colors.black : Colors.white,
    secondary: accent,
    onSecondary: dark ? Colors.black : Colors.white,
    error: const Color(0xFFB3261E),
    onError: Colors.white,
    surface: bg,
    onSurface: fg,
    onSurfaceVariant: fg,
    outline: kBordo,
    outlineVariant: kBordo,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: bg,
    surfaceContainerLow: bg,
    surfaceContainer: box,
    surfaceContainerHigh: box,
    surfaceContainerHighest: box,
    primaryContainer: box,
    onPrimaryContainer: fg,
    secondaryContainer: box,
    onSecondaryContainer: fg,
    inverseSurface: dark ? Colors.white : Colors.black,
    onInverseSurface: dark ? Colors.black : Colors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, hintColor: fg);
  final text = base.textTheme.apply(bodyColor: fg, displayColor: fg);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    textTheme: text,
    primaryTextTheme: text,
    iconTheme: IconThemeData(color: fg),
    appBarTheme: AppBarTheme(
      // Barra in alto arancione (come l'icona), scritte e icone nere.
      backgroundColor: dark ? bg : kBarra,
      foregroundColor: fg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: fg),
      actionsIconTheme: IconThemeData(color: fg),
      titleTextStyle: TextStyle(
        color: fg,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    listTileTheme: ListTileThemeData(textColor: fg, iconColor: fg),
    // Tasto Scrivi: cerchio blu con la matita bianca, come Edison.
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: kBarra,
      foregroundColor: Colors.black,
      shape: StadiumBorder(), // tondo sul tasto quadrato, a pillola su quello con scritta

      elevation: 4,
    ),
    dividerTheme: const DividerThemeData(
      color: kBordo,
      thickness: 0.8,
      space: 0.8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: fg),
      labelStyle: TextStyle(color: fg),
      floatingLabelStyle: TextStyle(color: fg, fontWeight: FontWeight.w700),
      helperStyle: TextStyle(color: fg),
      prefixStyle: TextStyle(color: fg),
      border: const OutlineInputBorder(borderSide: BorderSide(color: kBordo)),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: kBordo),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: fg, width: 1.6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? Colors.white : Colors.black,
      contentTextStyle: TextStyle(
        color: dark ? Colors.black : Colors.white,
        fontSize: 16,
      ),
      actionTextColor: dark ? kAccento : const Color(0xFF8AB4F8),
      behavior: SnackBarBehavior.floating,
    ),
    cardTheme: CardThemeData(color: box, elevation: 0, margin: EdgeInsets.zero),
    dialogTheme: DialogThemeData(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: fg,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(color: fg, fontSize: 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: bg,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: fg, fontSize: 16),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: box,
      labelStyle: TextStyle(color: fg),
      side: const BorderSide(color: kBordo),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? (dark ? Colors.black : Colors.white)
            : fg,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accent : box,
      ),
      trackOutlineColor: WidgetStateProperty.all(fg),
    ),
    // «Invia» e gli altri tasti pieni: arancione con scritte nere.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kBluIcone,
        foregroundColor: Colors.black,
        disabledBackgroundColor: kBluIcone.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.black,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        disabledForegroundColor: fg,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        disabledForegroundColor: fg,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: fg,
        disabledForegroundColor: fg,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bg,
      labelTextStyle: WidgetStateProperty.all(
        TextStyle(color: fg, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

/// Etichetta di sezione: MAIUSCOLO, nera, 20 px.
class Etichetta extends StatelessWidget {
  final String testo;
  const Etichetta(this.testo, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
    child: Text(
      testo.toUpperCase(),
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

const Color kLink = Color(0xFFE8590C);
