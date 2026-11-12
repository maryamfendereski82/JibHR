-- dashboard_split: the split dashboard returns exactly what the previous
-- function returned, for every profile in the database as the viewer, and
-- every scope equals the per-row check it replaces, id for id.
-- Runs after critical.sql and attendance_group_page.sql, as postgres.
-- Everything here is rolled back.

\set wa a0000000-0000-4000-8000-000000000001
\set wx c0000000-0000-4000-8000-000000000002
\set t1 c2000000-0000-4000-8000-000000000001
\set t2 c2000000-0000-4000-8000-000000000002
\set t3 c2000000-0000-4000-8000-000000000003
\set t4 c2000000-0000-4000-8000-000000000004

begin;

insert into public.workspaces (id, name) values (:'wx', 'فضای آزمون تفکیک');

-- People. Two digits at the end name the scenario.
create temp table s_people (id uuid, label text, ws uuid, team uuid, role_key text, status text) on commit drop;
insert into s_people values
  ('c1000000-0000-4000-8000-000000000001', 'employee',        :'wa', :'t1', 'employee',        'active'),
  ('c1000000-0000-4000-8000-000000000002', 'peer',            :'wa', :'t1', 'employee',        'active'),
  ('c1000000-0000-4000-8000-000000000003', 'manager t1',      :'wa', :'t1', 'team_manager',    'active'),
  ('c1000000-0000-4000-8000-000000000004', 'manager t2+t3',   :'wa', :'t2', 'team_manager',    'active'),
  ('c1000000-0000-4000-8000-000000000005', 'supervisor t2',   :'wa', :'t2', 'team_manager',    'active'),
  ('c1000000-0000-4000-8000-000000000006', 'deputy t3',       :'wa', :'t3', 'team_manager',    'active'),
  ('c1000000-0000-4000-8000-000000000007', 'revoked t3',      :'wa', :'t3', 'team_manager',    'active'),
  ('c1000000-0000-4000-8000-000000000008', 'custom t2',       :'wa', :'t2', 'qa_split_custom', 'active'),
  ('c1000000-0000-4000-8000-000000000009', 'no scope',        :'wa', :'t3', null,              'active'),
  ('c1000000-0000-4000-8000-000000000010', 'project manager', :'wa', :'t3', 'project_manager', 'active'),
  ('c1000000-0000-4000-8000-000000000011', 'general admin',   :'wa', :'t2', 'general_admin',   'active'),
  ('c1000000-0000-4000-8000-000000000012', 'super admin',     :'wa', :'t1', 'super_admin',     'active'),
  ('c1000000-0000-4000-8000-000000000013', 'inactive',        :'wa', :'t1', 'employee',        'inactive'),
  ('c1000000-0000-4000-8000-000000000014', 'other workspace', :'wx', :'t4', null,              'active'),
  ('c1000000-0000-4000-8000-000000000015', 'no primary team', :'wa', null,  'employee',        'active'),
  ('c1000000-0000-4000-8000-000000000016', 'member t2',       :'wa', :'t2', 'employee',        'active'),
  ('c1000000-0000-4000-8000-000000000017', 'member t3',       :'wa', :'t3', 'employee',        'active');

insert into auth.users (id, email) select id, 'split' || right(id::text, 2) || '@split.test' from s_people;
insert into public.profiles (id, workspace_id, first_name, last_name, status)
select id, ws, 'تفکیک', label, status from s_people;

insert into public.teams (id, workspace_id, name) values
  (:'t1', :'wa', 'تفکیک ۱'), (:'t2', :'wa', 'تفکیک ۲'), (:'t3', :'wa', 'تفکیک ۳'), (:'t4', :'wx', 'تفکیک بیرونی');

insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
select ws, team, id, true from s_people where team is not null;
-- A second, non-primary membership must not count as a primary team.
insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary)
values (:'wa', :'t2', 'c1000000-0000-4000-8000-000000000001', false);

