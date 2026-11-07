import 'package:supabase_flutter/supabase_flutter.dart';

import 'attendance_review.dart';

const _reportColumns = '''
id, profile_id, team_id, tehran_date, sequence, kind, status,
profiles!attendance_daily_reports_profile_id_fkey(first_name, last_name),
teams!attendance_daily_reports_team_id_fkey(name),
attendance_report_items(
  id, decision, reason, decided_at,
  decider:profiles!attendance_report_items_decided_by_fkey(first_name, last_name),
  attendance_daily_segments!attendance_report_items_segment_id_fkey(
    started_at, ended_at, interval_id,
    attendance_intervals!attendance_daily_segments_interval_id_fkey(start_platform, end_platform)
  )
)
''';

const _correctionColumns = '''
id, interval_id, kind, reason, status, created_at, decided_at, decision_reason,
proposed_started_at, proposed_ended_at,
profiles!attendance_corrections_profile_id_fkey(first_name, last_name),
decider:profiles!attendance_corrections_decided_by_fkey(first_name, last_name),
teams!attendance_corrections_team_id_fkey(name),
attendance_intervals!attendance_corrections_interval_id_fkey(
  effective_started_at, effective_ended_at, original_started_at, original_ended_at
)
''';

class AttendanceReviewRepository {
  AttendanceReviewRepository(this._client);

  final SupabaseClient _client;

  Future<List<TeamOption>> teams() async {
    final rows = await _client.from('teams').select('id, name').eq('status', 'active').order('name');
    return [
      for (final row in asMaps(rows))
        TeamOption(id: row['id'].toString(), name: row['name']?.toString() ?? ''),
    ];
  }

  /// shortcut: 200 open reports, add paging when one workspace exceeds that
  Future<List<ReviewReport>> openReports({String? teamId, String? tehranDate}) async {
    var query = _client.from('attendance_daily_reports').select(_reportColumns).inFilter('status', [
      'pending',
      'partially_approved',
      'needs_revision',
    ]);
    if (teamId != null) query = query.eq('team_id', teamId);
    if (tehranDate != null) query = query.eq('tehran_date', tehranDate);
    final rows = await query.order('tehran_date', ascending: false).limit(200);
    return [for (final row in asMaps(rows)) _report(row)]..sort((a, b) => b.tehranDate.compareTo(a.tehranDate));
  }

  Future<void> decideItem(String itemId, String decision, String? reason) {
    return _client.rpc('decide_attendance_item', params: {
      'p_item': itemId,
      'p_decision': decision,
      'p_reason': reason,
    });
  }

  Future<List<CorrectionRequest>> corrections({bool pendingOnly = false}) async {
    var query = _client.from('attendance_corrections').select(_correctionColumns);
    if (pendingOnly) query = query.eq('status', 'pending');
    final rows = await query.order('created_at', ascending: false).limit(200);
    return [for (final row in asMaps(rows)) _correction(row)];
  }

  Future<List<ReviewItem>> myIntervals() async {
    final rows = await _client
        .from('attendance_intervals')
        .select('id, status, effective_started_at, effective_ended_at, start_platform, end_platform')
        .neq('status', 'void')
        .order('effective_started_at', ascending: false)
        .limit(40);
    return [
      for (final row in asMaps(rows))
        if (asTime(row['effective_started_at']) != null)
          ReviewItem(
            id: row['id'].toString(),
            intervalId: row['id'].toString(),
            decision: row['status']?.toString() ?? '',
            startedAt: asTime(row['effective_started_at'])!,
            endedAt: asTime(row['effective_ended_at']) ?? asTime(row['effective_started_at'])!,
            startPlatform: row['start_platform']?.toString(),
            endPlatform: row['end_platform']?.toString(),
          ),
    ];
  }

  Future<void> requestCorrection({
    required String kind,
    required String reason,
    String? intervalId,
    DateTime? start,
    DateTime? end,
  }) {
    return _client.rpc('request_attendance_correction', params: {
      'p_kind': kind,
      'p_interval': intervalId,
      'p_proposed_start': start?.toUtc().toIso8601String(),
      'p_proposed_end': end?.toUtc().toIso8601String(),
      'p_reason': reason.trim(),
    });
  }

  Future<void> decideCorrection(String id, {required bool approve, String? reason}) {
    return _client.rpc('decide_attendance_correction', params: {
      'p_correction': id,
      'p_approve': approve,
      'p_reason': reason,
    });
  }

  ReviewReport _report(Map<String, dynamic> row) {
    final items = <ReviewItem>[];
    for (final item in asMaps(row['attendance_report_items'])) {
      final segment = asMap(item['attendance_daily_segments']);
      final started = asTime(segment?['started_at']);
      final ended = asTime(segment?['ended_at']);
      if (segment == null || started == null || ended == null) continue;
      final interval = asMap(segment['attendance_intervals']);
      final decider = asMap(item['decider']);
      items.add(ReviewItem(
        id: item['id'].toString(),
        intervalId: segment['interval_id']?.toString() ?? '',
        decision: item['decision']?.toString() ?? 'pending',
        startedAt: started,
        endedAt: ended,
        reason: item['reason']?.toString(),
        decidedAt: asTime(item['decided_at']),
        deciderName: personName(decider).isEmpty ? null : personName(decider),
        startPlatform: interval?['start_platform']?.toString(),
        endPlatform: interval?['end_platform']?.toString(),
      ));
    }
    items.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final day = DateTime.parse(row['tehran_date'].toString());
    return ReviewReport(
      id: row['id'].toString(),
      profileId: row['profile_id'].toString(),
      teamId: row['team_id'].toString(),
      employeeName: personName(asMap(row['profiles'])),
      teamName: asMap(row['teams'])?['name']?.toString() ?? '',
      tehranDate: DateTime.utc(day.year, day.month, day.day),
      sequence: (row['sequence'] as num?)?.toInt() ?? 1,
      kind: row['kind']?.toString() ?? 'primary',
      status: row['status']?.toString() ?? 'pending',
      items: items,
    );
  }

  CorrectionRequest _correction(Map<String, dynamic> row) {
    final interval = asMap(row['attendance_intervals']);
    final decider = asMap(row['decider']);
    return CorrectionRequest(
      id: row['id'].toString(),
      employeeName: personName(asMap(row['profiles'])),
      teamName: asMap(row['teams'])?['name']?.toString() ?? '',
      kind: row['kind']?.toString() ?? '',
      reason: row['reason']?.toString() ?? '',
      status: row['status']?.toString() ?? 'pending',
      createdAt: asTime(row['created_at']) ?? DateTime.now().toUtc(),
      intervalId: row['interval_id']?.toString(),
      currentStart: asTime(interval?['effective_started_at']) ?? asTime(interval?['original_started_at']),
      currentEnd: asTime(interval?['effective_ended_at']) ?? asTime(interval?['original_ended_at']),
      proposedStart: asTime(row['proposed_started_at']),
      proposedEnd: asTime(row['proposed_ended_at']),
      decisionReason: row['decision_reason']?.toString(),
      decidedAt: asTime(row['decided_at']),
      deciderName: personName(decider).isEmpty ? null : personName(decider),
    );
  }
}
