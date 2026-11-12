import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';

class DurationTotals {
  const DurationTotals({
    required this.recorded,
    required this.pending,
    required this.approved,
    required this.revision,
    required this.rejected,
  });

  final int recorded;
  final int pending;
  final int approved;
  final int revision;
  final int rejected;

  factory DurationTotals.fromRow(Map<String, dynamic> row) {
    int read(String key) => (row[key] as num?)?.toInt() ?? 0;
    return DurationTotals(
      recorded: read('recorded_seconds'),
      pending: read('pending_seconds'),
      approved: read('approved_seconds'),
      revision: read('revision_seconds'),
      rejected: read('rejected_seconds'),
    );
  }
}

enum DayTone { empty, open, incomplete, pending, approved, partial, revision, rejected }

/// One interval piece on a Tehran date. A cross-midnight interval stays two slices.
/// Durations are not computed here. They come from attendance_totals and attendance_buckets.
class CalendarSlice {
  const CalendarSlice({
    required this.intervalId,
    required this.tehranDate,
    required this.intervalStatus,
    this.profileId = '',
    this.startedAt,
    this.endedAt,
    this.approvalMode = 'report',
    this.decision,
    this.superseded = false,
    this.provisional = false,
    this.startPlatform,
    this.endPlatform,
  });

  final String intervalId;
  final String profileId;
  final String tehranDate;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String intervalStatus;
  final String approvalMode;
  final String? decision;
  final bool superseded;
  final bool provisional;
  final String? startPlatform;
  final String? endPlatform;

  bool get counts {
    if (superseded || provisional) return false;
    if (intervalStatus == 'void' || intervalStatus == 'open' || intervalStatus == 'incomplete') return false;
    if (startedAt == null || endedAt == null) return false;
    return true;
  }

  /// True on both halves: the slice starts or ends on the Tehran midnight cut.
  bool get dailyCut {
    if (startedAt == null || endedAt == null) return false;
    return _atMidnight(startedAt!) || _atMidnight(endedAt!);
  }

  static bool _atMidnight(DateTime instant) {
    final wall = TehranTime.wallClock(instant);
    return wall.hour == 0 && wall.minute == 0 && wall.second == 0;
  }
}

class DayAttendance {
  const DayAttendance({
    required this.day,
    required this.slices,
    required this.tone,
    required this.hasOpen,
    this.approvedSeconds = 0,
  });

  final Jalali day;
  final List<CalendarSlice> slices;
  final DayTone tone;
  final bool hasOpen;

  /// From `attendance_buckets`, never summed from slices in the app.
  final int approvedSeconds;

  String get iso => isoOf(day);
}

class PersonAttendance {
  const PersonAttendance({
    required this.id,
    required this.name,
    required this.teamId,
    required this.totals,
    required this.days,
  });

  final String id;
  final String name;
  final String teamId;

  /// From `attendance_totals` for the selected range.
  final DurationTotals totals;
  final List<DayAttendance> days;

  DayAttendance? dayOn(String iso) {
    for (final day in days) {
      if (day.iso == iso) return day;
    }
    return null;
  }
}

class AttendanceCalendarModel {
  const AttendanceCalendarModel({required this.days, required this.totals});

  final List<DayAttendance> days;
  final DurationTotals totals;

  static const emptyTotals = DurationTotals(recorded: 0, pending: 0, approved: 0, revision: 0, rejected: 0);
}

/// One server-side page. [total] counts everyone this viewer may see under the
/// current filters, not only the people on this page.
class GroupAttendance {
  const GroupAttendance({
    required this.people,
    required this.total,
    this.limit = groupPageSize,
    this.offset = 0,
  });

  final List<PersonAttendance> people;
  final int total;
  final int limit;
  final int offset;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + limit < total;
  int get pageIndex => offset ~/ limit;
  int get pageCount => total == 0 ? 1 : (total + limit - 1) ~/ limit;
}

const groupPageSize = 50;

/// Reads `attendance_group_page`. Every duration here is what the backend sent.
GroupAttendance parseGroupPage(Map<String, dynamic> raw, List<Jalali> days) {
  final people = <PersonAttendance>[];
  for (final row in _maps(raw['people'])) {
    final id = row['id']?.toString() ?? '';
    final totals = row['totals'];
    final approved = row['approved_by_day'];
    people.add(PersonAttendance(
      id: id,
      name: '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}'.trim(),
      teamId: row['team_id']?.toString() ?? '',
      totals: totals is Map ? DurationTotals.fromRow(Map<String, dynamic>.from(totals)) : AttendanceCalendarModel.emptyTotals,
      days: buildDays(
        days,
        [for (final slice in _maps(row['slices'])) _groupSlice(slice, id)],
        approved: approved is Map
            ? {for (final entry in approved.entries) entry.key.toString(): (entry.value as num?)?.toInt() ?? 0}
            : const {},
      ),
    ));
  }
  return GroupAttendance(
    people: people,
    total: (raw['total'] as num?)?.toInt() ?? 0,
    limit: (raw['limit'] as num?)?.toInt() ?? groupPageSize,
    offset: (raw['offset'] as num?)?.toInt() ?? 0,
  );
}

