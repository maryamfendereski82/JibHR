import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../session/workspace_session.dart';
import 'attendance_calendar.dart';
import 'attendance_calendar_view.dart';
import 'attendance_group_view.dart';
import 'attendance_providers.dart';
import 'attendance_repository.dart';
import 'attendance_review.dart';

final dashboardAttendanceProvider = FutureProvider<AttendanceBoard?>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('attendance.view.self')) return null;
  return AttendanceRepository(client).load(session.profileId);
});

final attendanceBoardProvider = FutureProvider<AttendanceBoard?>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('attendance.view.self')) return null;
  return AttendanceRepository(client).load(session.profileId);
});

/// Clock in or out through the existing RPCs and refresh what depends on it.
/// Shared by the attendance page and Home so both run the same logic.
/// Throws on failure; the caller decides how to tell the person.
Future<void> punchAttendance(WidgetRef ref, {required bool isOpen}) async {
  final client = ref.read(supabaseClientProvider);
  if (client == null) throw StateError('no client');
  await AttendanceRepository(client).punch(isOpen: isOpen);
  ref.invalidate(attendanceBoardProvider);
  ref.invalidate(dashboardAttendanceProvider);
  ref.invalidate(attendanceDayTotalsProvider);
}

class AttendancePage extends ConsumerStatefulWidget {
  const AttendancePage({super.key});

  @override
  ConsumerState<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends ConsumerState<AttendancePage> {
  final Jalali today = TehranTime.jalali(DateTime.now().toUtc());
  late Jalali month = today;
  late AttendanceRange range = AttendanceRange.week(today);
  int? selectedDay;
  bool group = false;
  String? teamId;
  ({String id, String name})? person;
  String search = '';
  int page = 0;
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || value.trim() == search) return;
      setState(() {
        search = value.trim();
        page = 0;
      });
    });
  }

  Future<void> _punch(bool isOpen, AttendanceCalendarQuery? query) async {
    if (ref.read(supabaseClientProvider) == null) return;
    try {
      await punchAttendance(ref, isOpen: isOpen);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(Fa.network)));
      return;
    }
    if (query != null) ref.invalidate(attendanceCalendarProvider(query));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final canGroup = session?.can('attendance.view.team') == true || session?.can('attendance.view.all') == true;
    final inGroup = group && canGroup;
    final matrix = inGroup && person == null;
    final profileId = inGroup ? (person?.id ?? '') : (session?.profileId ?? '');

    final monthQuery = session == null || matrix
        ? null
        : AttendanceCalendarQuery(
            year: month.year,
            month: month.month,
            profileId: profileId,
            includePreview: profileId == session.profileId,
          );
    final groupQuery = GroupAttendanceQuery(range: range, teamId: teamId, search: search, page: page);
        final palette = paletteOf(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topEnd,
          end: AlignmentDirectional.bottomStart,
          colors: [
            Color.alphaBlend(palette.jade.withValues(alpha: 0.10), palette.canvas),
            palette.canvas,
            Color.alphaBlend(palette.info.withValues(alpha: 0.07), palette.canvas),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            session: session,
            canGroup: canGroup,
            group: inGroup,
            onGroup: (value) => setState(() {
              group = value;
              selectedDay = null;
              if (!value) person = null;
            }),
          ),
          if (!inGroup) _ClockCard(onPunch: (isOpen) => _punch(isOpen, monthQuery)),
          if (inGroup)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _GroupFilters(
                teamId: teamId,
                person: person?.name,
                initialSearch: search,
                onTeam: (value) => setState(() {
                  teamId = value;
                  person = null;
                  selectedDay = null;
                  page = 0;
                }),
                onSearch: _onSearch,
                trailing: matrix
                    ? AttendanceRangeBar(range: range, today: today, onChanged: (value) => setState(() {
                        range = value;
                        page = 0;
                      }))
                    : TextButton.icon(
                        key: const Key('attendance-back-to-group'),
                        onPressed: () => setState(() {
                          person = null;
                          selectedDay = null;
                        }),
                        icon: const Icon(Icons.groups_outlined),
                        label: const Text(Fa.backToGroup),
                      ),
              ),
            ),
          Expanded(
            child: matrix
                ? _GroupBody(
                    query: groupQuery,
                    today: today,
                    onPerson: (value) => setState(() {
                      person = (id: value.id, name: value.name);
                      selectedDay = null;
                    }),
                    onPage: (value) => setState(() => page = value),
                  )
                : monthQuery == null || profileId.isEmpty
                    ? const LoadingView()
                    : _MonthBody(
                        month: month,
                        today: today,
                        query: monthQuery,
                        selectedDay: selectedDay,
                        onMonth: (delta) => setState(() {
                          month = shiftJalaliMonth(month, delta);
                          selectedDay = null;
                        }),
                        onSelect: (day) => setState(() => selectedDay = day.day.day),
                      ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.canGroup, required this.group, required this.onGroup});

  final WorkspaceSession? session;
  final bool canGroup;
  final bool group;
  final ValueChanged<bool> onGroup;

  @override
  Widget build(BuildContext context) {
    final current = session;
    final canApprove = current?.can('attendance.approve.team') == true || current?.can('attendance.approve.all') == true;
    final canCorrect = current?.can('attendance.correct.self') == true;
    final links = [
      if (canApprove) (Fa.approvalQueue, '/attendance/approvals'),
      if (canApprove) (Fa.correctionQueue, '/attendance/corrections'),
      if (canCorrect) (Fa.myCorrections, '/attendance/mine'),
    ];
    final compact = MediaQuery.sizeOf(context).width < compactBelow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(Fa.attendance, style: Theme.of(context).textTheme.headlineSmall),
          if (canGroup)
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text(Fa.individualCalendar)),
                ButtonSegment(value: true, label: Text(Fa.groupCalendar)),
              ],
              selected: {group},
              onSelectionChanged: (value) => onGroup(value.first),
            ),
          if (compact && links.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: Fa.moreActions,
              icon: const Icon(Icons.more_horiz),
              onSelected: (path) => context.go(path),
              itemBuilder: (context) => [
                for (final link in links) PopupMenuItem(value: link.$2, child: Text(link.$1)),
              ],
            )
          else
            for (final link in links) TextButton(onPressed: () => context.go(link.$2), child: Text(link.$1)),
        ],
      ),
    );
  }
}

