import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/theme/app_theme.dart';

double _channel(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) => 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// WCAG contrast of [fg] over [bg]. Translucent colours are first composited
/// over [under] (the page canvas), which is what the eye actually sees.
double contrast(Color fg, Color bg, {Color? under}) {
  final base = under ?? const Color(0xFFFFFFFF);
  final b = Color.alphaBlend(bg, base);
  final f = Color.alphaBlend(fg, b);
  final l1 = _luminance(f);
  final l2 = _luminance(b);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in {'light': AppPalette.light, 'dark': AppPalette.dark}.entries) {
    final p = entry.value;
    group('${entry.key} palette', () {
      final text = <String, (Color, Color)>{
        'ink on canvas': (p.ink, p.canvas),
        'ink on surface': (p.ink, p.surface),
        'muted on canvas': (p.muted, p.canvas),
        'muted on surface': (p.muted, p.surface),
        'muted on raised': (p.muted, p.surfaceRaised),
        'onJade on jade (primary button)': (p.onJade, p.jade),
        'jade text on surface': (p.jade, p.surface),
        'jade text on canvas': (p.jade, p.canvas),
        'onPine on pine': (p.onPine, p.pine),
        'onAccent on accent': (p.onAccent, p.accent),
        'success on surface': (p.success, p.surface),
        'warning on surface': (p.warning, p.surface),
        'danger on surface': (p.danger, p.surface),
        'info on surface': (p.info, p.surface),
        'revision on surface': (p.revision, p.surface),
        'alert on surface': (p.alert, p.surface),
        'tooltip text': (p.canvas, p.ink),
      };
      for (final pair in text.entries) {
        test('${pair.key} meets 4.5:1', () {
          expect(contrast(pair.value.$1, pair.value.$2), greaterThanOrEqualTo(4.5));
        });
      }

      // Translucent surfaces are measured over the canvas they sit on.
      for (final layer in {'card': p.card, 'panel': p.panel, 'glass': p.glass, 'glassDeep': p.glassDeep}.entries) {
        test('ink and muted on ${layer.key} over canvas meet 4.5:1', () {
          final composite = Color.alphaBlend(layer.value, p.canvas);
          expect(contrast(p.ink, composite), greaterThanOrEqualTo(4.5));
          expect(contrast(p.muted, composite), greaterThanOrEqualTo(4.5));
        });
      }

      test('control outline meets 3:1 on surface', () {
        expect(contrast(p.outline, p.surface), greaterThanOrEqualTo(3));
      });

      test('focus ring (jade) meets 3:1 on surface and canvas', () {
        expect(contrast(p.jade, p.surface), greaterThanOrEqualTo(3));
        expect(contrast(p.jade, p.canvas), greaterThanOrEqualTo(3));
      });
    });
  }

  test('theme builds for both brightnesses and uses the palette primary', () {
    for (final b in Brightness.values) {
      final theme = buildAppTheme(b);
      final p = theme.extension<AppPalette>()!;
      expect(theme.colorScheme.primary, p.jade);
      expect(theme.colorScheme.onPrimary, p.onJade);
      expect(theme.colorScheme.surface, p.surface);
    }
  });
}
