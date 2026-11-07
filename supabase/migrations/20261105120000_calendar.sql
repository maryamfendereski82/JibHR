-- Jalali conversion for report boundaries.
-- Supabase Postgres does not ship a Persian calendar extension.
-- This is a direct port of the tested jalaali algorithm
-- (jalaali-js / Calendrical Calculations), checked against shamsi_date vectors
-- in supabase/tests/critical.sql.
-- Asia/Tehran has no daylight-saving time; midnight math uses that zone explicitly.

create schema if not exists extensions;
create schema if not exists app;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema public;

create or replace function app.trunc_div(a integer, b integer)
returns integer
language sql
immutable
as $$
  select trunc(a::numeric / b::numeric)::integer;
$$;

create or replace function app.trunc_mod(a integer, b integer)
returns integer
language sql
immutable
as $$
  select a - app.trunc_div(a, b) * b;
$$;

-- leap follows jalaali-js: 0 means Esfand has 30 days. gy/march are Nowruz.
create or replace function app.jal_cal(p_jy integer)
returns table (leap integer, gy integer, march integer)
language plpgsql
immutable
as $$
declare
  breaks integer[] := array[
    -61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210,
    1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178
  ];
  bl integer;
  out_gy integer;
  leap_j integer := -14;
  jp integer;
  jm integer;
  jump integer := 0;
  n integer;
  i integer;
  leap_g integer;
  out_march integer;
  out_leap integer;
begin
  bl := array_length(breaks, 1);
  out_gy := p_jy + 621;
  jp := breaks[1];
  if p_jy < jp or p_jy >= breaks[bl] then
    raise exception 'jalali_year_out_of_range';
  end if;

  for i in 2..bl loop
    jm := breaks[i];
    jump := jm - jp;
    exit when p_jy < jm;
    leap_j := leap_j
      + app.trunc_div(jump, 33) * 8
      + app.trunc_div(app.trunc_mod(jump, 33), 4);
    jp := jm;
  end loop;

  n := p_jy - jp;
  leap_j := leap_j
    + app.trunc_div(n, 33) * 8
    + app.trunc_div(app.trunc_mod(n, 33) + 3, 4);
  if app.trunc_mod(jump, 33) = 4 and jump - n = 4 then
    leap_j := leap_j + 1;
  end if;

  leap_g := app.trunc_div(out_gy, 4)
    - app.trunc_div((app.trunc_div(out_gy, 100) + 1) * 3, 4)
    - 150;
  out_march := 20 + leap_j - leap_g;

  if jump - n < 6 then
    n := n - jump + app.trunc_div(jump + 4, 33) * 33;
  end if;
  out_leap := app.trunc_mod(app.trunc_mod(n + 1, 33) - 1, 4);
  if out_leap = -1 then
    out_leap := 4;
  end if;

  return query select out_leap, out_gy, out_march;
end;
$$;

create or replace function app.g2d(p_gy integer, p_gm integer, p_gd integer)
returns integer
language sql
immutable
as $$
  select
    app.trunc_div((p_gy + app.trunc_div(p_gm - 8, 6) + 100100) * 1461, 4)
    + app.trunc_div(153 * app.trunc_mod(p_gm + 9, 12) + 2, 5)
    + p_gd
    - 34840408
    - app.trunc_div(
        app.trunc_div(p_gy + 100100 + app.trunc_div(p_gm - 8, 6), 100) * 3,
        4
      )
    + 752;
$$;

create or replace function app.d2g(p_jdn integer)
returns table (gy integer, gm integer, gd integer)
language plpgsql
immutable
as $$
declare
  j integer;
  i integer;
  out_gd integer;
  out_gm integer;
  out_gy integer;
begin
  j := 4 * p_jdn + 139361631;
  j := j + app.trunc_div(app.trunc_div(4 * p_jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  i := app.trunc_div(app.trunc_mod(j, 1461), 4) * 5 + 308;
  out_gd := app.trunc_div(app.trunc_mod(i, 153), 5) + 1;
  out_gm := app.trunc_mod(app.trunc_div(i, 153), 12) + 1;
  out_gy := app.trunc_div(j, 1461) - 100100 + app.trunc_div(8 - out_gm, 6);
  return query select out_gy, out_gm, out_gd;
end;
$$;

create or replace function app.j2d(p_jy integer, p_jm integer, p_jd integer)
returns integer
language plpgsql
immutable
as $$
declare
  cal record;
begin
  select * into cal from app.jal_cal(p_jy);
  return app.g2d(cal.gy, 3, cal.march)
    + (p_jm - 1) * 31
    - app.trunc_div(p_jm, 7) * (p_jm - 7)
    + p_jd
    - 1;
end;
$$;

create or replace function app.gregorian_to_jalali(p_date date)
returns table (jy integer, jm integer, jd integer)
language plpgsql
immutable
as $$
declare
  jdn integer;
  g record;
  cal record;
  out_jy integer;
  out_jm integer;
  out_jd integer;
  k integer;
begin
  jdn := app.g2d(extract(year from p_date)::integer, extract(month from p_date)::integer, extract(day from p_date)::integer);
  select * into g from app.d2g(jdn);
  out_jy := g.gy - 621;
  select * into cal from app.jal_cal(out_jy);
  k := jdn - app.g2d(g.gy, 3, cal.march);
  if k >= 0 then
    if k <= 185 then
      out_jm := 1 + app.trunc_div(k, 31);
      out_jd := app.trunc_mod(k, 31) + 1;
      return query select out_jy, out_jm, out_jd;
      return;
    end if;
    k := k - 186;
  else
    out_jy := out_jy - 1;
    k := k + 179;
    if cal.leap = 1 then
      k := k + 1;
    end if;
  end if;
  out_jm := 7 + app.trunc_div(k, 30);
  out_jd := app.trunc_mod(k, 30) + 1;
  return query select out_jy, out_jm, out_jd;
end;
$$;

create or replace function app.jalali_to_gregorian(p_jy integer, p_jm integer, p_jd integer)
returns date
language plpgsql
immutable
as $$
declare
  g record;
begin
  select * into g from app.d2g(app.j2d(p_jy, p_jm, p_jd));
  return make_date(g.gy, g.gm, g.gd);
end;
$$;

create or replace function app.tehran_date(p_ts timestamptz)
returns date
language sql
immutable
as $$
  select (p_ts at time zone 'Asia/Tehran')::date;
$$;

create or replace function app.tehran_today()
returns date
language sql
stable
as $$
  select app.tehran_date(clock_timestamp());
$$;

-- PostgreSQL dow: Sunday = 0, Saturday = 6. Week starts Saturday.
create or replace function app.week_start(p_date date)
returns date
language sql
immutable
as $$
  select p_date - ((extract(dow from p_date)::integer + 1) % 7);
$$;

create or replace function app.jalali_month_bounds(p_jy integer, p_jm integer)
returns table (start_date date, end_date date)
language plpgsql
immutable
as $$
declare
  cal record;
  last_day integer;
begin
  if p_jm < 1 or p_jm > 12 then
    raise exception 'invalid_jalali_month';
  end if;
  select * into cal from app.jal_cal(p_jy);
  last_day := case
    when p_jm <= 6 then 31
    when p_jm <= 11 then 30
    when cal.leap = 0 then 30
    else 29
  end;
  return query select app.jalali_to_gregorian(p_jy, p_jm, 1), app.jalali_to_gregorian(p_jy, p_jm, last_day);
end;
$$;

revoke all on schema app from public;
