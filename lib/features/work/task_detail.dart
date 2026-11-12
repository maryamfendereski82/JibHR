import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_select.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'milestone_pages.dart';
import 'project_pages.dart';
import 'sprint_pages.dart';
import 'task_board.dart';
import 'task_actions.dart';
import 'task_form.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';
import 'workflow_presentation.dart';

final taskProvider = FutureProvider.family<TaskRow?, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return WorkRepository(client).task(id);
});

/// The editable stamp of a stored due date, in Tehran wall time.
JalaliStamp stampOf(DateTime dueUtc) {
  final day = TehranTime.jalali(dueUtc.toUtc());
  final wall = TehranTime.wallClock(dueUtc.toUtc());
  return JalaliStamp(year: day.year, month: day.month, day: day.day, hour: wall.hour, minute: wall.minute);
}

/// The due date to send with `update_task`. `update_task` writes every
/// field, so an untouched due date must be sent back exactly as stored:
/// [original] when the picked day is the stored day, the picked stamp when
/// it changed, null when cleared.
DateTime? dueToSend({required DateTime? original, required bool withDue, required JalaliStamp due}) {
  if (!withDue) return null;
  if (original != null) {
    final stored = stampOf(original);
    if (stored.year == due.year && stored.month == due.month && stored.day == due.day) return original.toUtc();
  }
  return due.toUtc();
}

/// Client mirror of who `update_task` and `transition_task` accept: the
/// assignee, `tasks.manage.project`, or an approver of the assignee's team
/// (approval permissions are the client-side signal). The server decides;
/// this only keeps fields read-only for people the server would refuse.
bool canEditTask(WorkspaceSession? session, TaskRow task) {
  if (session == null) return false;
  if (task.assigneeId == session.profileId) return true;
  if (session.can('tasks.manage.project') || session.can('tasks.view.all')) return true;
  return session.can('attendance.approve.team') || session.can('attendance.approve.all') || session.can('leave.approve.team') || session.can('leave.approve.all');
}

/// Client mirror of `decide_task` eligibility: the named reviewer; without
/// one, a project manager or reviewer member (project tasks) or an approver
/// of the assignee's team (personal tasks). Admin-wide access is left to
/// the server. A button never grants anything: the RPC re-checks.
bool canDecideTask(WorkspaceSession? session, TaskRow task, ProjectRow? project) {
  if (session == null || !task.approvalRequired) return false;
  if (task.reviewerId != null) return task.reviewerId == session.profileId || session.can('tasks.view.all');
  if (task.projectId != null) {
    return session.can('tasks.view.all') || (project?.members.any((m) => m.profileId == session.profileId && (m.role == 'manager' || m.role == 'reviewer')) ?? false);
  }
  return session.can('tasks.view.all') || session.can('attendance.approve.team') || session.can('attendance.approve.all') || session.can('leave.approve.team') || session.can('leave.approve.all');
}

/// A submission is waiting for a decision: the newest review round has no
/// decision yet. Decisions are offered only then (never for a task that was
/// only marked "approval required" and not sent).
bool awaitingDecision(TaskRow task) => task.approvalRequired && task.approvalState == 'pending' && task.rounds.isNotEmpty && task.rounds.first.decision == null;

/// A revision request is stored in the existing review `reason` as two
/// labelled parts; [parseRevision] reads them back (older free-text reasons
/// come back whole as the "what").
String composeRevision({required String what, required String why}) => '${Fa.revisionWhatPrefix} ${what.trim()}\n${Fa.revisionWhyPrefix} ${why.trim()}';

({String what, String? why}) parseRevision(String reason) {
  final text = reason.trim();
  final whatAt = text.indexOf(Fa.revisionWhatPrefix);
  final whyAt = text.indexOf(Fa.revisionWhyPrefix);
  if (whatAt == 0 && whyAt > 0) {
    return (what: text.substring(Fa.revisionWhatPrefix.length, whyAt).trim(), why: text.substring(whyAt + Fa.revisionWhyPrefix.length).trim());
  }
  return (what: text, why: null);
}

class TaskDetailPage extends ConsumerStatefulWidget {
  const TaskDetailPage({super.key, required this.taskId, this.embedded = false, this.onClose});

  final String taskId;
  final bool embedded;
  final VoidCallback? onClose;

  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage> {
  final title = TextEditingController();
  final description = TextEditingController();
  final checklistTitle = TextEditingController();
  final subtaskTitle = TextEditingController();
  String? loadedFor;
  bool busy = false;

  /// View-first: fields become editable only after "edit".
  bool editing = false;
  bool approval = false;
  bool requiredSubtask = false;
  bool withDue = false;
  String priority = 'medium';
  NamedPerson? assignee;
  NamedPerson? reviewer;
  JalaliStamp due = JalaliStamp.today();

  @override
  void didUpdateWidget(TaskDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) {
      loadedFor = null;
      editing = false;
    }
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    checklistTitle.dispose();
    subtaskTitle.dispose();
    super.dispose();
  }

  /// Seeds the form from the stored row, the due date included.
  void _seed(TaskRow row) {
    loadedFor = '${row.id}@${row.updatedAt.toIso8601String()}';
    title.text = row.title;
    description.text = row.description;
    approval = row.approvalRequired;
    priority = row.priority;
    assignee = row.assigneeId == null ? null : NamedPerson(id: row.assigneeId!, name: row.assigneeName);
    reviewer = row.reviewerId == null ? null : NamedPerson(id: row.reviewerId!, name: row.reviewerName ?? Fa.reviewer);
    withDue = row.dueAt != null;
    due = row.dueAt == null ? JalaliStamp.today() : stampOf(row.dueAt!);
  }

  bool _dirty(TaskRow row) {
    final nextDue = dueToSend(original: row.dueAt, withDue: withDue, due: due);
    return title.text.trim() != row.title.trim() ||
        description.text != row.description ||
        priority != row.priority ||
        assignee?.id != row.assigneeId ||
        reviewer?.id != row.reviewerId ||
        approval != row.approvalRequired ||
        nextDue?.toUtc() != row.dueAt?.toUtc();
  }

