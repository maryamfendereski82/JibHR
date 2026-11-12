import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_select.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../attendance/attendance_review.dart';
import '../session/workspace_session.dart';
import 'task_form.dart';
import 'widgets/kanban_board.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';

final projectListProvider = FutureProvider.family<({List<ProjectRow> projects, int total}), ({bool archived, int page})>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (projects: const <ProjectRow>[], total: 0);
  return WorkRepository(client).projects(archived: key.archived, page: key.page);
});

final projectProvider = FutureProvider.family<ProjectRow?, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || id == 'none') return null;
  return WorkRepository(client).project(id);
});

/// The overview page: searchable, with member and task counts.
final projectOverviewProvider = FutureProvider.family<({List<ProjectRow> projects, int total}), ({bool archived, int page, String search})>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return (projects: const <ProjectRow>[], total: 0);
  return WorkRepository(client).projects(archived: key.archived, page: key.page, search: key.search, withCounts: true);
});

/// Categories a new workflow status may take: the five final statuses only
/// (retired categories are never offered).
const workCategories = ['backlog', 'in_progress', 'in_review', 'approved', 'rejected'];

// ==================================================================== overview

class ProjectListPage extends ConsumerStatefulWidget {
  const ProjectListPage({super.key});

  @override
  ConsumerState<ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends ConsumerState<ProjectListPage> {
  bool archived = false;
  int page = 0;
  String search = '';
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || value.trim() == search) return;
      setState(() {
        search = value.trim();
        page = 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final key = (archived: archived, page: page, search: search);
    final list = ref.watch(projectOverviewProvider(key));
    final canCreate = session?.can('projects.create') == true;
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final gutter = compact ? AppSpace.l : AppSpace.xxl;
        final columns = constraints.maxWidth >= 1100
            ? 3
            : constraints.maxWidth >= 700
            ? 2
            : 1;
        final total = list.asData?.value.total;

        final searchField = SizedBox(
          height: 44,
          child: TextField(
            key: const Key('project-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: Fa.searchProjects,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: AppIconView(AppIcons.search, size: 18, color: p.muted),
              ),
            ),
          ),
        );
        final tabs = SegmentedButton<bool>(
          key: const Key('project-tabs'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, icon: AppIconView(AppIcons.projects, size: 18), label: Text(Fa.activeProjectsTab)),
            ButtonSegment(value: true, icon: AppIconView(AppIcons.archive, size: 18), label: Text(Fa.archivedProjectsTab)),
          ],
          selected: {archived},
          onSelectionChanged: (value) => setState(() {
            archived = value.first;
            page = 0;
          }),
        );
        final sectionTitle = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Fa.projects, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (total != null) ...[
              const SizedBox(width: AppSpace.s),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: 1),
                decoration: BoxDecoration(color: Color.alphaBlend(p.jade.withValues(alpha: 0.12), p.surface), borderRadius: BorderRadius.circular(999)),
                child: Text(persianDigits(total), style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        );

