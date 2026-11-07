import 'package:flutter/foundation.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar/tehran_time.dart';
import 'attendance_calendar.dart';
import 'attendance_review.dart';

class AttendanceBoard {
  const AttendanceBoard({
    required this.isOpen,
    required this.today,
    required this.week,
    required this.month,
    required this.provisional,
  });

  final bool isOpen;
  final DurationTotals today;
  final DurationTotals week;
  final DurationTotals month;
  final List<({DateTime start, DateTime end})> provisional;
}

class AttendanceRepository {
  AttendanceRepository(this._client);

  final SupabaseClient _client;

  Future<AttendanceBoard> load(String profileId) async {
    final now = DateTime.now().toUtc();
    final today = TehranTime.dateOnly(now);
    final month = TehranTime.jalaliMonth(now);
    final preview = await _client.rpc('preview_open_attendance');
    final spans = <({DateTime start, DateTime end})>[];
    if (preview is List) {
      for (final row in preview) {
        if (row is! Map) continue;
        final start = DateTime.tryParse(row['started_at']?.toString() ?? '');
        final end = DateTime.tryParse(row['ended_at']?.toString() ?? '');
        if (start != null && end != null) spans.add((start: start, end: end));
      }
    }
    return AttendanceBoard(
      isOpen: spans.isNotEmpty,
      today: await _totals(profileId, today, today),
      week: await _totals(profileId, TehranTime.weekStart(now), TehranTime.weekEnd(now)),
      month: await _totals(profileId, month.$1, month.$2),
      provisional: spans,
    );
  }

  Future<void> punch({required bool isOpen}) {
    return _client.rpc(isOpen ? 'clock_out' : 'clock_in', params: {'p_platform': _platform()});
  }

  Future<DurationTotals> _totals(String profileId, DateTime from, DateTime to) {
    return _totalsIso(profileId, TehranTime.formatDateIso(from), TehranTime.formatDateIso(to));
  }

