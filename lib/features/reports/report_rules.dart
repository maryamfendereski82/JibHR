import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';

/// One page of an export. The server refuses a larger page.
const exportPageSize = 200;

/// Rows painted on one PDF page, under the repeated header.
const pdfTableRows = 22;

int asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool showTeam(Object? team) => team is Map;

bool showProjects(Object? projects) => projects is Map;

bool showQueues(Object? queues) {
  if (queues is! Map) return false;
  for (final value in queues.values) {
    if (value is num && value > 0) return true;
  }
  return false;
}

bool canExportReports(Set<String> permissions) {
  return permissions.contains('reports.view.self') ||
      permissions.contains('reports.export.team') ||
      permissions.contains('reports.export.project') ||
      permissions.contains('reports.export.all');
}

bool canOpenAttendance(Set<String> permissions) {
  return permissions.contains('attendance.view.self') ||
      permissions.contains('attendance.view.team') ||
      permissions.contains('attendance.view.all');
}

/// Excel treats a leading = + - @ as a formula. A quote keeps the cell as text.
String plainCell(String value) {
  if (value.isEmpty) return value;
  final first = value.codeUnitAt(0);
  if (first == 0x3d || first == 0x2b || first == 0x2d || first == 0x40 || first == 0x09 || first == 0x0d) {
    return "'$value";
  }
  return value;
}

List<Map<String, dynamic>> sortPeople(List<Map<String, dynamic>> people, String key, bool ascending) {
  final copy = [...people];
  copy.sort((a, b) {
    final left = a[key];
    final right = b[key];
    final order = left is num && right is num ? left.compareTo(right) : '${left ?? ''}'.compareTo('${right ?? ''}');
    return ascending ? order : -order;
  });
  return copy;
}

List<List<Map<String, dynamic>>> pageSlices(List<Map<String, dynamic>> rows, {int pageSize = pdfTableRows}) {
  if (rows.isEmpty) return [const []];
  final pages = <List<Map<String, dynamic>>>[];
  for (var index = 0; index < rows.length; index += pageSize) {
    final end = index + pageSize > rows.length ? rows.length : index + pageSize;
    pages.add(rows.sublist(index, end));
  }
  return pages;
}

String persianDay(String iso) {
  final parts = iso.split('-');
  if (parts.length < 3) return iso;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return iso;
  return TehranTime.formatDate(DateTime.utc(year, month, day, 12));
}

class ReportPreset {
  const ReportPreset({
    required this.id,
    required this.label,
    required this.kind,
    this.grain = 'day',
    this.person = false,
    this.team = false,
    this.project = false,
    this.status = false,
    this.priority = false,
  });

  final String id;
  final String label;
  final String kind;
  final String grain;
  final bool person;
  final bool team;
  final bool project;
  final bool status;
  final bool priority;
}

const reportPresets = <ReportPreset>[
  ReportPreset(id: 'employee_attendance', label: 'حضور یک کارمند', kind: 'attendance_days', person: true),
  ReportPreset(id: 'team_attendance', label: 'حضور یک تیم', kind: 'attendance_days', team: true),
  ReportPreset(id: 'daily_attendance', label: 'حضور روزانه', kind: 'attendance_days'),
  ReportPreset(id: 'weekly_attendance', label: 'حضور هفتگی', kind: 'attendance_days', grain: 'week'),
  ReportPreset(id: 'monthly_attendance', label: 'حضور ماهانه', kind: 'attendance_days', grain: 'jalali_month'),
  ReportPreset(id: 'intervals', label: 'جزئیات بازه حضور', kind: 'attendance_intervals', person: true, team: true),
  ReportPreset(id: 'approvals', label: 'سابقه تأیید حضور', kind: 'attendance_approvals', person: true, team: true, status: true),
  ReportPreset(id: 'leave', label: 'مرخصی', kind: 'leave', person: true, team: true, status: true),
  ReportPreset(id: 'absence', label: 'غیبت ثبت‌شده', kind: 'absence', person: true, team: true),
  ReportPreset(id: 'employee_tasks', label: 'تسک یک کارمند', kind: 'tasks', person: true, status: true, priority: true),
  ReportPreset(id: 'project_tasks', label: 'تسک یک پروژه', kind: 'tasks', project: true, status: true, priority: true),
  ReportPreset(id: 'projects', label: 'خلاصه پروژه', kind: 'projects', project: true),
  ReportPreset(id: 'sprints', label: 'خلاصه اسپرینت', kind: 'sprints', project: true),
  ReportPreset(id: 'milestones', label: 'خلاصه مایلستون', kind: 'milestones', project: true),
];