insert into public.team_manager_assignments (workspace_id, team_id, profile_id, kind, revoked_at) values
  (:'wa', :'t1', 'c1000000-0000-4000-8000-000000000003', 'manager', null),
  (:'wa', :'t2', 'c1000000-0000-4000-8000-000000000004', 'manager', null),
  (:'wa', :'t3', 'c1000000-0000-4000-8000-000000000004', 'manager', null),
  (:'wa', :'t2', 'c1000000-0000-4000-8000-000000000005', 'supervisor', null),
  (:'wa', :'t3', 'c1000000-0000-4000-8000-000000000006', 'deputy', null),
  (:'wa', :'t3', 'c1000000-0000-4000-8000-000000000007', 'manager', now()),
  (:'wa', :'t2', 'c1000000-0000-4000-8000-000000000008', 'manager', null);

-- A custom role with a narrow scope: team attendance and leave approval only,
-- no employee or absence permissions.
insert into public.roles (workspace_id, key, name, is_system)
values (:'wa', 'qa_split_custom', 'نقش محدود آزمون', false);
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r, public.permissions p
where r.key = 'qa_split_custom' and r.workspace_id = :'wa'
  and p.key in ('attendance.view.self', 'attendance.view.team', 'attendance.approve.team', 'leave.approve.team');

insert into public.user_roles (workspace_id, profile_id, role_id)
select s.ws, s.id, r.id from s_people s
join public.roles r on r.key = s.role_key and r.workspace_id = s.ws;

-- Activity in every team and in the other workspace.
set local session_replication_role = replica;
do $$
declare
  v_today date := app.tehran_today();
  p record;
  v_status text;
  v_i int := 0;
  v_absence uuid;
  v_project uuid;
  v_flow uuid;
  v_review uuid;
  v_done uuid;
  v_todo uuid;
begin
  for p in select * from s_people where team is not null loop
    v_i := v_i + 1;
    foreach v_status in array array['pending', 'partially_approved', 'needs_revision', 'approved', 'rejected'] loop
      insert into public.attendance_daily_reports (workspace_id, profile_id, team_id, tehran_date, sequence, kind, submission_source, status)
      values (p.ws, p.id, p.team, v_today - (array_position(array['pending','partially_approved','needs_revision','approved','rejected'], v_status)), 1, 'primary', 'manual', v_status);
    end loop;
    if v_i % 2 = 0 then
      insert into public.attendance_intervals (workspace_id, profile_id, origin, status, original_started_at, effective_started_at)
      values (p.ws, p.id, 'clock', 'open', now() - interval '2 hours', now() - interval '2 hours');
    end if;
    if v_i % 3 = 0 then
      insert into public.attendance_intervals (workspace_id, profile_id, origin, status, original_started_at, effective_started_at)
      values (p.ws, p.id, 'clock', 'incomplete', now() - interval '3 days', now() - interval '3 days');
    end if;
    insert into public.attendance_corrections (workspace_id, profile_id, team_id, kind, reason, status, decided_by)
    values (p.ws, p.id, p.team, 'missing_out', 'آزمون',
            case when v_i % 2 = 0 then 'pending' else 'approved' end,
            case when v_i % 2 = 0 then null else p.id end)
    on conflict do nothing;
    insert into public.leave_requests (workspace_id, profile_id, team_id, kind, start_date, end_date, status)
    values (p.ws, p.id, p.team, 'daily', v_today + 3, v_today + 4, case when v_i % 3 = 0 then 'approved' else 'pending' end);
    insert into public.absence_records (workspace_id, profile_id, team_id, start_date, end_date, reason, recorded_by)
    values (p.ws, p.id, p.team, v_today - 9, v_today - 9, 'آزمون', p.id) returning id into v_absence;
    insert into public.absence_disputes (absence_id, profile_id, explanation, status)
    values (v_absence, p.id, 'آزمون', case when v_i % 2 = 1 then 'pending' else 'accepted' end);
    insert into public.notifications (workspace_id, recipient_id, category, title, body)
    values (p.ws, p.id, 'task', 'آزمون', 'آزمون');
  end loop;

  -- Personal tasks: one in review awaiting approval with no reviewer (team
  -- approver decides), one with a named reviewer, one done, one overdue.
  select w.id into v_flow from public.workflows w where w.project_id is null limit 1;
  select id into v_review from public.workflow_statuses where workflow_id = v_flow and category = 'in_review' limit 1;
  select id into v_done from public.workflow_statuses where workflow_id = v_flow and category = 'done' limit 1;
  select id into v_todo from public.workflow_statuses where workflow_id = v_flow and category = 'todo' limit 1;
  for p in select * from s_people where ws = 'a0000000-0000-4000-8000-000000000001' and status = 'active' loop
    insert into public.tasks (workspace_id, title, primary_assignee_id, status_id, approval_required, approval_state, created_by, reviewer_id, due_at)
    values
      (p.ws, 'بررسی بی‌بررسی‌کننده', p.id, v_review, true, 'pending', p.id, null, now() + interval '2 days'),
      (p.ws, 'بررسی با بررسی‌کننده', p.id, v_review, true, 'pending', p.id, 'c1000000-0000-4000-8000-000000000011', now() + interval '3 days'),
      (p.ws, 'انجام‌شده', p.id, v_done, false, 'not_required', p.id, null, now() - interval '5 days'),
      (p.ws, 'گذشته از مهلت', p.id, v_todo, false, 'not_required', p.id, null, now() - interval '1 day');
  end loop;

  -- A restricted project managed by the project manager, with an employee.
  insert into public.projects (workspace_id, name, visibility, created_by)
  values ('a0000000-0000-4000-8000-000000000001', 'پروژهٔ تفکیک', 'restricted', 'c1000000-0000-4000-8000-000000000010')
  returning id into v_project;
  insert into public.project_members (project_id, profile_id, member_role) values
    (v_project, 'c1000000-0000-4000-8000-000000000010', 'manager'),
    (v_project, 'c1000000-0000-4000-8000-000000000001', 'member');
  select w.id into v_flow from public.workflows w where w.project_id = v_project limit 1;
  if v_flow is null then
    select w.id into v_flow from public.workflows w where w.project_id is null limit 1;
  end if;
  select id into v_review from public.workflow_statuses where workflow_id = v_flow and category = 'in_review' limit 1;
  select id into v_todo from public.workflow_statuses where workflow_id = v_flow and category = 'todo' limit 1;
  insert into public.tasks (workspace_id, project_id, title, primary_assignee_id, status_id, approval_required, approval_state, created_by, due_at) values
    ('a0000000-0000-4000-8000-000000000001', v_project, 'پروژه در بررسی', 'c1000000-0000-4000-8000-000000000001', v_review, true, 'pending', 'c1000000-0000-4000-8000-000000000010', now() + interval '1 day'),
    ('a0000000-0000-4000-8000-000000000001', v_project, 'پروژه باز', 'c1000000-0000-4000-8000-000000000002', v_todo, false, 'not_required', 'c1000000-0000-4000-8000-000000000010', now() - interval '2 days');