        return ListView(
          key: const Key('project-overview'),
          padding: EdgeInsets.fromLTRB(gutter, AppSpace.l, gutter, AppSpace.xxl),
          children: [
            // Page header: title, purpose, the one primary action.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(Fa.work, style: (compact ? text.titleLarge : text.headlineSmall)?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(height: 2),
                      Text(Fa.workHint, style: text.bodySmall),
                    ],
                  ),
                ),
                if (canCreate) ...[
                  const SizedBox(width: AppSpace.m),
                  FilledButton.icon(
                    key: const Key('new-project'),
                    onPressed: () => _create(context),
                    icon: AppIconView(AppIcons.add, color: p.onJade),
                    label: Text(compact ? Fa.newProjectShort : Fa.newProject),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpace.l),
            // My tasks vs personal tasks: two different lists, said plainly.
            _grid(compact ? 1 : 2, [
              _Shortcut(key: const Key('go-mine'), icon: AppIcons.myTasks, label: Fa.myTasks, hint: Fa.myTasksHint, onTap: () => context.go('/work/mine')),
              _Shortcut(key: const Key('go-personal'), icon: AppIcons.person, label: Fa.personalTasks, hint: Fa.personalTasksHint, onTap: () => context.go('/work/personal')),
            ]),
            const SizedBox(height: AppSpace.l),
            // Toolbar: section title, search, active/archived.
            if (compact) ...[
              sectionTitle,
              const SizedBox(height: AppSpace.s),
              searchField,
              const SizedBox(height: AppSpace.s),
              SizedBox(width: double.infinity, child: tabs),
            ] else
              Row(
                children: [
                  sectionTitle,
                  const SizedBox(width: AppSpace.l),
                  Flexible(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: searchField),
                  ),
                  const Spacer(),
                  tabs,
                ],
              ),
            const SizedBox(height: AppSpace.m),
            list.when(
              skipLoadingOnReload: true,
              loading: () => _grid(columns, [for (var i = 0; i < 3; i++) const SkeletonBlock(height: 150, radius: AppRadius.card)]),
              error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(projectOverviewProvider(key))),
              data: (result) {
                if (result.projects.isEmpty) {
                  return _ProjectsEmpty(
                    archived: archived,
                    searching: search.isNotEmpty,
                    canCreate: canCreate,
                    onCreate: () => _create(context),
                    onClearSearch: () => setState(() {
                      _search.clear();
                      search = '';
                    }),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _grid(columns, [for (final project in result.projects) _ProjectCard(project: project)]),
                    if (result.total > taskPageSize) PageButtons(page: page, total: result.total, onPage: (value) => setState(() => page = value)),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _grid(int columns, List<Widget> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += columns) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.m),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < columns; c++) ...[if (c > 0) const SizedBox(width: AppSpace.m), Expanded(child: i + c < items.length ? items[i + c] : const SizedBox.shrink())],
              ],
            ),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Future<void> _create(BuildContext context) async {
    final id = await showDialog<String>(context: context, builder: (_) => const _NewProjectDialog());
    if (id == null || !mounted) return;
    ref.invalidate(projectOverviewProvider);
    ref.invalidate(projectListProvider);
    if (context.mounted) context.go('/work/p/$id');
  }
}

/// No project to show: why, and the next step.
class _ProjectsEmpty extends StatelessWidget {
  const _ProjectsEmpty({required this.archived, required this.searching, required this.canCreate, required this.onCreate, required this.onClearSearch});

