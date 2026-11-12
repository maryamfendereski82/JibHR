import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';
import '../attendance/attendance_review.dart';

const taskPageSize = 30;

/// shortcut: a picker shows 50 people, type a name to reach the rest
const peoplePageSize = 50;

int checklistPercent(int done, int total) {
  if (total <= 0) return 0;
  return ((done * 100) / total).round();
}

({int start, int end}) pageRange(int page, int size) {
  final start = page * size;
  return (start: start, end: start + size - 1);
}

bool employeeCanReopenRejected({required bool canManage, required bool canViewAll}) {
  return canManage || canViewAll;
}

bool subtaskNestingAllowed({required bool parentAlreadyHasParent}) => !parentAlreadyHasParent;

String priorityLabel(String priority) => switch (priority) {
  'low' => Fa.priorityLow,
  'high' => Fa.priorityHigh,
  'critical' => Fa.priorityCritical,
  _ => Fa.priorityMedium,
};

String approvalLabel(String state) => switch (state) {
  'approved' => Fa.approved,
  'changes_requested' => Fa.changesRequested,
  'rejected' => Fa.rejected,
  'pending' => Fa.pending,
  _ => Fa.approvalOptional,
};

String activityLabel(String action) => switch (action) {
  'task.create' => 'تسک ساخته شد',
  'task.update' => 'تسک ویرایش شد',
  'task.assign' => 'مسئول عوض شد',
  'task.priority' => 'اولویت عوض شد',
  'task.due' => 'مهلت عوض شد',
  'task.approval' => 'سیاست تأیید عوض شد',
  'task.collaborator' => 'همکار اضافه شد',
  'task.collaborator_remove' => 'همکار برداشته شد',
  'task.labels' => 'برچسب‌ها عوض شد',
  'task.transition' => 'وضعیت عوض شد',
  'task.review' => 'بررسی ثبت شد',
  'task.subtask' => 'زیرتسک ساخته شد',
  'task.subtask_done' => 'زیرتسک تمام شد',
  'task.override' => 'محدودیت زیرتسک رد شد',
  'checklist.add' => 'آیتم چک‌لیست اضافه شد',
  'checklist.toggle' => 'آیتم چک‌لیست عوض شد',
  'checklist.edit' => 'آیتم چک‌لیست ویرایش شد',
  'checklist.delete' => 'آیتم چک‌لیست حذف شد',
  'checklist.move' => 'ترتیب چک‌لیست عوض شد',
  'task.sprint' => 'تسک به اسپرینت رفت',
  'task.sprint_remove' => 'تسک از اسپرینت برداشته شد',
  _ => action,
};

/// Eligible completion is category done or approved, and approval satisfied.
/// Empty plans are 0 percent. Division matches the SQL integer percent.
int progressPercent(int complete, int total) {
  if (total <= 0) return 0;
  return (complete * 100) ~/ total;
}

int planPending(int total, int complete, int blocked) {
  final value = total - complete - blocked;
  return value < 0 ? 0 : value;
}

bool taskCountsComplete({required String category, required bool approvalRequired, required String approvalState, bool archived = false}) {
  if (archived) return false;
  final finished = category == 'done' || category == 'approved';
  return finished && (!approvalRequired || approvalState == 'approved');
}

/// Order of the open-task queries: due date ascending, undated last, then id.
int compareByDue(DateTime? dueA, String idA, DateTime? dueB, String idB) {
  if (dueA == null && dueB != null) return 1;
  if (dueA != null && dueB == null) return -1;
  if (dueA != null && dueB != null) {
    final byDue = dueA.compareTo(dueB);
    if (byDue != 0) return byDue;
  }
  return idA.compareTo(idB);
}

/// Sort key of the board order, the default of every task list.
const boardSort = 'board';

/// Same numbers as the generated `tasks.priority_rank` column.
int priorityRank(String priority) => switch (priority) {
  'critical' => 4,
  'high' => 3,
  'medium' => 2,
  'low' => 1,
  _ => 0,
};

