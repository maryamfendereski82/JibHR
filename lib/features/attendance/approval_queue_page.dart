import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../session/workspace_session.dart';
import 'attendance_review.dart';
import 'attendance_review_repository.dart';
import 'jalali_fields.dart';

typedef QueueKey = ({String? teamId, String? day});

final teamOptionsProvider = FutureProvider<List<TeamOption>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  return AttendanceReviewRepository(client).teams();
});

final approvalQueueProvider = FutureProvider.family<List<ReviewReport>, QueueKey>((ref, key) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('attendance.approve.team') && !session.can('attendance.approve.all')) return const [];
  return AttendanceReviewRepository(client).openReports(teamId: key.teamId, tehranDate: key.day);
});

class ApprovalQueuePage extends ConsumerStatefulWidget {
  const ApprovalQueuePage({super.key});

  @override
  ConsumerState<ApprovalQueuePage> createState() => _ApprovalQueuePageState();
}

class _ApprovalQueuePageState extends ConsumerState<ApprovalQueuePage> {
  final search = TextEditingController();
  String? teamId;
  JalaliStamp? day;
  String? selectedId;
  bool busy = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  QueueKey get _key => (teamId: teamId, day: day?.isoDay);

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(approvalQueueProvider(_key));
    final teams = ref.watch(teamOptionsProvider);
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    return queue.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: reviewErrorText(error), onRetry: () => ref.invalidate(approvalQueueProvider(_key))),
      data: (reports) {
        final shown = _filter(reports);
        ReviewReport? selected;
        for (final report in shown) {
          if (report.id == selectedId) selected = report;
        }
        final list = _ReportList(
          reports: shown,
          pendingCount: reports.where((report) => report.status == 'pending').length,
          selectedId: selectedId,
          search: search,
          teamId: teamId,
          teams: teams.asData?.value ?? const [],
          day: day,
          onQuery: () => setState(() {}),
          onTeam: (value) => setState(() => teamId = value),
          onDay: (value) => setState(() => day = value),
          onSelect: (id) => setState(() => selectedId = id),
        );
        final Widget detail;
        if (selected == null) {
          detail = const EmptyView(message: Fa.pickReport);
        } else {
          final current = selected;
          detail = ReportDetail(
            report: current,
            busy: busy,
            onDecide: _decide,
            onApprovePending: () => _approvePending(current),
          );
        }
        if (!wide && selected != null) {
          return Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => setState(() => selectedId = null), child: const Text(Fa.back)),
              ),
              Expanded(child: detail),
            ],
          );
        }
        if (!wide) return list;
        return Row(
          children: [
            SizedBox(width: 420, child: list),
            const VerticalDivider(width: 1),
            Expanded(child: detail),
          ],
        );
      },
    );
  }

  List<ReviewReport> _filter(List<ReviewReport> reports) {
    final needle = search.text.trim();
    if (needle.isEmpty) return reports;
    return reports.where((report) => report.employeeName.contains(needle)).toList();
  }

  Future<void> _approvePending(ReviewReport report) async {
    final client = ref.read(supabaseClientProvider);
    final ids = pendingDecisionIds(report.items);
    if (client == null || busy || ids.isEmpty) return;
    setState(() => busy = true);
    Object? failure;
    try {
      final repository = AttendanceReviewRepository(client);
      for (final id in ids) {
        try {
          await repository.decideItem(id, 'approved', null);
        } catch (error) {
          failure ??= error;
        }
      }
    } finally {
      ref.invalidate(approvalQueueProvider(_key));
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.saved : reviewErrorText(failure))));
  }

  Future<void> _decide(String itemId, String decision, String? reason) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    Object? failure;
    try {
      await AttendanceReviewRepository(client).decideItem(itemId, decision, reason);
    } catch (error) {
      failure = error;
    } finally {
      ref.invalidate(approvalQueueProvider(_key));
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.saved : reviewErrorText(failure))));
  }
}

class _ReportList extends StatelessWidget {
  const _ReportList({
    required this.reports,
    required this.pendingCount,
    required this.selectedId,
    required this.search,
    required this.teamId,
    required this.teams,
    required this.day,
    required this.onQuery,
    required this.onTeam,
    required this.onDay,
    required this.onSelect,
  });

