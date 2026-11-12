import 'package:flutter/material.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../dashboard/dashboard_rules.dart';
import '../work_rules.dart';
import '../workflow_presentation.dart';

/// Visual language shared by every work view: one colour, icon and Persian
/// name per workflow category, priority and due state. Colour never carries
/// meaning alone; every badge also has an icon and a word.

String categoryLabel(String category) => switch (category) {
  'backlog' => Fa.catBacklog,
  'todo' => Fa.catTodo,
  'in_progress' => Fa.catInProgress,
  'in_review' => Fa.catInReview,
  'approved' => Fa.catApproved,
  'done' => Fa.catDone,
  'blocked' => Fa.catBlocked,
  'changes_requested' => Fa.catChangesRequested,
  'rejected' => Fa.catRejected,
  _ => category,
};

/// Status colour token, by workflow category. Independent of
/// [priorityTone]: a status is drawn as an edge indicator and an outlined
/// badge, a priority as a filled badge, so the two never read as one.
///   neutral: backlog, todo · progress: info · review: jade
///   done/approved: success · blocked: alert · changes: revision
///   rejected: danger
Color statusTone(AppPalette p, String category) => switch (category) {
  'backlog' || 'todo' => p.muted,
  // Five distinct status colours: queue grey, in progress violet, review
  // jade, approved green, rejected red (outlined pill and column accent).
  'in_progress' => p.revision,
  'in_review' => p.jade,
  'approved' || 'done' => p.success,
  'blocked' => p.alert,
  'changes_requested' => p.revision,
  'rejected' => p.danger,
  _ => p.muted,
};

/// Kept for existing callers: the status token.
Color categoryTone(AppPalette p, String category) => statusTone(p, category);

AppIcon categoryIcon(String category) => switch (category) {
  'backlog' => AppIcons.archive,
  'todo' => AppIcons.checklist,
  'in_progress' => AppIcons.due,
  'in_review' => AppIcons.reviewer,
  'approved' || 'done' => AppIcons.approve,
  'blocked' => AppIcons.restricted,
  'changes_requested' => AppIcons.revise,
  'rejected' => AppIcons.reject,
  _ => AppIcons.checklist,
};

/// Priority colour identity, independent of the workflow status:
///   critical: soft red · high: amber · medium: blue · low: soft green.
/// A priority is always drawn as a filled chip with the flag icon and as the
/// tint and side rail of its card; a status is always an outlined pill with
/// its category icon and the column it sits in. The two never share a form.
Color priorityTone(AppPalette p, String priority) => switch (priority) {
  'critical' => p.danger,
  'high' => p.warning,
  'low' => p.success,
  _ => p.info,
};

/// The surfaces of one priority level, for light and dark themes. Tints stay
/// low so dense text keeps its contrast; critical is the strongest, so it is
/// recognisable at a glance without dominating the board.
class PriorityStyle {
  const PriorityStyle({required this.tone, required this.fill, required this.edge, required this.rail, required this.chip});

  /// Icon and label colour (meets 4.5:1 on [chip]).
  final Color tone;

  /// Card background.
  final Color fill;

  /// Card border.
  final Color edge;

  /// The start-side accent rail of a card or row.
  final Color rail;

  /// Background of the priority chip.
  final Color chip;

  static PriorityStyle of(BuildContext context, String priority) {
    final p = paletteOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tone = priorityTone(p, priority);
    final (fill, edge, rail) = switch (priority) {
      'critical' => (dark ? 0.11 : 0.065, dark ? 0.42 : 0.34, 1.0),
      'high' => (dark ? 0.08 : 0.06, dark ? 0.30 : 0.28, 0.9),
      'low' => (dark ? 0.05 : 0.035, dark ? 0.20 : 0.18, 0.6),
      _ => (dark ? 0.06 : 0.04, dark ? 0.24 : 0.20, 0.75),
    };
    return PriorityStyle(
      tone: tone,
      fill: Color.alphaBlend(tone.withValues(alpha: fill), p.surface),
      edge: Color.alphaBlend(tone.withValues(alpha: edge), p.surface),
      rail: tone.withValues(alpha: rail),
      chip: Color.alphaBlend(tone.withValues(alpha: dark ? 0.20 : 0.13), p.surface),
    );
  }
}