end
$$;
set local session_replication_role = origin;

-- Every profile as viewer.
do $$
declare
  v_viewer record;
  v_old jsonb;
  v_new jsonb;
  v_err_old text;
  v_err_new text;
  v_scope record;
  v_checked int := 0;
  v_diff int;
begin
  for v_viewer in select p.id, p.status, coalesce(s.label, 'existing ' || p.first_name || ' ' || p.last_name) as label
                  from public.profiles p left join s_people s on s.id = p.id order by p.id loop
    perform set_config('request.jwt.claim.sub', v_viewer.id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_viewer.id, 'role', 'authenticated')::text, true);

    if v_viewer.status <> 'active' then
      begin v_old := app.dashboard_summary_v1(); v_err_old := null; exception when others then v_err_old := sqlerrm; end;
      begin v_new := public.dashboard_summary(); v_err_new := null; exception when others then v_err_new := sqlerrm; end;
      if v_err_old is distinct from v_err_new or v_err_new is null then
        raise exception '% (inactive): old error %, new error %', v_viewer.label, v_err_old, v_err_new;
      end if;
      continue;
    end if;

    -- 1. Whole output, and each section against the matching part.
    v_old := app.dashboard_summary_v1();
    v_new := public.dashboard_summary();
    if v_old is distinct from v_new then
      raise exception '% summary differs: old % new %', v_viewer.label, v_old, v_new;
    end if;
    if v_old->'personal' is distinct from coalesce(public.dashboard_personal(), 'null'::jsonb) then raise exception '% personal differs', v_viewer.label; end if;
    if v_old->'team' is distinct from coalesce(public.dashboard_team(), 'null'::jsonb) then raise exception '% team differs', v_viewer.label; end if;
    if v_old->'projects' is distinct from coalesce(public.dashboard_projects(), 'null'::jsonb) then raise exception '% projects differs', v_viewer.label; end if;
    if v_old->'queues' is distinct from coalesce(public.dashboard_queues(), 'null'::jsonb) then raise exception '% queues differs', v_viewer.label; end if;

    -- 2. Scopes, id for id, both directions.
    select count(*) into v_diff from (
      (select p.id from public.profiles p where app.can_view_attendance(p.id) except select app.dash_attendance_profiles())
      union all
      (select app.dash_attendance_profiles() except select p.id from public.profiles p where app.can_view_attendance(p.id))
    ) d;
    if v_diff > 0 then raise exception '% attendance scope differs by % profiles', v_viewer.label, v_diff; end if;

    select count(*) into v_diff from (
      (select p.id from public.profiles p where app.can_view_employee(p.id) except select app.dash_employee_profiles())
      union all
      (select app.dash_employee_profiles() except select p.id from public.profiles p where app.can_view_employee(p.id))
    ) d;
    if v_diff > 0 then raise exception '% employee scope differs by % profiles', v_viewer.label, v_diff; end if;

    select count(*) into v_diff from (
      (select t.id from public.teams t where app.is_team_approver(t.id, v_viewer.id) except select unnest(app.dash_approver_teams()))
      union all
      (select unnest(app.dash_approver_teams()) except select t.id from public.teams t where app.is_team_approver(t.id, v_viewer.id))
    ) d;
    if v_diff > 0 then raise exception '% approver teams differ', v_viewer.label; end if;

    for v_scope in select k, s.all_teams, s.teams from unnest(array['attendance.approve', 'leave.approve']) k
                   cross join lateral app.dash_approval_scope(k) s loop
      select count(*) into v_diff from (
        select t.id from public.teams t
        union all select null::uuid
      ) t(id)
      where coalesce(app.can_approve_team(t.id, v_scope.k), false) is distinct from coalesce(v_scope.all_teams or t.id = any(v_scope.teams), false);
      if v_diff > 0 then raise exception '% % scope differs on % teams', v_viewer.label, v_scope.k, v_diff; end if;
    end loop;

    -- 3. Approvable rows, id for id: what the queue counts.
    select * into v_scope from app.dash_approval_scope('attendance.approve');
    select count(*) into v_diff from (
      (select r.id from public.attendance_daily_reports r where r.status in ('pending','partially_approved','needs_revision') and app.can_approve_team(r.team_id, 'attendance.approve')
       except select r.id from public.attendance_daily_reports r where r.status in ('pending','partially_approved','needs_revision') and (v_scope.all_teams or r.team_id = any(v_scope.teams)))
      union all
      (select r.id from public.attendance_daily_reports r where r.status in ('pending','partially_approved','needs_revision') and (v_scope.all_teams or r.team_id = any(v_scope.teams))
       except select r.id from public.attendance_daily_reports r where r.status in ('pending','partially_approved','needs_revision') and app.can_approve_team(r.team_id, 'attendance.approve'))
    ) d;
    if v_diff > 0 then raise exception '% approvable reports differ by %', v_viewer.label, v_diff; end if;

    select count(*) into v_diff from (
      (select t.id from public.tasks t join public.workflow_statuses s on s.id = t.status_id
       where t.archived_at is null and s.category = 'in_review' and t.approval_required and t.approval_state = 'pending'
         and (t.reviewer_id = v_viewer.id or app.is_super_admin(v_viewer.id)
              or (t.reviewer_id is null and t.project_id is null and app.is_team_approver(app.primary_team(t.primary_assignee_id), v_viewer.id))
              or (t.reviewer_id is null and t.project_id is not null and exists (select 1 from public.project_members m where m.project_id = t.project_id and m.profile_id = v_viewer.id and m.removed_at is null and m.member_role in ('manager','reviewer'))))
       except
       select t.id from public.tasks t join public.workflow_statuses s on s.id = t.status_id
       where t.archived_at is null and s.category = 'in_review' and t.approval_required and t.approval_state = 'pending'
         and (t.reviewer_id = v_viewer.id or app.is_super_admin(v_viewer.id)
              or (t.reviewer_id is null and t.project_id is null and app.primary_team(t.primary_assignee_id) = any(app.dash_approver_teams()))
              or (t.reviewer_id is null and t.project_id is not null and exists (select 1 from public.project_members m where m.project_id = t.project_id and m.profile_id = v_viewer.id and m.removed_at is null and m.member_role in ('manager','reviewer')))))
    ) d;
    if v_diff > 0 then raise exception '% task review rows differ by %', v_viewer.label, v_diff; end if;

    v_checked := v_checked + 1;
  end loop;
  if v_checked < 15 then
    raise exception 'expected at least 15 active viewers, checked %', v_checked;
  end if;
  raise notice 'dashboard_split: % viewers equal on output and scopes', v_checked;
