import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import '../attendance/attendance_review.dart';
import 'leave_rules.dart';

const _leaveColumns = '''
id, profile_id, team_id, kind, start_date, end_date, hours_date, start_time, end_time,
note, status, decided_at, decision_reason, created_at,
profiles!leave_requests_profile_id_fkey(first_name, last_name),
decider:profiles!leave_requests_decided_by_fkey(first_name, last_name),
teams!leave_requests_team_id_fkey(name)
''';

const _absenceColumns = '''
id, profile_id, team_id, start_date, end_date, reason, created_at,
profiles!absence_records_profile_id_fkey(first_name, last_name),
recorder:profiles!absence_records_recorded_by_fkey(first_name, last_name),
teams!absence_records_team_id_fkey(name),
absence_disputes(
  id, explanation, status, decision_reason, created_at, decided_at,
  decider:profiles!absence_disputes_decided_by_fkey(first_name, last_name)
)
''';

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.employeeName,
    required this.teamId,
    required this.teamName,
    required this.kind,
    required this.status,
    required this.note,
    required this.createdAt,
    this.startDate,
    this.endDate,
    this.hoursDate,
    this.startTime,
    this.endTime,
    this.decisionReason,
    this.decidedAt,
    this.deciderName,
  });

  final String id;
  final String employeeName;
  final String teamId;
  final String teamName;
  final String kind;
  final String status;
  final String note;
  final DateTime createdAt;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? hoursDate;
  final String? startTime;
  final String? endTime;
  final String? decisionReason;
  final DateTime? decidedAt;
  final String? deciderName;

  CalendarLeave get calendar => CalendarLeave(
        id: id,
        kind: kind,
        status: status,
        label: employeeName,
        start: startDate,
        end: endDate,
        hoursDate: hoursDate,
      );

  String get period {
    if (kind == 'hourly') {
      return '${_day(hoursDate)} ${_clock(startTime)}–${_clock(endTime)}';
    }
    return '${_day(startDate)} تا ${_day(endDate)}';
  }

  String get durationLabel {
    if (kind == 'hourly') {
      final start = _minutes(startTime);
      final end = _minutes(endTime);
      if (start == null || end == null || end <= start) return '';
      final minutes = end - start;
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return '${hours.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
    }
    if (startDate == null || endDate == null) return '';
    return inclusiveDays(startDate!, endDate!).toString();
  }
}

class AbsenceDispute {
  const AbsenceDispute({
    required this.id,
    required this.explanation,
    required this.status,
    required this.createdAt,
    this.decisionReason,
    this.decidedAt,
    this.deciderName,
  });

  final String id;
  final String explanation;
  final String status;
  final DateTime createdAt;
  final String? decisionReason;
  final DateTime? decidedAt;
  final String? deciderName;
}

class AbsenceRecord {
  const AbsenceRecord({
    required this.id,
    required this.employeeName,
    required this.teamName,
    required this.startDate,
    required this.endDate,
    required this.reason,
    required this.recordedBy,
    required this.createdAt,
    required this.disputes,
  });

  final String id;
  final String employeeName;
  final String teamName;
  final DateTime startDate;
  final DateTime endDate;
  final String reason;
  final String recordedBy;
  final DateTime createdAt;
  final List<AbsenceDispute> disputes;
}

class StaffOption {
  const StaffOption({required this.id, required this.name});
  final String id;
  final String name;
}

class LeaveRepository {
  LeaveRepository(this._client);

  final SupabaseClient _client;

  /// shortcut: 200 rows, add paging when one workspace exceeds that
  Future<List<LeaveRequest>> leaves({String? teamId, String? status, String? profileId}) async {
    var query = _client.from('leave_requests').select(_leaveColumns);
    if (teamId != null) query = query.eq('team_id', teamId);
    if (status != null) query = query.eq('status', status);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final rows = await query.order('created_at', ascending: false).limit(200);
    return [for (final row in asMaps(rows)) _leave(row)];
  }

  Future<void> requestLeave({
    required String kind,
    required String note,
    String? startDate,
    String? endDate,
    String? hoursDate,
    String? startTime,
    String? endTime,
  }) {
    return _client.rpc('request_leave', params: {
      'p_kind': kind,
      'p_start_date': startDate,
      'p_end_date': endDate,
      'p_hours_date': hoursDate,
      'p_start_time': startTime,
      'p_end_time': endTime,
      'p_note': note.trim(),
    });
  }

