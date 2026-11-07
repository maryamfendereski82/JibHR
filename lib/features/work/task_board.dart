import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'project_pages.dart';
import 'task_detail.dart';
import 'work_repository.dart';
import 'work_rules.dart';

final taskPageProvider = FutureProvider.family<TaskPage, TaskFilter>((ref, filter) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return TaskPage.empty;
  return WorkRepository(client).tasks(filter);
});

final personalWorkflowProvider = FutureProvider<WorkflowRow?>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return WorkRepository(client).personalWorkflow();
});

class TaskBoardPage extends ConsumerStatefulWidget {
  const TaskBoardPage({super.key, this.projectId, this.personal = false, this.mine = false});

  final String? projectId;
  final bool personal;
  final bool mine;

  @override
  ConsumerState<TaskBoardPage> createState() => _TaskBoardPageState();
}

class _TaskBoardPageState extends ConsumerState<TaskBoardPage> {
  String view = 'kanban';
  String search = '';
  String? priority;
  String? assigneeId;
  String? statusId;
  String sort = 'updated_at';
  int page = 0;
  final columnPages = <String, int>{};
  String? selectedId;
  bool busy = false;
  late Jalali month = TehranTime.jalali(DateTime.now().toUtc());

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = widget.projectId == null ? null : ref.watch(projectProvider(widget.projectId!));
    final personalFlow = widget.personal ? ref.watch(personalWorkflowProvider) : null;
    final statuses = widget.personal
        ? personalFlow?.asData?.value?.statuses ?? const <StatusRow>[]
        : (project?.asData?.value?.workflow?.statuses.where((status) => status.active).toList() ?? const <StatusRow>[]);
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    final title = widget.mine
        ? Fa.myTasks
        : widget.personal
            ? Fa.personalTasks
            : project?.asData?.value?.name ?? Fa.projects;
    final board = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: Fa.back, onPressed: () => context.go('/work'), icon: const Icon(Icons.arrow_forward)),
              if (widget.projectId != null) ...[
                IconButton(tooltip: Fa.sprints, onPressed: () => context.go('/work/p/${widget.projectId}/sprints'), icon: const Icon(Icons.flag_outlined)),
                IconButton(tooltip: Fa.milestones, onPressed: () => context.go('/work/p/${widget.projectId}/milestones'), icon: const Icon(Icons.outlined_flag)),
              ],
              if (widget.projectId != null && session?.can('projects.edit') == true)
                IconButton(tooltip: Fa.settings, onPressed: () => context.go('/work/p/${widget.projectId}/settings'), icon: const Icon(Icons.tune)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!widget.mine)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'kanban', label: Text(Fa.kanban)),
                    ButtonSegment(value: 'list', label: Text(Fa.taskList)),
                    ButtonSegment(value: 'calendar', label: Text(Fa.calendar)),
                  ],
                  selected: {view},
                  onSelectionChanged: (value) => setState(() => view = value.first),
                )
              else
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'list', label: Text(Fa.taskList)),
                    ButtonSegment(value: 'calendar', label: Text(Fa.calendar)),
                  ],
                  selected: {view == 'kanban' ? 'list' : view},
                  onSelectionChanged: (value) => setState(() => view = value.first),
                ),
              if (_canCreate(session, project?.asData?.value))
                FilledButton(onPressed: busy ? null : () => _create(context, session!, project?.asData?.value), child: const Text(Fa.newTask)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(labelText: Fa.searchTasks),
            onChanged: (value) => setState(() {
              search = value;
              page = 0;
              columnPages.clear();
            }),
          ),
        ),
        Expanded(child: _body(statuses, session)),
      ],
    );
    if (wide && selectedId != null && !widget.mine) {
      return Row(
        children: [
          Expanded(child: board),
          const VerticalDivider(width: 1),
          SizedBox(width: 440, child: TaskDetailPage(taskId: selectedId!, embedded: true, onClose: () => setState(() => selectedId = null))),
        ],
      );
    }
    return board;
  }

  Widget _body(List<StatusRow> statuses, WorkspaceSession? session) {
    final currentView = widget.mine && view == 'kanban' ? 'list' : view;
    if (currentView == 'list') return _list();
    if (currentView == 'calendar') return _calendar();
    if (statuses.isEmpty) return const LoadingView();
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(16),
      children: [
        for (final status in statuses)
          SizedBox(
            width: 300,
            child: _Column(
              title: status.name,
              filter: _filter(statusId: status.id, page: columnPages[status.id] ?? 0),
              busy: busy,
              onOpen: _open,
              onDrop: (taskId) => _move(taskId, status.id),
              onPage: (value) => setState(() => columnPages[status.id] = value),
            ),
          ),
      ],
    );
  }

  Widget _list() {
    final result = ref.watch(taskPageProvider(_filter(page: page)));
    return result.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskPageProvider(_filter(page: page)))),
      data: (pageData) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: sort,
            decoration: const InputDecoration(labelText: Fa.taskList),
            items: const [
              DropdownMenuItem(value: 'updated_at', child: Text('آخرین تغییر')),
              DropdownMenuItem(value: 'due_at', child: Text(Fa.dueDate)),
              DropdownMenuItem(value: 'title', child: Text(Fa.title)),
              DropdownMenuItem(value: 'priority_rank', child: Text('اولویت')),
            ],
            onChanged: (value) => setState(() {
              sort = value ?? 'updated_at';
              page = 0;
            }),
          ),
          DropdownButtonFormField<String?>(
            initialValue: priority,
            decoration: const InputDecoration(labelText: 'اولویت'),
            items: const [
              DropdownMenuItem(value: null, child: Text(Fa.allStatuses)),
              DropdownMenuItem(value: 'low', child: Text(Fa.priorityLow)),
              DropdownMenuItem(value: 'medium', child: Text(Fa.priorityMedium)),
              DropdownMenuItem(value: 'high', child: Text(Fa.priorityHigh)),
              DropdownMenuItem(value: 'critical', child: Text(Fa.priorityCritical)),
            ],
            onChanged: (value) => setState(() {
              priority = value;
              page = 0;
            }),
          ),
          if (pageData.tasks.isEmpty) const EmptyView(),
          for (final task in pageData.tasks) TaskTile(task: task, onTap: () => _open(task.id)),
          PageButtons(page: page, total: pageData.total, onPage: (value) => setState(() => page = value)),
        ],
      ),
    );
  }

  Widget _calendar() {
    final start = TehranTime.toUtcFromJalali(month.year, month.month, 1, 0, 0);
    final nextMonth = month.month == 12 ? Jalali(month.year + 1, 1, 1) : Jalali(month.year, month.month + 1, 1);
    final end = TehranTime.toUtcFromJalali(nextMonth.year, nextMonth.month, 1, 0, 0);
    final result = ref.watch(taskPageProvider(_filter(
      page: page,
      dueFrom: start.toIso8601String(),
      dueTo: end.toIso8601String(),
    )));
    return result.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskPageProvider)),
      data: (pageData) {
        final cells = _monthCells(month);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => setState(() {
                    month = month.month == 1 ? Jalali(month.year - 1, 12, 1) : Jalali(month.year, month.month - 1, 1);
                    page = 0;
                  }),
                  icon: const Icon(Icons.chevron_right),
                ),
                Expanded(child: Text('${jalaliMonths[month.month - 1]} ${persianDigits(month.year)}', textAlign: TextAlign.center)),
                IconButton(
                  onPressed: () => setState(() {
                    month = nextMonth;
                    page = 0;
                  }),
                  icon: const Icon(Icons.chevron_left),
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 0.8,
              children: [
                for (final cell in cells)
                  if (cell == null)
                    const SizedBox.shrink()
                  else
                    _DayTasks(
                      day: cell,
                      tasks: pageData.tasks.where((task) => dueOnJalaliDay(task.dueAt, cell.year, cell.month, cell.day)).toList(),
                      onOpen: _open,
                    ),
              ],
            ),
            PageButtons(page: page, total: pageData.total, onPage: (value) => setState(() => page = value)),
          ],
        );
      },
    );
  }

  TaskFilter _filter({String? statusId, int? page, String? dueFrom, String? dueTo}) {
    final session = ref.read(workspaceSessionProvider).asData?.value;
    return (
      projectId: widget.projectId,
      personal: widget.personal,
      assigneeId: widget.mine ? session?.profileId : assigneeId,
      statusId: statusId ?? (view == 'list' ? this.statusId : null),
      priority: priority,
      search: search,
      dueFrom: dueFrom,
      dueTo: dueTo,
      page: page ?? 0,
      sort: view == 'calendar' ? 'due_at' : sort,
    );
  }

  bool _canCreate(WorkspaceSession? session, ProjectRow? project) {
    if (session == null || widget.mine) return false;
    if (widget.personal) return session.can('tasks.create.personal');
    if (!session.can('tasks.create.project') || project == null) return false;
    return session.can('projects.view.all') || project.members.any((member) => member.profileId == session.profileId && member.role == 'manager');
  }

  void _open(String id) {
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    if (wide && !widget.mine) {
      setState(() => selectedId = id);
    } else {
      context.go('/work/t/$id');
    }
  }

  Future<void> _move(String taskId, String statusId) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await WorkRepository(client).transition(taskId, statusId);
      _refresh();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
      _refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create(BuildContext context, WorkspaceSession session, ProjectRow? project) async {
    final draft = await showDialog<_Draft>(
      context: context,
      builder: (context) => _CreateTaskDialog(project: project, personal: widget.personal, selfId: session.profileId),
    );
    final client = ref.read(supabaseClientProvider);
    if (draft == null || client == null) return;
    setState(() => busy = true);
    try {
      final id = await WorkRepository(client).createTask(
        title: draft.title,
        description: draft.description,
        projectId: widget.projectId,
        assigneeId: draft.assigneeId,
        priority: draft.priority,
        dueIso: draft.due?.toUtc().toIso8601String(),
        approval: widget.personal ? draft.approval : (draft.approval == project?.approvalRequired ? null : draft.approval),
        reviewerId: draft.reviewerId,
      );
      _refresh();
      if (!context.mounted) return;
      _open(id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _refresh() => ref.invalidate(taskPageProvider);
}

class _Column extends ConsumerWidget {
  const _Column({
    required this.title,
    required this.filter,
    required this.busy,
    required this.onOpen,
    required this.onDrop,
    required this.onPage,
  });

  final String title;
  final TaskFilter filter;
  final bool busy;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onDrop;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(taskPageProvider(filter));
    final palette = paletteOf(context);
    return DragTarget<String>(
      onAcceptWithDetails: busy ? null : (details) => onDrop(details.data),
      builder: (context, candidate, rejected) {
        return Padding(
          padding: const EdgeInsetsDirectional.only(end: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: candidate.isEmpty ? palette.card : palette.jade.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.stroke),
            ),
            child: page.when(
              loading: () => const LoadingView(),
              error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskPageProvider(filter))),
              data: (result) => ListView(
                padding: const EdgeInsets.all(10),
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(persianDigits(result.total), style: TextStyle(color: palette.muted)),
                  for (final task in result.tasks)
                    Draggable<String>(
                      data: task.id,
                      feedback: Material(child: SizedBox(width: 260, child: TaskTile(task: task, onTap: () {}))),
                      childWhenDragging: Opacity(opacity: 0.4, child: TaskTile(task: task, onTap: () => onOpen(task.id))),
                      child: TaskTile(task: task, onTap: () => onOpen(task.id)),
                    ),
                  PageButtons(page: filter.page, total: result.total, onPage: onPage),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task, required this.onTap});

  final TaskRow task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final tone = switch (task.priority) {
      'critical' => palette.danger,
      'high' => palette.warning,
      'low' => palette.muted,
      _ => palette.jade,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${priorityLabel(task.priority)} · ${task.assigneeName}', style: TextStyle(color: tone)),
              if (task.projectName != null) Text(task.projectName!),
              if (task.collaborators.isNotEmpty) Text('${Fa.collaborators}: ${task.collaborators.map((person) => person.name).join('، ')}'),
              if (task.labels.isNotEmpty) Text(task.labels.map((label) => label.name).join(' · ')),
              if (task.dueLabel.isNotEmpty) Text('${Fa.dueDate} ${task.dueLabel}'),
              Text(task.statusName),
              if (task.approvalRequired) Text(approvalLabel(task.approvalState), style: TextStyle(color: palette.warning)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayTasks extends StatelessWidget {
  const _DayTasks({required this.day, required this.tasks, required this.onOpen});

  final Jalali day;
  final List<TaskRow> tasks;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(persianDigits(day.day)),
        for (final task in tasks.take(2))
          InkWell(
            key: ValueKey('due-${day.day}-${task.priority}'),
            onTap: () => onOpen(task.id),
            child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: paletteOf(context).jade)),
          ),
      ],
    );
  }
}

