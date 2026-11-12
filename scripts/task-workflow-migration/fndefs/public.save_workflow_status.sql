CREATE OR REPLACE FUNCTION public.save_workflow_status(p_workflow uuid, p_status uuid, p_name text, p_category text, p_position integer, p_requires_authority boolean, p_active boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_project uuid;
  v_id uuid := p_status;
  v_key text;
begin
  perform app.require_active();
  select project_id into v_project from public.workflows where id = p_workflow;
  if not found then
    raise exception 'not_found';
  end if;
  if v_project is null then
    if not app.has_permission('tasks.view.all') then
      raise exception 'forbidden';
    end if;
  elsif not app.can_edit_project(v_project) then
    raise exception 'forbidden';
  end if;
  if p_category not in (
    'backlog', 'todo', 'in_progress', 'in_review', 'approved', 'done',
    'blocked', 'changes_requested', 'rejected'
  ) then
    raise exception 'invalid_status';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  if p_status is not null and not p_active then
    select key into v_key from public.workflow_statuses where id = p_status and workflow_id = p_workflow;
    if v_key = 'backlog' then
      raise exception 'status_required';
    end if;
    if exists (select 1 from public.tasks where status_id = p_status and archived_at is null) then
      raise exception 'status_in_use';
    end if;
  end if;
  if p_status is null then
    insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority, is_active)
    values (
      p_workflow,
      'custom_' || replace(gen_random_uuid()::text, '-', ''),
      trim(p_name),
      p_category,
      coalesce(p_position, (select coalesce(max(position), 0) + 1 from public.workflow_statuses where workflow_id = p_workflow)),
      p_requires_authority,
      p_active
    )
    returning id into v_id;
  else
    update public.workflow_statuses
      set name = trim(p_name),
          category = p_category,
          position = p_position,
          requires_authority = p_requires_authority,
          is_active = p_active
    where id = p_status and workflow_id = p_workflow;
    if not found then
      raise exception 'not_found';
    end if;
  end if;
  return v_id;
end;
$function$
;
