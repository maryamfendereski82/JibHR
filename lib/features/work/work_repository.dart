import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import '../attendance/attendance_review.dart';
import 'work_rules.dart';

const _taskColumns = '''
id, title, description, project_id, parent_task_id, primary_assignee_id, reviewer_id,
status_id, priority, due_at, approval_required, approval_state, is_required,
created_at, updated_at,
assignee:profiles!tasks_primary_assignee_id_fkey(first_name, last_name),
reviewer:profiles!tasks_reviewer_id_fkey(first_name, last_name),
projects(name),
workflow_statuses(id, key, name, category, position),
task_collaborators(profile_id, profiles!task_collaborators_profile_id_fkey(first_name, last_name)),
task_labels(label_id, labels(name, is_active))
''';

const _detailColumns = '''
$_taskColumns,
creator:profiles!tasks_created_by_fkey(first_name, last_name),
task_checklist_items(id, title, is_done, position),
task_activity_events(id, action, metadata, created_at, actor:profiles!task_activity_events_actor_id_fkey(first_name, last_name)),
task_review_rounds(id, round_number, opened_at, task_reviews(decision, reason, created_at, reviewer:profiles!task_reviews_reviewer_id_fkey(first_name, last_name)))
''';

typedef TaskFilter = ({
  String? projectId,
  bool personal,
  String? assigneeId,
  String? statusId,
  String? priority,
  String search,
  String? dueFrom,
  String? dueTo,
  int page,
  String sort,
});

class TaskPage {
  const TaskPage({required this.tasks, required this.total});

  final List<TaskRow> tasks;
  final int total;

  static const empty = TaskPage(tasks: [], total: 0);
}

class NamedPerson {
  const NamedPerson({required this.id, required this.name});
  final String id;
  final String name;
}

class TaskRow {
  const TaskRow({
    required this.id,
    required this.title,
    required this.description,
    required this.priority,
    required this.approvalRequired,
    required this.approvalState,
    required this.requiredSubtask,
    required this.assigneeName,
    required this.statusId,
    required this.statusName,
    required this.statusKey,
    required this.statusCategory,
    required this.collaborators,
    required this.labels,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.projectName,
    this.parentId,
    this.assigneeId,
    this.reviewerId,
    this.reviewerName,
    this.creatorName,
    this.dueAt,
    this.checklist = const [],
    this.activity = const [],
    this.reviews = const [],
    this.subtasks = const [],
  });

  final String id;
  final String title;
  final String description;
  final String? projectId;
  final String? projectName;
  final String? parentId;
  final String priority;
  final bool approvalRequired;
  final String approvalState;
  final bool requiredSubtask;
  final String? assigneeId;
  final String assigneeName;
  final String? reviewerId;
  final String? reviewerName;
  final String? creatorName;
  final String statusId;
  final String statusName;
  final String statusKey;
  final String statusCategory;
  final DateTime? dueAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<NamedPerson> collaborators;
  final List<NamedPerson> labels;
  final List<ChecklistRow> checklist;
  final List<ActivityRow> activity;
  final List<ReviewRow> reviews;
  final List<TaskRow> subtasks;

  int get checklistDone => checklist.where((item) => item.done).length;

  String get dueLabel => dueAt == null ? '' : TehranTime.formatDate(dueAt!);
}

class ChecklistRow {
  const ChecklistRow({required this.id, required this.title, required this.done, required this.position});
  final String id;
  final String title;
  final bool done;
  final int position;
}

class ActivityRow {
  const ActivityRow({required this.action, required this.createdAt, required this.actor});
  final String action;
  final DateTime createdAt;
  final String actor;
}

class ReviewRow {
  const ReviewRow({required this.round, required this.decision, required this.createdAt, this.reason, this.reviewer});
  final int round;
  final String decision;
  final String? reason;
  final String? reviewer;
  final DateTime createdAt;
}

class ProjectRow {
  const ProjectRow({
    required this.id,
    required this.name,
    required this.description,
    required this.visibility,
    required this.approvalRequired,
    required this.status,
    required this.createdAt,
    required this.creatorName,
    required this.members,
    required this.labels,
    this.workflow,
  });

