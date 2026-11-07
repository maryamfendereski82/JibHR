import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_review.dart';
import '../reports/report_repository.dart';
import '../reports/report_rules.dart';
import '../session/workspace_session.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(workspaceSessionProvider);
    return session.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(message: Fa.network, onRetry: () => ref.invalidate(workspaceSessionProvider)),
      data: (value) {
        if (value == null) return const LoadingView();
        final summary = ref.watch(dashboardSummaryProvider);
        final cached = ref.watch(dashboardCacheProvider);
        final live = summary.hasError ? null : summary.value;
        final data = live ?? cached;
        final stale = summary.hasError && data != null;
        if (data == null) {
          return summary.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              message: reportErrorText(error),
              onRetry: () => ref.invalidate(dashboardSummaryProvider),
            ),
            data: (_) => const LoadingView(),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(dashboardSummaryProvider),
          child: DashboardBody(
            firstName: value.firstName,
            teamName: value.teamName,
            summary: data,
            stale: stale,
            canOpenPerson: canOpenAttendance(value.permissions),
            canExport: canExportReports(value.permissions),
            pagedPeople: true,
            onRefresh: () => ref.invalidate(dashboardSummaryProvider),
          ),
        );
      },
    );
  }
}

class DashboardBody extends StatefulWidget {
  const DashboardBody({
    super.key,
    required this.firstName,
    required this.summary,
    required this.stale,
    required this.canOpenPerson,
    required     this.canExport,
    this.pagedPeople = false,
    this.teamName,
    this.onRefresh,
  });

  final String firstName;
  final String? teamName;
  final Map<String, dynamic> summary;
  final bool stale;
  final bool canOpenPerson;
  final bool canExport;
  final bool pagedPeople;
  final VoidCallback? onRefresh;