  Future<bool> _confirmLeave() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Fa.unsavedTitle),
        content: const Text(Fa.unsavedBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text(Fa.discard)),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fa.keepEditing)),
        ],
      ),
    );
    return answer == true;
  }

  Future<void> _leave(TaskRow? row, VoidCallback go) async {
    if (row != null && _dirty(row) && !await _confirmLeave()) return;
    if (mounted) go();
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(taskProvider(widget.taskId));
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    return task.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskProvider(widget.taskId))),
      data: (row) {
        if (row == null) return const EmptyView();
        if (loadedFor == null || !loadedFor!.startsWith(row.id)) _seed(row);
        return _view(context, row, session);
      },
    );
  }

  Widget _view(BuildContext context, TaskRow row, WorkspaceSession? session) {
    final personalFlow = ref.watch(personalWorkflowProvider);
    final project = row.projectId == null ? null : ref.watch(projectProvider(row.projectId!)).asData?.value;
    final flow = row.projectId == null ? personalFlow.asData?.value : project?.workflow;
    final dirty = _dirty(row);
    final editable = canEditTask(session, row);
    // Labels and collaborators of a project task have their own server rules,
    // so edit mode opens for them too; fields the person may not change stay
    // read-only inside it, exactly as before.
    final canEnterEdit = editable || row.projectId != null;
    final back = row.parentId != null
        ? '/work/t/${row.parentId}'
        : row.projectId == null
        ? '/work/personal'
        : '/work/p/${row.projectId}';

    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) context.go(back);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = !widget.embedded && constraints.maxWidth >= 960;
          final compact = constraints.maxWidth < 600;
          final gutter = compact ? AppSpace.l : (widget.embedded ? AppSpace.xl : AppSpace.xxl);
          final summary = editing ? _properties(context, row, session, project) : _overview(context, row, session, project);
          final main = _mainColumn(context, row, session, flow, editable);
          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: main),
                    const SizedBox(width: AppSpace.xxl),
                    SizedBox(width: 340, child: summary),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: AppSpace.xl),
                    main,
                  ],
                );
          final head = _header(context, row, flow, project, session, back, gutter: gutter, compact: compact, canEnterEdit: canEnterEdit);
          final banner = _approvalBanner(context, row, session, project, gutter);
          final content = Padding(
            padding: EdgeInsets.fromLTRB(gutter, AppSpace.l, gutter, AppSpace.xxl),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1120), child: body),
            ),
          );
          // Wider screens keep the head fixed above an independent scroll; on a
          // phone it scrolls away so the content gets the screen.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact) ...[head, banner],
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('task-detail'),
                  child: compact
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, banner, content])
                      : content,
                ),
              ),
              AnimatedSwitcher(duration: AppMotion.of(context, AppMotion.state), child: dirty ? _saveBar(context, row, compact) : const SizedBox.shrink()),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- header

  /// The fixed head of the task: where it lives, the title (the strongest
  /// element), its status, priority and version, and the edit action.
  Widget _header(BuildContext context, TaskRow row, WorkflowRow? flow, ProjectRow? project, WorkspaceSession? session, String back, {required double gutter, required bool compact, required bool canEnterEdit}) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final crumb = row.projectId == null ? Fa.personalTasks : (project?.name ?? row.projectName ?? Fa.projects);
    final titleStyle = (compact || widget.embedded ? text.titleLarge : text.headlineSmall)?.copyWith(fontWeight: FontWeight.w800, height: 1.45);
    return Container(
      key: const Key('detail-header'),
      padding: EdgeInsetsDirectional.fromSTEB(gutter - AppSpace.s - 4, AppSpace.s, gutter - AppSpace.xs, AppSpace.m),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.embedded)
                IconButton(
                  key: const Key('detail-close'),
                  tooltip: Fa.close,
                  onPressed: () => _leave(row, () => widget.onClose?.call()),
                  icon: const AppIconView(AppIcons.close, semanticLabel: Fa.close),
                )
              else
                IconButton(
                  key: const Key('detail-back'),
                  tooltip: Fa.back,
                  onPressed: () => _leave(row, () => context.go(back)),
                  icon: const AppIconView(AppIcons.back, semanticLabel: Fa.back),
                ),
              const SizedBox(width: AppSpace.xs),
              AppIconView(row.projectId == null ? AppIcons.person : AppIcons.projects, size: 15, color: p.muted),
              const SizedBox(width: AppSpace.xs + 2),
              Expanded(
                child: Text(
                  row.parentId == null ? crumb : '$crumb · ${Fa.parentTask}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(color: p.muted),
                ),
              ),
              if (canEnterEdit && !editing)
                OutlinedButton.icon(
                  key: const Key('detail-edit'),
                  onPressed: busy ? null : () => setState(() => editing = true),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: AppSpace.m), side: BorderSide(color: p.stroke)),
                  icon: const AppIconView(AppIcons.edit, size: 16),
                  label: const Text(Fa.edit),
                ),
              if (editing)
                TextButton(
                  key: const Key('detail-cancel-edit'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          _seed(row);
                          editing = false;
                        }),
                  child: const Text(Fa.cancelEdit),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: AppSpace.s + 4, top: AppSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (editing)
                  TextField(
                    key: const Key('detail-title'),
                    controller: title,
                    readOnly: !canEditTask(ref.read(workspaceSessionProvider).asData?.value, row),
                    maxLines: null,
                    onChanged: (_) => setState(() {}),
                    style: titleStyle,
                    decoration: InputDecoration(
                      hintText: Fa.title,
                      errorText: title.text.trim().isEmpty ? Fa.titleRequired : null,
                      filled: true,
                      fillColor: p.surfaceRaised,
                      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.m, vertical: AppSpace.s),
                    ),
                  )
                else
                  Semantics(
                    header: true,
                    child: Text(row.title, key: const Key('detail-title-text'), style: titleStyle),
                  ),
                const SizedBox(height: AppSpace.s + 2),
                Wrap(
                  spacing: AppSpace.s,
                  runSpacing: AppSpace.xs + 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // One of the four final statuses; a rejected task also
                    // shows which kind (blocked or final rejection).
                    StatusBadge(key: const Key('detail-status'), name: row.statusName, category: row.statusCategory),
                    ?rejectedMark(row.statusCategory, dense: false),
                    PriorityBadge(priority: row.priority),
                    if (row.submissions > 0) VersionBadge(submission: row.submissions),
                  ],
                ),
                const SizedBox(height: AppSpace.s),
                Text(
                  '${Fa.createdBy} ${(row.creatorName ?? '').trim().isEmpty ? Fa.noValue : row.creatorName} · ${formatStamp(row.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
                ?_actionBar(context, row, flow, session, project),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The task's next step as ONE clear action instead of a status menu:
  /// submit for review or complete (queue), return to the cycle (rejected
  /// group), plus "block" as a quiet secondary action. Shown only to people
  /// the server would accept; the server re-checks every step.
  Widget? _actionBar(BuildContext context, TaskRow row, WorkflowRow? flow, WorkspaceSession? session, ProjectRow? project) {
    final p = paletteOf(context);
    final canAct = canEditTask(session, row);
    final available = taskActions(row, flow, canAct: canAct, session: session);
    final primary = primaryAction(row);
    final permitted = primary != null && actionPermitted(row, primary, canAct: canAct, session: session);
    final primaryReady = primary != null && available.contains(primary);
    // A permitted action the stored workflow cannot express yet (reopening a
    // final rejection before the workflow update) is shown disabled, with why.
    final unavailable = permitted && !primaryReady;
    final block = available.contains(TaskAction.block);
    // Who may do what, said plainly where the person cannot act themselves.
    final group = groupOf(row);
    final isAssignee = session != null && row.assigneeId == session.profileId;
    final blockedReturn = primaryReady && primary == TaskAction.returnToCycle && isBlockedTask(row) && groupOfCategory(actionPath(row, flow, primary)!.last.category) != TaskGroup.backlog;
    final hint = switch (group) {
      TaskGroup.backlog || TaskGroup.inProgress when !isAssignee => Fa.roleOnlyAssignee,
      TaskGroup.inReview when awaitingDecision(row) && !canDecideTask(session, row, project) => Fa.roleWaitReviewer,
      TaskGroup.rejected when isFinalRejected(row) && !canReopenRejected(session) => Fa.roleReopenManagers,
      _ when blockedReturn => Fa.returnLandsInProgress,
      _ => null,
    };
    if (!primaryReady && !unavailable && !block) {
      if (hint == null) return null;
      return Padding(
        padding: const EdgeInsets.only(top: AppSpace.s),
        child: Row(
          children: [
            AppIconView(AppIcons.info, size: 15, color: p.muted),
            const SizedBox(width: AppSpace.xs + 2),
            Expanded(child: Text(hint, key: const Key('role-hint'), style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.s,
            runSpacing: AppSpace.s,
            children: [
              if (primaryReady || unavailable)
                FilledButton.icon(
                  key: const Key('detail-primary-action'),
                  onPressed: busy || !primaryReady ? null : () => _act(row, flow, primary),
                  icon: AppIconView(actionIcon(primary), size: 18, color: primaryReady ? p.onJade : p.muted),
                  label: Text(actionLabel(primary)),
                ),
              if (block)
                OutlinedButton.icon(
                  key: const Key('detail-action-block'),
                  onPressed: busy ? null : () => _act(row, flow, TaskAction.block),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: p.stroke)),
                  icon: AppIconView(AppIcons.restricted, size: 18, color: p.alert),
                  label: const Text(Fa.actionBlock),
                ),
            ],
          ),
          if (hint != null && !unavailable)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(hint, key: const Key('role-hint'), style: Theme.of(context).textTheme.bodySmall),
            ),
          if (unavailable)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(isFinalRejected(row) ? Fa.returnNeedsMigration : Fa.actionUnavailable, key: const Key('action-unavailable'), style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Future<void> _act(TaskRow row, WorkflowRow? flow, TaskAction action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (await runTaskAction(context, ref, row, flow, action)) _invalidateAll();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _approvalBanner(BuildContext context, TaskRow row, WorkspaceSession? session, ProjectRow? project, double gutter) {
    // Only while a version waits for a decision. A revision request is not a
    // current state (the task is back in the queue; the decision is in
    // "versions and reviews"); rejection and approval show as the status.
    final waiting = awaitingDecision(row);
    if (!row.approvalRequired || !waiting) return const SizedBox.shrink();
    final mayDecide = waiting && canDecideTask(session, row, project);
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final (message, tone, icon) = switch (row.approvalState) {
      'pending' when waiting => ('${Fa.awaitingDecision} · ${versionLabel(row.submissions)}', p.jade, AppIcons.pending),
      _ => ('', p.muted, AppIcons.info),
    };
    if (message.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('approval-banner'),
      padding: EdgeInsetsDirectional.fromSTEB(gutter, AppSpace.m, gutter, AppSpace.m),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.08), p.surface),
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ToneIcon(icon: icon, tone: tone, size: 28),
              const SizedBox(width: AppSpace.s + 2),
              Expanded(
                child: Text(message, style: text.bodyMedium?.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (waiting && !mayDecide)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 38, top: AppSpace.xs),
              child: Text(Fa.waitingForReviewer, style: text.bodySmall),
            ),
          if (mayDecide)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 38, top: AppSpace.s),
              child: Wrap(
                spacing: AppSpace.s,
                runSpacing: AppSpace.s,
                children: [
                  FilledButton.icon(
                    key: const Key('decide-approve'),
                    onPressed: busy ? null : () => _decide(row, 'approved', false),
                    icon: AppIconView(AppIcons.approve, size: 18, color: p.onJade),
                    label: const Text(Fa.approve),
                  ),
                  OutlinedButton.icon(
                    key: const Key('decide-revise'),
                    onPressed: busy ? null : () => _requestChanges(row),
                    icon: const AppIconView(AppIcons.revise, size: 18),
                    label: const Text(Fa.requestRevision),
                  ),
                  TextButton.icon(
                    key: const Key('decide-reject'),
                    onPressed: busy ? null : () => _decide(row, 'rejected', true),
                    icon: AppIconView(AppIcons.reject, size: 18, color: p.danger),
                    label: Text(Fa.finalReject, style: TextStyle(color: p.danger)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _saveBar(BuildContext context, TaskRow row, bool compact) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Container(
      key: const Key('save-bar'),
      padding: EdgeInsets.fromLTRB(compact ? AppSpace.l : AppSpace.xxl, AppSpace.m, compact ? AppSpace.l : AppSpace.xxl, AppSpace.m),
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        border: Border(top: BorderSide(color: p.stroke)),
        boxShadow: AppElevation.e2(p.ink),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            AppIconView(AppIcons.edit, size: 18, color: p.warning),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Text(Fa.unsavedChanges, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            TextButton(key: const Key('discard-changes'), onPressed: busy ? null : () => setState(() => _seed(row)), child: const Text(Fa.discardChanges)),
            const SizedBox(width: AppSpace.s),
            FilledButton(
              key: const Key('save-task'),
              onPressed: busy || title.text.trim().isEmpty ? null : () => _save(row),
              child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade)) : const Text(Fa.save),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- overview

  /// View mode: the facts a reader scans first, compact and read-only.
  Widget _overview(BuildContext context, TaskRow row, WorkspaceSession? session, ProjectRow? project) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final self = session?.profileId;
    final memberById = {for (final m in project?.members ?? const <MemberRow>[]) m.profileId: m};
    String nameOf(String? id, String stored) {
      if (id != null) {
        final member = memberById[id];
        if (member != null) return memberDisplayName(member, session);
        if (id == self && session != null) return selfLabel(session);
      }
      return stored.trim().isEmpty ? Fa.projectMemberFallback : stored;
    }

    Widget person(String? id, String stored) {
      final name = nameOf(id, stored);
      return Row(
        children: [
          PersonAvatar(name: name, size: 22),
          const SizedBox(width: AppSpace.s),
          Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: p.ink))),
        ],
      );
    }

    Widget plain(String value) => Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: p.ink));
    final complete = taskCountsComplete(category: row.statusCategory, approvalRequired: row.approvalRequired, approvalState: row.approvalState);
    final dueStamp = row.dueAt == null ? null : stampOf(row.dueAt!);
    final items = <(AppIcon, String, Widget)>[
      (AppIcons.person, Fa.assignee, person(row.assigneeId, row.assigneeName)),
      (
        AppIcons.reviewer,
        Fa.reviewer,
        !row.approvalRequired
            ? plain(Fa.noValue)
            : row.reviewerId == null
            ? plain(Fa.reviewerPool)
            : person(row.reviewerId, row.reviewerName ?? ''),
      ),
      (
        AppIcons.due,
        Fa.dueDate,
        dueStamp == null
            ? plain(Fa.noValue)
            : Wrap(
                spacing: AppSpace.s,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${persianDigits(dueStamp.day)} ${jalaliMonths[dueStamp.month - 1]} ${persianDigits(dueStamp.year)}', style: text.bodyMedium?.copyWith(color: p.ink)),
                  DueBadge(due: row.dueAt!, now: DateTime.now().toUtc(), complete: complete),
                ],
              ),
      ),
      (AppIcons.priority, Fa.priority, Align(alignment: AlignmentDirectional.centerStart, child: PriorityBadge(priority: row.priority))),
      (AppIcons.approvalPolicy, Fa.approvalRequired, plain(row.approvalRequired ? Fa.approvalYes : Fa.approvalNo)),
      (
        AppIcons.restricted,
        Fa.catBlocked,
        isBlockedTask(row) ? const Align(alignment: AlignmentDirectional.centerStart, child: BlockedBadge(dense: false)) : plain(Fa.notBlocked),
      ),
      if (row.projectId != null) ...[
        (
          AppIcons.label,
          Fa.labels,
          row.labels.isEmpty
              ? plain(Fa.noValue)
              : Wrap(spacing: AppSpace.xs, runSpacing: AppSpace.xs, children: [for (final l in row.labels) WorkBadge(label: l.name, tone: p.muted, icon: AppIcons.label, dense: true)]),
        ),
        (
          AppIcons.people,
          Fa.collaborators,
          row.collaborators.isEmpty
              ? plain(Fa.noValue)
              : Wrap(
                  spacing: AppSpace.s,
                  runSpacing: AppSpace.xs,
                  children: [
                    for (final c in row.collaborators)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PersonAvatar(name: nameOf(c.id, c.name), size: 20),
                          const SizedBox(width: AppSpace.xs),
                          Text(shortName(nameOf(c.id, c.name)), style: text.labelMedium?.copyWith(color: p.ink)),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    ];
    return Container(
      key: const Key('task-overview'),
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.l, AppSpace.s),
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: p.stroke),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 340 ? 2 : 1;
          final cell = (constraints.maxWidth - (columns - 1) * AppSpace.l) / columns;
          return Wrap(
            spacing: AppSpace.l,
            children: [
              for (final item in items)
                SizedBox(
                  width: cell,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: AppIconView(item.$1, size: 16, color: p.muted),
                        ),
                        const SizedBox(width: AppSpace.s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.$2, style: text.labelSmall?.copyWith(color: p.muted)),
                              const SizedBox(height: 2),
                              item.$3,
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- main

  Widget _mainColumn(BuildContext context, TaskRow row, WorkspaceSession? session, WorkflowRow? flow, bool editable) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (editing && !editable)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.m),
            child: NoticeBar(key: const Key('read-only-notice'), message: Fa.readOnlyTask, tone: p.muted, icon: AppIcons.restricted, subtle: true),
          ),
        _Section(
          first: true,
          icon: AppIcons.description,
          title: Fa.description,
          child: editing
              ? TextField(
                  key: const Key('detail-description'),
                  controller: description,
                  readOnly: !editable,
                  minLines: 3,
                  maxLines: 12,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: Fa.description),
                )
              : row.description.trim().isEmpty
              ? const _SoftEmpty(key: Key('description-empty'), icon: AppIcons.description, message: Fa.noTaskDescription)
              : SelectableText(row.description.trim(), key: const Key('description-text'), style: text.bodyLarge?.copyWith(height: 1.85, color: p.ink)),
        ),
        _checklist(context, row),
        if (row.parentId == null) _subtasks(context, row, session),
        _history(context, row, flow),
      ],
    );
  }

  Widget _checklist(BuildContext context, TaskRow row) {
    final total = row.checklist.length;
    return _Section(
      icon: AppIcons.checklist,
      title: Fa.checklist,
      trailing: total == 0 ? null : _CountPill(label: Fa.doneOf(persianDigits(row.checklistDone), persianDigits(total)), complete: row.checklistDone == total),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: SlimProgress(done: row.checklistDone, total: total, height: 6),
            ),
          if (total == 0) const _SoftEmpty(icon: AppIcons.checklist, message: Fa.noChecklistItems),
          for (var i = 0; i < total; i++) _checkRow(context, row.checklist[i], first: i == 0, last: i == total - 1),
          const SizedBox(height: AppSpace.s),
          _InlineAdd(
            inputKey: const Key('checklist-input'),
            addKey: const Key('checklist-add'),
            controller: checklistTitle,
            hint: Fa.addChecklistHint,
            busy: busy,
            onChanged: () => setState(() {}),
            onAdd: () => _addChecklist(row),
          ),
        ],
      ),
    );
  }

  Widget _checkRow(BuildContext context, ChecklistRow item, {required bool first, required bool last}) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Container(
      key: ValueKey('check-${item.id}'),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: item.done,
            onChanged: busy ? null : (value) => _run(() => _repo.toggleChecklist(item.id, done: value == true)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
              child: Text(
                item.title,
                style: text.bodyMedium?.copyWith(decoration: item.done ? TextDecoration.lineThrough : null, decorationColor: p.muted, color: item.done ? p.muted : p.ink),
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: ValueKey('check-menu-${item.id}'),
            tooltip: Fa.itemActions,
            enabled: !busy,
            icon: AppIconView(AppIcons.moreActions, size: 18, color: p.muted, semanticLabel: Fa.itemActions),
            onSelected: (value) {
              switch (value) {
                case 'up':
                  _run(() => _repo.moveChecklist(item.id, -1));
                case 'down':
                  _run(() => _repo.moveChecklist(item.id, 1));
                case 'rename':
                  _rename(item);
                case 'delete':
                  _run(() => _repo.deleteChecklist(item.id));
              }
            },
            itemBuilder: (context) {
              PopupMenuItem<String> entry(String value, AppIcon icon, String label, {bool enabled = true, Color? color, Key? key}) => PopupMenuItem(
                key: key,
                value: value,
                enabled: enabled,
                child: Row(
                  children: [
                    AppIconView(icon, size: 18, color: color),
                    const SizedBox(width: AppSpace.s),
                    Text(label, style: color == null ? null : TextStyle(color: color)),
                  ],
                ),
              );
              return [
                entry('up', AppIcons.moveUp, Fa.moveUp, enabled: !first, key: ValueKey('up-${item.id}')),
                entry('down', AppIcons.moveDown, Fa.moveDown, enabled: !last, key: ValueKey('down-${item.id}')),
                entry('rename', AppIcons.edit, Fa.renameItem),
                const PopupMenuDivider(),
                entry('delete', AppIcons.delete, Fa.deleteItem, color: p.danger),
              ];
            },
          ),
        ],
      ),
    );
  }

  Widget _subtasks(BuildContext context, TaskRow row, WorkspaceSession? session) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();
    bool finished(TaskRow t) => taskCountsComplete(category: t.statusCategory, approvalRequired: t.approvalRequired, approvalState: t.approvalState);
    final done = row.subtasks.where(finished).length;
    final total = row.subtasks.length;
    return _Section(
      icon: AppIcons.subtask,
      title: Fa.subtasks,
      trailing: total == 0 ? null : _CountPill(label: Fa.doneOf(persianDigits(done), persianDigits(total)), complete: done == total),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: SlimProgress(done: done, total: total, height: 6),
            ),
          if (total == 0) const _SoftEmpty(icon: AppIcons.subtask, message: Fa.noSubtasksYet),
          for (final child in row.subtasks)
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('subtask-${child.id}'),
                borderRadius: BorderRadius.circular(AppRadius.chip),
                onTap: () => _leave(row, () => context.go('/work/t/${child.id}')),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.s + 2, horizontal: AppSpace.xs),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.hairline)),
                  ),
                  child: Row(
                    children: [
                      AppIconView(categoryIcon(child.statusCategory), size: 18, color: categoryTone(p, child.statusCategory)),
                      const SizedBox(width: AppSpace.s + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              child.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: finished(child) ? p.muted : p.ink,
                                decoration: finished(child) ? TextDecoration.lineThrough : null,
                                decorationColor: p.muted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Wrap(
                              spacing: AppSpace.s,
                              runSpacing: 2,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PersonAvatar(name: child.assigneeName, size: 18),
                                    const SizedBox(width: AppSpace.xs),
                                    Text(shortName(child.assigneeName), style: text.labelSmall?.copyWith(color: p.muted)),
                                  ],
                                ),
                                if (child.dueAt != null) DueBadge(due: child.dueAt!, now: now, complete: finished(child)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpace.s),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          StatusBadge(name: child.statusName, category: child.statusCategory, dense: true),
                          const SizedBox(height: AppSpace.xs),
                          child.requiredSubtask
                              ? WorkBadge(key: ValueKey('subtask-required-${child.id}'), label: Fa.requiredShort, tone: p.warning, icon: AppIcons.warning, dense: true)
                              : WorkBadge(label: Fa.optionalSubtask, tone: p.muted, dense: true),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpace.s),
          _InlineAdd(
            inputKey: const Key('subtask-input'),
            addKey: const Key('subtask-add'),
            controller: subtaskTitle,
            hint: Fa.addSubtaskHint,
            busy: busy,
            onChanged: () => setState(() {}),
            onAdd: () => _subtask(row, session),
            extra: FilterChip(
              key: const Key('subtask-required'),
              label: const Text(Fa.requiredShort),
              selected: requiredSubtask,
              visualDensity: VisualDensity.compact,
              onSelected: busy ? null : (value) => setState(() => requiredSubtask = value),
            ),
          ),
        ],
      ),
    );
  }

  /// Versions and reviews apart from the activity log: two tabs.
  Widget _history(BuildContext context, TaskRow row, WorkflowRow? flow) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    // Status changes are told in the four final statuses, never stored names.
    final statusNames = {for (final s in flow?.statuses ?? const <StatusRow>[]) s.id: groupLabel(groupOfCategory(s.category))};
    return _Section(
      icon: AppIcons.reviews,
      title: Fa.activity,
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: p.hairline,
              labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              unselectedLabelStyle: text.labelLarge,
              labelColor: p.ink,
              unselectedLabelColor: p.muted,
              tabs: [
                Tab(key: const Key('tab-versions'), text: '${Fa.versionsAndReviews} (${persianDigits(row.rounds.length)})'),
                Tab(key: const Key('tab-activity'), text: '${Fa.activityHistory} (${persianDigits(row.activity.length)})'),
              ],
            ),
            const SizedBox(height: AppSpace.m),
            Builder(
              builder: (context) {
                final controller = DefaultTabController.of(context);
                return AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    if (controller.index == 0) {
                      if (row.rounds.isEmpty) {
                        return _SoftEmpty(icon: AppIcons.reviews, message: row.approvalRequired ? Fa.noSubmissionsYet : Fa.noApprovalCycle);
                      }
                      return Column(
                        key: const Key('version-history'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (var i = 0; i < row.rounds.length; i++) VersionEntry(round: row.rounds[i], current: i == 0, last: i == row.rounds.length - 1)],
                      );
                    }
                    if (row.activity.isEmpty) return const _SoftEmpty(icon: AppIcons.activity, message: Fa.noActivity);
                    return Column(
                      key: const Key('activity-timeline'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < row.activity.length; i++) _ActivityItem(event: row.activity[i], statusNames: statusNames, last: i == row.activity.length - 1),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- properties

  Widget _properties(BuildContext context, TaskRow row, WorkspaceSession? session, ProjectRow? project) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final self = session?.profileId;
    final editable = canEditTask(session, row);
    final members = assignableMembers(project);
    final memberById = {for (final m in members) m.profileId: m};
    NamedPerson named(NamedPerson person) => person.id == self && session != null ? NamedPerson(id: person.id, name: selfLabel(session)) : person;
    String nameOf(String id, String stored) {
      final member = memberById[id];
      if (member != null) return memberDisplayName(member, session);
      if (id == self && session != null) return selfLabel(session);
      return stored.trim().isEmpty ? Fa.projectMemberFallback : stored;
    }

    final activeLabels = project?.labels.where((l) => l.active).toList() ?? const <LabelRow>[];
    final projectLoading = row.projectId != null && project == null;
    return Material(
      key: const Key('task-properties'),
      color: p.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: Color.alphaBlend(p.jade.withValues(alpha: 0.35), p.surface)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Fa.properties, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpace.m),
            FormSection(
              title: Fa.priority,
              child: PriorityPicker(value: priority, enabled: !busy && editable, onChanged: (value) => setState(() => priority = value)),
            ),
            FormSection(
              title: Fa.assignee,
              child: row.projectId == null
                  // A personal task stays with its owner.
                  ? FixedAssignee(key: const Key('detail-assignee'), name: nameOf(row.assigneeId ?? '', row.assigneeName))
                  : AppSelectField<String>(
                      fieldKey: const Key('detail-assignee'),
                      value: assignee?.id,
                      selectedLabel: assignee == null ? null : nameOf(assignee!.id, assignee!.name),
                      options: memberOptions(members, session),
                      loading: projectLoading,
                      emptyText: Fa.noProjectMembers,
                      searchHint: Fa.searchPeople,
                      searchable: true,
                      onChanged: busy || !editable || session == null ? null : (value) => setState(() => assignee = NamedPerson(id: value, name: nameOf(value, ''))),
                    ),
            ),
            FormSection(
              title: Fa.dueDate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const Key('detail-due-switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(withDue ? '${Fa.dueDate}: ${persianDigits(due.day)} ${jalaliMonths[due.month - 1]} ${persianDigits(due.year)}' : Fa.clearDue),
                    value: withDue,
                    onChanged: busy || !editable ? null : (value) => setState(() => withDue = value),
                  ),
                  if (withDue) TaskDateField(key: const Key('detail-due'), value: due, onChanged: busy || !editable ? null : (value) => setState(() => due = value)),
                ],
              ),
            ),
            FormSection(
              title: Fa.approvalRequired,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const Key('detail-approval'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(approval ? Fa.approvalRequired : Fa.approvalOptional),
                    subtitle: Text(approvalLabel(row.approvalState)),
                    value: approval,
                    onChanged: busy || !editable ? null : (value) => setState(() => approval = value),
                  ),
                  if (approval && row.projectId != null)
                    AppSelectField<String>(
                      fieldKey: const Key('detail-reviewer'),
                      label: Fa.reviewer,
                      value: reviewer?.id ?? '',
                      selectedLabel: reviewer == null ? null : nameOf(reviewer!.id, reviewer!.name),
                      options: [
                        AppSelectOption<String>(
                          value: '',
                          label: Fa.reviewerPool,
                          leading: AppIconView(AppIcons.people, size: 22, color: p.muted),
                        ),
                        ...memberOptions([
                          for (final m in members)
                            if (m.role != 'member') m,
                        ], session),
                      ],
                      loading: projectLoading,
                      onChanged: busy || !editable ? null : (value) => setState(() => reviewer = value.isEmpty ? null : NamedPerson(id: value, name: nameOf(value, ''))),
                    ),
                  if (approval && row.projectId == null)
                    PersonField(
                      key: const Key('detail-reviewer'),
                      label: Fa.reviewer,
                      person: reviewer == null ? null : named(reviewer!),
                      emptyLabel: Fa.reviewerPool,
                      onClear: reviewer == null || busy || !editable ? null : () => setState(() => reviewer = null),
                      onTap: busy || session == null || !editable
                          ? null
                          : () async {
                              final picked = await showPersonPicker(
                                context,
                                title: Fa.reviewer,
                                suggestions: const [],
                                noneLabel: Fa.reviewerPool,
                                selfId: session.profileId,
                                selfName: selfLabel(session),
                              );
                              if (picked != null) setState(() => reviewer = picked.person);
                            },
                    ),
                ],
              ),
            ),
            if (row.projectId != null) ...[
              FormSection(
                title: Fa.labels,
                child: activeLabels.isEmpty
                    ? Text('—', style: text.bodySmall)
                    : Wrap(
                        spacing: AppSpace.xs,
                        runSpacing: AppSpace.xs,
                        children: [
                          for (final label in activeLabels)
                            FilterChip(
                              key: ValueKey('label-${label.id}'),
                              label: Text(label.name),
                              selected: row.labels.any((item) => item.id == label.id),
                              onSelected: busy
                                  ? null
                                  : (selected) {
                                      final ids = row.labels.map((item) => item.id).toSet();
                                      selected ? ids.add(label.id) : ids.remove(label.id);
                                      _run(() => _repo.setLabels(row.id, ids.toList()));
                                    },
                            ),
                        ],
                      ),
              ),
              FormSection(
                title: Fa.collaborators,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (row.collaborators.isNotEmpty) ...[
                      Wrap(
                        spacing: AppSpace.xs,
                        runSpacing: AppSpace.xs,
                        children: [
                          for (final person in row.collaborators)
                            InputChip(
                              avatar: PersonAvatar(name: person.name, size: 20),
                              label: Text(nameOf(person.id, person.name)),
                              onDeleted: busy ? null : () => _run(() => _repo.removeCollaborator(row.id, person.id)),
                              deleteIcon: const AppIconView(AppIcons.close, size: 16),
                              deleteButtonTooltipMessage: Fa.removeCollaborator,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.s),
                    ],
                    AppSelectField<String>(
                      fieldKey: const Key('add-collaborator'),
                      value: null,
                      placeholder: Fa.addCollaborator,
                      icon: AppIcons.add,
                      options: memberOptions([
                        for (final m in members)
                          if (m.profileId != row.assigneeId && !row.collaborators.any((c) => c.id == m.profileId)) m,
                      ], session),
                      emptyText: Fa.noMoreMembers,
                      loading: projectLoading,
                      onChanged: busy || session == null ? null : (value) => _run(() => _repo.addCollaborator(row.id, value)),
                    ),
                  ],
                ),
              ),
            ],
            Divider(color: p.hairline),
            const SizedBox(height: AppSpace.xs),
            Text('${Fa.createdOn} ${formatStamp(row.createdAt)}', style: text.bodySmall),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- actions

  WorkRepository get _repo => WorkRepository(ref.read(supabaseClientProvider)!);

  Future<void> _save(TaskRow row) async {
    final next = TaskRow(
      id: row.id,
      title: title.text,
      description: description.text,
      priority: priority,
      approvalRequired: approval,
      approvalState: row.approvalState,
      requiredSubtask: row.requiredSubtask,
      assigneeId: assignee?.id,
      assigneeName: assignee?.name ?? row.assigneeName,
      reviewerId: approval ? reviewer?.id : row.reviewerId,
      statusId: row.statusId,
      statusName: row.statusName,
      statusKey: row.statusKey,
      statusCategory: row.statusCategory,
      collaborators: row.collaborators,
      labels: row.labels,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
    final dueIso = dueToSend(original: row.dueAt, withDue: withDue, due: due)?.toIso8601String();
    await _run(() async {
      await _repo.updateTask(next, dueIso: dueIso);
      loadedFor = null;
      editing = false;
    });
  }

  /// "Needs revision": a dedicated form; both what to fix and why are
  /// required. Sent through the existing `decide_task` (revision_requested).
  Future<void> _requestChanges(TaskRow row) async {
    final answer = await showRevisionRequest(context, task: row);
    if (answer == null) return;
    await _run(
      () => _repo.decide(
        row.id,
        'revision_requested',
        reason: composeRevision(what: answer.what, why: answer.why),
      ),
    );
  }

  Future<void> _decide(TaskRow row, String decision, bool reasonRequired) async {
    final answer = await askDecision(
      context,
      title: decision == 'approved'
          ? Fa.approve
          : decision == 'rejected'
          ? Fa.finalReject
          : Fa.requestRevision,
      reasonRequired: reasonRequired,
    );
    if (answer == null) return;
    await _run(() => _repo.decide(row.id, decision, reason: reasonRequired ? answer : null));
  }

  Future<void> _rename(ChecklistRow item) async {
    final controller = TextEditingController(text: item.title);
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Fa.renameItem),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (value) => Navigator.pop(context, value)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text(Fa.save)),
        ],
      ),
    );
    controller.dispose();
    if (answer == null || answer.trim().isEmpty || answer.trim() == item.title) return;
    await _run(() => _repo.renameChecklist(item.id, answer));
  }

  Future<void> _addChecklist(TaskRow row) async {
    if (checklistTitle.text.trim().isEmpty) return;
    await _run(() async {
      await _repo.addChecklist(row.id, checklistTitle.text);
      checklistTitle.clear();
    });
  }

  Future<void> _subtask(TaskRow row, WorkspaceSession? session) async {
    await _run(() async {
      await _repo.createTask(
        title: subtaskTitle.text,
        description: '',
        projectId: row.projectId,
        assigneeId: row.assigneeId ?? session?.profileId ?? '',
        priority: 'medium',
        parentId: row.id,
        required: requiredSubtask,
        approval: row.projectId == null ? false : null,
      );
      subtaskTitle.clear();
      requiredSubtask = false;
    });
  }

  void _invalidateAll() {
    ref.invalidate(taskProvider(widget.taskId));
    ref.invalidate(taskPageProvider);
    ref.invalidate(monthTasksProvider);
    ref.invalidate(sprintListProvider);
    ref.invalidate(sprintProvider);
    ref.invalidate(projectSprintCountsProvider);
    ref.invalidate(sprintTaskProvider);
    ref.invalidate(sprintBreakdownProvider);
    ref.invalidate(milestoneListProvider);
    ref.invalidate(milestoneProvider);
    ref.invalidate(projectMilestoneCountsProvider);
    ref.invalidate(milestoneTaskProvider);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      _invalidateAll();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

/// One block of the task body. Blocks are separated by a hairline and
/// generous space instead of boxes inside boxes.
class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.child, this.trailing, this.first = false});

  final AppIcon icon;
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : AppSpace.l, bottom: AppSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!first) ...[Divider(color: p.hairline), const SizedBox(height: AppSpace.l)],
          Row(
            children: [
              AppIconView(icon, size: 18, color: p.muted),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppSpace.m),
          child,
        ],
      ),
    );
  }
}

