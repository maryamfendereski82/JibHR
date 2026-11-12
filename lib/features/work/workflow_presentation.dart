import 'dart:collection';

import '../../core/localization/fa.dart';
import 'work_repository.dart';

/// Presentation adapter of the five-status workflow.
///
/// The product model has exactly five statuses: در صف انجام (backlog),
/// در حال انجام (in_progress), در حال بررسی (in_review), تأیید شده (approved)
/// and رد شده (rejected). "Needs revision" is a reviewer decision that sends a
/// task back to the queue; "blocked" is a mark inside the rejected group.
///
/// Until the workflow migration runs, the database still stores the old
/// categories. This file maps them for DISPLAY and grouping only; it never
/// writes a status. Every change still goes through the existing RPCs
/// (`transition_task`, `decide_task`) along transitions the stored workflow
/// already allows, so the server keeps every rule and audit.
///
///   backlog, todo, changes_requested → در صف انجام
///   in_progress                      → در حال انجام
///   in_review                        → در حال بررسی
///   approved, done                   → تأیید شده   (checked on the data: the
///                                      only `done` task was approved in review)
///   rejected (mark «رد نهایی»), blocked (mark «مسدود») → رد شده
///
/// After the migration "blocked" is the `blocked_at` flag: [isBlockedTask]
/// and [categoriesForKey] are the only places to change then.
enum TaskGroup { backlog, inProgress, inReview, approved, rejected }

/// Board order of the groups.
const taskGroups = TaskGroup.values;

TaskGroup groupOfCategory(String category) => switch (category) {
  'in_progress' => TaskGroup.inProgress,
  'in_review' => TaskGroup.inReview,
  'approved' || 'done' => TaskGroup.approved,
  'blocked' || 'rejected' => TaskGroup.rejected,
  _ => TaskGroup.backlog,
};

TaskGroup groupOf(TaskRow task) => isBlockedTask(task) ? TaskGroup.rejected : groupOfCategory(task.statusCategory);

/// The only five status names the person ever sees.
String groupLabel(TaskGroup group) => switch (group) {
  TaskGroup.backlog => Fa.groupBacklog,
  TaskGroup.inProgress => Fa.groupInProgress,
  TaskGroup.inReview => Fa.groupInReview,
  TaskGroup.approved => Fa.groupApproved,
  TaskGroup.rejected => Fa.groupRejected,
};

/// The canonical category of a group, for its colour and icon.
String groupCategory(TaskGroup group) => switch (group) {
  TaskGroup.backlog => 'backlog',
  TaskGroup.inProgress => 'in_progress',
  TaskGroup.inReview => 'in_review',
  TaskGroup.approved => 'approved',
  TaskGroup.rejected => 'rejected',
};

String groupKey(TaskGroup group) => 'group:${group.name}';

TaskGroup? groupFromKey(String key) {
  for (final group in TaskGroup.values) {
    if (groupKey(group) == key) return group;
  }
  return null;
}

/// Blocked: today the old `blocked` status; after the migration the
/// `blocked_at` flag (the only line to change then).
bool isBlockedTask(TaskRow task) => task.statusCategory == 'blocked';
bool isBlockedCategory(String category) => category == 'blocked';

/// Final rejection (a reviewer's decision), as opposed to blocked.
bool isFinalRejected(TaskRow task) => task.statusCategory == 'rejected';

/// The two marks of the rejected group. They filter, they are not statuses.
enum RejectedKind { blocked, finalRejected }

String rejectedKindLabel(RejectedKind kind) => kind == RejectedKind.blocked ? Fa.catBlocked : Fa.finalRejectedBadge;

String rejectedKindKey(RejectedKind kind) => 'rejected:${kind.name}';

