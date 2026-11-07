import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'plan_repository.dart';
import 'project_pages.dart';
import 'work_repository.dart';
import 'work_rules.dart';

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
  return PlanRepository(client).sprintTasks(
    sprintId: query.sprintId,
    history: query.history,
    statusId: query.statusId,
    priority: query.priority,
    assigneeId: query.assigneeId,
    page: query.page,
  );
});

final sprintBreakdownProvider = FutureProvider.family<List<PlanBreakdown>, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  return PlanRepository(client).sprintBreakdown(id);
});

class PlanProgressBar extends StatelessWidget {
  const PlanProgressBar({super.key, required this.label, required this.complete, required this.total});

  final String label;
  final int complete;
  final int total;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final percent = progressPercent(complete, total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label ${persianDigits(percent)}٪'),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: total <= 0 ? 0 : complete / total,
            minHeight: 8,
            backgroundColor: palette.stroke,
            color: palette.jade,
          ),
        ),
      ],
    );
  }
}

class SprintListPage extends ConsumerStatefulWidget {
  const SprintListPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<SprintListPage> createState() => _SprintListPageState();
}

class _SprintListPageState extends ConsumerState<SprintListPage> {
  final name = TextEditingController();
  final description = TextEditingController();
  final chosen = <String, String>{};
  late JalaliStamp start = JalaliStamp.today();
  late JalaliStamp end = JalaliStamp.today();
  int page = 0;
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    final list = ref.watch(sprintListProvider((projectId: widget.projectId, page: page)));
    final counts = ref.watch(projectSprintCountsProvider(widget.projectId));
    final manage = canManagePlan(
      manageTasks: session?.can('tasks.manage.project') ?? false,
      editProject: session?.can('projects.edit') ?? false,
      viewAll: session?.can('projects.view.all') ?? false,
      projectManager: project.asData?.value?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
    );
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    final form = manage
        ? _SprintForm(
            name: name,
            description: description,
            start: start,
            end: end,
            projectId: widget.projectId,
            chosen: chosen,
            busy: busy,
            onStart: (value) => setState(() => start = value),
            onEnd: (value) => setState(() => end = value),
            onToggle: (id, title) => setState(() {
              if (!chosen.containsKey(id)) {
                chosen[id] = title;
              } else {
                chosen.remove(id);
              }
            }),
            onSubmit: _create,
          )
        : const SizedBox.shrink();
    final cards = list.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
      error: (error, _) => inlinePlanError(error, _refresh),
      data: (result) => _SprintCards(
        rows: result.rows,
        total: result.total,
        page: page,
        counts: counts.asData?.value ?? const {},
        onPage: (value) => setState(() => page = value),
        onOpen: (id) => context.go('/work/p/${widget.projectId}/sprint/$id'),
      ),
    );
    return Column(
      children: [
        PlanHeader(title: Fa.sprints, onBack: () => context.go('/work/p/${widget.projectId}')),
        Expanded(
          child: wide
              ? Row(
                  children: [
                    SizedBox(width: 420, child: ListView(padding: const EdgeInsets.all(16), children: [form])),
                    Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [cards])),
                  ],
                )
              : ListView(padding: const EdgeInsets.all(16), children: [form, cards]),
        ),
      ],
    );
  }

  void _refresh() {
    ref.invalidate(sprintListProvider);
    ref.invalidate(projectSprintCountsProvider);
  }

  Future<void> _create() async {
    if (!sprintRangeValid(start.isoDay, end.isoDay)) {
      _toast(Fa.invalidRange);
      return;
    }
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await PlanRepository(client).createSprint(
        projectId: widget.projectId,
        name: name.text,
        description: description.text,
        start: start.isoDay,
        end: end.isoDay,
        tasks: chosen.keys.toList(),
      );
      name.clear();
      description.clear();
      chosen.clear();
      _refresh();
    } catch (error) {
      _toast(taskErrorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class SprintDetailPage extends ConsumerStatefulWidget {
  const SprintDetailPage({super.key, required this.projectId, required this.sprintId});

  final String projectId;
  final String sprintId;

  @override
  ConsumerState<SprintDetailPage> createState() => _SprintDetailPageState();
}

class _SprintDetailPageState extends ConsumerState<SprintDetailPage> {
  final name = TextEditingController();
  final description = TextEditingController();
  JalaliStamp? start;
  JalaliStamp? end;
  String? statusId;
  String? priority;
  String? assigneeId;
  int page = 0;
  int historyPage = 0;
  bool busy = false;
  bool seeded = false;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    final sprint = ref.watch(sprintProvider(widget.sprintId));
    final counts = ref.watch(projectSprintCountsProvider(widget.projectId));
    final breakdown = ref.watch(sprintBreakdownProvider(widget.sprintId));
    final tasks = ref.watch(sprintTaskProvider((
      sprintId: widget.sprintId,
      history: false,
      statusId: statusId,
      priority: priority,
      assigneeId: assigneeId,
      page: page,
    )));
    final history = ref.watch(sprintTaskProvider((
      sprintId: widget.sprintId,
      history: true,
      statusId: null,
      priority: null,
      assigneeId: null,
      page: historyPage,
    )));
    final manage = canManagePlan(
      manageTasks: session?.can('tasks.manage.project') ?? false,
      editProject: session?.can('projects.edit') ?? false,
      viewAll: session?.can('projects.view.all') ?? false,
      projectManager: project.asData?.value?.members.any((member) => member.profileId == session?.profileId && member.role == 'manager') ?? false,
    );
    return sprint.when(
      loading: () => const LoadingView(),
      error: (error, _) => inlinePlanError(error, _refresh),
      data: (row) {
        if (row == null) return const EmptyView();
        _seed(row);
        final live = counts.asData?.value[row.id] ?? PlanCounts.zero;
        final wide = MediaQuery.sizeOf(context).width >= 1080;
        final summary = _summary(row, live, breakdown.asData?.value ?? const [], manage);
        final taskList = _taskColumn(row, tasks, history, manage, project.asData?.value);
        return Column(
          children: [
            PlanHeader(title: row.name, onBack: () => context.go('/work/p/${widget.projectId}/sprints')),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 420, child: ListView(padding: const EdgeInsets.all(16), children: summary)),
                        Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [taskList])),
                      ],
                    )
                  : ListView(padding: const EdgeInsets.all(16), children: [...summary, taskList]),
            ),
          ],
        );
      },
    );
  }

  void _seed(SprintRow row) {
    if (seeded) return;
    seeded = true;
    name.text = row.name;
    description.text = row.description;
    start = _stamp(row.startDate);
    end = _stamp(row.endDate);
  }

  List<Widget> _summary(SprintRow row, PlanCounts live, List<PlanBreakdown> groups, bool manage) {
    final editable = manage && row.status != 'closed' && row.status != 'cancelled';
    return [
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${sprintStatusLabel(row.status)} · ${formatPlanDate(row.startDate)} – ${formatPlanDate(row.endDate)}'),
            if (row.description.isNotEmpty) Text(row.description),
            const SizedBox(height: 12),
            PlanProgressBar(label: Fa.currentProgress, complete: live.complete, total: live.total),
            const SizedBox(height: 8),
            Text('${Fa.totalTasks}: ${persianDigits(live.total)}'),
            Text('${Fa.completedTasks}: ${persianDigits(live.complete)}'),
            Text('${Fa.remainingTasks}: ${persianDigits(live.remaining)}'),
            Text('${Fa.blockedTasks}: ${persianDigits(live.blocked)}'),
            Text('${Fa.pendingTasks}: ${persianDigits(live.pending)}'),
            if (row.summary != null) ...[
              const SizedBox(height: 12),
              Text(Fa.sprintSummary, style: Theme.of(context).textTheme.titleMedium),
              PlanProgressBar(label: Fa.sprintSummary, complete: row.summary!.complete, total: row.summary!.total),
              Text('${Fa.completedTasks}: ${persianDigits(row.summary!.complete)}'),
              Text('${Fa.remainingTasks}: ${persianDigits(row.summary!.remaining)}'),
              Text('${Fa.blockedTasks}: ${persianDigits(row.summary!.blocked)}'),
            ],
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (groups.isNotEmpty) _groups(groups),
      if (editable && start != null && end != null) ...[
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: Fa.title)),
              TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
              JalaliStampField(value: start!, onChanged: (value) => setState(() => start = value), withTime: false),
              JalaliStampField(value: end!, onChanged: (value) => setState(() => end = value), withTime: false),
              const SizedBox(height: 8),
              AppButton(label: Fa.save, busy: busy, onPressed: () => _save(row)),
            ],
          ),
        ),
      ],
      if (manage) ...[
        const SizedBox(height: 12),
        if (row.status == 'planned') AppButton(label: Fa.activateSprint, busy: busy, onPressed: () => _status('active')),
        if (row.status == 'active')
          AppButton(label: Fa.completeSprint, busy: busy, onPressed: () => _close(live)),
        if (row.status == 'planned' || row.status == 'active') ...[
          const SizedBox(height: 8),
          AppButton(label: Fa.cancelPlan, busy: busy, onPressed: () => _status('cancelled')),
        ],
        if (row.status == 'active' || row.status == 'closed') ...[
          const SizedBox(height: 8),
          AppButton(label: Fa.transferRemaining, busy: busy, onPressed: _transfer),
        ],
      ],
    ];
  }

  Widget _groups(List<PlanBreakdown> groups) {
    Widget block(String kind, String title) {
      final rows = groups.where((item) => item.kind == kind).toList();
      if (rows.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              for (final row in rows)
                Text('${kind == 'priority' ? priorityLabel(row.bucket) : row.bucket}: ${persianDigits(row.total)}'),
            ],
          ),
        ),
      );
    }

    return Column(children: [block('status', Fa.byStatus), block('priority', Fa.byPriority), block('assignee', Fa.byAssignee)]);
  }

  Widget _taskColumn(
    SprintRow row,
    AsyncValue<({List<PlanTaskRow> tasks, int total})> tasks,
    AsyncValue<({List<PlanTaskRow> tasks, int total})> history,
    bool manage,
    ProjectRow? project,
  ) {
    final open = manage && row.status != 'closed' && row.status != 'cancelled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (project != null) _filters(project),
        if (open)
          TaskChooser(
            projectId: widget.projectId,
            onPick: (id) => _run(() => PlanRepository(ref.read(supabaseClientProvider)!).moveTask(id, row.id)),
          ),
        tasks.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
          error: (error, _) => inlinePlanError(error, _refresh),
          data: (result) => Column(
            children: [
              for (final task in result.tasks) _taskTile(task, row, open, manage),
              PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(Fa.planHistory, style: Theme.of(context).textTheme.titleMedium),
        history.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
          error: (error, _) => inlinePlanError(error, _refresh),
          data: (result) => Column(
            children: [
              for (final task in result.tasks)
                ListTile(title: Text(task.title), subtitle: Text(task.statusName), onTap: () => context.go('/work/t/${task.id}')),
              PageButtons(page: historyPage, total: result.total, onPage: (value) => setState(() => historyPage = value)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filters(ProjectRow project) {
    return Wrap(
      spacing: 8,
      children: [
        DropdownButtonFormField<String?>(
          initialValue: statusId,
          decoration: const InputDecoration(labelText: Fa.planStatus),
          items: [
            const DropdownMenuItem(value: null, child: Text(Fa.allItems)),
            for (final status in project.workflow?.statuses ?? const <StatusRow>[])
              DropdownMenuItem(value: status.id, child: Text(status.name)),
          ],
          onChanged: (value) => setState(() {
            statusId = value;
            page = 0;
          }),
        ),
        DropdownButtonFormField<String?>(
          initialValue: priority,
          decoration: const InputDecoration(labelText: Fa.priority),
          items: [
            const DropdownMenuItem(value: null, child: Text(Fa.allItems)),
            for (final item in const ['low', 'medium', 'high', 'critical'])
              DropdownMenuItem(value: item, child: Text(priorityLabel(item))),
          ],
          onChanged: (value) => setState(() {
            priority = value;
            page = 0;
          }),
        ),
        DropdownButtonFormField<String?>(
          initialValue: assigneeId,
          decoration: const InputDecoration(labelText: Fa.assignee),
          items: [
            const DropdownMenuItem(value: null, child: Text(Fa.allItems)),
            for (final member in project.members) DropdownMenuItem(value: member.profileId, child: Text(member.name)),
          ],
          onChanged: (value) => setState(() {
            assigneeId = value;
            page = 0;
          }),
        ),
      ],
    );
  }

  Widget _taskTile(PlanTaskRow task, SprintRow row, bool open, bool manage) {
    return GlassCard(
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
          if (open)
            Wrap(
              spacing: 8,
              children: [
                TextButton(onPressed: busy ? null : () => _run(() => PlanRepository(ref.read(supabaseClientProvider)!).removeTask(task.id, row.id)), child: const Text(Fa.removeFromSprint)),
                TextButton(onPressed: busy ? null : () => _move(task.id), child: const Text(Fa.moveTask)),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _save(SprintRow row) async {
    final nextStart = start;
    final nextEnd = end;
    if (nextStart == null || nextEnd == null || !sprintRangeValid(nextStart.isoDay, nextEnd.isoDay)) {
      _toast(Fa.invalidRange);
      return;
    }
    await _run(() => PlanRepository(ref.read(supabaseClientProvider)!).updateSprint(SprintRow(
          id: row.id,
          name: name.text,
          description: description.text,
          startDate: nextStart.isoDay,
          endDate: nextEnd.isoDay,
          status: row.status,
        )));
  }

  Future<void> _status(String status) => _run(() => PlanRepository(ref.read(supabaseClientProvider)!).setSprintStatus(widget.sprintId, status));

  Future<void> _close(PlanCounts live) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Fa.completeSprint),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${Fa.completedTasks}: ${persianDigits(live.complete)}'),
            Text('${Fa.remainingTasks}: ${persianDigits(live.remaining)}'),
            Text('${Fa.blockedTasks}: ${persianDigits(live.blocked)}'),
            Text('${persianDigits(live.percent)}٪'),
            const SizedBox(height: 8),
            const Text(Fa.completeConfirm),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fa.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text(Fa.completeSprint)),
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
      _toast(taskErrorText(error));
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

}

Widget inlinePlanError(Object error, VoidCallback onRetry) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(taskErrorText(error), textAlign: TextAlign.center),
      TextButton(onPressed: onRetry, child: const Text(Fa.retry)),
    ],
  );
}

class _SprintForm extends StatelessWidget {
  const _SprintForm({
    required this.name,
    required this.description,
    required this.start,
    required this.end,
    required this.projectId,
    required this.chosen,
    required this.busy,
    required this.onStart,
    required this.onEnd,
    required this.onToggle,
    required this.onSubmit,
  });

  final TextEditingController name;
  final TextEditingController description;
  final JalaliStamp start;
  final JalaliStamp end;
  final String projectId;
  final Map<String, String> chosen;
  final bool busy;
  final ValueChanged<JalaliStamp> onStart;
  final ValueChanged<JalaliStamp> onEnd;
  final void Function(String id, String title) onToggle;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Fa.newSprint, style: Theme.of(context).textTheme.titleMedium),
          TextField(controller: name, decoration: const InputDecoration(labelText: Fa.title)),
          TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
          Text(Fa.startDate),
          JalaliStampField(value: start, onChanged: onStart, withTime: false),
          Text(Fa.endDate),
          JalaliStampField(value: end, onChanged: onEnd, withTime: false),
          const SizedBox(height: 8),
          Text(Fa.initialTasks),
          Wrap(spacing: 8, children: [for (final entry in chosen.entries) InputChip(label: Text(entry.value), onDeleted: () => onToggle(entry.key, entry.value))]),
          TaskChooser(projectId: projectId, chosen: chosen, onToggle: onToggle),
          const SizedBox(height: 8),
          AppButton(label: Fa.newSprint, busy: busy, onPressed: onSubmit),
        ],
      ),
    );
  }
}