/// "2 of 5": progress count beside a section title.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.label, this.complete = false});

  final String label;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final tone = complete ? p.success : p.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: 1),
      decoration: BoxDecoration(color: Color.alphaBlend(tone.withValues(alpha: 0.12), p.surface), borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: complete ? p.success : p.ink, fontWeight: FontWeight.w700)),
    );
  }
}

/// A small, quiet empty line: icon and a short sentence, no box.
class _SoftEmpty extends StatelessWidget {
  const _SoftEmpty({super.key, required this.icon, required this.message});

  final AppIcon icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          AppIconView(icon, size: 16, color: p.muted.withValues(alpha: 0.8)),
          const SizedBox(width: AppSpace.s),
          Flexible(child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted))),
        ],
      ),
    );
  }
}

/// A compact "add" row: one rounded field with its own add action, so the
/// input and its button read as one control.
class _InlineAdd extends StatelessWidget {
  const _InlineAdd({
    required this.inputKey,
    required this.addKey,
    required this.controller,
    required this.hint,
    required this.busy,
    required this.onChanged,
    required this.onAdd,
    this.extra,
  });

  final Key inputKey;
  final Key addKey;
  final TextEditingController controller;
  final String hint;
  final bool busy;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final ready = !busy && controller.text.trim().isNotEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsetsDirectional.only(start: AppSpace.m, end: AppSpace.xs),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: p.stroke),
      ),
      child: Row(
        children: [
          AppIconView(AppIcons.add, size: 18, color: p.muted),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: TextField(
              key: inputKey,
              controller: controller,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) {
                if (ready) onAdd();
              },
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.s + 2),
              ),
            ),
          ),
          if (extra != null) ...[const SizedBox(width: AppSpace.xs), extra!],
          const SizedBox(width: AppSpace.xs),
          TextButton(
            key: addKey,
            onPressed: ready ? onAdd : null,
            style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: AppSpace.m)),
            child: const Text(Fa.addItem),
          ),
        ],
      ),
    );
  }
}

