-- v18: every role change is logged, so each person is judged per role period
-- (tasks while staff count as staff; tasks while supervisor count for the supervisor period only)
create or replace function public.log_role_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and coalesce(current_setting('app.demote', true), '') <> '1'
     and old.role <> 'pending' then
    insert into public.role_changes (user_id, hotel, dept, from_role, to_role, changed_by)
    values (new.id, new.hotel, new.dept, old.role, new.role, auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists trg_log_role_change on public.profiles;
create trigger trg_log_role_change after update of role on public.profiles
  for each row execute function public.log_role_change();

-- role a person had at a given moment
create or replace function public.role_at(_u uuid, _ts timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select to_role from public.role_changes where user_id = _u and changed_at <= _ts order by changed_at desc limit 1),
    (select from_role from public.role_changes where user_id = _u and changed_at > _ts order by changed_at asc limit 1),
    (select role from public.profiles where id = _u))
$$;

-- same as team_stats2 but split by the role the person had when each task was created
create or replace function public.team_stats3(p_since timestamptz default null, p_until timestamptz default null, p_hotel text default null)
returns table(user_id uuid, role_at text, open_count int, review_count int, done_count int, late_count int, rejections int,
              with_due int, on_time int, avg_work_sec numeric, avg_start_sec numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  rl   text := public.my_role();
  myh  text := public.my_hotel();
  mydp text := public.my_dept();
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  return query
  with s as (
    select t.*, public.role_at(t.assignee, t.created_at) as rat,
      ((p_since is null or t.created_at >= p_since) and (p_until is null or t.created_at < p_until)) as in_c,
      (t.completed_at is not null and (p_since is null or t.completed_at >= p_since) and (p_until is null or t.completed_at < p_until)) as in_d
    from public.tasks t join public.profiles p on p.id = t.assignee
    where (rl = 'admin' and (p_hotel is null or t.hotel = p_hotel))
       or (rl in ('gm','supervisor') and t.hotel = myh)
       or (t.hotel = myh and ((p.dept <> '' and p.dept = mydp) or p.id = auth.uid()))
  )
  select s.assignee, s.rat,
    count(*) filter (where s.status <> 'done' and (p_until is null or s.in_c))::int,
    count(*) filter (where s.status = 'review' and (p_until is null or s.in_c))::int,
    count(*) filter (where s.status = 'done' and s.in_d)::int,
    count(*) filter (where s.status <> 'done' and s.due is not null and s.due < now() and (p_until is null or s.in_c))::int,
    coalesce(sum(s.rejections) filter (where s.in_c), 0)::int,
    count(*) filter (where s.status = 'done' and s.due is not null and s.in_d)::int,
    count(*) filter (where s.status = 'done' and s.due is not null and s.completed_at <= s.due and s.in_d)::int,
    avg(extract(epoch from (s.completed_at - s.started_at))) filter (where s.status = 'done' and s.started_at is not null and s.in_d),
    avg(extract(epoch from (s.started_at - s.created_at))) filter (where s.started_at is not null and s.in_c)
  from s group by s.assignee, s.rat;
end $$;
revoke execute on function public.team_stats3(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.team_stats3(timestamptz, timestamptz, text) to authenticated;
