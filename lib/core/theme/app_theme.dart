import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_tokens.dart';

/// JibHR colour tokens (option A, "Jade evolved").
///
/// The original names (canvas, ink, muted, jade, card, stroke, ...) are kept so
/// existing screens keep working; the semantic tokens below them are new.
/// Contrast pairs are checked in test/theme/palette_contrast_test.dart.
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
    required this.onJade,
    required this.pine,
    required this.onPine,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.surface,
    required this.surfaceRaised,
    required this.glass,
    required this.glassDeep,
    required this.glassBorder,
    required this.outline,
    required this.scrim,
  });

  /// L0: the page background.
  final Color canvas;

  /// Primary text.
  final Color ink;

  /// Secondary text. Meets 4.5:1 on canvas and surfaces.
  final Color muted;

  /// Primary brand colour: actions, selection, focus.
  final Color jade;

  /// L1 card fill: opaque enough for dense text.
  final Color card;

  /// Card and divider edge.
  final Color stroke;
  final Color warning;
  final Color danger;
  final Color info;
  final Color revision;
  final Color alert;

  /// A dense surface: translucent over the page, opaque enough for times and names.
  final Color panel;
  final Color hairline;

  /// Text and icons on [jade].
  final Color onJade;

  /// Secondary brand colour (the dark pine of the brand mark).
  final Color pine;
  final Color onPine;

  /// Brand gold. For brand moments only (today marker, highlight), never a status.
  final Color accent;
  final Color onAccent;
  final Color success;

  /// L1 opaque surface.
  final Color surface;

  /// L1 surface one step above [surface] (kanban column, table header).
  final Color surfaceRaised;

  /// L2 soft glass: header, bottom bar, hero cards.
  final Color glass;

  /// L3 deep glass: sidebar, side panels, dialogs, sheets.
  final Color glassDeep;

  /// The light edge of a glass surface.
  final Color glassBorder;

  /// Input and control boundary. Meets 3:1 against [surface].
  final Color outline;

  /// Behind dialogs and sheets.
  final Color scrim;

  static const light = AppPalette(
    canvas: Color(0xFFEEF3F0),
    ink: Color(0xFF14241C),
    muted: Color(0xFF4F625A),
    jade: Color(0xFF0B6B51),
    card: Color(0xF0FFFFFF),
    stroke: Color(0x1F14241C),
    warning: Color(0xFF8A5300),
    danger: Color(0xFFB42318),
    info: Color(0xFF1F5F99),
    revision: Color(0xFF6B4BA3),
    alert: Color(0xFFA8440C),
    panel: Color(0xEBFFFFFF),
    hairline: Color(0x1A14241C),
    onJade: Color(0xFFFFFFFF),
    pine: Color(0xFF12382C),
    onPine: Color(0xFFFFFFFF),
    accent: Color(0xFFE2B84E),
    onAccent: Color(0xFF2A1E00),
    success: Color(0xFF1E6B3E),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF6F9F7),
    glass: Color(0xC7FFFFFF),
    glassDeep: Color(0xB8FFFFFF),
    glassBorder: Color(0x99FFFFFF),
    outline: Color(0xFF75867E),
    scrim: Color(0x5214241C),
  );

  static const dark = AppPalette(
    canvas: Color(0xFF0B1310),
    ink: Color(0xFFE7F3EC),
    muted: Color(0xFFA8BDB3),
    jade: Color(0xFF3DDC97),
    card: Color(0xF0141E19),
    stroke: Color(0x24E7F3EC),
    warning: Color(0xFFF2C46B),
    danger: Color(0xFFFF9A92),
    info: Color(0xFF8CC4FF),
    revision: Color(0xFFC3A9F5),
    alert: Color(0xFFFFB27A),
    panel: Color(0xEB141E19),
    hairline: Color(0x1FE7F3EC),
    onJade: Color(0xFF06231A),
    pine: Color(0xFF9CC9B5),
    onPine: Color(0xFF0B1310),
    accent: Color(0xFFE7C56A),
    onAccent: Color(0xFF2A1E00),
    success: Color(0xFF6FD8A0),
    surface: Color(0xFF141E19),
    surfaceRaised: Color(0xFF1A2620),
    glass: Color(0xC716201B),
    glassDeep: Color(0xB8121A16),
    glassBorder: Color(0x1FE7F3EC),
    outline: Color(0xFF65786F),
    scrim: Color(0x99000000),
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
    Color? onJade,
    Color? pine,
    Color? onPine,
    Color? accent,
    Color? onAccent,
    Color? success,
    Color? surface,
    Color? surfaceRaised,
    Color? glass,
    Color? glassDeep,
    Color? glassBorder,
    Color? outline,
    Color? scrim,
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
      onJade: onJade ?? this.onJade,
      pine: pine ?? this.pine,
      onPine: onPine ?? this.onPine,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      glass: glass ?? this.glass,
      glassDeep: glassDeep ?? this.glassDeep,
      glassBorder: glassBorder ?? this.glassBorder,
      outline: outline ?? this.outline,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      canvas: mix(canvas, other.canvas),
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      jade: mix(jade, other.jade),
      card: mix(card, other.card),
      stroke: mix(stroke, other.stroke),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      info: mix(info, other.info),
      revision: mix(revision, other.revision),
      alert: mix(alert, other.alert),
      panel: mix(panel, other.panel),
      hairline: mix(hairline, other.hairline),
      onJade: mix(onJade, other.onJade),
      pine: mix(pine, other.pine),
      onPine: mix(onPine, other.onPine),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      success: mix(success, other.success),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      glass: mix(glass, other.glass),
      glassDeep: mix(glassDeep, other.glassDeep),
      glassBorder: mix(glassBorder, other.glassBorder),
      outline: mix(outline, other.outline),
      scrim: mix(scrim, other.scrim),
    );
  }
}

