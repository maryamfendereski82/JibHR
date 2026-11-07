import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';
import '../attendance/attendance_review.dart';

class NotificationRow {
  const NotificationRow({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.createdAt,
    this.entityType,
    this.entityId,
    this.readAt,
  });

  final String id;
  final String category;
  final String title;
  final String body;
  final String? entityType;
  final String? entityId;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get unread => readAt == null;

  NotificationRow copyRead(DateTime readAt) => NotificationRow(
        id: id,
        category: category,
        title: title,
        body: body,
        entityType: entityType,
        entityId: entityId,
        readAt: readAt,
        createdAt: createdAt,
      );

  static NotificationRow? fromMap(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final created = asTime(json['created_at']);
    if (id == null || id.isEmpty || created == null) return null;
    return NotificationRow(
      id: id,
      category: json['category']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      entityType: json['entity_type']?.toString(),
      entityId: json['entity_id']?.toString(),
      readAt: asTime(json['read_at']),
      createdAt: created,
    );
  }
}

String categoryLabel(String category) => switch (category) {
      'attendance' => Fa.categoryAttendance,
      'leave' => Fa.categoryLeave,
      'absence' => Fa.categoryAbsence,
      'task' => Fa.categoryTask,
      'project' => Fa.categoryProject,
      'sprint' => Fa.categorySprint,
      'milestone' => Fa.categoryMilestone,
      _ => category,
    };

String relativeNoticeTime(DateTime created, DateTime now) {
  final delta = now.toUtc().difference(created.toUtc());
  if (delta.isNegative || delta.inMinutes < 1) return Fa.justNow;
  if (delta.inMinutes < 60) return persianDigits('${delta.inMinutes} ${Fa.minutesAgo}');
  if (delta.inHours < 24) return persianDigits('${delta.inHours} ${Fa.hoursAgo}');
  if (delta.inDays < 7) return persianDigits('${delta.inDays} ${Fa.daysAgo}');
  return TehranTime.formatDate(created);
}

/// A hidden or missing record has no path. The inbox must not invent one.
String? notificationPath({
  required String? entityType,
  required String? entityId,
  required bool visible,
  String? projectId,
  required bool ownRecord,
}) {
  if (!visible || entityId == null || entityId.isEmpty) return null;
  return switch (entityType) {
    'task' => '/work/t/$entityId',
    'project' => '/work/p/$entityId',
    'sprint' => _planPath(projectId, 'sprint', entityId),
    'milestone' => _planPath(projectId, 'milestone', entityId),
    'attendance_report' => ownRecord ? '/attendance' : '/attendance/approvals',
    'attendance_correction' => ownRecord ? '/attendance/mine' : '/attendance/corrections',
    'leave_request' => ownRecord ? '/leave' : '/leave/queue',
    'absence' || 'absence_dispute' => ownRecord ? '/leave/my-absence' : '/leave/absence',
    _ => null,
  };
}

String? _planPath(String? projectId, String kind, String id) {
  if (projectId == null || projectId.isEmpty) return null;
  return '/work/p/$projectId/$kind/$id';
}

/// [reconnect] drops a stale push and keeps the server page.
List<NotificationRow> applyInbox(
  List<NotificationRow> page,
  NotificationRow? incoming, {
  required bool reconnect,
}) {
  if (reconnect || incoming == null) return page;
  if (page.any((row) => row.id == incoming.id)) return page;
  return [incoming, ...page];
}

List<NotificationRow> appendPage(List<NotificationRow> current, List<NotificationRow> next) {
  final seen = current.map((row) => row.id).toSet();
  return [...current, for (final row in next) if (!seen.contains(row.id)) row];
}
