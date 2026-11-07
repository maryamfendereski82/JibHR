import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../session/workspace_session.dart';
import 'attendance_review.dart';
import 'attendance_review_repository.dart';
import 'jalali_fields.dart';

final correctionQueueProvider = FutureProvider.family<List<CorrectionRequest>, bool>((ref, pendingOnly) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('attendance.approve.team') && !session.can('attendance.approve.all')) return const [];
  return AttendanceReviewRepository(client).corrections(pendingOnly: pendingOnly);
});

final myCorrectionsProvider = FutureProvider<List<CorrectionRequest>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('attendance.correct.self')) return const [];
  return AttendanceReviewRepository(client).corrections();
});

final myIntervalsProvider = FutureProvider<List<ReviewItem>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('attendance.correct.self')) return const [];
  return AttendanceReviewRepository(client).myIntervals();
});

class CorrectionQueuePage extends ConsumerStatefulWidget {
  const CorrectionQueuePage({super.key});

  @override
  ConsumerState<CorrectionQueuePage> createState() => _CorrectionQueuePageState();
}

class _CorrectionQueuePageState extends ConsumerState<CorrectionQueuePage> {
  bool pendingOnly = true;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(correctionQueueProvider(pendingOnly));
    return queue.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(
        message: reviewErrorText(error),
        onRetry: () => ref.invalidate(correctionQueueProvider(pendingOnly)),
      ),
      data: (rows) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(child: Text(Fa.correctionQueue, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: Fa.back, onPressed: () => context.go('/attendance'), icon: const Icon(Icons.arrow_forward)),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(Fa.pendingOnly),
            value: pendingOnly,
            onChanged: (value) => setState(() => pendingOnly = value),
          ),
          if (rows.isEmpty) const EmptyView(),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: CorrectionCard(
                request: row,
                busy: busy,
                onDecide: row.status == 'pending' ? (approve, reason) => _decide(row.id, approve, reason) : null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _decide(String id, bool approve, String? reason) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    Object? failure;
    try {
      await AttendanceReviewRepository(client).decideCorrection(id, approve: approve, reason: reason);
    } catch (error) {
      failure = error;
    } finally {
      ref.invalidate(correctionQueueProvider(pendingOnly));
      ref.invalidate(myCorrectionsProvider);
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.saved : reviewErrorText(failure))));
  }
}

class MyCorrectionsPage extends ConsumerStatefulWidget {
  const MyCorrectionsPage({super.key});

  @override
  ConsumerState<MyCorrectionsPage> createState() => _MyCorrectionsPageState();
}

