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
import '../attendance/approval_queue_page.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'leave_repository.dart';
import 'leave_rules.dart';

typedef LeaveKey = ({String? teamId, String? status});

final myLeaveProvider = FutureProvider<List<LeaveRequest>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('leave.view.self')) return const [];
  return LeaveRepository(client).leaves(profileId: session.profileId);
});

final leaveQueueProvider = FutureProvider.family<List<LeaveRequest>, LeaveKey>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('leave.approve.team') && !session.can('leave.approve.all')) return const [];
  return LeaveRepository(client).leaves(teamId: key.teamId, status: key.status);
});

final leaveCalendarProvider = FutureProvider<List<LeaveRequest>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  final canView = session.can('leave.view.self') || session.can('leave.view.team') || session.can('leave.view.all');
  if (!canView) return const [];
  return LeaveRepository(client).leaves();
});

class MyLeavePage extends ConsumerStatefulWidget {
  const MyLeavePage({super.key});

  @override
  ConsumerState<MyLeavePage> createState() => _MyLeavePageState();
}

class _MyLeavePageState extends ConsumerState<MyLeavePage> {
  String kind = 'daily';
  late JalaliStamp start = JalaliStamp.today().copyWith(hour: 9, minute: 0);
  late JalaliStamp end = JalaliStamp.today().copyWith(hour: 11, minute: 0);
  final note = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final history = ref.watch(myLeaveProvider);
    final canApprove = session?.can('leave.approve.team') == true || session?.can('leave.approve.all') == true;
    final canAbsence = session?.can('absence.record.team') == true || session?.can('absence.record.all') == true;
    final canSeeAbsence = session?.can('absence.view.self') == true;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(Fa.myLeave, style: Theme.of(context).textTheme.titleLarge),
        Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: () => context.go('/leave/calendar'), child: const Text(Fa.leaveCalendar)),
            if (canApprove) TextButton(onPressed: () => context.go('/leave/queue'), child: const Text(Fa.leaveQueue)),
            if (canAbsence) TextButton(onPressed: () => context.go('/leave/absence'), child: const Text(Fa.absenceAdmin)),
            if (canSeeAbsence) TextButton(onPressed: () => context.go('/leave/my-absence'), child: const Text(Fa.myAbsence)),
          ],
        ),
        const SizedBox(height: 8),
        if (session?.can('leave.request') == true)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'daily', label: Text(Fa.dailyLeave)),
                    ButtonSegment(value: 'hourly', label: Text(Fa.hourlyLeave)),
                  ],
                  selected: {kind},
                  onSelectionChanged: (value) => setState(() => kind = value.first),
                ),
                const SizedBox(height: 8),
                Text(kind == 'daily' ? Fa.startDate : Fa.date),
                JalaliStampField(value: start, withTime: false, onChanged: (value) => setState(() => start = value)),
                if (kind == 'daily') ...[
                  const SizedBox(height: 8),
                  const Text(Fa.endDate),
                  JalaliStampField(value: end, withTime: false, onChanged: (value) => setState(() => end = value)),
                ] else ...[
                  const SizedBox(height: 8),
                  const Text(Fa.startTime),
                  JalaliStampField(value: start, showDate: false, onChanged: (value) => setState(() => start = value)),
                  const SizedBox(height: 8),
                  const Text(Fa.endTime),
                  JalaliStampField(value: end, showDate: false, onChanged: (value) => setState(() => end = value)),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: Fa.description),
                ),
                const SizedBox(height: 12),
                AppButton(label: Fa.submitRequest, busy: busy, onPressed: _submit),
              ],
            ),
          ),
        const SizedBox(height: 16),
        history.when(
          skipLoadingOnReload: true,
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => ErrorView(message: leaveErrorText(error), onRetry: () => ref.invalidate(myLeaveProvider)),
          data: (rows) => Column(
            children: [
              if (rows.isEmpty) const EmptyView(),
              for (final row in rows) Padding(padding: const EdgeInsets.only(bottom: 10), child: LeaveCard(request: row)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final client = ref.read(supabaseClientProvider);
    final startDay = DateTime.parse(start.isoDay);
    final endDay = DateTime.parse(end.isoDay);
    final problem = leaveProblem(LeaveDraft(
      kind: kind,
      start: startDay,
      end: kind == 'daily' ? endDay : null,
      startMinute: kind == 'hourly' ? start.hour * 60 + start.minute : null,
      endMinute: kind == 'hourly' ? end.hour * 60 + end.minute : null,
    ));
    if (problem != null) {
      _toast(leaveErrorText(problem));
      return;
    }
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await LeaveRepository(client).requestLeave(
        kind: kind,
        note: note.text,
        startDate: kind == 'daily' ? start.isoDay : null,
        endDate: kind == 'daily' ? end.isoDay : null,
        hoursDate: kind == 'hourly' ? start.isoDay : null,
        startTime: kind == 'hourly' ? _hhmm(start.hour, start.minute) : null,
        endTime: kind == 'hourly' ? _hhmm(end.hour, end.minute) : null,
      );
      note.clear();
      ref.invalidate(myLeaveProvider);
      ref.invalidate(leaveCalendarProvider);
      _toast(Fa.leaveSent);
    } catch (error) {
      _toast(leaveErrorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class LeaveQueuePage extends ConsumerStatefulWidget {
  const LeaveQueuePage({super.key});

  @override
  ConsumerState<LeaveQueuePage> createState() => _LeaveQueuePageState();
}

class _LeaveQueuePageState extends ConsumerState<LeaveQueuePage> {
  final search = TextEditingController();
  String? teamId;
  String? status = 'pending';
  JalaliStamp? from;
  JalaliStamp? to;
  bool busy = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  LeaveKey get _key => (teamId: teamId, status: status);

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(leaveQueueProvider(_key));
    final teams = ref.watch(teamOptionsProvider);
    return queue.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: leaveErrorText(error), onRetry: () => ref.invalidate(leaveQueueProvider(_key))),
      data: (rows) {
        final shown = rows.where((row) {
          final needle = search.text.trim();
          if (needle.isNotEmpty && !row.employeeName.contains(needle)) return false;
          return leaveOverlaps(
            row.calendar,
            from == null ? null : DateTime.parse(from!.isoDay),
            to == null ? null : DateTime.parse(to!.isoDay),
          );
        }).toList();
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Expanded(child: Text(Fa.leaveQueue, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: Fa.back, onPressed: () => context.go('/leave'), icon: const Icon(Icons.arrow_forward)),
              ],
            ),
            TextField(
              controller: search,
              decoration: const InputDecoration(labelText: Fa.searchEmployee),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String?>(
              initialValue: (teams.asData?.value ?? const []).any((team) => team.id == teamId) ? teamId : null,
              decoration: const InputDecoration(labelText: Fa.team),
              items: [
                const DropdownMenuItem(value: null, child: Text(Fa.allTeams)),
                for (final team in teams.asData?.value ?? const <TeamOption>[])
                  DropdownMenuItem(value: team.id, child: Text(team.name)),
              ],
              onChanged: (value) => setState(() => teamId = value),
            ),
            DropdownButtonFormField<String?>(
              initialValue: status,
              decoration: const InputDecoration(labelText: Fa.decision),
              items: const [
                DropdownMenuItem(value: null, child: Text(Fa.allStatuses)),
                DropdownMenuItem(value: 'pending', child: Text(Fa.pending)),
                DropdownMenuItem(value: 'approved', child: Text(Fa.approved)),
                DropdownMenuItem(value: 'rejected', child: Text(Fa.rejected)),
              ],
              onChanged: (value) => setState(() => status = value),
            ),
            TextButton(
              onPressed: () => setState(() => from = JalaliStamp.today()),
              child: Text(from == null ? Fa.startDate : '${Fa.startDate} ${_stampLabel(from!)}'),
            ),
            if (from != null) JalaliStampField(value: from!, withTime: false, onChanged: (value) => setState(() => from = value)),
            TextButton(
              onPressed: () => setState(() => to = JalaliStamp.today()),
              child: Text(to == null ? Fa.endDate : '${Fa.endDate} ${_stampLabel(to!)}'),
            ),
            if (to != null) JalaliStampField(value: to!, withTime: false, onChanged: (value) => setState(() => to = value)),
            const SizedBox(height: 8),
            if (shown.isEmpty) const EmptyView(),
            for (final row in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: LeaveCard(request: row, busy: busy, onDecide: row.status == 'pending' ? _decide : null),
              ),
          ],
        );
      },
    );
  }

  Future<void> _decide(String id, bool approve, String? reason) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    Object? failure;
    try {
      await LeaveRepository(client).decideLeave(id, approve: approve, reason: reason);
    } catch (error) {
      failure = error;
    } finally {
      ref.invalidate(leaveQueueProvider(_key));
      ref.invalidate(myLeaveProvider);
      ref.invalidate(leaveCalendarProvider);
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.saved : leaveErrorText(failure))));
  }
}

