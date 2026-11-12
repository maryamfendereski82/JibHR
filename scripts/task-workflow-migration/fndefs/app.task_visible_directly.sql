CREATE OR REPLACE FUNCTION app.task_visible_directly(p_project uuid, p_assignee uuid, p_task uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_visibility text;
begin
  if p_project is null then
    return p_assignee = auth.uid()
      or app.is_team_approver(app.primary_team(p_assignee), auth.uid())
      or app.has_permission('tasks.view.all');
  end if;

  select visibility into v_visibility from public.projects where id = p_project;
  if app.has_permission('projects.view.all') then
    return true;
  end if;
  if v_visibility = 'project_wide' then
    return exists (
      select 1 from public.project_members
      where project_id = p_project and profile_id = auth.uid() and removed_at is null
    );
  end if;
  return p_assignee = auth.uid()
    or exists (
      select 1 from public.task_collaborators
      where task_id = p_task and profile_id = auth.uid()
    )
    or exists (
      select 1 from public.project_members
      where project_id = p_project
        and profile_id = auth.uid()
        and removed_at is null
        and member_role in ('manager', 'reviewer')
    );
end;
$function$
;