/// The quiet, short empty line of a board column, per workflow category.
String columnEmptyText(String category) => switch (category) {
  'backlog' || 'todo' => Fa.emptyQueue,
  'in_progress' => Fa.emptyInProgress,
  'in_review' => Fa.emptyInReview,
  'approved' || 'done' => Fa.emptyDone,
  'blocked' => Fa.emptyBlocked,
  'changes_requested' => Fa.emptyChanges,
  'rejected' => Fa.emptyRejected,
  _ => Fa.columnEmpty,
};

/// First word of a person's name, for dense rows ("کارمند آزمون" → "کارمند").
String shortName(String name) {
  final trimmed = name.trim();
  // A name the viewer may not see reads as the role, never a dash or an id.
  if (trimmed.isEmpty) return Fa.projectMemberFallback;
  return trimmed.split(RegExp(r'\s+')).first;
}

/// A slim progress bar with its own track, for checklist and subtask progress.
class SlimProgress extends StatelessWidget {
  const SlimProgress({super.key, required this.done, required this.total, this.height = 4});

  final int done;
  final int total;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final value = total <= 0 ? 0.0 : done / total;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: value >= 1 ? p.success : p.jade,
        backgroundColor: Color.alphaBlend(p.ink.withValues(alpha: 0.08), p.surface),
      ),
    );
  }
}

/// A small icon in a soft square: column headers and section heads.
class ToneIcon extends StatelessWidget {
  const ToneIcon({super.key, required this.icon, required this.tone, this.size = 28});

  final AppIcon icon;
  final Color tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Color.alphaBlend(tone.withValues(alpha: 0.13), p.surface), borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: AppIconView(icon, size: size * 0.57, color: tone),
    );
  }
}

/// The blocked mark: a flag on the task, never a change of status colour.
class BlockedBadge extends StatelessWidget {
  const BlockedBadge({super.key, this.dense = true});

  final bool dense;

  @override
  Widget build(BuildContext context) => WorkBadge(key: const Key('mark-blocked'), label: Fa.catBlocked, tone: paletteOf(context).alert, icon: AppIcons.restricted, dense: dense);
}

AppIcon actionIcon(TaskAction action) => switch (action) {
  TaskAction.start => AppIcons.clockIn,
  TaskAction.submit => AppIcons.reviewer,
  TaskAction.complete => AppIcons.approve,
  TaskAction.returnToCycle => AppIcons.restore,
  TaskAction.block => AppIcons.restricted,
};

/// The final-rejection mark inside the rejected group.
class FinalRejectedBadge extends StatelessWidget {
  const FinalRejectedBadge({super.key, this.dense = true});

  final bool dense;

  @override
  Widget build(BuildContext context) => WorkBadge(key: const Key('mark-final-rejected'), label: Fa.finalRejectedBadge, tone: paletteOf(context).danger, icon: AppIcons.reject, dense: dense);
}

/// The mark that tells the two kinds of the rejected group apart; nothing
/// for other tasks.
Widget? rejectedMark(String category, {bool dense = true}) {
  if (isBlockedCategory(category)) return BlockedBadge(dense: dense);
  if (category == 'rejected') return FinalRejectedBadge(dense: dense);
  return null;
}

/// Small tinted pill: icon + word. Used for status, priority, approval.
class WorkBadge extends StatelessWidget {
  const WorkBadge({super.key, required this.label, required this.tone, this.icon, this.dense = false});

