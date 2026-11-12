import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/offline/offline_cache.dart';
import '../../core/offline/offline_policy.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../work/workflow_presentation.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../attendance/jalali_fields.dart';
import 'pdf_report.dart';
import 'report_repository.dart';
import 'report_rules.dart';
import 'xlsx_report.dart';

class AttendanceAnalyticsPage extends ConsumerStatefulWidget {
  const AttendanceAnalyticsPage({super.key, this.profileId});

  final String? profileId;

  @override
  ConsumerState<AttendanceAnalyticsPage> createState() => _AttendanceAnalyticsPageState();
}

class _AttendanceAnalyticsPageState extends ConsumerState<AttendanceAnalyticsPage> {
  late JalaliStamp _from;
  late JalaliStamp _to;
  String _grain = 'day';
  String? _profileId;
  String? _teamId;
  int _offset = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    final today = JalaliStamp.today();
    _to = today;
    _from = today.copyWith(day: 1);
    _profileId = widget.profileId;
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(reportFiltersProvider);
    final repository = ref.watch(reportRepositoryProvider);
    return _screen(context, Fa.attendanceReport, filters.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(message: reportErrorText(error), onRetry: () => ref.invalidate(reportFiltersProvider)),
        data: (options) {
          if (repository == null) return const ErrorView(message: Fa.network);
          return FutureBuilder<Map<String, dynamic>>(
            key: ValueKey(_request),
            future: repository.attendance(
              from: _from.isoDay,
              to: _to.isoDay,
              profileId: _profileId,
              teamId: _teamId,
              grain: _grain,
              offset: _offset,
            ),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorView(message: reportErrorText(snapshot.error!), onRetry: () => setState(() => _request++));
              }
              if (!snapshot.hasData) return const LoadingView();
              final payload = snapshot.data!;
              final totals = asMap(payload['totals']) ?? const {};
              final rows = asMaps(payload['rows']);
              final total = asInt(payload['total_rows']);
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _rangeFields(
                    from: _from,
                    to: _to,
                    onFrom: (value) => setState(() => _from = value),
                    onTo: (value) => setState(() => _to = value),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _choice(_grain, const {'day': Fa.daily, 'week': Fa.weekly, 'jalali_month': Fa.monthly}, (value) {
                        setState(() => _grain = value);
                      }),
                      _named(options['people'], _profileId, Fa.allPeople, (value) => setState(() => _profileId = value)),
                      _named(options['teams'], _teamId, Fa.allTeams, (value) => setState(() => _teamId = value)),
                      FilledButton(
                        onPressed: () => setState(() {
                          _offset = 0;
                          _request++;
                        }),
                        child: const Text(Fa.applyFilters),
                      ),
                      TextButton(onPressed: () => context.go('/attendance'), child: const Text(Fa.attendance)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${Fa.approved}: ${formatHours(asInt(totals['approved_seconds']))}'),
                        Text('${Fa.pending}: ${formatHours(asInt(totals['pending_seconds']))}'),
                        Text('${Fa.recorded}: ${formatHours(asInt(totals['recorded_seconds']))}'),
                        Text('${Fa.rejected}: ${formatHours(asInt(totals['rejected_seconds']))}'),
                        Text('${Fa.intervalCount}: ${persianDigits(asInt(totals['intervals']))}'),
                        Text('${Fa.pendingReports}: ${persianDigits(asInt(totals['pending_reports']))}'),
                        Text('${Fa.incomplete}: ${persianDigits(asInt(totals['incomplete']))}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (rows.isEmpty) const Text(Fa.empty),
                  for (final row in rows) _attendanceRow(context, row),
                  _pager(total, _offset, (next) => setState(() {
                    _offset = next;
                    _request++;
                  })),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class WorkAnalyticsPage extends ConsumerStatefulWidget {
  const WorkAnalyticsPage({super.key});

  @override
  ConsumerState<WorkAnalyticsPage> createState() => _WorkAnalyticsPageState();
}

class _WorkAnalyticsPageState extends ConsumerState<WorkAnalyticsPage> {
  String? _projectId;
  int _request = 0;

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(reportFiltersProvider);
    final repository = ref.watch(reportRepositoryProvider);
    return _screen(context, Fa.workReport, filters.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(message: reportErrorText(error), onRetry: () => ref.invalidate(reportFiltersProvider)),
        data: (options) {
          if (repository == null) return const ErrorView(message: Fa.network);
          return FutureBuilder<Map<String, dynamic>>(
            key: ValueKey('$_request$_projectId'),
            future: repository.work(projectId: _projectId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorView(message: reportErrorText(snapshot.error!), onRetry: () => setState(() => _request++));
              }
              if (!snapshot.hasData) return const LoadingView();
              final data = snapshot.data!;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _named(options['projects'], _projectId, Fa.allProjects, (value) => setState(() => _projectId = value)),
                  const SizedBox(height: 12),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${Fa.completeTasks}: ${persianDigits(asInt(data['complete']))}'),
                        Text('${Fa.remaining}: ${persianDigits(asInt(data['remaining']))}'),
                        Text('${Fa.awaitingReview}: ${persianDigits(asInt(data['awaiting']))}'),
                        Text('${Fa.changesRequested}: ${persianDigits(asInt(data['revision']))}'),
                        Text('${Fa.blocked}: ${persianDigits(asInt(data['blocked']))}'),
                        Text('${Fa.overdueTasks}: ${persianDigits(asInt(data['overdue']))}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(Fa.byStatus, style: Theme.of(context).textTheme.titleMedium),
                  // The four final statuses, summed over the stored ones.
                  for (final group in taskGroups)
                    if (asMaps(data['by_status']).any((row) => groupOfCategory(row['category']?.toString() ?? '') == group))
                      Text(
                        '${groupLabel(group)}: ${persianDigits(asMaps(data['by_status']).where((row) => groupOfCategory(row['category']?.toString() ?? '') == group).fold<int>(0, (sum, row) => sum + asInt(row['total'])))}',
                      ),
                  const SizedBox(height: 12),
                  Text(Fa.byPriority, style: Theme.of(context).textTheme.titleMedium),
                  for (final row in asMaps(data['by_priority']))
                    Text('${row['priority']}: ${persianDigits(asInt(row['total']))}'),
                  const SizedBox(height: 12),
                  Text(Fa.byAssignee, style: Theme.of(context).textTheme.titleMedium),
                  for (final row in asMaps(data['by_assignee']))
                    Text('${row['name']}: ${persianDigits(asInt(row['total']))}'),
                  const SizedBox(height: 12),
                  Text(Fa.sprintProgress, style: Theme.of(context).textTheme.titleMedium),
                  for (final row in asMaps(data['sprints'])) _sprintRow(context, row),
                  const SizedBox(height: 12),
                  Text(Fa.milestoneSection, style: Theme.of(context).textTheme.titleMedium),
                  for (final row in asMaps(data['milestones'])) _milestoneRow(context, row),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class LeaveAnalyticsPage extends ConsumerStatefulWidget {
  const LeaveAnalyticsPage({super.key});

  @override
  ConsumerState<LeaveAnalyticsPage> createState() => _LeaveAnalyticsPageState();
}

class _LeaveAnalyticsPageState extends ConsumerState<LeaveAnalyticsPage> {
  late JalaliStamp _from;
  late JalaliStamp _to;
  String _kind = 'leave';
  String? _profileId;
  String? _teamId;
  String? _status;
  int _offset = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    final today = JalaliStamp.today();
    _to = today;
    _from = today.copyWith(day: 1);
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(reportFiltersProvider);
    final repository = ref.watch(reportRepositoryProvider);
    return _screen(context, Fa.leaveReport, filters.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(message: reportErrorText(error), onRetry: () => ref.invalidate(reportFiltersProvider)),
        data: (options) {
          if (repository == null) return const ErrorView(message: Fa.network);
          return FutureBuilder<Map<String, dynamic>>(
            key: ValueKey(_request),
            future: repository.leaveAbsence(
              kind: _kind,
              from: _from.isoDay,
              to: _to.isoDay,
              profileId: _profileId,
              teamId: _teamId,
              status: _status,
              offset: _offset,
            ),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorView(message: reportErrorText(snapshot.error!), onRetry: () => setState(() => _request++));
              }
              if (!snapshot.hasData) return const LoadingView();
              final payload = snapshot.data!;
              final counts = asMap(payload['counts']) ?? const {};
              final rows = asMaps(payload['rows']);
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _rangeFields(from: _from, to: _to, onFrom: (value) => setState(() => _from = value), onTo: (value) => setState(() => _to = value)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _choice(_kind, const {'leave': Fa.categoryLeave, 'absence': Fa.categoryAbsence}, (value) {
                        setState(() {
                          _kind = value;
                          _offset = 0;
                          _request++;
                        });
                      }),
                      _named(options['people'], _profileId, Fa.allPeople, (value) => setState(() => _profileId = value)),
                      _named(options['teams'], _teamId, Fa.allTeams, (value) => setState(() => _teamId = value)),
                      if (_kind == 'leave')
                        _choice(_status ?? '', const {
                          '': Fa.anyStatus,
                          'pending': Fa.pending,
                          'approved': Fa.approved,
                          'rejected': Fa.rejected,
                        }, (value) => setState(() => _status = value.isEmpty ? null : value)),
                      FilledButton(
                        onPressed: () => setState(() {
                          _offset = 0;
                          _request++;
                        }),
                        child: const Text(Fa.applyFilters),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_kind == 'leave')
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${Fa.pending}: ${persianDigits(asInt(counts['pending']))}'),
                          Text('${Fa.approved}: ${persianDigits(asInt(counts['approved']))}'),
                          Text('${Fa.rejected}: ${persianDigits(asInt(counts['rejected']))}'),
                          Text('${Fa.dailyLeave}: ${persianDigits(asInt(counts['daily']))}'),
                          Text('${Fa.multiDayLeave}: ${persianDigits(asInt(counts['multi_day']))}'),
                          Text('${Fa.hourlyLeave}: ${persianDigits(asInt(counts['hourly']))}'),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (rows.isEmpty) const Text(Fa.empty),
                  for (final row in rows) _kind == 'leave' ? _leaveRow(row) : _absenceRow(row),
                  _pager(asInt(payload['total_rows']), _offset, (next) => setState(() {
                    _offset = next;
                    _request++;
                  })),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  ReportPreset _preset = reportPresets.first;
  late JalaliStamp _from;
  late JalaliStamp _to;
  String? _profileId;
  String? _teamId;
  String? _projectId;
  String? _status;
  String? _priority;
  List<Map<String, dynamic>> _preview = const [];
  int _total = 0;
  String? _progress;
  Uint8List? _excel;
  Uint8List? _pdf;
  bool _busy = false;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    final today = JalaliStamp.today();
    _to = today;
    _from = today.copyWith(day: 1);
  }

  Map<String, dynamic> get _filters => {
        'profile_id': _profileId ?? '',
        'team_id': _teamId ?? '',
        'project_id': _projectId ?? '',
        'from': _from.isoDay,
        'to': _to.isoDay,
        'status': _status ?? '',
        'priority': _priority ?? '',
        'grain': _preset.grain,
      };

  List<String> get _filterLines => [
        _preset.label,
        '${Fa.fromDate} ${_from.isoDay}',
        '${Fa.toDate} ${_to.isoDay}',
        ?_profileId,
        ?_teamId,
        ?_projectId,
        ?_status,
      ];

  Future<void> _loadPreview() async {
    final repository = ref.read(reportRepositoryProvider);
    if (repository == null) return;
    setState(() => _busy = true);
    try {
      final page = await repository.exportPage(kind: _preset.kind, filters: _filters, format: 'preview', offset: 0);
      if (!mounted) return;
      setState(() {
        _preview = asMaps(page['rows']);
        _total = asInt(page['total_rows']);
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _tell(reportErrorText(error));
    }
  }

  Future<void> _excelFile() => _build('excel');

  Future<void> _pdfFile() => _build('pdf');

  Future<void> _build(String format) async {
    final repository = ref.read(reportRepositoryProvider);
    if (repository == null) return;
    setState(() {
      _busy = true;
      _cancel = false;
      _progress = Fa.exportProgress;
    });
    try {
      final rows = await collectExport(
        repository,
        kind: _preset.kind,
        filters: _filters,
        format: format,
        cancelled: () => _cancel,
        onProgress: (loaded, total) {
          if (mounted) setState(() => _progress = '${Fa.exportProgress}: ${persianDigits(loaded)} / ${persianDigits(total)}');
        },
      );
      final stamp = '${TehranTime.formatDate(DateTime.now().toUtc())} ${TehranTime.formatTime(DateTime.now().toUtc())}';
      final Uint8List bytes;
      if (format == 'excel') {
        bytes = buildXlsx(title: _preset.label, stamp: stamp, filterLines: _filterLines, kind: _preset.kind, rows: rows);
      } else {
        bytes = await buildReportPdf(title: _preset.label, stamp: stamp, filterLines: _filterLines, kind: _preset.kind, rows: rows);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _total = rows.length;
        if (format == 'excel') {
          _excel = bytes;
        } else {
          _pdf = bytes;
        }
      });
      _tell(Fa.exportReady);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      _tell(reportErrorText(error));
    }
  }

  Future<void> _share(Uint8List bytes, String name, String mime) async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: name, mimeType: mime)]));
    } catch (_) {
      _tell(Fa.exportFallback);
    }
  }

  Future<void> _print(Uint8List bytes) async {
    try {
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (_) {
      _tell(Fa.exportFallback);
      await _share(bytes, 'jibhr-report.pdf', 'application/pdf');
    }
  }

  void _tell(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(reportFiltersProvider);
    return _screen(context, Fa.exportReport, filters.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(message: reportErrorText(error), onRetry: () => ref.invalidate(reportFiltersProvider)),
        data: (options) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(_preset.id),
              initialValue: _preset.id,
              decoration: const InputDecoration(labelText: Fa.reportType),
              items: [for (final preset in reportPresets) DropdownMenuItem(value: preset.id, child: Text(preset.label))],
              onChanged: _busy
                  ? null
                  : (value) {
                      final next = reportPresets.firstWhere((preset) => preset.id == value);
                      setState(() {
                        _preset = next;
                        _preview = const [];
                        _excel = null;
                        _pdf = null;
                      });
                    },
            ),
            const SizedBox(height: 8),
            _rangeFields(from: _from, to: _to, onFrom: (value) => setState(() => _from = value), onTo: (value) => setState(() => _to = value)),
            const SizedBox(height: 8),
            if (_preset.person) _named(options['people'], _profileId, Fa.allPeople, (value) => setState(() => _profileId = value)),
            if (_preset.team) _named(options['teams'], _teamId, Fa.allTeams, (value) => setState(() => _teamId = value)),
            if (_preset.project) _named(options['projects'], _projectId, Fa.allProjects, (value) => setState(() => _projectId = value)),
            if (_preset.status)
              _choice(_status ?? '', const {'': Fa.anyStatus, 'pending': Fa.pending, 'approved': Fa.approved, 'rejected': Fa.rejected}, (value) {
                setState(() => _status = value.isEmpty ? null : value);
              }),
            if (_preset.priority)
              _choice(_priority ?? '', const {'': Fa.anyStatus, 'low': 'کم', 'medium': 'معمولی', 'high': 'زیاد', 'urgent': 'فوری'}, (value) {
                setState(() => _priority = value.isEmpty ? null : value);
              }),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(onPressed: _busy ? null : _loadPreview, child: const Text(Fa.preview)),
                FilledButton(onPressed: _busy || _writesLocked(ref) ? null : _excelFile, child: const Text(Fa.makeExcel)),
                FilledButton(onPressed: _busy || _writesLocked(ref) ? null : _pdfFile, child: const Text(Fa.makePdf)),
                if (_busy) TextButton(onPressed: () => setState(() => _cancel = true), child: const Text(Fa.cancel)),
                if (_excel != null)
                  TextButton(
                    onPressed: () => _share(_excel!, 'jibhr.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
                    child: const Text(Fa.shareFile),
                  ),
                if (_pdf != null) ...[
                  TextButton(onPressed: () => _share(_pdf!, 'jibhr.pdf', 'application/pdf'), child: const Text(Fa.shareFile)),
                  TextButton(onPressed: () => _print(_pdf!), child: const Text(Fa.printFile)),
                ],
              ],
            ),
            if (_progress != null) ...[const SizedBox(height: 12), Text(_progress!)],
            if (_preview.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${Fa.rows}: ${persianDigits(_preview.length)} / ${persianDigits(_total)}'),
              for (final row in _preview.take(8))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(exportCells(_preset.kind, row).take(4).join(' · ')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _writesLocked(WidgetRef ref) {
  ref.watch(connectionTickProvider);
  final hub = ref.watch(connectionHubProvider);
  return hub.offline || hub.locked;
}

Widget _screen(BuildContext context, String title, Widget body) {
  return Column(
    children: [
      Row(
        children: [
          const BackButton(),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        ],
      ),
      Expanded(child: body),
    ],
  );
}

Widget _attendanceRow(BuildContext context, Map<String, dynamic> row) {
  final palette = paletteOf(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row['name']?.toString() ?? ''),
          Text(persianDay(row['period_start']?.toString() ?? ''), style: TextStyle(color: palette.muted)),
          Text('${Fa.approved}: ${formatHours(asInt(row['approved_seconds']))}'),
          Text('${Fa.pending}: ${formatHours(asInt(row['pending_seconds']))}'),
          Text('${Fa.rejected}: ${formatHours(asInt(row['rejected_seconds']))}'),
          Text('${Fa.reportStatus}: ${periodStatusLabel(row['report_status']?.toString() ?? '')}'),
        ],
      ),
    ),
  );
}

Widget _sprintRow(BuildContext context, Map<String, dynamic> row) {
  return ListTile(
    title: Text(row['name']?.toString() ?? ''),
    subtitle: Text('${row['start_date'] ?? ''} – ${row['end_date'] ?? ''} · ${persianDigits(asInt(row['percent']))}٪'),
    onTap: () {
      final project = row['project_id']?.toString();
      final id = row['id']?.toString();
      if (project != null && id != null) context.push('/work/p/$project/sprint/$id');
    },
  );
}

Widget _milestoneRow(BuildContext context, Map<String, dynamic> row) {
  return ListTile(
    title: Text(row['title']?.toString() ?? ''),
    subtitle: Text('${row['target_date'] ?? ''} · ${row['status'] ?? ''} · ${persianDigits(asInt(row['percent']))}٪'),
    onTap: () {
      final project = row['project_id']?.toString();
      final id = row['id']?.toString();
      if (project != null && id != null) context.push('/work/p/$project/milestone/$id');
    },
  );
}

Widget _leaveRow(Map<String, dynamic> row) {
  return ListTile(
    title: Text(row['name']?.toString() ?? ''),
    subtitle: Text('${row['kind'] ?? ''} · ${row['start_date'] ?? row['hours_date'] ?? ''} · ${row['status'] ?? ''}'),
  );
}

Widget _absenceRow(Map<String, dynamic> row) {
  return ListTile(
    title: Text(row['name']?.toString() ?? ''),
    subtitle: Text('${row['start_date'] ?? ''} – ${row['end_date'] ?? ''} · ${row['reason'] ?? ''} · ${row['dispute_status'] ?? ''}'),
  );
}

Widget _rangeFields({
  required JalaliStamp from,
  required JalaliStamp to,
  required ValueChanged<JalaliStamp> onFrom,
  required ValueChanged<JalaliStamp> onTo,
}) {
  return Wrap(
    spacing: 12,
    runSpacing: 8,
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(Fa.fromDate),
          JalaliStampField(value: from, withTime: false, onChanged: onFrom),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(Fa.toDate),
          JalaliStampField(value: to, withTime: false, onChanged: onTo),
        ],
      ),
    ],
  );
}

Widget _choice(String value, Map<String, String> options, ValueChanged<String> onChanged) {
  return DropdownButton<String>(
    value: options.containsKey(value) ? value : options.keys.first,
    items: [for (final entry in options.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}

Widget _named(Object? raw, String? selected, String allLabel, ValueChanged<String?> onChanged) {
  final rows = asMaps(raw);
  return DropdownButton<String?>(
    value: selected,
    items: [
      DropdownMenuItem(value: null, child: Text(allLabel)),
      for (final row in rows) DropdownMenuItem(value: row['id']?.toString(), child: Text(row['name']?.toString() ?? '')),
    ],
    onChanged: onChanged,
  );
}

Widget _pager(int total, int offset, ValueChanged<int> onPage) {
  return Row(
    children: [
      TextButton(onPressed: offset <= 0 ? null : () => onPage(offset - 30), child: const Text(Fa.previousPage)),
      Text('${persianDigits(offset + 1)} / ${persianDigits(total)}'),
      TextButton(onPressed: offset + 30 >= total ? null : () => onPage(offset + 30), child: const Text(Fa.nextPage)),
    ],
  );
}
