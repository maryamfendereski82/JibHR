import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/localization/fa.dart';
import '../attendance/attendance_review.dart';
import '../reports/report_rules.dart';
import '../session/workspace_session.dart';
import '../work/work_repository.dart';
import '../work/work_rules.dart';

/// Greeting by the Tehran wall clock.
String greetingFor(DateTime nowUtc) {
  final hour = TehranTime.wallClock(nowUtc).hour;
  if (hour >= 5 && hour < 12) return Fa.greetMorning;
  if (hour >= 12 && hour < 16) return Fa.greetNoon;
  if (hour >= 16 && hour < 20) return Fa.greetAfternoon;
  return Fa.greetNight;
}

/// Whole Tehran calendar days from today to [due]. Negative when past.
int daysUntil(DateTime due, DateTime nowUtc) {
  return TehranTime.dateOnly(due).difference(TehranTime.dateOnly(nowUtc)).inDays;
}

/// "امروز", "فردا", "۳ روز مانده", "۲ روز گذشته", or a Jalali date when far.
String relativeDue(DateTime due, DateTime nowUtc) {
  final days = daysUntil(due, nowUtc);
  if (days == 0) return Fa.agendaToday;
  if (days == 1) return Fa.dueTomorrow;
  if (days == -1) return Fa.dueYesterday;
  if (days > 1 && days <= 14) return '${persianDigits(days)} ${Fa.daysLeft}';
  if (days < -1 && days >= -30) return '${persianDigits(-days)} ${Fa.daysPast}';
  final j = TehranTime.jalali(due);
  return persianDigits('${j.day} ${j.formatter.mN} ${j.year}');
}

enum AgendaGroup { overdue, today, week, later, undated }

AgendaGroup agendaGroupOf(TaskRow task, DateTime nowUtc) {
  final due = task.dueAt;
  if (due == null) return AgendaGroup.undated;
  final days = daysUntil(due, nowUtc);
  if (days < 0) return AgendaGroup.overdue;
  if (days == 0) return AgendaGroup.today;
  if (days <= 7) return AgendaGroup.week;
  return AgendaGroup.later;
}

String agendaGroupLabel(AgendaGroup group) => switch (group) {
      AgendaGroup.overdue => Fa.agendaOverdue,
      AgendaGroup.today => Fa.agendaToday,
      AgendaGroup.week => Fa.agendaWeek,
      AgendaGroup.later => Fa.agendaLater,
      AgendaGroup.undated => Fa.agendaNoDue,
    };

/// Open tasks only, in the order the server returned (due date first,
/// undated last). "Open" is the negation of [taskCountsComplete].
List<TaskRow> openTasks(List<TaskRow> tasks, {int limit = 6}) {
  return tasks
      .where((task) => !taskCountsComplete(
            category: task.statusCategory,
            approvalRequired: task.approvalRequired,
            approvalState: task.approvalState,
          ))
      .take(limit)
      .toList();
}

/// Tasks grouped for the agenda, groups in a fixed order, empty groups left out.
List<(AgendaGroup, List<TaskRow>)> groupAgenda(List<TaskRow> tasks, DateTime nowUtc) {
  final groups = <AgendaGroup, List<TaskRow>>{};
  for (final task in tasks) {
    groups.putIfAbsent(agendaGroupOf(task, nowUtc), () => []).add(task);
  }
  return [
    for (final group in AgendaGroup.values)
      if (groups[group] != null) (group, groups[group]!),
  ];
}

/// What a home action asks of the person.
enum ActionKind {
  /// Someone else waits for this person's decision.
  decide,

  /// This person's own item needs fixing.
  fix,

  /// Moving, nothing to do yet; shown for awareness.
  waiting,
}

class HomeAction {
  const HomeAction({required this.id, required this.title, required this.count, required this.icon, required this.path, required this.kind});

  final String id;
  final String title;
  final int count;
  final AppIcon icon;
  final String path;
  final ActionKind kind;
}