String sheetNameFor(String kind) {
  return switch (kind) {
    'attendance_days' => 'حضور روزانه',
    'attendance_intervals' => 'بازه حضور',
    'attendance_approvals' => 'تأیید حضور',
    'leave' => 'مرخصی',
    'absence' => 'غیبت',
    'tasks' => 'تسک',
    'projects' => 'پروژه',
    'sprints' => 'اسپرینت',
    'milestones' => 'مایلستون',
    _ => 'گزارش',
  };
}

List<String> exportHeaders(String kind) {
  return switch (kind) {
    'attendance_days' => [
      Fa.employee,
      Fa.date,
      'تاریخ نمایشی',
      'تا',
      Fa.registeredDuration,
      Fa.approvedHours,
      Fa.pendingHours,
      Fa.rejectedDuration,
      Fa.intervalCount,
      Fa.reportStatus,
    ],
    'attendance_intervals' => [Fa.employee, Fa.date, 'تاریخ نمایشی', 'شروع', 'پایان', Fa.registeredDuration, 'تصمیم', 'حالت'],
    'attendance_approvals' => [Fa.employee, Fa.date, 'تاریخ نمایشی', Fa.reportStatus, 'تصمیم', 'زمان تصمیم', Fa.reason],
    'leave' => [Fa.employee, 'نوع', Fa.date, 'تاریخ نمایشی', 'تا', 'ساعت', Fa.planStatus, Fa.reason],
    'absence' => [Fa.employee, Fa.date, 'تاریخ نمایشی', 'تا', Fa.reason, Fa.recordedBy, Fa.employeeResponse, Fa.disputeStatus],
    'tasks' => [Fa.title, Fa.categoryProject, Fa.planStatus, 'دسته', Fa.priority, 'مسئول', 'موعد', 'تأیید', 'تکمیل'],
    'projects' => ['نام', Fa.planStatus, 'دیده شدن', 'تسک', Fa.completeTasks],
    'sprints' => ['نام', Fa.planStatus, Fa.fromDate, Fa.toDate, 'کل', Fa.completeTasks, Fa.remaining, 'درصد'],
    'milestones' => ['عنوان', Fa.planStatus, 'موعد', 'کل', Fa.completeTasks, Fa.remaining, 'درصد'],
    _ => const ['مقدار'],
  };
}

List<Object?> exportCells(String kind, Map<String, dynamic> row) {
  String text(Object? value) => value?.toString() ?? '';
  String day(Object? value) => persianDay(text(value));
  return switch (kind) {
    'attendance_days' => [
      text(row['name']),
      text(row['period_start']),
      day(row['period_start']),
      text(row['period_end']),
      asInt(row['recorded_seconds']),
      asInt(row['approved_seconds']),
      asInt(row['pending_seconds']),
      asInt(row['rejected_seconds']),
      asInt(row['interval_count']),
      text(row['report_status']),
    ],
    'attendance_intervals' => [
      text(row['name']),
      text(row['period_start']),
      day(row['period_start']),
      text(row['started_at']),
      text(row['ended_at']),
      asInt(row['recorded_seconds']),
      text(row['decision']),
      text(row['approval_mode']),
    ],
    'attendance_approvals' => [
      text(row['name']),
      text(row['period_start']),
      day(row['period_start']),
      text(row['report_status']),
      text(row['decision']),
      text(row['decided_at']),
      text(row['reason']),
    ],
    'leave' => [
      text(row['name']),
      text(row['kind']),
      text(row['start_date'] ?? row['hours_date']),
      day(text(row['start_date'] ?? row['hours_date'])),
      text(row['end_date']),
      '${text(row['start_time'])} ${text(row['end_time'])}'.trim(),
      text(row['status']),
      text(row['note']),
    ],
    'absence' => [
      text(row['name']),
      text(row['start_date']),
      day(row['start_date']),
      text(row['end_date']),
      text(row['reason']),
      text(row['recorded_by']),
      text(row['explanation']),
      text(row['dispute_status']),
    ],
    'tasks' => [
      text(row['title']),
      text(row['project_name']),
      text(row['status_name']),
      text(row['category']),
      text(row['priority']),
      text(row['assignee']),
      text(row['due_at']),
      text(row['approval_state']),
      row['complete'] == true ? 'بله' : 'خیر',
    ],
    'projects' => [
      text(row['name']),
      text(row['status']),
      text(row['visibility']),
      asInt(row['tasks']),
      asInt(row['complete']),
    ],
    'sprints' => [
      text(row['name']),
      text(row['status']),
      text(row['start_date']),
      text(row['end_date']),
      asInt(row['total']),
      asInt(row['complete']),
      asInt(row['remaining']),
      asInt(row['percent']),
    ],
    'milestones' => [
      text(row['title']),
      text(row['status']),
      text(row['target_date']),
      asInt(row['total']),
      asInt(row['complete']),
      asInt(row['remaining']),
      asInt(row['percent']),
    ],
    _ => [text(row.values.firstOrNull)],
  };
}
