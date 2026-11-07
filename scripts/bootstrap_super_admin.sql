-- First super admin. Run once in the Supabase SQL editor after migrations.
-- Create the user in Authentication first, with a confirmed email and a
-- password of at least 8 characters. Then replace the email below.
-- This script does not print or store the password.

do $$
declare
  v_email text := 'CHANGE_ME@jibcart.ir';
  v_user uuid;
  v_workspace uuid := 'a0000000-0000-4000-8000-000000000001';
  v_team uuid;
  v_role uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(v_email);
  if v_user is null then
    raise exception 'auth user not found for %', v_email;
  end if;
  if exists (select 1 from public.profiles where id = v_user) then
    raise exception 'profile already exists';
  end if;

  select id into v_team
  from public.teams
  where workspace_id = v_workspace and status = 'active'
  order by created_at
  limit 1;

  if v_team is null then
    insert into public.teams (workspace_id, name)
    values (v_workspace, 'مدیریت')
    returning id into v_team;
  end if;

  select id into v_role
  from public.roles
  where workspace_id = v_workspace and key = 'super_admin';

  insert into public.profiles (id, workspace_id, first_name, last_name, must_change_password)
  values (v_user, v_workspace, 'سوپر', 'ادمین', false);
  insert into public.profile_accounts (profile_id, workspace_id, username, email)
  values (v_user, v_workspace, 'superadmin', lower(v_email));
  insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
  values (v_workspace, v_team, v_user, true);
  insert into public.user_roles (workspace_id, profile_id, role_id)
  values (v_workspace, v_user, v_role);
  insert into public.team_manager_assignments (workspace_id, team_id, profile_id, kind)
  values (v_workspace, v_team, v_user, 'manager');
end
$$;
