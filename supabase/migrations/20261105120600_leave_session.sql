-- Leave has no quota and no type. Absence is entered by a person, never inferred
-- from a missing clock-in. Neither path rewrites attendance intervals.

create or replace function app.can_view_leave(p_profile uuid, p_team uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.is_active() and (
    p_profile = auth.uid()
    or app.has_permission('leave.view.all')
    or (
      app.has_permission('leave.view.team')
      and app.is_team_approver(p_team, auth.uid())
    )
  );
$$;

create or replace function app.can_view_absence(p_profile uuid, p_team uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.is_active() and (
    p_profile = auth.uid()
    or app.has_permission('absence.view.all')
    or (
      app.has_permission('absence.view.team')
      and app.is_team_approver(p_team, auth.uid())
    )
  );
$$;

create or replace function public.request_leave(
  p_kind text,
  p_start_date date default null,
  p_end_date date default null,
  p_hours_date date default null,
  p_start_time time default null,
  p_end_time time default null,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team uuid;
  v_id uuid;
begin
  perform app.require_permission('leave.request');
  if p_kind not in ('daily', 'hourly') then
    raise exception 'invalid_kind';
  end if;
  v_team := app.primary_team(auth.uid());
  if v_team is null then
    raise exception 'primary_team_required';
  end if;
  insert into public.leave_requests (
    workspace_id, profile_id, team_id, kind,
    start_date, end_date, hours_date, start_time, end_time, note
  ) values (
    app.current_workspace(), auth.uid(), v_team, p_kind,
    case when p_kind = 'daily' then p_start_date end,
    case when p_kind = 'daily' then p_end_date end,
    case when p_kind = 'hourly' then p_hours_date end,
    case when p_kind = 'hourly' then p_start_time end,
    case when p_kind = 'hourly' then p_end_time end,
    coalesce(p_note, '')
  ) returning id into v_id;
  perform app.notify_team_approvers(
    app.current_workspace(), v_team, 'leave',
    'درخواست مرخصی', 'یک درخواست مرخصی در صف بررسی است.',
    'leave_request', v_id
  );
  perform app.audit(app.current_workspace(), auth.uid(), 'leave.request', 'leave_request', v_id, jsonb_build_object('kind', p_kind));
  return v_id;
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
    'نتیجه درخواست مرخصی', 'درخواست مرخصی بررسی شد.',
    'leave_request', p_request
  );
  perform app.audit(v_row.workspace_id, auth.uid(), 'leave.decide', 'leave_request', p_request, jsonb_build_object('approved', p_approve));
end;
$$;

create or replace function public.record_absence(
  p_profile uuid,
  p_start date,
  p_end date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team uuid;
  v_id uuid;
  v_allowed boolean;
begin
  perform app.require_active();
  if char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;
  if p_end < p_start then
    raise exception 'invalid_range';
  end if;
  v_team := app.primary_team(p_profile);
  if v_team is null then
    raise exception 'primary_team_required';
  end if;
  v_allowed := app.has_permission('absence.record.all')
    or (
      app.has_permission('absence.record.team')
      and app.is_team_approver(v_team, auth.uid())
    );
  if not v_allowed then
    raise exception 'forbidden';
  end if;
  insert into public.absence_records (
    workspace_id, profile_id, team_id, start_date, end_date, reason, recorded_by
  ) values (
    app.current_workspace(), p_profile, v_team, p_start, p_end, trim(p_reason), auth.uid()
  ) returning id into v_id;
  perform app.notify(
    app.current_workspace(), p_profile, 'absence',
    'ثبت غیبت', 'یک غیبت برای شما ثبت شد.',
    'absence', v_id
  );
  perform app.audit(app.current_workspace(), auth.uid(), 'absence.record', 'absence', v_id, jsonb_build_object('profile_id', p_profile));
  return v_id;
end;
$$;

create or replace function public.dispute_absence(p_absence uuid, p_explanation text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_id uuid;
begin
  perform app.require_active();
  select profile_id into v_profile from public.absence_records where id = p_absence;
  if v_profile is null or v_profile <> auth.uid() then
    raise exception 'forbidden';
  end if;
  insert into public.absence_disputes (absence_id, profile_id, explanation)
  values (p_absence, auth.uid(), trim(p_explanation))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.mark_notification_read(p_notification uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  update public.notifications
    set read_at = clock_timestamp()
  where id = p_notification and recipient_id = auth.uid() and read_at is null;
end;
$$;

create or replace function public.my_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_username text;
  v_email text;
  v_position text;
  v_team uuid;
  v_team_name text;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  select * into v_profile from public.profiles where id = auth.uid();
  if not found then
    return jsonb_build_object('status', 'missing');
  end if;
  select username::text, email into v_username, v_email
  from public.profile_accounts where profile_id = auth.uid();
  select title into v_position from public.job_positions where id = v_profile.job_position_id;
  v_team := app.primary_team(auth.uid());
  select name into v_team_name from public.teams where id = v_team;
  return jsonb_build_object(
    'profile_id', v_profile.id,
    'workspace_id', v_profile.workspace_id,
    'first_name', v_profile.first_name,
    'last_name', v_profile.last_name,
    'username', v_username,
    'email', v_email,
    'status', v_profile.status,
    'must_change_password', v_profile.must_change_password,
    'position', v_position,
    'team_id', v_team,
    'team_name', v_team_name,
    'roles', coalesce((
      select jsonb_agg(r.key order by r.key)
      from public.user_roles ur
      join public.roles r on r.id = ur.role_id
      where ur.profile_id = auth.uid() and ur.revoked_at is null and r.is_active
    ), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct p.key order by p.key)
      from public.user_roles ur
      join public.roles r on r.id = ur.role_id and r.is_active
      join public.role_permissions rp on rp.role_id = r.id
      join public.permissions p on p.id = rp.permission_id
      where ur.profile_id = auth.uid() and ur.revoked_at is null
    ), '[]'::jsonb)
  );
end;
$$;
