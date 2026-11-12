import 'package:flutter/material.dart';

import '../localization/fa.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'app_icons.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        liveRegion: true,
        label: Fa.loading,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: AppSpace.m),
            ExcludeSemantics(child: Text(Fa.loading)),
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, this.message = Fa.empty});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.empty, size: 28, color: p.muted),
            const SizedBox(height: AppSpace.s),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.offline, size: 28, color: p.danger),
            const SizedBox(height: AppSpace.s),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[const SizedBox(height: AppSpace.m), TextButton.icon(onPressed: onRetry, icon: const AppIconView(AppIcons.retry), label: const Text(Fa.retry))],
          ],
        ),
      ),
    );
  }
}

/// A block-shaped placeholder that keeps the space a section will fill, so the
/// page does not jump when data arrives.
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, this.height = 16, this.width, this.radius = AppRadius.chip});

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(radius)),
    );
  }
}

/// An error that stays inside its own card instead of replacing the page.
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          AppIconView(AppIcons.offline, color: p.danger),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Text(message, style: TextStyle(color: p.ink)),
          ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const AppIconView(AppIcons.retry, size: AppIconSize.inline),
              label: const Text(Fa.retry),
            ),
        ],
      ),
    );
  }
}

/// A one-line notice above content: stale data, offline, environment.
class NoticeBar extends StatelessWidget {
  const NoticeBar({super.key, required this.message, required this.tone, this.icon = AppIcons.info, this.subtle = false});

  final String message;
  final Color tone;
  final AppIcon icon;

  /// A quiet line without a coloured band, for information that is not a
  /// warning (the environment name).
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (subtle) {
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.l, AppSpace.xs, AppSpace.l, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AppIconView(icon, size: 14, color: p.muted),
            const SizedBox(width: AppSpace.xs),
            Text(message, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpace.l, vertical: AppSpace.s),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.12), p.surface),
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          AppIconView(icon, size: AppIconSize.inline, color: tone),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.ink)),
          ),
        ],
      ),
    );
  }
}