/// How an activity event looks: an icon and whether it is an important
/// change (assignee, priority, due date, status, review, block).
({AppIcon icon, Color Function(AppPalette) tone, bool important}) _activityLook(String action) => switch (action) {
  'task.create' => (icon: AppIcons.add, tone: (p) => p.jade, important: false),
  'task.assign' || 'task.reassign' || 'task.reassign_for' => (icon: AppIcons.person, tone: (p) => p.info, important: true),
  'task.priority' => (icon: AppIcons.priority, tone: (p) => p.warning, important: true),
  'task.due' => (icon: AppIcons.due, tone: (p) => p.info, important: true),
  'task.transition' || 'task.migrated' => (icon: AppIcons.workflow, tone: (p) => p.jade, important: true),
  'task.review' || 'task.submit' => (icon: AppIcons.reviewer, tone: (p) => p.revision, important: true),
  'task.override' => (icon: AppIcons.warning, tone: (p) => p.alert, important: true),
  'task.blocked' || 'task.unblocked' => (icon: AppIcons.restricted, tone: (p) => p.alert, important: true),
  'task.approval' => (icon: AppIcons.approvalPolicy, tone: (p) => p.muted, important: false),
  'task.collaborator' || 'task.collaborator_remove' => (icon: AppIcons.people, tone: (p) => p.muted, important: false),
  'task.labels' => (icon: AppIcons.label, tone: (p) => p.muted, important: false),
  'task.subtask' || 'task.subtask_done' => (icon: AppIcons.subtask, tone: (p) => p.muted, important: false),
  'task.sprint' || 'task.sprint_remove' => (icon: AppIcons.sprint, tone: (p) => p.muted, important: false),
  _ when action.startsWith('checklist.') => (icon: AppIcons.checklist, tone: (p) => p.muted, important: false),
  _ => (icon: AppIcons.activity, tone: (p) => p.muted, important: false),
};

