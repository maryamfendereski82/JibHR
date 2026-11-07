-- Clock times come from clock_timestamp() inside these functions.
-- A client-supplied timestamp is not part of the signature.
-- Cross-midnight splits are reporting segments, never extra clock events.

create or replace function app.supersede_segments(p_interval uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.attendance_daily_segments
    set superseded_at = clock_timestamp()
  where interval_id = p_interval
    and superseded_at is null;
end;
$$;

create or replace function app.materialize_segments(
  p_interval uuid,
  p_mode text,
  p_correction uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_profile uuid;
  v_workspace uuid;
  v_local_start timestamp;
  v_local_end timestamp;
  v_day date;
  v_last date;
  v_seg_start timestamp;
  v_seg_end timestamp;
begin
  if p_mode not in ('report', 'correction') then
    raise exception 'invalid_mode';
  end if;
  select effective_started_at, effective_ended_at, profile_id, workspace_id
    into v_start, v_end, v_profile, v_workspace
  from public.attendance_intervals
  where id = p_interval
  for update;
  if v_start is null or v_end is null then
    raise exception 'interval_not_closed';
  end if;

  v_local_start := v_start at time zone 'Asia/Tehran';
  v_local_end := v_end at time zone 'Asia/Tehran';
  v_day := v_local_start::date;
  v_last := v_local_end::date;

  while v_day <= v_last loop
    v_seg_start := greatest(v_local_start, v_day::timestamp);
    v_seg_end := least(v_local_end, (v_day + 1)::timestamp);
    if v_seg_end > v_seg_start then
      insert into public.attendance_daily_segments (
        workspace_id, profile_id, interval_id, tehran_date,
        started_at, ended_at, approval_mode, correction_id
      ) values (
        v_workspace,
        v_profile,
        p_interval,
        v_day,
        v_seg_start at time zone 'Asia/Tehran',
        v_seg_end at time zone 'Asia/Tehran',
        p_mode,
        p_correction
      );
    end if;
    v_day := v_day + 1;
  end loop;
end;
$$;

create or replace function app.rollup_report(p_report uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_approved integer;
  v_rejected integer;
  v_revision integer;
  v_pending integer;
  v_status text;
begin
  select
    count(*)::integer,
    count(*) filter (where decision = 'approved')::integer,
    count(*) filter (where decision = 'rejected')::integer,
    count(*) filter (where decision = 'needs_revision')::integer,
    count(*) filter (where decision = 'pending')::integer
  into v_total, v_approved, v_rejected, v_revision, v_pending
  from public.attendance_report_items
  where report_id = p_report;

  v_status := case
    when v_total = 0 or v_pending = v_total then 'pending'
    when v_revision > 0 then 'needs_revision'
    when v_approved = v_total then 'approved'
    when v_rejected = v_total then 'rejected'
    else 'partially_approved'
  end;

  update public.attendance_daily_reports set status = v_status where id = p_report;
end;
$$;

create or replace function app.notify_team_approvers(
  p_workspace uuid,
  p_team uuid,
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
    from public.team_manager_assignments
    where team_id = p_team and revoked_at is null
  loop
    perform app.notify(p_workspace, v_person, p_category, p_title, p_body, p_entity_type, p_entity_id);
  end loop;
end;
$$;

-- Creates a report only when final, unreported segments exist.
-- A second call for the same segments returns null.
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
    v_workspace, v_team, 'attendance',
    'گزارش حضور برای بررسی',
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

create or replace function app.queue_supplemental_reports(p_profile uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
begin
  for v_date in
    select distinct s.tehran_date
    from public.attendance_daily_segments s
    where s.profile_id = p_profile
      and s.approval_mode = 'report'
      and s.superseded_at is null
      and exists (
        select 1 from public.attendance_daily_reports r
        where r.profile_id = p_profile and r.tehran_date = s.tehran_date
      )
      and not exists (
        select 1 from public.attendance_report_items ri where ri.segment_id = s.id
      )
  loop
    perform app.submit_report_for(p_profile, v_date, 'automatic', p_actor);
  end loop;
end;
$$;

create or replace function public.clock_in(p_platform text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_now timestamptz := clock_timestamp();
begin
  perform app.require_permission('attendance.clock');
  if p_platform not in ('android', 'ios', 'windows', 'macos', 'web', 'linux') then
    raise exception 'invalid_platform';
  end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  if exists (
    select 1 from public.attendance_intervals
    where profile_id = auth.uid() and status = 'open'
  ) then
    raise exception 'open_interval';
  end if;
  begin
    insert into public.attendance_intervals (
      workspace_id, profile_id, origin, status,
      original_started_at, effective_started_at, start_platform
    ) values (
      app.current_workspace(), auth.uid(), 'clock', 'open',
      v_now, v_now, p_platform
    ) returning id into v_id;
  exception
    when unique_violation then
      raise exception 'open_interval';
  end;
  insert into public.attendance_events (
    workspace_id, profile_id, interval_id, event_type, platform
  ) values (
    app.current_workspace(), auth.uid(), v_id, 'clock_in', p_platform
  );
  perform app.audit(app.current_workspace(), auth.uid(), 'attendance.clock_in', 'attendance_interval', v_id, jsonb_build_object('platform', p_platform));
  return v_id;
end;
$$;

create or replace function public.clock_out(p_platform text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_now timestamptz := clock_timestamp();
begin
  perform app.require_permission('attendance.clock');
  if p_platform not in ('android', 'ios', 'windows', 'macos', 'web', 'linux') then
    raise exception 'invalid_platform';
  end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  select id into v_id
  from public.attendance_intervals
  where profile_id = auth.uid() and status = 'open'
  for update;
  if v_id is null then
    raise exception 'no_open_interval';
  end if;
  update public.attendance_intervals
    set original_ended_at = v_now,
        effective_ended_at = v_now,
        status = 'closed',
        end_platform = p_platform
  where id = v_id;
  insert into public.attendance_events (
    workspace_id, profile_id, interval_id, event_type, platform
  ) values (
    app.current_workspace(), auth.uid(), v_id, 'clock_out', p_platform
  );
  perform app.materialize_segments(v_id, 'report', null);
  perform app.queue_supplemental_reports(auth.uid(), auth.uid());
  perform app.audit(app.current_workspace(), auth.uid(), 'attendance.clock_out', 'attendance_interval', v_id, jsonb_build_object('platform', p_platform));
  return v_id;
end;
$$;

create or replace function public.submit_attendance_report(p_date date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('attendance.clock');
  if p_date > app.tehran_today() then
    raise exception 'invalid_date';
  end if;
  return app.submit_report_for(auth.uid(), p_date, 'manual', auth.uid());
end;
$$;

create or replace function public.submit_due_attendance_reports()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_date date;
  v_count integer := 0;
  v_report uuid;
begin
  for v_profile, v_date in
    select distinct s.profile_id, s.tehran_date
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    where s.tehran_date < app.tehran_today()
      and s.approval_mode = 'report'
      and s.superseded_at is null
      and i.status <> 'void'
      and not exists (
        select 1 from public.attendance_report_items ri where ri.segment_id = s.id
      )
  loop
    v_report := app.submit_report_for(v_profile, v_date, 'automatic', null);
    if v_report is not null then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
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
  select * into v_report from public.attendance_daily_reports where id = v_item.report_id;
  if not app.can_approve_team(v_report.team_id, 'attendance.approve') then
    raise exception 'forbidden';
  end if;

  update public.attendance_report_items
    set decision = p_decision,
        decided_by = auth.uid(),
        decided_at = clock_timestamp(),
        reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_item;
  perform app.rollup_report(v_report.id);
  perform app.notify(
    v_report.workspace_id, v_report.profile_id, 'attendance',
    'نتیجه بررسی حضور',
    'یکی از بازه‌های گزارش حضور و غیاب بررسی شد.',
    'attendance_report', v_report.id
  );
  perform app.audit(
    v_report.workspace_id, auth.uid(), 'attendance.decide', 'attendance_report_item', p_item,
    jsonb_build_object('decision', p_decision)
  );
end;
$$;

create or replace function public.request_attendance_correction(
  p_kind text,
  p_interval uuid,
  p_proposed_start timestamptz,
  p_proposed_end timestamptz,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_interval public.attendance_intervals%rowtype;
  v_team uuid;
  v_id uuid;
begin
  perform app.require_permission('attendance.correct.self');
  if char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;
  if p_kind not in ('missing_in', 'missing_out', 'edit_in', 'edit_out', 'delete_interval') then
    raise exception 'invalid_kind';
  end if;
  v_team := app.primary_team(auth.uid());
  if v_team is null then
    raise exception 'primary_team_required';
  end if;

  if p_kind = 'missing_in' then
    if p_proposed_start is null or p_proposed_end is null or p_proposed_end <= p_proposed_start then
      raise exception 'invalid_range';
    end if;
  else
    select * into v_interval from public.attendance_intervals where id = p_interval for update;
    if not found or v_interval.profile_id <> auth.uid() then
      raise exception 'not_found';
    end if;
    if p_kind in ('missing_out', 'edit_out') and (p_proposed_end is null or p_proposed_end <= v_interval.effective_started_at) then
      raise exception 'invalid_range';
    end if;
    if p_kind = 'edit_in' and (
      p_proposed_start is null
      or v_interval.effective_ended_at is null
      or v_interval.effective_ended_at <= p_proposed_start
    ) then
      raise exception 'invalid_range';
    end if;
    if v_interval.status = 'open' and p_kind in ('missing_out', 'delete_interval') then
      update public.attendance_intervals set status = 'incomplete' where id = v_interval.id;
      insert into public.attendance_events (
        workspace_id, profile_id, interval_id, event_type, metadata
      ) values (
        v_interval.workspace_id, auth.uid(), v_interval.id, 'flagged_incomplete',
        jsonb_build_object('kind', p_kind)
      );
    end if;
  end if;

  insert into public.attendance_corrections (
    workspace_id, profile_id, team_id, interval_id, kind,
    proposed_started_at, proposed_ended_at, reason
  ) values (
    app.current_workspace(), auth.uid(), v_team, p_interval, p_kind,
    p_proposed_start, p_proposed_end, trim(p_reason)
  ) returning id into v_id;

  insert into public.attendance_events (
    workspace_id, profile_id, interval_id, event_type, metadata
  ) values (
    app.current_workspace(), auth.uid(), p_interval, 'correction_requested',
    jsonb_build_object('correction_id', v_id, 'kind', p_kind)
  );
  perform app.notify_team_approvers(
    app.current_workspace(), v_team, 'attendance',
    'درخواست اصلاح حضور',
    'یک درخواست اصلاح حضور و غیاب در صف بررسی است.',
    'attendance_correction', v_id
  );
  perform app.audit(app.current_workspace(), auth.uid(), 'attendance.correction_request', 'attendance_correction', v_id, jsonb_build_object('kind', p_kind));
  return v_id;
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
    'نتیجه درخواست اصلاح',
    'درخواست اصلاح حضور و غیاب بررسی شد.',
    'attendance_correction', p_correction
  );
  perform app.audit(
    v_row.workspace_id, auth.uid(), 'attendance.correction_decide', 'attendance_correction', p_correction,
    jsonb_build_object('approved', p_approve)
  );
end;
$$;

create or replace function public.attendance_totals(
  p_profile uuid,
  p_from date,
  p_to date
)
returns table (
  recorded_seconds bigint,
  pending_seconds bigint,
  approved_seconds bigint,
  revision_seconds bigint,
  rejected_seconds bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not app.can_view_attendance(p_profile) then
    raise exception 'forbidden';
  end if;
  return query
  select
    coalesce(sum(extract(epoch from (s.ended_at - s.started_at)))::bigint, 0),
    coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
      where s.approval_mode = 'report' and coalesce(ri.decision, 'pending') = 'pending'
    )::bigint, 0),
    coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
      where s.approval_mode = 'correction' or ri.decision = 'approved'
    )::bigint, 0),
    coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
      where ri.decision = 'needs_revision'
    )::bigint, 0),
    coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
      where ri.decision = 'rejected'
    )::bigint, 0)
  from public.attendance_daily_segments s
  join public.attendance_intervals i on i.id = s.interval_id
  left join public.attendance_report_items ri on ri.segment_id = s.id
  where s.profile_id = p_profile
    and s.tehran_date between p_from and p_to
    and s.superseded_at is null
    and i.status <> 'void';
end;
$$;

create or replace function public.attendance_buckets(
  p_profile uuid,
  p_from date,
  p_to date,
  p_grain text
)
returns table (
  period_start date,
  period_end date,
  jalali_year integer,
  jalali_month integer,
  approved_seconds bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if p_grain not in ('day', 'week', 'jalali_month') then
    raise exception 'invalid_grain';
  end if;
  if not app.can_view_attendance(p_profile) then
    raise exception 'forbidden';
  end if;

  if p_grain = 'day' then
    return query
    select
      s.tehran_date,
      s.tehran_date,
      j.jy,
      j.jm,
      coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
        where s.approval_mode = 'correction' or ri.decision = 'approved'
      )::bigint, 0)
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    left join public.attendance_report_items ri on ri.segment_id = s.id
    left join lateral app.gregorian_to_jalali(s.tehran_date) j on true
    where s.profile_id = p_profile
      and s.tehran_date between p_from and p_to
      and s.superseded_at is null
      and i.status <> 'void'
    group by s.tehran_date, j.jy, j.jm
    order by s.tehran_date;
  elsif p_grain = 'week' then
    return query
    select
      app.week_start(s.tehran_date),
      app.week_start(s.tehran_date) + 6,
      null::integer,
      null::integer,
      coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
        where s.approval_mode = 'correction' or ri.decision = 'approved'
      )::bigint, 0)
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    left join public.attendance_report_items ri on ri.segment_id = s.id
    where s.profile_id = p_profile
      and s.tehran_date between p_from and p_to
      and s.superseded_at is null
      and i.status <> 'void'
    group by app.week_start(s.tehran_date)
    order by app.week_start(s.tehran_date);
  else
    return query
    select
      b.start_date,
      b.end_date,
      j.jy,
      j.jm,
      coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
        where s.approval_mode = 'correction' or ri.decision = 'approved'
      )::bigint, 0)
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    left join public.attendance_report_items ri on ri.segment_id = s.id
    join lateral app.gregorian_to_jalali(s.tehran_date) j on true
    join lateral app.jalali_month_bounds(j.jy, j.jm) b on true
    where s.profile_id = p_profile
      and s.tehran_date between p_from and p_to
      and s.superseded_at is null
      and i.status <> 'void'
    group by b.start_date, b.end_date, j.jy, j.jm
    order by b.start_date;
  end if;
