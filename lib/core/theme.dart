import 'package:flutter/material.dart';

import 'settings.dart';

const font = 'Jost';

ThemeData buildTheme(Brightness b, Color accent, {bool black = false}) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
    primary: dark ? accent : Color.lerp(accent, Colors.black, 0.25),
    surface: dark ? (black ? Colors.black : const Color(0xFF14151A)) : const Color(0xFFF7F6F3),
    surfaceContainerLowest: dark ? (black ? Colors.black : const Color(0xFF101115)) : Colors.white,
    surfaceContainerLow: dark
        ? (black ? const Color(0xFF0B0B0D) : const Color(0xFF1A1B21))
        : const Color(0xFFF0EFEB),
    surfaceContainer: dark
        ? (black ? const Color(0xFF121214) : const Color(0xFF202128))
        : const Color(0xFFE9E7E2),
    surfaceContainerHigh: dark
        ? (black ? const Color(0xFF1A1A1D) : const Color(0xFF292A32))
        : const Color(0xFFE1DFD9),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: font);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(fontFamily: font),
    sliderTheme: SliderThemeData(
      trackHeight: 6,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.14),
      thumbColor: scheme.primary,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
    ),
    listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
    dividerTheme: DividerThemeData(color: scheme.onSurface.withValues(alpha: 0.08), space: 1),
  );
}

/// Corners for covers in the chosen shape.
BorderRadius artRadius(ArtShape shape, double size) => switch (shape) {
  ArtShape.square => BorderRadius.circular(size * 0.02),
  ArtShape.rounded => BorderRadius.circular(size * 0.1),
  ArtShape.circle => BorderRadius.circular(size / 2),
};

/// Animation length, or none when animations are off.
Duration motion(Settings s, int ms) => s.animations ? Duration(milliseconds: ms) : Duration.zero;
