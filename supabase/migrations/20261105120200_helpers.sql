-- Helpers run as the migration owner so RLS policies can ask them
-- questions without recursively applying the same policies.
-- search_path is empty; every reference is schema-qualified.

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();
create trigger teams_touch before update on public.teams
  for each row execute function app.touch_updated_at();
create trigger projects_touch before update on public.projects
  for each row execute function app.touch_updated_at();
create trigger tasks_touch before update on public.tasks
  for each row execute function app.touch_updated_at();

create or replace function app.block_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'no_delete';
end;
$$;

create trigger attendance_intervals_no_delete before delete on public.attendance_intervals
  for each row execute function app.block_delete();
create trigger attendance_events_no_delete before delete on public.attendance_events
  for each row execute function app.block_delete();
create trigger attendance_events_no_update before update on public.attendance_events
  for each row execute function app.block_delete();
create trigger attendance_segments_no_delete before delete on public.attendance_daily_segments
  for each row execute function app.block_delete();
create trigger attendance_reports_no_delete before delete on public.attendance_daily_reports
  for each row execute function app.block_delete();
create trigger attendance_report_items_no_delete before delete on public.attendance_report_items
  for each row execute function app.block_delete();
create trigger audit_logs_no_delete before delete on public.audit_logs
  for each row execute function app.block_delete();
create trigger audit_logs_no_update before update on public.audit_logs
  for each row execute function app.block_delete();

create or replace function app.protect_attendance_interval()
returns trigger
language plpgsql
as $$
begin
  if new.original_started_at is distinct from old.original_started_at
     or new.profile_id is distinct from old.profile_id
     or new.workspace_id is distinct from old.workspace_id
     or new.origin is distinct from old.origin
     or (
       old.original_ended_at is not null
       and new.original_ended_at is distinct from old.original_ended_at
     )
  then
    raise exception 'immutable_original';
  end if;
  return new;
end;
$$;

create trigger attendance_intervals_protect before update on public.attendance_intervals
  for each row execute function app.protect_attendance_interval();

create or replace function app.protect_segment_facts()
returns trigger
language plpgsql
as $$
begin
  if new.started_at is distinct from old.started_at
     or new.ended_at is distinct from old.ended_at
     or new.tehran_date is distinct from old.tehran_date
     or new.interval_id is distinct from old.interval_id
     or new.profile_id is distinct from old.profile_id
     or new.approval_mode is distinct from old.approval_mode
     or (old.superseded_at is not null and new.superseded_at is distinct from old.superseded_at)
  then
    raise exception 'immutable_segment';
  end if;
  return new;
end;
$$;

create trigger attendance_segments_protect before update on public.attendance_daily_segments
  for each row execute function app.protect_segment_facts();

create or replace function app.protect_report_decision()
returns trigger
language plpgsql
as $$
begin
  if old.decision <> 'pending' and (
    new.decision is distinct from old.decision
    or new.decided_by is distinct from old.decided_by
    or new.decided_at is distinct from old.decided_at
    or new.reason is distinct from old.reason
  ) then
    raise exception 'already_decided';
  end if;
  return new;
end;
$$;

create trigger attendance_report_items_protect before update on public.attendance_report_items
  for each row execute function app.protect_report_decision();

create or replace function app.is_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'active'
  );
$$;

create or replace function app.current_workspace()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select workspace_id from public.profiles where id = auth.uid();
$$;

create or replace function app.has_permission(p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id and r.is_active
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions p on p.id = rp.permission_id
    where ur.profile_id = auth.uid()
      and ur.revoked_at is null
      and p.key = p_key
  );
$$;

create or replace function app.is_super_admin(p_profile uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.profile_id = p_profile
      and ur.revoked_at is null
      and r.key = 'super_admin'
      and r.is_system
      and r.is_active
  );
$$;

