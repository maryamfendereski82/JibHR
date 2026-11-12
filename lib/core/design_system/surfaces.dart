import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// Material tiers of the JibHR visual language.
///
/// * [solid] L1: tables, forms, task cards, kanban columns. No blur.
/// * [raised] L1 one step up: column headers, nested blocks. No blur.
/// * [glass] L2: header, bottom bar, home hero cards. Light blur.
/// * [deep] L3: sidebar, side panels, sheets. Stronger blur.
enum SurfaceLevel { solid, raised, glass, deep }

/// Build with `--dart-define=JIBHR_NO_BLUR=true` to render every glass surface
/// opaque. Used to profile the cost of blur against a no-blur baseline.
const bool kBlurDisabledByBuild = bool.fromEnvironment('JIBHR_NO_BLUR');

class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.level = SurfaceLevel.solid,
    this.padding = const EdgeInsets.all(AppSpace.l),
    this.radius = AppRadius.card,
    this.borderRadius,
    this.shadow = true,
    this.border = true,
  });

  final Widget child;
  final SurfaceLevel level;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Overrides [radius] when only some corners are rounded.
  final BorderRadiusGeometry? borderRadius;
  final bool shadow;
  final bool border;

  static bool blurAllowed(BuildContext context) {
    if (kBlurDisabledByBuild) return false;
    return !MediaQuery.highContrastOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final shape = borderRadius ?? BorderRadius.circular(radius);
    final blur = switch (level) {
      SurfaceLevel.glass => 12.0,
      SurfaceLevel.deep => 22.0,
      _ => 0.0,
    };
    final useBlur = blur > 0 && blurAllowed(context);
    final fill = switch (level) {
      SurfaceLevel.solid => p.card,
      SurfaceLevel.raised => p.surfaceRaised,
      SurfaceLevel.glass => useBlur ? p.glass : p.panel,
      SurfaceLevel.deep => useBlur ? p.glassDeep : p.panel,
    };
    final edge = switch (level) {
      SurfaceLevel.glass || SurfaceLevel.deep => p.glassBorder,
      _ => p.stroke,
    };
    final shadows = !shadow
        ? null
        : switch (level) {
            SurfaceLevel.solid || SurfaceLevel.raised => AppElevation.e1(p.ink),
            SurfaceLevel.glass => AppElevation.e2(p.ink),
            SurfaceLevel.deep => AppElevation.e3(p.ink),
          };
    final glassy = level == SurfaceLevel.glass || level == SurfaceLevel.deep;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Glass: a faint light sheen from the top corner and a 1px inner highlight
    // along the top edge, so the surface reads as a pane, not a white box.
    final sheen = Color.alphaBlend((dark ? Colors.white : Colors.white).withValues(alpha: dark ? 0.06 : 0.35), fill);
    Widget decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: glassy ? null : fill,
        gradient: glassy
            ? LinearGradient(
                begin: AlignmentDirectional.topStart.resolve(Directionality.of(context)),
                end: AlignmentDirectional.bottomEnd.resolve(Directionality.of(context)),
                colors: [sheen, fill],
                stops: const [0, 0.55],
              )
            : null,
        borderRadius: shape,
        border: border ? Border.all(color: edge) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (glassy && border) {
      final r = shape.resolve(Directionality.of(context));
      final inset = r.topLeft.x.clamp(0, 40).toDouble();
      decorated = Stack(
        children: [
          decorated,
          Positioned(
            top: 1,
            left: inset,
            right: inset,
            height: 1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: dark ? 0.16 : 0.85),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final body = useBlur
        ? ClipRRect(
            borderRadius: shape,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: decorated,
            ),
          )
        : decorated;
    final framed = shadows == null
        ? body
        : DecoratedBox(
            decoration: BoxDecoration(borderRadius: shape, boxShadow: shadows),
            child: body,
          );
    return useBlur ? RepaintBoundary(child: framed) : framed;
  }
}

/// L0: the canvas behind every page. A base wash plus three wide, very soft
/// colour fields (jade, info, a trace of brand gold) that give the glass
/// something to sit over. Static: it never animates or repaints with content.
class AppCanvas extends StatelessWidget {
  const AppCanvas({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget field(Color color, double alpha, AlignmentGeometry at, double radius) => Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: at.resolve(Directionality.of(context)),
            radius: radius,
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.topEnd.resolve(Directionality.of(context)),
                          end: AlignmentDirectional.bottomStart.resolve(Directionality.of(context)),
                          colors: [Color.alphaBlend(p.jade.withValues(alpha: 0.05), p.canvas), p.canvas],
                        ),
                      ),
                    ),
                  ),
                  field(p.jade, dark ? 0.16 : 0.20, const AlignmentDirectional(0.7, -0.9), 0.9),
                  field(p.info, dark ? 0.10 : 0.12, const AlignmentDirectional(-0.9, 0.6), 0.85),
                  field(p.accent, dark ? 0.05 : 0.10, const AlignmentDirectional(-0.2, -0.8), 0.55),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
