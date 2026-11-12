CREATE OR REPLACE FUNCTION app.seed_workflow(p_workspace uuid, p_project uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_workflow uuid;
  v_name text := case when p_project is null then 'شخصی' else 'پیش‌فرض' end;
  v_backlog uuid;
  v_todo uuid;
  v_progress uuid;
  v_review uuid;
  v_approved uuid;
  v_done uuid;
  v_blocked uuid;
  v_changes uuid;
  v_rejected uuid;
begin
  insert into public.workflows (workspace_id, project_id, name)
  values (p_workspace, p_project, v_name)
  returning id into v_workflow;

  insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority)
  values
    (v_workflow, 'backlog', 'بک‌لاگ', 'backlog', 1, false),
    (v_workflow, 'todo', 'انجام‌نشده', 'todo', 2, false),
    (v_workflow, 'in_progress', 'در حال انجام', 'in_progress', 3, false),
    (v_workflow, 'in_review', 'در حال بررسی', 'in_review', 4, false),
    (v_workflow, 'approved', 'تأییدشده', 'approved', 5, true),
    (v_workflow, 'done', 'انجام‌شده', 'done', 6, true),
    (v_workflow, 'blocked', 'مسدود', 'blocked', 7, false),
    (v_workflow, 'changes_requested', 'نیاز به اصلاح', 'changes_requested', 8, true),
    (v_workflow, 'rejected', 'ردشده', 'rejected', 9, true);

  select id into v_backlog from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog';
  select id into v_todo from public.workflow_statuses where workflow_id = v_workflow and key = 'todo';
  select id into v_progress from public.workflow_statuses where workflow_id = v_workflow and key = 'in_progress';
  select id into v_review from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review';
  select id into v_approved from public.workflow_statuses where workflow_id = v_workflow and key = 'approved';
  select id into v_done from public.workflow_statuses where workflow_id = v_workflow and key = 'done';
  select id into v_blocked from public.workflow_statuses where workflow_id = v_workflow and key = 'blocked';
  select id into v_changes from public.workflow_statuses where workflow_id = v_workflow and key = 'changes_requested';
  select id into v_rejected from public.workflow_statuses where workflow_id = v_workflow and key = 'rejected';

  insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
  values
    (v_workflow, v_backlog, v_todo),
    (v_workflow, v_todo, v_progress),
    (v_workflow, v_progress, v_review),
    (v_workflow, v_progress, v_blocked),
    (v_workflow, v_blocked, v_progress),
    (v_workflow, v_review, v_approved),
    (v_workflow, v_approved, v_done),
    (v_workflow, v_review, v_changes),
    (v_workflow, v_changes, v_progress),
    (v_workflow, v_review, v_rejected);

  return v_workflow;
end;
$function$
;
