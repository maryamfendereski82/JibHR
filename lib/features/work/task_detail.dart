import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_controls.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'milestone_pages.dart';
import 'project_pages.dart';
import 'sprint_pages.dart';
import 'task_board.dart';
import 'work_repository.dart';
import 'work_rules.dart';

final taskProvider = FutureProvider.family<TaskRow?, String>((ref, id) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return null;
  return WorkRepository(client).task(id);
});

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
  final peopleSearch = TextEditingController();
  bool loaded = false;
  bool busy = false;
  bool approval = false;
  bool requiredSubtask = false;
  bool withDue = false;
  String priority = 'medium';
  String? assigneeId;
  String? reviewerId;
  late JalaliStamp due = JalaliStamp.today();

  @override
  void didUpdateWidget(TaskDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) loaded = false;
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    checklistTitle.dispose();
    subtaskTitle.dispose();
    peopleSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(taskProvider(widget.taskId));
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final people = ref.watch(peopleProvider(peopleSearch.text));
    final personalFlow = ref.watch(personalWorkflowProvider);
    final projectId = task.asData?.value?.projectId;
    final projectFlow = ref.watch(projectProvider(projectId ?? 'none'));
    return task.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: taskErrorText(error), onRetry: () => ref.invalidate(taskProvider(widget.taskId))),
      data: (row) {
        if (row == null) return const EmptyView();
        if (!loaded) {
          loaded = true;
          title.text = row.title;
          description.text = row.description;
          approval = row.approvalRequired;
          priority = row.priority;
          assigneeId = row.assigneeId;
          reviewerId = row.reviewerId;
          withDue = row.dueAt != null;
        }
        final flow = row.projectId == null ? personalFlow.asData?.value : projectFlow.asData?.value?.workflow;
        final next = flow?.statuses.where((status) => flow.transitions.any((edge) => edge.from == row.statusId && edge.to == status.id)).toList() ?? const <StatusRow>[];
        final names = people.asData?.value ?? const <NamedPerson>[];
        final palette = paletteOf(context);
        final percent = checklistPercent(row.checklistDone, row.checklist.length);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(child: Text(row.statusName, style: Theme.of(context).textTheme.titleMedium)),
                if (widget.embedded)
                  IconButton(onPressed: widget.onClose, icon: const Icon(Icons.close))
                else
                  IconButton(tooltip: Fa.back, onPressed: () => context.go(row.projectId == null ? '/work/personal' : '/work/p/${row.projectId}'), icon: const Icon(Icons.arrow_forward)),
              ],
            ),
            Text('${row.creatorName ?? ''} · ${formatStamp(row.createdAt)}', style: TextStyle(color: palette.muted)),
            TextField(controller: title, decoration: const InputDecoration(labelText: Fa.title)),
            TextField(controller: description, maxLines: 3, decoration: const InputDecoration(labelText: Fa.description)),
            DropdownButtonFormField<String>(
              initialValue: priority,
              items: const [
                DropdownMenuItem(value: 'low', child: Text(Fa.priorityLow)),
                DropdownMenuItem(value: 'medium', child: Text(Fa.priorityMedium)),
                DropdownMenuItem(value: 'high', child: Text(Fa.priorityHigh)),
                DropdownMenuItem(value: 'critical', child: Text(Fa.priorityCritical)),
              ],
              onChanged: (value) => setState(() => priority = value ?? 'medium'),
            ),
            TextField(
              controller: peopleSearch,
              decoration: const InputDecoration(labelText: Fa.peopleHint),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _known(names, assigneeId),
              decoration: const InputDecoration(labelText: Fa.assignee),
              items: [
                if (assigneeId != null && !names.any((person) => person.id == assigneeId))
                  DropdownMenuItem(value: assigneeId, child: Text(row.assigneeName)),
                for (final person in names) DropdownMenuItem(value: person.id, child: Text(person.name)),
              ],
              onChanged: (value) => setState(() => assigneeId = value),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _known(names, reviewerId),
              decoration: const InputDecoration(labelText: Fa.reviewer),
              items: [
                const DropdownMenuItem(value: null, child: Text(Fa.reviewerPool)),
                if (reviewerId != null && !names.any((person) => person.id == reviewerId))
                  DropdownMenuItem(value: reviewerId, child: Text(row.reviewerName ?? Fa.reviewer)),
                for (final person in names) DropdownMenuItem(value: person.id, child: Text(person.name)),
              ],
              onChanged: (value) => setState(() => reviewerId = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(withDue ? '${Fa.dueDate} ${due.isoDay}' : Fa.clearDue),
              value: withDue,
              onChanged: (value) => setState(() => withDue = value),
            ),
            if (withDue) JalaliStampField(value: due, withTime: false, onChanged: (value) => setState(() => due = value)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fa.approvalRequired),
              subtitle: Text(approvalLabel(row.approvalState)),
              value: approval,
              onChanged: (value) => setState(() => approval = value),
            ),
            AppButton(label: Fa.save, busy: busy, onPressed: () => _save(row)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final status in next)
                  OutlinedButton(
                    onPressed: busy ? null : () => _move(row, status),
                    child: Text(status.name),
                  ),
              ],
            ),
            if (row.approvalRequired && row.approvalState == 'pending') ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: busy ? null : () => _decide(row, 'approved', false), child: const Text(Fa.approve)),
                  OutlinedButton(onPressed: busy ? null : () => _decide(row, 'revision_requested', true), child: const Text(Fa.requestRevision)),
                  OutlinedButton(onPressed: busy ? null : () => _decide(row, 'rejected', true), child: const Text(Fa.finalReject)),
                ],
              ),
            ],
            if (row.projectId != null) ...[
              const SizedBox(height: 12),
              Text(Fa.labels, style: Theme.of(context).textTheme.titleMedium),
              Wrap(
                spacing: 6,
                children: [
                  for (final label in projectFlow.asData?.value?.labels.where((label) => label.active) ?? const <LabelRow>[])
                    FilterChip(
                      label: Text(label.name),
                      selected: row.labels.any((item) => item.id == label.id),
                      onSelected: busy
                          ? null
                          : (selected) {
                              final ids = row.labels.map((item) => item.id).toSet();
                              if (selected) {
                                ids.add(label.id);
                              } else {
                                ids.remove(label.id);
                              }
                              _run(() => WorkRepository(ref.read(supabaseClientProvider)!).setLabels(row.id, ids.toList()));
                            },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(Fa.collaborators, style: Theme.of(context).textTheme.titleMedium),
              for (final person in row.collaborators)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(person.name),
                  trailing: IconButton(
                    onPressed: busy ? null : () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).removeCollaborator(row.id, person.id)),
                    icon: const Icon(Icons.close),
                  ),
                ),
              DropdownButtonFormField<String?>(
                initialValue: null,
                decoration: const InputDecoration(labelText: Fa.collaborators),
                items: [
                  const DropdownMenuItem(value: null, child: Text(Fa.chooseEmployee)),
                  for (final person in names) DropdownMenuItem(value: person.id, child: Text(person.name)),
                ],
                onChanged: (value) {
                  if (value != null) _run(() => WorkRepository(ref.read(supabaseClientProvider)!).addCollaborator(row.id, value));
                },
              ),
            ],
            const SizedBox(height: 12),
            Text('${Fa.checklist} ${persianDigits(percent)}٪', style: Theme.of(context).textTheme.titleMedium),
            for (final item in row.checklist)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: item.done,
                title: Text(item.title),
                onChanged: busy ? null : (value) => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).toggleChecklist(item.id, done: value == true)),
                secondary: Wrap(
                  children: [
                    IconButton(onPressed: busy ? null : () => _rename(item), icon: const Icon(Icons.edit_outlined)),
                    IconButton(onPressed: busy ? null : () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).moveChecklist(item.id, -1)), icon: const Icon(Icons.arrow_upward)),
                    IconButton(onPressed: busy ? null : () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).deleteChecklist(item.id)), icon: const Icon(Icons.close)),
                  ],
                ),
              ),
            TextField(controller: checklistTitle, decoration: const InputDecoration(labelText: Fa.checklist)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : () => _run(() => WorkRepository(ref.read(supabaseClientProvider)!).addChecklist(row.id, checklistTitle.text)),
                child: const Text(Fa.checklist),
              ),
            ),
            if (row.parentId == null) ...[
              Text(Fa.subtasks, style: Theme.of(context).textTheme.titleMedium),
              for (final child in row.subtasks)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(child.title),
                  subtitle: Text('${child.assigneeName} · ${child.statusName}${child.requiredSubtask ? ' · ${Fa.requiredSubtask}' : ''}'),
                  onTap: () => context.go('/work/t/${child.id}'),
                ),
              TextField(controller: subtaskTitle, decoration: const InputDecoration(labelText: Fa.subtasks), onChanged: (_) => setState(() {})),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Fa.requiredSubtask),
                value: requiredSubtask,
                onChanged: (value) => setState(() => requiredSubtask = value),
              ),
              AppButton(
                label: Fa.subtasks,
                busy: busy,
                onPressed: subtaskTitle.text.trim().isEmpty ? null : () => _subtask(row, session),
              ),
            ],
            const SizedBox(height: 12),
            Text(Fa.reviews, style: Theme.of(context).textTheme.titleMedium),
            for (final review in row.reviews)
              Text('${review.reviewer ?? ''} · ${approvalLabel(review.decision)} · ${review.reason ?? ''}'),
            const SizedBox(height: 12),
            Text(Fa.activity, style: Theme.of(context).textTheme.titleMedium),
            for (final event in row.activity)
              Text('${activityLabel(event.action)} · ${event.actor} · ${formatStamp(event.createdAt)}', style: TextStyle(color: palette.muted)),
          ],
        );
      },
    );
  }

  Future<void> _save(TaskRow row) async {
    final next = TaskRow(
      id: row.id,
      title: title.text,
      description: description.text,
      priority: priority,
      approvalRequired: approval,
      approvalState: row.approvalState,
      requiredSubtask: row.requiredSubtask,
      assigneeId: assigneeId,
      assigneeName: row.assigneeName,
      reviewerId: reviewerId,
      statusId: row.statusId,
      statusName: row.statusName,
      statusKey: row.statusKey,
      statusCategory: row.statusCategory,
      collaborators: row.collaborators,
      labels: row.labels,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
    await _run(() async {
      await WorkRepository(ref.read(supabaseClientProvider)!).updateTask(next, dueIso: withDue ? due.toUtc().toIso8601String() : null);
      loaded = false;
    });
  }

  Future<void> _move(TaskRow row, StatusRow status) async {
    String? reason;
    final blocked = status.category == 'done' &&
        row.subtasks.any((child) => child.requiredSubtask && (child.statusCategory != 'done' && child.statusCategory != 'approved' || child.approvalRequired && child.approvalState != 'approved'));
    if (blocked) {
      final answer = await askDecision(context, title: Fa.overrideSubtasks, reasonRequired: true);
      if (answer == null || !mounted) return;
      reason = answer.trim();
    }
    await _run(() => WorkRepository(ref.read(supabaseClientProvider)!).transition(row.id, status.id, overrideReason: reason));
  }

  Future<void> _decide(TaskRow row, String decision, bool reasonRequired) async {
    final answer = await askDecision(
      context,
      title: decision == 'approved' ? Fa.approve : decision == 'rejected' ? Fa.finalReject : Fa.requestRevision,
      reasonRequired: reasonRequired,
    );
    if (answer == null) return;
    await _run(() => WorkRepository(ref.read(supabaseClientProvider)!).decide(row.id, decision, reason: reasonRequired ? answer : null));
  }

  Future<void> _rename(ChecklistRow item) async {
    final answer = await askDecision(context, title: Fa.checklist, reasonRequired: true);
    if (answer == null) return;
    await _run(() => WorkRepository(ref.read(supabaseClientProvider)!).renameChecklist(item.id, answer));
  }

  Future<void> _subtask(TaskRow row, WorkspaceSession? session) async {
    await _run(() async {
      await WorkRepository(ref.read(supabaseClientProvider)!).createTask(
        title: subtaskTitle.text,
        description: '',
        projectId: row.projectId,
        assigneeId: assigneeId ?? session?.profileId ?? row.assigneeId ?? '',
        priority: 'medium',
        parentId: row.id,
        required: requiredSubtask,
        approval: row.projectId == null ? false : null,
      );
      subtaskTitle.clear();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || ref.read(supabaseClientProvider) == null) return;
    setState(() => busy = true);
    try {
      await action();
      checklistTitle.clear();
      ref.invalidate(taskProvider(widget.taskId));
      ref.invalidate(taskPageProvider);
      ref.invalidate(sprintListProvider);
      ref.invalidate(sprintProvider);
      ref.invalidate(projectSprintCountsProvider);
      ref.invalidate(sprintTaskProvider);
      ref.invalidate(sprintBreakdownProvider);
      ref.invalidate(milestoneListProvider);
      ref.invalidate(milestoneProvider);
      ref.invalidate(projectMilestoneCountsProvider);
      ref.invalidate(milestoneTaskProvider);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskErrorText(error))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

String? _known(List<NamedPerson> people, String? id) {
  if (id == null) return null;
  if (people.any((person) => person.id == id)) return id;
  return id;
}
