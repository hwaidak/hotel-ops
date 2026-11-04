-- v20b: private storage for proof files + helpers for the 30-day cleanup
insert into storage.buckets (id, name, public, file_size_limit)
values ('task-files', 'task-files', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists "task files read" on storage.objects;
create policy "task files read" on storage.objects for select to authenticated
  using (bucket_id = 'task-files' and exists (select 1 from public.task_files f where f.path = name));

drop policy if exists "task files upload" on storage.objects;
create policy "task files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'task-files' and name ~ '^[0-9]+/[A-Za-z0-9._-]+$'
              and exists (select 1 from public.tasks t where t.id = split_part(name, '/', 1)::bigint
                          and (public.can_see_task(t.assignee, t.reporter, t.parent_id, t.hotel)
                               or (t.hotel = public.my_hotel() and auth.uid() = any(t.prev_assignees)))));

-- files older than 30 days (only the cleanup job, running with the service role, may call these)
create or replace function public.purge_due_files() returns table(path text)
language sql security definer set search_path = public, storage as $$
  select o.name from storage.objects o
  where o.bucket_id = 'task-files' and o.created_at < now() - interval '30 days'
  limit 1000
$$;
create or replace function public.mark_files_purged(p_paths text[]) returns int
language sql security definer set search_path = public as $$
  with u as (update public.task_files set expired = true where path = any(p_paths) and not expired returning 1)
  select count(*)::int from u
$$;
revoke execute on function public.purge_due_files() from public, anon, authenticated;
revoke execute on function public.mark_files_purged(text[]) from public, anon, authenticated;
grant execute on function public.purge_due_files() to service_role;
grant execute on function public.mark_files_purged(text[]) to service_role;
