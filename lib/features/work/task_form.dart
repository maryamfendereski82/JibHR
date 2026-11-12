import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_select.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'project_pages.dart';
import 'widgets/work_ui.dart';
import 'work_repository.dart';
import 'work_rules.dart';

/// Whether the person may change the approval default of a project task:
/// the same rule `create_task` applies to `p_approval`.
bool canOverrideProjectApproval(WorkspaceSession session, ProjectRow project) =>
    session.can('projects.view.all') || project.members.any((m) => m.profileId == session.profileId && m.role == 'manager');

String selfLabel(WorkspaceSession session) {
  final name = '${session.firstName} ${session.lastName}'.trim();
  return name.isEmpty ? Fa.selfSuffix : '$name ${Fa.selfSuffix}';
}

/// A project member's display name. The signed-in person is "name (خودم)".
/// When RLS hides the member's profile the name is unknown: the member is
/// shown by role, never by id.
String memberDisplayName(MemberRow member, WorkspaceSession? session) {
  if (session != null && member.profileId == session.profileId) return selfLabel(session);
  return member.name.trim().isEmpty ? '${Fa.projectMemberFallback} · ${roleLabel(member.role)}' : member.name;
}

/// Select options for project members: avatar, full name, role as helper.
List<AppSelectOption<String>> memberOptions(List<MemberRow> members, WorkspaceSession? session) {
  return [
    for (final m in members)
      AppSelectOption(
        value: m.profileId,
        label: memberDisplayName(m, session),
        subtitle: m.name.trim().isEmpty && m.profileId != session?.profileId ? Fa.nameHidden : roleLabel(m.role),
        leading: PersonAvatar(name: m.profileId == session?.profileId ? selfLabel(session!) : m.name, size: 28),
      ),
  ];
}

/// Who may hold a project task: the project's active members, from the
/// project read (not a profile search), so the list never depends on what
/// else the form holds and never collapses to the signed-in person.
List<MemberRow> assignableMembers(ProjectRow? project) => project?.members ?? const <MemberRow>[];

/// Opens the create form (dialog on wide screens, full screen on phones),
/// creates the task and then applies labels and collaborators with the
/// existing RPCs. Returns the new task's id, or null when cancelled.
Future<String?> showTaskForm(BuildContext context, {required WorkspaceSession session, required bool personal, ProjectRow? project}) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  final form = TaskForm(session: session, personal: personal, project: project, compact: compact);
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => compact
        ? Dialog.fullscreen(child: form)
        : Dialog(
            insetPadding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600, maxHeight: 780), child: form),
          ),
  );
}

class TaskForm extends ConsumerStatefulWidget {
  const TaskForm({super.key, required this.session, required this.personal, required this.compact, this.project});

  final WorkspaceSession session;
  final bool personal;
  final bool compact;
  final ProjectRow? project;

  @override
  ConsumerState<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends ConsumerState<TaskForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String priority = 'medium';
  bool withDue = false;
  JalaliStamp due = JalaliStamp.today();

  /// Project tasks start with the signed-in person; personal tasks always
  /// are theirs (the field is not editable).
  late String assigneeId = widget.session.profileId;
  String? reviewerId;
  NamedPerson? personalReviewer;
  late bool approval = widget.project?.approvalRequired ?? false;
  final labelIds = <String>{};
  final collaboratorIds = <String>[];
  bool busy = false;
  bool triedSubmit = false;
  String? error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _approvalEditable => widget.project == null || canOverrideProjectApproval(widget.session, widget.project!);

