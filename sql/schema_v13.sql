-- v13: a supervisor can never approve his own task.
-- A task given to a supervisor by a department manager / hotel manager / admin must be approved by them
-- (or by the supervisor's direct manager), even if "needs approval" was unticked.
-- Supervisors still approve tasks of their own staff normally.
create or replace function public.role_rank(_r text) returns int language sql immutable as $$
  select case _r when 'admin' then 5 when 'gm' then 4 when 'manager' then 3 when 'supervisor' then 2 when 'staff' then 1 else 0 end
$$;

create or replace function public.task_needs_boss(_assignee uuid, _reporter uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select _assignee is not null and _reporter is not null and _assignee <> _reporter
     and exists (select 1 from public.profiles a, public.profiles r
                 where a.id = _assignee and r.id = _reporter
                   and a.role = 'supervisor' and r.role in ('manager','gm','admin'))
$$;

create or replace function public.can_approve(_assignee uuid, _reporter uuid, _hotel text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_hotel_admin(_hotel)
      or (public.is_member() and _hotel = public.my_hotel() and _assignee is distinct from auth.uid() and (
            public.is_above(auth.uid(), _assignee)
         or (public.is_dept_boss(_assignee)
             and public.role_rank(public.my_role()) > public.role_rank((select role from public.profiles where id = _assignee)))
         or (_reporter = auth.uid() and _assignee is not null)))
$$;

create or replace function public.transition_task(p_id bigint, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t    public.tasks;
  appr boolean;
  ok   boolean := false;
  act  text := 'move';
  note text := nullif(trim(coalesce(p_note, '')), '');
  na   boolean;
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  if p_to not in ('todo','progress','review','rejected','done') then raise exception 'bad_status'; end if;
  select * into t from public.tasks where id = p_id for update;
  if not found or not (public.can_see_task(t.assignee, t.reporter, t.parent_id, t.hotel)
                       or (t.hotel = public.my_hotel() and auth.uid() = any(t.prev_assignees))) then
    raise exception 'not_found';
  end if;
  if t.status = p_to then raise exception 'same_status'; end if;
  appr := public.can_approve(t.assignee, t.reporter, t.hotel)
          or (t.hotel = public.my_hotel() and t.assignee is not null and t.assignee <> auth.uid()
              and auth.uid() = any(t.prev_assignees));
  if appr then ok := (p_to <> 'rejected' or t.status = 'review'); end if;
  if not ok and t.assignee = auth.uid() then
    na := t.needs_approval or public.task_needs_boss(t.assignee, t.reporter);
    ok := (t.status = 'todo'     and p_to = 'progress')
       or (t.status = 'rejected' and p_to = 'progress')
       or (t.status = 'progress' and p_to = 'review' and na)
       or (t.status = 'progress' and p_to = 'done'   and not na)
       or (t.status = 'review'   and p_to = 'progress');
  end if;
  if not ok then raise exception 'not_allowed'; end if;
  if p_to = 'rejected' and note is null then raise exception 'reason_required'; end if;
  if p_to = 'done' and t.status = 'review' then act := 'approve';
  elsif p_to = 'rejected' then act := 'reject';
  end if;
  update public.tasks set
    status       = p_to,
    status_at    = now(),
    updated_at   = now(),
    started_at   = case when started_at is null and p_to = 'progress' then now()
                        when started_at is null and p_to = 'done'     then created_at
                        else started_at end,
    submitted_at = case when p_to = 'review' then now()
                        when p_to = 'done' and submitted_at is null then now()
                        else submitted_at end,
    completed_at = case when p_to = 'done' then now() else null end,
    approval_by  = case when p_to = 'done' then auth.uid() else null end,
    approval_at  = case when p_to = 'done' then now() else null end,
    approval_note= case when p_to = 'done' then note else null end,
    rejections   = rejections + case when p_to = 'rejected' then 1 else 0 end,
    last_reject_note = case when p_to = 'rejected' then note       else last_reject_note end,
    last_reject_by   = case when p_to = 'rejected' then auth.uid() else last_reject_by end,
    last_reject_at   = case when p_to = 'rejected' then now()      else last_reject_at end
  where id = p_id;
  insert into public.task_events (task_id, actor, action, from_status, to_status, note)
  values (p_id, auth.uid(), act, t.status, p_to, note);
end $$;
