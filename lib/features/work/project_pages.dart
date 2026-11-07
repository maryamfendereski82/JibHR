import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
import '../session/workspace_session.dart';
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

class ProjectListPage extends ConsumerStatefulWidget {
  const ProjectListPage({super.key});

  @override
  ConsumerState<ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends ConsumerState<ProjectListPage> {
  final name = TextEditingController();
  final description = TextEditingController();
  bool archived = false;
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
    final list = ref.watch(projectListProvider((archived: archived, page: page)));
    final canCreate = session?.can('projects.create') == true;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(Fa.projects, style: Theme.of(context).textTheme.titleLarge),
        Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: () => context.go('/work/personal'), child: const Text(Fa.personalTasks)),
            TextButton(onPressed: () => context.go('/work/mine'), child: const Text(Fa.myTasks)),
          ],
        ),
        if (canCreate)
          GlassCard(
            child: Column(
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: Fa.projectName)),
                TextField(controller: description, decoration: const InputDecoration(labelText: Fa.description)),
                const SizedBox(height: 12),
                AppButton(label: Fa.newProject, busy: busy, onPressed: _create),
              ],
            ),
          ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(Fa.archived),
          value: archived,
          onChanged: (value) => setState(() {
            archived = value;
            page = 0;
          }),
        ),
        list.when(
          skipLoadingOnReload: true,
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(projectListProvider((archived: archived, page: page)))),
          data: (result) => Column(
            children: [
              if (result.projects.isEmpty) const EmptyView(),
              for (final project in result.projects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlassCard(
                    padding: const EdgeInsets.all(14),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(project.name),
                      subtitle: Text('${project.creatorName} · ${formatStamp(project.createdAt)}'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () => context.go('/work/p/${project.id}'),
                    ),
                  ),
                ),
              PageButtons(
                page: page,
                total: result.total,
                onPage: (value) => setState(() => page = value),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _create() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy || name.text.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      final id = await WorkRepository(client).createProject(name.text, description.text);
      name.clear();
      description.clear();
      ref.invalidate(projectListProvider);
      if (mounted) context.go('/work/p/$id');
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
  final statusName = TextEditingController();
  final peopleSearch = TextEditingController();
  bool approval = true;
  bool loaded = false;
  bool busy = false;
  String? memberId;
  String memberRole = 'member';
  String category = 'todo';

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    labelName.dispose();
    statusName.dispose();
    peopleSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final project = ref.watch(projectProvider(widget.projectId));
    final people = ref.watch(peopleProvider(peopleSearch.text));
    return project.when(
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
        final canEdit = session?.can('projects.edit') == true &&
            (session?.can('projects.view.all') == true || row.members.any((member) => member.profileId == session?.profileId && member.role == 'manager'));
        final canArchive = session?.can('projects.archive') == true;
        final palette = paletteOf(context);
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Expanded(child: Text(row.name, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: Fa.back, onPressed: () => context.go('/work/p/${row.id}'), icon: const Icon(Icons.arrow_forward)),
              ],
            ),
            Text('${Fa.recordedBy} ${row.creatorName} · ${formatStamp(row.createdAt)}', style: TextStyle(color: palette.muted)),
            const SizedBox(height: 12),
            TextField(controller: name, enabled: canEdit, decoration: const InputDecoration(labelText: Fa.projectName)),
            TextField(controller: description, enabled: canEdit, decoration: const InputDecoration(labelText: Fa.description)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fa.approvalRequired),
              value: approval,
              onChanged: canEdit ? (value) => setState(() => approval = value) : null,
            ),
            if (canEdit) AppButton(label: Fa.save, busy: busy, onPressed: () => _save(row)),
            const SizedBox(height: 16),
            Text(Fa.visibility, style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'project_wide', label: Text(Fa.projectWide)),
                ButtonSegment(value: 'restricted', label: Text(Fa.restricted)),
              ],
              selected: {row.visibility},
              onSelectionChanged: canEdit ? (value) => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).setVisibility(row.id, value.first)) : null,
            ),
            if (canArchive)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).archive(row.id, archived: row.status != 'archived')),
                  child: Text(row.status == 'archived' ? Fa.restore : Fa.archive),
                ),
              ),
            const SizedBox(height: 16),
            Text(Fa.members, style: Theme.of(context).textTheme.titleMedium),
            for (final member in row.members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(member.name),
                subtitle: Text(_roleLabel(member.role)),
                trailing: canEdit
                    ? IconButton(
                        tooltip: Fa.reject,
                        onPressed: () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).removeMember(row.id, member.profileId)),
                        icon: const Icon(Icons.close),
                      )
                    : null,
              ),
            if (canEdit) ...[
              TextField(
                controller: peopleSearch,
                decoration: const InputDecoration(labelText: Fa.peopleHint),
                onChanged: (_) => setState(() {}),
              ),
              DropdownButtonFormField<String?>(
                initialValue: (people.asData?.value ?? const []).any((person) => person.id == memberId) ? memberId : null,
                decoration: const InputDecoration(labelText: Fa.employee),
                items: [
                  const DropdownMenuItem(value: null, child: Text(Fa.chooseEmployee)),
                  for (final person in people.asData?.value ?? const <NamedPerson>[])
                    DropdownMenuItem(value: person.id, child: Text(person.name)),
                ],
                onChanged: (value) => setState(() => memberId = value),
              ),
              DropdownButtonFormField<String>(
                initialValue: memberRole,
                items: const [
                  DropdownMenuItem(value: 'manager', child: Text(Fa.roleManager)),
                  DropdownMenuItem(value: 'reviewer', child: Text(Fa.roleReviewer)),
                  DropdownMenuItem(value: 'member', child: Text(Fa.roleMember)),
                ],
                onChanged: (value) => setState(() => memberRole = value ?? 'member'),
              ),
              const SizedBox(height: 8),
              AppButton(
                label: Fa.members,
                busy: busy,
                onPressed: memberId == null
                    ? null
                    : () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).addMember(row.id, memberId!, memberRole)),
              ),
            ],
            const SizedBox(height: 16),
            Text(Fa.labels, style: Theme.of(context).textTheme.titleMedium),
            for (final label in row.labels)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label.name),
                value: label.active,
                onChanged: canEdit
                    ? (value) => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).saveLabel(row.id, labelId: label.id, name: label.name, active: value))
                    : null,
              ),
            if (canEdit) ...[
              TextField(controller: labelName, decoration: const InputDecoration(labelText: Fa.labels)),
              const SizedBox(height: 8),
              AppButton(
                label: Fa.labels,
                busy: busy,
                onPressed: () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).saveLabel(row.id, name: labelName.text, active: true)),
              ),
            ],
            const SizedBox(height: 16),
            Text(Fa.workflow, style: Theme.of(context).textTheme.titleMedium),
            if (row.workflow != null) _WorkflowEditor(project: row, canEdit: canEdit, busy: busy, onRun: _run),
          ],
        );
      },
    );
  }

  Future<void> _save(ProjectRow row) async {
    await _run(() => WorkRepository(ref.read(supabaseClientProvider)!).updateProject(
          row.id,
          name: name.text,
          description: description.text,
          approval: approval,
        ));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      labelName.clear();
      ref.invalidate(projectProvider(widget.projectId));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

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
  String category = 'todo';

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _rename(SupabaseClient? client, WorkflowRow flow, StatusRow status) async {
    final next = await askDecision(context, title: status.name, reasonRequired: true);
    if (next == null || client == null || !mounted) return;
    await widget.onRun(() => WorkRepository(client).saveStatus(
          workflowId: flow.id,
          statusId: status.id,
          name: next,
          category: status.category,
          position: status.position,
          authority: status.requiresAuthority,
          active: status.active,
        ));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final status in flow.statuses) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(status.name),
            subtitle: Text(status.category),
            trailing: widget.canEdit
                ? Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: Fa.save,
                        onPressed: widget.busy ? null : () => _rename(client, flow, status),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        onPressed: widget.busy ? null : () => _swap(client, flow, status, -1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        onPressed: widget.busy ? null : () => _swap(client, flow, status, 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      Switch(
                        value: status.active,
                        onChanged: widget.busy
                            ? null
                            : (value) => widget.onRun(() => WorkRepository(client!).saveStatus(
                                  workflowId: flow.id,
                                  statusId: status.id,
                                  name: status.name,
                                  category: status.category,
                                  position: status.position,
                                  authority: status.requiresAuthority,
                                  active: value,
                                )),
                      ),
                    ],
                  )
                : null,
          ),
          if (widget.canEdit)
            Wrap(
              spacing: 6,
              children: [
                for (final target in flow.statuses)
                  if (target.id != status.id)
                    FilterChip(
                      label: Text(target.name),
                      selected: flow.transitions.any((edge) => edge.from == status.id && edge.to == target.id),
                      onSelected: widget.busy
                          ? null
                          : (selected) => widget.onRun(() => WorkRepository(client!).setTransition(status.id, target.id, allow: selected)),
                    ),
              ],
            ),
        ],
        if (widget.canEdit) ...[
          TextField(controller: name, decoration: const InputDecoration(labelText: Fa.addStatus)),
          DropdownButtonFormField<String>(
            initialValue: category,
            items: const [
              DropdownMenuItem(value: 'backlog', child: Text('بک‌لاگ')),
              DropdownMenuItem(value: 'todo', child: Text('انجام‌نشده')),
              DropdownMenuItem(value: 'in_progress', child: Text('در حال انجام')),
              DropdownMenuItem(value: 'in_review', child: Text('در حال بررسی')),
              DropdownMenuItem(value: 'approved', child: Text('تأییدشده')),
              DropdownMenuItem(value: 'done', child: Text('انجام‌شده')),
              DropdownMenuItem(value: 'blocked', child: Text('مسدود')),
              DropdownMenuItem(value: 'changes_requested', child: Text('نیاز به اصلاح')),
              DropdownMenuItem(value: 'rejected', child: Text('ردشده')),
            ],
            onChanged: (value) => setState(() => category = value ?? 'todo'),
          ),
          const SizedBox(height: 8),
          AppButton(
            label: Fa.addStatus,
            busy: widget.busy,
            onPressed: () => widget.onRun(() => WorkRepository(client!).saveStatus(
                  workflowId: flow.id,
                  name: name.text,
                  category: category,
                  position: flow.statuses.length + 1,
                  authority: category == 'approved' || category == 'done' || category == 'changes_requested' || category == 'rejected',
                  active: true,
                )),
          ),
        ],
      ],
    );
  }
}

class PageButtons extends StatelessWidget {
  const PageButtons({super.key, required this.page, required this.total, required this.onPage});

  final int page;
  final int total;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final pages = total == 0 ? 1 : (total / taskPageSize).ceil();
    return Row(
      children: [
        TextButton(onPressed: page > 0 ? () => onPage(page - 1) : null, child: const Text(Fa.previousPage)),
        Text('${persianDigits(page + 1)} / ${persianDigits(pages)}'),
        TextButton(onPressed: page + 1 < pages ? () => onPage(page + 1) : null, child: const Text(Fa.nextPage)),
      ],
    );
  }
}

final peopleProvider = FutureProvider.family<List<NamedPerson>, String>((ref, search) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  return WorkRepository(client).people(search);
});

String _roleLabel(String role) => switch (role) {
      'manager' => Fa.roleManager,
      'reviewer' => Fa.roleReviewer,
      _ => Fa.roleMember,
    };
