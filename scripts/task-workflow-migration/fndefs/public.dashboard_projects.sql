CREATE OR REPLACE FUNCTION public.dashboard_projects()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not (exists (select 1 from public.projects p where app.can_view_project(p.id))
          or app.has_permission('projects.view.all')) then
    return null;
  end if;
  return jsonb_build_object(
    'active', (select count(*) from public.projects p where p.status = 'active' and app.can_view_project(p.id)),
    'archived', (select count(*) from public.projects p where p.status = 'archived' and app.can_view_project(p.id)),
    'tasks', (select count(*) from public.tasks t where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id)),
    'awaiting_review', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and t.project_id is not null and s.category = 'in_review' and app.can_view_task(t.id)
    ),
    'overdue', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.project_id is not null and t.due_at < clock_timestamp()
        and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
    ),
    'complete', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
    ),
    'active_sprints', (
      select count(*) from public.sprints s where s.status = 'active' and app.can_view_project(s.project_id)
    ),
    'upcoming_milestones', (
      select count(*) from public.milestones m
      where m.status in ('upcoming', 'in_progress') and app.can_view_project(m.project_id)
    ),
    'reached_milestones', (
      select count(*) from public.milestones m
      where m.status = 'reached' and app.can_view_project(m.project_id)
    )
  );
end;
$function$
;