class _SprintCards extends StatelessWidget {
  const _SprintCards({
    required this.rows,
    required this.total,
    required this.page,
    required this.counts,
    required this.onPage,
    required this.onOpen,
  });

  final List<SprintRow> rows;
  final int total;
  final int page;
  final Map<String, PlanCounts> counts;
  final ValueChanged<int> onPage;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text(Fa.empty);
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              padding: const EdgeInsets.all(12),
              child: InkWell(
                onTap: () => onOpen(row.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.name, style: Theme.of(context).textTheme.titleMedium),
                    Text('${sprintStatusLabel(row.status)} · ${formatPlanDate(row.startDate)} – ${formatPlanDate(row.endDate)}'),
                    const SizedBox(height: 8),
                    PlanProgressBar(
                      label: Fa.currentProgress,
                      complete: (counts[row.id] ?? PlanCounts.zero).complete,
                      total: (counts[row.id] ?? PlanCounts.zero).total,
                    ),
                    Text('${Fa.totalTasks}: ${persianDigits((counts[row.id] ?? PlanCounts.zero).total)} · ${Fa.completedTasks}: ${persianDigits((counts[row.id] ?? PlanCounts.zero).complete)} · ${Fa.remainingTasks}: ${persianDigits((counts[row.id] ?? PlanCounts.zero).remaining)}'),
                  ],
                ),
              ),
            ),
          ),
        PageButtons(page: page, total: total, onPage: onPage),
      ],
    );
  }
}

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
    return WorkRepository(client).tasks((
      projectId: widget.projectId,
      personal: false,
      assigneeId: null,
      statusId: null,
      priority: null,
      search: search.text,
      dueFrom: null,
      dueTo: null,
      page: page,
      sort: 'title',
    ));
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
    return FutureBuilder<TaskPage>(
      future: future,
      builder: (context, snapshot) {
        final result = snapshot.data ?? TaskPage.empty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: search,
              decoration: const InputDecoration(labelText: Fa.searchTasks),
              onSubmitted: (_) => _reload(),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final task in result.tasks)
                  FilterChip(
                    label: Text(task.title),
                    selected: widget.chosen.containsKey(task.id),
                    onSelected: (_) {
                      if (widget.onPick != null) {
                        widget.onPick!(task.id);
                      } else {
                        widget.onToggle?.call(task.id, task.title);
                      }
                    },
                  ),
              ],
            ),
            PageButtons(page: page, total: result.total, onPage: (value) => _reload(nextPage: value)),
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
    return PlanRepository(widget.client).sprints(
      projectId: widget.projectId,
      statuses: const ['planned', 'active'],
      search: search.text,
      page: page,
    );
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
                  decoration: const InputDecoration(labelText: Fa.searchSprint),
                  onSubmitted: (_) => _reload(),
                ),
                for (final row in rows)
                  ListTile(title: Text(row.name), subtitle: Text(sprintStatusLabel(row.status)), onTap: () => Navigator.pop(context, row.id)),
                if (rows.isEmpty) const Text(Fa.empty),
                PageButtons(page: page, total: result.total, onPage: (value) => _reload(nextPage: value)),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel))],
    );
  }
}

class PlanHeader extends StatelessWidget {
  const PlanHeader({super.key, required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          IconButton(tooltip: Fa.back, onPressed: onBack, icon: const Icon(Icons.arrow_forward)),
        ],
      ),
    );
  }
}

JalaliStamp _stamp(String iso) {
  final parts = iso.split('-');
  if (parts.length < 3) return JalaliStamp.today();
  final date = DateTime.utc(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]), 12);
  final jalali = TehranTime.jalali(date);
  return JalaliStamp(year: jalali.year, month: jalali.month, day: jalali.day);
}