  Future<void> _submit() async {
    setState(() => triedSubmit = true);
    if (_title.text.trim().isEmpty) return;
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    final repository = WorkRepository(client);
    final project = widget.project;
    final String id;
    try {
      id = await repository.createTask(
        title: _title.text,
        description: _description.text,
        projectId: project?.id,
        // A personal task is always the signed-in person's own.
        assigneeId: project == null ? widget.session.profileId : assigneeId,
        priority: priority,
        dueIso: withDue ? due.toUtc().toIso8601String() : null,
        // Same rule as before: a project task sends approval only when it
        // differs from the project default.
        approval: project == null ? approval : (approval == project.approvalRequired ? null : approval),
        reviewerId: approval ? (project == null ? personalReviewer?.id : reviewerId) : null,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = taskErrorText(e);
        });
      }
      return;
    }
    var extrasFailed = false;
    if (project != null) {
      try {
        if (labelIds.isNotEmpty) await repository.setLabels(id, labelIds.toList());
        for (final person in collaboratorIds) {
          await repository.addCollaborator(id, person);
        }
      } catch (_) {
        extrasFailed = true;
      }
    }
    if (!mounted) return;
    if (extrasFailed) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(Fa.extrasFailed)));
    Navigator.pop(context, id);
  }

  Future<void> _pickPersonalReviewer() async {
    final picked = await showPersonPicker(context, title: Fa.reviewer, suggestions: const [], noneLabel: Fa.reviewerPool, selfId: widget.session.profileId, selfName: selfLabel(widget.session));
    if (picked != null) setState(() => personalReviewer = picked.person);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final project = widget.project;
    final titleMissing = triedSubmit && _title.text.trim().isEmpty;
    final activeLabels = project?.labels.where((l) => l.active).toList() ?? const <LabelRow>[];
    // The member list is read fresh for this project, with its own loading
    // and error states; the title field never touches it.
    final membersAsync = project == null ? null : ref.watch(projectProvider(project.id));
    final members = assignableMembers(membersAsync?.asData?.value ?? project);
    final memberError = membersAsync != null && membersAsync.hasError ? taskErrorText(membersAsync.error!) : null;
    final memberById = {for (final m in members) m.profileId: m};

    final header = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, AppSpace.l, AppSpace.s, AppSpace.s),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(Fa.newTask, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 2),
                Text(project?.name ?? Fa.personalTasks, style: text.bodySmall),
              ],
            ),
          ),
          IconButton(
            tooltip: Fa.close,
            onPressed: busy ? null : () => Navigator.pop(context),
            icon: const AppIconView(AppIcons.close, semanticLabel: Fa.close),
          ),
        ],
      ),
    );

    final assigneeField = project == null
        ? FixedAssignee(key: const Key('task-form-assignee'), name: selfLabel(widget.session))
        : AppSelectField<String>(
            fieldKey: const Key('task-form-assignee'),
            label: Fa.assignee,
            value: assigneeId,
            selectedLabel: memberById[assigneeId] == null && assigneeId == widget.session.profileId ? selfLabel(widget.session) : null,
            options: memberOptions(members, widget.session),
            loading: membersAsync?.isLoading == true && members.isEmpty,
            loadError: memberError,
            onRetry: () => ref.invalidate(projectProvider(project.id)),
            emptyText: Fa.noProjectMembers,
            searchHint: Fa.searchPeople,
            searchable: true,
            onChanged: busy
                ? null
                : (value) => setState(() {
                    assigneeId = value;
                    collaboratorIds.remove(value);
                  }),
          );

    final reviewerOptions = [
      AppSelectOption<String>(
        value: '',
        label: Fa.reviewerPool,
        leading: AppIconView(AppIcons.people, size: 22, color: p.muted),
      ),
      ...memberOptions([
        for (final m in members)
          if (m.role != 'member') m,
      ], widget.session),
    ];

    final fields = <Widget>[
      TextField(
        key: const Key('task-form-title'),
        controller: _title,
        autofocus: true,
        textInputAction: TextInputAction.next,
        onChanged: (_) {
          if (triedSubmit) setState(() {});
        },
        decoration: InputDecoration(labelText: Fa.title, errorText: titleMissing ? Fa.titleRequired : null),
      ),
      const SizedBox(height: AppSpace.m),
      TextField(
        key: const Key('task-form-description'),
        controller: _description,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(labelText: Fa.description, alignLabelWithHint: true),
      ),
      const SizedBox(height: AppSpace.l),
      FormSection(
        title: Fa.priority,
        child: PriorityPicker(value: priority, onChanged: (value) => setState(() => priority = value)),
      ),
      FormSection(title: Fa.assignee, child: assigneeField),
      FormSection(
        title: Fa.dueDate,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('task-form-due-switch'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(withDue ? Fa.dueDate : Fa.clearDue),
              value: withDue,
              onChanged: busy ? null : (value) => setState(() => withDue = value),
            ),
            if (withDue) TaskDateField(value: due, onChanged: busy ? null : (value) => setState(() => due = value)),
          ],
        ),
      ),
      FormSection(
        title: Fa.approvalRequired,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('task-form-approval'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(approval ? Fa.approvalRequired : Fa.approvalOptional),
              subtitle: project == null ? null : Text('${Fa.projectDefault}: ${project.approvalRequired ? Fa.approvalRequired : Fa.approvalOptional}'),
              value: approval,
              onChanged: busy || !_approvalEditable ? null : (value) => setState(() => approval = value),
            ),
            if (approval && project != null)
              AppSelectField<String>(
                fieldKey: const Key('task-form-reviewer'),
                label: Fa.reviewer,
                value: reviewerId ?? '',
                options: reviewerOptions,
                loading: membersAsync?.isLoading == true && members.isEmpty,
                loadError: memberError,
                onRetry: () => ref.invalidate(projectProvider(project.id)),
                onChanged: busy ? null : (value) => setState(() => reviewerId = value.isEmpty ? null : value),
              ),
            // Personal tasks keep the reviewer search (RLS decides who is listed).
            if (approval && project == null)
              PersonField(
                key: const Key('task-form-reviewer'),
                label: Fa.reviewer,
                person: personalReviewer,
                emptyLabel: Fa.reviewerPool,
                onTap: busy ? null : _pickPersonalReviewer,
                onClear: personalReviewer == null || busy ? null : () => setState(() => personalReviewer = null),
              ),
          ],
        ),
      ),
      if (project != null) ...[
        if (activeLabels.isNotEmpty)
          FormSection(
            title: Fa.labels,
            child: Wrap(
              spacing: AppSpace.s,
              runSpacing: AppSpace.s,
              children: [
                for (final label in activeLabels)
                  FilterChip(
                    label: Text(label.name),
                    selected: labelIds.contains(label.id),
                    onSelected: busy ? null : (selected) => setState(() => selected ? labelIds.add(label.id) : labelIds.remove(label.id)),
                  ),
              ],
            ),
          ),
        FormSection(
          title: Fa.collaborators,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (collaboratorIds.isNotEmpty) ...[
                Wrap(
                  spacing: AppSpace.s,
                  runSpacing: AppSpace.s,
                  children: [
                    for (final id in collaboratorIds)
                      InputChip(
                        avatar: PersonAvatar(name: memberById[id]?.name ?? '', size: 20),
                        label: Text(memberById[id] == null ? Fa.projectMemberFallback : memberDisplayName(memberById[id]!, widget.session)),
                        onDeleted: busy ? null : () => setState(() => collaboratorIds.remove(id)),
                        deleteIcon: const AppIconView(AppIcons.close, size: 16),
                        deleteButtonTooltipMessage: Fa.removeCollaborator,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.s),
              ],
              AppSelectField<String>(
                fieldKey: const Key('task-form-collaborator'),
                value: null,
                placeholder: Fa.addCollaborator,
                icon: AppIcons.add,
                options: memberOptions([
                  for (final m in members)
                    if (m.profileId != assigneeId && !collaboratorIds.contains(m.profileId)) m,
                ], widget.session),
                emptyText: Fa.noMoreMembers,
                loading: membersAsync?.isLoading == true && members.isEmpty,
                loadError: memberError,
                onRetry: () => ref.invalidate(projectProvider(project.id)),
                onChanged: busy ? null : (value) => setState(() => collaboratorIds.add(value)),
              ),
            ],
          ),
        ),
        Text(Fa.afterCreate, style: text.bodySmall),
      ],
      if (error != null) ...[const SizedBox(height: AppSpace.m), Text(error!, style: text.bodyMedium?.copyWith(color: p.danger))],
    ];

    final actions = Container(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.m, AppSpace.xl, AppSpace.l),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          const Spacer(),
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text(Fa.cancel)),
          const SizedBox(width: AppSpace.s),
          FilledButton(
            key: const Key('task-form-submit'),
            onPressed: busy ? null : _submit,
            child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade)) : const Text(Fa.createTask),
          ),
        ],
      ),
    );

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.s, AppSpace.xl, AppSpace.l),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: fields),
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

