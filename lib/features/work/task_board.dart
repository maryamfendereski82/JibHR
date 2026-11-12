import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_select.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'milestone_pages.dart';
import 'plan_repository.dart';
import 'project_pages.dart';
import 'sprint_pages.dart';
import 'task_detail.dart';
import 'task_actions.dart';
import 'task_form.dart';
import 'widgets/kanban_board.dart';
import 'widgets/task_card.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';
import 'workflow_presentation.dart';

final taskPageProvider = FutureProvider.family<TaskPage, TaskFilter>((ref, filter) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return TaskPage.empty;
  return WorkRepository(client).tasks(filter);
});

/// Cap of the calendar month read: pages of [taskPageSize] up to this many.
const monthTaskCap = 600;

/// Every task due in a month (all pages of the same filter), so the calendar
/// never drops tasks beyond the first page. [TaskFilter.page] must be 0.
final monthTasksProvider = FutureProvider.family<({List<TaskRow> tasks, bool truncated}), TaskFilter>((ref, filter) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (tasks: const <TaskRow>[], truncated: false);
  final repository = WorkRepository(client);
  final tasks = <TaskRow>[];
  var page = 0;
  var total = 0;
  do {
    final result = await repository.tasks((
      projectId: filter.projectId,
      personal: filter.personal,
      assigneeId: filter.assigneeId,
      statusId: filter.statusId,
      priority: filter.priority,
      search: filter.search,
      dueFrom: filter.dueFrom,
      dueTo: filter.dueTo,
      page: page,
      sort: filter.sort,
    ));
    tasks.addAll(result.tasks);
    total = result.total;
    page++;
  } while (tasks.length < total && tasks.length < monthTaskCap);
  return (tasks: tasks, truncated: tasks.length < total);
});

final personalWorkflowProvider = FutureProvider<WorkflowRow?>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return WorkRepository(client).personalWorkflow();
});

enum DueWindow { any, week, month, past }

String dueWindowLabel(DueWindow window) => switch (window) {
  DueWindow.any => Fa.dueAny,
  DueWindow.week => Fa.dueWeek,
  DueWindow.month => Fa.dueMonth,
  DueWindow.past => Fa.duePast,
};

/// Server-side bounds for a due window. [DueWindow.past] counts every task
/// whose due date has passed, done or not; it is a date filter, not a state.
({String? from, String? to}) dueBounds(DueWindow window, DateTime nowUtc) => switch (window) {
  DueWindow.any => (from: null, to: null),
  DueWindow.week => (from: nowUtc.toIso8601String(), to: nowUtc.add(const Duration(days: 7)).toIso8601String()),
  DueWindow.month => (from: nowUtc.toIso8601String(), to: nowUtc.add(const Duration(days: 30)).toIso8601String()),
  DueWindow.past => (from: null, to: nowUtc.toIso8601String()),
};

const searchDebounce = Duration(milliseconds: 300);

class TaskBoardPage extends ConsumerStatefulWidget {
  const TaskBoardPage({super.key, this.projectId, this.personal = false, this.mine = false});

  final String? projectId;
  final bool personal;
  final bool mine;

  @override
  ConsumerState<TaskBoardPage> createState() => _TaskBoardPageState();
}

class _TaskBoardPageState extends ConsumerState<TaskBoardPage> {
  late String view = widget.mine ? 'list' : 'kanban';
  final _search = TextEditingController();
  Timer? _debounce;
  String search = '';
  String? priority;
  String? assigneeId;
  String? statusId;
  String? projectFilter;
  DueWindow due = DueWindow.any;
  String sort = boardSort;
  int page = 0;
  final columnPages = <String, int>{};
  String? selectedId;

  /// The task the side panel shows; kept while the panel animates closed.
  String? _panelTask;
  bool busy = false;
  final _nav = KanbanNav();
  double _layoutWidth = 0;
  late Jalali month = TehranTime.jalali(DateTime.now().toUtc());
  Jalali? calendarDay;