/// Stored status ids that make up a group (or one rejected mark), as the
/// comma-separated status filter of the task queries. Inactive statuses are
/// included: a task standing in a retired status still belongs somewhere.
String? statusIdsForKey(WorkflowRow? flow, String key) {
  if (flow == null) return null;
  final group = groupFromKey(key);
  bool include(StatusRow s) {
    if (group != null) return groupOfCategory(s.category) == group;
    if (key == rejectedKindKey(RejectedKind.blocked)) return isBlockedCategory(s.category);
    if (key == rejectedKindKey(RejectedKind.finalRejected)) return s.category == 'rejected';
    return s.id == key;
  }

  final ids = [
    for (final s in flow.statuses)
      if (include(s)) s.id,
  ];
  // A group with no stored status matches nothing (never "everything").
  return ids.isEmpty ? '00000000-0000-0000-0000-000000000000' : ids.join(',');
}

/// Stored categories of a group key or rejected mark, for queries that span
/// several workflows (My tasks, personal, project). Null for anything else
/// (a plain status id). After the migration, "blocked" is the `blocked_at`
/// flag rather than a category: this is the one place to change then.
List<String>? categoriesForKey(String? key) {
  if (key == null) return null;
  if (key == rejectedKindKey(RejectedKind.blocked)) return const ['blocked'];
  if (key == rejectedKindKey(RejectedKind.finalRejected)) return const ['rejected'];
  final group = groupFromKey(key);
  if (group == null) return null;
  return switch (group) {
    TaskGroup.backlog => const ['backlog', 'todo', 'changes_requested'],
    TaskGroup.inProgress => const ['in_progress'],
    TaskGroup.inReview => const ['in_review'],
    TaskGroup.approved => const ['approved', 'done'],
    TaskGroup.rejected => const ['blocked', 'rejected'],
  };
}

/// A pseudo status row per group, so board columns, chips and filters can
/// keep their shape. Its id is the group key, never a stored status id.
StatusRow groupColumn(TaskGroup group) =>
    StatusRow(id: groupKey(group), key: group.name, name: groupLabel(group), category: groupCategory(group), position: group.index, requiresAuthority: false, active: true);

List<StatusRow> groupColumns() => [for (final g in taskGroups) groupColumn(g)];

/// Filter choices: the five groups, then the two marks of the rejected group.
List<({String key, String label, String category})> statusFilterChoices() => [
  for (final g in taskGroups) (key: groupKey(g), label: groupLabel(g), category: groupCategory(g)),
  (key: rejectedKindKey(RejectedKind.blocked), label: '${Fa.groupRejected} · ${Fa.catBlocked}', category: 'blocked'),
  (key: rejectedKindKey(RejectedKind.finalRejected), label: '${Fa.groupRejected} · ${Fa.finalRejectedBadge}', category: 'rejected'),
];

String? statusFilterLabel(String? key) {
  if (key == null) return null;
  for (final c in statusFilterChoices()) {
    if (c.key == key) return c.label;
  }
  return null;
}

// ---------------------------------------------------------------- actions

/// The few actions the workflow offers instead of a status menu.
enum TaskAction {
  /// Backlog → In Progress (the primary assignee only).
  start,

  /// In Progress → In Review (the primary assignee only; tasks that need approval).
  submit,

  /// In Progress → Approved for a task that needs NO approval (the primary
  /// assignee only; no reviewer involved).
  complete,

  /// Rejected group (final rejection or blocked) → back into the cycle.
  returnToCycle,

  /// In Progress → blocked mark.
  block,
}

String actionLabel(TaskAction action) => switch (action) {
  TaskAction.start => Fa.actionStart,
  TaskAction.submit => Fa.actionSubmit,
  TaskAction.complete => Fa.actionComplete,
  TaskAction.returnToCycle => Fa.actionReturnToCycle,
  TaskAction.block => Fa.actionBlock,
};

bool _queueCategory(String category) => groupOfCategory(category) == TaskGroup.backlog;

