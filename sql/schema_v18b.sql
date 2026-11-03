-- v18b: demote_supervisor logs its own detailed row
create or replace function public.demote_supervisor(p_sup uuid, p_to uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  s   public.profiles; r public.profiles; tg public.sup_targets;
  now_l timestamp := (now() at time zone 'Africa/Cairo');
  ps timestamp; pe timestamp; kept int; n int := 0; t public.tasks; f uuid[]; nst text;
begin
  select * into s from public.profiles where id = p_sup for update;
  if not found or s.role <> 'supervisor' then raise exception 'not_found'; end if;
  if p_sup = auth.uid() then raise exception 'cannot_change_self'; end if;
  if not (public.is_admin()
          or (public.my_role() = 'gm' and s.hotel = public.my_hotel())
          or (public.my_role() = 'manager' and public.in_my_scope(p_sup))) then
    raise exception 'not_allowed';
  end if;
  select * into r from public.profiles where id = p_to;
  if not found or not r.active or r.id = p_sup or r.hotel is distinct from s.hotel
     or r.role not in ('supervisor','manager','gm') then raise exception 'bad_assignee'; end if;
  if public.my_role() = 'manager' and not (r.id = auth.uid() or (r.role = 'supervisor' and public.in_my_scope(r.id))) then
    raise exception 'assign_not_allowed';
  end if;

  -- split the target of the running period by days
  select * into tg from public.sup_targets where supervisor = p_sup;
  if found then
    if tg.period = 'week' then
      ps := date_trunc('day', now_l) - ((extract(dow from now_l)::int + 1) % 7) * interval '1 day';
      pe := ps + interval '7 days';
    else
      ps := date_trunc('month', now_l); pe := ps + interval '1 month';
    end if;
    kept := greatest(0, round(tg.target * extract(epoch from (now_l - ps)) / extract(epoch from (pe - ps))))::int;
    if r.role = 'supervisor' and tg.target - kept > 0 then
      insert into public.sup_target_adj (supervisor, hotel, period, period_start, extra, from_user)
      values (p_to, s.hotel, tg.period, ps at time zone 'Africa/Cairo', tg.target - kept, p_sup);
    end if;
    delete from public.sup_targets where supervisor = p_sup;
  end if;

  -- hand over every unfinished task he has
  for t in select * from public.tasks where assignee = p_sup and status <> 'done' for update loop
    nst := case when t.status in ('progress','review','rejected') then 'todo' else t.status end;
    f := t.prev_assignees; if not (p_sup = any(f)) then f := f || p_sup; end if; f := array_remove(f, p_to);
    perform set_config('app.transfer_note', 'role change', true);
    update public.tasks set assignee = p_to, transferred_from = p_sup, transferred_by = auth.uid(), transferred_at = now(),
      prev_assignees = f, status = nst, status_at = case when nst <> t.status then now() else t.status_at end, updated_at = now()
    where id = t.id;
    insert into public.task_events (task_id, actor, action, from_status, to_status, note)
    values (t.id, auth.uid(), 'transfer', t.status, nst, p_sup::text || '>' || p_to::text || '|role change');
    n := n + 1;
  end loop;

  perform set_config('app.demote', '1', true);
  update public.profiles set role = 'staff', reports_to = case when r.role = 'supervisor' then p_to else reports_to end where id = p_sup;
  -- people who reported to him now report to the one who took over
  update public.profiles set reports_to = p_to where reports_to = p_sup and id <> p_to;

  insert into public.role_changes (user_id, hotel, dept, from_role, to_role, changed_by, handover_to, moved,
                                   period, period_start, period_end, target_full, target_kept)
  values (p_sup, s.hotel, s.dept, 'supervisor', 'staff', auth.uid(), p_to, n,
          tg.period, ps at time zone 'Africa/Cairo', pe at time zone 'Africa/Cairo', tg.target, kept);
  return n;
end $$;
revoke execute on function public.demote_supervisor(uuid, uuid) from public, anon;
grant execute on function public.demote_supervisor(uuid, uuid) to authenticated;
