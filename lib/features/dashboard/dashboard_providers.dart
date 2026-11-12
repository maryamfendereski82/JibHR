import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/networking/supabase_provider.dart';
import '../reports/report_repository.dart';
import '../session/workspace_session.dart';
import '../shell/navigation.dart';
import '../work/work_repository.dart';
import 'dashboard_rules.dart';

/// The person's open tasks for Home: one read, independent of
/// `dashboard_summary`, so the agenda survives that RPC failing.
final homeTasksProvider = FutureProvider<List<TaskRow>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null || !canSeeWork(session)) return const [];
  // Filtered on the server; openTasks is only a guard that drops nothing
  // unless the server and the client rule ever disagree.
  final rows = await WorkRepository(client).assignedOpen(session.profileId, limit: homeTaskLimit);
  return openTasks(rows, limit: homeTaskLimit);
});

const homeTaskLimit = 6;

typedef PeopleQuery = ({String search, String? teamId, String sort, bool ascending, int offset});

/// One page of `dashboard_people`. Keyed by the query, so the request runs
/// once per change instead of once per rebuild.
final homePeopleProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, PeopleQuery>((ref, query) async {
  final repository = ref.watch(reportRepositoryProvider);
  if (repository == null) return const {};
  return repository.people(
    search: query.search,
    teamId: query.teamId,
    sort: query.sort,
    descending: !query.ascending,
    offset: query.offset,
  );
});