/// The assignee of a personal task: always the signed-in person, shown as
/// a fixed line, not a picker.
class FixedAssignee extends StatelessWidget {
  const FixedAssignee({super.key, required this.name, this.hint = Fa.personalAssigneeHint});

  final String name;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: '${Fa.assignee}: $name',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, AppSpace.s, AppSpace.m, AppSpace.s),
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: p.stroke),
        ),
        child: Row(
          children: [
            PersonAvatar(name: name, size: 28),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${Fa.assignee}: $name', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(hint, style: text.labelSmall?.copyWith(color: p.muted)),
                ],
              ),
            ),
            AppIconView(AppIcons.restricted, size: 16, color: p.muted),
          ],
        ),
      ),
    );
  }
}

/// A Jalali day (year, month, day) on the shared select, for task, sprint
/// and milestone dates. The time part of [value] is kept as is.
class TaskDateField extends StatelessWidget {
  const TaskDateField({super.key, required this.value, required this.onChanged});

  final JalaliStamp value;
  final ValueChanged<JalaliStamp>? onChanged;

  @override
  Widget build(BuildContext context) {
    final length = Jalali(value.year, value.month).monthLength;
    final today = TehranTime.jalali(DateTime.now().toUtc());
    final years = {today.year - 1, today.year, today.year + 1, today.year + 2, value.year}.toList()..sort();
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: AppSelectField<int>(
            fieldKey: const Key('date-day'),
            dense: true,
            label: Fa.dayWord,
            value: value.day.clamp(1, length),
            options: [for (var d = 1; d <= length; d++) AppSelectOption(value: d, label: persianDigits(d))],
            searchable: false,
            onChanged: onChanged == null ? null : (d) => onChanged!(value.copyWith(day: d)),
          ),
        ),
        const SizedBox(width: AppSpace.s),
        Expanded(
          flex: 3,
          child: AppSelectField<int>(
            fieldKey: const Key('date-month'),
            dense: true,
            label: Fa.monthWord,
            value: value.month,
            options: [for (var m = 1; m <= 12; m++) AppSelectOption(value: m, label: jalaliMonths[m - 1])],
            searchable: false,
            onChanged: onChanged == null ? null : (m) => onChanged!(value.copyWith(month: m)),
          ),
        ),
        const SizedBox(width: AppSpace.s),
        Expanded(
          flex: 2,
          child: AppSelectField<int>(
            fieldKey: const Key('date-year'),
            dense: true,
            label: Fa.yearWord,
            value: value.year,
            options: [for (final y in years) AppSelectOption(value: y, label: persianDigits(y))],
            searchable: false,
            onChanged: onChanged == null ? null : (y) => onChanged!(value.copyWith(year: y)),
          ),
        ),
      ],
    );
  }
}

