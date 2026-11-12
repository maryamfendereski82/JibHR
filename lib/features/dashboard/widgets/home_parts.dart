import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/state_views.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';

/// What one Home section knows about its data.
///
/// Sections that read the same RPC get the same [SectionData]; when that RPC
/// fails they all show their own inline error, but they fail together.
class SectionData<T> {
  const SectionData({this.value, this.loading = false, this.error, this.stale = false});

  final T? value;
  final bool loading;
  final Object? error;

  /// A cached value is shown because the refresh failed.
  final bool stale;

  bool get hasValue => value != null;
}

/// Persian digits in equal widths (Vazirmatn has `tnum` for U+06F0..06F9).
const tabular = [FontFeature.tabularFigures()];

class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({super.key, required this.title, this.subtitle, this.trailing, this.icon});

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final AppIcon? icon;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          AppIconView(icon!, color: p.jade, size: AppIconSize.control),
          const SizedBox(width: AppSpace.s),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              if (subtitle != null) Text(subtitle!, style: text.bodySmall),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A labelled number. Label, value and unit each have their own weight, so
/// the figure reads without colour.
class Kpi extends StatelessWidget {
  const Kpi({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.emphasis = false,
    this.tone,
    this.icon,
  });

  final String label;
  final String value;

  /// Unit or short explanation under the value.
  final String? unit;

  /// Larger value for the one or two figures a section is about.
  final bool emphasis;
  final Color? tone;
  final AppIcon? icon;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: unit == null ? '$label: $value' : '$label: $value $unit',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                AppIconView(icon!, size: AppIconSize.inline, color: tone ?? p.muted),
                const SizedBox(width: AppSpace.xs),
              ],
              Flexible(
                child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.labelMedium?.copyWith(color: p.muted)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            style: (emphasis ? text.headlineMedium : text.titleLarge)?.copyWith(
              fontWeight: FontWeight.w700,
              color: tone ?? p.ink,
              height: 1.25,
            ),
          ),
          if (unit != null)
            Text(unit!, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
        ],
      ),
    );
  }
}

/// Icon + word + tint. Colour is never the only signal.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone, this.icon});

  final String label;
  final Color tone;
  final AppIcon? icon;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.s, 3, AppSpace.m, 3),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.14), p.surface),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[AppIconView(icon!, size: 14, color: tone), const SizedBox(width: AppSpace.xs)],
          Flexible(
            child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Loading, error, stale and data for one section, without leaving the card.
class SectionStates<T> extends StatelessWidget {
  const SectionStates({
    super.key,
    required this.data,
    required this.skeleton,
    required this.builder,
    this.onRetry,
    this.errorText = Fa.network,
  });

  final SectionData<T> data;
  final Widget skeleton;
  final Widget Function(T value) builder;
  final VoidCallback? onRetry;
  final String errorText;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final value = data.value;
    final Widget body;
    if (value != null) {
      body = Column(
        key: const ValueKey('data'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.stale) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: StatusPill(label: Fa.staleDashboard, tone: p.warning, icon: AppIcons.warning),
            ),
            const SizedBox(height: AppSpace.s),
          ],
          builder(value),
        ],
      );
    } else if (data.error != null && !data.loading) {
      body = Padding(
        key: const ValueKey('error'),
        padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
        child: InlineError(message: errorText, onRetry: onRetry),
      );
    } else {
      body = KeyedSubtree(key: const ValueKey('loading'), child: Semantics(label: Fa.loading, child: skeleton));
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.state),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      ),
      child: body,
    );
  }
}

/// Skeleton rows that keep roughly the size of the content they stand for.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.rows = 3, this.height = 44});

  final int rows;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < rows; i++) ...[
          if (i > 0) const SizedBox(height: AppSpace.s),
          SkeletonBlock(height: height, radius: AppRadius.control),
        ],
      ],
    );
  }
}

/// Fades and lifts a section in once, staggered by [order]. Nothing moves
/// when the platform asks for reduced motion.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.panel);
  Timer? _start;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.value > 0 || _start != null) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _controller.value = 1;
      return;
    }
    _start = Timer(Duration(milliseconds: 40 * widget.order), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _controller, curve: AppMotion.enter);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}