  final String id;
  final String name;
  final String description;
  final String visibility;
  final bool approvalRequired;
  final String status;
  final DateTime createdAt;
  final String creatorName;
  final List<MemberRow> members;
  final List<LabelRow> labels;
  final WorkflowRow? workflow;
}

class MemberRow {
  const MemberRow({required this.profileId, required this.name, required this.role});
  final String profileId;
  final String name;
  final String role;
}

class LabelRow {
  const LabelRow({required this.id, required this.name, required this.active});
  final String id;
  final String name;
  final bool active;
}

class WorkflowRow {
  const WorkflowRow({required this.id, required this.statuses, required this.transitions});
  final String id;
  final List<StatusRow> statuses;
  final List<({String from, String to})> transitions;
}

class StatusRow {
  const StatusRow({
    required this.id,
    required this.key,
    required this.name,
    required this.category,
    required this.position,
    required this.requiresAuthority,
    required this.active,
  });

  final String id;
  final String key;
  final String name;
  final String category;
  final int position;
  final bool requiresAuthority;
  final bool active;
}

class WorkRepository {
  WorkRepository(this._client);

  final SupabaseClient _client;

  Future<({List<ProjectRow> projects, int total})> projects({required bool archived, required int page}) async {
    final bounds = pageRange(page, taskPageSize);
    final response = await _client
        .from('projects')
        .select('''
id, name, description, visibility, approval_required, status, created_at,
creator:profiles!projects_created_by_fkey(first_name, last_name)
''')
        .eq('status', archived ? 'archived' : 'active')
        .order('created_at', ascending: false)
        .range(bounds.start, bounds.end)
        .count(CountOption.exact);
    return (
      projects: [for (final row in asMaps(response.data)) _project(row)],
      total: response.count,
    );
  }

  Future<ProjectRow?> project(String id) async {
    final row = await _client.from('projects').select('''
id, name, description, visibility, approval_required, status, created_at,
creator:profiles!projects_created_by_fkey(first_name, last_name),
project_members(profile_id, member_role, removed_at, profiles!project_members_profile_id_fkey(first_name, last_name)),
labels(id, name, is_active),
workflows(
  id,
  workflow_statuses(id, key, name, category, position, requires_authority, is_active),
  workflow_transitions(from_status_id, to_status_id)
)
''').eq('id', id).maybeSingle();
    if (row == null) return null;
    return _project(row, withChildren: true);
  }

  Future<WorkflowRow?> personalWorkflow() async {
    final row = await _client.from('workflows').select('''
id,
workflow_statuses(id, key, name, category, position, requires_authority, is_active),
workflow_transitions(from_status_id, to_status_id)
''').isFilter('project_id', null).maybeSingle();
    if (row == null) return null;
    final statuses = [for (final status in asMaps(row['workflow_statuses'])) _status(status)]
      ..sort((a, b) => a.position.compareTo(b.position));
    return WorkflowRow(
      id: row['id'].toString(),
      statuses: [for (final status in statuses) if (status.active) status],
      transitions: [
        for (final edge in asMaps(row['workflow_transitions']))
          (from: edge['from_status_id'].toString(), to: edge['to_status_id'].toString()),
      ],
    );
  }

  Future<TaskPage> tasks(TaskFilter filter) async {
    final bounds = pageRange(filter.page, taskPageSize);
    var query = _client.from('tasks').select(_taskColumns);
    if (filter.personal) query = query.isFilter('project_id', null);
    if (filter.projectId != null) query = query.eq('project_id', filter.projectId!);
    if (filter.assigneeId != null) query = query.eq('primary_assignee_id', filter.assigneeId!);
    if (filter.statusId != null) query = query.eq('status_id', filter.statusId!);
    if (filter.priority != null) query = query.eq('priority', filter.priority!);
    final search = _like(filter.search);
    if (search != null) query = query.ilike('title', '%$search%');
    if (filter.dueFrom != null) query = query.gte('due_at', filter.dueFrom!);
    if (filter.dueTo != null) query = query.lt('due_at', filter.dueTo!);
    final ascending = filter.sort != 'updated_at';
    final response = await query.order(filter.sort, ascending: ascending).range(bounds.start, bounds.end).count(CountOption.exact);
    return TaskPage(
      tasks: [for (final row in asMaps(response.data)) _task(row)],
      total: response.count,
    );
  }