  @override
  State<DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends State<DashboardBody> {
  String _sortKey = 'name';
  bool _ascending = true;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final personal = asMap(widget.summary['personal']) ?? const {};
    final team = asMap(widget.summary['team']);
    final projects = asMap(widget.summary['projects']);
    final queues = asMap(widget.summary['queues']);
    final people = sortPeople(asMaps(team?['people']), _sortKey, _ascending);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('${Fa.greeting}، ${widget.firstName}', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(TehranTime.formatDate(DateTime.now().toUtc()), style: TextStyle(color: palette.muted)),
        if (widget.teamName != null) Text(widget.teamName!, style: TextStyle(color: palette.muted)),
        if (widget.stale) ...[
          const SizedBox(height: 12),
          Text(Fa.staleDashboard, style: TextStyle(color: palette.jade)),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _link(context, Fa.attendanceReport, '/reports/attendance'),
            _link(context, Fa.workReport, '/reports/work'),
            _link(context, Fa.leaveReport, '/reports/leave'),
            if (widget.canExport) _link(context, Fa.exportReport, '/reports/export'),
            TextButton(onPressed: widget.onRefresh, child: const Text(Fa.refresh)),
          ],
        ),
        const SizedBox(height: 16),
        _section(context, Fa.personalSummary, [
          _metric(Fa.today, personal['open'] == true ? Fa.clockedIn : Fa.clockedOut),
          _metric(Fa.incomplete, persianDigits(asInt(personal['incomplete']))),
          _metric(Fa.approved, formatHours(asInt(personal['approved_seconds']))),
          _metric(Fa.pending, formatHours(asInt(personal['pending_seconds']))),
          _metric(Fa.recorded, formatHours(asInt(personal['recorded_seconds']))),
          _metric(Fa.weekApproved, formatHours(asInt(personal['week_approved_seconds']))),
          _metric(Fa.monthApproved, formatHours(asInt(personal['month_approved_seconds']))),
          _metric(Fa.personalTaskCount, persianDigits(asInt(personal['personal_tasks']))),
          _metric(Fa.projectTasks, persianDigits(asInt(personal['project_tasks']))),
          _metric(Fa.awaitingReview, persianDigits(asInt(personal['awaiting_review']))),
          _metric(Fa.changesRequested, persianDigits(asInt(personal['needs_revision']))),
          _metric(Fa.leavePending, persianDigits(asInt(personal['leave_pending']))),
          _metric(Fa.notifications, persianDigits(asInt(personal['unread']))),
        ]),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _link(context, Fa.myTasks, '/work/mine'),
            _link(context, Fa.attendance, '/attendance'),
            _link(context, Fa.inbox, '/notifications'),
          ],
        ),
        const SizedBox(height: 12),
        _statusList(context, asMaps(personal['statuses'])),
        if (showTeam(team)) ...[
          const SizedBox(height: 16),
          _section(context, Fa.teamSummary, [
            _metric(Fa.activeEmployees, persianDigits(asInt(team!['employees']))),
            _metric(Fa.openIntervals, persianDigits(asInt(team['open_intervals']))),
            _metric(Fa.pendingReports, persianDigits(asInt(team['pending_reports']))),
            _metric(Fa.pendingCorrections, persianDigits(asInt(team['pending_corrections']))),
            _metric(Fa.leavePending, persianDigits(asInt(team['pending_leave']))),
            _metric(Fa.pendingDisputes, persianDigits(asInt(team['pending_disputes']))),
            _metric(Fa.activeTasks, persianDigits(asInt(team['active_tasks']))),
            _metric(Fa.reviewTasks, persianDigits(asInt(team['review_tasks']))),
            _metric(Fa.overdueTasks, persianDigits(asInt(team['overdue_tasks']))),
            _metric(Fa.completeTasks, persianDigits(asInt(team['complete_tasks']))),
          ]),
          const SizedBox(height: 8),
          Text(Fa.noRanking, style: TextStyle(color: palette.muted)),
          const SizedBox(height: 8),
          if (people.isNotEmpty)
            _peopleTable(context, people)
          else if (widget.pagedPeople)
            DashboardPeopleTable(canOpenPerson: widget.canOpenPerson),
        ],
        if (showProjects(projects)) ...[
          const SizedBox(height: 16),
          _section(context, Fa.projectSummary, [
            _metric(Fa.activeProjects, persianDigits(asInt(projects!['active']))),
            _metric(Fa.archivedProjects, persianDigits(asInt(projects['archived']))),
            _metric(Fa.activeTasks, persianDigits(asInt(projects['tasks']))),
            _metric(Fa.awaitingReview, persianDigits(asInt(projects['awaiting_review']))),
            _metric(Fa.overdueTasks, persianDigits(asInt(projects['overdue']))),
            _metric(Fa.completeTasks, persianDigits(asInt(projects['complete']))),
            _metric(Fa.activeSprints, persianDigits(asInt(projects['active_sprints']))),
            _metric(Fa.upcomingMilestones, persianDigits(asInt(projects['upcoming_milestones']))),
            _metric(Fa.reachedMilestones, persianDigits(asInt(projects['reached_milestones']))),
          ]),
        ],
        if (showQueues(queues)) ...[
          const SizedBox(height: 16),
          Text(Fa.pendingApprovals, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (asInt(queues!['attendance']) > 0)
                _link(context, '${Fa.approvalQueue} ${persianDigits(asInt(queues['attendance']))}', '/attendance/approvals'),
              if (asInt(queues['corrections']) > 0)
                _link(context, '${Fa.correctionQueue} ${persianDigits(asInt(queues['corrections']))}', '/attendance/corrections'),
              if (asInt(queues['leave']) > 0)
                _link(context, '${Fa.leavePending} ${persianDigits(asInt(queues['leave']))}', '/leave/queue'),
              if (asInt(queues['disputes']) > 0)
                _link(context, '${Fa.pendingDisputes} ${persianDigits(asInt(queues['disputes']))}', '/leave/absence'),
              if (asInt(queues['task_reviews']) > 0)
                _link(context, '${Fa.taskReviews} ${persianDigits(asInt(queues['task_reviews']))}', '/work'),
            ],
          ),
        ],
      ],
    );
  }

  Widget _peopleTable(BuildContext context, List<Map<String, dynamic>> people) {
    if (people.isEmpty) return const Text(Fa.empty);
    final table = DataTable(
      showCheckboxColumn: false,
      sortColumnIndex: _columnIndex(_sortKey),
      sortAscending: _ascending,
      columns: [
        _column(Fa.employee, 'name'),
        _column(Fa.position, 'position'),
        _column(Fa.approvedHours, 'approved_seconds'),
        _column(Fa.pendingHours, 'pending_seconds'),
        _column(Fa.activeTasks, 'active_tasks'),
        _column(Fa.completeTasks, 'complete_tasks'),
        _column(Fa.reviewTasks, 'review_tasks'),
        _column(Fa.openCorrections, 'open_corrections'),
      ],
      rows: [
        for (final person in people)
          DataRow(
            onSelectChanged: widget.canOpenPerson
                ? (_) => context.push('/reports/attendance?profile=${person['id']}')
                : null,
            cells: [
              DataCell(Text(person['name']?.toString() ?? '')),
              DataCell(Text(person['position']?.toString() ?? '')),
              DataCell(Text(formatHours(asInt(person['approved_seconds'])))),
              DataCell(Text(formatHours(asInt(person['pending_seconds'])))),
              DataCell(Text(persianDigits(asInt(person['active_tasks'])))),
              DataCell(Text(persianDigits(asInt(person['complete_tasks'])))),
              DataCell(Text(persianDigits(asInt(person['review_tasks'])))),
              DataCell(Text(persianDigits(asInt(person['open_corrections'])))),
            ],
          ),
      ],
    );
    return GlassCard(
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
    );
  }

  DataColumn _column(String label, String key) {
    return DataColumn(
      label: Text(label),
      onSort: (_, ascending) => setState(() {
        _sortKey = key;
        _ascending = ascending;
      }),
    );
  }
}

class DashboardPeopleTable extends ConsumerStatefulWidget {
  const DashboardPeopleTable({super.key, required this.canOpenPerson});

