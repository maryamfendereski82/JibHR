import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'plan_repository.dart';
import 'task_form.dart';
import 'project_pages.dart';
import 'widgets/plan_ui.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';
import 'workflow_presentation.dart';

export 'widgets/plan_ui.dart' show PlanHeader, PlanProgressBar;

final sprintListProvider = FutureProvider.family<({List<SprintRow> rows, int total}), ({String projectId, int page})>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (rows: const <SprintRow>[], total: 0);
  return PlanRepository(client).sprints(projectId: key.projectId, page: key.page);
});

final sprintProvider = FutureProvider.family<SprintRow?, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return PlanRepository(client).sprint(id);
});

final projectSprintCountsProvider = FutureProvider.family<Map<String, PlanCounts>, String>((ref, projectId) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const {};
  return PlanRepository(client).sprintCounts(projectId);
});

typedef SprintTaskQuery = ({String sprintId, bool history, String? statusId, String? priority, String? assigneeId, int page});

final sprintTaskProvider = FutureProvider.family<({List<PlanTaskRow> tasks, int total}), SprintTaskQuery>((ref, query) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (tasks: const <PlanTaskRow>[], total: 0);
  return PlanRepository(client).sprintTasks(sprintId: query.sprintId, history: query.history, statusId: query.statusId, priority: query.priority, assigneeId: query.assigneeId, page: query.page);
});

final sprintBreakdownProvider = FutureProvider.family<List<PlanBreakdown>, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  return PlanRepository(client).sprintBreakdown(id);
});

bool _canManage(WorkspaceSession? session, ProjectRow? project) => canManagePlan(
  manageTasks: session?.can('tasks.manage.project') ?? false,
  editProject: session?.can('projects.edit') ?? false,
  viewAll: session?.can('projects.view.all') ?? false,
  projectManager: project?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
);

double _gutter(BuildContext context) => MediaQuery.sizeOf(context).width < 600 ? AppSpace.l : AppSpace.xxl;

// ==================================================================== list

class SprintListPage extends ConsumerStatefulWidget {
  const SprintListPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<SprintListPage> createState() => _SprintListPageState();
}

