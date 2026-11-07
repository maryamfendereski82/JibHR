-- Organization and access changes. Each function checks the caller's
-- permission itself because security definer bypasses row level security.

create or replace function app.is_team_manager(p_team uuid, p_profile uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.team_manager_assignments
    where team_id = p_team
      and profile_id = p_profile
      and revoked_at is null
      and kind = 'manager'
  );
$$;

create or replace function app.super_admin_count()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.user_roles ur
  join public.roles r on r.id = ur.role_id
  join public.profiles p on p.id = ur.profile_id
  where ur.revoked_at is null
    and r.key = 'super_admin'
    and r.is_system
    and p.status = 'active';
$$;

create or replace function public.upsert_job_position(p_title text, p_position uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_workspace uuid;
begin
  perform app.require_permission('positions.manage');
  v_workspace := app.current_workspace();
  if p_position is null then
    insert into public.job_positions (workspace_id, title)
    values (v_workspace, trim(p_title))
    returning id into v_id;
  else
    update public.job_positions
      set title = trim(p_title)
    where id = p_position and workspace_id = v_workspace
    returning id into v_id;
    if v_id is null then
      raise exception 'not_found';
    end if;
  end if;
  perform app.audit(v_workspace, auth.uid(), 'job_position.upsert', 'job_position', v_id, jsonb_build_object('title', trim(p_title)));
  return v_id;
end;
$$;

create or replace function public.set_position_active(p_position uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('positions.manage');
  update public.job_positions
    set is_active = p_active
  where id = p_position and workspace_id = app.current_workspace();
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'job_position.active', 'job_position', p_position, jsonb_build_object('active', p_active));
end;
$$;

create or replace function public.create_team(p_name text, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission('teams.create');
  insert into public.teams (workspace_id, name, description)
  values (app.current_workspace(), trim(p_name), coalesce(p_description, ''))
  returning id into v_id;
  perform app.audit(app.current_workspace(), auth.uid(), 'team.create', 'team', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end;
$$;

create or replace function public.set_team_status(p_team uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('teams.archive');
  if p_status not in ('active', 'inactive', 'archived') then
    raise exception 'invalid_status';
  end if;
  update public.teams
    set status = p_status
  where id = p_team and workspace_id = app.current_workspace();
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'team.status', 'team', p_team, jsonb_build_object('status', p_status));
end;
$$;

create or replace function public.add_team_member(p_profile uuid, p_team uuid, p_primary boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid := app.current_workspace();
  v_membership uuid;
  v_primary boolean := p_primary;
begin
  perform app.require_active();
  if not (
    app.has_permission('teams.members.manage.all')
    or (
      app.has_permission('teams.members.manage.team')
      and app.is_team_manager(p_team, auth.uid())
    )
  ) then
    raise exception 'forbidden';
  end if;
  if not exists (
    select 1 from public.teams
    where id = p_team and workspace_id = v_workspace and status = 'active'
  ) then
    raise exception 'team_unavailable';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile and workspace_id = v_workspace
  ) then
    raise exception 'not_found';
  end if;
  if v_primary or app.primary_team(p_profile) is null then
    update public.team_memberships
      set is_primary = false
    where profile_id = p_profile and is_primary and left_at is null and team_id <> p_team;
    v_primary := true;
  end if;
  select id into v_membership
  from public.team_memberships
  where team_id = p_team and profile_id = p_profile and left_at is null;
  if v_membership is null then
    insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
    values (v_workspace, p_team, p_profile, v_primary);
  else
    update public.team_memberships set is_primary = v_primary where id = v_membership;
  end if;
  perform app.audit(v_workspace, auth.uid(), 'team.member_add', 'team', p_team, jsonb_build_object('profile_id', p_profile, 'primary', v_primary));
end;
$$;

create or replace function public.remove_team_member(p_profile uuid, p_team uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not (
    app.has_permission('teams.members.manage.all')
    or (
      app.has_permission('teams.members.manage.team')
      and app.is_team_manager(p_team, auth.uid())
    )
  ) then
    raise exception 'forbidden';
  end if;
  if exists (
    select 1 from public.team_memberships
    where team_id = p_team and profile_id = p_profile and left_at is null and is_primary
  ) then
    raise exception 'primary_team_required';
  end if;
  update public.team_memberships
    set left_at = clock_timestamp()
  where team_id = p_team and profile_id = p_profile and left_at is null;
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'team.member_remove', 'team', p_team, jsonb_build_object('profile_id', p_profile));
end;
$$;

create or replace function public.assign_team_leadership(p_profile uuid, p_team uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('teams.managers.assign');
  if p_kind not in ('manager', 'supervisor', 'deputy') then
    raise exception 'invalid_kind';
  end if;
  if not exists (
    select 1 from public.team_memberships
    where team_id = p_team and profile_id = p_profile and left_at is null
  ) then
    raise exception 'not_a_member';
  end if;
  if not exists (
    select 1 from public.team_manager_assignments
    where team_id = p_team and profile_id = p_profile and kind = p_kind and revoked_at is null
  ) then
    insert into public.team_manager_assignments (workspace_id, team_id, profile_id, kind)
    values (app.current_workspace(), p_team, p_profile, p_kind);
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'team.leadership', 'team', p_team, jsonb_build_object('profile_id', p_profile, 'kind', p_kind));
end;
$$;

create or replace function public.revoke_team_leadership(p_profile uuid, p_team uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('teams.managers.assign');
  update public.team_manager_assignments
    set revoked_at = clock_timestamp()
  where team_id = p_team and profile_id = p_profile and kind = p_kind and revoked_at is null;
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'team.leadership_revoke', 'team', p_team, jsonb_build_object('profile_id', p_profile, 'kind', p_kind));
end;
$$;

create or replace function public.create_role(p_key text, p_name text, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission('roles.manage');
  if p_key !~ '^[a-z][a-z0-9_]{1,40}$' then
    raise exception 'invalid_role_key';
  end if;
  insert into public.roles (workspace_id, key, name, description, is_system)
  values (app.current_workspace(), p_key, trim(p_name), coalesce(p_description, ''), false)
  returning id into v_id;
  perform app.audit(app.current_workspace(), auth.uid(), 'role.create', 'role', v_id, jsonb_build_object('key', p_key));
  return v_id;
end;
$$;

create or replace function public.set_role_active(p_role uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_system boolean;
  v_key text;
begin
  perform app.require_permission('roles.manage');
  select is_system, key into v_system, v_key
  from public.roles
  where id = p_role and workspace_id = app.current_workspace();
  if v_key is null then
    raise exception 'not_found';
  end if;
  if v_system and v_key = 'super_admin' and not p_active then
    raise exception 'protected_role';
  end if;
  update public.roles set is_active = p_active where id = p_role;
  perform app.audit(app.current_workspace(), auth.uid(), 'role.active', 'role', p_role, jsonb_build_object('active', p_active));
end;
$$;

create or replace function public.set_role_permissions(p_role uuid, p_keys text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_system boolean;
begin
  perform app.require_permission('roles.manage');
  select key, is_system into v_key, v_system
  from public.roles
  where id = p_role and workspace_id = app.current_workspace();
  if v_key is null then
    raise exception 'not_found';
  end if;
  if v_system and v_key = 'super_admin' and not ('roles.manage' = any (p_keys) and 'roles.assign' = any (p_keys)) then
    raise exception 'protected_role';
  end if;
  delete from public.role_permissions where role_id = p_role;
  insert into public.role_permissions (role_id, permission_id)
  select p_role, id from public.permissions where key = any (p_keys);
  perform app.audit(app.current_workspace(), auth.uid(), 'role.permissions', 'role', p_role, jsonb_build_object('keys', p_keys));
end;
$$;

create or replace function public.assign_user_role(p_profile uuid, p_role_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role uuid;
  v_system boolean;
  v_workspace uuid := app.current_workspace();
begin
  perform app.require_active();
  select id, is_system into v_role, v_system
  from public.roles
  where workspace_id = v_workspace and key = p_role_key and is_active;
  if v_role is null then
    raise exception 'not_found';
  end if;
  if p_role_key = 'super_admin' then
    if not app.is_super_admin(auth.uid()) then
      raise exception 'forbidden';
    end if;
  elsif not app.has_permission('roles.assign') then
    raise exception 'forbidden';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile and workspace_id = v_workspace
  ) then
    raise exception 'not_found';
  end if;
  if not exists (
    select 1 from public.user_roles
    where profile_id = p_profile and role_id = v_role and revoked_at is null
  ) then
    insert into public.user_roles (workspace_id, profile_id, role_id, granted_by)
    values (v_workspace, p_profile, v_role, auth.uid());
  end if;
  perform app.audit(v_workspace, auth.uid(), 'role.assign', 'profile', p_profile, jsonb_build_object('role', p_role_key));
end;
$$;

create or replace function public.revoke_user_role(p_profile uuid, p_role_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role uuid;
begin
  perform app.require_active();
  if p_role_key = 'super_admin' then
    if not app.is_super_admin(auth.uid()) then
      raise exception 'forbidden';
    end if;
    if app.super_admin_count() <= 1 and app.is_super_admin(p_profile) then
      raise exception 'last_super_admin';
    end if;
  elsif not app.has_permission('roles.assign') then
    raise exception 'forbidden';
  end if;
  select id into v_role
  from public.roles
  where workspace_id = app.current_workspace() and key = p_role_key;
  update public.user_roles
    set revoked_at = clock_timestamp()
  where profile_id = p_profile and role_id = v_role and revoked_at is null;
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'role.revoke', 'profile', p_profile, jsonb_build_object('role', p_role_key));
end;
$$;

create or replace function public.set_employee_status(p_profile uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('employees.deactivate');
  if p_status not in ('active', 'inactive') then
    raise exception 'invalid_status';
  end if;
  if p_status = 'inactive'
     and app.is_super_admin(p_profile)
     and app.super_admin_count() <= 1 then
    raise exception 'last_super_admin';
  end if;
  update public.profiles
    set status = p_status
  where id = p_profile and workspace_id = app.current_workspace();
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'employee.status', 'profile', p_profile, jsonb_build_object('status', p_status));
end;
$$;

create or replace function public.create_invitation(
  p_email text,
  p_first_name text,
  p_last_name text,
  p_username text,
  p_position uuid,
  p_team uuid,
  p_role_keys text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_key text;
begin
  perform app.require_permission('employees.create');
  if p_team is null then
    raise exception 'primary_team_required';
  end if;
  if p_team is null then
    raise exception 'primary_team_required';
  end if;
  if p_role_keys is null or cardinality(p_role_keys) = 0 then
    raise exception 'role_required';
  end if;
  foreach v_key in array p_role_keys loop
    if v_key = 'super_admin' and not app.is_super_admin(auth.uid()) then
      raise exception 'forbidden';
    end if;
    if not exists (
      select 1 from public.roles
      where workspace_id = app.current_workspace() and key = v_key and is_active
    ) then
      raise exception 'not_found';
    end if;
  end loop;
  insert into public.invitations (
    workspace_id, email, first_name, last_name, username,
    job_position_id, primary_team_id, role_keys, invited_by, expires_at
  ) values (
    app.current_workspace(), lower(trim(p_email)), trim(p_first_name), trim(p_last_name), lower(trim(p_username)),
    p_position, p_team, p_role_keys, auth.uid(), clock_timestamp() + interval '7 days'
  )
  returning id into v_id;
  perform app.audit(app.current_workspace(), auth.uid(), 'employee.invite', 'invitation', v_id, jsonb_build_object('email', lower(trim(p_email))));
  return v_id;
end;
$$;

create or replace function public.accept_invitation(p_invitation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.invitations%rowtype;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_key text;
  v_role uuid;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  select * into v_row from public.invitations where id = p_invitation for update;
  if not found then
    raise exception 'not_found';
  end if;
  if v_row.consumed_at is not null or v_row.expires_at < clock_timestamp() then
    raise exception 'invitation_closed';
  end if;
  if lower(v_row.email) <> v_email then
    raise exception 'forbidden';
  end if;
  insert into public.profiles (
    id, workspace_id, first_name, last_name, job_position_id, must_change_password
  ) values (
    auth.uid(), v_row.workspace_id, v_row.first_name, v_row.last_name, v_row.job_position_id, false
  );
  insert into public.profile_accounts (profile_id, workspace_id, username, email)
  values (auth.uid(), v_row.workspace_id, v_row.username, v_row.email);
  if v_row.primary_team_id is not null then
    insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
    values (v_row.workspace_id, v_row.primary_team_id, auth.uid(), true);
  end if;
  foreach v_key in array v_row.role_keys loop
    select id into v_role from public.roles
    where workspace_id = v_row.workspace_id and key = v_key and is_active;
    if v_role is not null then
      insert into public.user_roles (workspace_id, profile_id, role_id, granted_by)
      values (v_row.workspace_id, auth.uid(), v_role, v_row.invited_by);
    end if;
  end loop;
  update public.invitations set consumed_at = clock_timestamp() where id = p_invitation;
  perform app.audit(v_row.workspace_id, auth.uid(), 'employee.joined', 'profile', auth.uid(), jsonb_build_object('invitation_id', p_invitation));
end;
$$;

create or replace function public.record_auth_attempt(p_key text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_key is null or char_length(p_key) < 16 then
    raise exception 'invalid_attempt';
  end if;
  insert into public.auth_attempts (attempt_key) values (p_key);
  select count(*)::integer into v_count
  from public.auth_attempts
  where attempt_key = p_key
    and created_at > clock_timestamp() - interval '15 minutes';
  return v_count;
end;
$$;

create or replace function public.assert_permission(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission(p_key);
end;
$$;

create or replace function public.mark_password_changed(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles set must_change_password = false where id = p_profile;
end;
$$;
