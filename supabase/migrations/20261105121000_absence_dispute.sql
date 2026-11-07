-- The dispute row is the history. Deciding it does not rewrite the absence.
-- Authorization matches record_absence: the team stored on the absence, not a later team.

create or replace function public.dispute_absence(p_absence uuid, p_explanation text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.absence_records%rowtype;
  v_id uuid;
begin
  perform app.require_active();
  if char_length(trim(coalesce(p_explanation, ''))) = 0 then
    raise exception 'reason_required';
  end if;
  select * into v_row from public.absence_records where id = p_absence;
  if v_row.id is null or v_row.profile_id <> auth.uid() then
    raise exception 'forbidden';
  end if;
  insert into public.absence_disputes (absence_id, profile_id, explanation)
  values (p_absence, auth.uid(), trim(p_explanation))
  returning id into v_id;
  perform app.notify_team_approvers(
    v_row.workspace_id, v_row.team_id, 'absence',
    'درخواست بررسی غیبت', 'کارمند برای یک غیبت توضیح ثبت کرد.',
    'absence_dispute', v_id
  );
  perform app.audit(v_row.workspace_id, auth.uid(), 'absence.dispute', 'absence_dispute', v_id, jsonb_build_object('absence_id', p_absence));
  return v_id;
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
    'نتیجه بررسی غیبت', 'توضیح شما درباره غیبت بررسی شد.',
    'absence_dispute', p_dispute
  );
  perform app.audit(
    v_absence.workspace_id, auth.uid(), 'absence.dispute_decide', 'absence_dispute', p_dispute,
    jsonb_build_object('accepted', p_accept)
  );
end;
$$;

revoke all on function public.decide_absence_dispute(uuid, boolean, text) from public, anon;
grant execute on function public.decide_absence_dispute(uuid, boolean, text) to authenticated, service_role;
