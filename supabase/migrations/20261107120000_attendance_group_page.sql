-- One page of the group calendar in one request.
-- Durations are not calculated here: every person's figures come from
-- attendance_totals and attendance_buckets, so they cannot drift from them.
-- This function bypasses RLS, so the same two checks RLS and the old client
-- path applied are repeated in the scope below.

create or replace function public.attendance_group_page(
  p_from date,
  p_to date,
  p_team uuid default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pattern text;
  v_result jsonb;
begin
  perform app.require_active();
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from >= 31 then
    raise exception 'invalid_range';
  end if;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then
    raise exception 'invalid_page';
  end if;
  if v_search is not null then
    v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  with scope as materialized (
    select m.profile_id, m.team_id, p.first_name, p.last_name
    from public.team_memberships m
    join public.profiles p on p.id = m.profile_id
    where m.is_primary
      and m.left_at is null
      and (p_team is null or m.team_id = p_team)
      and (v_pattern is null or (p.first_name || ' ' || p.last_name) ilike v_pattern)
      and app.can_view_employee(m.profile_id)
      and app.can_view_attendance(m.profile_id)
  ),
  page as materialized (
    select *
    from scope
    order by first_name, last_name, profile_id
    limit p_limit
    offset p_offset
  )
  select jsonb_build_object(
    'total', (select count(*) from scope),
    'limit', p_limit,
    'offset', p_offset,
    'people', coalesce(jsonb_agg(
      jsonb_build_object(
        'id', g.profile_id,
        'team_id', g.team_id,
        'first_name', g.first_name,
        'last_name', g.last_name,
        'totals', to_jsonb(t),
        'approved_by_day', coalesce((
          select jsonb_object_agg(b.period_start, b.approved_seconds)
          from public.attendance_buckets(g.profile_id, p_from, p_to, 'day') b
        ), '{}'::jsonb),
        'slices', coalesce((
          select jsonb_agg(x)
          from (
            select
              s.interval_id,
              s.tehran_date,
              s.started_at,
              s.ended_at,
              s.approval_mode,
              i.status as interval_status,
              i.start_platform,
              i.end_platform,
              ri.decision
            from public.attendance_daily_segments s
            join public.attendance_intervals i on i.id = s.interval_id
            left join public.attendance_report_items ri on ri.segment_id = s.id
            where s.profile_id = g.profile_id
              and s.tehran_date between p_from and p_to
              and s.superseded_at is null
              and i.status <> 'void'
            union all
            -- Open and incomplete intervals have no segment until they close.
            select
              i.id,
              (i.effective_started_at at time zone 'Asia/Tehran')::date,
              i.effective_started_at,
              null,
              'report',
              i.status,
              i.start_platform,
              i.end_platform,
              null
            from public.attendance_intervals i
            where i.profile_id = g.profile_id
              and i.status in ('open', 'incomplete')
              and (i.effective_started_at at time zone 'Asia/Tehran')::date between p_from and p_to
              and not exists (
                select 1
                from public.attendance_daily_segments s
                where s.interval_id = i.id
                  and s.superseded_at is null
                  and s.tehran_date between p_from and p_to
              )
          ) x
        ), '[]'::jsonb)
      )
      order by g.first_name, g.last_name, g.profile_id
    ), '[]'::jsonb)
  )
  into v_result
  from page g
  cross join lateral public.attendance_totals(g.profile_id, p_from, p_to) t;

  return v_result;
end;
$$;

revoke all on function public.attendance_group_page(date, date, uuid, text, integer, integer)
  from public, anon;
grant execute on function public.attendance_group_page(date, date, uuid, text, integer, integer)
  to authenticated;