class _MyCorrectionsPageState extends ConsumerState<MyCorrectionsPage> {
  final reason = TextEditingController();
  String kind = 'missing_out';
  String? intervalId;
  late JalaliStamp start = JalaliStamp.today();
  late JalaliStamp end = JalaliStamp.today();
  bool busy = false;

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(myCorrectionsProvider);
    final intervals = ref.watch(myIntervalsProvider);
    final choices = intervals.asData?.value ?? const <ReviewItem>[];
    final needsInterval = kind != 'missing_in';
    final needsStart = kind == 'missing_in' || kind == 'edit_in';
    final needsEnd = kind == 'missing_in' || kind == 'missing_out' || kind == 'edit_out';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: Text(Fa.myCorrections, style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: Fa.back, onPressed: () => context.go('/attendance'), icon: const Icon(Icons.arrow_forward)),
          ],
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: Fa.correctionKind),
                items: const [
                  DropdownMenuItem(value: 'missing_in', child: Text(Fa.missingIn)),
                  DropdownMenuItem(value: 'missing_out', child: Text(Fa.missingOut)),
                  DropdownMenuItem(value: 'edit_in', child: Text(Fa.editIn)),
                  DropdownMenuItem(value: 'edit_out', child: Text(Fa.editOut)),
                  DropdownMenuItem(value: 'delete_interval', child: Text(Fa.deleteInterval)),
                ],
                onChanged: (value) => setState(() => kind = value ?? kind),
              ),
              if (needsInterval) ...[
                const SizedBox(height: 8),
                if (choices.isEmpty)
                  const Text(Fa.noInterval)
                else
                  DropdownButtonFormField<String>(
                    initialValue: choices.any((item) => item.id == intervalId) ? intervalId : null,
                    decoration: const InputDecoration(labelText: Fa.chooseInterval),
                    items: [
                      for (final item in choices)
                        DropdownMenuItem(
                          value: item.id,
                          child: Text('${formatStamp(item.startedAt)} – ${item.decision == 'open' ? '…' : formatStamp(item.endedAt)}'),
                        ),
                    ],
                    onChanged: (value) => setState(() => intervalId = value),
                  ),
              ],
              if (needsStart) ...[
                const SizedBox(height: 8),
                const Text(Fa.proposedStart),
                JalaliStampField(value: start, onChanged: (value) => setState(() => start = value)),
              ],
              if (needsEnd) ...[
                const SizedBox(height: 8),
                const Text(Fa.proposedEnd),
                JalaliStampField(value: end, onChanged: (value) => setState(() => end = value)),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: reason,
                maxLines: 3,
                decoration: const InputDecoration(labelText: Fa.reason),
              ),
              const SizedBox(height: 12),
              AppButton(label: Fa.submitCorrection, busy: busy, onPressed: choices.isEmpty && needsInterval ? null : _submit),
            ],
          ),
        ),
        const SizedBox(height: 16),
        history.when(
          skipLoadingOnReload: true,
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => ErrorView(message: reviewErrorText(error), onRetry: () => ref.invalidate(myCorrectionsProvider)),
          data: (rows) => Column(
            children: [
              if (rows.isEmpty) const EmptyView(),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CorrectionCard(request: row),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final client = ref.read(supabaseClientProvider);
    final intervals = ref.read(myIntervalsProvider).asData?.value ?? const <ReviewItem>[];
    ReviewItem? selected;
    for (final item in intervals) {
      if (item.id == intervalId) selected = item;
    }
    final problem = correctionProblem(
      kind: kind,
      reason: reason.text,
      intervalId: kind == 'missing_in' ? null : intervalId,
      start: kind == 'missing_in' || kind == 'edit_in' ? start.toUtc() : null,
      end: kind == 'missing_in' || kind == 'missing_out' || kind == 'edit_out' ? end.toUtc() : null,
      intervalStart: selected?.startedAt,
      intervalEnd: selected?.decision == 'open' ? null : selected?.endedAt,
    );
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reviewErrorText(problem))));
      return;
    }
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await AttendanceReviewRepository(client).requestCorrection(
        kind: kind,
        reason: reason.text,
        intervalId: kind == 'missing_in' ? null : intervalId,
        start: kind == 'missing_in' || kind == 'edit_in' ? start.toUtc() : null,
        end: kind == 'missing_in' || kind == 'missing_out' || kind == 'edit_out' ? end.toUtc() : null,
      );
      reason.clear();
      ref.invalidate(myCorrectionsProvider);
      ref.invalidate(myIntervalsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(Fa.correctionSent)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reviewErrorText(error))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class CorrectionCard extends StatelessWidget {
  const CorrectionCard({super.key, required this.request, this.onDecide, this.busy = false});

  final CorrectionRequest request;
  final Future<void> Function(bool approve, String? reason)? onDecide;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.employeeName.isEmpty ? Fa.attendance : request.employeeName, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${request.teamName} · ${correctionKindLabel(request.kind)} · ${decisionLabel(request.status)}'),
          Text(formatStamp(request.createdAt), style: TextStyle(color: palette.muted)),
          const SizedBox(height: 6),
          Text('${Fa.currentTimes}: ${formatStamp(request.currentStart)} – ${formatStamp(request.currentEnd)}'),
          Text('${Fa.proposedTimes}: ${formatStamp(request.proposedStart)} – ${formatStamp(request.proposedEnd)}'),
          Text(request.reason),
          if (request.decisionReason != null && request.decisionReason!.isNotEmpty)
            Text('${Fa.decision}: ${request.deciderName ?? ''} ${request.decisionReason}'),
          if (onDecide != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : () => _act(context, true, Fa.confirmApproveCorrection, false),
                  child: const Text(Fa.approve),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => _act(context, false, Fa.confirmRejectCorrection, true),
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
    await onDecide?.call(approve, reasonRequired ? answer : null);
  }
}
