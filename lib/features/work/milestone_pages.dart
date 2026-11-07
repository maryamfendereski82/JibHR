import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'plan_repository.dart';
import 'project_pages.dart';
import 'work_repository.dart';
import 'sprint_pages.dart';
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

class MilestoneListPage extends ConsumerStatefulWidget {
  const MilestoneListPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<MilestoneListPage> createState() => _MilestoneListPageState();
}

class _MilestoneListPageState extends ConsumerState<MilestoneListPage> {
  final title = TextEditingController();
  final description = TextEditingController();
  final chosen = <String, String>{};
  late JalaliStamp target = JalaliStamp.today();
  String? status;
  int page = 0;
  bool busy = false;

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    final list = ref.watch(milestoneListProvider((projectId: widget.projectId, status: status, page: page)));
    final counts = ref.watch(projectMilestoneCountsProvider(widget.projectId));
    final manage = _manage(session, project.asData?.value);
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    final form = manage
        ? GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Fa.newMilestone, style: Theme.of(context).textTheme.titleMedium),
                TextField(controller: title, decoration: const InputDecoration(labelText: Fa.title)),
                TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
                Text(Fa.targetDate),
                JalaliStampField(value: target, onChanged: (value) => setState(() => target = value), withTime: false),
                const SizedBox(height: 8),
                Text(Fa.initialTasks),
                Wrap(spacing: 8, children: [for (final entry in chosen.entries) InputChip(label: Text(entry.value), onDeleted: () => _toggle(entry.key, entry.value))]),
                TaskChooser(projectId: widget.projectId, chosen: chosen, onToggle: _toggle),
                const SizedBox(height: 8),
                AppButton(label: Fa.newMilestone, busy: busy, onPressed: _create),
              ],
            ),
          )
        : const SizedBox.shrink();
    final timeline = list.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
      error: (error, _) => inlinePlanError(error, _refresh),
      data: (result) => _timeline(result.rows, result.total, counts.asData?.value ?? const {}),
    );
    return Column(
      children: [
        PlanHeader(title: Fa.milestones, onBack: () => context.go('/work/p/${widget.projectId}')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final item in [null, 'upcoming', 'in_progress', 'reached', 'cancelled'])
                FilterChip(
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
          child: wide
              ? Row(
                  children: [
                    SizedBox(width: 420, child: ListView(padding: const EdgeInsets.all(16), children: [form])),
                    Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [timeline])),
                  ],
                )
              : ListView(padding: const EdgeInsets.all(16), children: [form, timeline]),
        ),
      ],
    );
  }

  bool _manage(WorkspaceSession? session, ProjectRow? project) {
    return canManagePlan(
      manageTasks: session?.can('tasks.manage.project') ?? false,
      editProject: session?.can('projects.edit') ?? false,
      viewAll: session?.can('projects.view.all') ?? false,
      projectManager: project?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
    );
  }

  void _toggle(String id, String name) {
    setState(() {
      if (!chosen.containsKey(id)) {
        chosen[id] = name;
      } else {
        chosen.remove(id);
      }
    });
  }

  Widget _timeline(List<MilestoneRow> rows, int total, Map<String, PlanCounts> counts) {
    final palette = paletteOf(context);
    if (rows.isEmpty) return const Text(Fa.empty);
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              padding: const EdgeInsets.all(12),
              child: InkWell(
                onTap: () => context.go('/work/p/${widget.projectId}/milestone/${row.id}'),
                child: Row(
                  children: [
                    Container(width: 4, height: 72, color: _tone(palette, row.status)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row.title, style: Theme.of(context).textTheme.titleMedium),
                          Text('${milestoneStatusLabel(row.status)} · ${formatPlanDate(row.targetDate)}'),
                          if (row.description.isNotEmpty) Text(row.description),
                          const SizedBox(height: 8),
                          PlanProgressBar(
                            label: Fa.currentProgress,
                            complete: (counts[row.id] ?? PlanCounts.zero).complete,
                            total: (counts[row.id] ?? PlanCounts.zero).total,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        PageButtons(page: page, total: total, onPage: (value) => setState(() => page = value)),
      ],
    );
  }

  Future<void> _create() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await PlanRepository(client).createMilestone(
        projectId: widget.projectId,
        title: title.text,
        description: description.text,
        target: target.isoDay,
        tasks: chosen.keys.toList(),
      );
      title.clear();
      description.clear();
      chosen.clear();
      _refresh();
    } catch (error) {
      _toast(taskErrorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(milestoneListProvider);
    ref.invalidate(projectMilestoneCountsProvider);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class MilestoneDetailPage extends ConsumerStatefulWidget {
  const MilestoneDetailPage({super.key, required this.projectId, required this.milestoneId});

  final String projectId;
  final String milestoneId;

  @override
  ConsumerState<MilestoneDetailPage> createState() => _MilestoneDetailPageState();
}

class _MilestoneDetailPageState extends ConsumerState<MilestoneDetailPage> {
  final title = TextEditingController();
  final description = TextEditingController();
  JalaliStamp? target;
  int page = 0;
  bool busy = false;
  bool seeded = false;

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    final milestone = ref.watch(milestoneProvider(widget.milestoneId));
    final counts = ref.watch(projectMilestoneCountsProvider(widget.projectId));
    final tasks = ref.watch(milestoneTaskProvider((milestoneId: widget.milestoneId, page: page)));
    final manage = canManagePlan(
      manageTasks: session?.can('tasks.manage.project') ?? false,
      editProject: session?.can('projects.edit') ?? false,
      viewAll: session?.can('projects.view.all') ?? false,
      projectManager: project.asData?.value?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
    );
    return milestone.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: _refresh),
      data: (row) {
        if (row == null) return const EmptyView();
        if (!seeded) {
          seeded = true;
          title.text = row.title;
          description.text = row.description;
          target = _milestoneStamp(row.targetDate);
        }
        final live = counts.asData?.value[row.id] ?? PlanCounts.zero;
        final wide = MediaQuery.sizeOf(context).width >= 1080;
        final summary = _summary(row, live, manage);
        final linked = _tasks(tasks, manage);
        return Column(
          children: [
            PlanHeader(title: row.title, onBack: () => context.go('/work/p/${widget.projectId}/milestones')),
            Expanded(
              child: wide
                  ? Row(
                      children: [
                        SizedBox(width: 420, child: ListView(padding: const EdgeInsets.all(16), children: summary)),
                        Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [linked])),
                      ],
                    )
                  : ListView(padding: const EdgeInsets.all(16), children: [...summary, linked]),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _summary(MilestoneRow row, PlanCounts live, bool manage) {
    return [
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${milestoneStatusLabel(row.status)} · ${formatPlanDate(row.targetDate)}'),
            if (row.description.isNotEmpty) Text(row.description),
            const SizedBox(height: 12),
            PlanProgressBar(label: Fa.currentProgress, complete: live.complete, total: live.total),
            Text('${Fa.completedTasks}: ${persianDigits(live.complete)}'),
            Text('${Fa.pendingTasks}: ${persianDigits(live.pending)}'),
            Text('${Fa.blockedTasks}: ${persianDigits(live.blocked)}'),
            Text('${Fa.totalTasks}: ${persianDigits(live.total)}'),
          ],
        ),
      ),
      if (manage && target != null) ...[
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: Fa.title)),
              TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
              JalaliStampField(value: target!, onChanged: (value) => setState(() => target = value), withTime: false),
              const SizedBox(height: 8),
              AppButton(label: Fa.save, busy: busy, onPressed: () => _save(row)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final item in const ['upcoming', 'in_progress', 'reached', 'cancelled'])
          if (item != row.status)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppButton(
                label: milestoneStatusLabel(item),
                busy: busy,
                onPressed: () => item == 'reached' ? _reach() : _status(item),
              ),
            ),
      ],
    ];
  }

  Widget _tasks(AsyncValue<({List<PlanTaskRow> tasks, int total})> tasks, bool manage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (manage)
          TaskChooser(
            projectId: widget.projectId,
            onPick: (id) => _run(() => PlanRepository(ref.read(supabaseClientProvider)!).linkTask(widget.milestoneId, id)),
          ),
        tasks.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
          error: (error, _) => inlinePlanError(error, _refresh),
          data: (result) => Column(
            children: [
              for (final task in result.tasks)
                GlassCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(task.title),
                        subtitle: Text('${task.statusName} · ${priorityLabel(task.priority)} · ${task.assigneeName}'),
                        onTap: () => context.go('/work/t/${task.id}'),
                      ),
                      if (manage)
                        TextButton(
                          onPressed: busy ? null : () => _run(() => PlanRepository(ref.read(supabaseClientProvider)!).unlinkTask(widget.milestoneId, task.id)),
                          child: const Text(Fa.unlinkTask),
                        ),
                    ],
                  ),
                ),
              PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _save(MilestoneRow row) async {
    final next = target;
    if (next == null) return;
    await _run(() => PlanRepository(ref.read(supabaseClientProvider)!).updateMilestone(MilestoneRow(
          id: row.id,
          title: title.text,
          description: description.text,
          targetDate: next.isoDay,
          status: row.status,
        )));
  }

  Future<void> _status(String status) {
    return _run(() => PlanRepository(ref.read(supabaseClientProvider)!).setMilestoneStatus(widget.milestoneId, status));
  }

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

Color _tone(AppPalette palette, String status) => switch (status) {
      'in_progress' => palette.jade,
      'reached' => palette.muted,
      'cancelled' => palette.danger,
      _ => palette.warning,
    };

JalaliStamp _milestoneStamp(String iso) {
  final parts = iso.split('-');
  if (parts.length < 3) return JalaliStamp.today();
  final date = DateTime.utc(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]), 12);
  final jalali = TehranTime.jalali(date);
  return JalaliStamp(year: jalali.year, month: jalali.month, day: jalali.day);
}
