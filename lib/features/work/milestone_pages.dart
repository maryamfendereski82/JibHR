import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import 'sprint_pages.dart';
import 'widgets/plan_ui.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';

final milestoneListProvider = FutureProvider.family<({List<MilestoneRow> rows, int total}), ({String projectId, String? status, int page})>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (rows: const <MilestoneRow>[], total: 0);
  return PlanRepository(client).milestones(projectId: key.projectId, status: key.status, page: key.page);
});

final milestoneProvider = FutureProvider.family<MilestoneRow?, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return PlanRepository(client).milestone(id);
});

final projectMilestoneCountsProvider = FutureProvider.family<Map<String, PlanCounts>, String>((ref, projectId) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const {};
  return PlanRepository(client).milestoneCounts(projectId);
});

final milestoneTaskProvider = FutureProvider.family<({List<PlanTaskRow> tasks, int total}), ({String milestoneId, int page})>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (tasks: const <PlanTaskRow>[], total: 0);
  return PlanRepository(client).milestoneTasks(milestoneId: key.milestoneId, page: key.page);
});

const _milestoneStatuses = ['upcoming', 'in_progress', 'reached', 'cancelled'];

bool _canManage(WorkspaceSession? session, ProjectRow? project) => canManagePlan(
  manageTasks: session?.can('tasks.manage.project') ?? false,
  editProject: session?.can('projects.edit') ?? false,
  viewAll: session?.can('projects.view.all') ?? false,
  projectManager: project?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
);

double _gutter(BuildContext context) => MediaQuery.sizeOf(context).width < 600 ? AppSpace.l : AppSpace.xxl;

// ==================================================================== list

class MilestoneListPage extends ConsumerStatefulWidget {
  const MilestoneListPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<MilestoneListPage> createState() => _MilestoneListPageState();
}

class _MilestoneListPageState extends ConsumerState<MilestoneListPage> {
  String? status;
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId)).asData?.value;
    final list = ref.watch(milestoneListProvider((projectId: widget.projectId, status: status, page: page)));
    final counts = ref.watch(projectMilestoneCountsProvider(widget.projectId)).asData?.value ?? const <String, PlanCounts>{};
    final manage = _canManage(session, project);
    final p = paletteOf(context);
    final gutter = _gutter(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlanHeader(
          title: Fa.milestones,
          eyebrow: project?.name,
          onBack: () => context.go('/work/p/${widget.projectId}'),
          actions: [
            if (manage)
              FilledButton.icon(
                key: const Key('new-milestone'),
                onPressed: () => _create(context),
                icon: AppIconView(AppIcons.add, color: p.onJade),
                label: const Text(Fa.newMilestone),
              ),
          ],
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpace.s),
          child: Wrap(
            spacing: AppSpace.s,
            runSpacing: AppSpace.s,
            children: [
              for (final item in [null, ..._milestoneStatuses])
                ChoiceChip(
                  key: ValueKey('milestone-filter-${item ?? 'all'}'),
                  showCheckmark: false,
                  label: Text(item == null ? Fa.allItems : milestoneStatusLabel(item)),
                  selected: status == item,
                  onSelected: (_) => setState(() {
                    status = item;
                    page = 0;
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.when(
            skipLoadingOnReload: true,
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: _refresh),
            data: (result) {
              if (result.rows.isEmpty) return const EmptyView(message: Fa.empty);
              return ListView(
                padding: EdgeInsets.fromLTRB(gutter, AppSpace.s, gutter, AppSpace.xxl),
                children: [
                  for (var i = 0; i < result.rows.length; i++)
                    _MilestoneItem(
                      row: result.rows[i],
                      counts: counts[result.rows[i].id] ?? PlanCounts.zero,
                      last: i == result.rows.length - 1,
                      onOpen: () => context.go('/work/p/${widget.projectId}/milestone/${result.rows[i].id}'),
                    ),
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
    ref.invalidate(milestoneListProvider);
    ref.invalidate(projectMilestoneCountsProvider);
  }

  Future<void> _create(BuildContext context) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _MilestoneDialog(projectId: widget.projectId),
    );
    if (created == true) _refresh();
  }
}

/// A timeline row: a dot and rail in the milestone's tone, then the card.
class _MilestoneItem extends StatelessWidget {
  const _MilestoneItem({required this.row, required this.counts, required this.last, required this.onOpen});

  final MilestoneRow row;
  final PlanCounts counts;
  final bool last;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final tone = milestoneTone(p, row.status);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                const SizedBox(height: AppSpace.l),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.surface, width: 2),
                  ),
                ),
                if (!last) Expanded(child: Container(width: 2, color: p.hairline)),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Material(
                color: p.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  key: ValueKey('milestone-${row.id}'),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: onOpen,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpace.l),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                row.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            WorkBadge(label: milestoneStatusLabel(row.status), tone: tone, dense: true),
                          ],
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Row(
                          children: [
                            AppIconView(AppIcons.due, size: 14, color: p.muted),
                            const SizedBox(width: 4),
                            Text('${Fa.targetDate}: ${formatPlanDate(row.targetDate)}', style: text.bodySmall),
                          ],
                        ),
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
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestoneDialog extends ConsumerStatefulWidget {
  const _MilestoneDialog({required this.projectId, this.existing});

  final String projectId;
  final MilestoneRow? existing;

  @override
  ConsumerState<_MilestoneDialog> createState() => _MilestoneDialogState();
}

class _MilestoneDialogState extends ConsumerState<_MilestoneDialog> {
  late final title = TextEditingController(text: widget.existing?.title ?? '');
  late final description = TextEditingController(text: widget.existing?.description ?? '');
  late JalaliStamp target = widget.existing == null ? JalaliStamp.today() : _stamp(widget.existing!.targetDate);
  final chosen = <String, String>{};
  bool busy = false;
  bool tried = false;
  String? error;

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => tried = true);
    if (title.text.trim().isEmpty) return;
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await PlanRepository(client).createMilestone(projectId: widget.projectId, title: title.text, description: description.text, target: target.isoDay, tasks: chosen.keys.toList());
      } else {
        await PlanRepository(client).updateMilestone(MilestoneRow(id: existing.id, title: title.text, description: description.text, targetDate: target.isoDay, status: existing.status));
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
          key: const Key('milestone-title'),
          controller: title,
          autofocus: true,
          onChanged: (_) {
            if (tried) setState(() {});
          },
          decoration: InputDecoration(labelText: Fa.title, errorText: tried && title.text.trim().isEmpty ? Fa.titleRequired : null),
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: description,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: Fa.description, alignLabelWithHint: true),
        ),
        const SizedBox(height: AppSpace.l),
        Text(Fa.targetDate, style: text.labelLarge),
        const SizedBox(height: AppSpace.xs),
        TaskDateField(value: target, onChanged: (value) => setState(() => target = value)),
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
          TaskChooser(projectId: widget.projectId, chosen: chosen, onToggle: (id, name) => setState(() => chosen.containsKey(id) ? chosen.remove(id) : chosen[id] = name)),
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
                  child: Text(widget.existing == null ? Fa.newMilestone : Fa.editMilestone, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
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
                  key: const Key('milestone-submit'),
                  onPressed: busy ? null : _submit,
                  child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade)) : Text(widget.existing == null ? Fa.newMilestone : Fa.save),
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

