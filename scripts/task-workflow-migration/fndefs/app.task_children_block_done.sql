CREATE OR REPLACE FUNCTION app.task_children_block_done(p_task uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.tasks child
    join public.workflow_statuses st on st.id = child.status_id
    where child.parent_task_id = p_task
      and child.is_required
      and child.archived_at is null
      and (
        st.category not in ('done', 'approved')
        or (child.approval_required and child.approval_state <> 'approved')
      )
  );
$function$
;