/// The shortest chain of transitions the stored workflow allows from the
/// task's status to a status accepted by [target], passing only through
/// statuses accepted by [via]. Null when the workflow has no such path.
/// Before the migration one action may need several existing transitions
/// (for example queue → todo → in progress); each one is a separate,
/// audited `transition_task` call that the server re-checks.
List<StatusRow>? workflowPath(WorkflowRow flow, String fromStatusId, {required bool Function(StatusRow) target, required bool Function(StatusRow) via}) {
  final byId = {for (final s in flow.statuses) s.id: s};
  final previous = <String, String>{};
  final queue = Queue<String>()..add(fromStatusId);
  final seen = {fromStatusId};
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    for (final edge in flow.transitions.where((e) => e.from == current)) {
      final next = byId[edge.to];
      if (next == null || !next.active || !seen.add(next.id)) continue;
      previous[next.id] = current;
      if (target(next)) {
        final path = <StatusRow>[next];
        var step = current;
        while (step != fromStatusId) {
          path.insert(0, byId[step]!);
          step = previous[step]!;
        }
        return path;
      }
      if (via(next)) queue.add(next.id);
    }
  }
  return null;
}

/// The path an action would take for this task; null when not possible.
List<StatusRow>? actionPath(TaskRow task, WorkflowRow? flow, TaskAction action) {
  if (flow == null) return null;
  final group = groupOf(task);
  switch (action) {
    case TaskAction.start:
      if (group != TaskGroup.backlog) return null;
      return workflowPath(flow, task.statusId, target: (s) => s.category == 'in_progress', via: (s) => _queueCategory(s.category));
    case TaskAction.submit:
      if (group != TaskGroup.inProgress || !task.approvalRequired) return null;
      return workflowPath(flow, task.statusId, target: (s) => s.category == 'in_review', via: (_) => false);
    case TaskAction.complete:
      // No approval: the assignee finishes. Before the migration the only
      // existing route passes through the old in-review status, in one action.
      if (group != TaskGroup.inProgress || task.approvalRequired) return null;
      return workflowPath(flow, task.statusId, target: (s) => groupOfCategory(s.category) == TaskGroup.approved, via: (s) => s.category == 'in_review');
    case TaskAction.returnToCycle:
      if (group != TaskGroup.rejected) return null;
      // Back to the queue when the workflow allows it; before the migration a
      // blocked task's only stored way out is "in progress".
      return workflowPath(flow, task.statusId, target: (s) => _queueCategory(s.category), via: (_) => false) ??
          (isBlockedTask(task) ? workflowPath(flow, task.statusId, target: (s) => s.category == 'in_progress', via: (_) => false) : null);
    case TaskAction.block:
      if (group != TaskGroup.inProgress) return null;
      return workflowPath(flow, task.statusId, target: (s) => isBlockedCategory(s.category), via: (_) => false);
  }
}

/// Who may run an action (client mirror; the server re-checks):
///   start, submit, complete: the primary assignee only;
///   block, return a blocked task: anyone who may edit the task;
///   reopen a final rejection: management permission only.
bool actionAllowed(TaskRow task, TaskAction action, {required bool isAssignee, required bool canEdit, required bool canReopenRejected}) => switch (action) {
  TaskAction.start || TaskAction.submit || TaskAction.complete => isAssignee,
  TaskAction.block => canEdit,
  TaskAction.returnToCycle => isFinalRejected(task) ? canReopenRejected : canEdit,
};

/// The single primary action of a task, by group; null when none applies
/// (in review: the reviewer decides; approved: finished).
TaskAction? primaryAction(TaskRow task) => switch (groupOf(task)) {
  TaskGroup.backlog => TaskAction.start,
  TaskGroup.inProgress => task.approvalRequired ? TaskAction.submit : TaskAction.complete,
  TaskGroup.inReview => null,
  TaskGroup.approved => null,
  TaskGroup.rejected => TaskAction.returnToCycle,
};

/// The action a drop on a board column means; null when the drop is refused.
TaskAction? dropAction(TaskRow task, TaskGroup column) {
  final from = groupOf(task);
  if (from == column) return null;
  return switch (column) {
    TaskGroup.inProgress when from == TaskGroup.backlog => TaskAction.start,
    TaskGroup.inReview when from == TaskGroup.inProgress && task.approvalRequired => TaskAction.submit,
    TaskGroup.approved when from == TaskGroup.inProgress && !task.approvalRequired => TaskAction.complete,
    TaskGroup.backlog when from == TaskGroup.rejected => TaskAction.returnToCycle,
    _ => null,
  };
}
