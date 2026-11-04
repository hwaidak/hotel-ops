-- v21: proof document can be required or optional per task.
-- Only a supervisor, department manager, hotel manager or the system admin can choose; default is required.
alter table public.tasks add column if not exists proof_required boolean not null default true;

create or replace function public.can_set_proof() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_role() in ('supervisor','manager','gm','admin')
$$;

create or replace function public.create_task(p jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_assignee uuid   := nullif(p->>'assignee', '')::uuid;
  v_parent   bigint := nullif(p->>'parent_id', '')::bigint;
  v_hotel    text;
  par        public.tasks;
  new_id     bigint;
  v_proof    boolean := case when public.can_set_proof() then coalesce((p->>'proof_required')::boolean, true) else true end;
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  if v_parent is not null then
    select * into par from public.tasks where id = v_parent;
    if not found or not public.can_see_task(par.assignee, par.reporter, par.parent_id, par.hotel) then
      raise exception 'not_found';
    end if;
    if not (public.is_hotel_admin(par.hotel) or par.assignee = auth.uid() or par.reporter = auth.uid()) then
      raise exception 'not_allowed';
    end if;
    v_hotel := par.hotel;
  elsif public.is_admin() then
    v_hotel := coalesce(nullif(p->>'hotel', ''), (select hotel from public.profiles where id = v_assignee));
  else
    v_hotel := public.my_hotel();
  end if;
  if v_hotel is null or not exists (select 1 from public.hotels where code = v_hotel) then
    raise exception 'hotel_required';
  end if;
  if v_assignee is not null then
    if not public.can_assign_to(v_assignee) then raise exception 'assign_not_allowed'; end if;
    if (select hotel from public.profiles where id = v_assignee) is distinct from v_hotel then
      raise exception 'other_hotel';
    end if;
  end if;
  insert into public.tasks (title, descr, dept, location, assignee, reporter, priority,
                            due, shift, estimate, needs_approval, parent_id, hotel, no_transfer, proof_required)
  values (trim(p->>'title'), coalesce(p->>'descr', ''),
          coalesce(nullif(p->>'dept', ''), par.dept, ''),
          coalesce(trim(p->>'location'), ''), v_assignee, auth.uid(),
          coalesce(p->>'priority', 'normal'), nullif(p->>'due', '')::timestamptz,
          coalesce(p->>'shift', ''), nullif(p->>'estimate', '')::numeric,
          coalesce((p->>'needs_approval')::boolean, true), v_parent, v_hotel,
          coalesce((p->>'no_transfer')::boolean, false), v_proof)
  returning id into new_id;
  insert into public.task_events (task_id, actor, action, to_status, note)
  values (new_id, auth.uid(), 'create', 'todo', case when v_parent is not null then '#' || v_parent end);
  if v_parent is not null then
    insert into public.task_events (task_id, actor, action, note)
    values (v_parent, auth.uid(), 'delegate', '#' || new_id || ' ' || trim(p->>'title'));
  end if;
  return new_id;
end $$;

create or replace function public.update_task(p_id bigint, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  t          public.tasks;
  n          public.tasks;
  v_assignee uuid := nullif(p->>'assignee', '')::uuid;
  changed    text[] := '{}';
begin
  select * into t from public.tasks where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not (public.is_hotel_admin(t.hotel) or (public.is_member() and t.reporter = auth.uid())) then
    raise exception 'not_allowed';
  end if;
  if v_assignee is distinct from t.assignee and v_assignee is not null then
    if not public.can_assign_to(v_assignee) then raise exception 'assign_not_allowed'; end if;
    if (select hotel from public.profiles where id = v_assignee) is distinct from t.hotel then
      raise exception 'other_hotel';
    end if;
  end if;
  update public.tasks set
    title          = trim(p->>'title'),
    descr          = coalesce(p->>'descr', ''),
    dept           = coalesce(p->>'dept', ''),
    location       = coalesce(trim(p->>'location'), ''),
    assignee       = v_assignee,
    priority       = coalesce(p->>'priority', 'normal'),
    due            = nullif(p->>'due', '')::timestamptz,
    shift          = coalesce(p->>'shift', ''),
    estimate       = nullif(p->>'estimate', '')::numeric,
    needs_approval = coalesce((p->>'needs_approval')::boolean, true),
    no_transfer    = coalesce((p->>'no_transfer')::boolean, t.no_transfer),
    proof_required = case when public.can_set_proof() then coalesce((p->>'proof_required')::boolean, t.proof_required) else t.proof_required end,
    updated_at     = now()
  where id = p_id
  returning * into n;
  if n.title    is distinct from t.title    then changed := changed || 'title'::text; end if;
  if n.descr    is distinct from t.descr    then changed := changed || 'details'::text; end if;
  if n.dept     is distinct from t.dept     then changed := changed || 'department'::text; end if;
  if n.location is distinct from t.location then changed := changed || 'location'::text; end if;
  if n.assignee is distinct from t.assignee then changed := changed || 'assignee'::text; end if;
  if n.priority is distinct from t.priority then changed := changed || 'priority'::text; end if;
  if n.due      is distinct from t.due      then changed := changed || 'due'::text; end if;
  if n.shift    is distinct from t.shift    then changed := changed || 'shift'::text; end if;
  if n.estimate is distinct from t.estimate then changed := changed || 'estimate'::text; end if;
  if n.needs_approval is distinct from t.needs_approval then changed := changed || 'approval'::text; end if;
  if n.no_transfer is distinct from t.no_transfer then changed := changed || 'lock'::text; end if;
  if n.proof_required is distinct from t.proof_required then changed := changed || 'proof'::text; end if;
  if array_length(changed, 1) > 0 then
    insert into public.task_events (task_id, actor, action, note)
    values (p_id, auth.uid(), case when n.assignee is distinct from t.assignee then 'assign' else 'edit' end,
            array_to_string(changed, ','));
  end if;
end $$;

-- the proof is only enforced when the task requires it
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
  -- proof: whoever submits, finishes or approves must have attached a file (and accepted the statement) for this step
  if p_to in ('review','done') and t.proof_required and not exists (
       select 1 from public.task_files f
       where f.task_id = p_id and f.uploaded_by = auth.uid() and f.ack
         and f.created_at >= t.status_at - interval '1 minute') then
    raise exception 'attach_required';
  end if;
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
