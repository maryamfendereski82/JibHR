import 'package:supabase_flutter/supabase_flutter.dart';

import '../attendance/attendance_review.dart';
import 'work_rules.dart';

const _planTaskColumns = '''
task_id, removed_at, carried_from_sprint_id, added_at,
tasks!inner(
  id, title, priority, primary_assignee_id, status_id, approval_required, approval_state, archived_at,
  assignee:profiles!tasks_primary_assignee_id_fkey(first_name, last_name),
  workflow_statuses(name, category)
)
''';

class PlanCounts {
  const PlanCounts({required this.total, required this.complete, required this.blocked});

  final int total;
  final int complete;
  final int blocked;

  int get remaining => total - complete;
  int get pending => planPending(total, complete, blocked);
  int get percent => progressPercent(complete, total);

  static const zero = PlanCounts(total: 0, complete: 0, blocked: 0);

  static PlanCounts? fromSummary(dynamic value) {
    final row = asMap(value);
    if (row == null || row.isEmpty) return null;
    return PlanCounts(total: _int(row['total']), complete: _int(row['complete']), blocked: _int(row['blocked']));
  }
}

class SprintRow {
  const SprintRow({
    required this.id,
    required this.name,
    required this.description,
    required this.startDate,
    required this.endDate,
    required this.status,
    this.summary,
  });

  final String id;
  final String name;
  final String description;
  final String startDate;
  final String endDate;
  final String status;
  final PlanCounts? summary;
}

class MilestoneRow {
  const MilestoneRow({
    required this.id,
    required this.title,
    required this.description,
    required this.targetDate,
    required this.status,
  });

  final String id;
  final String title;
  final String description;
  final String targetDate;
  final String status;
}

class PlanTaskRow {
  const PlanTaskRow({
    required this.id,
    required this.title,
    required this.priority,
    required this.statusId,
    required this.statusName,
    required this.statusCategory,
    required this.assigneeName,
    required this.approvalRequired,
    required this.approvalState,
    required this.removed,
    this.assigneeId,
  });

  final String id;
  final String title;
  final String priority;
  final String statusId;
  final String statusName;
  final String statusCategory;
  final String? assigneeId;
  final String assigneeName;
  final bool approvalRequired;
  final String approvalState;
  final bool removed;

  bool get complete => taskCountsComplete(
        category: statusCategory,
        approvalRequired: approvalRequired,
        approvalState: approvalState,
      );
}

class PlanBreakdown {
  const PlanBreakdown({required this.kind, required this.bucket, required this.total});

  final String kind;
  final String bucket;
  final int total;
}

class PlanRepository {
  PlanRepository(this._client);

  final SupabaseClient _client;

  Future<({List<SprintRow> rows, int total})> sprints({
    required String projectId,
    String? status,
    List<String>? statuses,
    String search = '',
    int page = 0,
  }) async {
    final bounds = pageRange(page, taskPageSize);
    var query = _client.from('sprints').select('id, name, description, start_date, end_date, status, summary').eq('project_id', projectId);
    if (statuses != null && statuses.isNotEmpty) {
      query = query.inFilter('status', statuses);
    } else if (status != null) {
      query = query.eq('status', status);
    }
    final like = _like(search);
    if (like != null) query = query.ilike('name', '%$like%');
    final response = await query.order('start_date').range(bounds.start, bounds.end).count(CountOption.exact);
    return (rows: [for (final row in asMaps(response.data)) _sprint(row)], total: response.count);
  }

  Future<SprintRow?> sprint(String id) async {
    final row = await _client.from('sprints').select('id, name, description, start_date, end_date, status, summary').eq('id', id).maybeSingle();
    if (row == null) return null;
    return _sprint(row);
  }

  Future<Map<String, PlanCounts>> sprintCounts(String projectId) async {
    final rows = asMaps(await _client.rpc('project_sprint_counts', params: {'p_project': projectId}));
    return {for (final row in rows) row['sprint_id'].toString(): _counts(row)};
  }

  Future<List<PlanBreakdown>> sprintBreakdown(String sprintId) async {
    final rows = asMaps(await _client.rpc('sprint_breakdown', params: {'p_sprint': sprintId}));
    return [
      for (final row in rows)
        PlanBreakdown(kind: row['kind']?.toString() ?? '', bucket: row['bucket']?.toString() ?? '', total: _int(row['total'])),
    ];
  }

  Future<({List<PlanTaskRow> tasks, int total})> sprintTasks({
    required String sprintId,
    required bool history,
    String? statusId,
    String? priority,
    String? assigneeId,
    int page = 0,
  }) async {
    final bounds = pageRange(page, taskPageSize);
    var query = _client.from('sprint_tasks').select(_planTaskColumns).eq('sprint_id', sprintId);
    query = history ? query.not('removed_at', 'is', null) : query.isFilter('removed_at', null);
    query = query.isFilter('tasks.archived_at', null);
    if (statusId != null) query = query.eq('tasks.status_id', statusId);
    if (priority != null) query = query.eq('tasks.priority', priority);
    if (assigneeId != null) query = query.eq('tasks.primary_assignee_id', assigneeId);
    final response = await query.order('added_at', ascending: false).range(bounds.start, bounds.end).count(CountOption.exact);
    return (tasks: [for (final row in asMaps(response.data)) _task(row)], total: response.count);
  }

  Future<String> createSprint({
    required String projectId,
    required String name,
    required String description,
    required String start,
    required String end,
    List<String> tasks = const [],
  }) async {
    final id = await _client.rpc('create_sprint', params: {
      'p_project': projectId,
      'p_name': name,
      'p_description': description,
      'p_start': start,
      'p_end': end,
      'p_tasks': tasks,
    });
    return id.toString();
  }

