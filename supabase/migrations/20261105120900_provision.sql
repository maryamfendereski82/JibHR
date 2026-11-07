-- One transaction for the rows that follow auth.admin.createUser.
-- The edge function creates the Auth user, then calls this. A failure rolls
-- the profile back, so the function can delete the Auth user afterwards.

create or replace function public.provision_employee(
  p_profile uuid,
  p_workspace uuid,
  p_first text,
  p_last text,
  p_username text,
  p_email text,
  p_position uuid,
  p_team uuid,
  p_role_keys text[],
  p_granted_by uuid,
  p_must_change_password boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_role uuid;
begin
  if current_user not in ('postgres', 'service_role') then
    raise exception 'forbidden';
  end if;
  if p_role_keys is null or cardinality(p_role_keys) = 0 then
    raise exception 'invalid_input';
  end if;
  if not exists (
    select 1 from public.teams
    where id = p_team and workspace_id = p_workspace and status = 'active'
  ) then
    raise exception 'invalid_team';
  end if;
  if p_position is not null and not exists (
    select 1 from public.job_positions
    where id = p_position and workspace_id = p_workspace and is_active
  ) then
    raise exception 'invalid_position';
  end if;
  if 'super_admin' = any (p_role_keys) and not exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.profile_id = p_granted_by
      and ur.revoked_at is null
      and r.key = 'super_admin'
      and r.is_active
  ) then
    raise exception 'forbidden';
  end if;

  insert into public.profiles (
    id, workspace_id, first_name, last_name, job_position_id, must_change_password
  ) values (
    p_profile, p_workspace, btrim(p_first), btrim(p_last), p_position, p_must_change_password
  );
  insert into public.profile_accounts (profile_id, workspace_id, username, email)
  values (p_profile, p_workspace, lower(btrim(p_username)), lower(btrim(p_email)));
  insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
  values (p_workspace, p_team, p_profile, true);

  foreach v_key in array p_role_keys loop
    select id into v_role
    from public.roles
    where workspace_id = p_workspace and key = v_key and is_active;
    if v_role is null then
      raise exception 'invalid_role';
    end if;
    insert into public.user_roles (workspace_id, profile_id, role_id, granted_by)
    values (p_workspace, p_profile, v_role, p_granted_by);
  end loop;

  perform app.audit(
    p_workspace, p_granted_by, 'employee.provision', 'profile', p_profile,
    jsonb_build_object('roles', to_jsonb(p_role_keys), 'team_id', p_team)
  );
end;
$$;

revoke all on function public.provision_employee(uuid, uuid, text, text, text, text, uuid, uuid, text[], uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.provision_employee(uuid, uuid, text, text, text, text, uuid, uuid, text[], uuid, boolean)
  to service_role;