  final String label;
  final Color tone;
  final AppIcon? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(dense ? 6 : AppSpace.s, 2, dense ? AppSpace.s : AppSpace.m - 2, 2),
      decoration: BoxDecoration(color: Color.alphaBlend(tone.withValues(alpha: 0.13), p.surface), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[AppIconView(icon!, size: dense ? 12 : 14, color: tone), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class PriorityBadge extends StatelessWidget {
  const PriorityBadge({super.key, required this.priority, this.dense = false});

  final String priority;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = PriorityStyle.of(context, priority);
    final strong = priority == 'critical' || priority == 'high';
    // One form for every level: a filled chip, flag icon and the word. The
    // colour is never the only signal.
    return Semantics(
      label: '${Fa.priority}: ${priorityLabel(priority)}',
      excludeSemantics: true,
      child: Container(
        key: ValueKey('priority-badge-$priority'),
        padding: EdgeInsetsDirectional.fromSTEB(dense ? 6 : AppSpace.s, dense ? 1 : 2, dense ? AppSpace.s : AppSpace.m - 2, dense ? 1 : 2),
        decoration: BoxDecoration(color: style.chip, borderRadius: BorderRadius.circular(AppRadius.chip - 2)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.priority, selected: strong, size: dense ? 13 : 15, color: style.tone),
            const SizedBox(width: 4),
            Text(
              priorityLabel(priority),
              style: text.labelSmall?.copyWith(color: style.tone, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status as an outlined pill: tone edge, tone icon, ink word.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.name, required this.category, this.dense = false, this.suffix});

  final String name;
  final String category;
  final bool dense;

  /// Extra text after the name, e.g. the version "v2".
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // Always one of the four final statuses, whatever the stored category or
    // name (see workflow_presentation.dart): never «انجام‌نشده» or «نیاز به اصلاح».
    final group = groupOfCategory(this.category);
    final category = groupCategory(group);
    final tone = statusTone(p, category);
    final label = groupLabel(group);
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(dense ? 6 : AppSpace.s, 1, dense ? AppSpace.s : AppSpace.m - 2, 1),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.08), p.surface),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconView(categoryIcon(category), size: dense ? 12 : 14, color: tone),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              suffix == null ? label : '$label · $suffix',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Version of the n-th submission for review: "v1", "v2", ... A badge
/// beside the title; the stored title never changes.
String versionLabel(int submission) => 'v$submission';

class VersionBadge extends StatelessWidget {
  const VersionBadge({super.key, required this.submission});

  final int submission;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Semantics(
      label: '${Fa.versionWord} ${persianDigits(submission)}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.chip - 2),
          border: Border.all(color: p.outline.withValues(alpha: 0.6)),
        ),
        child: Text(
          versionLabel(submission),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.ink, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}

/// Due date as a relative word with urgency: overdue, today, soon or later.
/// Completed tasks never show as overdue.
class DueBadge extends StatelessWidget {
  const DueBadge({super.key, required this.due, required this.now, this.complete = false});

  final DateTime due;
  final DateTime now;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final days = daysUntil(due, now);
    final tone = complete
        ? p.muted
        : days < 0
        ? p.danger
        : days == 0
        ? p.warning
        : p.muted;
    final label = relativeDue(due, now);
    return Semantics(
      label: '${Fa.dueDate}: $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconView(days < 0 && !complete ? AppIcons.warning : AppIcons.due, size: 14, color: tone),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone == p.muted ? p.ink : tone, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// A person's initial in a tinted circle. The name is the semantics label.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.size = 24});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final initial = name.trim().isEmpty ? '؟' : name.trim().characters.first;
    final hue = (name.hashCode % 360).abs().toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.35, Theme.of(context).brightness == Brightness.dark ? 0.32 : 0.86).toColor();
    return Tooltip(
      message: name,
      excludeFromSemantics: true,
      child: Semantics(
        label: name,
        excludeSemantics: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: tint,
            shape: BoxShape.circle,
            border: Border.all(color: p.surface, width: 1.5),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: TextStyle(fontSize: size * 0.46, fontWeight: FontWeight.w700, color: p.ink, height: 1),
          ),
        ),
      ),
    );
  }
}

/// Short date for dense places: "۱۷ آبان".
String shortJalali(DateTime instant) {
  final j = TehranTime.jalali(instant);
  return persianDigits('${j.day} ${j.formatter.mN}');
}