  Future<void> decideLeave(String id, {required bool approve, String? reason}) {
    return _client.rpc('decide_leave', params: {
      'p_request': id,
      'p_approve': approve,
      'p_reason': reason,
    });
  }

  Future<List<AbsenceRecord>> absences({String? profileId}) async {
    var query = _client.from('absence_records').select(_absenceColumns);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final rows = await query.order('created_at', ascending: false).limit(200);
    return [for (final row in asMaps(rows)) _absence(row)];
  }

  Future<List<StaffOption>> staff() async {
    final rows = await _client.from('profiles').select('id, first_name, last_name').eq('status', 'active').order('first_name').limit(200);
    return [
      for (final row in asMaps(rows))
        StaffOption(id: row['id'].toString(), name: personName(row)),
    ];
  }

  Future<void> recordAbsence({
    required String profileId,
    required String startDate,
    required String endDate,
    required String reason,
  }) {
    return _client.rpc('record_absence', params: {
      'p_profile': profileId,
      'p_start': startDate,
      'p_end': endDate,
      'p_reason': reason.trim(),
    });
  }

  Future<void> dispute(String absenceId, String explanation) {
    return _client.rpc('dispute_absence', params: {
      'p_absence': absenceId,
      'p_explanation': explanation.trim(),
    });
  }

  Future<void> decideDispute(String id, {required bool accept, String? reason}) {
    return _client.rpc('decide_absence_dispute', params: {
      'p_dispute': id,
      'p_accept': accept,
      'p_reason': reason,
    });
  }

  LeaveRequest _leave(Map<String, dynamic> row) {
    final decider = asMap(row['decider']);
    return LeaveRequest(
      id: row['id'].toString(),
      employeeName: personName(asMap(row['profiles'])),
      teamId: row['team_id']?.toString() ?? '',
      teamName: asMap(row['teams'])?['name']?.toString() ?? '',
      kind: row['kind']?.toString() ?? 'daily',
      status: row['status']?.toString() ?? 'pending',
      note: row['note']?.toString() ?? '',
      createdAt: asTime(row['created_at']) ?? DateTime.now().toUtc(),
      startDate: _date(row['start_date']),
      endDate: _date(row['end_date']),
      hoursDate: _date(row['hours_date']),
      startTime: row['start_time']?.toString(),
      endTime: row['end_time']?.toString(),
      decisionReason: row['decision_reason']?.toString(),
      decidedAt: asTime(row['decided_at']),
      deciderName: personName(decider).isEmpty ? null : personName(decider),
    );
  }

  List<AbsenceDispute> _disputes(dynamic raw) {
    final disputes = [
      for (final item in asMaps(raw))
        AbsenceDispute(
          id: item['id'].toString(),
          explanation: item['explanation']?.toString() ?? '',
          status: item['status']?.toString() ?? 'pending',
          createdAt: asTime(item['created_at']) ?? DateTime.now().toUtc(),
          decisionReason: item['decision_reason']?.toString(),
          decidedAt: asTime(item['decided_at']),
          deciderName: personName(asMap(item['decider'])).isEmpty ? null : personName(asMap(item['decider'])),
        ),
    ];
    disputes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return disputes;
  }

  AbsenceRecord _absence(Map<String, dynamic> row) {
    return AbsenceRecord(
      id: row['id'].toString(),
      employeeName: personName(asMap(row['profiles'])),
      teamName: asMap(row['teams'])?['name']?.toString() ?? '',
      startDate: _date(row['start_date']) ?? DateTime.now().toUtc(),
      endDate: _date(row['end_date']) ?? DateTime.now().toUtc(),
      reason: row['reason']?.toString() ?? '',
      recordedBy: personName(asMap(row['recorder'])),
      createdAt: asTime(row['created_at']) ?? DateTime.now().toUtc(),
      disputes: _disputes(row['absence_disputes']),
    );
  }
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  final parsed = DateTime.tryParse(value.toString());
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

int? _minutes(String? value) {
  if (value == null || value.length < 5) return null;
  final parts = value.split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return hour * 60 + minute;
}

String _clock(String? value) {
  if (value == null || value.length < 5) return '—';
  return persianDigits(value.substring(0, 5));
}

String _day(DateTime? value) {
  if (value == null) return '—';
  return TehranTime.formatDate(DateTime.utc(value.year, value.month, value.day, 12));
}