  Future<DurationTotals> _totalsIso(String profileId, String from, String to) async {
    final raw = await _client.rpc('attendance_totals', params: {
      'p_profile': profileId,
      'p_from': from,
      'p_to': to,
    });
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return DurationTotals.fromRow(Map<String, dynamic>.from(raw.first as Map));
    }
    return AttendanceCalendarModel.emptyTotals;
  }

  Future<DurationTotals> dayTotals(String profileId, String iso) => _totalsIso(profileId, iso, iso);

  Future<Map<String, int>> _approvedByDay(String profileId, String from, String to) async {
    final raw = await _client.rpc('attendance_buckets', params: {
      'p_profile': profileId,
      'p_from': from,
      'p_to': to,
      'p_grain': 'day',
    });
    return {
      for (final row in asMaps(raw))
        row['period_start']?.toString() ?? '': (row['approved_seconds'] as num?)?.toInt() ?? 0,
    };
  }

  Future<AttendanceCalendarModel> calendar(AttendanceCalendarQuery query) async {
    final month = Jalali(query.year, query.month, 1);
    final from = TehranTime.jalaliDayIso(month.year, month.month, 1);
    final to = TehranTime.jalaliDayIso(month.year, month.month, month.monthLength);
    final (slices, approved, totals) = await (
      _slices(from: from, to: to, profileIds: [query.profileId], includePreview: query.includePreview),
      _approvedByDay(query.profileId, from, to),
      _totalsIso(query.profileId, from, to),
    ).wait;
    return AttendanceCalendarModel(
      days: buildMonth(month, slices, approved: approved),
      totals: totals,
    );
  }

  /// People come from memberships, but attendance is narrower than employee
  /// visibility. Someone the backend refuses is left out instead of failing the screen.
  Future<GroupAttendance> group(GroupAttendanceQuery query) async {
    final days = query.range.days;
    final from = isoOf(query.range.from);
    final to = isoOf(query.range.to);
    final members = await _members(query.teamId);
    final truncated = members.length > _peopleLimit;
    final shown = members.take(_peopleLimit).toList();
    final rows = <({String id, DurationTotals totals, Map<String, int> approved})>[];
    for (var start = 0; start < shown.length; start += _rpcBatch) {
      final batch = shown.skip(start).take(_rpcBatch);
      final results = await Future.wait(batch.map((person) async {
        try {
          final totals = await _totalsIso(person.id, from, to);
          final approved = await _approvedByDay(person.id, from, to);
          return (id: person.id, totals: totals, approved: approved);
        } on PostgrestException catch (error) {
          if (error.message.contains('forbidden')) return null;
          rethrow;
        }
      }));
      rows.addAll(results.nonNulls);
    }
    final slices = await _slices(from: from, to: to, profileIds: [for (final row in rows) row.id]);
    final byId = {for (final row in rows) row.id: row};
    return GroupAttendance(
      truncated: truncated,
      people: [
        for (final person in shown)
          if (byId[person.id] case final row?)
            PersonAttendance(
              id: person.id,
              name: person.name,
              teamId: person.teamId,
              totals: row.totals,
              days: buildDays(
                days,
                slices.where((slice) => slice.profileId == person.id),
                approved: row.approved,
              ),
            ),
      ],
    );
  }

  static const _peopleLimit = 80;
  static const _rpcBatch = 8;

  Future<List<({String id, String name, String teamId})>> _members(String? teamId) async {
    var request = _client
        .from('team_memberships')
        .select('profile_id, team_id, profiles!team_memberships_profile_id_fkey(first_name, last_name)')
        .eq('is_primary', true)
        .isFilter('left_at', null);
    if (teamId != null) request = request.eq('team_id', teamId);
    final rows = await request.limit(_peopleLimit + 1);
    final people = <({String id, String name, String teamId})>[];
    for (final row in asMaps(rows)) {
      final id = row['profile_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      people.add((id: id, name: personName(asMap(row['profiles'])), teamId: row['team_id']?.toString() ?? ''));
    }
    people.sort((a, b) => a.name.compareTo(b.name));
    return people;
  }

  Future<List<CalendarSlice>> _slices({
    required String from,
    required String to,
    required List<String> profileIds,
    bool includePreview = false,
  }) async {
    if (profileIds.isEmpty || profileIds.any((id) => id.isEmpty)) return const [];
    // PostgREST caps a response at max_rows. A team's month can pass it.
    const page = 1000;
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0;; offset += page) {
      final batch = asMaps(await _client
          .from('attendance_daily_segments')
          .select('''
id, interval_id, profile_id, tehran_date, started_at, ended_at, approval_mode, superseded_at,
attendance_intervals!attendance_daily_segments_interval_id_fkey(status, start_platform, end_platform),
attendance_report_items(decision)
''')
          .inFilter('profile_id', profileIds)
          .gte('tehran_date', from)
          .lte('tehran_date', to)
          .isFilter('superseded_at', null)
          .order('id')
          .range(offset, offset + page - 1));
      rows.addAll(batch);
      if (batch.length < page) break;
    }
    final slices = <CalendarSlice>[];
    final seen = <String>{};
    for (final row in rows) {
      final interval = asMap(row['attendance_intervals']);
      final status = interval?['status']?.toString() ?? 'closed';
      if (status == 'void') continue;
      final id = row['interval_id']?.toString() ?? '';
      seen.add(id);
      slices.add(CalendarSlice(
        intervalId: id,
        profileId: row['profile_id']?.toString() ?? '',
        tehranDate: row['tehran_date']?.toString() ?? '',
        startedAt: asTime(row['started_at']),
        endedAt: asTime(row['ended_at']),
        intervalStatus: status,
        approvalMode: row['approval_mode']?.toString() ?? 'report',
        decision: asMap(row['attendance_report_items'])?['decision']?.toString(),
        startPlatform: interval?['start_platform']?.toString(),
        endPlatform: interval?['end_platform']?.toString(),
      ));
    }
    final openRows = await _client
        .from('attendance_intervals')
        .select('id, profile_id, status, effective_started_at, start_platform, end_platform')
        .inFilter('profile_id', profileIds)
        .inFilter('status', ['open', 'incomplete']);
    for (final row in asMaps(openRows)) {
      final id = row['id']?.toString() ?? '';
      if (seen.contains(id)) continue;
      if (includePreview && row['status']?.toString() == 'open') continue;
      final started = asTime(row['effective_started_at']);
      if (started == null) continue;
      final date = TehranTime.formatDateIso(TehranTime.dateOnly(started));
      if (date.compareTo(from) < 0 || date.compareTo(to) > 0) continue;
      slices.add(CalendarSlice(
        intervalId: id,
        profileId: row['profile_id']?.toString() ?? '',
        tehranDate: date,
        startedAt: started,
        intervalStatus: row['status']?.toString() ?? 'open',
        approvalMode: 'report',
        startPlatform: row['start_platform']?.toString(),
        endPlatform: row['end_platform']?.toString(),
      ));
    }
    if (includePreview) {
      final preview = await _client.rpc('preview_open_attendance');
      if (preview is List) {
        for (final row in preview) {
          if (row is! Map) continue;
          final date = row['tehran_date']?.toString() ?? '';
          if (date.compareTo(from) < 0 || date.compareTo(to) > 0) continue;
          slices.add(CalendarSlice(
            intervalId: row['interval_id']?.toString() ?? '',
            profileId: profileIds.length == 1 ? profileIds.first : '',
            tehranDate: date,
            startedAt: asTime(row['started_at']),
            endedAt: asTime(row['ended_at']),
            intervalStatus: 'open',
            provisional: true,
          ));
        }
      }
    }
    return slices;
  }

  String _platform() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'linux',
    };
  }
}
