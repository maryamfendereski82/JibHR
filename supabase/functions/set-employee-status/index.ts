import { corsHeaders, json, userClient } from '../_shared/http.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'method' }, 405);

  const body = await request.json().catch(() => null);
  const profileId = typeof body?.profile_id === 'string' ? body.profile_id : '';
  const status = body?.status === 'inactive' ? 'inactive' : body?.status === 'active' ? 'active' : '';
  if (!profileId || !status) return json({ error: 'invalid_input' }, 400);

  const caller = userClient(request);
  const changed = await caller.rpc('set_employee_status', { p_profile: profileId, p_status: status });
  if (changed.error) return json({ error: 'forbidden' }, 403);

  if (status === 'inactive') {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY');
    if (url && key) {
      await fetch(`${url}/auth/v1/admin/users/${profileId}/logout`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, apikey: key },
      });
    }
  }

  return json({ ok: true });
});