class _SprintListPageState extends ConsumerState<SprintListPage> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId)).asData?.value;
    final list = ref.watch(sprintListProvider((projectId: widget.projectId, page: page)));
    final counts = ref.watch(projectSprintCountsProvider(widget.projectId)).asData?.value ?? const <String, PlanCounts>{};
    final manage = _canManage(session, project);
    final p = paletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlanHeader(
          title: Fa.sprints,
          eyebrow: project?.name,
          onBack: () => context.go('/work/p/${widget.projectId}'),
          actions: [
            if (manage)
              FilledButton.icon(
                key: const Key('new-sprint'),
                onPressed: () => _create(context),
                icon: AppIconView(AppIcons.add, color: p.onJade),
                label: const Text(Fa.newSprint),
              ),
          ],
        ),
        Expanded(
          child: list.when(
            skipLoadingOnReload: true,
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: _refresh),
            data: (result) {
              if (result.rows.isEmpty) return const EmptyView(message: Fa.empty);
              return ListView(
                padding: EdgeInsets.fromLTRB(_gutter(context), AppSpace.s, _gutter(context), AppSpace.xxl),
                children: [
                  for (final row in result.rows) _SprintCard(row: row, counts: counts[row.id] ?? PlanCounts.zero, onOpen: () => context.go('/work/p/${widget.projectId}/sprint/${row.id}')),
                  if (result.total > taskPageSize) PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _refresh() {
    ref.invalidate(sprintListProvider);
    ref.invalidate(projectSprintCountsProvider);
  }

  Future<void> _create(BuildContext context) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _SprintDialog(projectId: widget.projectId),
    );
    if (created == true) _refresh();
  }
}

class _SprintCard extends StatelessWidget {
  const _SprintCard({required this.row, required this.counts, required this.onOpen});

  final SprintRow row;
  final PlanCounts counts;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final tone = sprintTone(p, row.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.m),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          key: ValueKey('sprint-${row.id}'),
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.all(AppSpace.l),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: row.status == 'active' ? tone : p.stroke, width: row.status == 'active' ? 1.5 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AppIconView(AppIcons.sprint, size: 20, color: tone),
                    const SizedBox(width: AppSpace.s),
                    Expanded(
                      child: Text(
                        row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    WorkBadge(label: sprintStatusLabel(row.status), tone: tone, dense: true),
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                Text(planRange(row.startDate, row.endDate), style: text.bodySmall),
                if (row.description.trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    row.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: p.ink),
                  ),
                ],
                const SizedBox(height: AppSpace.m),
                PlanProgressBar(label: '${persianDigits(counts.complete)} از ${persianDigits(counts.total)} ${Fa.completedTasks}', complete: counts.complete, total: counts.total),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Create (with initial tasks) or edit a sprint. Pops true on success.
class _SprintDialog extends ConsumerStatefulWidget {
  const _SprintDialog({required this.projectId, this.existing});

  final String projectId;
  final SprintRow? existing;

  @override
  ConsumerState<_SprintDialog> createState() => _SprintDialogState();
}

class _SprintDialogState extends ConsumerState<_SprintDialog> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final description = TextEditingController(text: widget.existing?.description ?? '');
  late JalaliStamp start = widget.existing == null ? JalaliStamp.today() : _stamp(widget.existing!.startDate);
  late JalaliStamp end = widget.existing == null ? JalaliStamp.today() : _stamp(widget.existing!.endDate);
  final chosen = <String, String>{};
  bool busy = false;
  bool tried = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => tried = true);
    if (name.text.trim().isEmpty) return;
    if (!sprintRangeValid(start.isoDay, end.isoDay)) {
      setState(() => error = Fa.invalidRange);
      return;
    }
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await PlanRepository(client).createSprint(projectId: widget.projectId, name: name.text, description: description.text, start: start.isoDay, end: end.isoDay, tasks: chosen.keys.toList());
      } else {
        await PlanRepository(client).updateSprint(SprintRow(id: existing.id, name: name.text, description: description.text, startDate: start.isoDay, endDate: end.isoDay, status: existing.status));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = taskErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('sprint-name'),
          controller: name,
          autofocus: true,
          onChanged: (_) {
            if (tried) setState(() {});
          },
          decoration: InputDecoration(labelText: Fa.title, errorText: tried && name.text.trim().isEmpty ? Fa.titleRequired : null),
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: description,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: Fa.description, alignLabelWithHint: true),
        ),
        const SizedBox(height: AppSpace.l),
        Text(Fa.startDate, style: text.labelLarge),
        const SizedBox(height: AppSpace.xs),
        TaskDateField(value: start, onChanged: (value) => setState(() => start = value)),
        const SizedBox(height: AppSpace.m),
        Text(Fa.endDate, style: text.labelLarge),
        const SizedBox(height: AppSpace.xs),
        TaskDateField(value: end, onChanged: (value) => setState(() => end = value)),
        if (widget.existing == null) ...[
          const SizedBox(height: AppSpace.l),
          Text(Fa.initialTasks, style: text.labelLarge),
          const SizedBox(height: AppSpace.xs),
          if (chosen.isNotEmpty)
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                for (final entry in chosen.entries)
                  InputChip(label: Text(entry.value), onDeleted: () => setState(() => chosen.remove(entry.key)), deleteIcon: const AppIconView(AppIcons.close, size: 16)),
              ],
            ),
          TaskChooser(projectId: widget.projectId, chosen: chosen, onToggle: (id, title) => setState(() => chosen.containsKey(id) ? chosen.remove(id) : chosen[id] = title)),
        ],
        if (error != null) ...[const SizedBox(height: AppSpace.m), Text(error!, style: TextStyle(color: p.danger))],
      ],
    );
    final content = SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, AppSpace.l, AppSpace.s, AppSpace.s),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.existing == null ? Fa.newSprint : Fa.editSprint, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  tooltip: Fa.close,
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const AppIconView(AppIcons.close, semanticLabel: Fa.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.l), child: body),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.m, AppSpace.xl, AppSpace.l),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.hairline)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text(Fa.cancel)),
                const SizedBox(width: AppSpace.s),
                FilledButton(
                  key: const Key('sprint-submit'),
                  onPressed: busy ? null : _submit,
                  child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade)) : Text(widget.existing == null ? Fa.newSprint : Fa.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return compact
        ? Dialog.fullscreen(child: content)
        : Dialog(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780), child: content),
          );
  }
}

// ==================================================================== detail

class SprintDetailPage extends ConsumerStatefulWidget {
  const SprintDetailPage({super.key, required this.projectId, required this.sprintId});

  final String projectId;
  final String sprintId;

