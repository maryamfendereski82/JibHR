import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/networking/supabase_provider.dart';
import '../session/workspace_session.dart';
import 'attendance_calendar.dart';
import 'attendance_repository.dart';
import 'attendance_review.dart';
import 'attendance_review_repository.dart';

final attendanceTeamsProvider = FutureProvider<List<TeamOption>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('attendance.view.team') && !session.can('attendance.view.all')) return const [];
  return AttendanceReviewRepository(client).teams();
});

final attendanceCalendarProvider =
    FutureProvider.autoDispose.family<AttendanceCalendarModel, AttendanceCalendarQuery>((ref, query) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return const AttendanceCalendarModel(days: [], totals: AttendanceCalendarModel.emptyTotals);
  }
  return AttendanceRepository(client).calendar(query);
});

final attendanceGroupProvider =
    FutureProvider.autoDispose.family<GroupAttendance, GroupAttendanceQuery>((ref, query) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return const GroupAttendance(people: [], total: 0);
  return AttendanceRepository(client).group(query);
});

typedef AttendanceDayKey = ({String profileId, String iso});

/// One day's five durations, always from `attendance_totals`.
final attendanceDayTotalsProvider =
    FutureProvider.autoDispose.family<DurationTotals, AttendanceDayKey>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return AttendanceCalendarModel.emptyTotals;
  return AttendanceRepository(client).dayTotals(key.profileId, key.iso);
});
