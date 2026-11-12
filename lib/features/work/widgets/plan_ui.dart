import 'package:flutter/material.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../plan_repository.dart';
import '../work_rules.dart';
import 'work_ui.dart';

Color sprintTone(AppPalette p, String status) => switch (status) {
  'active' => p.jade,
  'closed' => p.muted,
  'cancelled' => p.danger,
  _ => p.info,
};

Color milestoneTone(AppPalette p, String status) => switch (status) {
  'in_progress' => p.jade,
  'reached' => p.success,
  'cancelled' => p.danger,
  _ => p.warning,
};

/// Page header for plan pages: back, eyebrow, title and actions.
class PlanHeader extends StatelessWidget {
  const PlanHeader({super.key, required this.title, required this.onBack, this.eyebrow, this.actions = const [], this.badge});

  final String title;
  final String? eyebrow;
  final VoidCallback onBack;
  final List<Widget> actions;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final gutter = compact ? AppSpace.l : AppSpace.xxl;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(gutter - AppSpace.s, AppSpace.l, gutter, AppSpace.s),
      child: Row(
        children: [
          IconButton(
            tooltip: Fa.back,
            onPressed: onBack,
            icon: const AppIconView(AppIcons.back, semanticLabel: Fa.back),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (eyebrow != null)
                  Text(
                    eyebrow!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(color: p.muted),
                  ),
                Row(
                  children: [
                    Flexible(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (compact ? text.titleLarge : text.headlineSmall)?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    if (badge != null) ...[const SizedBox(width: AppSpace.s), badge!],
                  ],
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class PlanProgressBar extends StatelessWidget {
  const PlanProgressBar({super.key, required this.label, required this.complete, required this.total});

  final String label;
  final int complete;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final percent = progressPercent(complete, total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: text.labelMedium?.copyWith(color: p.muted)),
            ),
            Text('${persianDigits(percent)}٪', style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(value: total <= 0 ? 0 : complete / total, minHeight: 8, backgroundColor: p.hairline, color: p.jade),
        ),
      ],
    );
  }
}

/// Counts as small tiles: total, complete, remaining, blocked, pending.
class PlanStats extends StatelessWidget {
  const PlanStats({super.key, required this.counts});

  final PlanCounts counts;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final items = [
      (Fa.totalTasks, counts.total, p.ink),
      (Fa.completedTasks, counts.complete, p.success),
      (Fa.remainingTasks, counts.remaining, p.info),
      (Fa.blockedTasks, counts.blocked, p.danger),
      (Fa.pendingTasks, counts.pending, p.warning),
    ];
    return Wrap(
      spacing: AppSpace.s,
      runSpacing: AppSpace.s,
      children: [
        for (final item in items)
          Container(
            constraints: const BoxConstraints(minWidth: 96),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.m, vertical: AppSpace.s),
            decoration: BoxDecoration(
              color: p.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  persianDigits(item.$2),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: item.$2 == 0 ? p.muted : item.$3),
                ),
                Text(item.$1, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.muted)),
              ],
            ),
          ),
      ],
    );
  }
}

/// A titled solid card for plan pages.
class PlanCard extends StatelessWidget {
  const PlanCard({super.key, required this.child, this.title, this.icon, this.trailing});

  final Widget child;
  final String? title;
  final AppIcon? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.l),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: p.stroke),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null) ...[
                Row(
                  children: [
                    if (icon != null) ...[AppIconView(icon!, size: 18, color: p.muted), const SizedBox(width: AppSpace.s)],
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(title!, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: AppSpace.m),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A task inside a sprint or milestone; extra actions live in a menu.
class PlanTaskTile extends StatelessWidget {
  const PlanTaskTile({super.key, required this.task, required this.onOpen, this.actions = const []});

  final PlanTaskRow task;
  final VoidCallback onOpen;
  final List<({String label, AppIcon icon, VoidCallback? onTap, bool danger})> actions;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.s, AppSpace.s, 0, AppSpace.s),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.hairline)),
          ),
          child: Row(
            children: [
              AppIconView(categoryIcon(task.statusCategory), size: 18, color: categoryTone(p, task.statusCategory)),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: task.complete ? p.muted : p.ink, decoration: task.complete ? TextDecoration.lineThrough : null),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: AppSpace.s,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusBadge(name: task.statusName, category: task.statusCategory, dense: true),
                        PriorityBadge(priority: task.priority, dense: true),
                      ],
                    ),
                  ],
                ),
              ),
              PersonAvatar(name: task.assigneeName, size: 26),
              if (actions.isNotEmpty)
                PopupMenuButton<VoidCallback?>(
                  tooltip: Fa.taskActions,
                  icon: AppIconView(AppIcons.moreActions, size: 18, color: p.muted, semanticLabel: Fa.taskActions),
                  onSelected: (action) => action?.call(),
                  itemBuilder: (context) => [
                    for (final a in actions)
                      PopupMenuItem(
                        value: a.onTap,
                        enabled: a.onTap != null,
                        child: Row(
                          children: [
                            AppIconView(a.icon, size: 18, color: a.danger ? p.danger : p.ink),
                            const SizedBox(width: AppSpace.s),
                            Text(a.label, style: TextStyle(color: a.danger ? p.danger : null)),
                          ],
                        ),
                      ),
                  ],
                )
              else
                const SizedBox(width: AppSpace.s),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plan date range for cards: "۱ آبان – ۱۴ آبان".
String planRange(String start, String end) => '${formatPlanDate(start)} – ${formatPlanDate(end)}';

/// A plan-page form opened as a dialog (full screen on phones).
Future<T?> showPlanDialog<T>(BuildContext context, {required String title, required Widget Function(BuildContext) body, required List<Widget> Function(BuildContext) actions}) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  Widget content(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, AppSpace.l, AppSpace.s, AppSpace.s),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: Fa.close,
                onPressed: () => Navigator.pop(context),
                icon: const AppIconView(AppIcons.close, semanticLabel: Fa.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.l), child: body(context)),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.m, AppSpace.xl, AppSpace.l),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: paletteOf(context).hairline)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions(context)),
        ),
      ],
    ),
  );
  return showDialog<T>(
    context: context,
    builder: (context) => compact
        ? Dialog.fullscreen(child: content(context))
        : Dialog(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: content(context)),
          ),
  );
}

/// The stored Gregorian ISO day as an editable Jalali day.
JalaliDay jalaliOfIso(String iso) {
  final parts = iso.split('-');
  final date = parts.length < 3 ? DateTime.now().toUtc() : DateTime.utc(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]), 12);
  final j = TehranTime.jalali(date);
  return (year: j.year, month: j.month, day: j.day);
}

typedef JalaliDay = ({int year, int month, int day});