class LeaveCalendarPage extends ConsumerStatefulWidget {
  const LeaveCalendarPage({super.key});

  @override
  ConsumerState<LeaveCalendarPage> createState() => _LeaveCalendarPageState();
}

class _LeaveCalendarPageState extends ConsumerState<LeaveCalendarPage> {
  late Jalali month = TehranTime.jalali(DateTime.now().toUtc());
  Jalali? selected;

  @override
  Widget build(BuildContext context) {
    final leaves = ref.watch(leaveCalendarProvider);
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    return leaves.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: leaveErrorText(error), onRetry: () => ref.invalidate(leaveCalendarProvider)),
      data: (rows) {
        final visible = rows.where((row) => visibleOnCalendar(row.status)).map((row) => row.calendar).toList();
        final grid = LeaveMonthGrid(
          month: month,
          leaves: visible,
          selected: selected,
          onMonth: (value) => setState(() => month = value),
          onDay: (value) => setState(() => selected = value),
        );
        final detail = _DayDetail(
          day: selected,
          rows: rows.where((row) => visibleOnCalendar(row.status) && selected != null && row.calendar.covers(_gregorianNoon(selected!))).toList(),
        );
        return Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => context.go('/leave'), child: const Text(Fa.back)),
            ),
            Expanded(
              child: wide
                  ? Row(children: [Expanded(child: grid), const VerticalDivider(width: 1), SizedBox(width: 360, child: detail)])
                  : ListView(children: [grid, detail]),
            ),
          ],
        );
      },
    );
  }
}

