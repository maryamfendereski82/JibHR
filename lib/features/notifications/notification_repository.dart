import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/networking/supabase_provider.dart';
import '../session/workspace_session.dart';
import '../work/work_rules.dart';
import 'notification_rules.dart';

final unreadCountProvider = FutureProvider<int>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final session = await ref.watch(workspaceSessionProvider.future);
  if (client == null || session == null) return 0;
  final response = await client
      .from('notifications')
      .select('id')
      .isFilter('read_at', null)
      .range(0, 0)
      .count(CountOption.exact);
  return response.count;
});

final inboxArrivalProvider = NotifierProvider<InboxArrival, NotificationRow?>(InboxArrival.new);
final inboxReconnectProvider = NotifierProvider<InboxReconnect, int>(InboxReconnect.new);

class InboxArrival extends Notifier<NotificationRow?> {
  @override
  NotificationRow? build() => null;

  void arrive(NotificationRow row) => state = row;
}

class InboxReconnect extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Subscribes only to the signed-in recipient. RLS is the boundary; the filter is not.
/// shortcut: a later subscribed event reloads the first page, not rows already paged past
final notificationRealtimeProvider = Provider<void>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final session = ref.watch(workspaceSessionProvider).asData?.value;
  if (client == null || session == null) return;
  var live = false;
  final channel = client.channel('inbox:${session.profileId}');
  channel
      .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'notifications',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: session.profileId,
        ),
        callback: (payload) {
          final row = NotificationRow.fromMap(Map<String, dynamic>.from(payload.newRecord));
          if (row == null) return;
          ref.read(inboxArrivalProvider.notifier).arrive(row);
          ref.invalidate(unreadCountProvider);
        },
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'notifications',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: session.profileId,
        ),
        callback: (_) => ref.invalidate(unreadCountProvider),
      )
      .subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed && live) {
          ref.read(inboxReconnectProvider.notifier).bump();
          ref.invalidate(unreadCountProvider);
        }
        if (status == RealtimeSubscribeStatus.subscribed) live = true;
      });
  ref.onDispose(() => client.removeChannel(channel));
});

final notificationRepositoryProvider = Provider<NotificationRepository?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return null;
  return NotificationRepository(client);
});

class NotificationRepository {
  NotificationRepository(this._client);

  final SupabaseClient _client;

  Future<({List<NotificationRow> rows, int total})> page({
    String? category,
    bool unreadOnly = false,
    int page = 0,
  }) async {
    final bounds = pageRange(page, taskPageSize);
    var query = _client.from('notifications').select(
          'id, category, title, body, entity_type, entity_id, read_at, created_at',
        );
    if (category != null) query = query.eq('category', category);
    if (unreadOnly) query = query.isFilter('read_at', null);
    final response = await query.order('created_at', ascending: false).range(bounds.start, bounds.end).count(CountOption.exact);
    return (
      rows: [
        for (final row in response.data as List)
          if (row is Map && NotificationRow.fromMap(Map<String, dynamic>.from(row)) != null)
            NotificationRow.fromMap(Map<String, dynamic>.from(row))!,
      ],
      total: response.count,
    );
  }

  Future<void> markRead(String id) async {
    await _client.rpc('mark_notification_read', params: {'p_notification': id});
  }

  Future<void> markAll() async {
    await _client.rpc('mark_all_notifications_read');
  }

  Future<String?> openPath(NotificationRow row) async {
    final id = row.entityId;
    if (id == null || id.isEmpty) return null;
    final me = _client.auth.currentUser?.id;
    final found = await _lookup(row.entityType, id);
    return notificationPath(
      entityType: row.entityType,
      entityId: id,
      visible: found != null,
      projectId: found?.projectId,
      ownRecord: found?.profileId != null && found!.profileId == me,
    );
  }

  Future<({String? profileId, String? projectId})?> _lookup(String? entityType, String id) async {
    switch (entityType) {
      case 'task':
        final row = await _client.from('tasks').select('id').eq('id', id).maybeSingle();
        return row == null ? null : (profileId: null, projectId: null);
      case 'project':
        final row = await _client.from('projects').select('id').eq('id', id).maybeSingle();
        return row == null ? null : (profileId: null, projectId: null);
      case 'sprint':
        final row = await _client.from('sprints').select('project_id').eq('id', id).maybeSingle();
        if (row == null) return null;
        return (profileId: null, projectId: row['project_id']?.toString());
      case 'milestone':
        final row = await _client.from('milestones').select('project_id').eq('id', id).maybeSingle();
        if (row == null) return null;
        return (profileId: null, projectId: row['project_id']?.toString());
      case 'attendance_report':
        return _profile('attendance_daily_reports', id);
      case 'attendance_correction':
        return _profile('attendance_corrections', id);
      case 'leave_request':
        return _profile('leave_requests', id);
      case 'absence':
        return _profile('absence_records', id);
      case 'absence_dispute':
        return _profile('absence_disputes', id);
      default:
        return null;
    }
  }

  Future<({String? profileId, String? projectId})?> _profile(String table, String id) async {
    final row = await _client.from(table).select('profile_id').eq('id', id).maybeSingle();
    if (row == null) return null;
    return (profileId: row['profile_id']?.toString(), projectId: null);
  }
}