  @override
  ConsumerState<SprintDetailPage> createState() => _SprintDetailPageState();
}

class _SprintDetailPageState extends ConsumerState<SprintDetailPage> {
  String? statusId;
  String? priority;
  String? assigneeId;
  int page = 0;
  int historyPage = 0;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId)).asData?.value;
    final sprint = ref.watch(sprintProvider(widget.sprintId));
    final counts = ref.watch(projectSprintCountsProvider(widget.projectId));
    final breakdown = ref.watch(sprintBreakdownProvider(widget.sprintId));
    final tasks = ref.watch(sprintTaskProvider((sprintId: widget.sprintId, history: false, statusId: statusId == null ? null : statusIdsForKey(project?.workflow, statusId!), priority: priority, assigneeId: assigneeId, page: page)));
    final history = ref.watch(sprintTaskProvider((sprintId: widget.sprintId, history: true, statusId: null, priority: null, assigneeId: null, page: historyPage)));
    final manage = _canManage(session, project);
    return sprint.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: _refresh),
      data: (row) {
        if (row == null) return const EmptyView();
        final live = counts.asData?.value[row.id] ?? PlanCounts.zero;
        final p = paletteOf(context);
        final editable = manage && row.status != 'closed' && row.status != 'cancelled';
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1080;
            final summary = _summary(row, live, breakdown.asData?.value ?? const [], manage);
            final taskList = _taskColumn(row, tasks, history, manage, project);
            final gutter = _gutter(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlanHeader(
                  title: row.name,
                  eyebrow: '${Fa.sprints} · ${planRange(row.startDate, row.endDate)}',
                  badge: WorkBadge(label: sprintStatusLabel(row.status), tone: sprintTone(p, row.status), dense: true),
                  onBack: () => context.go('/work/p/${widget.projectId}/sprints'),
                  actions: [
                    if (editable)
                      IconButton(
                        key: const Key('edit-sprint'),
                        tooltip: Fa.editSprint,
                        onPressed: busy ? null : () => _edit(row),
                        icon: const AppIconView(AppIcons.edit, semanticLabel: Fa.editSprint),
                      ),
                  ],
                ),
                if (manage) _actionBar(row, live, gutter),
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 400,
                              child: ListView(padding: EdgeInsetsDirectional.fromSTEB(gutter, AppSpace.s, AppSpace.s, AppSpace.xxl), children: summary),
                            ),
                            Expanded(
                              child: ListView(padding: EdgeInsetsDirectional.fromSTEB(AppSpace.l, AppSpace.s, gutter, AppSpace.xxl), children: [taskList]),
                            ),
                          ],
                        )
                      : ListView(padding: EdgeInsets.fromLTRB(gutter, AppSpace.s, gutter, AppSpace.xxl), children: [...summary, taskList]),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// One primary step forward, the rest quieter; cancel is a danger text action.
  Widget _actionBar(SprintRow row, PlanCounts live, double gutter) {
    final p = paletteOf(context);
    final primary = switch (row.status) {
      'planned' => FilledButton.icon(
        key: const Key('activate-sprint'),
        onPressed: busy ? null : () => _status('active'),
        icon: AppIconView(AppIcons.sprint, size: 18, color: p.onJade),
        label: const Text(Fa.activateSprint),
      ),
      'active' => FilledButton.icon(
        key: const Key('complete-sprint'),
        onPressed: busy ? null : () => _close(live),
        icon: AppIconView(AppIcons.approve, size: 18, color: p.onJade),
        label: const Text(Fa.completeSprint),
      ),
      _ => null,
    };
    final buttons = <Widget>[
      ?primary,
      if (row.status == 'active' || row.status == 'closed')
        OutlinedButton.icon(key: const Key('transfer-remaining'), onPressed: busy ? null : _transfer, icon: const AppIconView(AppIcons.next, size: 18), label: const Text(Fa.transferRemaining)),
      if (row.status == 'planned' || row.status == 'active')
        TextButton.icon(
          key: const Key('cancel-sprint'),
          onPressed: busy ? null : _cancel,
          icon: AppIconView(AppIcons.close, size: 18, color: p.danger),
          label: Text(Fa.cancelPlan, style: TextStyle(color: p.danger)),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpace.s),
      child: Wrap(spacing: AppSpace.s, runSpacing: AppSpace.s, children: buttons),
    );
  }

  List<Widget> _summary(SprintRow row, PlanCounts live, List<PlanBreakdown> groups, bool manage) {
    final text = Theme.of(context).textTheme;
    return [
      PlanCard(
        title: Fa.currentProgress,
        icon: AppIcons.reports,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (row.description.trim().isNotEmpty) ...[Text(row.description, style: text.bodyMedium), const SizedBox(height: AppSpace.m)],
            PlanProgressBar(label: Fa.currentProgress, complete: live.complete, total: live.total),
            const SizedBox(height: AppSpace.m),
            PlanStats(counts: live),
          ],
        ),
      ),
      if (row.summary != null)
        PlanCard(
          title: Fa.sprintSummary,
          icon: AppIcons.checklist,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlanProgressBar(label: Fa.sprintSummary, complete: row.summary!.complete, total: row.summary!.total),
              const SizedBox(height: AppSpace.m),
              PlanStats(counts: row.summary!),
            ],
          ),
        ),
      if (groups.isNotEmpty) _groups(groups),
    ];
  }

  Widget _groups(List<PlanBreakdown> groups) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    Widget block(String kind, String title) {
      final rows = groups.where((item) => item.kind == kind).toList();
      if (rows.isEmpty) return const SizedBox.shrink();
      final max = rows.fold<int>(1, (m, r) => r.total > m ? r.total : m);
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpace.xs),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        kind == 'priority' ? priorityLabel(row.bucket) : row.bucket,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: p.ink),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(value: row.total / max, minHeight: 6, backgroundColor: p.hairline, color: kind == 'priority' ? priorityTone(p, row.bucket) : p.jade),
                      ),
                    ),
                    const SizedBox(width: AppSpace.s),
                    SizedBox(
                      width: 28,
                      child: Text(persianDigits(row.total), textAlign: TextAlign.end, style: text.labelMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return PlanCard(
      title: Fa.breakdown,
      icon: AppIcons.list,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [block('status', Fa.byStatus), block('priority', Fa.byPriority), block('assignee', Fa.byAssignee)]),
    );
  }

  Widget _taskColumn(SprintRow row, AsyncValue<({List<PlanTaskRow> tasks, int total})> tasks, AsyncValue<({List<PlanTaskRow> tasks, int total})> history, bool manage, ProjectRow? project) {
    final open = manage && row.status != 'closed' && row.status != 'cancelled';
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlanCard(
          title: Fa.totalTasks,
          icon: AppIcons.list,
          trailing: open
              ? TextButton.icon(key: const Key('sprint-add-task'), onPressed: busy ? null : () => _addTasks(row), icon: const AppIconView(AppIcons.add, size: 18), label: const Text(Fa.addToPlan))
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (project != null) _filters(project),
              tasks.when(
                skipLoadingOnReload: true,
                loading: () => const Padding(padding: EdgeInsets.all(AppSpace.l), child: LinearProgressIndicator()),
                error: (error, _) => InlineError(message: taskErrorText(error), onRetry: _refresh),
                data: (result) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (result.tasks.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(AppSpace.l),
                        child: Text(Fa.empty, textAlign: TextAlign.center, style: text.bodySmall),
                      ),
                    for (final task in result.tasks)
                      PlanTaskTile(
                        key: ValueKey('sprint-task-${task.id}'),
                        task: task,
                        onOpen: () => context.go('/work/t/${task.id}'),
                        actions: open
                            ? [
                                (label: Fa.moveTask, icon: AppIcons.next, onTap: busy ? null : () => _move(task.id), danger: false),
                                (label: Fa.removeFromSprint, icon: AppIcons.close, onTap: busy ? null : () => _run(() => _repo.removeTask(task.id, row.id)), danger: true),
                              ]
                            : const [],
                      ),
                    if (result.total > taskPageSize) PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
                  ],
                ),
              ),
            ],
          ),
        ),
        PlanCard(
          title: Fa.planHistory,
          icon: AppIcons.activity,
          child: history.when(
            skipLoadingOnReload: true,
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => InlineError(message: taskErrorText(error), onRetry: _refresh),
            data: (result) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (result.tasks.isEmpty) Text(Fa.empty, style: text.bodySmall),
                for (final task in result.tasks) PlanTaskTile(task: task, onOpen: () => context.go('/work/t/${task.id}')),
                if (result.total > taskPageSize) PageButtons(page: historyPage, total: result.total, onPage: (value) => setState(() => historyPage = value)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _filters(ProjectRow project) {
    Widget menu<T>({required String label, required T? value, required List<(T?, String)> items, required ValueChanged<T?> onChanged}) {
      final current = items.firstWhere((i) => i.$1 == value, orElse: () => items.first).$2;
      return PopupMenuButton<(T?, String)>(
        tooltip: label,
        onSelected: (item) => onChanged(item.$1),
        itemBuilder: (context) => [for (final item in items) CheckedPopupMenuItem(value: item, checked: item.$1 == value, child: Text(item.$2))],
        child: Chip(
          avatar: AppIconView(AppIcons.filter, size: 14, color: value == null ? paletteOf(context).muted : paletteOf(context).jade),
          label: Text(value == null ? label : '$label: $current'),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Wrap(
        spacing: AppSpace.s,
        runSpacing: AppSpace.s,
        children: [
          menu<String>(
            label: Fa.planStatus,
            value: statusId,
            // The four final statuses and the two rejected marks, never stored statuses.
            items: [(null, Fa.allItems), for (final c in statusFilterChoices()) (c.key, c.label)],
            onChanged: (value) => setState(() {
              statusId = value;
              page = 0;
            }),
          ),
          menu<String>(
            label: Fa.priority,
            value: priority,
            items: [
              (null, Fa.allItems),
              for (final item in const ['critical', 'high', 'medium', 'low']) (item, priorityLabel(item)),
            ],
            onChanged: (value) => setState(() {
              priority = value;
              page = 0;
            }),
          ),
          menu<String>(
            label: Fa.assignee,
            value: assigneeId,
            items: [(null, Fa.allItems), for (final m in project.members) (m.profileId, m.name)],
            onChanged: (value) => setState(() {
              assigneeId = value;
              page = 0;
            }),
          ),
        ],
      ),
    );
  }

  PlanRepository get _repo => PlanRepository(ref.read(supabaseClientProvider)!);

  Future<void> _edit(SprintRow row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SprintDialog(projectId: widget.projectId, existing: row),
    );
    if (saved == true) _refresh();
  }

  Future<void> _addTasks(SprintRow row) async {
    await showPlanDialog<void>(
      context,
      title: Fa.addToPlan,
      body: (context) => TaskChooser(projectId: widget.projectId, onPick: (id) => _run(() => _repo.moveTask(id, row.id))),
      actions: (context) => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.close))],
    );
  }

  Future<void> _status(String status) => _run(() => _repo.setSprintStatus(widget.sprintId, status));

  Future<void> _cancel() async {
    final answer = await askDecision(context, title: Fa.cancelSprintConfirm, reasonRequired: false);
    if (answer != null) await _status('cancelled');
  }

  Future<void> _close(PlanCounts live) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Fa.completeSprint),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlanProgressBar(label: Fa.currentProgress, complete: live.complete, total: live.total),
            const SizedBox(height: AppSpace.m),
            PlanStats(counts: live),
            const SizedBox(height: AppSpace.m),
            const Text(Fa.completeConfirm),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fa.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text(Fa.completeSprint)),
        ],
      ),
    );
    if (yes == true) await _status('closed');
  }

  Future<void> _transfer() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _DestinationDialog(client: client, projectId: widget.projectId, currentId: widget.sprintId),
    );
    if (picked == null) return;
    await _run(() => PlanRepository(client).transferRemainder(widget.sprintId, picked));
  }

  Future<void> _move(String taskId) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _DestinationDialog(client: client, projectId: widget.projectId, currentId: widget.sprintId),
    );
    if (picked == null) return;
    await _run(() => PlanRepository(client).moveTask(taskId, picked));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      _refresh();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(sprintProvider(widget.sprintId));
    ref.invalidate(sprintListProvider);
    ref.invalidate(projectSprintCountsProvider);
    ref.invalidate(sprintTaskProvider);
    ref.invalidate(sprintBreakdownProvider);
  }
}