  Future<TaskRow?> task(String id) async {
    final row = await _client.from('tasks').select(_detailColumns).eq('id', id).maybeSingle();
    if (row == null) return null;
    final task = _task(row, detailed: true);
    final children = await _client.from('tasks').select(_taskColumns).eq('parent_task_id', id).order('created_at');
    return TaskRow(
      id: task.id,
      title: task.title,
      description: task.description,
      projectId: task.projectId,
      projectName: task.projectName,
      parentId: task.parentId,
      priority: task.priority,
      approvalRequired: task.approvalRequired,
      approvalState: task.approvalState,
      requiredSubtask: task.requiredSubtask,
      assigneeId: task.assigneeId,
      assigneeName: task.assigneeName,
      reviewerId: task.reviewerId,
      reviewerName: task.reviewerName,
      creatorName: task.creatorName,
      statusId: task.statusId,
      statusName: task.statusName,
      statusKey: task.statusKey,
      statusCategory: task.statusCategory,
      dueAt: task.dueAt,
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      collaborators: task.collaborators,
      labels: task.labels,
      checklist: task.checklist,
      activity: task.activity,
      reviews: task.reviews,
      subtasks: [for (final child in asMaps(children)) _task(child)],
    );
  }

  Future<List<NamedPerson>> people(String search) async {
    var query = _client.from('profiles').select('id, first_name, last_name').eq('status', 'active');
    final needle = _like(search);
    if (needle != null) {
      query = query.or('first_name.ilike.%$needle%,last_name.ilike.%$needle%');
    }
    final rows = await query.order('first_name').limit(peoplePageSize);
    return [
      for (final row in asMaps(rows))
        NamedPerson(id: row['id'].toString(), name: personName(row)),
    ];
  }

  Future<String> createProject(String name, String description) async {
    final id = await _client.rpc('create_project', params: {'p_name': name.trim(), 'p_description': description.trim()});
    return id.toString();
  }

  Future<void> updateProject(String id, {required String name, required String description, required bool approval}) {
    return _client.rpc('update_project', params: {
      'p_project': id,
      'p_name': name.trim(),
      'p_description': description.trim(),
      'p_approval': approval,
    });
  }

  Future<void> setVisibility(String id, String visibility) {
    return _client.rpc('set_project_visibility', params: {'p_project': id, 'p_visibility': visibility});
  }

  Future<void> archive(String id, {required bool archived}) {
    return _client.rpc('archive_project', params: {'p_project': id, 'p_archived': archived});
  }

  Future<void> addMember(String projectId, String profileId, String role) {
    return _client.rpc('add_project_member', params: {
      'p_project': projectId,
      'p_profile': profileId,
      'p_role': role,
    });
  }

  Future<void> removeMember(String projectId, String profileId) {
    return _client.rpc('remove_project_member', params: {'p_project': projectId, 'p_profile': profileId});
  }

  Future<void> saveLabel(String projectId, {String? labelId, required String name, required bool active}) {
    return _client.rpc('save_label', params: {
      'p_project': projectId,
      'p_label': labelId,
      'p_name': name.trim(),
      'p_active': active,
    });
  }

  Future<void> saveStatus({
    required String workflowId,
    String? statusId,
    required String name,
    required String category,
    required int position,
    required bool authority,
    required bool active,
  }) {
    return _client.rpc('save_workflow_status', params: {
      'p_workflow': workflowId,
      'p_status': statusId,
      'p_name': name.trim(),
      'p_category': category,
      'p_position': position,
      'p_requires_authority': authority,
      'p_active': active,
    });
  }

  Future<void> setTransition(String from, String to, {required bool allow}) {
    return _client.rpc('set_workflow_transition', params: {
      'p_from': from,
      'p_to': to,
      'p_allow': allow,
    });
  }

