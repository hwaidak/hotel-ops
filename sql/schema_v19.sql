-- v19: slim task rows for the reports page (numbers and times only, no titles or details)
-- staff and supervisors see their own department, read-only; managers their scope; gm the hotel; admin all
create or replace function public.report_tasks(p_hotel text default null)
returns table(id bigint, hotel text, dept text, assignee uuid, reporter uuid, transferred_by uuid, parent_id bigint,
              parent_assignee uuid, status text, due timestamptz, created_at timestamptz, started_at timestamptz,
              submitted_at timestamptz, completed_at timestamptz, rejections int)
language plpgsql stable security definer set search_path = public as $$
declare rl text := public.my_role(); myh text := public.my_hotel(); mydp text := coalesce(public.my_dept(), '');
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  return query
  select t.id, t.hotel, t.dept, t.assignee, t.reporter, t.transferred_by, t.parent_id,
         (select pt.assignee from public.tasks pt where pt.id = t.parent_id),
         t.status, t.due, t.created_at, t.started_at, t.submitted_at, t.completed_at, t.rejections
  from public.tasks t
  left join public.profiles a on a.id = t.assignee
  left join public.profiles r on r.id = t.reporter
  where (rl = 'admin' and (p_hotel is null or t.hotel = p_hotel))
     or (rl = 'gm' and t.hotel = myh)
     or (t.hotel = myh and (mydp = '' and rl in ('manager','supervisor')
                            or t.dept = mydp or a.dept = mydp or r.dept = mydp
                            or t.assignee = auth.uid() or t.reporter = auth.uid()))
  order by t.created_at desc limit 5000;
end $$;
revoke execute on function public.report_tasks(text) from public, anon;
grant execute on function public.report_tasks(text) to authenticated;

-- team_stats3: supervisors now see their department (not the whole hotel), like everyone else
create or replace function public.team_stats3(p_since timestamptz default null, p_until timestamptz default null, p_hotel text default null)
returns table(user_id uuid, role_at text, open_count int, review_count int, done_count int, late_count int, rejections int,
              with_due int, on_time int, avg_work_sec numeric, avg_start_sec numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  rl   text := public.my_role();
  myh  text := public.my_hotel();
  mydp text := coalesce(public.my_dept(), '');
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  return query
  with s as (
    select t.*, public.role_at(t.assignee, t.created_at) as rat,
      ((p_since is null or t.created_at >= p_since) and (p_until is null or t.created_at < p_until)) as in_c,
      (t.completed_at is not null and (p_since is null or t.completed_at >= p_since) and (p_until is null or t.completed_at < p_until)) as in_d
    from public.tasks t join public.profiles p on p.id = t.assignee
    where (rl = 'admin' and (p_hotel is null or t.hotel = p_hotel))
       or (rl = 'gm' and t.hotel = myh)
       or (t.hotel = myh and ((mydp = '' and rl in ('manager','supervisor')) or (p.dept <> '' and p.dept = mydp) or p.id = auth.uid()))
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
