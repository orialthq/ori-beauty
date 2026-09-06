import 'package:flutter/material.dart';

/// Shared visual language for luffi.
///
/// Sea-glass green gives saved moments a gentle direction. The near-black
/// canvas keeps the workspace calm, with readable secondary text on phones.
abstract final class AppTheme {
  /// Keeps bottom-sheet actions above Android gesture/three-button navigation.
  /// `showModalBottomSheet(useSafeArea: true)` does not protect the bottom edge.
  static const bottomSheetSafeInset = 28.0;

  static const primary = Color(0xFFB6E8D8);
  static const primarySoft = Color(0xFF1C352E);
  static const accent = Color(0xFFE6B59D);
  static const accentSoft = Color(0xFF352820);
  static const background = Color(0xFF0B0B0D);
  static const surface = Color(0xFF151517);
  static const surfaceRaised = Color(0xFF1C1C20);
  static const ink = Color(0xFFF4F4F2);
  static const muted = Color(0xFFB1B1B8);
  static const subtle = Color(0xFF8B8B94);
  static const border = Color(0xFF2E2E34);
  static const fill = Color(0xFF202024);
  static const positive = Color(0xFF91CFBB);
  static const caution = Color(0xFFFFB84D);
  static const negative = Color(0xFFFF6B67);

  // The planning flow keeps its own token names so its screens can be restyled
  // without touching the rest of the app, but the colors are the app's own.
  // They started as a paper-like light palette, which made the plan tab read as
  // a different app dropped inside a near-black one.
  static const planCanvas = background;
  static const planSurface = surface;
  static const planInk = ink;
  static const planMuted = muted;
  static const planSubtle = subtle;
  static const planBorder = border;
  static const planNegative = negative;

  // The three hues that tell a plan's states apart — 활성, 예정, 완료 — mapped
  // onto the accents the rest of the app already reads as "now", "waiting", and
  // "done". Each pairs with a darkened container of the same hue, the recipe
  // primarySoft and accentSoft already follow.
  static const planMauve = primary;
  static const planMauveSoft = primarySoft;
  static const planSand = caution;
  static const planSandSoft = Color(0xFF3A2A12);
  static const planSage = positive;
  static const planSageSoft = Color(0xFF0E332F);

  // The nearest plan is filled rather than outlined, so one card carries the
  // whole list's urgency and the rest can stay quiet. Both ends sit in the same
  // family as `accent`, which is the app's own "now" color.
  static const planHeroStart = Color(0xFFE0AD94);
  static const planHeroEnd = Color(0xFFF0CAB4);

  /// Ink for the filled card. Near-black rather than white: the gradient is
  /// light enough that white type on it fails contrast at small sizes.
  static const planHeroInk = Color(0xFF1A0B08);
  static const planHeroMuted = Color(0xCC2A0F0A);

  /// Segments already ticked off, on the filled card and off it. The mint is
  /// `primary` — the same green the rest of the app spends on done-ness.
  static const planProgressDone = primary;
  static const planProgressDoneOnHero = Color(0xFF7E2018);
  static const planProgressTrack = Color(0xFF2A2A30);
  static const planProgressTrackOnHero = Color(0x33330D08);

  // The one banner that counts what is due. Warm rather than red: it is a nudge
  // about today, not an error.
  static const planAlert = Color(0xFFE6B59D);
  static const planAlertSurface = Color(0xFF29211D);
  static const planAlertBorder = Color(0xFF594339);