  /// Due-window bounds are frozen when the window is chosen, so the provider
  /// key does not change on every rebuild.
  DateTime _anchor = DateTime.now().toUtc();

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _nav.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(searchDebounce, () {
      if (!mounted || value.trim() == search) return;
      setState(() {
        search = value.trim();
        page = 0;
        columnPages.clear();
      });
    });
  }

  void _resetPaging() {
    page = 0;
    columnPages.clear();
  }

  /// "My tasks" and "Personal tasks" are both the signed-in person's own
  /// tasks (assignee = me); personal ones are those without a project.
  TaskFilter _filter({String? statusId, int? page, String? dueFrom, String? dueTo, bool calendar = false, bool board = false}) {
    final session = ref.read(workspaceSessionProvider).asData?.value;
    final bounds = calendar ? (from: dueFrom, to: dueTo) : dueBounds(due, _anchor);
    return (
      projectId: widget.projectId ?? (widget.mine ? projectFilter : null),
      personal: widget.personal,
      assigneeId: widget.mine || widget.personal ? session?.profileId : assigneeId,
      statusId: statusId ?? (view == 'list' ? this.statusId : null),
      priority: priority,
      search: search,
      dueFrom: bounds.from,
      dueTo: bounds.to,
      page: page ?? 0,
      sort: calendar
          ? 'due_at'
          : board
          ? boardSort
          : sort,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = widget.projectId == null ? null : ref.watch(projectProvider(widget.projectId!));
    final personalFlow = widget.personal ? ref.watch(personalWorkflowProvider) : null;
    final flow = widget.personal ? personalFlow?.asData?.value : project?.asData?.value?.workflow;
    // The board shows the four final statuses only (workflow_presentation.dart).
    final statuses = flow == null ? const <StatusRow>[] : groupColumns();
    final projectRow = project?.asData?.value;
    final title = widget.mine
        ? Fa.myTasks
        : widget.personal
        ? Fa.personalTasks
        : projectRow?.name ?? Fa.projects;
    final now = DateTime.now().toUtc();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < 600;
        _layoutWidth = width;
        final canPanel = width >= 1080 && !widget.mine;
        final panelWidth = width >= 1280 ? 520.0 : 440.0;
        final boardWidth = canPanel && selectedId != null ? width - panelWidth : width;
        final gutter = AppSpace.gutter(boardWidth);
        final board = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BoardHeader(
              title: title,
              subtitle: widget.mine
                  ? Fa.myTasksSubtitle
                  : widget.personal
                  ? Fa.personalTasksSubtitle
                  : null,
              project: projectRow,
              projectId: widget.projectId,
              compact: compact,
              gutter: gutter,
              canCreate: _canCreate(session, projectRow),
              canEdit: widget.projectId != null && session?.can('projects.edit') == true,
              busy: busy,
              onBack: () => context.go('/work'),
              onCreate: () => _create(context, session!, projectRow),
            ),
            _Toolbar(
              mine: widget.mine,
              compact: compact,
              gutter: gutter,
              nav: _nav,
              view: view,
              searchController: _search,
              onSearch: _onSearch,
              onView: (value) => setState(() {
                view = value;
                calendarDay = null;
              }),
              sort: sort,
              onSort: (value) => setState(() {
                sort = value;
                _resetPaging();
              }),
              filterCount: _activeFilters(statuses, projectRow).length,
              onFilters: () => _openFilters(context, statuses, projectRow, compact),
            ),
            _ActiveFilters(
              gutter: gutter,
              chips: _activeFilters(statuses, projectRow),
              onClear: () => setState(() {
                priority = null;
                assigneeId = null;
                statusId = null;
                projectFilter = null;
                due = DueWindow.any;
                _resetPaging();
              }),
            ),
            Expanded(child: _body(statuses, flow, now)),
          ],
        );
        if (!canPanel) return board;
        final open = selectedId != null;
        if (open) _panelTask = selectedId;
        final p = paletteOf(context);
        // The detail panel slides in beside the board: a solid L1 surface (it
        // carries dense text; no extra blur layer on the page).
        return Row(
          children: [
            Expanded(child: board),
            AnimatedContainer(
              key: const Key('detail-panel'),
              duration: AppMotion.of(context, open ? AppMotion.panel : AppMotion.panelExit),
              curve: open ? AppMotion.enter : AppMotion.exit,
              width: open ? panelWidth : 0,
              onEnd: () {
                if (selectedId == null && _panelTask != null && mounted) setState(() => _panelTask = null);
              },
              decoration: BoxDecoration(
                color: p.surface,
                border: BorderDirectional(start: BorderSide(color: p.stroke)),
                boxShadow: open ? AppElevation.e2(p.ink) : null,
              ),
              child: _panelTask == null
                  ? null
                  : ClipRect(
                      child: OverflowBox(
                        alignment: AlignmentDirectional.centerStart,
                        minWidth: panelWidth,
                        maxWidth: panelWidth,
                        child: TaskDetailPage(key: ValueKey('panel-$_panelTask'), taskId: _panelTask!, embedded: true, onClose: () => setState(() => selectedId = null)),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- filters

  List<({String label, VoidCallback onRemove})> _activeFilters(List<StatusRow> statuses, ProjectRow? project) {
    String? memberName(String? id) {
      if (id == null) return null;
      final session = ref.read(workspaceSessionProvider).asData?.value;
      for (final m in project?.members ?? const <MemberRow>[]) {
        if (m.profileId == id) return memberDisplayName(m, session);
      }
      return null;
    }

    return [
      if (statusId != null && view == 'list')
        (
          label: '${Fa.filterStatus}: ${statusFilterLabel(statusId) ?? ''}',
          onRemove: () => setState(() {
            statusId = null;
            _resetPaging();
          }),
        ),
      if (priority != null)
        (
          label: '${Fa.filterPriority}: ${priorityLabel(priority!)}',
          onRemove: () => setState(() {
            priority = null;
            _resetPaging();
          }),
        ),
      if (assigneeId != null)
        (
          label: '${Fa.filterAssignee}: ${memberName(assigneeId) ?? ''}',
          onRemove: () => setState(() {
            assigneeId = null;
            _resetPaging();
          }),
        ),
      if (due != DueWindow.any && view != 'calendar')
        (
          label: '${Fa.filterDue}: ${dueWindowLabel(due)}',
          onRemove: () => setState(() {
            due = DueWindow.any;
            _resetPaging();
          }),
        ),
      if (projectFilter != null)
        (
          label: Fa.filterProject,
          onRemove: () => setState(() {
            projectFilter = null;
            _resetPaging();
          }),
        ),
    ];
  }

  Future<void> _openFilters(BuildContext context, List<StatusRow> statuses, ProjectRow? project, bool compact) async {
    final projects = widget.mine ? ref.read(projectListProvider((archived: false, page: 0))).asData?.value.projects ?? const <ProjectRow>[] : const <ProjectRow>[];
    final result = await showFilterSheet(
      context,
      compact: compact,
      initial: (statusId: statusId, priority: priority, assigneeId: assigneeId, projectId: projectFilter, due: due),
      showStatus: view == 'list',
      // Assignee choices are the project's members: people who can hold its tasks.
      members: widget.projectId == null ? const [] : project?.members ?? const [],
      projects: projects,
      showDue: view != 'calendar',
      session: ref.read(workspaceSessionProvider).asData?.value,
    );
    if (result == null || !mounted) return;
    setState(() {
      statusId = result.statusId;
      priority = result.priority;
      assigneeId = result.assigneeId;
      projectFilter = result.projectId;
      if (result.due != due) _anchor = DateTime.now().toUtc();
      due = result.due;
      _resetPaging();
    });
  }

  // ---------------------------------------------------------------- views

  Widget _body(List<StatusRow> statuses, WorkflowRow? flow, DateTime now) {
    final current = widget.mine && view == 'kanban' ? 'list' : view;
    if (current == 'list') return _list(flow, now);
    if (current == 'calendar') return _calendar(flow, now);
    if (statuses.isEmpty) return const LoadingView();
    // One count of the whole board (same filters, no status): an empty
    // board shows one guiding empty state instead of empty columns.
    final whole = ref.watch(taskPageProvider(_filter(page: 0, board: true)));
    if (whole.asData?.value.total == 0) {
      final session = ref.read(workspaceSessionProvider).asData?.value;
      final project = widget.projectId == null ? null : ref.read(projectProvider(widget.projectId!)).asData?.value;
      final filtered = search.isNotEmpty || priority != null || assigneeId != null || due != DueWindow.any;
      return BoardEmptyState(
        filtered: filtered,
        canCreate: _canCreate(session, project),
        onCreate: session == null ? null : () => _create(context, session, project),
        onClear: () => setState(() {
          _search.clear();
          search = '';
          priority = null;
          assigneeId = null;
          due = DueWindow.any;
          _resetPaging();
        }),
      );
    }
    final session = ref.read(workspaceSessionProvider).asData?.value;
    final project = widget.projectId == null ? null : ref.read(projectProvider(widget.projectId!)).asData?.value;
    return KanbanBoard(
      statuses: statuses,
      flow: flow,
      now: now,
      busy: busy,
      nav: _nav,
      onCreate: session != null && _canCreate(session, project) && !busy ? () => _create(context, session, project) : null,
      selectedId: selectedId,
      filterFor: (id) => _filter(statusId: id, page: columnPages[id] ?? 0, board: true),
      canDrop: (task, column) {
        final group = groupFromKey(column.id);
        final action = group == null ? null : dropAction(task, group);
        return action != null && _actionsFor(task, flow).contains(action);
      },
      actionsFor: (task) => _actionsFor(task, flow),
      onAction: (task, action) => _act(task, flow, action),
      onPage: (id, value) => setState(() => columnPages[id] = value),
      onOpen: _open,
      onMove: (task, column) {
        final group = groupFromKey(column.id);
        final action = group == null ? null : dropAction(task, group);
        if (action != null) _act(task, flow, action);
      },
    );
  }

  Widget _list(WorkflowRow? flow, DateTime now) {
    final filter = _filter(page: page);
    final result = ref.watch(taskPageProvider(filter));
    return result.when(
      skipLoadingOnReload: true,
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpace.xxl),
        child: Column(
          children: [
            SkeletonBlock(height: 56, radius: AppRadius.control),
            SizedBox(height: AppSpace.s),
            SkeletonBlock(height: 56, radius: AppRadius.control),
            SizedBox(height: AppSpace.s),
            SkeletonBlock(height: 56, radius: AppRadius.control),
          ],
        ),
      ),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskPageProvider(filter))),
      data: (data) => TaskListView(
        tasks: data.tasks,
        total: data.total,
        page: page,
        now: now,
        selectedId: selectedId,
        showProject: widget.mine,
        flow: flow,
        busy: busy,
        onPage: (value) => setState(() => page = value),
        onOpen: _open,
        actionsFor: (task) => _actionsFor(task, flow),
        onMove: (task, action) => _act(task, flow, action),
      ),
    );
  }

  Widget _calendar(WorkflowRow? flow, DateTime now) {
    final start = TehranTime.toUtcFromJalali(month.year, month.month, 1, 0, 0);
    final nextMonth = month.month == 12 ? Jalali(month.year + 1, 1, 1) : Jalali(month.year, month.month + 1, 1);
    final end = TehranTime.toUtcFromJalali(nextMonth.year, nextMonth.month, 1, 0, 0);
    final filter = _filter(page: 0, dueFrom: start.toIso8601String(), dueTo: end.toIso8601String(), calendar: true);
    final result = ref.watch(monthTasksProvider(filter));
    return TaskCalendarView(
      month: month,
      now: now,
      selectedDay: calendarDay,
      data: result,
      flow: flow,
      busy: busy,
      onMonth: (delta) => setState(() {
        final m = month.month + delta;
        month = m < 1
            ? Jalali(month.year - 1, 12, 1)
            : m > 12
            ? Jalali(month.year + 1, 1, 1)
            : Jalali(month.year, m, 1);
        calendarDay = null;
      }),
      onDay: (day) => setState(() => calendarDay = day),
      onRetry: () => ref.invalidate(monthTasksProvider(filter)),
      onOpen: _open,
      actionsFor: (task) => _actionsFor(task, flow),
      onMove: (task, action) => _act(task, flow, action),
    );
  }

  // ---------------------------------------------------------------- actions

  bool _canCreate(WorkspaceSession? session, ProjectRow? project) {
    if (session == null || widget.mine) return false;
    if (widget.personal) return session.can('tasks.create.personal');
    if (!session.can('tasks.create.project') || project == null) return false;
    return session.can('projects.view.all') || project.members.any((member) => member.profileId == session.profileId && member.role == 'manager');
  }

  void _open(String id) {
    // Same width the panel is laid out with (the content area, not the window),
    // so a card never gets selected without its panel opening.
    final wide = _layoutWidth >= 1080;
    if (wide && !widget.mine) {
      setState(() => selectedId = id);
    } else {
      context.go('/work/t/$id');
    }
  }

  /// The actions a task offers on this board (none in "My tasks", whose
  /// tasks span workflows: there the task page offers them).
  List<TaskAction> _actionsFor(TaskRow task, WorkflowRow? flow) {
    final session = ref.read(workspaceSessionProvider).asData?.value;
    return taskActions(task, flow, canAct: canEditTask(session, task), session: session);
  }

  /// Submit, complete, return to the cycle or block: existing, audited
  /// transitions only (see task_actions.dart).
  Future<void> _act(TaskRow task, WorkflowRow? flow, TaskAction action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await runTaskAction(context, ref, task, flow, action);
    } finally {
      _refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create(BuildContext context, WorkspaceSession session, ProjectRow? project) async {
    final id = await showTaskForm(context, project: project, personal: widget.personal, session: session);
    if (id == null || !mounted) return;
    _refresh();
    _open(id);
  }

  void _refresh() {
    ref.invalidate(taskPageProvider);
    ref.invalidate(monthTasksProvider);
  }
}

// ==================================================================== header

class _BoardHeader extends ConsumerWidget {
  const _BoardHeader({
    required this.title,
    this.subtitle,
    required this.project,
    required this.projectId,
    required this.compact,
    required this.gutter,
    required this.canCreate,
    required this.canEdit,
    required this.busy,
    required this.onBack,
    required this.onCreate,
  });

  final String title;
  final String? subtitle;
  final ProjectRow? project;
  final String? projectId;
  final bool compact;
  final double gutter;
  final bool canCreate;
  final bool canEdit;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final planLinks = projectId == null
        ? const <Widget>[]
        : [
            _HeaderAction(icon: AppIcons.sprint, label: Fa.sprints, onTap: () => context.go('/work/p/$projectId/sprints'), compact: compact),
            _HeaderAction(icon: AppIcons.milestone, label: Fa.milestones, onTap: () => context.go('/work/p/$projectId/milestones'), compact: compact),
            if (canEdit) _HeaderAction(icon: AppIcons.settings, label: Fa.settings, onTap: () => context.go('/work/p/$projectId/settings'), compact: compact),
          ];
    final create = canCreate
        ? FilledButton.icon(
            key: const Key('board-new-task'),
            onPressed: busy ? null : onCreate,
            icon: AppIconView(AppIcons.add, color: p.onJade),
            label: const Text(Fa.newTask),
          )
        : null;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(gutter - AppSpace.s, compact ? AppSpace.s : AppSpace.m, gutter, AppSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (compact ? text.titleLarge : text.headlineSmall)?.copyWith(fontWeight: FontWeight.w800, height: 1.3),
                      ),
                    ),
                    if (subtitle != null)
                      Text(subtitle!, key: const Key('board-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: p.muted)),
                  ],
                ),
              ),
              if (!compact) ...[...planLinks, const SizedBox(width: AppSpace.s)],
              if (compact && planLinks.isNotEmpty)
                PopupMenuButton<VoidCallback>(
                  tooltip: Fa.moreActions,
                  icon: const AppIconView(AppIcons.moreActions, semanticLabel: Fa.moreActions),
                  onSelected: (action) => action(),
                  itemBuilder: (context) => [
                    for (final link in planLinks.cast<_HeaderAction>())
                      PopupMenuItem(
                        value: link.onTap,
                        child: Row(
                          children: [
                            AppIconView(link.icon, size: 18),
                            const SizedBox(width: AppSpace.s),
                            Text(link.label),
                          ],
                        ),
                      ),
                  ],
                ),
              ?create,
            ],
          ),
          if (project != null && projectId != null) _ProjectStrip(project: project!, projectId: projectId!),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.icon, required this.label, required this.onTap, required this.compact});

  final AppIcon icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: AppIconView(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: paletteOf(context).ink),
    );
  }
}

