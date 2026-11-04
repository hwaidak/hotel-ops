-- v20: proof documents. Finishing, submitting or approving a task needs an attached file
-- from the person doing it, plus an accepted responsibility statement.
create table if not exists public.task_files (
  id          bigint generated always as identity primary key,
  task_id     bigint not null references public.tasks(id) on delete cascade,
  path        text not null unique,
  name        text not null,
  mime        text not null default '',
  size        int  not null default 0,
  orig_size   int  not null default 0,
  gz          boolean not null default false,
  stage       text not null default '',
  ack         boolean not null default false,
  expired     boolean not null default false,
  uploaded_by uuid not null default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists task_files_task on public.task_files(task_id);
create index if not exists task_files_created on public.task_files(created_at) where not expired;
alter table public.task_files enable row level security;
drop policy if exists task_files_read on public.task_files;
create policy task_files_read on public.task_files for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id
                 and (public.can_see_task(t.assignee, t.reporter, t.parent_id, t.hotel)
                      or (t.hotel = public.my_hotel() and auth.uid() = any(t.prev_assignees)))));
drop policy if exists task_files_add on public.task_files;
create policy task_files_add on public.task_files for insert to authenticated
  with check (uploaded_by = auth.uid() and not expired
              and size between 1 and 10485760
              and path like task_id::text || '/%'
              and exists (select 1 from public.tasks t where t.id = task_id
                          and (public.can_see_task(t.assignee, t.reporter, t.parent_id, t.hotel)
                               or (t.hotel = public.my_hotel() and auth.uid() = any(t.prev_assignees)))));
grant select, insert on public.task_files to authenticated;

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
  if p_to in ('review','done') and not exists (
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