/// The change an event records, in words. Only values that resolve to a
/// label are shown; ids are never printed.
String? activityDetail(ActivityRow event, Map<String, String> statusNames) {
  final m = event.metadata;
  String? text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
  switch (event.action) {
    case 'task.priority':
      final from = text(m['from']);
      final to = text(m['to']);
      if (to == null) return null;
      return from == null ? Fa.changeTo(priorityLabel(to)) : Fa.changeFromTo(priorityLabel(from), priorityLabel(to));
    case 'task.review':
      return switch (text(m['decision'])) {
        'approved' => Fa.decisionApproved,
        'revision_requested' => Fa.decisionRevisionShort,
        'rejected' => Fa.finalRejectedBadge,
        _ => null,
      };
    case 'task.transition' || 'task.migrated':
      final to = statusNames[text(m['to'])];
      final from = statusNames[text(m['from'])];
      if (to == null || to == from) return null;
      return from == null ? Fa.changeTo(to) : Fa.changeFromTo(from, to);
    case 'task.due':
      final to = DateTime.tryParse(text(m['to']) ?? '');
      return to == null ? null : Fa.changeTo(TehranTime.formatDate(to.toUtc()));
    case 'task.override':
      return text(m['reason']);
    case 'task.submit':
      final version = m['version'];
      return version is int ? versionLabel(version) : null;
  }
  return null;
}