class LeaveMonthGrid extends StatelessWidget {
  const LeaveMonthGrid({super.key,
    required this.month,
    required this.leaves,
    required this.selected,
    required this.onMonth,
    required this.onDay,
  });

  final Jalali month;
  final List<CalendarLeave> leaves;
  final Jalali? selected;
  final ValueChanged<Jalali> onMonth;
  final ValueChanged<Jalali> onDay;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final cells = leaveMonthCells(month);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => onMonth(month.month == 1 ? Jalali(month.year - 1, 12, 1) : Jalali(month.year, month.month - 1, 1)),
              icon: const Icon(Icons.chevron_right),
            ),
            Expanded(
              child: Text(
                '${jalaliMonths[month.month - 1]} ${persianDigits(month.year)}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: () => onMonth(month.month == 12 ? Jalali(month.year + 1, 1, 1) : Jalali(month.year, month.month + 1, 1)),
              icon: const Icon(Icons.chevron_left),
            ),
          ],
        ),
        const Row(
          children: [
            _WeekLabel('ش'),
            _WeekLabel('ی'),
            _WeekLabel('د'),
            _WeekLabel('س'),
            _WeekLabel('چ'),
            _WeekLabel('پ'),
            _WeekLabel('ج'),
          ],
        ),
        GridView.count(
          crossAxisCount: 7,
          childAspectRatio: 0.72,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final cell in cells)
              if (cell == null)
                const SizedBox.shrink()
              else
                InkWell(
                  key: ValueKey('day-${cell.day}'),
                  onTap: () => onDay(cell),
                  child: _DayCell(
                    day: cell,
                    leaves: leaves.where((leave) => leave.covers(_gregorianNoon(cell))).toList(),
                    selected: selected?.year == cell.year && selected?.month == cell.month && selected?.day == cell.day,
                    muted: palette.muted,
                    jade: palette.jade,
                    warning: palette.warning,
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.leaves,
    required this.selected,
    required this.muted,
    required this.jade,
    required this.warning,
  });

  final Jalali day;
  final List<CalendarLeave> leaves;
  final bool selected;
  final Color muted;
  final Color jade;
  final Color warning;

  @override
  Widget build(BuildContext context) {
    final approved = leaves.where((leave) => countsAsApprovedLeave(leave.status)).length;
    final pending = leaves.length - approved;
    return Column(
      key: ValueKey('day-${day.day}-approved-$approved-pending-$pending'),
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          persianDigits(day.day),
          style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400, color: selected ? jade : null),
        ),
        if (approved > 0) Text(persianDigits(approved), key: ValueKey('approved-${day.day}'), style: TextStyle(color: jade, fontSize: 11)),
        if (pending > 0) Text(persianDigits(pending), key: ValueKey('pending-${day.day}'), style: TextStyle(color: warning, fontSize: 11)),
        if (leaves.isEmpty) Text(' ', style: TextStyle(color: muted, fontSize: 11)),
      ],
    );
  }
}

