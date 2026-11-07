import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';
import '../../core/networking/supabase_provider.dart';

class WorkspaceSession {
  const WorkspaceSession({
    required this.profileId,
    required this.firstName,
    required this.lastName,
    required this.status,
    required this.mustChangePassword,
    required this.permissions,
    this.teamName,
    this.email,
    this.workspaceId,
  });

  final String profileId;
  final String firstName;
  final String lastName;
  final String status;
  final bool mustChangePassword;
  final Set<String> permissions;
  final String? teamName;
  final String? email;
  final String? workspaceId;

  bool can(String key) => permissions.contains(key);

  factory WorkspaceSession.fromJson(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];
    return WorkspaceSession(
      profileId: json['profile_id']?.toString() ?? '',
      firstName: json['first_name']?.toString() ?? '',
      lastName: json['last_name']?.toString() ?? '',
      status: json['status']?.toString() ?? 'missing',
      mustChangePassword: json['must_change_password'] == true,
      permissions: rawPermissions is List ? rawPermissions.map((item) => item.toString()).toSet() : const {},
      teamName: json['team_name']?.toString(),
      email: json['email']?.toString(),
      workspaceId: json['workspace_id']?.toString(),
    );
  }
}

final authTickProvider = NotifierProvider<AuthTick, int>(AuthTick.new);

class AuthTick extends Notifier<int> {
  @override
  int build() {
    final client = ref.watch(supabaseClientProvider);
    if (client == null) return 0;
    final subscription = client.auth.onAuthStateChange.listen((_) => state++);
    ref.onDispose(subscription.cancel);
    return 0;
  }
}

final workspaceSessionProvider = FutureProvider<WorkspaceSession?>((ref) async {
  ref.watch(authTickProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client == null || client.auth.currentSession == null) return null;

  var json = await _sessionMap(client);
  if (json['status'] == 'missing') {
    final invitation = client.auth.currentUser?.userMetadata?['invitation_id'];
    if (invitation is String && invitation.isNotEmpty) {
      await client.rpc('accept_invitation', params: {'p_invitation': invitation});
      json = await _sessionMap(client);
    }
  }
  if (json['status'] == 'inactive') {
    await client.auth.signOut();
    return null;
  }
  if (json['status'] != 'active') return null;
  return WorkspaceSession.fromJson(json);
});

Future<Map<String, dynamic>> _sessionMap(SupabaseClient client) async {
  final raw = await client.rpc('my_session');
  if (raw is! Map) throw const AppFailure('network');
  return Map<String, dynamic>.from(raw);
}
