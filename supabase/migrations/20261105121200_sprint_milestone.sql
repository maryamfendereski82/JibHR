-- Sprint and milestone writes stay on the existing tables.
-- closed is the completed sprint. cancelled is new.
-- Milestone open/archived become upcoming/cancelled. reached stays the completed state.
-- One active sprint per project: lock the project row, and a partial unique index.
-- A task still has one current sprint. History is removed_at plus carried_from_sprint_id.

begin;

alter table public.sprints drop constraint sprints_status_check;
alter table public.sprints add constraint sprints_status_check
  check (status in ('planned', 'active', 'closed', 'cancelled'));

alter table public.milestones drop constraint milestones_status_check;
update public.milestones set status = 'upcoming' where status = 'open';
update public.milestones set status = 'cancelled' where status = 'archived';
alter table public.milestones add constraint milestones_status_check
  check (status in ('upcoming', 'in_progress', 'reached', 'cancelled'));
alter table public.milestones alter column status set default 'upcoming';

alter table public.sprints add column summary jsonb;

create unique index sprints_one_active_idx
  on public.sprints (project_id)
  where status = 'active';

create or replace function app.task_counts_complete(p_task uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tasks t
    join public.workflow_statuses s on s.id = t.status_id
    where t.id = p_task
      and t.archived_at is null
      and s.category in ('done', 'approved')
      and (t.approval_required = false or t.approval_state = 'approved')
  );
$$;

