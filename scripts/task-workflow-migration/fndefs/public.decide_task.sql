CREATE OR REPLACE FUNCTION public.decide_task(p_task uuid, p_decision text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