Widget inlinePlanError(Object error, VoidCallback onRetry) => InlineError(message: taskErrorText(error), onRetry: onRetry);

// ==================================================================== shared

class TaskChooser extends ConsumerStatefulWidget {
  const TaskChooser({super.key, required this.projectId, this.chosen = const {}, this.onToggle, this.onPick});

  final String projectId;
  final Map<String, String> chosen;
  final void Function(String id, String title)? onToggle;
  final ValueChanged<String>? onPick;

  @override
  ConsumerState<TaskChooser> createState() => _TaskChooserState();
}

class _TaskChooserState extends ConsumerState<TaskChooser> {
  final search = TextEditingController();
  final picked = <String>{};
  int page = 0;
  Future<TaskPage>? future;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<TaskPage> _load() {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return Future.value(TaskPage.empty);
    return WorkRepository(
      client,
    ).tasks((projectId: widget.projectId, personal: false, assigneeId: null, statusId: null, priority: null, search: search.text, dueFrom: null, dueTo: null, page: page, sort: 'title'));
  }

  void _reload({int? nextPage}) {
    setState(() {
      page = nextPage ?? 0;
      future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(supabaseClientProvider) == null) return const SizedBox.shrink();
    future ??= _load();
    final p = paletteOf(context);
    return FutureBuilder<TaskPage>(
      future: future,
      builder: (context, snapshot) {
        final result = snapshot.data ?? TaskPage.empty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('task-chooser-search'),
              controller: search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: Fa.searchTasks,
                isDense: true,
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(10),
                  child: AppIconView(AppIcons.search, size: 18, color: p.muted),
                ),
              ),
              onSubmitted: (_) => _reload(),
            ),
            if (snapshot.connectionState == ConnectionState.waiting) const LinearProgressIndicator(),
            const SizedBox(height: AppSpace.s),
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                for (final task in result.tasks)
                  FilterChip(
                    label: Text(task.title),
                    selected: widget.chosen.containsKey(task.id) || picked.contains(task.id),
                    onSelected: (_) {
                      if (widget.onPick != null) {
                        if (picked.contains(task.id)) return;
                        setState(() => picked.add(task.id));
                        widget.onPick!(task.id);
                      } else {
                        widget.onToggle?.call(task.id, task.title);
                      }
                    },
                  ),
              ],
            ),
            if (result.total > taskPageSize)
              PageButtons(
                page: page,
                total: result.total,
                onPage: (value) => _reload(nextPage: value),
              ),
          ],
        );
      },
    );
  }
}

