CREATE OR REPLACE FUNCTION public.remove_project_member(p_project uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_role text;
  v_managers integer;
  v_workspace uuid;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  select workspace_id into v_workspace from public.projects where id = p_project;
  select member_role into v_role
  from public.project_members
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if v_role is null then
    raise exception 'not_found';
  end if;
  if v_role = 'manager' then
    select count(*) into v_managers
    from public.project_members
    where project_id = p_project and member_role = 'manager' and removed_at is null;
    if v_managers <= 1 then
      raise exception 'last_manager';
    end if;
  end if;
  update public.project_members
    set removed_at = clock_timestamp()
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if p_profile is distinct from auth.uid() and v_workspace is not null then
    perform app.notify(
      v_workspace, p_profile, 'project',
      'از پروژه برداشته شدید', 'عضویت شما در یک پروژه پایان یافت.',
      'project', p_project
    );
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member_remove', 'project', p_project, jsonb_build_object('profile_id', p_profile));
end;
$function$
;
