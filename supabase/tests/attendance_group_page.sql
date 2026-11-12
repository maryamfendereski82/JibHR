-- attendance_group_page: same figures as the existing functions, exact pages,
-- no one outside the viewer's access. Runs after critical.sql, as postgres.

\set wa b0000000-0000-4000-8000-000000000001
\set wb b0000000-0000-4000-8000-000000000002
\set gadmin b1000000-0000-4000-8000-000000000001
\set gmanager b1000000-0000-4000-8000-000000000002
\set gemployee b1000000-0000-4000-8000-000000000003
\set gpeer b1000000-0000-4000-8000-000000000004
\set goutsider b1000000-0000-4000-8000-000000000005
\set gpm b1000000-0000-4000-8000-000000000006
\set gforeign b1000000-0000-4000-8000-000000000007
\set teama b2000000-0000-4000-8000-000000000001
\set teamb b2000000-0000-4000-8000-000000000002
\set teamc b2000000-0000-4000-8000-000000000003

begin;

insert into public.workspaces (id, name) values (:'wb', 'فضای دیگر');
select id as ws from public.workspaces where id = 'a0000000-0000-4000-8000-000000000001' \gset
\set wa :ws

insert into auth.users (id, email)
select v::uuid, v || '@group.test'
from unnest(array[:'gadmin', :'gmanager', :'gemployee', :'gpeer', :'goutsider', :'gpm', :'gforeign']) v;

insert into public.profiles (id, workspace_id, first_name, last_name) values
  (:'gadmin', :'wa', 'گروه', 'ادمین'),
  (:'gmanager', :'wa', 'گروه', 'مدیر'),
  (:'gemployee', :'wa', 'گروه', 'کارمند'),
  (:'gpeer', :'wa', 'گروه', 'همکار'),
  (:'goutsider', :'wa', 'گروه', 'بیرونی'),
  (:'gpm', :'wa', 'گروه', 'مدیرپروژه'),
  (:'gforeign', :'wb', 'گروه', 'خارجی');

insert into public.teams (id, workspace_id, name) values
  (:'teama', :'wa', 'تیم الف صفحه'),
  (:'teamb', :'wa', 'تیم ب صفحه'),
  (:'teamc', :'wb', 'تیم فضای دیگر');

insert into public.team_memberships (workspace_id, team_id, profile_id, is_primary) values
  (:'wa', :'teama', :'gmanager', true),
  (:'wa', :'teama', :'gemployee', true),
  (:'wa', :'teama', :'gpeer', true),
  (:'wa', :'teamb', :'goutsider', true),
  (:'wa', :'teamb', :'gpm', true),
  (:'wa', :'teamb', :'gadmin', true),
  (:'wb', :'teamc', :'gforeign', true);

insert into public.team_manager_assignments (workspace_id, team_id, profile_id, kind)
values (:'wa', :'teama', :'gmanager', 'manager');

insert into public.user_roles (workspace_id, profile_id, role_id)
select :'wa', v.p::uuid, r.id
from (values (:'gadmin', 'general_admin'), (:'gmanager', 'team_manager'), (:'gemployee', 'employee'),
             (:'gpeer', 'employee'), (:'goutsider', 'employee'), (:'gpm', 'project_manager')) v(p, k)
join public.roles r on r.key = v.k and r.workspace_id = :'wa';

-- Backdated attendance goes around the triggers, only in this fixture.
set local session_replication_role = replica;

create temp table group_intervals (id uuid, status text, decision text, mode text) on commit drop;

do $$
declare
  v_today date := app.tehran_today();
  v_employee uuid := 'b1000000-0000-4000-8000-000000000003';
  v_peer uuid := 'b1000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b1000000-0000-4000-8000-000000000005';
  v_workspace uuid := 'a0000000-0000-4000-8000-000000000001';
  v_team uuid := 'b2000000-0000-4000-8000-000000000001';
  v_report uuid;
  v_case record;
  v_interval uuid;
  v_start timestamptz;
  v_end timestamptz;
