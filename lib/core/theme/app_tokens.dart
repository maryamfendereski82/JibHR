import 'package:flutter/material.dart';

/// 4-point spacing scale.
abstract final class AppSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const x3 = 32.0;
  static const x4 = 40.0;

  /// Page gutter for a given content width.
  static double gutter(double width) => width < 600 ? l : (width < 1024 ? xxl : x3);
}

abstract final class AppRadius {
  static const chip = 8.0;
  static const control = 12.0;
  static const card = 16.0;
  static const panel = 20.0;
  static const pill = 28.0;
}

/// Motion tokens. Exit runs at about 70 percent of enter.
abstract final class AppMotion {
  static const press = Duration(milliseconds: 100);
  static const state = Duration(milliseconds: 200);
  static const panel = Duration(milliseconds: 280);
  static const panelExit = Duration(milliseconds: 200);
  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;

  /// Zero when the platform asks for reduced motion.
  static Duration of(BuildContext context, Duration value) {
    return MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : value;
  }
}

/// Size classes, measured on the width actually available to the content.
enum SizeClass { compact, medium, expanded, large }

abstract final class AppBreakpoints {
  static const medium = 600.0;
  static const expanded = 1024.0;
  static const large = 1280.0;

  static SizeClass of(double width) {
    if (width < medium) return SizeClass.compact;
    if (width < expanded) return SizeClass.medium;
    if (width < large) return SizeClass.expanded;
    return SizeClass.large;
  }
}

/// Ambient shadows. Tinted with the ink colour, never pure black.
abstract final class AppElevation {
  static List<BoxShadow> e1(Color ink) => [
        BoxShadow(color: ink.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
      ];

  static List<BoxShadow> e2(Color ink) => [
        BoxShadow(color: ink.withValues(alpha: 0.06), blurRadius: 24, offset: const Offset(0, 8)),
      ];

  static List<BoxShadow> e3(Color ink) => [
        BoxShadow(color: ink.withValues(alpha: 0.08), blurRadius: 40, offset: const Offset(0, 16)),
      ];
}