/// Action items from `dashboard_summary`. Counts of zero are left out, so an
/// empty queue never becomes an empty card. Queue counts are already limited
/// by the server to what this person may decide.
List<HomeAction> homeActions(Map<String, dynamic> summary) {
  final queues = asMap(summary['queues']) ?? const {};
  final personal = asMap(summary['personal']) ?? const {};
  HomeAction? item(String id, String title, Object? raw, AppIcon icon, String path, ActionKind kind) {
    final count = asInt(raw);
    return count > 0 ? HomeAction(id: id, title: title, count: count, icon: icon, path: path, kind: kind) : null;
  }

  final decide = [
    item('attendance', Fa.actAttendance, queues['attendance'], AppIcons.attendance, '/attendance/approvals', ActionKind.decide),
    item('corrections', Fa.actCorrections, queues['corrections'], AppIcons.edit, '/attendance/corrections', ActionKind.decide),
    item('leave', Fa.actLeave, queues['leave'], AppIcons.leave, '/leave/queue', ActionKind.decide),
    item('disputes', Fa.actDisputes, queues['disputes'], AppIcons.absence, '/leave/absence', ActionKind.decide),
    item('task_reviews', Fa.actTaskReviews, queues['task_reviews'], AppIcons.reviewer, '/work', ActionKind.decide),
  ].whereType<HomeAction>().toList()
    ..sort((a, b) => b.count.compareTo(a.count));
  final fix = [
    item('needs_revision', Fa.actNeedsRevision, personal['needs_revision'], AppIcons.revise, '/work/mine', ActionKind.fix),
    item('incomplete', Fa.actIncomplete, personal['incomplete'], AppIcons.warning, '/attendance/mine', ActionKind.fix),
  ].whereType<HomeAction>();
  final waiting = [
    item('awaiting_review', Fa.actAwaitingReview, personal['awaiting_review'], AppIcons.pending, '/work/mine', ActionKind.waiting),
    item('leave_pending', Fa.actLeavePending, personal['leave_pending'], AppIcons.leave, '/leave', ActionKind.waiting),
    item('unread', Fa.actUnread, personal['unread'], AppIcons.notifications, '/notifications', ActionKind.waiting),
  ].whereType<HomeAction>();
  return [...decide, ...fix, ...waiting];
}

/// Share of team tasks that count as complete, or null with no tasks.
/// Active and complete are disjoint in `dashboard_summary`.
double? teamCompletion(Map<String, dynamic> team) {
  final active = asInt(team['active_tasks']);
  final complete = asInt(team['complete_tasks']);
  final total = active + complete;
  return total == 0 ? null : complete / total;
}

/// Whether `dashboard_team` can return data for this person: the same four
/// permissions the function checks. Used only to decide whether a loading or
/// failed team section is shown; the data itself still comes from the server.
bool mayHaveTeamSection(WorkspaceSession session) =>
    session.can('employees.view.team') ||
    session.can('employees.view.all') ||
    session.can('attendance.view.team') ||
    session.can('attendance.view.all');

/// Whether `dashboard_projects` can return data: project permissions, or
/// membership the client cannot know. A failed or loading section is shown
/// only to people with a project permission; members without one see the
/// section once it has loaded.
bool mayHaveProjectsSection(WorkspaceSession session) =>
    session.can('projects.view.all') || session.can('projects.create') || session.can('tasks.create.project');

class QuickAction {
  const QuickAction({required this.id, required this.label, required this.icon, required this.path});

  final String id;
  final String label;
  final AppIcon icon;
  final String path;
}

/// Shortcuts the person's permissions allow. Each opens an existing page.
List<QuickAction> quickActions(WorkspaceSession session) {
  return [
    if (session.can('tasks.create.personal'))
      const QuickAction(id: 'task', label: Fa.quickPersonalTask, icon: AppIcons.addBoxed, path: '/work/personal'),
    if (session.can('leave.request'))
      const QuickAction(id: 'leave', label: Fa.quickLeave, icon: AppIcons.leave, path: '/leave'),
    if (session.can('attendance.correct.self'))
      const QuickAction(id: 'correction', label: Fa.quickCorrection, icon: AppIcons.edit, path: '/attendance/mine'),
    const QuickAction(id: 'reports', label: Fa.reports, icon: AppIcons.reports, path: '/reports'),
    if (canExportReports(session.permissions))
      const QuickAction(id: 'export', label: Fa.exportReport, icon: AppIcons.export, path: '/reports/export'),
  ];
}