class MilestoneDetailPage extends ConsumerStatefulWidget {
  const MilestoneDetailPage({super.key, required this.projectId, required this.milestoneId});

  final String projectId;
  final String milestoneId;

  @override
  ConsumerState<MilestoneDetailPage> createState() => _MilestoneDetailPageState();
}

class _MilestoneDetailPageState extends ConsumerState<MilestoneDetailPage> {
  int page = 0;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId)).asData?.value;
    final milestone = ref.watch(milestoneProvider(widget.milestoneId));
    final counts = ref.watch(projectMilestoneCountsProvider(widget.projectId));
    final tasks = ref.watch(milestoneTaskProvider((milestoneId: widget.milestoneId, page: page)));
    final manage = _canManage(session, project);
    return milestone.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: _refresh),
      data: (row) {
        if (row == null) return const EmptyView();
        final live = counts.asData?.value[row.id] ?? PlanCounts.zero;
        final p = paletteOf(context);
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1080;
            final gutter = _gutter(context);
            final summary = _summary(row, live);
            final linked = _tasks(tasks, manage);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlanHeader(
                  title: row.title,
                  eyebrow: '${Fa.milestones} · ${Fa.targetDate}: ${formatPlanDate(row.targetDate)}',
                  badge: WorkBadge(label: milestoneStatusLabel(row.status), tone: milestoneTone(p, row.status), dense: true),
                  onBack: () => context.go('/work/p/${widget.projectId}/milestones'),
                  actions: [
                    if (manage)
                      IconButton(
                        key: const Key('edit-milestone'),
                        tooltip: Fa.editMilestone,
                        onPressed: busy ? null : () => _edit(row),
                        icon: const AppIconView(AppIcons.edit, semanticLabel: Fa.editMilestone),
                      ),
                  ],
                ),
                if (manage) _actionBar(row, gutter),
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
                              child: ListView(padding: EdgeInsetsDirectional.fromSTEB(AppSpace.l, AppSpace.s, gutter, AppSpace.xxl), children: [linked]),
                            ),
                          ],
                        )
                      : ListView(padding: EdgeInsets.fromLTRB(gutter, AppSpace.s, gutter, AppSpace.xxl), children: [...summary, linked]),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The next step in the sequence is primary; the other statuses stay
  /// available as quieter actions, cancel as a danger text action.
  Widget _actionBar(MilestoneRow row, double gutter) {
    final p = paletteOf(context);
    final next = switch (row.status) {
      'upcoming' => 'in_progress',
      'in_progress' => 'reached',
      _ => null,
    };
    final others = [
      for (final s in _milestoneStatuses)
        if (s != row.status && s != next && s != 'cancelled') s,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpace.s),
      child: Wrap(
        spacing: AppSpace.s,
        runSpacing: AppSpace.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (next != null)
            FilledButton.icon(
              key: ValueKey('milestone-to-$next'),
              onPressed: busy ? null : () => _to(next),
              icon: AppIconView(next == 'reached' ? AppIcons.approve : AppIcons.milestone, size: 18, color: p.onJade),
              label: Text('${Fa.milestoneStatusTo} «${milestoneStatusLabel(next)}»'),
            ),
          for (final s in others) OutlinedButton(key: ValueKey('milestone-to-$s'), onPressed: busy ? null : () => _to(s), child: Text(milestoneStatusLabel(s))),
          if (row.status != 'cancelled')
            TextButton.icon(
              key: const Key('cancel-milestone'),
              onPressed: busy ? null : _cancel,
              icon: AppIconView(AppIcons.close, size: 18, color: p.danger),
              label: Text(Fa.cancelPlan, style: TextStyle(color: p.danger)),
            ),
        ],
      ),
    );
  }

  List<Widget> _summary(MilestoneRow row, PlanCounts live) {
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
    ];
  }

  Widget _tasks(AsyncValue<({List<PlanTaskRow> tasks, int total})> tasks, bool manage) {
    final text = Theme.of(context).textTheme;
    return PlanCard(
      title: Fa.totalTasks,
      icon: AppIcons.list,
      trailing: manage
          ? TextButton.icon(key: const Key('milestone-add-task'), onPressed: busy ? null : _addTasks, icon: const AppIconView(AppIcons.add, size: 18), label: const Text(Fa.addToPlan))
          : null,
      child: tasks.when(
        skipLoadingOnReload: true,
        loading: () => const LinearProgressIndicator(),
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
                key: ValueKey('milestone-task-${task.id}'),
                task: task,
                onOpen: () => context.go('/work/t/${task.id}'),
                actions: manage ? [(label: Fa.unlinkTask, icon: AppIcons.close, onTap: busy ? null : () => _run(() => _repo.unlinkTask(widget.milestoneId, task.id)), danger: true)] : const [],
              ),
            if (result.total > taskPageSize) PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
          ],
        ),
      ),
    );
  }

  PlanRepository get _repo => PlanRepository(ref.read(supabaseClientProvider)!);

  Future<void> _edit(MilestoneRow row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MilestoneDialog(projectId: widget.projectId, existing: row),
    );
    if (saved == true) _refresh();
  }

  Future<void> _addTasks() async {
    await showPlanDialog<void>(
      context,
      title: Fa.addToPlan,
      body: (context) => TaskChooser(projectId: widget.projectId, onPick: (id) => _run(() => _repo.linkTask(widget.milestoneId, id))),
      actions: (context) => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.close))],
    );
  }

  Future<void> _to(String status) => status == 'reached' ? _reach() : _status(status);

  Future<void> _cancel() async {
    final answer = await askDecision(context, title: Fa.cancelMilestoneConfirm, reasonRequired: false);
    if (answer != null) await _status('cancelled');
  }

  Future<void> _status(String status) => _run(() => _repo.setMilestoneStatus(widget.milestoneId, status));

  /// Unchanged flow: a refused "reached" asks for the audited override reason.
  Future<void> _reach() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await PlanRepository(client).setMilestoneStatus(widget.milestoneId, 'reached');
      _refresh();
    } catch (error) {
      if (!error.toString().contains('tasks_incomplete') || !mounted) {
        _toast(taskErrorText(error));
      } else {
        final reason = await askDecision(context, title: Fa.overrideComplete, reasonRequired: true);
        if (reason != null) {
          try {
            await PlanRepository(client).setMilestoneStatus(widget.milestoneId, 'reached', reason: reason);
            _refresh();
          } catch (error) {
            _toast(taskErrorText(error));
          }
        }
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      _refresh();
    } catch (error) {
      _toast(taskErrorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(milestoneProvider(widget.milestoneId));
    ref.invalidate(milestoneListProvider);
    ref.invalidate(projectMilestoneCountsProvider);
    ref.invalidate(milestoneTaskProvider);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

JalaliStamp _stamp(String iso) {
  final day = jalaliOfIso(iso);
  return JalaliStamp(year: day.year, month: day.month, day: day.day);
}