begin
  for v_case in
    select * from (values
      -- owner, days back, start hour, end hour (past 24 crosses midnight), status, decision, mode
      (v_employee, 2, 9.0, 11.0, 'closed', 'approved', 'report'),
      (v_employee, 2, 12.0, 13.0, 'closed', 'rejected', 'report'),
      (v_employee, 2, 14.0, 15.5, 'closed', 'needs_revision', 'report'),
      (v_employee, 2, 16.0, 16.5, 'closed', 'pending', 'report'),
      (v_employee, 3, 22.0, 25.0, 'closed', 'approved', 'report'),
      (v_employee, 5, 9.0, 10.0, 'closed', null, 'correction'),
      (v_employee, 6, 9.0, 12.0, 'void', 'approved', 'report'),
      (v_peer, 2, 8.0, 9.0, 'closed', 'approved', 'report'),
      (v_outsider, 2, 8.0, 12.0, 'closed', 'approved', 'report')
    ) c(owner, back, h1, h2, status, decision, mode)
  loop
    v_start := ((v_today - v_case.back)::timestamp + make_interval(mins => (v_case.h1 * 60)::int)) at time zone 'Asia/Tehran';
    v_end := ((v_today - v_case.back)::timestamp + make_interval(mins => (v_case.h2 * 60)::int)) at time zone 'Asia/Tehran';
    insert into public.attendance_intervals (workspace_id, profile_id, origin, status, original_started_at, original_ended_at, effective_started_at, effective_ended_at)
    values (v_workspace, v_case.owner, 'clock', 'closed', v_start, v_end, v_start, v_end)
    returning id into v_interval;
    perform app.materialize_segments(v_interval, v_case.mode, null);
    if v_case.status = 'void' then
      update public.attendance_intervals set status = 'void' where id = v_interval;
    end if;
    if v_case.mode = 'report' then
      insert into public.attendance_daily_reports (workspace_id, profile_id, team_id, tehran_date, sequence, kind, submission_source)
      values (v_workspace, v_case.owner, v_team, v_today - v_case.back, 1 + (select count(*) from public.attendance_daily_reports r where r.profile_id = v_case.owner and r.tehran_date = v_today - v_case.back), 'primary', 'manual')
      returning id into v_report;
      insert into public.attendance_report_items (report_id, segment_id, decision)
      select v_report, s.id, v_case.decision from public.attendance_daily_segments s where s.interval_id = v_interval;
    end if;
  end loop;

  -- A superseded segment must not appear.
  v_start := ((v_today - 7)::timestamp + time '09:00') at time zone 'Asia/Tehran';
  insert into public.attendance_intervals (workspace_id, profile_id, origin, status, original_started_at, original_ended_at, effective_started_at, effective_ended_at)
  values (v_workspace, v_employee, 'clock', 'closed', v_start, v_start + interval '1 hour', v_start, v_start + interval '1 hour')
  returning id into v_interval;
  perform app.materialize_segments(v_interval, 'report', null);
  update public.attendance_daily_segments set superseded_at = now() where interval_id = v_interval;

  -- A forgotten clock-out has no segment and must still show.
  v_start := ((v_today - 4)::timestamp + time '09:30') at time zone 'Asia/Tehran';
  insert into public.attendance_intervals (workspace_id, profile_id, origin, status, original_started_at, effective_started_at)
  values (v_workspace, v_employee, 'clock', 'incomplete', v_start, v_start);
end
$$;

set local session_replication_role = origin;
commit;

\set gfrom (app.tehran_today() - 20)
\set gto app.tehran_today()

-- Figures: general admin reads everyone and each person matches the existing functions.
select set_config('request.jwt.claim.sub', :'gadmin', false);
set role authenticated;
do $$
declare
  v_from date := app.tehran_today() - 20;
  v_to date := app.tehran_today();
  v_page jsonb := public.attendance_group_page(v_from, v_to, null, 'گروه', 100, 0);
  v_person jsonb;
  v_id uuid;
  v_total record;
  v_bucket record;
  v_employee jsonb;
  v_day date := app.tehran_today() - 3;