  Future<String> createTask({
    required String title,
    required String description,
    String? projectId,
    required String assigneeId,
    required String priority,
    String? dueIso,
    bool? approval,
    String? reviewerId,
    String? parentId,
    bool required = false,
  }) async {
    final id = await _client.rpc('create_task', params: {
      'p_title': title.trim(),
      'p_description': description.trim(),
      'p_project': projectId,
      'p_assignee': assigneeId,
      'p_priority': priority,
      'p_due': dueIso,
      'p_approval': approval,
      'p_reviewer': reviewerId,
      'p_parent': parentId,
      'p_required': required,
    });
    return id.toString();
  }

  Future<void> updateTask(TaskRow task, {String? dueIso}) {
    return _client.rpc('update_task', params: {
      'p_task': task.id,
      'p_title': task.title,
      'p_description': task.description,
      'p_assignee': task.assigneeId,
      'p_reviewer': task.reviewerId,
      'p_priority': task.priority,
      'p_due': dueIso,
      'p_approval': task.approvalRequired,
    });
  }

  Future<void> setLabels(String taskId, List<String> labelIds) {
    return _client.rpc('set_task_labels', params: {'p_task': taskId, 'p_labels': labelIds});
  }

  Future<void> addCollaborator(String taskId, String profileId) {
    return _client.rpc('add_task_collaborator', params: {'p_task': taskId, 'p_profile': profileId});
  }

  Future<void> removeCollaborator(String taskId, String profileId) {
    return _client.rpc('remove_task_collaborator', params: {'p_task': taskId, 'p_profile': profileId});
  }

  Future<void> transition(String taskId, String statusId, {String? overrideReason}) {
    return _client.rpc('transition_task', params: {
      'p_task': taskId,
      'p_status': statusId,
      'p_override_reason': overrideReason,
    });
  }

  Future<void> decide(String taskId, String decision, {String? reason}) {
    return _client.rpc('decide_task', params: {
      'p_task': taskId,
      'p_decision': decision,
      'p_reason': reason,
    });
  }

  Future<void> addChecklist(String taskId, String title) {
    return _client.rpc('add_checklist_item', params: {'p_task': taskId, 'p_title': title.trim()});
  }

  Future<void> toggleChecklist(String itemId, {required bool done}) {
    return _client.rpc('toggle_checklist_item', params: {'p_item': itemId, 'p_done': done});
  }

  Future<void> renameChecklist(String itemId, String title) {
    return _client.rpc('rename_checklist_item', params: {'p_item': itemId, 'p_title': title.trim()});
  }

  Future<void> deleteChecklist(String itemId) {
    return _client.rpc('delete_checklist_item', params: {'p_item': itemId});
  }

  Future<void> moveChecklist(String itemId, int direction) {
    return _client.rpc('move_checklist_item', params: {'p_item': itemId, 'p_direction': direction});
  }

  ProjectRow _project(Map<String, dynamic> row, {bool withChildren = false}) {
    final members = <MemberRow>[];
    final labels = <LabelRow>[];
    WorkflowRow? workflow;
    if (withChildren) {
      for (final member in asMaps(row['project_members'])) {
        if (member['removed_at'] != null) continue;
        members.add(MemberRow(
          profileId: member['profile_id'].toString(),
          name: personName(asMap(member['profiles'])),
          role: member['member_role']?.toString() ?? 'member',
        ));
      }
      for (final label in asMaps(row['labels'])) {
        labels.add(LabelRow(
          id: label['id'].toString(),
          name: label['name']?.toString() ?? '',
          active: label['is_active'] != false,
        ));
      }
      final flows = asMaps(row['workflows']);
      if (flows.isNotEmpty) {
        final flow = flows.first;
        final statuses = [for (final status in asMaps(flow['workflow_statuses'])) _status(status)]
          ..sort((a, b) => a.position.compareTo(b.position));
        workflow = WorkflowRow(
          id: flow['id'].toString(),
          statuses: statuses,
          transitions: [
            for (final edge in asMaps(flow['workflow_transitions']))
              (from: edge['from_status_id'].toString(), to: edge['to_status_id'].toString()),
          ],
        );
      }
    }
    return ProjectRow(
      id: row['id'].toString(),
      name: row['name']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      visibility: row['visibility']?.toString() ?? 'project_wide',
      approvalRequired: row['approval_required'] == true,
      status: row['status']?.toString() ?? 'active',
      createdAt: asTime(row['created_at']) ?? DateTime.now().toUtc(),
      creatorName: personName(asMap(row['creator'])),
      members: members,
      labels: labels,
      workflow: workflow,
    );
  }