  Future<void> updateSprint(SprintRow sprint) {
    return _client.rpc('update_sprint', params: {
      'p_sprint': sprint.id,
      'p_name': sprint.name,
      'p_description': sprint.description,
      'p_start': sprint.startDate,
      'p_end': sprint.endDate,
    });
  }

  Future<void> setSprintStatus(String sprintId, String status) {
    return _client.rpc('set_sprint_status', params: {'p_sprint': sprintId, 'p_status': status});
  }

  Future<void> moveTask(String taskId, String sprintId) {
    return _client.rpc('move_task_to_sprint', params: {'p_task': taskId, 'p_sprint': sprintId});
  }

  Future<void> removeTask(String taskId, String sprintId) {
    return _client.rpc('remove_task_from_sprint', params: {'p_task': taskId, 'p_sprint': sprintId});
  }

  Future<void> transferRemainder(String fromSprintId, String toSprintId) {
    return _client.rpc('transfer_sprint_remainder', params: {'p_from': fromSprintId, 'p_to': toSprintId});
  }

  Future<({List<MilestoneRow> rows, int total})> milestones({
    required String projectId,
    String? status,
    int page = 0,
  }) async {
    final bounds = pageRange(page, taskPageSize);
    var query = _client.from('milestones').select('id, title, description, target_date, status').eq('project_id', projectId);
    if (status != null) query = query.eq('status', status);
    final response = await query.order('target_date').range(bounds.start, bounds.end).count(CountOption.exact);
    return (rows: [for (final row in asMaps(response.data)) _milestone(row)], total: response.count);
  }

  Future<MilestoneRow?> milestone(String id) async {
    final row = await _client.from('milestones').select('id, title, description, target_date, status').eq('id', id).maybeSingle();
    if (row == null) return null;
    return _milestone(row);
  }

  Future<Map<String, PlanCounts>> milestoneCounts(String projectId) async {
    final rows = asMaps(await _client.rpc('project_milestone_counts', params: {'p_project': projectId}));
    return {for (final row in rows) row['milestone_id'].toString(): _counts(row)};
  }

  Future<({List<PlanTaskRow> tasks, int total})> milestoneTasks({required String milestoneId, int page = 0}) async {
    final bounds = pageRange(page, taskPageSize);
    final response = await _client
        .from('milestone_tasks')
        .select(_planTaskColumns)
        .eq('milestone_id', milestoneId)
        .isFilter('tasks.archived_at', null)
        .order('task_id')
        .range(bounds.start, bounds.end)
        .count(CountOption.exact);
    return (tasks: [for (final row in asMaps(response.data)) _task(row)], total: response.count);
  }

  Future<String> createMilestone({
    required String projectId,
    required String title,
    required String description,
    required String target,
    List<String> tasks = const [],
  }) async {
    final id = await _client.rpc('create_milestone', params: {
      'p_project': projectId,
      'p_title': title,
      'p_description': description,
      'p_target': target,
      'p_tasks': tasks,
    });
    return id.toString();
  }

  Future<void> updateMilestone(MilestoneRow milestone) {
    return _client.rpc('update_milestone', params: {
      'p_milestone': milestone.id,
      'p_title': milestone.title,
      'p_description': milestone.description,
      'p_target': milestone.targetDate,
    });
  }

  Future<void> setMilestoneStatus(String milestoneId, String status, {String reason = ''}) {
    return _client.rpc('set_milestone_status', params: {
      'p_milestone': milestoneId,
      'p_status': status,
      'p_reason': reason,
    });
  }

  Future<void> linkTask(String milestoneId, String taskId) {
    return _client.rpc('link_milestone_task', params: {'p_milestone': milestoneId, 'p_task': taskId});
  }

  Future<void> unlinkTask(String milestoneId, String taskId) {
    return _client.rpc('unlink_milestone_task', params: {'p_milestone': milestoneId, 'p_task': taskId});
  }

  SprintRow _sprint(Map<String, dynamic> row) {
    return SprintRow(
      id: row['id'].toString(),
      name: row['name']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      startDate: _day(row['start_date']),
      endDate: _day(row['end_date']),
      status: row['status']?.toString() ?? 'planned',
      summary: PlanCounts.fromSummary(row['summary']),
    );
  }

  MilestoneRow _milestone(Map<String, dynamic> row) {
    return MilestoneRow(
      id: row['id'].toString(),
      title: row['title']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      targetDate: _day(row['target_date']),
      status: row['status']?.toString() ?? 'upcoming',
    );
  }

  PlanTaskRow _task(Map<String, dynamic> row) {
    final task = asMap(row['tasks']) ?? const {};
    final status = asMap(task['workflow_statuses']);
    return PlanTaskRow(
      id: row['task_id']?.toString() ?? task['id']?.toString() ?? '',
      title: task['title']?.toString() ?? '',
      priority: task['priority']?.toString() ?? 'medium',
      statusId: task['status_id']?.toString() ?? '',
      statusName: status?['name']?.toString() ?? '',
      statusCategory: status?['category']?.toString() ?? '',
      assigneeId: task['primary_assignee_id']?.toString(),
      assigneeName: personName(asMap(task['assignee'])),
      approvalRequired: task['approval_required'] == true,
      approvalState: task['approval_state']?.toString() ?? 'not_required',
      removed: row['removed_at'] != null,
    );
  }
}

PlanCounts _counts(Map<String, dynamic> row) {
  return PlanCounts(total: _int(row['total']), complete: _int(row['complete']), blocked: _int(row['blocked']));
}

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

String _day(dynamic value) => value?.toString().split('T').first ?? '';

String? _like(String value) {
  final trimmed = value.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
  if (trimmed.isEmpty) return null;
  return trimmed;
}