  final bool archived;
  final bool searching;
  final bool canCreate;
  final VoidCallback onCreate;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final (title, hint, icon) = searching
        ? (Fa.noProjectMatch, Fa.noProjectMatchHint, AppIcons.search)
        : archived
        ? (Fa.noArchivedProjects, Fa.noArchivedProjectsHint, AppIcons.archive)
        : (Fa.noProjectsTitle, canCreate ? Fa.noProjectsHint : Fa.noProjectsReadOnly, AppIcons.projects);
    return Material(
      key: const Key('projects-empty'),
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: p.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.x3),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Color.alphaBlend(p.jade.withValues(alpha: 0.12), p.surface), shape: BoxShape.circle),
              child: AppIconView(icon, size: 30, color: p.jade),
            ),
            const SizedBox(height: AppSpace.l),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpace.s),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: p.muted),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            if (searching)
              OutlinedButton.icon(onPressed: onClearSearch, icon: const AppIconView(AppIcons.close, size: 18), label: const Text(Fa.clearSearch))
            else if (!archived && canCreate)
              FilledButton.icon(
                key: const Key('create-first-project'),
                onPressed: onCreate,
                icon: AppIconView(AppIcons.add, color: p.onJade),
                label: const Text(Fa.createFirstProject),
              ),
          ],
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({super.key, required this.icon, required this.label, required this.hint, required this.onTap});

  final AppIcon icon;
  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: p.stroke),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Color.alphaBlend(p.jade.withValues(alpha: 0.12), p.surface), borderRadius: BorderRadius.circular(AppRadius.control)),
                child: AppIconView(icon, size: 22, color: p.jade),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.s),
              AppIconView(AppIcons.open, size: 18, color: p.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});

  final ProjectRow project;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final archived = project.status == 'archived';
    Widget stat(AppIcon icon, String value, String label) => Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconView(icon, size: 16, color: p.muted),
          const SizedBox(width: 4),
          Text(value, style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text(label, style: text.labelSmall?.copyWith(color: p.muted)),
        ],
      ),
    );
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: p.stroke),
      ),
      elevation: 0,
      child: InkWell(
        key: ValueKey('project-${project.id}'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.go('/work/p/${project.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: Color.alphaBlend((archived ? p.muted : p.jade).withValues(alpha: 0.12), p.surface), borderRadius: BorderRadius.circular(AppRadius.control)),
                    child: AppIconView(archived ? AppIcons.archive : AppIcons.projects, size: 22, color: archived ? p.muted : p.jade),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${project.creatorName.trim().isEmpty ? '—' : project.creatorName} · ${TehranTime.formatDate(project.createdAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.m),
              Text(
                project.description.trim().isEmpty ? Fa.noDescription : project.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: project.description.trim().isEmpty ? p.muted : p.ink),
              ),
              const Spacer(),
              const SizedBox(height: AppSpace.m),
              Divider(height: 1, color: p.hairline),
              const SizedBox(height: AppSpace.m),
              Wrap(
                spacing: AppSpace.l,
                runSpacing: AppSpace.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (project.taskCount != null) stat(AppIcons.checklist, persianDigits(project.taskCount!), Fa.tasksWord),
                  if (project.memberCount != null) stat(AppIcons.people, persianDigits(project.memberCount!), Fa.membersWord),
                  WorkBadge(
                    label: project.visibility == 'restricted' ? Fa.restricted : Fa.projectWide,
                    tone: project.visibility == 'restricted' ? p.warning : p.muted,
                    icon: project.visibility == 'restricted' ? AppIcons.restricted : AppIcons.projectWide,
                    dense: true,
                  ),
                  if (project.approvalRequired) WorkBadge(label: Fa.approvalRequired, tone: p.revision, icon: AppIcons.approvalPolicy, dense: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewProjectDialog extends ConsumerStatefulWidget {
  const _NewProjectDialog();

  @override
  ConsumerState<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<_NewProjectDialog> {
  final name = TextEditingController();
  final description = TextEditingController();
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
    final client = ref.read(supabaseClientProvider);
    if (client == null || name.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = await WorkRepository(client).createProject(name.text, description.text);
      if (mounted) Navigator.pop(context, id);
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
    return AlertDialog(
      title: const Text(Fa.newProject),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('project-name'),
              controller: name,
              autofocus: true,
              onChanged: (_) {
                if (tried) setState(() {});
              },
              decoration: InputDecoration(labelText: Fa.projectName, errorText: tried && name.text.trim().isEmpty ? Fa.titleRequired : null),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: description,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: Fa.description, alignLabelWithHint: true),
            ),
            if (error != null) ...[const SizedBox(height: AppSpace.m), Text(error!, style: TextStyle(color: p.danger))],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text(Fa.cancel)),
        FilledButton(
          key: const Key('project-create'),
          onPressed: busy ? null : _submit,
          child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade)) : const Text(Fa.newProject),
        ),
      ],
    );
  }
}

// ==================================================================== settings

class ProjectSettingsPage extends ConsumerStatefulWidget {
  const ProjectSettingsPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectSettingsPage> createState() => _ProjectSettingsPageState();
}

