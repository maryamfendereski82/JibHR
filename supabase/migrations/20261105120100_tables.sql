-- One Tehran workspace today. workspace_id is on every business table so a
-- later workspace is another row, not a new schema. Sensitive writes go
-- through functions in the next migration; these tables only store facts.

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 120),
  timezone text not null default 'Asia/Tehran' check (timezone = 'Asia/Tehran'),
  created_at timestamptz not null default clock_timestamp()
);

create table public.job_positions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  title text not null check (char_length(trim(title)) between 1 and 120),
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, title)
);

create table public.profiles (
  id uuid primary key references auth.users (id) on delete restrict,
  workspace_id uuid not null references public.workspaces (id),
  first_name text not null check (char_length(trim(first_name)) between 1 and 80),
  last_name text not null check (char_length(trim(last_name)) between 1 and 80),
  job_position_id uuid references public.job_positions (id),
  status text not null default 'active' check (status in ('active', 'inactive')),
  must_change_password boolean not null default false,
  joined_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create index profiles_workspace_status_idx on public.profiles (workspace_id, status);

-- Login identifiers stay off the directory row.
create table public.profile_accounts (
  profile_id uuid primary key references public.profiles (id) on delete restrict,
  workspace_id uuid not null references public.workspaces (id),
  username public.citext not null check (username::text ~ '^[a-z0-9._]{3,32}$'),
  email text not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  unique (workspace_id, username),
  unique (email)
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  name text not null check (char_length(trim(name)) between 1 and 120),
  description text not null default '',
  status text not null default 'active' check (status in ('active', 'inactive', 'archived')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, name)
);

create table public.team_memberships (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  team_id uuid not null references public.teams (id),
  profile_id uuid not null references public.profiles (id),
  is_primary boolean not null default false,
  joined_at timestamptz not null default clock_timestamp(),
  left_at timestamptz,
  check (left_at is null or left_at >= joined_at)
);

create unique index team_memberships_one_primary_idx
  on public.team_memberships (profile_id)
  where is_primary and left_at is null;

create unique index team_memberships_active_idx
  on public.team_memberships (team_id, profile_id)
  where left_at is null;

create index team_memberships_profile_idx on public.team_memberships (profile_id);

create table public.team_manager_assignments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  team_id uuid not null references public.teams (id),
  profile_id uuid not null references public.profiles (id),
  kind text not null check (kind in ('manager', 'supervisor', 'deputy')),
  assigned_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);

create unique index team_leadership_active_idx
  on public.team_manager_assignments (team_id, profile_id, kind)
  where revoked_at is null;

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  module text not null,
  action text not null,
  scope text not null,
  description text not null
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  key text not null,
  name text not null check (char_length(trim(name)) between 1 and 80),
  description text not null default '',
  is_system boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, key)
);

create table public.role_permissions (
  role_id uuid not null references public.roles (id),
  permission_id uuid not null references public.permissions (id),
  primary key (role_id, permission_id)
);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  role_id uuid not null references public.roles (id),
  granted_by uuid references public.profiles (id),
  granted_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);

create unique index user_roles_active_idx
  on public.user_roles (profile_id, role_id)
  where revoked_at is null;

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  email text not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  first_name text not null,
  last_name text not null,
  username public.citext not null check (username::text ~ '^[a-z0-9._]{3,32}$'),
  job_position_id uuid references public.job_positions (id),
  primary_team_id uuid references public.teams (id),
  role_keys text[] not null,
  invited_by uuid not null references public.profiles (id),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);

create index invitations_email_idx on public.invitations (email) where consumed_at is null;

-- Hashed attempt keys only. The edge function never writes the password.
create table public.auth_attempts (
  id bigint generated always as identity primary key,
  attempt_key text not null,
  created_at timestamptz not null default clock_timestamp()
);

create index auth_attempts_key_idx on public.auth_attempts (attempt_key, created_at desc);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  name text not null check (char_length(trim(name)) between 1 and 160),
  description text not null default '',
  visibility text not null default 'project_wide' check (visibility in ('project_wide', 'restricted')),
  approval_required boolean not null default true,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  archived_at timestamptz
);

create table public.project_members (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id),
  profile_id uuid not null references public.profiles (id),
  member_role text not null check (member_role in ('manager', 'reviewer', 'member')),
  added_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz
);

create unique index project_members_active_idx
  on public.project_members (project_id, profile_id)
  where removed_at is null;

create index project_members_profile_idx on public.project_members (profile_id) where removed_at is null;

create table public.labels (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  project_id uuid not null references public.projects (id),
  name text not null check (char_length(trim(name)) between 1 and 40),
  is_active boolean not null default true,
  unique (project_id, name)
);

create table public.workflows (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  project_id uuid references public.projects (id),
  name text not null,
  created_at timestamptz not null default clock_timestamp()
);

create unique index workflows_one_personal_idx
  on public.workflows (workspace_id)
  where project_id is null;

