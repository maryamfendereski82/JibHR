import 'package:flutter/material.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';

class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.intervalId,
    required this.decision,
    required this.startedAt,
    required this.endedAt,
    this.reason,
    this.decidedAt,
    this.deciderName,
    this.startPlatform,
    this.endPlatform,
  });

  final String id;
  final String intervalId;
  final String decision;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? reason;
  final DateTime? decidedAt;
  final String? deciderName;
  final String? startPlatform;
  final String? endPlatform;

  int get seconds => endedAt.difference(startedAt).inSeconds.clamp(0, 1 << 30);
}

class ReviewReport {
  const ReviewReport({
    required this.id,
    required this.profileId,
    required this.teamId,
    required this.employeeName,
    required this.teamName,
    required this.tehranDate,
    required this.sequence,
    required this.kind,
    required this.status,
    required this.items,
  });

  final String id;
  final String profileId;
  final String teamId;
  final String employeeName;
  final String teamName;
  final DateTime tehranDate;
  final int sequence;
  final String kind;
  final String status;
  final List<ReviewItem> items;

  int get intervalCount => items.map((item) => item.intervalId).toSet().length;
}

class CorrectionRequest {
  const CorrectionRequest({
    required this.id,
    required this.employeeName,
    required this.teamName,
    required this.kind,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.intervalId,
    this.currentStart,
    this.currentEnd,
    this.proposedStart,
    this.proposedEnd,
    this.decisionReason,
    this.decidedAt,
    this.deciderName,
  });

  final String id;
  final String employeeName;
  final String teamName;
  final String kind;
  final String reason;
  final String status;
  final DateTime createdAt;
  final String? intervalId;
  final DateTime? currentStart;
  final DateTime? currentEnd;
  final DateTime? proposedStart;
  final DateTime? proposedEnd;
  final String? decisionReason;
  final DateTime? decidedAt;
  final String? deciderName;
}

class TeamOption {
  const TeamOption({required this.id, required this.name});
  final String id;
  final String name;
}

/// Bulk approval may touch only items still waiting. A revision or rejection stays.
List<String> pendingDecisionIds(Iterable<ReviewItem> items) =>
    [for (final item in items) if (item.decision == 'pending') item.id];

int recordedSeconds(Iterable<ReviewItem> items) => items.fold(0, (sum, item) => sum + item.seconds);

int approvedSeconds(Iterable<ReviewItem> items) =>
    items.where((item) => item.decision == 'approved').fold(0, (sum, item) => sum + item.seconds);

/// Mirrors `request_attendance_correction` so the form does not submit a known-invalid row.
String? correctionProblem({
  required String kind,
  required String reason,
  required String? intervalId,
  required DateTime? start,
  required DateTime? end,
  required DateTime? intervalStart,
  required DateTime? intervalEnd,
}) {
  if (reason.trim().isEmpty) return 'reason_required';
  switch (kind) {
    case 'missing_in':
      if (start == null || end == null || !end.isAfter(start)) return 'invalid_range';
    case 'missing_out':
    case 'edit_out':
      if (intervalId == null || end == null || intervalStart == null || !end.isAfter(intervalStart)) {
        return 'invalid_range';
      }
    case 'edit_in':
      if (intervalId == null || start == null || intervalEnd == null || !intervalEnd.isAfter(start)) {
        return 'invalid_range';
      }
    case 'delete_interval':
      if (intervalId == null) return 'invalid_range';
    default:
      return 'invalid_kind';
  }
  return null;
}

String reportKindLabel(String kind) => switch (kind) {
      'supplemental' => Fa.supplementalReport,
      'automatic' => Fa.automaticReport,
      _ => Fa.primaryReport,
    };

String reportStatusLabel(String status) => switch (status) {
      'partially_approved' => Fa.partiallyApproved,
      'approved' => Fa.approved,
      'needs_revision' => Fa.needsRevision,
      'rejected' => Fa.rejected,
      _ => Fa.pending,
    };

String decisionLabel(String decision) => switch (decision) {
      'approved' => Fa.approved,
      'needs_revision' => Fa.needsRevision,
      'rejected' => Fa.rejected,
      _ => Fa.pending,
    };

String correctionKindLabel(String kind) => switch (kind) {
      'missing_in' => Fa.missingIn,
      'missing_out' => Fa.missingOut,
      'edit_in' => Fa.editIn,
      'edit_out' => Fa.editOut,
      'delete_interval' => Fa.deleteInterval,
      _ => kind,
    };

String reviewErrorText(Object error) {
  final raw = error.toString();
  if (raw.contains('already_decided')) return Fa.alreadyDecided;
  if (raw.contains('reason_required')) return Fa.reasonRequired;
  if (raw.contains('offline')) return 'این کار آفلاین انجام نمی‌شود.';
  if (raw.contains('forbidden')) return Fa.forbidden;
  if (raw.contains('invalid_range') || raw.contains('invalid_kind')) return Fa.invalidRange;
  return Fa.network;
}

String platformLabel(String? start, String? end) {
  if (start == null && end == null) return '';
  if (start == end || end == null) return '${Fa.platformIn} $start';
  if (start == null) return '${Fa.platformOut} $end';
  return '${Fa.platformIn} $start · ${Fa.platformOut} $end';
}

String personName(Map<String, dynamic>? row) {
  if (row == null) return '';
  final name = '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}'.trim();
  return name;
}

Map<String, dynamic>? asMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return null;
}

List<Map<String, dynamic>> asMaps(dynamic value) {
  if (value is! List) return const [];
  return [for (final row in value) if (row is Map) Map<String, dynamic>.from(row)];
}

DateTime? asTime(dynamic value) => value == null ? null : DateTime.tryParse(value.toString());

String formatStamp(DateTime? value) {
  if (value == null) return '—';
  return '${TehranTime.formatDate(value)} ${TehranTime.formatTime(value)}';
}

/// Returns the reason, an empty string when no reason is required, or null if cancelled.
Future<String?> askDecision(
  BuildContext context, {
  required String title,
  required bool reasonRequired,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: reasonRequired
            ? TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: Fa.reason),
                maxLines: 3,
              )
            : null,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.cancel)),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reasonRequired && reason.isEmpty) return;
              Navigator.pop(context, reason);
            },
            child: const Text(Fa.confirm),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}