class _ProjectSettingsPageState extends ConsumerState<ProjectSettingsPage> {
  final name = TextEditingController();
  final description = TextEditingController();
  final labelName = TextEditingController();
  bool approval = true;
  bool loaded = false;
  bool busy = false;
  NamedPerson? member;
  String memberRole = 'member';

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    labelName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    return project.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(projectProvider(widget.projectId))),
      data: (row) {
        if (row == null) return const EmptyView();
        if (!loaded) {
          loaded = true;
          name.text = row.name;
          description.text = row.description;
          approval = row.approvalRequired;
        }
        final canEdit = session?.can('projects.edit') == true && (session?.can('projects.view.all') == true || row.members.any((m) => m.profileId == session?.profileId && m.role == 'manager'));
        final canArchive = session?.can('projects.archive') == true;
        final p = paletteOf(context);
        final text = Theme.of(context).textTheme;
        final compact = MediaQuery.sizeOf(context).width < 600;
        final gutter = compact ? AppSpace.l : AppSpace.xxl;
        return ListView(
          padding: EdgeInsets.fromLTRB(gutter, AppSpace.l, gutter, AppSpace.xxl),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: Fa.back,
                  onPressed: () => context.go('/work/p/${row.id}'),
                  icon: const AppIconView(AppIcons.back, semanticLabel: Fa.back),
                ),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(color: p.muted),
                      ),
                      Semantics(
                        header: true,
                        child: Text(Fa.settings, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                if (canArchive)
                  OutlinedButton.icon(
                    key: const Key('archive-project'),
                    onPressed: busy ? null : () => _confirmArchive(row),
                    icon: AppIconView(row.status == 'archived' ? AppIcons.restore : AppIcons.archive, size: 18),
                    label: Text(row.status == 'archived' ? Fa.restore : Fa.archive),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.l),
            _Card(
              title: Fa.taskDetails,
              icon: AppIcons.description,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${Fa.recordedBy} ${row.creatorName} · ${formatStamp(row.createdAt)}', style: text.bodySmall),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: name,
                    enabled: canEdit,
                    decoration: const InputDecoration(labelText: Fa.projectName),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: description,
                    enabled: canEdit,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: Fa.description),
                  ),
                  SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text(Fa.approvalRequired), value: approval, onChanged: canEdit ? (value) => setState(() => approval = value) : null),
                  if (canEdit)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton(onPressed: busy ? null : () => _save(row), child: const Text(Fa.save)),
                    ),
                ],
              ),
            ),
            _Card(
              title: Fa.visibility,
              icon: AppIcons.restricted,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'project_wide', label: Text(Fa.projectWide), icon: AppIconView(AppIcons.projectWide, size: 18)),
                    ButtonSegment(value: 'restricted', label: Text(Fa.restricted), icon: AppIconView(AppIcons.restricted, size: 18)),
                  ],
                  selected: {row.visibility},
                  onSelectionChanged: canEdit && !busy ? (value) => _run(() => _repo.setVisibility(row.id, value.first)) : null,
                ),
              ),
            ),
            _Card(
              title: Fa.members,
              icon: AppIcons.people,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final m in row.members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: PersonAvatar(name: m.name, size: 32),
                      title: Text(m.name),
                      subtitle: Text(roleLabel(m.role)),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: Fa.removeMember,
                              onPressed: busy ? null : () => _run(() => _repo.removeMember(row.id, m.profileId)),
                              icon: AppIconView(AppIcons.close, color: p.muted, semanticLabel: Fa.removeMember),
                            )
                          : null,
                    ),
                  if (canEdit) ...[
                    const SizedBox(height: AppSpace.s),
                    Wrap(
                      spacing: AppSpace.s,
                      runSpacing: AppSpace.s,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 260,
                          child: PersonField(
                            person: member,
                            emptyLabel: Fa.chooseEmployee,
                            onTap: busy || session == null
                                ? null
                                : () async {
                                    final picked = await showPersonPicker(context, title: Fa.members, suggestions: const [], selfId: session.profileId, selfName: selfLabel(session));
                                    if (picked?.person != null) setState(() => member = picked!.person);
                                  },
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: AppSelectField<String>(
                            fieldKey: const Key('member-role'),
                            label: Fa.memberRole,
                            value: memberRole,
                            searchable: false,
                            options: const [
                              AppSelectOption(value: 'manager', label: Fa.roleManager),
                              AppSelectOption(value: 'reviewer', label: Fa.roleReviewer),
                              AppSelectOption(value: 'member', label: Fa.roleMember),
                            ],
                            onChanged: busy ? null : (value) => setState(() => memberRole = value),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: member == null || busy
                              ? null
                              : () => _run(() async {
                                  await _repo.addMember(row.id, member!.id, memberRole);
                                  member = null;
                                }),
                          icon: const AppIconView(AppIcons.add, size: 18),
                          label: const Text(Fa.addMember),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            _Card(
              title: Fa.labels,
              icon: AppIcons.label,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (row.labels.isEmpty) Text('—', style: text.bodySmall),
                  for (final label in row.labels)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: AppIconView(AppIcons.label, size: 18, color: label.active ? p.jade : p.muted),
                      title: Text(label.name),
                      value: label.active,
                      onChanged: canEdit && !busy ? (value) => _run(() => _repo.saveLabel(row.id, labelId: label.id, name: label.name, active: value)) : null,
                    ),
                  if (canEdit)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: labelName,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(hintText: Fa.newLabel, isDense: true),
                          ),
                        ),
                        const SizedBox(width: AppSpace.s),
                        OutlinedButton.icon(
                          onPressed: busy || labelName.text.trim().isEmpty
                              ? null
                              : () => _run(() async {
                                  await _repo.saveLabel(row.id, name: labelName.text, active: true);
                                  labelName.clear();
                                }),
                          icon: const AppIconView(AppIcons.add, size: 18),
                          label: const Text(Fa.addItem),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            _Card(
              title: Fa.workflow,
              icon: AppIcons.workflow,
              child: row.workflow == null ? Text('—', style: text.bodySmall) : _WorkflowEditor(project: row, canEdit: canEdit, busy: busy, onRun: _run),
            ),
          ],
        );
      },
    );
  }

  WorkRepository get _repo => WorkRepository(ref.read(supabaseClientProvider)!);

  Future<void> _confirmArchive(ProjectRow row) async {
    final archiving = row.status != 'archived';
    final answer = await askDecision(context, title: archiving ? Fa.archiveConfirm : Fa.restoreConfirm, reasonRequired: false);
    if (answer == null) return;
    await _run(() => _repo.archive(row.id, archived: archiving));
    ref.invalidate(projectListProvider);
  }

  Future<void> _save(ProjectRow row) async {
    await _run(() => _repo.updateProject(row.id, name: name.text, description: description.text, approval: approval));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      ref.invalidate(projectProvider(widget.projectId));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child});

  final String title;
  final AppIcon icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // Material, not a coloured box: list tiles inside paint their ink on it.
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
              Row(
                children: [
                  AppIconView(icon, size: 18, color: p.muted),
                  const SizedBox(width: AppSpace.s),
                  Semantics(
                    header: true,
                    child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.m),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

// ==================================================================== workflow

class _WorkflowEditor extends StatefulWidget {
  const _WorkflowEditor({required this.project, required this.canEdit, required this.busy, required this.onRun});

  final ProjectRow project;
  final bool canEdit;
  final bool busy;
  final Future<void> Function(Future<void> Function() action) onRun;

  @override
  State<_WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<_WorkflowEditor> {
  final name = TextEditingController();
  String category = 'backlog';

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _rename(SupabaseClient? client, WorkflowRow flow, StatusRow status) async {
    final controller = TextEditingController(text: status.name);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Fa.renameStatus),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (value) => Navigator.pop(context, value)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text(Fa.save)),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty || client == null || !mounted) return;
    await widget.onRun(
      () => WorkRepository(
        client,
      ).saveStatus(workflowId: flow.id, statusId: status.id, name: next, category: status.category, position: status.position, authority: status.requiresAuthority, active: status.active),
    );
  }

  Future<void> _swap(SupabaseClient? client, WorkflowRow flow, StatusRow status, int direction) async {
    if (client == null) return;
    final ordered = [...flow.statuses]..sort((a, b) => a.position.compareTo(b.position));
    final index = ordered.indexWhere((item) => item.id == status.id);
    final otherIndex = index + direction;
    if (index < 0 || otherIndex < 0 || otherIndex >= ordered.length) return;
    final other = ordered[otherIndex];
    await widget.onRun(() async {
      final repository = WorkRepository(client);
      await repository.saveStatus(
        workflowId: flow.id,
        statusId: status.id,
        name: status.name,
        category: status.category,
        position: other.position,
        authority: status.requiresAuthority,
        active: status.active,
      );
      await repository.saveStatus(
        workflowId: flow.id,
        statusId: other.id,
        name: other.name,
        category: other.category,
        position: status.position,
        authority: other.requiresAuthority,
        active: other.active,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final flow = widget.project.workflow!;
    final client = ProviderScope.containerOf(context).read(supabaseClientProvider);
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final busy = widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < flow.statuses.length; i++) ...[
          Builder(
            builder: (context) {
              final status = flow.statuses[i];
              final tone = categoryTone(p, status.category);
              return Container(
                key: ValueKey('status-${status.id}'),
                margin: const EdgeInsets.only(bottom: AppSpace.s),
                padding: const EdgeInsets.all(AppSpace.m),
                decoration: BoxDecoration(
                  color: status.active ? p.surface : Color.alphaBlend(p.muted.withValues(alpha: 0.06), p.surface),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: BorderDirectional(
                    start: BorderSide(color: tone, width: 3),
                    top: BorderSide(color: p.hairline),
                    end: BorderSide(color: p.hairline),
                    bottom: BorderSide(color: p.hairline),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        AppIconView(categoryIcon(status.category), size: 18, color: tone),
                        const SizedBox(width: AppSpace.s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                status.name,
                                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: status.active ? p.ink : p.muted),
                              ),
                              Text([categoryLabel(status.category), if (status.requiresAuthority) Fa.requiresAuthority, if (!status.active) Fa.statusOff].join(' · '), style: text.bodySmall),
                            ],
                          ),
                        ),
                        if (widget.canEdit) ...[
                          IconButton(
                            tooltip: Fa.renameStatus,
                            onPressed: busy ? null : () => _rename(client, flow, status),
                            icon: AppIconView(AppIcons.edit, size: 18, color: p.muted, semanticLabel: Fa.renameStatus),
                          ),
                          IconButton(
                            tooltip: Fa.moveUp,
                            onPressed: busy || i == 0 ? null : () => _swap(client, flow, status, -1),
                            icon: AppIconView(AppIcons.moveUp, size: 18, color: p.muted, semanticLabel: Fa.moveUp),
                          ),
                          IconButton(
                            tooltip: Fa.moveDown,
                            onPressed: busy || i == flow.statuses.length - 1 ? null : () => _swap(client, flow, status, 1),
                            icon: AppIconView(AppIcons.moveDown, size: 18, color: p.muted, semanticLabel: Fa.moveDown),
                          ),
                          Tooltip(
                            message: status.active ? Fa.statusTurnOff : Fa.statusTurnOn,
                            child: Switch(
                              value: status.active,
                              onChanged: busy
                                  ? null
                                  : (value) => widget.onRun(
                                      () => WorkRepository(client!).saveStatus(
                                        workflowId: flow.id,
                                        statusId: status.id,
                                        name: status.name,
                                        category: status.category,
                                        position: status.position,
                                        authority: status.requiresAuthority,
                                        active: value,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (widget.canEdit) ...[
                      const SizedBox(height: AppSpace.s),
                      Text(Fa.allowedMoves, style: text.labelSmall?.copyWith(color: p.muted)),
                      const SizedBox(height: AppSpace.xs),
                      Wrap(
                        spacing: AppSpace.xs,
                        runSpacing: AppSpace.xs,
                        children: [
                          for (final target in flow.statuses)
                            if (target.id != status.id)
                              FilterChip(
                                visualDensity: VisualDensity.compact,
                                avatar: AppIconView(categoryIcon(target.category), size: 14, color: categoryTone(p, target.category)),
                                label: Text(target.name),
                                selected: flow.transitions.any((edge) => edge.from == status.id && edge.to == target.id),
                                onSelected: busy ? null : (selected) => widget.onRun(() => WorkRepository(client!).setTransition(status.id, target.id, allow: selected)),
                              ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        '${Fa.allowedMoves}: ${[for (final t in flow.statuses)
                          if (flow.transitions.any((e) => e.from == status.id && e.to == t.id)) t.name].join('، ')}',
                        style: text.bodySmall,
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
        if (widget.canEdit) ...[
          const SizedBox(height: AppSpace.s),
          Wrap(
            spacing: AppSpace.s,
            runSpacing: AppSpace.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: name,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: Fa.addStatus, isDense: true),
                ),
              ),
              SizedBox(
                width: 220,
                child: AppSelectField<String>(
                  fieldKey: const Key('status-category'),
                  label: Fa.statusCategory,
                  value: category,
                  searchable: false,
                  options: [
                    for (final c in workCategories)
                      AppSelectOption(
                        value: c,
                        label: categoryLabel(c),
                        leading: AppIconView(categoryIcon(c), size: 18, color: statusTone(p, c)),
                      ),
                  ],
                  onChanged: busy ? null : (value) => setState(() => category = value),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy || name.text.trim().isEmpty
                    ? null
                    : () => widget.onRun(() async {
                        await WorkRepository(client!).saveStatus(
                          workflowId: flow.id,
                          name: name.text,
                          category: category,
                          position: flow.statuses.length + 1,
                          authority: category == 'approved' || category == 'done' || category == 'changes_requested' || category == 'rejected',
                          active: true,
                        );
                        name.clear();
                      }),
                icon: const AppIconView(AppIcons.add, size: 18),
                label: const Text(Fa.addStatus),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ==================================================================== shared

class PageButtons extends StatelessWidget {
  const PageButtons({super.key, required this.page, required this.total, required this.onPage});

  final int page;
  final int total;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final pages = total == 0 ? 1 : (total / taskPageSize).ceil();
    return MiniPager(page: page, pages: pages, onPage: onPage);
  }
}

final peopleProvider = FutureProvider.family<List<NamedPerson>, String>((ref, search) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  return WorkRepository(client).people(search);
});

String roleLabel(String role) => switch (role) {
  'manager' => Fa.roleManager,
  'reviewer' => Fa.roleReviewer,
  _ => Fa.roleMember,
};