end;
$$;

create or replace function public.preview_open_attendance()
returns table (
  interval_id uuid,
  tehran_date date,
  started_at timestamptz,
  ended_at timestamptz,
  provisional boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_start timestamptz;
  v_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_day date;
  v_last date;
  v_seg_start timestamp;
  v_seg_end timestamp;
begin
  perform app.require_active();
  select id, effective_started_at into v_id, v_start
  from public.attendance_intervals
  where profile_id = auth.uid() and status = 'open';
  if v_id is null then
    return;
  end if;
  v_end := clock_timestamp();
  v_local_start := v_start at time zone 'Asia/Tehran';
  v_local_end := v_end at time zone 'Asia/Tehran';
  v_day := v_local_start::date;
  v_last := v_local_end::date;
  while v_day <= v_last loop
    v_seg_start := greatest(v_local_start, v_day::timestamp);
    v_seg_end := least(v_local_end, (v_day + 1)::timestamp);
    if v_seg_end > v_seg_start then
      interval_id := v_id;
      tehran_date := v_day;
      started_at := v_seg_start at time zone 'Asia/Tehran';
      ended_at := v_seg_end at time zone 'Asia/Tehran';
      provisional := true;
      return next;
    end if;
    v_day := v_day + 1;
  end loop;
end;
$$;
