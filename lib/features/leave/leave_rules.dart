class LeaveDraft {
  const LeaveDraft({
    required this.kind,
    this.start,
    this.end,
    this.startMinute,
    this.endMinute,
  });

  final String kind;
  final DateTime? start;
  final DateTime? end;
  final int? startMinute;
  final int? endMinute;
}

/// Same bounds as the `leave_requests` check: daily end is inclusive, hourly end is later the same day.
String? leaveProblem(LeaveDraft draft) {
  if (draft.kind == 'daily') {
    if (draft.start == null || draft.end == null || draft.end!.isBefore(draft.start!)) return 'invalid_range';
    return null;
  }
  if (draft.kind == 'hourly') {
    if (draft.start == null || draft.startMinute == null || draft.endMinute == null) return 'invalid_range';
    if (draft.endMinute! <= draft.startMinute!) return 'invalid_range';
    return null;
  }
  return 'invalid_kind';
}

int inclusiveDays(DateTime start, DateTime end) => end.difference(start).inDays + 1;

int hourlyMinutes(int startMinute, int endMinute) => endMinute - startMinute;

class CalendarLeave {
  const CalendarLeave({
    required this.id,
    required this.kind,
    required this.status,
    required this.label,
    this.start,
    this.end,
    this.hoursDate,
  });

  final String id;
  final String kind;
  final String status;
  final String label;
  final DateTime? start;
  final DateTime? end;
  final DateTime? hoursDate;

  bool covers(DateTime day) {
    final target = DateTime.utc(day.year, day.month, day.day);
    if (kind == 'hourly') {
      final hours = hoursDate;
      return hours != null && DateTime.utc(hours.year, hours.month, hours.day) == target;
    }
    final first = start;
    final last = end;
    if (first == null || last == null) return false;
    final from = DateTime.utc(first.year, first.month, first.day);
    final to = DateTime.utc(last.year, last.month, last.day);
    return !target.isBefore(from) && !target.isAfter(to);
  }
}

bool leaveOverlaps(CalendarLeave leave, DateTime? from, DateTime? to) {
  final start = leave.kind == 'hourly' ? leave.hoursDate : leave.start;
  final end = leave.kind == 'hourly' ? leave.hoursDate : leave.end;
  if (start == null || end == null) return false;
  if (from == null && to == null) return true;
  final first = DateTime.utc(start.year, start.month, start.day);
  final last = DateTime.utc(end.year, end.month, end.day);
  if (from != null && last.isBefore(DateTime.utc(from.year, from.month, from.day))) return false;
  if (to != null && first.isAfter(DateTime.utc(to.year, to.month, to.day))) return false;
  return true;
}

bool countsAsApprovedLeave(String status) => status == 'approved';

bool visibleOnCalendar(String status) => status == 'approved' || status == 'pending';
