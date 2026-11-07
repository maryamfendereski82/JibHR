import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';
import '../../core/networking/supabase_provider.dart';
import '../attendance/attendance_review.dart';
import 'report_rules.dart';

Object reportFailure(Object error) {
  if (error is AppFailure) return error;
  final text = error.toString();
  if (text.contains('offline')) return const AppFailure('offline');
  if (text.contains('forbidden')) return const AppFailure('forbidden');
  if (text.contains('invalid_range') || text.contains('invalid_grain') || text.contains('invalid_kind')) {
    return const AppFailure('invalid_range');
  }
  return error;
}

String reportErrorText(Object error) {
  final failure = reportFailure(error);
  if (failure is AppFailure && failure.code == 'offline') return 'این کار آفلاین انجام نمی‌شود.';
  if (failure is AppFailure && failure.code == 'cancelled') return 'ساخت گزارش لغو شد.';
  if (failure is AppFailure && failure.code == 'export_changed') return 'داده‌ها وسط ساخت عوض شد. دوباره بسازید.';
  if (failure is AppFailure && failure.code == 'forbidden') return 'مجوز این کار را ندارید.';
  if (failure is AppFailure && failure.code == 'invalid_range') return 'بازه زمانی درست نیست.';
  return 'ارتباط با سرور برقرار نشد.';
}

final dashboardCacheProvider = NotifierProvider<DashboardCache, Map<String, dynamic>?>(DashboardCache.new);

class DashboardCache extends Notifier<Map<String, dynamic>?> {
  @override
  Map<String, dynamic>? build() => null;

  void keep(Map<String, dynamic> value) => state = value;
}

final dashboardSummaryProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) throw const AppFailure('network');
  final map = await _rpcMap(client, 'dashboard_summary');
  ref.read(dashboardCacheProvider.notifier).keep(map);
  return map;
});

final reportFiltersProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) throw const AppFailure('network');
  return _rpcMap(client, 'report_filters');
});

class ReportRepository {
  ReportRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> attendance({
    required String from,
    required String to,
    String? profileId,
    String? teamId,
    String grain = 'day',
    int offset = 0,
    int limit = 30,
  }) {
    return _rpcMap(_client, 'attendance_analytics', {
      'p_from': from,
      'p_to': to,
      'p_profile': profileId,
      'p_team': teamId,
      'p_grain': grain,
      'p_offset': offset,
      'p_limit': limit,
    });
  }

  Future<Map<String, dynamic>> people({
    String search = '',
    String? teamId,
    String sort = 'name',
    bool descending = false,
    int offset = 0,
    int limit = 30,
  }) {
    return _rpcMap(_client, 'dashboard_people', {
      'p_search': search,
      'p_team': teamId,
      'p_sort': sort,
      'p_desc': descending,
      'p_offset': offset,
      'p_limit': limit,
    });
  }

  Future<Map<String, dynamic>> work({String? projectId}) {
    return _rpcMap(_client, 'work_analytics', {'p_project': projectId});
  }

  Future<Map<String, dynamic>> leaveAbsence({
    required String kind,
    required String from,
    required String to,
    String? profileId,
    String? teamId,
    String? status,
    int offset = 0,
    int limit = 30,
  }) {
    return _rpcMap(_client, 'leave_absence_report', {
      'p_kind': kind,
      'p_from': from,
      'p_to': to,
      'p_profile': profileId,
      'p_team': teamId,
      'p_status': status,
      'p_offset': offset,
      'p_limit': limit,
    });
  }

  Future<Map<String, dynamic>> exportPage({
    required String kind,
    required Map<String, dynamic> filters,
    required String format,
    required int offset,
    bool audit = false,
  }) {
    return _rpcMap(_client, 'report_export', {
      'p_kind': kind,
      'p_filters': filters,
      'p_format': format,
      'p_offset': offset,
      'p_limit': exportPageSize,
      'p_audit': audit,
    });
  }
}

final reportRepositoryProvider = Provider<ReportRepository?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return null;
  return ReportRepository(client);
});

/// Pages of 200. The file still holds the whole export once it is built.
Future<List<Map<String, dynamic>>> collectExport(
  ReportRepository repository, {
  required String kind,
  required Map<String, dynamic> filters,
  required String format,
  void Function(int loaded, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final rows = <Map<String, dynamic>>[];
  var offset = 0;
  var total = 0;
  int? expected;
  do {
    final page = await repository.exportPage(
      kind: kind,
      filters: filters,
      format: format,
      offset: offset,
      audit: offset == 0,
    );
    if (cancelled?.call() == true) throw const AppFailure('cancelled');
    total = asInt(page['total_rows']);
    expected ??= total;
    if (total != expected) throw const AppFailure('export_changed');
    final chunk = asMaps(page['rows']);
    if (chunk.isEmpty && rows.length != expected) throw const AppFailure('export_changed');
    rows.addAll(chunk);
    onProgress?.call(rows.length, expected);
    if (chunk.isEmpty || rows.length >= expected) break;
    offset += chunk.length;
  } while (offset < expected);
  if (rows.length != expected) throw const AppFailure('export_changed');
  return rows;
}

Future<Map<String, dynamic>> _rpcMap(SupabaseClient client, String name, [Map<String, dynamic>? params]) async {
  try {
    final raw = await client.rpc(name, params: params);
    final map = asMap(raw);
    if (map == null) throw const AppFailure('network');
    return map;
  } catch (error) {
    throw reportFailure(error);
  }
}