class _Draft {
  const _Draft({
    required this.title,
    required this.description,
    required this.assigneeId,
    required this.priority,
    required this.approval,
    this.reviewerId,
    this.due,
  });

  final String title;
  final String description;
  final String assigneeId;
  final String priority;
  final bool approval;
  final String? reviewerId;
  final DateTime? due;
}

class _CreateTaskDialog extends ConsumerStatefulWidget {
  const _CreateTaskDialog({required this.project, required this.personal, required this.selfId});

  final ProjectRow? project;
  final bool personal;
  final String selfId;

  @override
  ConsumerState<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

class _CreateTaskDialogState extends ConsumerState<_CreateTaskDialog> {
  final title = TextEditingController();
  final description = TextEditingController();
  final peopleSearch = TextEditingController();
  late String assigneeId = widget.selfId;
  String? reviewerId;
  String priority = 'medium';
  late bool approval = widget.project?.approvalRequired ?? false;
  bool withDue = false;
  late JalaliStamp due = JalaliStamp.today();

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    peopleSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(peopleProvider(peopleSearch.text));
    final names = people.asData?.value ?? const <NamedPerson>[];
    return AlertDialog(
      title: const Text(Fa.newTask),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: Fa.title),
              onChanged: (_) => setState(() {}),
            ),
            TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
            TextField(
              controller: peopleSearch,
              decoration: const InputDecoration(labelText: Fa.peopleHint),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
              initialValue: assigneeId,
              decoration: const InputDecoration(labelText: Fa.assignee),
              items: [
                DropdownMenuItem(value: widget.selfId, child: const Text(Fa.assignee)),
                if (assigneeId != widget.selfId)
                  DropdownMenuItem(value: assigneeId, child: Text(assigneeId)),
                for (final person in names)
                  if (person.id != widget.selfId && person.id != assigneeId)
                    DropdownMenuItem(value: person.id, child: Text(person.name)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => assigneeId = value);
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: priority,
              decoration: const InputDecoration(labelText: 'اولویت'),
              items: const [
                DropdownMenuItem(value: 'low', child: Text(Fa.priorityLow)),
                DropdownMenuItem(value: 'medium', child: Text(Fa.priorityMedium)),
                DropdownMenuItem(value: 'high', child: Text(Fa.priorityHigh)),
                DropdownMenuItem(value: 'critical', child: Text(Fa.priorityCritical)),
              ],
              onChanged: (value) => setState(() => priority = value ?? 'medium'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fa.dueDate),
              value: withDue,
              onChanged: (value) => setState(() => withDue = value),
            ),
            if (withDue) JalaliStampField(value: due, withTime: false, onChanged: (value) => setState(() => due = value)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fa.approvalRequired),
              value: approval,
              onChanged: (value) => setState(() => approval = value),
            ),
            DropdownButtonFormField<String?>(
              initialValue: names.any((person) => person.id == reviewerId) ? reviewerId : null,
              decoration: const InputDecoration(labelText: Fa.reviewer),
              items: [
                const DropdownMenuItem(value: null, child: Text(Fa.reviewerPool)),
                for (final person in names) DropdownMenuItem(value: person.id, child: Text(person.name)),
              ],
              onChanged: (value) => setState(() => reviewerId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
        FilledButton(
          onPressed: title.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    _Draft(
                      title: title.text,
                      description: description.text,
                      assigneeId: assigneeId,
                      priority: priority,
                      approval: approval,
                      reviewerId: reviewerId,
                      due: withDue ? due.toUtc() : null,
                    ),
                  ),
          child: const Text(Fa.save),
        ),
      ],
    );
  }
}

List<Jalali?> _monthCells(Jalali month) {
  final first = Jalali(month.year, month.month, 1);
  final cells = <Jalali?>[for (var index = 1; index < first.weekDay; index++) null];
  for (var day = 1; day <= first.monthLength; day++) {
    cells.add(Jalali(month.year, month.month, day));
  }
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return cells;
}