end
$$;

-- 4. Negative and named checks: nothing new became visible.
do $$
declare
  v jsonb;
  v_ids uuid[];
begin
  -- Manager of t1 sees t1 people and self, never t2/t3 or the other workspace.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000003', true);
  v_ids := array(select app.dash_attendance_profiles());
  if 'c1000000-0000-4000-8000-000000000004' = any(v_ids) or 'c1000000-0000-4000-8000-000000000014' = any(v_ids)
     or 'c1000000-0000-4000-8000-000000000017' = any(v_ids) then
    raise exception 'manager t1 sees outside t1';
  end if;
  if not ('c1000000-0000-4000-8000-000000000001' = any(v_ids)) then
    raise exception 'manager t1 lost its own team';
  end if;
  -- The employee's extra non-primary membership in t2 does not make them t2's.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000005', true);
  if 'c1000000-0000-4000-8000-000000000001' = any(array(select app.dash_attendance_profiles())) then
    raise exception 'supervisor t2 sees a non-primary member';
  end if;
  -- Revoked manager approves nothing.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000007', true);
  if cardinality(app.dash_approver_teams()) <> 0 then raise exception 'revoked assignment still counts'; end if;
  -- No role, no scope: no team, no projects, empty queues.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000009', true);
  v := public.dashboard_summary();
  if v->'team' <> 'null'::jsonb or v->'projects' <> 'null'::jsonb then raise exception 'no-scope user sees team or projects: %', v; end if;
  if (select sum(value::int) from jsonb_each_text(v->'queues')) <> 0 then raise exception 'no-scope user has queue items: %', v->'queues'; end if;
  -- Custom role: team attendance only. No employee permission, so the
  -- employee count stays 0 while attendance figures cover t2.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000008', true);
  v := public.dashboard_team();
  if (v->>'employees')::int <> 0 then raise exception 'custom role counts employees: %', v; end if;
  if (v->>'pending_reports')::int = 0 then raise exception 'custom role lost its t2 reports'; end if;
  if (public.dashboard_queues()->>'disputes')::int <> 0 then raise exception 'custom role sees disputes'; end if;
  -- Other workspace: only itself.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000014', true);
  if public.dashboard_team() is not null then raise exception 'foreign user sees a team section'; end if;
  -- General admin of this workspace never sees the other workspace's person.
  perform set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000011', true);
  if 'c1000000-0000-4000-8000-000000000014' = any(array(select app.dash_attendance_profiles()))
     or 'c1000000-0000-4000-8000-000000000014' = any(array(select app.dash_employee_profiles())) then
    raise exception 'general admin sees another workspace';
  end if;
end
$$;

-- 5. EXECUTE grants: the sections are public to signed-in users, the
-- reference and the scopes are not.
select set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000001', true);
set local role authenticated;
select (public.dashboard_personal() is not null) as personal_ok,
       (public.dashboard_queues() is not null) as queues_ok,
       (public.dashboard_summary() ? 'personal') as summary_ok;
do $$
declare v_fn text;
begin
  foreach v_fn in array array['app.dashboard_summary_v1()', 'app.dash_approver_teams()', 'app.dash_attendance_profiles()', 'app.dash_employee_profiles()', 'app.dash_approval_scope(''attendance.approve'')'] loop
    begin
      execute 'select ' || v_fn;
      raise exception 'authenticated can call %', v_fn;
    exception when insufficient_privilege then
      null;
    end;
  end loop;
end
$$;
reset role;
set local role anon;
do $$
begin
  perform public.dashboard_summary();
  raise exception 'anon can call dashboard_summary';
exception when insufficient_privilege then
  null;
end
$$;
reset role;

rollback;
\echo 'DASHBOARD SPLIT TESTS PASSED'