List<Map<String, dynamic>> _maps(dynamic value) {
  if (value is! List) return const [];
  return [for (final row in value) if (row is Map) Map<String, dynamic>.from(row)];
}

DateTime? _time(dynamic value) => value == null ? null : DateTime.tryParse(value.toString());

CalendarSlice _groupSlice(Map<String, dynamic> row, String profileId) {
  return CalendarSlice(
    intervalId: row['interval_id']?.toString() ?? '',
    profileId: profileId,
    tehranDate: row['tehran_date']?.toString() ?? '',
    startedAt: _time(row['started_at']),
    endedAt: _time(row['ended_at']),
    intervalStatus: row['interval_status']?.toString() ?? 'closed',
    approvalMode: row['approval_mode']?.toString() ?? 'report',
    decision: row['decision']?.toString(),
    startPlatform: row['start_platform']?.toString(),
    endPlatform: row['end_platform']?.toString(),
  );
}

class AttendanceCalendarQuery {
  const AttendanceCalendarQuery({
    required this.year,
    required this.month,
    required this.profileId,
    this.includePreview = false,
  });

  final int year;
  final int month;
  final String profileId;
  final bool includePreview;

  @override
  bool operator ==(Object other) {
    return other is AttendanceCalendarQuery &&
        other.year == year &&
        other.month == month &&
        other.profileId == profileId &&
        other.includePreview == includePreview;
  }

  @override
  int get hashCode => Object.hash(year, month, profileId, includePreview);
}

class GroupAttendanceQuery {
  const GroupAttendanceQuery({required this.range, this.teamId, this.search = '', this.page = 0});

  final AttendanceRange range;
  final String? teamId;
  final String search;
  final int page;

  @override
  bool operator ==(Object other) {
    return other is GroupAttendanceQuery &&
        other.range == range &&
        other.teamId == teamId &&
        other.search == search &&
        other.page == page;
  }

  @override
  int get hashCode => Object.hash(range, teamId, search, page);
}

enum RangeKind { week, month, custom }

class AttendanceRange {
  const AttendanceRange._(this.kind, this.from, this.to);

  /// The Saturday-to-Friday week that holds [day].
  factory AttendanceRange.week(Jalali day) {
    final start = day.addDays(1 - day.weekDay);
    return AttendanceRange._(RangeKind.week, start, start.addDays(6));
  }

  factory AttendanceRange.month(Jalali day) {
    return AttendanceRange._(
      RangeKind.month,
      Jalali(day.year, day.month, 1),
      Jalali(day.year, day.month, day.monthLength),
    );
  }

  /// Null when [to] is before [from] or the span is over [maxDays].
  static AttendanceRange? custom(Jalali from, Jalali to) {
    final span = _utcDay(to).difference(_utcDay(from)).inDays + 1;
    if (span < 1 || span > maxDays) return null;
    return AttendanceRange._(RangeKind.custom, from, to);
  }

  static const maxDays = 31;

  final RangeKind kind;
  final Jalali from;
  final Jalali to;

  List<Jalali> get days {
    final span = _utcDay(to).difference(_utcDay(from)).inDays + 1;
    return [for (var index = 0; index < span; index++) from.addDays(index)];
  }

  AttendanceRange shift(int delta) {
    return switch (kind) {
      RangeKind.week => AttendanceRange.week(from.addDays(delta * 7)),
      RangeKind.month => AttendanceRange.month(shiftJalaliMonth(from, delta)),
      RangeKind.custom => AttendanceRange._(
          RangeKind.custom,
          from.addDays(delta * days.length),
          to.addDays(delta * days.length),
        ),
    };
  }

  bool contains(Jalali day) => isoOf(from).compareTo(isoOf(day)) <= 0 && isoOf(day).compareTo(isoOf(to)) <= 0;

  @override
  bool operator ==(Object other) {
    return other is AttendanceRange && other.kind == kind && other.from == from && other.to == to;
  }

  @override
  int get hashCode => Object.hash(kind, isoOf(from), isoOf(to));
}