/// Members, the active sprint and the current milestone: the project at a
/// glance, all from existing reads.
class _ProjectStrip extends ConsumerWidget {
  const _ProjectStrip({required this.project, required this.projectId});

  final ProjectRow project;
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final sprints = ref.watch(sprintListProvider((projectId: projectId, page: 0))).asData?.value.rows ?? const <SprintRow>[];
    final active = sprints.where((s) => s.status == 'active').firstOrNull;
    final milestones = ref.watch(milestoneListProvider((projectId: projectId, status: 'in_progress', page: 0))).asData?.value.rows ?? const <MilestoneRow>[];
    final milestone = milestones.firstOrNull;
    final members = project.members;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 52, top: AppSpace.xs),
      child: Wrap(
        spacing: AppSpace.l,
        runSpacing: AppSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (project.description.trim().isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(project.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
            ),
          if (members.isNotEmpty)
            Semantics(
              label: '${Fa.projectMembers}: ${persianDigits(members.length)}',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in members.take(4))
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 2),
                      child: PersonAvatar(name: m.name, size: 22),
                    ),
                  if (members.length > 4) Text('+${persianDigits(members.length - 4)}', style: text.labelSmall),
                ],
              ),
            ),
          InkWell(
            onTap: active == null ? null : () => context.go('/work/p/$projectId/sprint/${active.id}'),
            borderRadius: BorderRadius.circular(999),
            child: WorkBadge(label: active == null ? Fa.noActiveSprint : '${Fa.activeSprintShort}: ${active.name}', tone: active == null ? p.muted : p.jade, icon: AppIcons.sprint),
          ),
          if (milestone != null)
            InkWell(
              onTap: () => context.go('/work/p/$projectId/milestone/${milestone.id}'),
              borderRadius: BorderRadius.circular(999),
              child: WorkBadge(label: '${Fa.activeMilestoneShort}: ${milestone.title} · ${formatPlanDate(milestone.targetDate)}', tone: p.revision, icon: AppIcons.milestone),
            ),
        ],
      ),
    );
  }
}

