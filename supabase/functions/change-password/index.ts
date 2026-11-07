import { adminClient, corsHeaders, json, userClient } from '../_shared/http.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'method' }, 405);

  const caller = userClient(request);
  const who = await caller.auth.getUser();
  const userId = who.data.user?.id;
  if (!userId) return json({ error: 'forbidden' }, 403);

  const body = await request.json().catch(() => null);
  const password = typeof body?.password === 'string' ? body.password : '';
  if (password.length < 8) return json({ error: 'weak_password' }, 400);

  const admin = adminClient();
  const updated = await admin.auth.admin.updateUserById(userId, { password });
  if (updated.error) return json({ error: 'update_failed' }, 400);
  const marked = await admin.rpc('mark_password_changed', { p_profile: userId });
  if (marked.error) return json({ error: 'update_failed' }, 400);
  return json({ ok: true });
});