  /// Local theme for the plan inbox/editor.
  ///
  /// This is intentionally opt-in. Feature screens wrap themselves with this
  /// theme so legacy surfaces keep the original high-contrast dark palette.
  static ThemeData plansTheme(ThemeData base) {
    const scheme = ColorScheme.dark(
      primary: planMauve,
      onPrimary: Color(0xFF101208),
      primaryContainer: planMauveSoft,
      onPrimaryContainer: planMauve,
      secondary: planSage,
      onSecondary: Color(0xFF06201C),
      secondaryContainer: planSageSoft,
      onSecondaryContainer: planSage,
      surface: planSurface,
      onSurface: planInk,
      error: planNegative,
      outline: planBorder,
      outlineVariant: fill,
    );

    final textTheme = base.textTheme
        .apply(bodyColor: planInk, displayColor: planInk)
        .copyWith(
          headlineMedium: const TextStyle(
            color: planInk,
            fontSize: 30,
            height: 1.2,
            letterSpacing: -0.9,
            fontWeight: FontWeight.w800,
          ),
          titleLarge: const TextStyle(
            color: planInk,
            fontSize: 18,
            height: 1.35,
            letterSpacing: -0.35,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: const TextStyle(
            color: planInk,
            fontSize: 16,
            height: 1.4,
            letterSpacing: -0.2,
            fontWeight: FontWeight.w700,
          ),
          bodyLarge: const TextStyle(
            color: planInk,
            fontSize: 16,
            height: 1.55,
            letterSpacing: -0.15,
            fontWeight: FontWeight.w400,
          ),
          bodyMedium: const TextStyle(
            color: planInk,
            fontSize: 14,
            height: 1.5,
            letterSpacing: -0.1,
            fontWeight: FontWeight.w400,
          ),
          labelLarge: const TextStyle(
            color: planInk,
            fontSize: 15,
            height: 1.4,
            letterSpacing: -0.1,
            fontWeight: FontWeight.w700,
          ),
        );

    return base.copyWith(
      colorScheme: scheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: planCanvas,
      canvasColor: planCanvas,
      textTheme: textTheme,
      iconTheme: const IconThemeData(color: planMuted),
      dividerTheme: const DividerThemeData(
        color: planBorder,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: planCanvas,
        foregroundColor: planInk,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        iconTheme: IconThemeData(color: planInk, size: 23),
        titleTextStyle: TextStyle(
          color: planInk,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.25,
        ),
      ),
      cardTheme: const CardThemeData(
        color: planSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: planBorder),
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: fill,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 17),
        labelStyle: TextStyle(color: planMuted, fontWeight: FontWeight.w500),
        floatingLabelStyle: TextStyle(
          color: planMauve,
          fontWeight: FontWeight.w600,
        ),
        helperStyle: TextStyle(color: planSubtle, fontSize: 12, height: 1.4),
        hintStyle: TextStyle(color: planSubtle),
        prefixIconColor: planMuted,
        suffixIconColor: planMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: planBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: planBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: planMauve, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: planNegative),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: planNegative, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          backgroundColor: planMauve,
          foregroundColor: const Color(0xFF101208),
          disabledBackgroundColor: planBorder,
          disabledForegroundColor: planSubtle,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          foregroundColor: planInk,
          side: const BorderSide(color: planBorder),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: planMauve,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: planSurface,
        surfaceTintColor: Colors.transparent,
      ),
      datePickerTheme: const DatePickerThemeData(
        backgroundColor: planSurface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: planMauveSoft,
        headerForegroundColor: planInk,
      ),
      timePickerTheme: const TimePickerThemeData(
        backgroundColor: planSurface,
        dialBackgroundColor: planMauveSoft,
        dialHandColor: planMauve,
        hourMinuteColor: planMauveSoft,
        hourMinuteTextColor: planInk,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: planSurface,
        modalBackgroundColor: planSurface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: planBorder,
      ),
    );
  }

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: primary,
      onPrimary: Color(0xFF101208),
      primaryContainer: primarySoft,
      onPrimaryContainer: primary,
      secondary: accent,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: ink,
      error: negative,
      outline: border,
      outlineVariant: fill,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      splashFactory: InkRipple.splashFactory,
      fontFamily: 'SUIT',
      fontFamilyFallback: const ['Apple SD Gothic Neo', 'sans-serif'],
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          fontSize: 38,
          height: 1.08,
          letterSpacing: -1.2,
          fontWeight: FontWeight.w900,
          color: ink,
        ),
        headlineLarge: TextStyle(
          fontSize: 32,
          height: 1.18,
          letterSpacing: -0.9,
          fontWeight: FontWeight.w900,
          color: ink,
        ),
        headlineMedium: TextStyle(
          fontSize: 27,
          height: 1.24,
          letterSpacing: -0.7,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
        titleLarge: TextStyle(
          fontSize: 22,
          height: 1.3,
          letterSpacing: -0.45,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
        titleMedium: TextStyle(
          fontSize: 18,
          height: 1.38,
          letterSpacing: -0.25,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          height: 1.5,
          letterSpacing: -0.15,
          fontWeight: FontWeight.w400,
          color: ink,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 1.5,
          letterSpacing: -0.1,
          fontWeight: FontWeight.w400,
          color: ink,
        ),
        labelLarge: TextStyle(
          fontSize: 15,
          height: 1.4,
          letterSpacing: -0.1,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        iconTheme: IconThemeData(size: 24, color: ink),
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: const CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: border),
          borderRadius: BorderRadius.all(Radius.circular(22)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: fill,
        selectedColor: primarySoft,
        checkmarkColor: primary,
        side: const BorderSide(color: border),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: const TextStyle(
          color: muted,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
        secondaryLabelStyle: const TextStyle(
          color: primary,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: primarySoft,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? primary : subtle,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? primary : subtle, size: 24);
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 56),
          backgroundColor: primary,
          foregroundColor: const Color(0xFF101208),
          disabledBackgroundColor: fill,
          disabledForegroundColor: subtle,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 54),
          foregroundColor: ink,
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(44)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surfaceRaised,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 17),
        labelStyle: TextStyle(color: muted, fontWeight: FontWeight.w600),
        helperStyle: TextStyle(color: subtle, fontSize: 12),
        hintStyle: TextStyle(color: subtle),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: border,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: TextStyle(color: background, fontSize: 14),
        actionTextColor: Color(0xFF4C6500),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
    );
  }

  // Kept as a compatibility alias while feature files migrate to `dark`.
  static ThemeData get light => dark;
}