// ==================================================================== shared form parts

class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.s),
          child,
        ],
      ),
    );
  }
}

class PriorityPicker extends StatelessWidget {
  const PriorityPicker({super.key, required this.value, required this.onChanged, this.enabled = true});

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Wrap(
      spacing: AppSpace.s,
      runSpacing: AppSpace.s,
      children: [
        for (final item in const ['low', 'medium', 'high', 'critical'])
          ChoiceChip(
            key: ValueKey('priority-$item'),
            showCheckmark: false,
            avatar: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: priorityTone(p, item), shape: BoxShape.circle),
            ),
            label: Text(priorityLabel(item)),
            selected: value == item,
            onSelected: enabled ? (_) => onChanged(item) : null,
          ),
      ],
    );
  }
}

/// A person shown by name with an avatar, never by id; tap to change.
class PersonField extends StatelessWidget {
  const PersonField({super.key, required this.person, this.onTap, this.onClear, this.label, this.emptyLabel = Fa.pickPerson});

  final NamedPerson? person;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final String? label;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final name = person?.name ?? emptyLabel;
    return Semantics(
      button: onTap != null,
      label: '${label ?? ''} $name',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, AppSpace.xs, AppSpace.xs, AppSpace.xs),
            decoration: BoxDecoration(
              border: Border.all(color: p.outline),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              children: [
                if (person != null) PersonAvatar(name: person!.name, size: 26) else AppIconView(AppIcons.people, size: 20, color: p.muted),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (label != null) Text(label!, style: text.labelSmall?.copyWith(color: p.muted)),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(color: person == null ? p.muted : p.ink),
                      ),
                    ],
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: Fa.reset,
                    onPressed: onClear,
                    icon: AppIconView(AppIcons.close, size: 18, color: p.muted, semanticLabel: Fa.reset),
                  ),
                if (onTap != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.s),
                    child: Text(Fa.changePerson, style: text.labelLarge?.copyWith(color: p.jade)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Picks a person: suggestions first, then a name search over active
/// profiles (RLS decides who is listed). Returns `(person: null)` for the
/// "none" choice when [noneLabel] is given; null when dismissed.
Future<({NamedPerson? person})?> showPersonPicker(
  BuildContext context, {
  required String title,
  required List<NamedPerson> suggestions,
  required String selfId,
  required String selfName,
  String? noneLabel,
}) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  final picker = _PersonPicker(title: title, suggestions: suggestions, noneLabel: noneLabel, selfId: selfId, selfName: selfName);
  if (compact) {
    return showModalBottomSheet<({NamedPerson? person})>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(height: MediaQuery.sizeOf(context).height * 0.8, child: picker),
      ),
    );
  }
  return showDialog<({NamedPerson? person})>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560), child: picker),
    ),
  );
}

