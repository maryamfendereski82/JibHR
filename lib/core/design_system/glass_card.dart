import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.blur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final decoration = BoxDecoration(
      color: palette.card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: palette.stroke),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    );
    final body = Padding(padding: padding, child: child);
    if (!blur) {
      return DecoratedBox(decoration: decoration, child: body);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(decoration: decoration, child: body),
      ),
    );
  }
}
