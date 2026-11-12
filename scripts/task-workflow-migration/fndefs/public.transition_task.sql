CREATE OR REPLACE FUNCTION public.transition_task(p_task uuid, p_status uuid, p_override_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
