CREATE OR REPLACE FUNCTION app.task_counts_complete(p_task uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.tasks t
    join public.workflow_statuses s on s.id = t.status_id
    where t.id = p_task
      and t.archived_at is null
      and s.category in ('done', 'approved')
      and (t.approval_required = false or t.approval_state = 'approved')
  );
$function$
;
