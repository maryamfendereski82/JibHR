-- Rollback of 20261108120000_dashboard_split.sql. Not applied automatically.
-- Restores the previous dashboard_summary exactly (it was kept as
-- app.dashboard_summary_v1) and removes the split functions and scopes.
begin;

drop function if exists public.dashboard_summary();
drop function if exists public.dashboard_personal();
drop function if exists public.dashboard_team();
drop function if exists public.dashboard_projects();
drop function if exists public.dashboard_queues();
drop function if exists app.dash_approval_scope(text);
drop function if exists app.dash_employee_profiles();
drop function if exists app.dash_attendance_profiles();
drop function if exists app.dash_approver_teams();

alter function app.dashboard_summary_v1() set schema public;
alter function public.dashboard_summary_v1() rename to dashboard_summary;
revoke all on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_summary() to authenticated, service_role;

commit;