// ==================================================================== toolbar

/// Search, filters, sort, board arrows and the view switch in one compact
/// bar (one row at every width), so the tasks themselves get the height.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.mine,
    required this.compact,
    required this.gutter,
    required this.nav,
    required this.view,
    required this.searchController,
    required this.onSearch,
    required this.onView,
    required this.sort,
    required this.onSort,
    required this.filterCount,
    required this.onFilters,
  });

  final bool mine;
  final bool compact;
  final double gutter;
  final KanbanNav nav;
  final String view;
  final TextEditingController searchController;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onView;
  final String sort;
  final ValueChanged<String> onSort;
  final int filterCount;
  final VoidCallback onFilters;

  static const _height = 40.0;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final views = <(String, String, AppIcon)>[if (!mine) ('kanban', Fa.kanban, AppIcons.kanban), ('list', Fa.taskList, AppIcons.list), ('calendar', Fa.calendar, AppIcons.calendar)];
    final current = view == 'kanban' && mine ? 'list' : view;
    final switcher = SegmentedButton<String>(
      key: const Key('view-switch'),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, _height),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.symmetric(horizontal: compact ? AppSpace.s : AppSpace.m),
      ),
      segments: [
        for (final v in views)
          ButtonSegment(
            value: v.$1,
            icon: AppIconView(v.$3, size: 18, selected: current == v.$1),
            label: compact ? null : Text(v.$2),
            tooltip: v.$2,
          ),
      ],
      selected: {current},
      onSelectionChanged: (value) => onView(value.first),
    );
    final searchField = SizedBox(
      height: _height,
      child: TextField(
        key: const Key('task-search'),
        controller: searchController,
        onChanged: onSearch,
        textInputAction: TextInputAction.search,
        style: text.bodyMedium,
        decoration: InputDecoration(
          hintText: Fa.searchTasks,
          isDense: true,
          filled: true,
          fillColor: Color.alphaBlend(p.ink.withValues(alpha: 0.04), p.surface),
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control - 2), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control - 2), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control - 2), borderSide: BorderSide(color: p.jade, width: 1.5)),
          prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: _height),
          prefixIcon: AppIconView(AppIcons.search, size: 18, color: p.muted),
        ),
      ),
    );
    final quiet = TextButton.styleFrom(
      foregroundColor: p.ink,
      minimumSize: const Size(_height, _height),
      padding: EdgeInsets.symmetric(horizontal: compact ? AppSpace.s : AppSpace.m),
      textStyle: text.labelLarge,
    );
    final filterButton = TextButton(
      key: const Key('open-filters'),
      onPressed: onFilters,
      style: quiet,
      child: Semantics(
        label: filterCount > 0 ? '${Fa.filters}: ${persianDigits(filterCount)}' : Fa.filters,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.filter, size: 18, selected: filterCount > 0, color: filterCount > 0 ? p.jade : p.ink),
            if (!compact) ...[const SizedBox(width: AppSpace.s), const Text(Fa.filters)],
            if (filterCount > 0) ...[
              const SizedBox(width: AppSpace.xs + 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: p.jade, borderRadius: BorderRadius.circular(999)),
                child: Text(persianDigits(filterCount), style: text.labelSmall?.copyWith(color: p.onJade, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
    final sortMenu = current == 'list'
        ? PopupMenuButton<String>(
            key: const Key('sort-menu'),
            tooltip: Fa.sortBy,
            initialValue: sort,
            onSelected: onSort,
            itemBuilder: (context) => [
              for (final s in const [(boardSort, Fa.sortBoard), ('due_at', Fa.sortDue), ('updated_at', Fa.sortUpdated), ('title', Fa.sortTitle)])
                CheckedPopupMenuItem(value: s.$1, checked: sort == s.$1, child: Text(s.$2)),
            ],
            child: Container(
              height: _height,
              padding: EdgeInsets.symmetric(horizontal: compact ? AppSpace.s + 2 : AppSpace.m),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIconView(AppIcons.sort, size: 18),
                  if (!compact) ...[const SizedBox(width: AppSpace.s), Text(_sortLabel(sort), style: text.labelLarge)],
                ],
              ),
            ),
          )
        : null;
    Widget divider() => Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs), color: p.hairline);
    final arrows = current == 'kanban' && !compact
        ? ListenableBuilder(
            listenable: nav,
            builder: (context, _) {
              if (!nav.overflow) return const SizedBox.shrink();
              IconButton arrow(Key key, String tip, AppIcon icon, bool enabled, VoidCallback onTap) => IconButton(
                key: key,
                tooltip: tip,
                style: IconButton.styleFrom(minimumSize: const Size(_height, _height)),
                onPressed: enabled ? onTap : null,
                icon: AppIconView(icon, size: 18, color: enabled ? p.ink : p.muted.withValues(alpha: 0.45), semanticLabel: tip),
              );
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  arrow(const Key('kanban-prev'), Fa.previousColumns, AppIcons.previous, nav.canBack, nav.back),
                  arrow(const Key('kanban-next'), Fa.nextColumns, AppIcons.next, nav.canForward, nav.forward),
                  const SizedBox(width: AppSpace.xs),
                ],
              );
            },
          )
        : const SizedBox.shrink();
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, AppSpace.s),
      child: Container(
        key: const Key('task-toolbar'),
        padding: const EdgeInsets.all(AppSpace.xs),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppRadius.control + 2),
          border: Border.all(color: p.stroke),
          boxShadow: AppElevation.e1(p.ink),
        ),
        child: Row(
          children: [
            if (compact)
              Expanded(child: searchField)
            else
              Flexible(
                flex: 3,
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: searchField),
              ),
            const SizedBox(width: AppSpace.xs),
            filterButton,
            if (sortMenu != null) ...[divider(), sortMenu],
            if (!compact) const Spacer(),
            arrows,
            SizedBox(width: compact ? AppSpace.xs : AppSpace.s),
            switcher,
          ],
        ),
      ),
    );
  }

  static String _sortLabel(String sort) => switch (sort) {
    'due_at' => Fa.sortDue,
    'title' => Fa.sortTitle,
    'updated_at' => Fa.sortUpdated,
    _ => Fa.sortBoard,
  };
}

