-- Reads are policies. Writes stay in security-definer functions, so there are
-- no insert/update/delete policies for the API roles.

grant usage on schema public to authenticated, service_role;
grant usage on schema app to authenticated, service_role;

revoke all on all tables in schema public from public, anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke select on public.auth_attempts from authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app from public, anon, authenticated;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on all functions in schema app to service_role;

revoke execute on function public.submit_due_attendance_reports() from authenticated;
revoke execute on function public.record_auth_attempt(text) from authenticated;
revoke execute on function public.mark_password_changed(uuid) from authenticated;

grant execute on function app.is_active() to authenticated;
grant execute on function app.current_workspace() to authenticated;
grant execute on function app.has_permission(text) to authenticated;
grant execute on function app.is_super_admin(uuid) to authenticated;
grant execute on function app.primary_team(uuid) to authenticated;
grant execute on function app.is_team_approver(uuid, uuid) to authenticated;
grant execute on function app.can_view_employee(uuid) to authenticated;
grant execute on function app.can_view_attendance(uuid) to authenticated;
grant execute on function app.can_view_project(uuid) to authenticated;
grant execute on function app.can_view_task(uuid) to authenticated;
grant execute on function app.can_view_leave(uuid, uuid) to authenticated;
grant execute on function app.can_view_absence(uuid, uuid) to authenticated;
grant execute on function app.trunc_div(integer, integer) to authenticated;
grant execute on function app.trunc_mod(integer, integer) to authenticated;
grant execute on function app.jal_cal(integer) to authenticated;
grant execute on function app.g2d(integer, integer, integer) to authenticated;
grant execute on function app.d2g(integer) to authenticated;
grant execute on function app.j2d(integer, integer, integer) to authenticated;
grant execute on function app.gregorian_to_jalali(date) to authenticated;
grant execute on function app.jalali_to_gregorian(integer, integer, integer) to authenticated;
grant execute on function app.tehran_date(timestamptz) to authenticated;
grant execute on function app.tehran_today() to authenticated;
grant execute on function app.week_start(date) to authenticated;
grant execute on function app.jalali_month_bounds(integer, integer) to authenticated;

do $$
declare
  r record;
begin
  for r in
    select tablename from pg_tables
    where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', r.tablename);
  end loop;
end;
$$;

create policy workspaces_select on public.workspaces
  for select to authenticated
  using (id = app.current_workspace() and app.is_active());

create policy positions_select on public.job_positions
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.is_active());

create policy profiles_select on public.profiles
  for select to authenticated
  using (app.can_view_employee(id));

create policy accounts_select on public.profile_accounts
  for select to authenticated
  using (
    app.is_active()
    and workspace_id = app.current_workspace()
    and (profile_id = auth.uid() or app.has_permission('employees.view.all'))
  );

create policy teams_select on public.teams
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.is_active());

create policy memberships_select on public.team_memberships
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.can_view_employee(profile_id));

create policy leadership_select on public.team_manager_assignments
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.is_active());

create policy permissions_select on public.permissions
  for select to authenticated
  using (app.is_active());

create policy roles_select on public.roles
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.is_active());

create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (
    app.is_active()
    and exists (
      select 1 from public.roles r
      where r.id = role_id and r.workspace_id = app.current_workspace()
    )
  );

create policy user_roles_select on public.user_roles
  for select to authenticated
  using (
    workspace_id = app.current_workspace()
    and (
      profile_id = auth.uid()
      or app.has_permission('roles.view')
      or app.has_permission('employees.view.all')
    )
  );

create policy invitations_select on public.invitations
  for select to authenticated
  using (
    workspace_id = app.current_workspace()
    and app.has_permission('employees.create')
  );

create policy projects_select on public.projects
  for select to authenticated
  using (app.can_view_project(id));

create policy project_members_select on public.project_members
  for select to authenticated
  using (app.can_view_project(project_id));

create policy labels_select on public.labels
  for select to authenticated
  using (app.can_view_project(project_id));

create policy workflows_select on public.workflows
  for select to authenticated
  using (
    workspace_id = app.current_workspace()
    and app.is_active()
    and (project_id is null or app.can_view_project(project_id))
  );

create policy statuses_select on public.workflow_statuses
  for select to authenticated
  using (
    exists (
      select 1 from public.workflows w
      where w.id = workflow_id
        and w.workspace_id = app.current_workspace()
        and (w.project_id is null or app.can_view_project(w.project_id))
    )
  );

create policy transitions_select on public.workflow_transitions
  for select to authenticated
  using (
    exists (
      select 1 from public.workflows w
      where w.id = workflow_id
        and w.workspace_id = app.current_workspace()
        and (w.project_id is null or app.can_view_project(w.project_id))
    )
  );

create policy tasks_select on public.tasks
  for select to authenticated
  using (app.can_view_task(id));

create policy collaborators_select on public.task_collaborators
  for select to authenticated
  using (app.can_view_task(task_id));

create policy task_labels_select on public.task_labels
  for select to authenticated
  using (app.can_view_task(task_id));

create policy checklist_select on public.task_checklist_items
  for select to authenticated
  using (app.can_view_task(task_id));

create policy rounds_select on public.task_review_rounds
  for select to authenticated
  using (app.can_view_task(task_id));

create policy reviews_select on public.task_reviews
  for select to authenticated
  using (
    exists (
      select 1 from public.task_review_rounds round
      where round.id = round_id and app.can_view_task(round.task_id)
    )
  );

create policy activity_select on public.task_activity_events
  for select to authenticated
  using (app.can_view_task(task_id));

create policy sprints_select on public.sprints
  for select to authenticated
  using (app.can_view_project(project_id));

create policy sprint_tasks_select on public.sprint_tasks
  for select to authenticated
  using (app.can_view_task(task_id));

create policy milestones_select on public.milestones
  for select to authenticated
  using (app.can_view_project(project_id));

create policy milestone_tasks_select on public.milestone_tasks
  for select to authenticated
  using (app.can_view_task(task_id));

create policy intervals_select on public.attendance_intervals
  for select to authenticated
  using (app.can_view_attendance(profile_id));

create policy events_select on public.attendance_events
  for select to authenticated
  using (app.can_view_attendance(profile_id));

create policy segments_select on public.attendance_daily_segments
  for select to authenticated
  using (app.can_view_attendance(profile_id));

create policy reports_select on public.attendance_daily_reports
  for select to authenticated
  using (app.can_view_attendance(profile_id));

create policy report_items_select on public.attendance_report_items
  for select to authenticated
  using (
    exists (
      select 1 from public.attendance_daily_reports r
      where r.id = report_id and app.can_view_attendance(r.profile_id)
    )
  );

create policy corrections_select on public.attendance_corrections
  for select to authenticated
  using (app.can_view_attendance(profile_id));

create policy leave_select on public.leave_requests
  for select to authenticated
  using (app.can_view_leave(profile_id, team_id));

create policy absence_select on public.absence_records
  for select to authenticated
  using (app.can_view_absence(profile_id, team_id));

create policy disputes_select on public.absence_disputes
  for select to authenticated
  using (
    exists (
      select 1 from public.absence_records a
      where a.id = absence_id and app.can_view_absence(a.profile_id, a.team_id)
    )
  );

create policy notifications_select on public.notifications
  for select to authenticated
  using (recipient_id = auth.uid() and app.is_active());

create policy audit_select on public.audit_logs
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.has_permission('audit.view'));

create policy settings_select on public.app_settings
  for select to authenticated
  using (workspace_id = app.current_workspace() and app.is_active());