begin
  if (v_page->>'total')::int <> 6 then
    raise exception 'admin expected 6 people in this workspace, got %', v_page->>'total';
  end if;
  if v_page::text like '%خارجی%' then
    raise exception 'another workspace leaked into the page';
  end if;
  for v_person in select * from jsonb_array_elements(v_page->'people') loop
    v_id := (v_person->>'id')::uuid;
    select * into v_total from public.attendance_totals(v_id, v_from, v_to);
    if (v_person->'totals'->>'recorded_seconds')::bigint <> v_total.recorded_seconds
       or (v_person->'totals'->>'approved_seconds')::bigint <> v_total.approved_seconds
       or (v_person->'totals'->>'pending_seconds')::bigint <> v_total.pending_seconds
       or (v_person->'totals'->>'revision_seconds')::bigint <> v_total.revision_seconds
       or (v_person->'totals'->>'rejected_seconds')::bigint <> v_total.rejected_seconds then
      raise exception 'totals differ from attendance_totals for %', v_id;
    end if;
    for v_bucket in select * from public.attendance_buckets(v_id, v_from, v_to, 'day') loop
      if (v_person->'approved_by_day'->>v_bucket.period_start::text)::bigint is distinct from v_bucket.approved_seconds then
        raise exception 'day differs from attendance_buckets for % on %', v_id, v_bucket.period_start;
      end if;
    end loop;
  end loop;

  select p into v_employee from jsonb_array_elements(v_page->'people') p where p->>'last_name' = 'کارمند';
  -- 2h approved + 1h rejected + 1.5h revision + 0.5h pending + cross-midnight 3h + correction 1h.
  if (v_employee->'totals'->>'approved_seconds')::bigint <> (2 + 3 + 1) * 3600 then
    raise exception 'unexpected approved figure: %', v_employee->'totals';
  end if;
  -- 4 same-day + 2 midnight halves + 1 correction + 1 incomplete. Void and superseded stay out.
  if jsonb_array_length(v_employee->'slices') <> 8 then
    raise exception 'expected 8 slices, got %', jsonb_array_length(v_employee->'slices');
  end if;
  if (select count(distinct s->>'interval_id') from jsonb_array_elements(v_employee->'slices') s) <> 7 then
    raise exception 'an interval went missing or was duplicated';
  end if;
  if (select count(*) from jsonb_array_elements(v_employee->'slices') s where s->>'interval_status' = 'incomplete' and s->>'ended_at' is null) <> 1 then
    raise exception 'the incomplete interval is missing';
  end if;
  if (
    select array_agg(s->>'tehran_date' order by s->>'tehran_date')
    from jsonb_array_elements(v_employee->'slices') s
    where s->>'interval_id' = (
      select i->>'interval_id'
      from jsonb_array_elements(v_employee->'slices') i
      group by 1
      having count(*) = 2
    )
  ) is distinct from array[v_day::text, (v_day + 1)::text] then
    raise exception 'a cross-midnight interval did not stay on two days';
  end if;
end
$$;
reset role;

-- Pagination: every page size covers everyone once, in a stable order.
select set_config('request.jwt.claim.sub', :'gadmin', false);
set role authenticated;
do $$
declare
  v_from date := app.tehran_today() - 6;
  v_to date := app.tehran_today();
  v_size int;
  v_offset int;
  v_page jsonb;
  v_ids text[];
  v_all text[];
begin
  select array_agg(p->>'id' order by ord) into v_all
  from jsonb_array_elements(public.attendance_group_page(v_from, v_to, null, 'گروه', 100, 0)->'people') with ordinality as t(p, ord);
  foreach v_size in array array[1, 2, 4, 5, 6] loop
    v_offset := 0;
    v_ids := '{}';
    loop
      v_page := public.attendance_group_page(v_from, v_to, null, 'گروه', v_size, v_offset);
      if (v_page->>'total')::int <> 6 then
        raise exception 'total changed between pages';
      end if;
      exit when jsonb_array_length(v_page->'people') = 0;
      if jsonb_array_length(v_page->'people') > v_size then
        raise exception 'page larger than its limit';
      end if;
      v_ids := v_ids || array(select p->>'id' from jsonb_array_elements(v_page->'people') p);
      v_offset := v_offset + v_size;
    end loop;
    if v_ids is distinct from v_all then
      raise exception 'pages of % did not cover everyone exactly once', v_size;
    end if;
  end loop;
  if jsonb_array_length(public.attendance_group_page(v_from, v_to, null, 'گروه', 2, 600)->'people') <> 0 then
    raise exception 'an offset past the end returned people';
  end if;
