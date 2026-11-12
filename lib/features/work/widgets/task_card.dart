import 'package:flutter/material.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../work_repository.dart';
import '../work_rules.dart';
import '../workflow_presentation.dart';
import 'work_ui.dart';

/// Statuses the workflow allows this task to move to, in board order.
List<StatusRow> allowedTargets(TaskRow task, WorkflowRow? flow) {
  if (flow == null) return const [];
  return [
    for (final status in flow.statuses)
      if (status.active && status.id != task.statusId && flow.transitions.any((edge) => edge.from == task.statusId && edge.to == status.id)) status,
  ];
}

/// Where a task stands in the review cycle, for its card. Null when the
/// task needs no approval and was never sent. "Awaiting decision" only
/// appears after the task was really sent (it is in a review status);
/// a task that only needs approval shows the policy, not a queue state.
({String label, Color Function(AppPalette) tone, AppIcon icon})? reviewState(TaskRow task) {
  final version = task.submissions > 0 ? ' · ${versionLabel(task.submissions)}' : '';
  if (task.statusCategory == 'in_review' && task.approvalRequired && task.approvalState == 'pending') {
    return (label: '${Fa.inReviewBadge}$version', tone: (p) => p.jade, icon: AppIcons.reviewer);
  }
  // "Needs revision" is a reviewer decision, not a state: the task is simply
  // back in the queue (the decision lives in "versions and reviews"). A final
  // rejection is the rejected group's own mark ([rejectedMark]).
  if (task.approvalRequired && task.approvalState != 'approved' && (groupOf(task) == TaskGroup.backlog || groupOf(task) == TaskGroup.inProgress)) {
    return (label: Fa.needsApprovalBadge, tone: (p) => p.muted, icon: AppIcons.approvalPolicy);
  }
  return null;
}