  final List<ReviewReport> reports;
  final int pendingCount;
  final String? selectedId;
  final TextEditingController search;
  final String? teamId;
  final List<TeamOption> teams;
  final JalaliStamp? day;
  final VoidCallback onQuery;
  final ValueChanged<String?> onTeam;
  final ValueChanged<JalaliStamp?> onDay;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: Text(Fa.approvalQueue, style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: Fa.back, onPressed: () => context.go('/attendance'), icon: const Icon(Icons.arrow_forward)),
          ],
        ),
        Text('${persianDigits(pendingCount)} ${Fa.pending} · ${persianDigits(reports.length)} ${Fa.openReports}', style: TextStyle(color: palette.muted)),
        const SizedBox(height: 12),
        TextField(
          controller: search,
          decoration: const InputDecoration(labelText: Fa.searchEmployee),
          onChanged: (_) => onQuery(),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: teams.any((team) => team.id == teamId) ? teamId : null,
          decoration: const InputDecoration(labelText: Fa.team),
          items: [
            const DropdownMenuItem(value: null, child: Text(Fa.allTeams)),
            for (final team in teams) DropdownMenuItem(value: team.id, child: Text(team.name)),
          ],
          onChanged: onTeam,
        ),
        const SizedBox(height: 8),
        if (day == null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => onDay(JalaliStamp.today()), child: const Text(Fa.date)),
          )
        else
          Row(
            children: [
              Expanded(child: JalaliStampField(value: day!, withTime: false, onChanged: onDay)),
              IconButton(tooltip: Fa.clearDate, onPressed: () => onDay(null), icon: const Icon(Icons.close)),
            ],
          ),
        const SizedBox(height: 12),
        if (reports.isEmpty) const EmptyView(),
        for (final report in reports)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              padding: const EdgeInsets.all(14),
              child: InkWell(
                onTap: () => onSelect(report.id),
                child: _ReportSummary(report: report, selected: report.id == selectedId),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReportSummary extends StatelessWidget {
  const _ReportSummary({required this.report, required this.selected});

  final ReviewReport report;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final date = DateTime.utc(report.tehranDate.year, report.tehranDate.month, report.tehranDate.day, 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(report.employeeName.isEmpty ? Fa.attendance : report.employeeName, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('${report.teamName} · ${TehranTime.formatDate(date)}', style: TextStyle(color: palette.muted)),
        const SizedBox(height: 6),
        Text('${reportKindLabel(report.kind)}${report.sequence > 1 ? ' ${persianDigits(report.sequence)}' : ''} · ${reportStatusLabel(report.status)}'),
        Text('${persianDigits(report.intervalCount)} ${Fa.intervals} · ${Fa.recorded} ${formatHours(recordedSeconds(report.items))} · ${Fa.approved} ${formatHours(approvedSeconds(report.items))}'),
        if (selected) const SizedBox(height: 4),
      ],
    );
  }
}

class ReportDetail extends StatelessWidget {
  const ReportDetail({
    super.key,
    required this.report,
    required this.onDecide,
    this.onApprovePending,
    this.busy = false,
  });

  final ReviewReport report;
  final Future<void> Function(String itemId, String decision, String? reason) onDecide;
  final Future<void> Function()? onApprovePending;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final pending = pendingDecisionIds(report.items);
    final date = DateTime.utc(report.tehranDate.year, report.tehranDate.month, report.tehranDate.day, 12);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(Fa.reportDetail, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('${report.employeeName} · ${report.teamName}'),
        Text('${TehranTime.formatDate(date)} · ${reportKindLabel(report.kind)} · ${reportStatusLabel(report.status)}'),
        const SizedBox(height: 12),
        if (pending.isNotEmpty && onApprovePending != null)
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final answer = await askDecision(context, title: Fa.confirmApprovePending, reasonRequired: false);
                    if (answer == null) return;
                    await onApprovePending!();
                  },
            child: const Text(Fa.approvePending),
          ),
        const SizedBox(height: 16),
        for (final item in report.items) _IntervalTile(item: item, busy: busy, onDecide: onDecide),
      ],
    );
  }
}

class _IntervalTile extends StatelessWidget {
  const _IntervalTile({required this.item, required this.busy, required this.onDecide});

  final ReviewItem item;
  final bool busy;
  final Future<void> Function(String itemId, String decision, String? reason) onDecide;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final pending = item.decision == 'pending';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${TehranTime.formatTime(item.startedAt)} – ${item.endedAt == item.startedAt ? '…' : TehranTime.formatTime(item.endedAt)}'),
            Text('${formatHours(item.seconds)} · ${decisionLabel(item.decision)}', style: TextStyle(color: palette.muted)),
            if (platformLabel(item.startPlatform, item.endPlatform).isNotEmpty)
              Text(platformLabel(item.startPlatform, item.endPlatform), style: TextStyle(color: palette.muted)),
            if (!pending && item.deciderName != null)
              Text('${item.deciderName}${item.decidedAt == null ? '' : ' · ${formatStamp(item.decidedAt)}'}'),
            if (item.reason != null && item.reason!.isNotEmpty) Text(item.reason!),
            if (pending) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy ? null : () => _act(context, 'approved', Fa.confirmApprove, false),
                    child: const Text(Fa.approve),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => _act(context, 'needs_revision', Fa.confirmRevision, true),
                    child: const Text(Fa.requestRevision),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => _act(context, 'rejected', Fa.confirmReject, true),
                    child: const Text(Fa.reject),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, String decision, String title, bool reasonRequired) async {
    final answer = await askDecision(context, title: title, reasonRequired: reasonRequired);
    if (answer == null) return;
    await onDecide(item.id, decision, reasonRequired ? answer : null);
  }
}