end
$$;
reset role;

-- Filters run on the server, and a search term is text, not a pattern.
select set_config('request.jwt.claim.sub', :'gadmin', false);
set role authenticated;
do $$
declare
  v_from date := app.tehran_today() - 6;
  v_to date := app.tehran_today();
begin
  if (public.attendance_group_page(v_from, v_to, 'b2000000-0000-4000-8000-000000000001', null, 50, 0)->>'total')::int <> 3 then
    raise exception 'team filter';
  end if;
  if (public.attendance_group_page(v_from, v_to, null, 'گروه همکار', 50, 0)->>'total')::int <> 1 then
    raise exception 'name search';
  end if;
  if (public.attendance_group_page(v_from, v_to, null, '%', 50, 0)->>'total')::int <> 0
     or (public.attendance_group_page(v_from, v_to, null, '_', 50, 0)->>'total')::int <> 0 then
    raise exception 'a wildcard matched as a pattern';
  end if;
  if (public.attendance_group_page(v_from, v_to, 'b2000000-0000-4000-8000-000000000003', null, 50, 0)->>'total')::int <> 0 then
    raise exception 'a team in another workspace was readable';
  end if;
end
$$;
reset role;

-- Access: a team manager sees the team, and only the team.
select set_config('request.jwt.claim.sub', :'gmanager', false);
set role authenticated;
do $$
declare
  v_from date := app.tehran_today() - 6;
  v_to date := app.tehran_today();
  v_page jsonb := public.attendance_group_page(v_from, v_to, null, null, 100, 0);
begin
  if (v_page->>'total')::int <> 3 then
    raise exception 'manager expected the 3 people of the team, got %', v_page->>'total';
  end if;
  if v_page::text like '%بیرونی%' or v_page::text like '%مدیرپروژه%' then
    raise exception 'manager saw someone outside the team';
  end if;
  if (public.attendance_group_page(v_from, v_to, 'b2000000-0000-4000-8000-000000000002', null, 50, 0)->>'total')::int <> 0 then
    raise exception 'manager read another team';
  end if;
end
$$;
reset role;

-- Access: an employee and a project manager see themselves and no one else.
select set_config('request.jwt.claim.sub', :'gemployee', false);
set role authenticated;
do $$
declare
  v_page jsonb := public.attendance_group_page(app.tehran_today() - 6, app.tehran_today(), null, null, 100, 0);
begin
  if (v_page->>'total')::int <> 1 or v_page->'people'->0->>'last_name' <> 'کارمند' then
    raise exception 'employee saw other people: %', v_page->>'total';
  end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'gpm', false);
set role authenticated;
do $$
declare
  v_page jsonb := public.attendance_group_page(app.tehran_today() - 6, app.tehran_today(), null, null, 100, 0);
begin
  if (v_page->>'total')::int <> 1 or v_page->'people'->0->>'last_name' <> 'مدیرپروژه' then
    raise exception 'project manager saw other people: %', v_page->>'total';
  end if;
end
$$;
reset role;

-- Bad input and anonymous calls stay refused.
select set_config('request.jwt.claim.sub', :'gadmin', false);
set role authenticated;
do $$
declare
  v_today date := app.tehran_today();
begin
  begin
    perform public.attendance_group_page(v_today - 31, v_today, null, null, 50, 0);
    raise exception 'a 32-day range was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  perform public.attendance_group_page(v_today - 30, v_today, null, null, 50, 0);
  begin
    perform public.attendance_group_page(v_today, v_today - 1, null, null, 50, 0);
    raise exception 'a reversed range was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform public.attendance_group_page(v_today, v_today, null, null, 101, 0);
    raise exception 'an oversized page was accepted';
  exception when others then
    if sqlerrm <> 'invalid_page' then raise; end if;
  end;
  begin
    perform public.attendance_group_page(v_today, v_today, null, null, 50, -1);
    raise exception 'a negative offset was accepted';
  exception when others then
    if sqlerrm <> 'invalid_page' then raise; end if;
  end;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', '', false);
set role anon;
do $$
begin
  perform public.attendance_group_page(current_date, current_date, null, null, 50, 0);
  raise exception 'anon reached the group page';
exception when insufficient_privilege then
  null;
end
$$;
reset role;