/// A task in a board column or a list. Solid surface: it carries dense text.
///
/// The card's own colour is its PRIORITY (tint, side rail, chip); its status
/// is the column it stands in, or an outlined status pill where there is no
/// column ([showStatus]). Only what a reader needs at a glance: priority,
/// title, review state, blocked mark, checklist progress, assignee and due.
class TaskCard extends StatefulWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.now,
    required this.onOpen,
    this.actions = const [],
    this.onAction,
    this.showStatus = false,
    this.showProject = false,
    this.selected = false,
  });

  final TaskRow task;
  final DateTime now;
  final VoidCallback onOpen;

  /// What the person may do with this task now (submit, complete, return to
  /// the cycle, block); the card menu lists them. Never a raw status list.
  final List<TaskAction> actions;
  final ValueChanged<TaskAction>? onAction;

  /// Off inside a status column, where the column already names the status.
  final bool showStatus;
  final bool showProject;
  final bool selected;

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final task = widget.task;
    final complete = taskCountsComplete(category: task.statusCategory, approvalRequired: task.approvalRequired, approvalState: task.approvalState);
    final checklistTotal = task.checklist.length;
    final review = reviewState(task);
    final blocked = isBlockedTask(task);
    final mark = rejectedMark(task.statusCategory);
    final style = PriorityStyle.of(context, task.priority);
    final border = widget.selected ? p.jade : (_hover ? Color.alphaBlend(style.tone.withValues(alpha: 0.45), p.surface) : style.edge);

    final meta = <Widget>[
      if (widget.showStatus) StatusBadge(name: task.statusName, category: task.statusCategory, dense: true),
      if (widget.showProject) WorkBadge(label: task.projectName ?? Fa.personalTasks, tone: p.pine, icon: task.projectId == null ? AppIcons.person : AppIcons.projects, dense: true),
    ];

    return Semantics(
      container: true,
      label: '${task.title}، ${Fa.priority} ${priorityLabel(task.priority)}${blocked ? '، ${Fa.catBlocked}' : ''}',
      child: AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.state),
        decoration: BoxDecoration(
          color: style.fill,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: border, width: widget.selected ? 1.5 : 1),
          boxShadow: _hover ? AppElevation.e2(p.ink) : AppElevation.e1(p.ink),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Priority rail, on the reading start side.
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: task.priority == 'critical' ? 4 : 3,
              child: ColoredBox(key: ValueKey('priority-rail-${task.id}'), color: style.rail),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('card-${task.id}'),
                borderRadius: BorderRadius.circular(AppRadius.control),
                onTap: widget.onOpen,
                onHover: (value) => setState(() => _hover = value),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m + 2, AppSpace.s, AppSpace.xs, AppSpace.m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. Priority, review state, blocked; version and actions at the end.
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: AppSpace.xs,
                              runSpacing: AppSpace.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                PriorityBadge(priority: task.priority, dense: true),
                                ?mark,
                                if (review != null) WorkBadge(key: ValueKey('review-${task.id}'), label: review.label, tone: review.tone(p), icon: review.icon, dense: true),
                              ],
                            ),
                          ),
                          if (task.submissions > 0 && review == null) ...[const SizedBox(width: AppSpace.xs), VersionBadge(submission: task.submissions)],
                          _menu(context),
                        ],
                      ),
                      const SizedBox(height: AppSpace.xs + 2),
                      // 2. Title: the most important line, at most two lines.
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: AppSpace.s),
                        child: Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                            decoration: complete ? TextDecoration.lineThrough : null,
                            color: complete ? p.muted : p.ink,
                          ),
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.s),
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: AppSpace.s),
                          child: Wrap(spacing: AppSpace.xs, runSpacing: AppSpace.xs, children: meta),
                        ),
                      ],
                      // 3. Checklist progress, only when there is a checklist.
                      if (checklistTotal > 0) ...[
                        const SizedBox(height: AppSpace.s + 2),
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: AppSpace.s),
                          child: Semantics(
                            label: '${Fa.checklistProgress}: ${persianDigits(task.checklistDone)} از ${persianDigits(checklistTotal)}',
                            excludeSemantics: true,
                            child: Row(
                              children: [
                                AppIconView(AppIcons.checklist, size: 14, color: task.checklistDone == checklistTotal ? p.success : p.muted),
                                const SizedBox(width: AppSpace.xs),
                                Expanded(child: SlimProgress(done: task.checklistDone, total: checklistTotal)),
                                const SizedBox(width: AppSpace.s),
                                Text(
                                  '${persianDigits(task.checklistDone)}/${persianDigits(checklistTotal)}',
                                  style: text.labelSmall?.copyWith(color: p.ink, fontFeatures: const [FontFeature.tabularFigures()]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpace.m),
                      // 4. Who and when.
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: AppSpace.s),
                        child: Row(
                          children: [
                            PersonAvatar(name: task.assigneeName, size: 22),
                            const SizedBox(width: AppSpace.xs + 2),
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      shortName(task.assigneeName),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.labelMedium?.copyWith(color: p.ink),
                                    ),
                                  ),
                                  if (task.collaborators.isNotEmpty) ...[
                                    const SizedBox(width: AppSpace.xs),
                                    Semantics(
                                      label: '${persianDigits(task.collaborators.length)} ${Fa.collaboratorsCount}',
                                      excludeSemantics: true,
                                      child: Text('+${persianDigits(task.collaborators.length)}', style: text.labelSmall?.copyWith(color: p.muted)),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (task.dueAt != null) ...[const SizedBox(width: AppSpace.s), Flexible(child: DueBadge(due: task.dueAt!, now: widget.now, complete: complete))],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final p = paletteOf(context);
    return SizedBox(
      width: 36,
      height: 32,
      child: PopupMenuButton<Object>(
        key: ValueKey('card-menu-${widget.task.id}'),
        tooltip: Fa.taskActions,
        padding: EdgeInsets.zero,
        icon: AppIconView(AppIcons.moreActions, size: 18, color: p.muted, semanticLabel: Fa.taskActions),
        onSelected: (value) {
          if (value is TaskAction) widget.onAction?.call(value);
          if (value == 'open') widget.onOpen();
        },
        itemBuilder: (context) => [
          PopupMenuItem<Object>(
            value: 'open',
            child: Row(
              children: [
                const AppIconView(AppIcons.open, size: 18),
                const SizedBox(width: AppSpace.s),
                Text(Fa.open),
              ],
            ),
          ),
          if (widget.actions.isNotEmpty && widget.onAction != null) ...[
            const PopupMenuDivider(),
            for (final action in widget.actions)
              PopupMenuItem<Object>(
                key: ValueKey('action-${widget.task.id}-${action.name}'),
                value: action,
                child: Row(
                  children: [
                    AppIconView(actionIcon(action), size: 18, color: action == TaskAction.block ? p.alert : p.ink),
                    const SizedBox(width: AppSpace.s),
                    Flexible(child: Text(actionLabel(action))),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