class _DestinationDialog extends StatefulWidget {
  const _DestinationDialog({required this.client, required this.projectId, required this.currentId});

  final SupabaseClient client;
  final String projectId;
  final String currentId;

  @override
  State<_DestinationDialog> createState() => _DestinationDialogState();
}

class _DestinationDialogState extends State<_DestinationDialog> {
  final search = TextEditingController();
  int page = 0;
  Future<({List<SprintRow> rows, int total})>? future;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<({List<SprintRow> rows, int total})> _load() {
    return PlanRepository(widget.client).sprints(projectId: widget.projectId, statuses: const ['planned', 'active'], search: search.text, page: page);
  }

  void _reload({int? nextPage}) {
    setState(() {
      page = nextPage ?? 0;
      future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    future ??= _load();
    final p = paletteOf(context);
    return AlertDialog(
      title: const Text(Fa.destinationSprint),
      content: SizedBox(
        width: 420,
        height: 360,
        child: FutureBuilder<({List<SprintRow> rows, int total})>(
          future: future,
          builder: (context, snapshot) {
            final result = snapshot.data ?? (rows: const <SprintRow>[], total: 0);
            final rows = result.rows.where((row) => row.id != widget.currentId).toList();
            return ListView(
              children: [
                TextField(
                  controller: search,
                  decoration: InputDecoration(
                    hintText: Fa.searchSprint,
                    isDense: true,
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: AppIconView(AppIcons.search, size: 18, color: p.muted),
                    ),
                  ),
                  onSubmitted: (_) => _reload(),
                ),
                if (snapshot.connectionState == ConnectionState.waiting) const LinearProgressIndicator(),
                for (final row in rows)
                  ListTile(
                    leading: AppIconView(AppIcons.sprint, color: sprintTone(p, row.status)),
                    title: Text(row.name),
                    subtitle: Text('${sprintStatusLabel(row.status)} · ${planRange(row.startDate, row.endDate)}'),
                    onTap: () => Navigator.pop(context, row.id),
                  ),
                if (rows.isEmpty && snapshot.connectionState != ConnectionState.waiting)
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.l),
                    child: Text(Fa.empty, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ),
                if (result.total > taskPageSize)
                  PageButtons(
                    page: page,
                    total: result.total,
                    onPage: (value) => _reload(nextPage: value),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel))],
    );
  }
}

JalaliStamp _stamp(String iso) {
  final day = jalaliOfIso(iso);
  return JalaliStamp(year: day.year, month: day.month, day: day.day);
}