/// Persian type scale on Vazirmatn.
///
/// Body and label styles keep the font's own line metrics (about 1.6 for
/// Vazirmatn, already comfortable for Persian). An explicit height there is
/// inherited by every Text in the app and overflows tight cells such as the
/// attendance calendar; only headings set one.
TextTheme _textTheme(TextTheme base, Color ink, Color muted) {
  TextStyle? s(TextStyle? style, double size, FontWeight weight, {double? height, Color? color}) =>
      style?.copyWith(fontSize: size, fontWeight: weight, height: height, color: color ?? ink, letterSpacing: 0);
  return base.copyWith(
    displaySmall: s(base.displaySmall, 28, FontWeight.w700, height: 1.35),
    headlineMedium: s(base.headlineMedium, 24, FontWeight.w700, height: 1.4),
    headlineSmall: s(base.headlineSmall, 22, FontWeight.w700, height: 1.4),
    titleLarge: s(base.titleLarge, 18, FontWeight.w600),
    titleMedium: s(base.titleMedium, 16, FontWeight.w600),
    titleSmall: s(base.titleSmall, 14, FontWeight.w600),
    bodyLarge: s(base.bodyLarge, 15, FontWeight.w400),
    bodyMedium: s(base.bodyMedium, 14, FontWeight.w400),
    bodySmall: s(base.bodySmall, 12, FontWeight.w400, color: muted),
    labelLarge: s(base.labelLarge, 14, FontWeight.w500),
    labelMedium: s(base.labelMedium, 13, FontWeight.w500),
    labelSmall: s(base.labelSmall, 12, FontWeight.w500),
  );
}

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  final seeded = ColorScheme.fromSeed(seedColor: p.jade, brightness: brightness);
  final scheme = seeded.copyWith(
    primary: p.jade,
    onPrimary: p.onJade,
    primaryContainer: Color.alphaBlend(p.jade.withValues(alpha: 0.14), p.surface),
    onPrimaryContainer: p.ink,
    secondary: p.pine,
    onSecondary: p.onPine,
    secondaryContainer: Color.alphaBlend(p.jade.withValues(alpha: 0.10), p.surface),
    onSecondaryContainer: p.ink,
    tertiary: p.accent,
    onTertiary: p.onAccent,
    error: p.danger,
    onError: brightness == Brightness.dark ? const Color(0xFF3A0D0A) : Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surfaceRaised,
    surfaceContainer: p.surfaceRaised,
    surfaceContainerHigh: p.surfaceRaised,
    surfaceContainerHighest: Color.alphaBlend(p.ink.withValues(alpha: 0.06), p.surface),
    outline: p.outline,
    outlineVariant: Color.alphaBlend(p.stroke, p.surface),
    scrim: p.scrim,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    fontFamily: 'Vazirmatn',
    extensions: [p],
    visualDensity: VisualDensity.standard,
  );
  final text = _textTheme(base.textTheme.apply(fontFamily: 'Vazirmatn'), p.ink, p.muted);
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control));
  const minButton = Size(64, 44);
  return base.copyWith(
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.ink, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.jade,
        foregroundColor: p.onJade,
        minimumSize: minButton,
        shape: controlShape,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: minButton,
        shape: controlShape,
        side: BorderSide(color: p.outline),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.jade,
        minimumSize: const Size(48, 44),
        shape: controlShape,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.ink, minimumSize: const Size(44, 44)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: p.ink,
        foregroundColor: p.muted,
        side: BorderSide(color: Color.alphaBlend(p.stroke, p.surface)),
        minimumSize: const Size(0, 40),
        textStyle: text.labelMedium,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      isDense: false,
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.muted),
      contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control), borderSide: BorderSide(color: p.outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control), borderSide: BorderSide(color: p.outline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control), borderSide: BorderSide(color: p.jade, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control), borderSide: BorderSide(color: p.danger)),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card), side: BorderSide(color: p.stroke)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      barrierColor: p.scrim,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.panel)),
      titleTextStyle: text.titleLarge,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: p.scrim,
      showDragHandle: true,
      dragHandleColor: p.outline,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.panel))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control), side: BorderSide(color: p.stroke)),
      textStyle: text.bodyMedium,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control))),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(AppRadius.chip)),
      textStyle: text.labelMedium?.copyWith(color: p.canvas),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.canvas),
      actionTextColor: brightness == Brightness.dark ? AppPalette.light.jade : AppPalette.dark.jade,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      selectedColor: scheme.primaryContainer,
      side: BorderSide(color: Color.alphaBlend(p.stroke, p.surface)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
      labelStyle: text.labelMedium,
      checkmarkColor: p.jade,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      textColor: p.ink,
      selectedColor: p.ink,
      selectedTileColor: scheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onJade : p.outline),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.jade : p.surfaceRaised),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.jade : p.outline),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.jade : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.onJade),
      side: BorderSide(color: p.outline, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.jade,
      linearTrackColor: Color.alphaBlend(p.jade.withValues(alpha: 0.14), p.surface),
      circularTrackColor: Colors.transparent,
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: text.labelMedium?.copyWith(color: p.muted, fontWeight: FontWeight.w600),
      dataTextStyle: text.bodyMedium,
      dividerThickness: 1,
    ),
    badgeTheme: BadgeThemeData(backgroundColor: p.danger, textColor: brightness == Brightness.dark ? const Color(0xFF3A0D0A) : Colors.white),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelSmall?.copyWith(fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: p.jade,
      headerForegroundColor: p.onJade,
    ),
    timePickerTheme: TimePickerThemeData(backgroundColor: p.surface),
    scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(p.outline.withValues(alpha: 0.6))),
    focusColor: p.jade.withValues(alpha: 0.14),
    hoverColor: p.ink.withValues(alpha: 0.05),
    highlightColor: p.ink.withValues(alpha: 0.06),
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
