import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.canvas,
    required this.ink,
    required this.muted,
    required this.jade,
    required this.card,
    required this.stroke,
    required this.warning,
    required this.danger,
    required this.info,
    required this.revision,
    required this.alert,
    required this.panel,
    required this.hairline,
  });

  final Color canvas;
  final Color ink;
  final Color muted;
  final Color jade;
  final Color card;
  final Color stroke;
  final Color warning;
  final Color danger;
  final Color info;
  final Color revision;
  final Color alert;

  /// A dense surface: translucent over the page, opaque enough for times and names.
  final Color panel;
  final Color hairline;

  static const light = AppPalette(
    canvas: Color(0xFFE6EEE9),
    ink: Color(0xFF14241C),
    muted: Color(0xFF5C6F66),
    jade: Color(0xFF0C7A5C),
    card: Color(0xB8FFFFFF),
    stroke: Color(0x66FFFFFF),
    warning: Color(0xFF8A5A12),
    danger: Color(0xFF8E2F2F),
    info: Color(0xFF1F5F99),
    revision: Color(0xFF6B4BA3),
    alert: Color(0xFFA8440C),
    panel: Color(0xE6FFFFFF),
    hairline: Color(0x1A14241C),
  );

  static const dark = AppPalette(
    canvas: Color(0xFF0C1411),
    ink: Color(0xFFE7F3EC),
    muted: Color(0xFFA8BDB3),
    jade: Color(0xFF3DDC97),
    card: Color(0x141E2A24),
    stroke: Color(0x22FFFFFF),
    warning: Color(0xFFE7C56A),
    danger: Color(0xFFFF8E8E),
    info: Color(0xFF8CC4FF),
    revision: Color(0xFFC3A9F5),
    alert: Color(0xFFFFB27A),
    panel: Color(0xD9162019),
    hairline: Color(0x1FE7F3EC),
  );

  @override
  AppPalette copyWith({
    Color? canvas,
    Color? ink,
    Color? muted,
    Color? jade,
    Color? card,
    Color? stroke,
    Color? warning,
    Color? danger,
    Color? info,
    Color? revision,
    Color? alert,
    Color? panel,
    Color? hairline,
  }) {
    return AppPalette(
      canvas: canvas ?? this.canvas,
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
      jade: jade ?? this.jade,
      card: card ?? this.card,
      stroke: stroke ?? this.stroke,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      revision: revision ?? this.revision,
      alert: alert ?? this.alert,
      panel: panel ?? this.panel,
      hairline: hairline ?? this.hairline,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      jade: Color.lerp(jade, other.jade, t)!,
      card: Color.lerp(card, other.card, t)!,
      stroke: Color.lerp(stroke, other.stroke, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      revision: Color.lerp(revision, other.revision, t)!,
      alert: Color.lerp(alert, other.alert, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
    );
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final palette = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.jade,
    brightness: brightness,
    surface: palette.canvas,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.canvas,
    fontFamily: 'Vazirmatn',
    extensions: [palette],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'Vazirmatn',
      bodyColor: palette.ink,
      displayColor: palette.ink,
    ),
    splashFactory: InkSparkle.splashFactory,
  );
}

final themeModeProvider = NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);

class ThemeController extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    state = ThemeMode.values.firstWhere((mode) => mode.name == raw, orElse: () => ThemeMode.system);
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}

AppPalette paletteOf(BuildContext context) {
  return Theme.of(context).extension<AppPalette>() ?? AppPalette.light;
}