create or replace function app.require_plan_manager(p_project uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('tasks.manage.project');
  if p_project is null or not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
end;
$$;

revoke all on function app.task_counts_complete(uuid) from public, anon, authenticated;
revoke all on function app.require_plan_manager(uuid) from public, anon, authenticated;

create or replace function public.move_task_to_sprint(p_task uuid, p_sprint uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_status text;
  v_workspace uuid;
  v_previous uuid;
begin
  select project_id, status, workspace_id into v_project, v_status, v_workspace
  from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  if v_status in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if not exists (
    select 1 from public.tasks
    where id = p_task and project_id = v_project and archived_at is null
  ) then
    raise exception 'project_mismatch';
  end if;
  select sprint_id into v_previous
  from public.sprint_tasks
  where task_id = p_task and removed_at is null;
  if v_previous = p_sprint then
    return;
  end if;
  if v_previous is not null then
    update public.sprint_tasks
      set removed_at = clock_timestamp()
    where task_id = p_task and removed_at is null;
  end if;
  insert into public.sprint_tasks (sprint_id, task_id, carried_from_sprint_id)
  values (p_sprint, p_task, v_previous);
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (
    v_workspace, p_task, auth.uid(), 'task.sprint',
    jsonb_build_object('sprint_id', p_sprint, 'from_sprint_id', v_previous)
  );
  perform app.audit(
    v_workspace, auth.uid(), 'sprint.task_move', 'sprint', p_sprint,
    jsonb_build_object('task_id', p_task, 'from_sprint_id', v_previous)
  );
end;
$$;

create or replace function public.remove_task_from_sprint(p_task uuid, p_sprint uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_workspace uuid;
begin
  select project_id, workspace_id into v_project, v_workspace
  from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  update public.sprint_tasks
    set removed_at = clock_timestamp()
  where task_id = p_task and sprint_id = p_sprint and removed_at is null;
  if not found then
    raise exception 'not_found';
  end if;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_workspace, p_task, auth.uid(), 'task.sprint_remove', jsonb_build_object('sprint_id', p_sprint));
  perform app.audit(
    v_workspace, auth.uid(), 'sprint.task_remove', 'sprint', p_sprint,
    jsonb_build_object('task_id', p_task)
  );
end;
$$;

drop function public.create_sprint(uuid, text, date, date, text);

create function public.create_sprint(
  p_project uuid,
  p_name text,
  p_start date,
  p_end date,
  p_description text default '',
  p_tasks uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_task uuid;
begin
  perform app.require_plan_manager(p_project);
  if p_end < p_start then
    raise exception 'invalid_range';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  insert into public.sprints (workspace_id, project_id, name, description, start_date, end_date)
  values (app.current_workspace(), p_project, trim(p_name), coalesce(p_description, ''), p_start, p_end)
  returning id into v_id;
  foreach v_task in array coalesce(p_tasks, array[]::uuid[]) loop
    perform public.move_task_to_sprint(v_task, v_id);
  end loop;
  perform app.audit(app.current_workspace(), auth.uid(), 'sprint.create', 'sprint', v_id, '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function public.update_sprint(
  p_sprint uuid,
  p_name text,
  p_description text,
  p_start date,
  p_end date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_status text;
begin
  select project_id, status into v_project, v_status from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  if v_status in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if p_end < p_start then
    raise exception 'invalid_range';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  update public.sprints
    set name = trim(p_name),
        description = coalesce(p_description, ''),
        start_date = p_start,
        end_date = p_end
  where id = p_sprint;
  perform app.audit(app.current_workspace(), auth.uid(), 'sprint.update', 'sprint', p_sprint, '{}'::jsonb);
end;
$$;

create or replace function public.set_sprint_status(p_sprint uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v public.sprints%rowtype;
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  if p_status not in ('planned', 'active', 'closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select project_id into v_project from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  perform 1 from public.projects where id = v_project for update;
  select * into v from public.sprints where id = p_sprint for update;
  if v.status = p_status then
    return;
  end if;
  if v.status = 'planned' and p_status not in ('active', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status = 'active' and p_status not in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if p_status = 'active' and exists (
    select 1 from public.sprints
    where project_id = v.project_id and status = 'active' and id <> v.id
  ) then
    raise exception 'already_active';
  end if;
  if p_status = 'closed' and v.summary is null then
    select
      count(t.id)::integer,
      count(t.id) filter (where app.task_counts_complete(t.id))::integer,
      count(t.id) filter (
        where st.category = 'blocked' and not app.task_counts_complete(t.id)
      )::integer
    into v_total, v_complete, v_blocked
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id and t.archived_at is null
    join public.workflow_statuses st on st.id = t.status_id
    where link.sprint_id = v.id and link.removed_at is null;
    update public.sprints
      set status = 'closed',
          summary = jsonb_build_object(
            'total', v_total,
            'complete', v_complete,
            'blocked', v_blocked,
            'remaining', v_total - v_complete,
            'percent', case when v_total = 0 then 0 else v_complete * 100 / v_total end
          )
    where id = v.id;
  else
    update public.sprints set status = p_status where id = v.id;
  end if;
  perform app.audit(
    v.workspace_id, auth.uid(), 'sprint.status', 'sprint', v.id,
    jsonb_build_object('status', p_status)
  );
exception
  when unique_violation then
    raise exception 'already_active';
end;
$$;

create or replace function public.transfer_sprint_remainder(p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from public.sprints%rowtype;
  v_to public.sprints%rowtype;
  v_task uuid;
  v_count integer := 0;
begin
  if p_from = p_to then
    raise exception 'invalid_status';
  end if;
  select * into v_from from public.sprints where id = p_from;
  select * into v_to from public.sprints where id = p_to;
  if v_from.id is null or v_to.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_from.project_id);
  if v_from.project_id <> v_to.project_id then
    raise exception 'project_mismatch';
  end if;
  if v_to.status not in ('planned', 'active') then
    raise exception 'invalid_status';
  end if;
  perform 1 from public.projects where id = v_from.project_id for update;
  for v_task in
    select t.id
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id
    where link.sprint_id = v_from.id
      and link.removed_at is null
      and t.archived_at is null
      and not app.task_counts_complete(t.id)
  loop
    perform public.move_task_to_sprint(v_task, v_to.id);
    v_count := v_count + 1;
  end loop;
  perform app.audit(
    v_from.workspace_id, auth.uid(), 'sprint.transfer', 'sprint', v_from.id,
    jsonb_build_object('to', v_to.id, 'count', v_count)
  );
  return v_count;
end;
$$;

create or replace function public.project_sprint_counts(p_project uuid)
returns table (sprint_id uuid, total integer, complete integer, blocked integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    s.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.sprints s
  left join public.sprint_tasks link
    on link.sprint_id = s.id and link.removed_at is null
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where s.project_id = p_project
  group by s.id;
end;
$$;

create or replace function public.sprint_breakdown(p_sprint uuid)
returns table (kind text, bucket text, total integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project uuid;
begin
  perform app.require_active();
  select project_id into v_project from public.sprints where id = p_sprint;
  if v_project is null or not app.can_view_project(v_project) then
    raise exception 'forbidden';
  end if;
  return query
  select 'status'::text, st.name::text, count(*)::integer
  from public.sprint_tasks link
  join public.tasks t on t.id = link.task_id and t.archived_at is null and app.can_view_task(t.id)
  join public.workflow_statuses st on st.id = t.status_id
  where link.sprint_id = p_sprint and link.removed_at is null
  group by st.name
  union all
  select 'priority'::text, t.priority::text, count(*)::integer
  from public.sprint_tasks link
  join public.tasks t on t.id = link.task_id and t.archived_at is null and app.can_view_task(t.id)
  where link.sprint_id = p_sprint and link.removed_at is null
  group by t.priority
  union all
  select 'assignee'::text, trim(concat(p.first_name, ' ', p.last_name)), count(*)::integer
  from public.sprint_tasks link
  join public.tasks t on t.id = link.task_id and t.archived_at is null and app.can_view_task(t.id)
  join public.profiles p on p.id = t.primary_assignee_id
  where link.sprint_id = p_sprint and link.removed_at is null
  group by p.first_name, p.last_name;
end;
$$;

create or replace function public.link_milestone_task(p_milestone uuid, p_task uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_workspace uuid;
begin
  select project_id, workspace_id into v_project, v_workspace
  from public.milestones where id = p_milestone;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  if not exists (
    select 1 from public.tasks
    where id = p_task and project_id = v_project and archived_at is null
  ) then
    raise exception 'project_mismatch';
  end if;
  insert into public.milestone_tasks (milestone_id, task_id)
  values (p_milestone, p_task)
  on conflict do nothing;
  if found then
    perform app.audit(
      v_workspace, auth.uid(), 'milestone.task_link', 'milestone', p_milestone,
      jsonb_build_object('task_id', p_task)
    );
  end if;
end;
$$;

create or replace function public.unlink_milestone_task(p_milestone uuid, p_task uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_workspace uuid;
begin
  select project_id, workspace_id into v_project, v_workspace
  from public.milestones where id = p_milestone;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  delete from public.milestone_tasks
  where milestone_id = p_milestone and task_id = p_task;
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(
    v_workspace, auth.uid(), 'milestone.task_unlink', 'milestone', p_milestone,
    jsonb_build_object('task_id', p_task)
  );
end;
$$;

drop function public.create_milestone(uuid, text, date, text);

create function public.create_milestone(
  p_project uuid,
  p_title text,
  p_target date,
  p_description text default '',
  p_tasks uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_task uuid;
begin
  perform app.require_plan_manager(p_project);
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  insert into public.milestones (workspace_id, project_id, title, description, target_date)
  values (app.current_workspace(), p_project, trim(p_title), coalesce(p_description, ''), p_target)
  returning id into v_id;
  foreach v_task in array coalesce(p_tasks, array[]::uuid[]) loop
    perform public.link_milestone_task(v_id, v_task);
  end loop;
  perform app.audit(app.current_workspace(), auth.uid(), 'milestone.create', 'milestone', v_id, '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function public.update_milestone(
  p_milestone uuid,
  p_title text,
  p_description text,
  p_target date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
begin
  select project_id into v_project from public.milestones where id = p_milestone;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  update public.milestones
    set title = trim(p_title),
        description = coalesce(p_description, ''),
        target_date = p_target
  where id = p_milestone;
  perform app.audit(app.current_workspace(), auth.uid(), 'milestone.update', 'milestone', p_milestone, '{}'::jsonb);
end;
$$;

create or replace function public.set_milestone_status(
  p_milestone uuid,
  p_status text,
  p_reason text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.milestones%rowtype;
  v_open integer;
begin
  if p_status not in ('upcoming', 'in_progress', 'reached', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select * into v from public.milestones where id = p_milestone for update;
  if v.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v.project_id);
  if p_status = 'reached' then
    select count(*)::integer into v_open
    from public.milestone_tasks mt
    join public.tasks t on t.id = mt.task_id
    where mt.milestone_id = v.id
      and t.archived_at is null
      and not app.task_counts_complete(t.id);
    if v_open > 0 and char_length(trim(coalesce(p_reason, ''))) = 0 then
      raise exception 'tasks_incomplete';
    end if;
    if v_open > 0 then
      perform app.audit(
        v.workspace_id, auth.uid(), 'milestone.override', 'milestone', v.id,
        jsonb_build_object('reason', trim(p_reason), 'open_tasks', v_open)
      );
    end if;
  end if;
  update public.milestones set status = p_status where id = v.id;
  perform app.audit(
    v.workspace_id, auth.uid(), 'milestone.status', 'milestone', v.id,
    jsonb_build_object('status', p_status)
  );
end;
$$;

create or replace function public.project_milestone_counts(p_project uuid)
returns table (milestone_id uuid, total integer, complete integer, blocked integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    m.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.milestones m
  left join public.milestone_tasks link on link.milestone_id = m.id
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where m.project_id = p_project
  group by m.id;
end;
$$;

revoke all on function public.create_sprint(uuid, text, date, date, text, uuid[]) from public, anon;
revoke all on function public.update_sprint(uuid, text, text, date, date) from public, anon;
revoke all on function public.set_sprint_status(uuid, text) from public, anon;
revoke all on function public.remove_task_from_sprint(uuid, uuid) from public, anon;
revoke all on function public.transfer_sprint_remainder(uuid, uuid) from public, anon;
revoke all on function public.project_sprint_counts(uuid) from public, anon;
revoke all on function public.sprint_breakdown(uuid) from public, anon;
revoke all on function public.create_milestone(uuid, text, date, text, uuid[]) from public, anon;
revoke all on function public.update_milestone(uuid, text, text, date) from public, anon;
revoke all on function public.set_milestone_status(uuid, text, text) from public, anon;
revoke all on function public.unlink_milestone_task(uuid, uuid) from public, anon;
revoke all on function public.project_milestone_counts(uuid) from public, anon;

grant execute on function public.create_sprint(uuid, text, date, date, text, uuid[]) to authenticated, service_role;
grant execute on function public.update_sprint(uuid, text, text, date, date) to authenticated, service_role;
grant execute on function public.set_sprint_status(uuid, text) to authenticated, service_role;
grant execute on function public.remove_task_from_sprint(uuid, uuid) to authenticated, service_role;
grant execute on function public.transfer_sprint_remainder(uuid, uuid) to authenticated, service_role;
grant execute on function public.project_sprint_counts(uuid) to authenticated, service_role;
grant execute on function public.sprint_breakdown(uuid) to authenticated, service_role;
grant execute on function public.create_milestone(uuid, text, date, text, uuid[]) to authenticated, service_role;
grant execute on function public.update_milestone(uuid, text, text, date) to authenticated, service_role;
grant execute on function public.set_milestone_status(uuid, text, text) to authenticated, service_role;
grant execute on function public.unlink_milestone_task(uuid, uuid) to authenticated, service_role;
grant execute on function public.project_milestone_counts(uuid) to authenticated, service_role;

commit;