/// The board order, applied by the server (`WorkRepository.tasks` with
/// [boardSort]) and mirrored here for tests and merges:
///   1. priority, critical first;
///   2. due date, nearest first, undated after dated;
///   3. created_at, oldest first (stable tie-breaker);
///   4. id.
/// The id comparison matches Postgres' uuid order for lowercase uuids.
int compareBoardOrder({
  required String priorityA,
  required DateTime? dueA,
  required DateTime createdA,
  required String idA,
  required String priorityB,
  required DateTime? dueB,
  required DateTime createdB,
  required String idB,
}) {
  final byPriority = priorityRank(priorityB).compareTo(priorityRank(priorityA));
  if (byPriority != 0) return byPriority;
  if (dueA == null && dueB != null) return 1;
  if (dueA != null && dueB == null) return -1;
  if (dueA != null && dueB != null) {
    final byDue = dueA.compareTo(dueB);
    if (byDue != 0) return byDue;
  }
  final byCreated = createdA.compareTo(createdB);
  if (byCreated != 0) return byCreated;
  return idA.compareTo(idB);
}

/// Merges two lists that are each already in that order and keeps the first
/// [limit]. A row present in both is kept once.
List<T> mergeOrdered<T>(List<T> a, List<T> b, int limit, {required String Function(T) id, required DateTime? Function(T) due}) {
  final seen = <String>{};
  final out = <T>[];
  var i = 0;
  var j = 0;
  while (out.length < limit && (i < a.length || j < b.length)) {
    final T next;
    if (j >= b.length || (i < a.length && compareByDue(due(a[i]), id(a[i]), due(b[j]), id(b[j])) <= 0)) {
      next = a[i++];
    } else {
      next = b[j++];
    }
    if (seen.add(id(next))) out.add(next);
  }
  return out;
}

bool sprintRangeValid(String startIso, String endIso) => endIso.compareTo(startIso) >= 0;

bool canManagePlan({required bool manageTasks, required bool editProject, required bool viewAll, required bool projectManager}) {
  return manageTasks && editProject && (viewAll || projectManager);
}

String formatPlanDate(String iso) {
  final parts = iso.split('-');
  if (parts.length < 3) return iso;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return iso;
  return TehranTime.formatDate(DateTime.utc(year, month, day, 12));
}

String sprintStatusLabel(String status) => switch (status) {
  'active' => Fa.activeLabel,
  'closed' => Fa.sprintClosed,
  'cancelled' => Fa.sprintCancelled,
  _ => Fa.planned,
};

String milestoneStatusLabel(String status) => switch (status) {
  'in_progress' => Fa.milestoneProgress,
  'reached' => Fa.reached,
  'cancelled' => Fa.sprintCancelled,
  _ => Fa.upcoming,
};

bool dueOnJalaliDay(DateTime? due, int year, int month, int day) {
  if (due == null) return false;
  final jalali = TehranTime.jalali(due.toUtc());
  return jalali.year == year && jalali.month == month && jalali.day == day;
}

String taskErrorText(Object error) {
  final raw = error.toString();
  if (raw.contains('nesting_limit')) return Fa.nestingLimit;
  if (raw.contains('subtasks_incomplete')) return Fa.subtasksIncomplete;
  if (raw.contains('approval_required')) return Fa.approvalBypass;
  if (raw.contains('rejected_closed')) return Fa.rejectedClosed;
  if (raw.contains('transition_denied')) return Fa.transitionDenied;
  if (raw.contains('status_in_use')) return Fa.statusInUse;
  if (raw.contains('status_inactive')) return Fa.statusInactive;
  if (raw.contains('status_required')) return Fa.statusRequired;
  if (raw.contains('last_manager')) return Fa.lastManager;
  if (raw.contains('not_submitted')) return Fa.notSubmitted;
  if (raw.contains('invalid_label')) return Fa.invalidLabel;
  if (raw.contains('already_active')) return Fa.alreadyActive;
  if (raw.contains('tasks_incomplete')) return Fa.tasksIncomplete;
  if (raw.contains('project_mismatch')) return Fa.projectMismatch;
  if (raw.contains('invalid_status')) return Fa.invalidStatus;
  if (raw.contains('invalid_name') || raw.contains('invalid_priority')) return Fa.invalidRange;
  return reviewErrorText(error);
}