class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.chips, required this.onClear, required this.gutter});

  final List<({String label, VoidCallback onRemove})> chips;
  final VoidCallback onClear;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, AppSpace.s),
      child: Wrap(
        spacing: AppSpace.s,
        runSpacing: AppSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final chip in chips) InputChip(label: Text(chip.label), onDeleted: chip.onRemove, deleteIcon: const AppIconView(AppIcons.close, size: 16), deleteButtonTooltipMessage: Fa.reset),
          TextButton(key: const Key('clear-filters'), onPressed: onClear, child: const Text(Fa.reset)),
        ],
      ),
    );
  }
}

// ==================================================================== filter sheet

typedef BoardFilters = ({String? statusId, String? priority, String? assigneeId, String? projectId, DueWindow due});

Future<BoardFilters?> showFilterSheet(
  BuildContext context, {
  required bool compact,
  required BoardFilters initial,
  required bool showStatus,
  required List<MemberRow> members,
  required List<ProjectRow> projects,
  required bool showDue,
  WorkspaceSession? session,
}) {
  final content = _FilterForm(initial: initial, showStatus: showStatus, members: members, projects: projects, showDue: showDue, session: session);
  if (compact) {
    return showModalBottomSheet<BoardFilters>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(child: content),
    );
  }
  return showDialog<BoardFilters>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: content),
    ),
  );
}