create unique index workflows_one_project_idx
  on public.workflows (project_id)
  where project_id is not null;

create table public.workflow_statuses (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  key text not null,
  name text not null,
  category text not null check (category in (
    'backlog', 'todo', 'in_progress', 'in_review', 'approved', 'done',
    'blocked', 'changes_requested', 'rejected'
  )),
  position integer not null,
  requires_authority boolean not null default false,
  unique (workflow_id, key)
);

create table public.workflow_transitions (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  from_status_id uuid not null references public.workflow_statuses (id),
  to_status_id uuid not null references public.workflow_statuses (id),
  unique (from_status_id, to_status_id)
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  project_id uuid references public.projects (id),
  parent_task_id uuid references public.tasks (id),
  title text not null check (char_length(trim(title)) between 1 and 200),
  description text not null default '',
  primary_assignee_id uuid not null references public.profiles (id),
  reviewer_id uuid references public.profiles (id),
  status_id uuid not null references public.workflow_statuses (id),
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high', 'critical')),
  due_at timestamptz,
  approval_required boolean not null default false,
  approval_state text not null default 'not_required' check (approval_state in (
    'not_required', 'pending', 'changes_requested', 'approved', 'rejected'
  )),
  is_required boolean not null default false,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  archived_at timestamptz,
  check (parent_task_id is distinct from id)
);

create index tasks_assignee_idx on public.tasks (primary_assignee_id) where archived_at is null;
create index tasks_project_status_idx on public.tasks (project_id, status_id) where archived_at is null;
create index tasks_parent_idx on public.tasks (parent_task_id);

create table public.task_collaborators (
  task_id uuid not null references public.tasks (id),
  profile_id uuid not null references public.profiles (id),
  added_at timestamptz not null default clock_timestamp(),
  primary key (task_id, profile_id)
);

create table public.task_labels (
  task_id uuid not null references public.tasks (id),
  label_id uuid not null references public.labels (id),
  primary key (task_id, label_id)
);

create table public.task_checklist_items (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id),
  title text not null check (char_length(trim(title)) between 1 and 200),
  is_done boolean not null default false,
  position integer not null,
  created_at timestamptz not null default clock_timestamp()
);

create index task_checklist_items_task_idx on public.task_checklist_items (task_id, position);

create table public.task_review_rounds (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id),
  round_number integer not null check (round_number > 0),
  opened_at timestamptz not null default clock_timestamp(),
  unique (task_id, round_number)
);

-- One decision per round. The unique constraint is the race backstop.
create table public.task_reviews (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null unique references public.task_review_rounds (id),
  reviewer_id uuid not null references public.profiles (id),
  decision text not null check (decision in ('approved', 'revision_requested', 'rejected')),
  reason text,
  created_at timestamptz not null default clock_timestamp(),
  check (decision = 'approved' or char_length(trim(coalesce(reason, ''))) > 0)
);

create table public.task_activity_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  task_id uuid not null references public.tasks (id),
  actor_id uuid references public.profiles (id),
  action text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);

create index task_activity_events_task_idx on public.task_activity_events (task_id, created_at);

create table public.sprints (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  project_id uuid not null references public.projects (id),
  name text not null check (char_length(trim(name)) between 1 and 160),
  description text not null default '',
  start_date date not null,
  end_date date not null,
  status text not null default 'planned' check (status in ('planned', 'active', 'closed')),
  created_at timestamptz not null default clock_timestamp(),
  check (end_date >= start_date)
);

create table public.sprint_tasks (
  id uuid primary key default gen_random_uuid(),
  sprint_id uuid not null references public.sprints (id),
  task_id uuid not null references public.tasks (id),
  carried_from_sprint_id uuid references public.sprints (id),
  added_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz
);

create unique index sprint_tasks_one_current_idx
  on public.sprint_tasks (task_id)
  where removed_at is null;

create table public.milestones (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  project_id uuid not null references public.projects (id),
  title text not null check (char_length(trim(title)) between 1 and 160),
  description text not null default '',
  target_date date not null,
  status text not null default 'open' check (status in ('open', 'reached', 'archived')),
  created_at timestamptz not null default clock_timestamp()
);

create table public.milestone_tasks (
  milestone_id uuid not null references public.milestones (id),
  task_id uuid not null references public.tasks (id),
  primary key (milestone_id, task_id)
);

-- Original clock times never move. Approved corrections change effective_*.
create table public.attendance_intervals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  origin text not null check (origin in ('clock', 'approved_correction')),
  status text not null check (status in ('open', 'closed', 'incomplete', 'void')),
  original_started_at timestamptz not null,
  original_ended_at timestamptz,
  effective_started_at timestamptz not null,
  effective_ended_at timestamptz,
  start_platform text,
  end_platform text,
  created_at timestamptz not null default clock_timestamp(),
  check (original_ended_at is null or original_ended_at > original_started_at),
  check (effective_ended_at is null or effective_ended_at > effective_started_at),
  check (status <> 'open' or (effective_ended_at is null and original_ended_at is null)),
  check (status <> 'closed' or effective_ended_at is not null)
);

