import { adminClient, corsHeaders, json, userClient } from '../_shared/http.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'method' }, 405);

  const caller = userClient(request);
  const body = await request.json().catch(() => null);
  const created = await caller.rpc('create_invitation', {
    p_email: String(body?.email ?? ''),
    p_first_name: String(body?.first_name ?? ''),
    p_last_name: String(body?.last_name ?? ''),
    p_username: String(body?.username ?? ''),
    p_position: body?.position_id ?? null,
    p_team: body?.team_id ?? null,
    p_role_keys: Array.isArray(body?.role_keys) ? body.role_keys : ['employee'],
  });
  if (created.error || !created.data) return json({ error: 'forbidden' }, 403);

  const site = Deno.env.get('SITE_URL') ?? '';
  const admin = adminClient();
  const invited = await admin.auth.admin.inviteUserByEmail(String(body.email).trim().toLowerCase(), {
    data: { invitation_id: created.data },
    redirectTo: site ? `${site}/login` : undefined,
  });
  if (invited.error) return json({ error: 'invite_failed', invitation_id: created.data }, 400);
  return json({ invitation_id: created.data });
});