DateTime _utcDay(Jalali day) {
  final gregorian = day.toGregorian();
  return DateTime.utc(gregorian.year, gregorian.month, gregorian.day);
}

String isoOf(Jalali day) => TehranTime.jalaliDayIso(day.year, day.month, day.day);

Jalali shiftJalaliMonth(Jalali month, int delta) {
  final index = month.year * 12 + (month.month - 1) + delta;
  return Jalali(index ~/ 12, index % 12 + 1, 1);
}

/// Saturday is column 0 and Friday is column 6.
List<Jalali?> monthCells(Jalali month) {
  final first = Jalali(month.year, month.month, 1);
  final cells = <Jalali?>[for (var index = 1; index < first.weekDay; index++) null];
  for (var day = 1; day <= first.monthLength; day++) {
    cells.add(Jalali(month.year, month.month, day));
  }
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return cells;
}

DayTone dayTone(Iterable<CalendarSlice> slices) {
  final visible = [for (final slice in slices) if (!slice.superseded && slice.intervalStatus != 'void') slice];
  if (visible.any((slice) => slice.intervalStatus == 'incomplete')) return DayTone.incomplete;
  final counted = [for (final slice in visible) if (slice.counts) slice];
  if (counted.isEmpty) {
    return visible.any((slice) => slice.intervalStatus == 'open' || slice.provisional) ? DayTone.open : DayTone.empty;
  }
  final kinds = counted.map(_kind).toSet();
  if (kinds.length > 1) return DayTone.partial;
  return switch (kinds.single) {
    'approved' => DayTone.approved,
    'pending' => DayTone.pending,
    'rejected' => DayTone.rejected,
    'revision' => DayTone.revision,
    _ => DayTone.pending,
  };
}

/// A person's approval state, read only from backend totals.
DayTone personTone(DurationTotals totals) {
  if (totals.recorded == 0) return DayTone.empty;
  final kinds = [
    if (totals.approved > 0) DayTone.approved,
    if (totals.pending > 0) DayTone.pending,
    if (totals.revision > 0) DayTone.revision,
    if (totals.rejected > 0) DayTone.rejected,
  ];
  if (kinds.isEmpty) return DayTone.pending;
  return kinds.length == 1 ? kinds.single : DayTone.partial;
}

String _kind(CalendarSlice slice) {
  if (slice.approvalMode == 'correction' || slice.decision == 'approved') return 'approved';
  if (slice.decision == 'needs_revision') return 'revision';
  if (slice.decision == 'rejected') return 'rejected';
  return 'pending';
}

List<DayAttendance> buildDays(
  Iterable<Jalali> days,
  Iterable<CalendarSlice> slices, {
  Map<String, int> approved = const {},
}) {
  return [for (final day in days) _day(day, slices, approved)];
}

List<DayAttendance> buildMonth(
  Jalali month,
  Iterable<CalendarSlice> slices, {
  Map<String, int> approved = const {},
}) {
  final first = Jalali(month.year, month.month, 1);
  return buildDays(
    [for (var day = 1; day <= first.monthLength; day++) Jalali(month.year, month.month, day)],
    slices,
    approved: approved,
  );
}

DayAttendance _day(Jalali day, Iterable<CalendarSlice> slices, Map<String, int> approved) {
  final iso = isoOf(day);
  final mine = [
    for (final slice in slices)
      if (slice.tehranDate == iso && !slice.superseded && slice.intervalStatus != 'void') slice,
  ]..sort((a, b) => (a.startedAt ?? DateTime.utc(1970)).compareTo(b.startedAt ?? DateTime.utc(1970)));
  return DayAttendance(
    day: day,
    slices: mine,
    tone: dayTone(mine),
    hasOpen: mine.any((slice) => slice.intervalStatus == 'open' || slice.provisional),
    approvedSeconds: approved[iso] ?? 0,
  );
}

List<PersonAttendance> filterPeople(Iterable<PersonAttendance> people, {String? teamId, String? employeeId}) {
  return [
    for (final person in people)
      if ((teamId == null || person.teamId == teamId) && (employeeId == null || person.id == employeeId)) person,
  ];
}

String dayToneLabel(DayTone tone) {
  return switch (tone) {
    DayTone.empty => '—',
    DayTone.open => 'باز',
    DayTone.incomplete => 'ناقص',
    DayTone.pending => 'انتظار',
    DayTone.approved => 'تأیید',
    DayTone.partial => 'جزئی',
    DayTone.revision => 'اصلاح',
    DayTone.rejected => 'رد',
  };
}
