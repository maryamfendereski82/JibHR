import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import '../session/workspace_session.dart';
import 'leave_pages.dart';
import 'leave_repository.dart';

final absenceAdminProvider = FutureProvider<List<AbsenceRecord>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('absence.record.team') && !session.can('absence.record.all') && !session.can('absence.view.team') && !session.can('absence.view.all')) {
    return const [];
  }
  return LeaveRepository(client).absences();
});

final myAbsenceProvider = FutureProvider<List<AbsenceRecord>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !session.can('absence.view.self')) return const [];
  return LeaveRepository(client).absences(profileId: session.profileId);
});

final staffOptionsProvider = FutureProvider<List<StaffOption>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return const [];
  if (!session.can('absence.record.team') && !session.can('absence.record.all')) return const [];
  return LeaveRepository(client).staff();
});

class AbsenceAdminPage extends ConsumerStatefulWidget {
  const AbsenceAdminPage({super.key});

  @override
  ConsumerState<AbsenceAdminPage> createState() => _AbsenceAdminPageState();
}

class _AbsenceAdminPageState extends ConsumerState<AbsenceAdminPage> {
  String? profileId;
  late JalaliStamp start = JalaliStamp.today();
  late JalaliStamp end = JalaliStamp.today();
  final reason = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    final canRecord = session?.can('absence.record.team') == true || session?.can('absence.record.all') == true;
    final staff = ref.watch(staffOptionsProvider);
    final history = ref.watch(absenceAdminProvider);
    final people = staff.asData?.value ?? const <StaffOption>[];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: Text(Fa.absenceAdmin, style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: Fa.back, onPressed: () => context.go('/leave'), icon: const Icon(Icons.arrow_forward)),
          ],
        ),
        if (canRecord)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: people.any((person) => person.id == profileId) ? profileId : null,
                  decoration: const InputDecoration(labelText: Fa.employee),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Fa.chooseEmployee)),
                    for (final person in people) DropdownMenuItem(value: person.id, child: Text(person.name)),
                  ],
                  onChanged: people.isEmpty ? null : (value) => setState(() => profileId = value),
                ),
                if (staff.hasValue && people.isEmpty) const Text(Fa.noStaff),
                const SizedBox(height: 8),
                const Text(Fa.startDate),
                JalaliStampField(value: start, withTime: false, onChanged: (value) => setState(() => start = value)),
                const SizedBox(height: 8),
                const Text(Fa.endDate),
                JalaliStampField(value: end, withTime: false, onChanged: (value) => setState(() => end = value)),
                const SizedBox(height: 8),
                TextField(
                  controller: reason,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: Fa.description),
                ),
                const SizedBox(height: 12),
                AppButton(label: Fa.submitRequest, busy: busy, onPressed: _record),
              ],
            ),
          ),
        const SizedBox(height: 16),
        history.when(
          skipLoadingOnReload: true,
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => ErrorView(message: leaveErrorText(error), onRetry: () => ref.invalidate(absenceAdminProvider)),
          data: (rows) => Column(
            children: [
              if (rows.isEmpty) const EmptyView(),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AbsenceCard(record: row, busy: busy, onDecide: _decide),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _record() async {
    final client = ref.read(supabaseClientProvider);
    final startDay = DateTime.parse(start.isoDay);
    final endDay = DateTime.parse(end.isoDay);
    if (profileId == null) {
      _toast(Fa.chooseEmployee);
      return;
    }
    if (reason.text.trim().isEmpty) {
      _toast(Fa.reasonRequired);
      return;
    }
    if (endDay.isBefore(startDay)) {
      _toast(Fa.invalidRange);
      return;
    }
    if (client == null || busy) return;
    setState(() => busy = true);
    try {
      await LeaveRepository(client).recordAbsence(
        profileId: profileId!,
        startDate: start.isoDay,
        endDate: end.isoDay,
        reason: reason.text,
      );
      reason.clear();
      ref.invalidate(absenceAdminProvider);
      ref.invalidate(myAbsenceProvider);
      _toast(Fa.absenceSent);
    } catch (error) {
      _toast(leaveErrorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _decide(String id, bool accept, String? decisionReason) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || busy) return;
    setState(() => busy = true);
    Object? failure;
    try {
      await LeaveRepository(client).decideDispute(id, accept: accept, reason: decisionReason);
    } catch (error) {
      failure = error;
    } finally {
      ref.invalidate(absenceAdminProvider);
      ref.invalidate(myAbsenceProvider);
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.saved : leaveErrorText(failure))));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class MyAbsencePage extends ConsumerStatefulWidget {
  const MyAbsencePage({super.key});

  @override
  ConsumerState<MyAbsencePage> createState() => _MyAbsencePageState();
}

class _MyAbsencePageState extends ConsumerState<MyAbsencePage> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(myAbsenceProvider);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: Text(Fa.myAbsence, style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: Fa.back, onPressed: () => context.go('/leave'), icon: const Icon(Icons.arrow_forward)),
          ],
        ),
        history.when(
          skipLoadingOnReload: true,
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(message: leaveErrorText(error), onRetry: () => ref.invalidate(myAbsenceProvider)),
          data: (rows) => Column(
            children: [
              if (rows.isEmpty) const EmptyView(),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AbsenceCard(record: row, busy: busy, onDispute: _dispute),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _dispute(String absenceId) async {
    final client = ref.read(supabaseClientProvider);
    final explanation = await askDecision(context, title: Fa.requestReview, reasonRequired: true);
    if (explanation == null || explanation.trim().isEmpty || client == null || busy) return;
    setState(() => busy = true);
    Object? failure;
    try {
      await LeaveRepository(client).dispute(absenceId, explanation);
    } catch (error) {
      failure = error;
    } finally {
      ref.invalidate(myAbsenceProvider);
      ref.invalidate(absenceAdminProvider);
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure == null ? Fa.disputeSent : leaveErrorText(failure))));
  }
}

class AbsenceCard extends StatelessWidget {
  const AbsenceCard({super.key, required this.record, this.onDecide, this.onDispute, this.busy = false});

  final AbsenceRecord record;
  final Future<void> Function(String id, bool accept, String? reason)? onDecide;
  final Future<void> Function(String absenceId)? onDispute;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final pending = record.disputes.where((item) => item.status == 'pending').toList();
    final latest = pending.isEmpty ? null : pending.last;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.employeeName, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(record.teamName),
          Text('${_day(record.startDate)} تا ${_day(record.endDate)}'),
          Text('${Fa.recordedBy}: ${record.recordedBy}'),
          Text(formatStamp(record.createdAt), style: TextStyle(color: palette.muted)),
          Text(record.reason),
          for (final dispute in record.disputes) ...[
            const SizedBox(height: 8),
            Text('${Fa.employeeResponse}: ${dispute.explanation}'),
            Text(disputeStatusLabel(dispute.status)),
            if (dispute.decisionReason != null && dispute.decisionReason!.isNotEmpty)
              Text('${Fa.decision}: ${dispute.deciderName ?? ''} ${dispute.decisionReason}'),
          ],
          if (onDecide != null && latest != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : () => _act(context, latest.id, true, Fa.confirmAcceptDispute, false),
                  child: const Text(Fa.approve),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => _act(context, latest.id, false, Fa.confirmRejectDispute, true),
                  child: const Text(Fa.reject),
                ),
              ],
            ),
          ],
          if (onDispute != null && pending.isEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: busy ? null : () => onDispute!(record.id),
              child: const Text(Fa.requestReview),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _act(BuildContext context, String id, bool accept, String title, bool reasonRequired) async {
    final answer = await askDecision(context, title: title, reasonRequired: reasonRequired);
    if (answer == null) return;
    await onDecide?.call(id, accept, reasonRequired ? answer : null);
  }
}

String disputeStatusLabel(String status) => switch (status) {
      'accepted' => Fa.accepted,
      'rejected' => Fa.rejected,
      _ => Fa.pending,
    };

String _day(DateTime value) => TehranTime.formatDate(DateTime.utc(value.year, value.month, value.day, 12));
