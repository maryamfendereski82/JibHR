import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/surfaces.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../attendance/attendance_review.dart';
import '../../reports/report_repository.dart';
import '../../reports/report_rules.dart';
import '../dashboard_providers.dart';
import 'home_parts.dart';

const _peoplePage = 30;

/// People in the person's scope, from `dashboard_people` (server-side search,
/// team filter, sort and paging). Hours are the backend's monthly sums.
class PeoplePanel extends ConsumerStatefulWidget {
  const PeoplePanel({super.key, required this.canOpenPerson, required this.onOpenPerson});

  final bool canOpenPerson;
  final ValueChanged<String> onOpenPerson;

  @override
  ConsumerState<PeoplePanel> createState() => _PeoplePanelState();
}

class _PeoplePanelState extends ConsumerState<PeoplePanel> {
  final _search = TextEditingController();
  PeopleQuery _query = (search: '', teamId: null, sort: 'name', ascending: true, offset: 0);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _set(PeopleQuery next) => setState(() => _query = next);

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(homePeopleProvider(_query));
    final filters = ref.watch(reportFiltersProvider);
    final teams = filters.asData?.value == null ? const <Map<String, dynamic>>[] : asMaps(filters.asData!.value['teams']);
    return AppSurface(
      key: const Key('home-people'),
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final controls = [
            SizedBox(
              width: wide ? 260 : double.infinity,
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: Fa.searchPeople,
                  prefixIcon: Padding(padding: EdgeInsets.all(12), child: AppIconView(AppIcons.search)),
                ),
                onSubmitted: (value) => _set((search: value.trim(), teamId: _query.teamId, sort: _query.sort, ascending: _query.ascending, offset: 0)),
              ),
            ),
            if (teams.isNotEmpty)
              SizedBox(
                width: wide ? 220 : double.infinity,
                child: DropdownButtonFormField<String?>(
                  initialValue: _query.teamId,
                  icon: const AppIconView(AppIcons.expand),
                  decoration: const InputDecoration(labelText: Fa.allTeams),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Fa.allTeams)),
                    for (final team in teams)
                      DropdownMenuItem(value: team['id']?.toString(), child: Text(team['name']?.toString() ?? '')),
                  ],
                  onChanged: (value) => _set((search: _query.search, teamId: value, sort: _query.sort, ascending: _query.ascending, offset: 0)),
                ),
              ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HomeSectionHeader(title: Fa.homePeople, icon: AppIcons.people, subtitle: Fa.homeTeamScope),
              const SizedBox(height: AppSpace.l),
              Wrap(spacing: AppSpace.m, runSpacing: AppSpace.m, children: controls),
              const SizedBox(height: AppSpace.m),
              SectionStates<Map<String, dynamic>>(
                data: SectionData(value: page.asData?.value, loading: page.isLoading, error: page.error),
                onRetry: () => ref.invalidate(homePeopleProvider(_query)),
                errorText: page.error == null ? Fa.network : reportErrorText(page.error!),
                skeleton: const SkeletonRows(rows: 4, height: 40),
                builder: (data) {
                  final rows = asMaps(data['rows']);
                  final total = asInt(data['total_rows'] ?? data['total']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpace.l),
                          child: Text(Fa.empty, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                        )
                      else if (wide)
                        _table(context, rows)
                      else
                        _list(context, rows),
                      _pager(context, total),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  static const _columns = [
    ('name', Fa.employee),
    ('position', Fa.position),
    ('approved_seconds', Fa.approvedHours),
    ('pending_seconds', Fa.pendingHours),
    ('active_tasks', Fa.activeTasks),
    ('complete_tasks', Fa.completeTasks),
    ('review_tasks', Fa.reviewTasks),
    ('open_corrections', Fa.openCorrections),
  ];

  Widget _table(BuildContext context, List<Map<String, dynamic>> rows) {
    final sortIndex = _columns.indexWhere((c) => c.$1 == _query.sort);
    final numberStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: tabular);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        showCheckboxColumn: false,
        headingRowHeight: 44,
        sortColumnIndex: sortIndex < 0 ? null : sortIndex,
        sortAscending: _query.ascending,
        columns: [
          for (final column in _columns)
            DataColumn(
              label: Text(column.$2),
              numeric: column.$1 != 'name' && column.$1 != 'position',
              onSort: (_, ascending) => _set((search: _query.search, teamId: _query.teamId, sort: column.$1, ascending: ascending, offset: 0)),
            ),
        ],
        rows: [
          for (final person in rows)
            DataRow(
              onSelectChanged: widget.canOpenPerson ? (_) => widget.onOpenPerson(person['id'].toString()) : null,
              cells: [
                DataCell(Text(person['name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                DataCell(Text(person['position']?.toString() ?? '')),
                DataCell(Text(formatHours(asInt(person['approved_seconds'])), style: numberStyle)),
                DataCell(Text(formatHours(asInt(person['pending_seconds'])), style: numberStyle)),
                DataCell(Text(persianDigits(asInt(person['active_tasks'])), style: numberStyle)),
                DataCell(Text(persianDigits(asInt(person['complete_tasks'])), style: numberStyle)),
                DataCell(Text(persianDigits(asInt(person['review_tasks'])), style: numberStyle)),
                DataCell(Text(persianDigits(asInt(person['open_corrections'])), style: numberStyle)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<Map<String, dynamic>> rows) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.hairline),
          InkWell(
            onTap: widget.canOpenPerson ? () => widget.onOpenPerson(rows[i]['id'].toString()) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.m),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(rows[i]['name']?.toString() ?? '', style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    Text(rows[i]['position']?.toString() ?? '', style: text.bodySmall),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(formatHours(asInt(rows[i]['approved_seconds'])), style: text.titleSmall?.copyWith(fontFeatures: tabular)),
                  Text(Fa.approvedHours, style: text.bodySmall),
                ]),
              ]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _pager(BuildContext context, int total) {
    final pages = total == 0 ? 1 : (total / _peoplePage).ceil();
    final current = _query.offset ~/ _peoplePage + 1;
    PeopleQuery at(int offset) => (search: _query.search, teamId: _query.teamId, sort: _query.sort, ascending: _query.ascending, offset: offset);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.s),
      child: Row(
        children: [
          Text('${persianDigits(total)} ${Fa.unitPeople}', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          IconButton(
            tooltip: Fa.previousPage,
            onPressed: _query.offset < _peoplePage ? null : () => _set(at(_query.offset - _peoplePage)),
            icon: const AppIconView(AppIcons.previous),
          ),
          Text('${persianDigits(current)} / ${persianDigits(pages)}', style: const TextStyle(fontFeatures: tabular)),
          IconButton(
            tooltip: Fa.nextPage,
            onPressed: _query.offset + _peoplePage >= total ? null : () => _set(at(_query.offset + _peoplePage)),
            icon: const AppIconView(AppIcons.next),
          ),
        ],
      ),
    );
  }
}