-- The concurrency backstop: one open interval per person in the whole system.
create unique index attendance_one_open_idx
  on public.attendance_intervals (profile_id)
  where status = 'open';

create index attendance_intervals_profile_idx
  on public.attendance_intervals (profile_id, original_started_at desc);

create table public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  interval_id uuid references public.attendance_intervals (id),
  event_type text not null check (event_type in (
    'clock_in', 'clock_out', 'flagged_incomplete', 'correction_requested', 'correction_decided'
  )),
  occurred_at timestamptz not null default clock_timestamp(),
  platform text,
  metadata jsonb not null default '{}'::jsonb
);

create index attendance_events_profile_idx on public.attendance_events (profile_id, occurred_at);

create table public.attendance_corrections (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  team_id uuid not null references public.teams (id),
  interval_id uuid references public.attendance_intervals (id),
  kind text not null check (kind in (
    'missing_in', 'missing_out', 'edit_in', 'edit_out', 'delete_interval'
  )),
  proposed_started_at timestamptz,
  proposed_ended_at timestamptz,
  reason text not null check (char_length(trim(reason)) > 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default clock_timestamp(),
  check (status = 'pending' or decided_by is not null),
  check (status <> 'rejected' or char_length(trim(coalesce(decision_reason, ''))) > 0)
);

create unique index attendance_one_pending_correction_idx
  on public.attendance_corrections (interval_id)
  where status = 'pending' and interval_id is not null;

create table public.attendance_daily_segments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  interval_id uuid not null references public.attendance_intervals (id),
  tehran_date date not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  approval_mode text not null check (approval_mode in ('report', 'correction')),
  correction_id uuid references public.attendance_corrections (id),
  superseded_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check (ended_at > started_at)
);

create unique index attendance_segments_active_day_idx
  on public.attendance_daily_segments (interval_id, tehran_date)
  where superseded_at is null;

create index attendance_segments_profile_day_idx
  on public.attendance_daily_segments (profile_id, tehran_date);

create table public.attendance_daily_reports (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  team_id uuid not null references public.teams (id),
  tehran_date date not null,
  sequence integer not null check (sequence > 0),
  kind text not null check (kind in ('primary', 'supplemental', 'automatic')),
  submission_source text not null check (submission_source in ('manual', 'automatic')),
  status text not null default 'pending' check (status in (
    'pending', 'partially_approved', 'approved', 'needs_revision', 'rejected'
  )),
  submitted_at timestamptz not null default clock_timestamp(),
  unique (profile_id, tehran_date, sequence)
);

create index attendance_reports_team_idx
  on public.attendance_daily_reports (team_id, status, tehran_date);

create table public.attendance_report_items (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.attendance_daily_reports (id),
  segment_id uuid not null unique references public.attendance_daily_segments (id),
  decision text not null default 'pending' check (decision in (
    'pending', 'approved', 'needs_revision', 'rejected'
  )),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  reason text
);

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  team_id uuid not null references public.teams (id),
  kind text not null check (kind in ('daily', 'hourly')),
  start_date date,
  end_date date,
  hours_date date,
  start_time time,
  end_time time,
  note text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default clock_timestamp(),
  check (
    (
      kind = 'daily'
      and start_date is not null
      and end_date is not null
      and end_date >= start_date
      and hours_date is null
    )
    or (
      kind = 'hourly'
      and hours_date is not null
      and start_time is not null
      and end_time is not null
      and end_time > start_time
      and start_date is null
    )
  ),
  check (status <> 'rejected' or char_length(trim(coalesce(decision_reason, ''))) > 0)
);

create index leave_requests_team_idx on public.leave_requests (team_id, status, created_at desc);

create table public.absence_records (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  profile_id uuid not null references public.profiles (id),
  team_id uuid not null references public.teams (id),
  start_date date not null,
  end_date date not null,
  reason text not null check (char_length(trim(reason)) > 0),
  recorded_by uuid not null references public.profiles (id),
  created_at timestamptz not null default clock_timestamp(),
  check (end_date >= start_date)
);

create table public.absence_disputes (
  id uuid primary key default gen_random_uuid(),
  absence_id uuid not null references public.absence_records (id),
  profile_id uuid not null references public.profiles (id),
  explanation text not null check (char_length(trim(explanation)) > 0),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default clock_timestamp()
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  recipient_id uuid not null references public.profiles (id),
  category text not null,
  title text not null,
  body text not null,
  entity_type text,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);

create index notifications_unread_idx
  on public.notifications (recipient_id, created_at desc)
  where read_at is null;

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id),
  actor_id uuid references public.profiles (id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);

create index audit_logs_workspace_idx on public.audit_logs (workspace_id, created_at desc);
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id);

create table public.app_settings (
  workspace_id uuid not null references public.workspaces (id),
  key text not null,
  value jsonb not null,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (workspace_id, key)
);