class _ClockCard extends ConsumerWidget {
  const _ClockCard({required this.onPunch});

  final ValueChanged<bool> onPunch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = paletteOf(context);
    final canClock = ref.watch(workspaceSessionProvider).asData?.value?.can('attendance.clock') ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ref.watch(attendanceBoardProvider).when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => const SizedBox.shrink(),
            data: (value) => value == null
                ? const SizedBox.shrink()
                : GlassCard(
                    blur: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(color: value.isOpen ? palette.info : palette.muted, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 6),
                                Text(value.isOpen ? Fa.clockedIn : Fa.clockedOut, style: const TextStyle(fontWeight: FontWeight.w600)),
                              ],
                            ),
                            Text('${Fa.today}: ${formatHours(value.today.recorded)}'),
                            Text('${Fa.thisWeek}: ${formatHours(value.week.recorded)}'),
                            if (value.isOpen) Text(Fa.provisional, style: TextStyle(color: palette.warning, fontSize: 12.5)),
                          ],
                        ),
                        if (canClock)
                          SizedBox(
                            width: 150,
                            child: AppButton(
                              label: value.isOpen ? Fa.clockOut : Fa.clockIn,
                              onPressed: () async => onPunch(value.isOpen),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
    );
  }
}

/// A failed read shows the error at once. The provider keeps retrying behind it,
/// and without this check the retries would read as an endless spinner.
class _GroupBody extends ConsumerWidget {
  const _GroupBody({required this.query, required this.today, required this.onPerson, required this.onPage});

  final GroupAttendanceQuery query;
  final Jalali today;
  final ValueChanged<PersonAttendance> onPerson;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(attendanceGroupProvider(query));
    if (group.hasError && !group.hasValue) {
      return ErrorView(message: Fa.network, onRetry: () => ref.invalidate(attendanceGroupProvider(query)));
    }
    final value = group.asData?.value;
    if (value == null) return const LoadingView();
    return AttendanceGroupView(range: query.range, today: today, group: value, onPerson: onPerson, onPage: onPage);
  }
}

/// The grid stays up with its month while the data loads, so the arrows never jump.
class _MonthBody extends ConsumerWidget {
  const _MonthBody({
    required this.month,
    required this.today,
    required this.query,
    required this.selectedDay,
    required this.onMonth,
    required this.onSelect,
  });

  final Jalali month;
  final Jalali today;
  final AttendanceCalendarQuery query;
  final int? selectedDay;
  final ValueChanged<int> onMonth;
  final ValueChanged<DayAttendance> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendar = ref.watch(attendanceCalendarProvider(query));
    if (calendar.hasError && !calendar.hasValue) {
      return ErrorView(message: Fa.network, onRetry: () => ref.invalidate(attendanceCalendarProvider(query)));
    }
    final model = calendar.asData?.value ??
        AttendanceCalendarModel(days: buildMonth(month, const []), totals: AttendanceCalendarModel.emptyTotals);
    return AttendanceCalendarView(
      month: month,
      today: today,
      profileId: query.profileId,
      model: model,
      loading: calendar.isLoading,
      selectedDay: selectedDay,
      onMonth: onMonth,
      onSelect: onSelect,
    );
  }
}

class _GroupFilters extends ConsumerWidget {
  const _GroupFilters({
    required this.teamId,
    required this.person,
    required this.initialSearch,
    required this.onTeam,
    required this.onSearch,
    required this.trailing,
  });

  final String? teamId;
  final String? person;
  final String initialSearch;
  final ValueChanged<String?> onTeam;
  final ValueChanged<String> onSearch;
  final Widget trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teams = ref.watch(attendanceTeamsProvider).asData?.value ?? const <TeamOption>[];
    final teamValue = teams.any((team) => team.id == teamId) ? teamId : null;
    final compact = MediaQuery.sizeOf(context).width < compactBelow;
    final fieldWidth = compact ? (MediaQuery.sizeOf(context).width - 40) / 2 : 200.0;
    final name = person;
    return Wrap(
      key: const Key('attendance-group-filters'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: fieldWidth,
          child: DropdownButtonFormField<String?>(
            key: ValueKey('team-${teams.length}-$teamValue'),
            isExpanded: true,
            initialValue: teamValue,
            decoration: const InputDecoration(labelText: Fa.team, isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text(Fa.allTeams)),
              for (final team in teams) DropdownMenuItem(value: team.id, child: Text(team.name)),
            ],
            onChanged: onTeam,
          ),
        ),
        if (name == null)
          SizedBox(
            width: fieldWidth,
            child: TextFormField(
              key: const Key('attendance-search'),
              initialValue: initialSearch,
              onChanged: onSearch,
              decoration: const InputDecoration(
                labelText: Fa.searchEmployee,
                isDense: true,
                suffixIcon: Icon(Icons.search, size: 20),
              ),
            ),
          )
        else
          Text(name.isEmpty ? Fa.employee : name, key: const Key('attendance-person-name'), style: Theme.of(context).textTheme.titleSmall),
        trailing,
      ],
    );
  }
}