class _ActivityItem extends StatelessWidget {
  const _ActivityItem({required this.event, required this.statusNames, required this.last});

  final ActivityRow event;
  final Map<String, String> statusNames;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final look = _activityLook(event.action);
    final tone = look.tone(p);
    final detail = activityDetail(event, statusNames);
    final actor = event.actor.trim().isEmpty ? Fa.noValue : event.actor;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                ToneIcon(icon: look.icon, tone: tone, size: 28),
                if (!last) Expanded(child: Center(child: Container(width: 1.5, color: p.hairline))),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.l, top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(activityLabel(event.action), style: text.bodyMedium?.copyWith(color: p.ink, fontWeight: look.important ? FontWeight.w700 : FontWeight.w500)),
                  if (detail != null) Text(detail, style: text.bodySmall?.copyWith(color: p.ink)),
                  const SizedBox(height: 2),
                  Text('$actor · ${formatStamp(event.createdAt)}', style: text.labelSmall?.copyWith(color: p.muted)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================================================================== review cycle

/// One submission (version) on the review timeline. The latest version and
/// its decision stand out; a revision request shows "what" and "why" apart.
class VersionEntry extends StatelessWidget {
  const VersionEntry({super.key, required this.round, required this.current, required this.last});

  final ReviewRoundRow round;
  final bool current;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final (label, tone, icon) = switch (round.decision) {
      'approved' => (Fa.decisionApproved, p.success, AppIcons.approve),
      'revision_requested' => (Fa.decisionRevisionShort, p.revision, AppIcons.revise),
      'rejected' => (Fa.finalRejectedBadge, p.danger, AppIcons.reject),
      _ => (Fa.awaitingDecision, p.jade, AppIcons.pending),
    };
    Widget fact(String name, String value) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(name, style: text.bodySmall?.copyWith(color: p.muted))),
          Expanded(child: Text(value, style: text.bodySmall?.copyWith(color: p.ink))),
        ],
      ),
    );
    return IntrinsicHeight(
      key: ValueKey('version-${round.number}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rail: dot and line, the timeline's spine.
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: AppSpace.l),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: current ? tone : p.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: tone, width: 2),
                  ),
                ),
                if (!last) Expanded(child: Container(width: 1.5, color: p.hairline)),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Container(
                padding: const EdgeInsets.all(AppSpace.m),
                decoration: BoxDecoration(
                  color: current ? Color.alphaBlend(tone.withValues(alpha: 0.06), p.surface) : p.surface,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(color: current ? tone.withValues(alpha: 0.45) : p.stroke, width: current ? 1.5 : 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: AppSpace.s,
                      runSpacing: AppSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        VersionBadge(submission: round.number),
                        WorkBadge(label: label, tone: tone, icon: icon, dense: true),
                        if (current)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(999)),
                            child: Text(Fa.latestVersion, style: text.labelSmall?.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.s),
                    fact(Fa.submittedAt, formatStamp(round.openedAt)),
                    if (round.decision != null) ...[
                      fact(Fa.reviewer, (round.reviewer ?? '').trim().isEmpty ? Fa.noValue : round.reviewer!),
                      if (round.decidedAt != null) fact(Fa.decidedAt, formatStamp(round.decidedAt!)),
                    ],
                    if ((round.reason ?? '').trim().isNotEmpty) ...[const SizedBox(height: AppSpace.s), _ReasonText(reason: round.reason!, revision: round.decision == 'revision_requested')],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A reviewer's reason. A revision request shows "what to fix" and "why"
/// as two separate blocks; other reasons as one quote.
class _ReasonText extends StatelessWidget {
  const _ReasonText({required this.reason, required this.revision});

  final String reason;
  final bool revision;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    Widget block(String? title, String body, Color tone, {Key? key}) => Container(
      key: key,
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpace.xs),
      padding: const EdgeInsets.all(AppSpace.s + 2),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.07), p.surface),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: BorderDirectional(start: BorderSide(color: tone.withValues(alpha: 0.7), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) Text(title, style: text.labelSmall?.copyWith(color: p.muted, fontWeight: FontWeight.w700)),
          Text(body, style: text.bodyMedium?.copyWith(color: p.ink, height: 1.7)),
        ],
      ),
    );
    if (!revision) return block(null, reason.trim(), p.muted);
    final parts = parseRevision(reason);
    return Column(
      key: const Key('revision-reason'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        block(Fa.revisionWhatTitle, parts.what, p.revision, key: const Key('revision-what-block')),
        if (parts.why != null) block(Fa.revisionWhyTitle, parts.why!, p.muted, key: const Key('revision-why-block')),
      ],
    );
  }
}

