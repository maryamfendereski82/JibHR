import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'surfaces.dart';

/// The original card API, now drawn by [AppSurface].
///
/// Without [blur] it is an L1 solid card. With [blur] it is an L2 glass card.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(AppSpace.xl), this.blur = false});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    return AppSurface(level: blur ? SurfaceLevel.glass : SurfaceLevel.solid, padding: padding, radius: AppRadius.panel, child: child);
  }
}