class _PersonPicker extends ConsumerStatefulWidget {
  const _PersonPicker({required this.title, required this.suggestions, required this.selfId, required this.selfName, this.noneLabel});

  final String title;
  final List<NamedPerson> suggestions;
  final String selfId;
  final String selfName;
  final String? noneLabel;

  @override
  ConsumerState<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends ConsumerState<_PersonPicker> {
  final _search = TextEditingController();
  String query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final searching = query.trim().isNotEmpty;
    final found = searching ? ref.watch(peopleProvider(query.trim())) : null;
    final rows = searching
        ? [for (final person in found?.asData?.value ?? const <NamedPerson>[]) person.id == widget.selfId ? NamedPerson(id: person.id, name: widget.selfName) : person]
        : widget.suggestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, AppSpace.l, AppSpace.s, AppSpace.s),
          child: Row(
            children: [
              Expanded(child: Text(widget.title, style: text.titleLarge)),
              IconButton(
                tooltip: Fa.close,
                onPressed: () => Navigator.pop(context),
                icon: const AppIconView(AppIcons.close, semanticLabel: Fa.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          child: TextField(
            key: const Key('person-search'),
            controller: _search,
            autofocus: true,
            onChanged: (value) => setState(() => query = value),
            decoration: InputDecoration(
              hintText: Fa.searchPeople,
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: AppIconView(AppIcons.search, size: 18, color: p.muted),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.s),
        if (found != null && found.isLoading) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpace.l),
            children: [
              if (widget.noneLabel != null && !searching)
                ListTile(
                  leading: AppIconView(AppIcons.people, color: p.muted),
                  title: Text(widget.noneLabel!),
                  onTap: () => Navigator.pop<({NamedPerson? person})>(context, (person: null)),
                ),
              for (final person in rows)
                ListTile(
                  key: ValueKey('person-${person.id}'),
                  leading: PersonAvatar(name: person.name, size: 30),
                  title: Text(person.name),
                  onTap: () => Navigator.pop<({NamedPerson? person})>(context, (person: person)),
                ),
              // A failed search is an error, not an empty or one-person list.
              if (found != null && found.hasError && !found.isLoading)
                Padding(
                  key: const Key('person-search-error'),
                  padding: const EdgeInsets.all(AppSpace.l),
                  child: InlineError(message: taskErrorText(found.error!), onRetry: () => ref.invalidate(peopleProvider(query.trim()))),
                )
              else if (rows.isEmpty && (found == null || !found.isLoading))
                Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Text(searching ? Fa.noPerson : Fa.peopleHint, textAlign: TextAlign.center, style: text.bodySmall),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