class _FilterForm extends StatefulWidget {
  const _FilterForm({required this.initial, required this.showStatus, required this.members, required this.projects, required this.showDue, this.session});

  final WorkspaceSession? session;
  final BoardFilters initial;
  final bool showStatus;
  final List<MemberRow> members;
  final List<ProjectRow> projects;
  final bool showDue;

  @override
  State<_FilterForm> createState() => _FilterFormState();
}

class _FilterFormState extends State<_FilterForm> {
  late String? statusId = widget.initial.statusId;
  late String? priority = widget.initial.priority;
  late String? assigneeId = widget.initial.assigneeId;
  late String? projectId = widget.initial.projectId;
  late DueWindow due = widget.initial.due;

  Widget _group(String title, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.s),
          Wrap(spacing: AppSpace.s, runSpacing: AppSpace.s, children: chips),
        ],
      ),
    );
  }

  Widget _field(String title, Widget field) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.l),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.s),
        field,
      ],
    ),
  );

  ChoiceChip _chip(String label, bool selected, VoidCallback onTap, {Key? key}) => ChoiceChip(key: key, label: Text(label), selected: selected, showCheckmark: false, onSelected: (_) => onTap());

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.l, AppSpace.xl, AppSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Fa.filters, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpace.l),
          // The four final statuses, then the two marks of the rejected group;
          // never the stored (retired) statuses.
          if (widget.showStatus)
            _field(
              Fa.filterStatus,
              AppSelectField<String>(
                fieldKey: const Key('filter-status'),
                value: statusId ?? '',
                options: [
                  const AppSelectOption(value: '', label: Fa.anyStatus),
                  for (final c in statusFilterChoices())
                    AppSelectOption(
                      value: c.key,
                      label: c.label,
                      leading: AppIconView(categoryIcon(c.category), size: 18, color: c.category == 'blocked' ? p.alert : statusTone(p, c.category)),
                    ),
                ],
                onChanged: (value) => setState(() => statusId = value.isEmpty ? null : value),
              ),
            ),
          _group(Fa.filterPriority, [
            _chip(Fa.anyone, priority == null, () => setState(() => priority = null)),
            for (final item in const ['critical', 'high', 'medium', 'low']) _chip(priorityLabel(item), priority == item, () => setState(() => priority = item), key: ValueKey('filter-priority-$item')),
          ]),
          if (widget.members.isNotEmpty)
            _field(
              Fa.filterAssignee,
              AppSelectField<String>(
                fieldKey: const Key('filter-assignee'),
                value: assigneeId ?? '',
                options: [
                  const AppSelectOption(value: '', label: Fa.anyone),
                  ...memberOptions(widget.members, widget.session),
                ],
                onChanged: (value) => setState(() => assigneeId = value.isEmpty ? null : value),
              ),
            ),
          if (widget.showDue) _group(Fa.filterDue, [for (final w in DueWindow.values) _chip(dueWindowLabel(w), due == w, () => setState(() => due = w), key: ValueKey('filter-due-${w.name}'))]),
          if (widget.projects.isNotEmpty)
            _field(
              Fa.filterProject,
              AppSelectField<String>(
                fieldKey: const Key('filter-project'),
                value: projectId ?? '',
                options: [
                  const AppSelectOption(value: '', label: Fa.anyProject),
                  for (final pr in widget.projects)
                    AppSelectOption(
                      value: pr.id,
                      label: pr.name,
                      leading: AppIconView(AppIcons.projects, size: 18, color: p.jade),
                    ),
                ],
                onChanged: (value) => setState(() => projectId = value.isEmpty ? null : value),
              ),
            ),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  statusId = null;
                  priority = null;
                  assigneeId = null;
                  projectId = null;
                  due = DueWindow.any;
                }),
                child: const Text(Fa.reset),
              ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
              const SizedBox(width: AppSpace.s),
              FilledButton(
                key: const Key('apply-filters'),
                onPressed: () => Navigator.pop<BoardFilters>(context, (statusId: statusId, priority: priority, assigneeId: assigneeId, projectId: projectId, due: due)),
                child: const Text(Fa.applyFilters),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==================================================================== list

class TaskListView extends StatelessWidget {
  const TaskListView({
    super.key,
    required this.tasks,
    required this.total,
    required this.page,
    required this.now,
    required this.onPage,
    required this.onOpen,
    required this.onMove,
    this.actionsFor,
    this.flow,
    this.selectedId,
    this.showProject = false,
    this.busy = false,
  });

  final List<TaskRow> tasks;
  final int total;
  final int page;
  final DateTime now;
  final ValueChanged<int> onPage;
  final ValueChanged<String> onOpen;
  final void Function(TaskRow task, TaskAction action) onMove;
  final List<TaskAction> Function(TaskRow task)? actionsFor;
  final WorkflowRow? flow;
  final String? selectedId;
  final bool showProject;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final pages = total == 0 ? 1 : (total / taskPageSize).ceil();
    if (tasks.isEmpty) return EmptyView(message: Fa.noResults);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final gutter = constraints.maxWidth < 600 ? AppSpace.l : AppSpace.xxl;
        if (!wide) {
          return ListView.separated(
            key: const Key('task-list'),
            padding: EdgeInsets.fromLTRB(gutter, AppSpace.xs, gutter, AppSpace.l),
            itemCount: tasks.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpace.s),
            itemBuilder: (context, i) {
              if (i == tasks.length) return MiniPager(page: page, pages: pages, onPage: onPage);
              final task = tasks[i];
              return TaskCard(
                key: ValueKey('list-${task.id}'),
                task: task,
                now: now,
                showStatus: true,
                showProject: showProject,
                selected: task.id == selectedId,
                onOpen: () => onOpen(task.id),
                actions: actionsFor?.call(task) ?? const [],
                onAction: busy ? null : (action) => onMove(task, action),
              );
            },
          );
        }
        return ListView(
          key: const Key('task-list'),
          padding: EdgeInsets.fromLTRB(gutter, AppSpace.xs, gutter, AppSpace.l),
          children: [
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: paletteOf(context).surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: paletteOf(context).stroke),
                boxShadow: AppElevation.e1(paletteOf(context).ink),
              ),
              child: Column(
                children: [
                  const _ListHeader(),
                  for (final task in tasks) _ListRow(key: ValueKey('row-${task.id}'), task: task, now: now, showProject: showProject, selected: task.id == selectedId, onOpen: () => onOpen(task.id)),
                ],
              ),
            ),
            MiniPager(page: page, pages: pages, onPage: onPage),
          ],
        );
      },
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: p.muted, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.l, vertical: AppSpace.s + 2),
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text(Fa.title, style: style)),
          Expanded(flex: 2, child: Text(Fa.filterStatus, style: style)),
          Expanded(flex: 2, child: Text(Fa.filterPriority, style: style)),
          Expanded(flex: 2, child: Text(Fa.assignee, style: style)),
          Expanded(flex: 2, child: Text(Fa.dueDate, style: style)),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({super.key, required this.task, required this.now, required this.showProject, required this.selected, required this.onOpen});

  final TaskRow task;
  final DateTime now;
  final bool showProject;
  final bool selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final complete = taskCountsComplete(category: task.statusCategory, approvalRequired: task.approvalRequired, approvalState: task.approvalState);
    final meta = [
      if (showProject) task.projectName ?? Fa.personalTasks,
      if (task.checklist.isNotEmpty) '${Fa.checklist} ${persianDigits(task.checklistDone)}/${persianDigits(task.checklist.length)}',
      ...task.labels.take(2).map((l) => l.name),
    ];
    final style = PriorityStyle.of(context, task.priority);
    final review = reviewState(task);
    return Material(
      color: selected ? Color.alphaBlend(p.jade.withValues(alpha: 0.07), p.surface) : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.l - 3, AppSpace.m, AppSpace.l, AppSpace.m),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: style.rail, width: 3),
              bottom: BorderSide(color: p.hairline),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: complete ? p.muted : p.ink, decoration: complete ? TextDecoration.lineThrough : null),
                          ),
                        ),
                        if (task.statusCategory == 'blocked') ...[const SizedBox(width: AppSpace.s), const BlockedBadge()],
                        if (review != null) ...[const SizedBox(width: AppSpace.s), Flexible(child: WorkBadge(label: review.label, tone: review.tone(p), icon: review.icon, dense: true))],
                      ],
                    ),
                    if (meta.isNotEmpty) Text(meta.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: StatusBadge(name: task.statusName, category: task.statusCategory, dense: true),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PriorityBadge(priority: task.priority, dense: true),
                ),
              ),
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    PersonAvatar(name: task.assigneeName, size: 22),
                    const SizedBox(width: AppSpace.xs),
                    Flexible(
                      child: Text(
                        task.assigneeName.trim().isEmpty ? '—' : task.assigneeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: p.ink),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: task.dueAt == null
                    ? Text('—', style: text.bodySmall)
                    : Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: DueBadge(due: task.dueAt!, now: now, complete: complete),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================================================================== calendar

class TaskCalendarView extends StatelessWidget {
  const TaskCalendarView({
    super.key,
    required this.month,
    required this.now,
    required this.selectedDay,
    required this.data,
    required this.onMonth,
    required this.onDay,
    required this.onRetry,
    required this.onOpen,
    required this.onMove,
    this.actionsFor,
    this.flow,
    this.busy = false,
  });

  final Jalali month;
  final DateTime now;
  final Jalali? selectedDay;
  final AsyncValue<({List<TaskRow> tasks, bool truncated})> data;
  final ValueChanged<int> onMonth;
  final ValueChanged<Jalali> onDay;
  final VoidCallback onRetry;
  final ValueChanged<String> onOpen;
  final void Function(TaskRow task, TaskAction action) onMove;
  final List<TaskAction> Function(TaskRow task)? actionsFor;
  final WorkflowRow? flow;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final today = TehranTime.jalali(now);
    final tasks = data.asData?.value.tasks ?? const <TaskRow>[];
    final cells = monthCells(month);
    List<TaskRow> on(Jalali day) => [
      for (final t in tasks)
        if (dueOnJalaliDay(t.dueAt, day.year, day.month, day.day)) t,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < 600;
        final side = width >= 1000;
        final gutter = compact ? AppSpace.l : AppSpace.xxl;
        final header = Row(
          children: [
            IconButton(
              tooltip: Fa.previousMonth,
              onPressed: () => onMonth(-1),
              icon: const AppIconView(AppIcons.previous, semanticLabel: Fa.previousMonth),
            ),
            Expanded(
              child: Text('${jalaliMonths[month.month - 1]} ${persianDigits(month.year)}', textAlign: TextAlign.center, style: text.titleLarge),
            ),
            IconButton(
              tooltip: Fa.nextMonth,
              onPressed: () => onMonth(1),
              icon: const AppIconView(AppIcons.next, semanticLabel: Fa.nextMonth),
            ),
          ],
        );
        final grid = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                      child: Text(
                        Fa.weekdaysShort[i],
                        textAlign: TextAlign.center,
                        style: text.labelMedium?.copyWith(color: i == 6 ? p.danger : p.muted, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
            for (var r = 0; r < cells.length ~/ 7; r++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < 7; c++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: cells[r * 7 + c] == null
                            ? SizedBox(height: compact ? 52 : 112)
                            : _DayCell(
                                key: ValueKey('day-${cells[r * 7 + c]!.day}'),
                                day: cells[r * 7 + c]!,
                                tasks: on(cells[r * 7 + c]!),
                                compact: compact,
                                today: cells[r * 7 + c] == today,
                                selected: cells[r * 7 + c] == selectedDay,
                                now: now,
                                onTap: () => onDay(cells[r * 7 + c]!),
                                onOpen: onOpen,
                              ),
                      ),
                    ),
                ],
              ),
          ],
        );
        final dayList = selectedDay == null ? null : _DayList(day: selectedDay!, tasks: on(selectedDay!), now: now, onOpen: onOpen, onMove: onMove, actionsFor: actionsFor, flow: flow, busy: busy);
        final body = data.hasError && !data.hasValue
            ? ErrorView(message: taskErrorText(data.error!), onRetry: onRetry)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (data.isLoading && !data.hasValue) const LinearProgressIndicator(),
                  if (data.asData?.value.truncated == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.s),
                      child: NoticeBar(message: Fa.monthTruncated, tone: p.warning, icon: AppIcons.warning),
                    ),
                  grid,
                ],
              );
        if (side) {
          return Padding(
            padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, AppSpace.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(key: const Key('task-calendar'), children: [header, body]),
                ),
                if (dayList != null) ...[const SizedBox(width: AppSpace.l), SizedBox(width: 340, child: dayList)],
              ],
            ),
          );
        }
        return ListView(
          key: const Key('task-calendar'),
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpace.l),
          children: [
            header,
            body,
            if (dayList != null) ...[const SizedBox(height: AppSpace.l), dayList],
          ],
        );
      },
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({super.key, required this.day, required this.tasks, required this.compact, required this.today, required this.selected, required this.now, required this.onTap, required this.onOpen});

  final Jalali day;
  final List<TaskRow> tasks;
  final bool compact;
  final bool today;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final visible = compact ? 0 : 3;
    final shown = tasks.take(visible).toList();
    final extra = tasks.length - shown.length;
    return Semantics(
      button: true,
      selected: selected,
      label: '${persianDigits(day.day)} ${jalaliMonths[day.month - 1]}، ${persianDigits(tasks.length)} تسک',
      excludeSemantics: true,
      child: Material(
        color: selected ? Color.alphaBlend(p.jade.withValues(alpha: 0.10), p.surface) : p.surface,
        borderRadius: BorderRadius.circular(AppRadius.control - 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control - 2),
          onTap: onTap,
          child: Container(
            height: compact ? 52 : 112,
            padding: const EdgeInsets.all(AppSpace.xs),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.control - 2),
              border: Border.all(color: selected ? p.jade : p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: today ? BoxDecoration(color: p.jade, shape: BoxShape.circle) : null,
                      child: Text(
                        persianDigits(day.day),
                        style: text.labelMedium?.copyWith(color: today ? p.onJade : p.ink, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (compact && tasks.isNotEmpty) ...[
                      const Spacer(),
                      Text(
                        persianDigits(tasks.length),
                        style: text.labelSmall?.copyWith(color: p.jade, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),
                if (compact && tasks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 2,
                      children: [
                        for (final t in tasks.take(4))
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(color: priorityTone(p, t.priority), shape: BoxShape.circle),
                          ),
                      ],
                    ),
                  ),
                for (final task in shown)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: InkWell(
                      key: ValueKey('cal-${task.id}'),
                      onTap: () => onOpen(task.id),
                      child: Container(
                        padding: const EdgeInsetsDirectional.fromSTEB(5, 1, 4, 1),
                        decoration: BoxDecoration(
                          color: PriorityStyle.of(context, task.priority).chip,
                          borderRadius: BorderRadius.circular(4),
                          border: BorderDirectional(start: BorderSide(color: priorityTone(p, task.priority), width: 2)),
                        ),
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(color: p.ink),
                        ),
                      ),
                    ),
                  ),
                if (!compact && extra > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '+${persianDigits(extra)} ${Fa.moreTasks}',
                      style: text.labelSmall?.copyWith(color: p.jade, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  const _DayList({required this.day, required this.tasks, required this.now, required this.onOpen, required this.onMove, required this.flow, required this.busy, this.actionsFor});

  final Jalali day;
  final List<TaskRow> tasks;
  final DateTime now;
  final ValueChanged<String> onOpen;
  final void Function(TaskRow task, TaskAction action) onMove;
  final List<TaskAction> Function(TaskRow task)? actionsFor;
  final WorkflowRow? flow;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      key: const Key('calendar-day-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${Fa.dayTasks} ${persianDigits(day.day)} ${jalaliMonths[day.month - 1]}', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.s),
        if (tasks.isEmpty) Text(Fa.empty, style: text.bodySmall),
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.s),
            child: TaskCard(
              task: task,
              now: now,
              showStatus: true,
              onOpen: () => onOpen(task.id),
              actions: actionsFor?.call(task) ?? const [],
              onAction: busy ? null : (action) => onMove(task, action),
            ),
          ),
      ],
    );
  }
}

