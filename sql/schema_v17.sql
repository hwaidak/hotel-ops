-- v17: team stats for any date range (day / week / a given month / last N days)
create or replace function public.team_stats2(p_since timestamptz default null, p_until timestamptz default null, p_hotel text default null)
returns table(user_id uuid, open_count int, review_count int, done_count int, late_count int, rejections int,
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
    select t.*,
      ((p_since is null or t.created_at >= p_since) and (p_until is null or t.created_at < p_until)) as in_c,
      (t.completed_at is not null and (p_since is null or t.completed_at >= p_since) and (p_until is null or t.completed_at < p_until)) as in_d
    from public.tasks t join public.profiles p on p.id = t.assignee
    where (rl = 'admin' and (p_hotel is null or t.hotel = p_hotel))
       or (rl in ('gm','supervisor') and t.hotel = myh)
       or (t.hotel = myh and ((p.dept <> '' and p.dept = mydp) or p.id = auth.uid()))
  )
  select s.assignee,
    count(*) filter (where s.status <> 'done' and (p_until is null or s.in_c))::int,
    count(*) filter (where s.status = 'review' and (p_until is null or s.in_c))::int,
    count(*) filter (where s.status = 'done' and s.in_d)::int,
    count(*) filter (where s.status <> 'done' and s.due is not null and s.due < now() and (p_until is null or s.in_c))::int,
    coalesce(sum(s.rejections) filter (where s.in_c), 0)::int,
    count(*) filter (where s.status = 'done' and s.due is not null and s.in_d)::int,
    count(*) filter (where s.status = 'done' and s.due is not null and s.completed_at <= s.due and s.in_d)::int,
    avg(extract(epoch from (s.completed_at - s.started_at))) filter (where s.status = 'done' and s.started_at is not null and s.in_d),
    avg(extract(epoch from (s.started_at - s.created_at))) filter (where s.started_at is not null and s.in_c)
  from s group by s.assignee;
end $$;
revoke execute on function public.team_stats2(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.team_stats2(timestamptz, timestamptz, text) to authenticated;