  StatusRow _status(Map<String, dynamic> row) {
    return StatusRow(
      id: row['id'].toString(),
      key: row['key']?.toString() ?? '',
      name: row['name']?.toString() ?? '',
      category: row['category']?.toString() ?? 'todo',
      position: row['position'] is int ? row['position'] as int : int.tryParse('${row['position']}') ?? 0,
      requiresAuthority: row['requires_authority'] == true,
      active: row['is_active'] != false,
    );
  }

  TaskRow _task(Map<String, dynamic> row, {bool detailed = false}) {
    final status = asMap(row['workflow_statuses']);
    final checklist = <ChecklistRow>[];
    final activity = <ActivityRow>[];
    final reviews = <ReviewRow>[];
    if (detailed) {
      for (final item in asMaps(row['task_checklist_items'])) {
        checklist.add(ChecklistRow(
          id: item['id'].toString(),
          title: item['title']?.toString() ?? '',
          done: item['is_done'] == true,
          position: item['position'] is int ? item['position'] as int : 0,
        ));
      }
      checklist.sort((a, b) => a.position.compareTo(b.position));
      for (final item in asMaps(row['task_activity_events'])) {
        activity.add(ActivityRow(
          action: item['action']?.toString() ?? '',
          createdAt: asTime(item['created_at']) ?? DateTime.now().toUtc(),
          actor: personName(asMap(item['actor'])),
        ));
      }
      activity.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final round in asMaps(row['task_review_rounds'])) {
        final roundNumber = round['round_number'] is int ? round['round_number'] as int : 0;
        for (final review in asMaps(round['task_reviews'])) {
          reviews.add(ReviewRow(
            round: roundNumber,
            decision: review['decision']?.toString() ?? '',
            reason: review['reason']?.toString(),
            reviewer: personName(asMap(review['reviewer'])),
            createdAt: asTime(review['created_at']) ?? DateTime.now().toUtc(),
          ));
        }
      }
      reviews.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    return TaskRow(
      id: row['id'].toString(),
      title: row['title']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      projectId: row['project_id']?.toString(),
      projectName: asMap(row['projects'])?['name']?.toString(),
      parentId: row['parent_task_id']?.toString(),
      priority: row['priority']?.toString() ?? 'medium',
      approvalRequired: row['approval_required'] == true,
      approvalState: row['approval_state']?.toString() ?? 'not_required',
      requiredSubtask: row['is_required'] == true,
      assigneeId: row['primary_assignee_id']?.toString(),
      assigneeName: personName(asMap(row['assignee'])),
      reviewerId: row['reviewer_id']?.toString(),
      reviewerName: personName(asMap(row['reviewer'])).isEmpty ? null : personName(asMap(row['reviewer'])),
      creatorName: personName(asMap(row['creator'])).isEmpty ? null : personName(asMap(row['creator'])),
      statusId: row['status_id']?.toString() ?? status?['id']?.toString() ?? '',
      statusName: status?['name']?.toString() ?? '',
      statusKey: status?['key']?.toString() ?? '',
      statusCategory: status?['category']?.toString() ?? '',
      dueAt: asTime(row['due_at']),
      createdAt: asTime(row['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: asTime(row['updated_at']) ?? DateTime.now().toUtc(),
      collaborators: [
        for (final item in asMaps(row['task_collaborators']))
          NamedPerson(
            id: item['profile_id'].toString(),
            name: personName(asMap(item['profiles'])),
          ),
      ],
      labels: [
        for (final item in asMaps(row['task_labels']))
          if (asMap(item['labels'])?['is_active'] != false)
            NamedPerson(id: item['label_id'].toString(), name: asMap(item['labels'])?['name']?.toString() ?? ''),
      ],
      checklist: checklist,
      activity: activity,
      reviews: reviews,
    );
  }
}

String? _like(String value) {
  final trimmed = value.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
  if (trimmed.isEmpty) return null;
  return trimmed;
}
