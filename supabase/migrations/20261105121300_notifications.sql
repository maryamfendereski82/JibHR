-- One inbox. Existing writers stay; missing events call the same app.notify.
-- A repeated decision is already rejected, so it does not insert a second row.
-- Report outcome is sent once, when the report status actually changes.

create or replace function app.notify_project_managers(
  p_workspace uuid,
  p_project uuid,
  p_category text,
  p_title text,
  p_body text,
  p_entity_type text,
  p_entity_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
begin
  for v_person in
    select profile_id
    from public.project_members
    where project_id = p_project
      and removed_at is null
      and member_role = 'manager'
      and profile_id is distinct from auth.uid()
  loop
    perform app.notify(p_workspace, v_person, p_category, p_title, p_body, p_entity_type, p_entity_id);
  end loop;
end;
$$;

revoke all on function app.notify_project_managers(uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;

create or replace function app.notify_sprint_closed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.notify_project_managers(
    new.workspace_id, new.project_id, 'sprint',
    'اسپرینت تمام شد', new.name, 'sprint', new.id
  );
  return new;
end;
$$;

create or replace function app.notify_milestone_reached()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.notify_project_managers(
    new.workspace_id, new.project_id, 'milestone',
    'مایلستون تکمیل شد', new.title, 'milestone', new.id
  );
  return new;
end;
$$;

revoke all on function app.notify_sprint_closed() from public, anon, authenticated;
revoke all on function app.notify_milestone_reached() from public, anon, authenticated;

create trigger sprints_notify_closed
  after update of status on public.sprints
  for each row
  when (old.status is distinct from new.status and new.status = 'closed')
  execute function app.notify_sprint_closed();

create trigger milestones_notify_reached
  after update of status on public.milestones
  for each row
  when (old.status is distinct from new.status and new.status = 'reached')
  execute function app.notify_milestone_reached();

create or replace function app.submit_report_for(
  p_profile uuid,
  p_date date,
  p_source text,
  p_actor uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
  v_team uuid;
  v_seq integer;
  v_kind text;
  v_report uuid;
  v_segment uuid;
  v_title text;
begin
  if p_source not in ('manual', 'automatic') then
    raise exception 'invalid_source';
  end if;
  select workspace_id into v_workspace from public.profiles where id = p_profile;
  perform 1 from public.profiles where id = p_profile for update;
  v_team := app.primary_team(p_profile);
  if v_team is null then
    raise exception 'primary_team_required';
  end if;

  if not exists (
    select 1
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    where s.profile_id = p_profile
      and s.tehran_date = p_date
      and s.approval_mode = 'report'
      and s.superseded_at is null
      and i.status <> 'void'
      and not exists (
        select 1 from public.attendance_report_items ri where ri.segment_id = s.id
      )
  ) then
    return null;
  end if;

  select coalesce(max(sequence), 0) into v_seq
  from public.attendance_daily_reports
  where profile_id = p_profile and tehran_date = p_date;
  v_seq := v_seq + 1;
  v_kind := case
    when v_seq > 1 then 'supplemental'
    when p_source = 'automatic' then 'automatic'
    else 'primary'
  end;
  v_title := case
    when v_kind = 'supplemental' then 'گزارش تکمیلی حضور'
    else 'گزارش روزانه حضور'
  end;

  insert into public.attendance_daily_reports (
    workspace_id, profile_id, team_id, tehran_date, sequence, kind, submission_source
  ) values (
    v_workspace, p_profile, v_team, p_date, v_seq, v_kind, p_source
  ) returning id into v_report;

  for v_segment in
    select s.id
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    where s.profile_id = p_profile
      and s.tehran_date = p_date
      and s.approval_mode = 'report'
      and s.superseded_at is null
      and i.status <> 'void'
      and not exists (
        select 1 from public.attendance_report_items ri where ri.segment_id = s.id
      )
  loop
    insert into public.attendance_report_items (report_id, segment_id) values (v_report, v_segment);
  end loop;

  perform app.notify_team_approvers(
    v_workspace, v_team, 'attendance', v_title,
    'یک گزارش حضور و غیاب در صف بررسی است.',
    'attendance_report', v_report
  );
  perform app.audit(
    v_workspace, p_actor, 'attendance.report_submit', 'attendance_report', v_report,
    jsonb_build_object('date', p_date, 'kind', v_kind, 'source', p_source)
  );
  return v_report;
end;
$$;

create or replace function public.decide_attendance_item(
  p_item uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.attendance_report_items%rowtype;
  v_report public.attendance_daily_reports%rowtype;
  v_before text;
  v_after text;
  v_title text;
begin
  perform app.require_active();
  if p_decision not in ('approved', 'needs_revision', 'rejected') then
    raise exception 'invalid_decision';
  end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;

  select * into v_item from public.attendance_report_items where id = p_item for update;
  if not found then
    raise exception 'not_found';
  end if;
  if v_item.decision <> 'pending' then
    raise exception 'already_decided';
  end if;
  select * into v_report from public.attendance_daily_reports where id = v_item.report_id for update;
  if not app.can_approve_team(v_report.team_id, 'attendance.approve') then
    raise exception 'forbidden';
  end if;
  v_before := v_report.status;

  update public.attendance_report_items
    set decision = p_decision,
        decided_by = auth.uid(),
        decided_at = clock_timestamp(),
        reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_item;
  perform app.rollup_report(v_report.id);
  select status into v_after from public.attendance_daily_reports where id = v_report.id;
  if v_after is distinct from v_before and v_after in ('approved', 'partially_approved', 'rejected') then
    v_title := case v_after
      when 'approved' then 'گزارش حضور تأیید شد'
      when 'rejected' then 'گزارش حضور رد شد'
      else 'گزارش حضور بخشی تأیید شد'
    end;
    perform app.notify(
      v_report.workspace_id, v_report.profile_id, 'attendance', v_title,
      'نتیجه بررسی گزارش حضور آماده است.',
      'attendance_report', v_report.id
    );
  end if;
  perform app.audit(
    v_report.workspace_id, auth.uid(), 'attendance.decide', 'attendance_report_item', p_item,
    jsonb_build_object('decision', p_decision)
  );
end;
$$;

create or replace function public.decide_attendance_correction(
  p_correction uuid,
  p_approve boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.attendance_corrections%rowtype;
  v_interval public.attendance_intervals%rowtype;
  v_new uuid;
begin
  perform app.require_active();
  select * into v_row from public.attendance_corrections where id = p_correction for update;
  if not found then
    raise exception 'not_found';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'already_decided';
  end if;
  if not app.can_approve_team(v_row.team_id, 'attendance.approve') then
    raise exception 'forbidden';
  end if;

  if not p_approve then
    if char_length(trim(coalesce(p_reason, ''))) = 0 then
      raise exception 'reason_required';
    end if;
    update public.attendance_corrections
      set status = 'rejected', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_reason = trim(p_reason)
    where id = p_correction;
  else
    if v_row.kind = 'missing_in' then
      insert into public.attendance_intervals (
        workspace_id, profile_id, origin, status,
        original_started_at, original_ended_at, effective_started_at, effective_ended_at,
        end_platform
      ) values (
        v_row.workspace_id, v_row.profile_id, 'approved_correction', 'closed',
        v_row.proposed_started_at, v_row.proposed_ended_at,
        v_row.proposed_started_at, v_row.proposed_ended_at,
        'correction'
      ) returning id into v_new;
      perform app.materialize_segments(v_new, 'correction', p_correction);
      update public.attendance_corrections set interval_id = v_new where id = p_correction;
    elsif v_row.kind = 'delete_interval' then
      perform app.supersede_segments(v_row.interval_id);
      update public.attendance_intervals set status = 'void' where id = v_row.interval_id;
    else
      select * into v_interval from public.attendance_intervals where id = v_row.interval_id for update;
      if v_row.kind = 'missing_out' or v_row.kind = 'edit_out' then
        update public.attendance_intervals
          set effective_ended_at = v_row.proposed_ended_at,
              status = 'closed',
              end_platform = coalesce(end_platform, 'correction')
        where id = v_interval.id;
      elsif v_row.kind = 'edit_in' then
        update public.attendance_intervals
          set effective_started_at = v_row.proposed_started_at
        where id = v_interval.id;
      end if;
      perform app.supersede_segments(v_interval.id);
      perform app.materialize_segments(v_interval.id, 'correction', p_correction);
    end if;
    update public.attendance_corrections
      set status = 'approved', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_reason = nullif(trim(coalesce(p_reason, '')), '')
    where id = p_correction;
  end if;

  insert into public.attendance_events (
    workspace_id, profile_id, interval_id, event_type, metadata
  ) values (
    v_row.workspace_id, v_row.profile_id, coalesce(v_new, v_row.interval_id), 'correction_decided',
    jsonb_build_object('correction_id', p_correction, 'approved', p_approve)
  );
  perform app.notify(
    v_row.workspace_id, v_row.profile_id, 'attendance',
    case when p_approve then 'اصلاح حضور تأیید شد' else 'اصلاح حضور رد شد' end,
    'درخواست اصلاح حضور و غیاب بررسی شد.',
    'attendance_correction', p_correction
  );
  perform app.audit(
    v_row.workspace_id, auth.uid(), 'attendance.correction_decide', 'attendance_correction', p_correction,
    jsonb_build_object('approved', p_approve)
  );
end;
$$;

create or replace function public.decide_leave(p_request uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.leave_requests%rowtype;
begin
  perform app.require_active();
  if not p_approve and char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;
  select * into v_row from public.leave_requests where id = p_request for update;
  if not found then
    raise exception 'not_found';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'already_decided';
  end if;
  if not app.can_approve_team(v_row.team_id, 'leave.approve') then
    raise exception 'forbidden';
  end if;
  update public.leave_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        decided_by = auth.uid(),
        decided_at = clock_timestamp(),
        decision_reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_request;
  perform app.notify(
    v_row.workspace_id, v_row.profile_id, 'leave',
    case when p_approve then 'مرخصی تأیید شد' else 'مرخصی رد شد' end,
    'درخواست مرخصی بررسی شد.',
    'leave_request', p_request
  );
  perform app.audit(v_row.workspace_id, auth.uid(), 'leave.decide', 'leave_request', p_request, jsonb_build_object('approved', p_approve));
end;
$$;

create or replace function public.decide_absence_dispute(
  p_dispute uuid,
  p_accept boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dispute public.absence_disputes%rowtype;
  v_absence public.absence_records%rowtype;
  v_allowed boolean;
begin
  perform app.require_active();
  if not p_accept and char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;
  select * into v_dispute from public.absence_disputes where id = p_dispute for update;
  if not found then
    raise exception 'not_found';
  end if;
  if v_dispute.status <> 'pending' then
    raise exception 'already_decided';
  end if;
  select * into v_absence from public.absence_records where id = v_dispute.absence_id;
  v_allowed := app.has_permission('absence.record.all')
    or (
      app.has_permission('absence.record.team')
      and app.is_team_approver(v_absence.team_id, auth.uid())
    );
  if not v_allowed then
    raise exception 'forbidden';
  end if;
  update public.absence_disputes
    set status = case when p_accept then 'accepted' else 'rejected' end,
        decided_by = auth.uid(),
        decided_at = clock_timestamp(),
        decision_reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_dispute;
  perform app.notify(
    v_absence.workspace_id, v_absence.profile_id, 'absence',
    case when p_accept then 'توضیح غیبت پذیرفته شد' else 'توضیح غیبت رد شد' end,
    'توضیح شما درباره غیبت بررسی شد.',
    'absence_dispute', p_dispute
  );
  perform app.audit(
    v_absence.workspace_id, auth.uid(), 'absence.dispute_decide', 'absence_dispute', p_dispute,
    jsonb_build_object('accepted', p_accept)
  );
end;
$$;

create or replace function public.create_task(
  p_title text,
  p_description text,
  p_project uuid,
  p_assignee uuid,
  p_priority text default 'medium',
  p_due timestamptz default null,
  p_approval boolean default null,
  p_reviewer uuid default null,
  p_parent uuid default null,
  p_required boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid := app.current_workspace();
  v_assignee uuid := coalesce(p_assignee, auth.uid());
  v_workflow uuid;
  v_status uuid;
  v_approval boolean;
  v_id uuid;
  v_parent_project uuid;
begin
  perform app.require_active();
  if p_priority not in ('low', 'medium', 'high', 'critical') then
    raise exception 'invalid_priority';
  end if;

  if p_project is null then
    if v_assignee = auth.uid() then
      perform app.require_permission('tasks.create.personal');
    elsif not (
      app.is_team_approver(app.primary_team(v_assignee), auth.uid())
      or app.has_permission('tasks.view.all')
    ) then
      raise exception 'forbidden';
    end if;
    select id into v_workflow from public.workflows
    where workspace_id = v_workspace and project_id is null;
    v_approval := coalesce(p_approval, false);
  else
    perform app.require_permission('tasks.create.project');
    if not (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members
        where project_id = p_project and profile_id = auth.uid() and removed_at is null
          and member_role = 'manager'
      )
    ) then
      raise exception 'forbidden';
    end if;
    select id into v_workflow from public.workflows where project_id = p_project;
    select approval_required into v_approval from public.projects where id = p_project;
    if p_approval is not null and (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members
        where project_id = p_project and profile_id = auth.uid() and removed_at is null
          and member_role = 'manager'
      )
    ) then
      v_approval := p_approval;
    end if;
  end if;

  if p_parent is not null then
    select project_id into v_parent_project from public.tasks where id = p_parent;
    if v_parent_project is distinct from p_project then
      raise exception 'parent_project_mismatch';
    end if;
    if exists (
      select 1 from public.tasks where id = p_parent and parent_task_id is not null
    ) then
      raise exception 'nesting_limit';
    end if;
  end if;

  select id into v_status from public.workflow_statuses
  where workflow_id = v_workflow and key = 'backlog';
  if v_status is null then
    raise exception 'workflow_missing';
  end if;

  insert into public.tasks (
    workspace_id, project_id, parent_task_id, title, description,
    primary_assignee_id, reviewer_id, status_id, priority, due_at,
    approval_required, approval_state, is_required, created_by
  ) values (
    v_workspace, p_project, p_parent, trim(p_title), coalesce(p_description, ''),
    v_assignee, p_reviewer,
    v_status, p_priority, p_due,
    v_approval, case when v_approval then 'pending' else 'not_required' end,
    p_parent is not null and p_required, auth.uid()
  ) returning id into v_id;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_workspace, v_id, auth.uid(), 'task.create', jsonb_build_object('assignee', v_assignee));
  if p_parent is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_workspace, p_parent, auth.uid(), 'task.subtask', jsonb_build_object('child', v_id));
  end if;
  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);
  if v_assignee <> auth.uid() then
    perform app.notify(v_workspace, v_assignee, 'task', 'تسک جدید', 'یک تسک به شما سپرده شد.', 'task', v_id);
  end if;
  return v_id;
end;
$$;

create or replace function public.add_project_member(p_project uuid, p_profile uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_workspace uuid;
begin
  perform app.require_permission('projects.edit');
  if p_role not in ('manager', 'reviewer', 'member') then
    raise exception 'invalid_role';
  end if;
  select name, workspace_id into v_name, v_workspace from public.projects where id = p_project;
  if not exists (
    select 1 from public.project_members
    where project_id = p_project and profile_id = p_profile and removed_at is null
  ) then
    insert into public.project_members (project_id, profile_id, member_role)
    values (p_project, p_profile, p_role);
    if p_profile is distinct from auth.uid() and v_workspace is not null then
      perform app.notify(v_workspace, p_profile, 'project', 'به پروژه اضافه شدید', v_name, 'project', p_project);
    end if;
  else
    update public.project_members
      set member_role = p_role
    where project_id = p_project and profile_id = p_profile and removed_at is null;
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member', 'project', p_project, jsonb_build_object('profile_id', p_profile, 'role', p_role));
end;
$$;

create or replace function public.remove_project_member(p_project uuid, p_profile uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_managers integer;
  v_workspace uuid;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  select workspace_id into v_workspace from public.projects where id = p_project;
  select member_role into v_role
  from public.project_members
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if v_role is null then
    raise exception 'not_found';
  end if;
  if v_role = 'manager' then
    select count(*) into v_managers
    from public.project_members
    where project_id = p_project and member_role = 'manager' and removed_at is null;
    if v_managers <= 1 then
      raise exception 'last_manager';
    end if;
  end if;
  update public.project_members
    set removed_at = clock_timestamp()
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if p_profile is distinct from auth.uid() and v_workspace is not null then
    perform app.notify(
      v_workspace, p_profile, 'project',
      'از پروژه برداشته شدید', 'عضویت شما در یک پروژه پایان یافت.',
      'project', p_project
    );
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member_remove', 'project', p_project, jsonb_build_object('profile_id', p_profile));
end;
$$;

create or replace function public.update_task(
  p_task uuid,
  p_title text,
  p_description text,
  p_assignee uuid,
  p_reviewer uuid,
  p_priority text,
  p_due timestamptz,
  p_approval boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks%rowtype;
  v_state text;
begin
  perform app.require_active();
  if p_priority not in ('low', 'medium', 'high', 'critical') then
    raise exception 'invalid_priority';
  end if;
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  if v_task.primary_assignee_id <> auth.uid()
     and not app.has_permission('tasks.manage.project')
     and not app.is_team_approver(app.primary_team(v_task.primary_assignee_id), auth.uid())
  then
    raise exception 'forbidden';
  end if;

  v_state := v_task.approval_state;
  if p_approval and not v_task.approval_required then
    v_state := case when v_task.approval_state = 'approved' then 'approved' else 'pending' end;
  elsif not p_approval and v_task.approval_required and v_task.approval_state = 'pending' then
    v_state := 'not_required';
  end if;

  if v_task.title is distinct from trim(p_title) or v_task.description is distinct from coalesce(p_description, '') then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.update');
  end if;
  if v_task.primary_assignee_id is distinct from p_assignee then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.assign', jsonb_build_object('assignee', p_assignee));
    if p_assignee is distinct from auth.uid() then
      perform app.notify(v_task.workspace_id, p_assignee, 'task', 'مسئول تسک عوض شد', 'مسئولیت یک تسک به شما سپرده شد.', 'task', p_task);
    end if;
  end if;
  if v_task.priority is distinct from p_priority then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.priority', jsonb_build_object('priority', p_priority));
  end if;
  if v_task.due_at is distinct from p_due then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.due');
  end if;
  if v_task.reviewer_id is distinct from p_reviewer or v_task.approval_required is distinct from p_approval then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.approval', jsonb_build_object('required', p_approval));
  end if;

  update public.tasks
    set title = trim(p_title),
        description = coalesce(p_description, ''),
        primary_assignee_id = p_assignee,
        reviewer_id = p_reviewer,
        priority = p_priority,
        due_at = p_due,
        approval_required = p_approval,
        approval_state = v_state
  where id = p_task;
end;
$$;

create or replace function public.add_task_collaborator(p_task uuid, p_profile uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_workspace uuid;
  v_inserted integer;
begin
  perform app.require_active();
  select project_id, workspace_id into v_project, v_workspace
  from public.tasks where id = p_task;
  if v_project is null then
    raise exception 'personal_task';
  end if;
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  insert into public.task_collaborators (task_id, profile_id)
  values (p_task, p_profile)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted > 0 and p_profile is distinct from auth.uid() then
    perform app.notify(v_workspace, p_profile, 'task', 'همکار تسک شدید', 'به یک تسک به‌عنوان همکار اضافه شدید.', 'task', p_task);
  end if;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));
end;
$$;

create or replace function public.transition_task(
  p_task uuid,
  p_status uuid,
  p_override_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks%rowtype;
  v_from uuid;
  v_category text;
  v_current text;
  v_authority boolean;
  v_active boolean;
  v_round integer;
  v_person uuid;
begin
  perform app.require_active();
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  if v_task.primary_assignee_id <> auth.uid()
     and not app.has_permission('tasks.manage.project')
     and not app.is_team_approver(app.primary_team(v_task.primary_assignee_id), auth.uid())
  then
    raise exception 'forbidden';
  end if;

  select category into v_current from public.workflow_statuses where id = v_task.status_id;
  if v_current = 'rejected'
     and not (app.has_permission('tasks.manage.project') or app.has_permission('tasks.view.all'))
  then
    raise exception 'rejected_closed';
  end if;

  v_from := v_task.status_id;
  if not exists (
    select 1 from public.workflow_transitions
    where from_status_id = v_from and to_status_id = p_status
  ) then
    raise exception 'transition_denied';
  end if;

  select category, requires_authority, is_active into v_category, v_authority, v_active
  from public.workflow_statuses where id = p_status;
  if not coalesce(v_active, false) then
    raise exception 'status_inactive';
  end if;

  if v_authority
     and v_task.approval_required
     and v_task.approval_state <> 'approved'
     and v_category in ('approved', 'done', 'changes_requested', 'rejected')
  then
    raise exception 'approval_required';
  end if;

  if v_category = 'done' and app.task_children_block_done(p_task) then
    if p_override_reason is null or char_length(trim(p_override_reason)) = 0 then
      raise exception 'subtasks_incomplete';
    end if;
    if not (app.has_permission('tasks.manage.project') or app.has_permission('tasks.view.all')) then
      raise exception 'forbidden';
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks', 'task', p_task, jsonb_build_object('reason', trim(p_override_reason)));
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.override', jsonb_build_object('reason', trim(p_override_reason)));
  end if;

  update public.tasks set status_id = p_status where id = p_task;

  if v_category = 'in_review' and v_task.approval_required then
    select coalesce(max(round_number), 0) + 1 into v_round
    from public.task_review_rounds where task_id = p_task;
    if not exists (
      select 1
      from public.task_review_rounds round
      where round.task_id = p_task
        and not exists (select 1 from public.task_reviews review where review.round_id = round.id)
    ) then
      insert into public.task_review_rounds (task_id, round_number) values (p_task, v_round);
    end if;
    update public.tasks set approval_state = 'pending' where id = p_task;
    if v_task.reviewer_id is not null then
      if v_task.reviewer_id is distinct from auth.uid() then
        perform app.notify(
          v_task.workspace_id, v_task.reviewer_id, 'task',
          'تسک برای بررسی', 'یک تسک برای بررسی شما فرستاده شد.',
          'task', p_task
        );
      end if;
    elsif v_task.project_id is null then
      perform app.notify_team_approvers(
        v_task.workspace_id, app.primary_team(v_task.primary_assignee_id), 'task',
        'تسک برای بررسی', 'یک تسک برای بررسی فرستاده شد.',
        'task', p_task
      );
    else
      for v_person in
        select profile_id from public.project_members
        where project_id = v_task.project_id
          and removed_at is null
          and member_role in ('manager', 'reviewer')
          and profile_id is distinct from auth.uid()
      loop
        perform app.notify(
          v_task.workspace_id, v_person, 'task',
          'تسک برای بررسی', 'یک تسک برای بررسی فرستاده شد.',
          'task', p_task
        );
      end loop;
    end if;
  end if;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition', jsonb_build_object('to', p_status));
  if v_category = 'done' and v_task.parent_task_id is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, v_task.parent_task_id, auth.uid(), 'task.subtask_done', jsonb_build_object('child', p_task));
  end if;
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.transition', 'task', p_task, jsonb_build_object('status', p_status));
end;
$$;

create or replace function public.decide_task(
  p_task uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks%rowtype;
  v_round uuid;
  v_status uuid;
  v_eligible boolean := false;
  v_title text;
  v_person uuid;
begin
  perform app.require_active();
  if p_decision not in ('approved', 'revision_requested', 'rejected') then
    raise exception 'invalid_decision';
  end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;

  select * into v_task from public.tasks where id = p_task for update;
  if not found then
    raise exception 'not_found';
  end if;
  if not v_task.approval_required then
    raise exception 'not_required';
  end if;

  if v_task.reviewer_id is not null then
    v_eligible := v_task.reviewer_id = auth.uid() or app.is_super_admin(auth.uid());
  elsif v_task.project_id is null then
    v_eligible := app.is_team_approver(app.primary_team(v_task.primary_assignee_id), auth.uid())
      or app.is_super_admin(auth.uid());
  else
    v_eligible := app.is_super_admin(auth.uid()) or exists (
      select 1 from public.project_members
      where project_id = v_task.project_id
        and profile_id = auth.uid()
        and removed_at is null
        and member_role in ('manager', 'reviewer')
    );
  end if;
  if not v_eligible then
    raise exception 'forbidden';
  end if;

  select id into v_round
  from public.task_review_rounds
  where task_id = p_task
    and not exists (select 1 from public.task_reviews review where review.round_id = task_review_rounds.id)
  order by round_number desc
  limit 1
  for update;
  if v_round is null then
    if exists (
      select 1
      from public.task_reviews review
      join public.task_review_rounds round on round.id = review.round_id
      where round.task_id = p_task
    ) then
      raise exception 'already_decided';
    end if;
    raise exception 'not_submitted';
  end if;

  begin
    insert into public.task_reviews (round_id, reviewer_id, decision, reason)
    values (v_round, auth.uid(), p_decision, nullif(trim(coalesce(p_reason, '')), ''));
  exception
    when unique_violation then
      raise exception 'already_decided';
  end;

  select id into v_status
  from public.workflow_statuses
  where workflow_id = (select workflow_id from public.workflow_statuses where id = v_task.status_id)
    and key = case p_decision
      when 'approved' then 'approved'
      when 'revision_requested' then 'changes_requested'
      else 'rejected'
    end;

  update public.tasks
    set approval_state = case p_decision
          when 'approved' then 'approved'
          when 'revision_requested' then 'changes_requested'
          else 'rejected'
        end,
        status_id = v_status
  where id = p_task;

  v_title := case p_decision
    when 'approved' then 'تسک تأیید شد'
    when 'revision_requested' then 'تسک برای اصلاح برگشت'
    else 'تسک رد شد'
  end;
  if v_task.primary_assignee_id is distinct from auth.uid() then
    perform app.notify(v_task.workspace_id, v_task.primary_assignee_id, 'task', v_title, 'نتیجه بررسی تسک آماده است.', 'task', p_task);
  end if;
  for v_person in
    select profile_id from public.task_collaborators
    where task_id = p_task
      and profile_id is distinct from auth.uid()
      and profile_id is distinct from v_task.primary_assignee_id
  loop
    perform app.notify(v_task.workspace_id, v_person, 'task', v_title, 'نتیجه بررسی تسک آماده است.', 'task', p_task);
  end loop;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.review', jsonb_build_object('decision', p_decision));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.review', 'task', p_task, jsonb_build_object('decision', p_decision));
end;
$$;

create or replace function public.mark_all_notifications_read()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  update public.notifications
    set read_at = clock_timestamp()
  where recipient_id = auth.uid() and read_at is null;
end;
$$;

revoke all on function public.mark_all_notifications_read() from public, anon;
grant execute on function public.mark_all_notifications_read() to authenticated, service_role;

alter table public.notifications replica identity full;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'notifications'
    ) then
      alter publication supabase_realtime add table public.notifications;
    end if;
  end if;
end
$$;
