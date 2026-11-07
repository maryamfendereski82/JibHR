import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminClient, corsHeaders, json, sha256 } from '../_shared/http.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'method' }, 405);

  const body = await request.json().catch(() => null);
  const identifier = typeof body?.identifier === 'string' ? body.identifier.trim().toLowerCase() : '';
  const password = typeof body?.password === 'string' ? body.password : '';
  if (identifier.length < 3 || password.length < 8) return json({ error: 'invalid_credentials' }, 401);

  const admin = adminClient();
  const ip = (request.headers.get('x-forwarded-for') ?? 'local').split(',')[0].trim();
  const identifierKey = await sha256(`id:${identifier}`);
  const ipKey = await sha256(`ip:${ip}`);
  const identifierCount = await admin.rpc('record_auth_attempt', { p_key: identifierKey });
  const ipCount = await admin.rpc('record_auth_attempt', { p_key: ipKey });
  if (identifierCount.error || ipCount.error) return json({ error: 'unavailable' }, 503);
  if ((identifierCount.data ?? 0) > 8 || (ipCount.data ?? 0) > 30) {
    return json({ error: 'rate_limited' }, 429);
  }

  const column = identifier.includes('@') ? 'email' : 'username';
  const account = await admin
    .from('profile_accounts')
    .select('email, profiles!inner(status)')
    .eq(column, identifier)
    .maybeSingle();
  const embedded = account.data?.profiles as { status?: string } | { status?: string }[] | null;
  const status = Array.isArray(embedded) ? embedded[0]?.status : embedded?.status;
  if (!account.data || status !== 'active') return json({ error: 'invalid_credentials' }, 401);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')!;
  const signer = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await signer.auth.signInWithPassword({ email: account.data.email, password });
  if (signed.error || !signed.data.session) return json({ error: 'invalid_credentials' }, 401);

  return json({
    access_token: signed.data.session.access_token,
    refresh_token: signed.data.session.refresh_token,
    expires_in: signed.data.session.expires_in,
  });
});