/// The cells of a Jalali month, weeks from Saturday; null pads the edges.
List<Jalali?> monthCells(Jalali month) {
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

// ==================================================================== empty board

/// The whole board has no task: one short, centred state with guidance and
/// the create action, instead of tall empty columns.
class BoardEmptyState extends StatelessWidget {
  const BoardEmptyState({super.key, required this.filtered, required this.canCreate, required this.onCreate, required this.onClear});

  final bool filtered;
  final bool canCreate;
  final VoidCallback? onCreate;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            key: const Key('board-empty'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Color.alphaBlend(p.jade.withValues(alpha: 0.12), p.surface), shape: BoxShape.circle),
                child: AppIconView(filtered ? AppIcons.filter : AppIcons.kanban, size: 30, color: p.jade),
              ),
              const SizedBox(height: AppSpace.l),
              Text(
                filtered ? Fa.boardEmptyFiltered : Fa.boardEmptyTitle,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                filtered
                    ? Fa.boardEmptyFilteredHint
                    : canCreate
                    ? Fa.boardEmptyHint
                    : Fa.boardEmptyReadOnly,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: p.muted),
              ),
              const SizedBox(height: AppSpace.xl),
              if (filtered)
                OutlinedButton.icon(key: const Key('board-empty-clear'), onPressed: onClear, icon: const AppIconView(AppIcons.close, size: 18), label: const Text(Fa.clearFilters))
              else if (canCreate && onCreate != null)
                FilledButton.icon(
                  key: const Key('board-empty-create'),
                  onPressed: onCreate,
                  icon: AppIconView(AppIcons.add, color: p.onJade),
                  label: const Text(Fa.createFirstTask),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