class _WeekLabel extends StatelessWidget {
  const _WeekLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Expanded(child: Text(text, textAlign: TextAlign.center));
}

class _DayDetail extends StatelessWidget {
  const _DayDetail({required this.day, required this.rows});

  final Jalali? day;
  final List<LeaveRequest> rows;

  @override
  Widget build(BuildContext context) {
    if (day == null) return const EmptyView(message: Fa.pickReport);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(16),
      children: [
        Text(TehranTime.formatDate(_gregorianNoon(day!)), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (rows.isEmpty) const EmptyView(),
        for (final row in rows) Padding(padding: const EdgeInsets.only(bottom: 8), child: LeaveCard(request: row)),
      ],
    );
  }
}

class LeaveCard extends StatelessWidget {
  const LeaveCard({super.key, required this.request, this.onDecide, this.busy = false});

  final LeaveRequest request;
  final Future<void> Function(String id, bool approve, String? reason)? onDecide;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final duration = request.durationLabel;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.employeeName.isEmpty ? Fa.leave : request.employeeName, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${request.teamName} · ${request.kind == 'hourly' ? Fa.hourlyLeave : Fa.dailyLeave} · ${decisionLabel(request.status)}'),
          Text(request.period),
          if (duration.isNotEmpty)
            Text('${Fa.duration}: ${request.kind == 'hourly' ? persianDigits(duration) : '${persianDigits(duration)} ${Fa.dayCount}'}'),
          Text(formatStamp(request.createdAt), style: TextStyle(color: palette.muted)),
          if (request.note.isNotEmpty) Text(request.note),
          if (request.decisionReason != null && request.decisionReason!.isNotEmpty)
            Text('${Fa.decision}: ${request.deciderName ?? ''} ${request.decisionReason}'),
          if (onDecide != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : () => _act(context, true, Fa.confirmApproveLeave, false),
                  child: const Text(Fa.approve),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => _act(context, false, Fa.confirmRejectLeave, true),
                  child: const Text(Fa.reject),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _act(BuildContext context, bool approve, String title, bool reasonRequired) async {
    final answer = await askDecision(context, title: title, reasonRequired: reasonRequired);
    if (answer == null) return;
    await onDecide?.call(request.id, approve, reasonRequired ? answer : null);
  }
}

List<Jalali?> leaveMonthCells(Jalali month) {
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

DateTime _gregorianNoon(Jalali day) {
  final gregorian = day.toGregorian();
  return DateTime.utc(gregorian.year, gregorian.month, gregorian.day, 12);
}

String _hhmm(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

String leaveErrorText(Object error) {
  final raw = error.toString();
  if (raw.contains('primary_team_required')) return Fa.primaryTeamRequired;
  if (raw.contains('check constraint') || raw.contains('invalid_range') || raw.contains('invalid_kind')) {
    return Fa.invalidRange;
  }
  return reviewErrorText(error);
}

String _stampLabel(JalaliStamp stamp) => TehranTime.formatDate(DateTime.parse('${stamp.isoDay}T12:00:00Z'));
