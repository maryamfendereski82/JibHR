import { adminClient, corsHeaders, json, temporaryPassword, userClient } from '../_shared/http.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'method' }, 405);

  const caller = userClient(request);
  const permission = await caller.rpc('assert_permission', { p_key: 'employees.create' });
  if (permission.error) return json({ error: 'forbidden' }, 403);

  const body = await request.json().catch(() => null);
  const email = String(body?.email ?? '').trim().toLowerCase();
  const username = String(body?.username ?? '').trim().toLowerCase();
  const firstName = String(body?.first_name ?? '').trim();
  const lastName = String(body?.last_name ?? '').trim();
  const teamId = typeof body?.team_id === 'string' ? body.team_id : '';
  const positionId = typeof body?.position_id === 'string' ? body.position_id : null;
  const roleKeys = Array.isArray(body?.role_keys) ? body.role_keys.map(String) : ['employee'];
  if (!email || !username || !firstName || !lastName || !teamId) return json({ error: 'invalid_input' }, 400);
  if (roleKeys.includes('super_admin')) {
    const allowed = await caller.rpc('assert_permission', { p_key: 'roles.manage' });
    if (allowed.error) return json({ error: 'forbidden' }, 403);
  }

  const who = await caller.auth.getUser();
  const callerId = who.data.user?.id;
  if (!callerId) return json({ error: 'forbidden' }, 403);
  const admin = adminClient();
  const callerProfile = await admin.from('profiles').select('workspace_id').eq('id', callerId).single();
  const workspaceId = callerProfile.data?.workspace_id as string | undefined;
  if (!workspaceId) return json({ error: 'forbidden' }, 403);

  const password = temporaryPassword();
  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    app_metadata: { provisioned_by: 'admin' },
    user_metadata: { first_name: firstName, last_name: lastName },
  });
  if (created.error || !created.data.user) return json({ error: 'create_failed' }, 400);
  const userId = created.data.user.id;

  const provisioned = await admin.rpc('provision_employee', {
    p_profile: userId,
    p_workspace: workspaceId,
    p_first: firstName,
    p_last: lastName,
    p_username: username,
    p_email: email,
    p_position: positionId,
    p_team: teamId,
    p_role_keys: roleKeys,
    p_granted_by: callerId,
    p_must_change_password: true,
  });
  if (provisioned.error) {
    await admin.auth.admin.deleteUser(userId);
    return json({ error: 'create_failed' }, 400);
  }

  return json({ user_id: userId, temporary_password: password });
});