/// The "needs revision" form: what must change and why, both required.
Future<({String what, String why})?> showRevisionRequest(BuildContext context, {required TaskRow task}) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  final form = _RevisionForm(task: task);
  if (compact) {
    return showModalBottomSheet<({String what, String why})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(child: form),
      ),
    );
  }
  return showDialog<({String what, String why})>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: form),
    ),
  );
}

class _RevisionForm extends StatefulWidget {
  const _RevisionForm({required this.task});

  final TaskRow task;

  @override
  State<_RevisionForm> createState() => _RevisionFormState();
}

class _RevisionFormState extends State<_RevisionForm> {
  final _what = TextEditingController();
  final _why = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _what.dispose();
    _why.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() => _tried = true);
    if (_what.text.trim().isEmpty || _why.text.trim().isEmpty) return;
    Navigator.pop<({String what, String why})>(context, (what: _what.text.trim(), why: _why.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final task = widget.task;
    return SingleChildScrollView(
      key: const Key('revision-form'),
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.l, AppSpace.xl, AppSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Color.alphaBlend(p.revision.withValues(alpha: 0.14), p.surface), shape: BoxShape.circle),
                child: AppIconView(AppIcons.revise, size: 20, color: p.revision),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(Fa.requestRevision, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.m),
          Material(
            color: p.surfaceRaised,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(color: p.stroke),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.m),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (task.submissions > 0) ...[const SizedBox(width: AppSpace.s), VersionBadge(submission: task.submissions)],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.s),
          Text(Fa.revisionFormHint, style: text.bodySmall),
          const SizedBox(height: AppSpace.l),
          TextField(
            key: const Key('revision-what'),
            controller: _what,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            onChanged: (_) {
              if (_tried) setState(() {});
            },
            decoration: InputDecoration(
              labelText: Fa.revisionWhatTitle,
              hintText: Fa.revisionWhatHint,
              alignLabelWithHint: true,
              errorText: _tried && _what.text.trim().isEmpty ? Fa.fieldRequired : null,
            ),
          ),
          const SizedBox(height: AppSpace.m),
          TextField(
            key: const Key('revision-why'),
            controller: _why,
            minLines: 2,
            maxLines: 6,
            onChanged: (_) {
              if (_tried) setState(() {});
            },
            decoration: InputDecoration(
              labelText: Fa.revisionWhyTitle,
              hintText: Fa.revisionWhyHint,
              alignLabelWithHint: true,
              errorText: _tried && _why.text.trim().isEmpty ? Fa.fieldRequired : null,
            ),
          ),
          const SizedBox(height: AppSpace.l),
          Row(
            children: [
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
              const SizedBox(width: AppSpace.s),
              FilledButton.icon(
                key: const Key('revision-submit'),
                onPressed: _submit,
                icon: AppIconView(AppIcons.revise, size: 18, color: p.onJade),
                label: const Text(Fa.sendRevision),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