create or replace function app.primary_team(p_profile uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select team_id
  from public.team_memberships
  where profile_id = p_profile
    and is_primary
    and left_at is null
  limit 1;
$$;

create or replace function app.is_team_approver(p_team uuid, p_profile uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_team is not null and exists (
    select 1
    from public.team_manager_assignments
    where team_id = p_team
      and profile_id = p_profile
      and revoked_at is null
      and kind in ('manager', 'supervisor', 'deputy')
  );
$$;

create or replace function app.require_active()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  if not app.is_active() then
    raise exception 'inactive';
  end if;
end;
$$;

create or replace function app.require_permission(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not app.has_permission(p_key) then
    raise exception 'forbidden';
  end if;
end;
$$;

create or replace function app.audit(
  p_workspace uuid,
  p_actor uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_logs (workspace_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_workspace, p_actor, p_action, p_entity_type, p_entity_id, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

create or replace function app.notify(
  p_workspace uuid,
  p_recipient uuid,
  p_category text,
  p_title text,
  p_body text,
  p_entity_type text default null,
  p_entity_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_recipient is null then
    return;
  end if;
  insert into public.notifications (
    workspace_id, recipient_id, category, title, body, entity_type, entity_id
  ) values (
    p_workspace, p_recipient, p_category, p_title, p_body, p_entity_type, p_entity_id
  );
end;
$$;

create or replace function app.can_view_employee(p_profile uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
  v_team uuid;
begin
  if auth.uid() is null or not app.is_active() then
    return false;
  end if;
  select workspace_id into v_workspace from public.profiles where id = p_profile;
  if v_workspace is null or v_workspace is distinct from app.current_workspace() then
    return false;
  end if;
  if p_profile = auth.uid() or app.has_permission('employees.view.all') then
    return true;
  end if;
  if app.has_permission('employees.view.team') then
    v_team := app.primary_team(p_profile);
    if app.is_team_approver(v_team, auth.uid()) then
      return true;
    end if;
  end if;
  return false;
end;
$$;

create or replace function app.can_view_attendance(p_profile uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app.is_active() then
    return false;
  end if;
  if p_profile = auth.uid() then
    return app.current_workspace() = (select workspace_id from public.profiles where id = p_profile);
  end if;
  if app.has_permission('attendance.view.all') then
    return app.current_workspace() = (select workspace_id from public.profiles where id = p_profile);
  end if;
  if app.has_permission('attendance.view.team')
     and app.is_team_approver(app.primary_team(p_profile), auth.uid()) then
    return true;
  end if;
  return false;
end;
$$;

create or replace function app.can_view_project(p_project uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
begin
  if auth.uid() is null or not app.is_active() then
    return false;
  end if;
  select workspace_id into v_workspace from public.projects where id = p_project;
  if v_workspace is null or v_workspace is distinct from app.current_workspace() then
    return false;
  end if;
  if app.has_permission('projects.view.all') then
    return true;
  end if;
  return exists (
    select 1 from public.project_members
    where project_id = p_project
      and profile_id = auth.uid()
      and removed_at is null
  );
end;
$$;

create or replace function app.task_visible_directly(
  p_project uuid,
  p_assignee uuid,
  p_task uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_visibility text;
begin
  if p_project is null then
    return p_assignee = auth.uid()
      or app.is_team_approver(app.primary_team(p_assignee), auth.uid())
      or app.has_permission('tasks.view.all');
  end if;

  select visibility into v_visibility from public.projects where id = p_project;
  if app.has_permission('projects.view.all') then
    return true;
  end if;
  if v_visibility = 'project_wide' then
    return exists (
      select 1 from public.project_members
      where project_id = p_project and profile_id = auth.uid() and removed_at is null
    );
  end if;
  return p_assignee = auth.uid()
    or exists (
      select 1 from public.task_collaborators
      where task_id = p_task and profile_id = auth.uid()
    )
    or exists (
      select 1 from public.project_members
      where project_id = p_project
        and profile_id = auth.uid()
        and removed_at is null
        and member_role in ('manager', 'reviewer')
    );
end;
$$;

create or replace function app.can_view_task(p_task uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_task;
  v_project uuid;
  v_assignee uuid;
  v_parent uuid;
  v_workspace uuid;
  i integer;
begin
  if auth.uid() is null or not app.is_active() then
    return false;
  end if;
  for i in 1..8 loop
    select project_id, primary_assignee_id, parent_task_id, workspace_id
      into v_project, v_assignee, v_parent, v_workspace
    from public.tasks
    where id = v_id;
    if not found or v_workspace is distinct from app.current_workspace() then
      return false;
    end if;
    if app.task_visible_directly(v_project, v_assignee, v_id) then
      return true;
    end if;
    exit when v_parent is null;
    v_id := v_parent;
  end loop;
  return false;
end;
$$;

create or replace function app.can_approve_team(p_team uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.is_active() and (
    app.has_permission(p_permission || '.all')
    or (
      app.has_permission(p_permission || '.team')
      and app.is_team_approver(p_team, auth.uid())
    )
  );
$$;