  final bool canOpenPerson;

  @override
  ConsumerState<DashboardPeopleTable> createState() => _DashboardPeopleTableState();
}

class _DashboardPeopleTableState extends ConsumerState<DashboardPeopleTable> {
  final _search = TextEditingController();
  String? _team;
  String _sort = 'name';
  bool _ascending = true;
  int _offset = 0;
  int _request = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(reportRepositoryProvider);
    final filters = ref.watch(reportFiltersProvider);
    if (repository == null) return const SizedBox.shrink();
    return FutureBuilder<Map<String, dynamic>>(
      key: ValueKey('$_request$_sort$_ascending$_offset$_team${_search.text}'),
      future: repository.people(
        search: _search.text.trim(),
        teamId: _team,
        sort: _sort,
        descending: !_ascending,
        offset: _offset,
      ),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Text(reportErrorText(snapshot.error!));
        if (!snapshot.hasData) return const LinearProgressIndicator();
        final rows = asMaps(snapshot.data!['rows']);
        final total = asInt(snapshot.data!['total_rows'] ?? snapshot.data!['total']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(labelText: Fa.searchPeople),
              onSubmitted: (_) => setState(() {
                _offset = 0;
                _request++;
              }),
            ),
            filters.maybeWhen(
              data: (options) => DropdownButton<String?>(
                value: _team,
                items: [
                  const DropdownMenuItem(value: null, child: Text(Fa.allTeams)),
                  for (final team in asMaps(options['teams']))
                    DropdownMenuItem(value: team['id']?.toString(), child: Text(team['name']?.toString() ?? '')),
                ],
                onChanged: (value) => setState(() {
                  _team = value;
                  _offset = 0;
                  _request++;
                }),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            if (rows.isEmpty) const Text(Fa.empty),
            if (rows.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  sortColumnIndex: _columnIndex(_sort),
                  sortAscending: _ascending,
                  columns: [
                    _serverColumn(Fa.employee, 'name'),
                    _serverColumn(Fa.position, 'position'),
                    _serverColumn(Fa.approvedHours, 'approved_seconds'),
                    _serverColumn(Fa.pendingHours, 'pending_seconds'),
                    _serverColumn(Fa.activeTasks, 'active_tasks'),
                    _serverColumn(Fa.completeTasks, 'complete_tasks'),
                    _serverColumn(Fa.reviewTasks, 'review_tasks'),
                    _serverColumn(Fa.openCorrections, 'open_corrections'),
                  ],
                  rows: [
                    for (final person in rows)
                      DataRow(
                        onSelectChanged: widget.canOpenPerson
                            ? (_) => context.push('/reports/attendance?profile=${person['id']}')
                            : null,
                        cells: [
                          DataCell(Text(person['name']?.toString() ?? '')),
                          DataCell(Text(person['position']?.toString() ?? '')),
                          DataCell(Text(formatHours(asInt(person['approved_seconds'])))),
                          DataCell(Text(formatHours(asInt(person['pending_seconds'])))),
                          DataCell(Text(persianDigits(asInt(person['active_tasks'])))),
                          DataCell(Text(persianDigits(asInt(person['complete_tasks'])))),
                          DataCell(Text(persianDigits(asInt(person['review_tasks'])))),
                          DataCell(Text(persianDigits(asInt(person['open_corrections'])))),
                        ],
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                TextButton(
                  onPressed: _offset < 30 ? null : () => setState(() => _offset -= 30),
                  child: const Text(Fa.previousPage),
                ),
                Text(persianDigits(total)),
                TextButton(
                  onPressed: _offset + 30 >= total ? null : () => setState(() => _offset += 30),
                  child: const Text(Fa.nextPage),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  DataColumn _serverColumn(String label, String key) {
    return DataColumn(
      label: Text(label),
      onSort: (_, ascending) => setState(() {
        _sort = key;
        _ascending = ascending;
        _offset = 0;
        _request++;
      }),
    );
  }
}

int? _columnIndex(String key) {
  const keys = [
    'name',
    'position',
    'approved_seconds',
    'pending_seconds',
    'active_tasks',
    'complete_tasks',
    'review_tasks',
    'open_corrections',
  ];
  final index = keys.indexOf(key);
  return index < 0 ? null : index;
}

Widget _section(BuildContext context, String title, List<Widget> metrics) {
  return GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(spacing: 16, runSpacing: 12, children: metrics),
      ],
    ),
  );
}

Widget _metric(String label, String value) {
  return SizedBox(
    width: 160,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(value),
      ],
    ),
  );
}

Widget _statusList(BuildContext context, List<Map<String, dynamic>> statuses) {
  if (statuses.isEmpty) return const SizedBox.shrink();
  return GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final status in statuses)
          Text('${status['name']}: ${persianDigits(asInt(status['total']))}'),
      ],
    ),
  );
}

Widget _link(BuildContext context, String label, String path) {
  return TextButton(onPressed: () => context.push(path), child: Text(label));
}
