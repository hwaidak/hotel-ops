-- v16: a supervisor becomes staff only through demote_supervisor (hand-over + target split)
create or replace function public.admin_set_member(p_id uuid, p_role text, p_dept text, p_title text,
                                                   p_active boolean, p_reports_to uuid default null,
                                                   p_hotel text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  cur    public.profiles;
  adm    boolean := public.is_admin();
  rl     text := public.my_role();
  myd    text := coalesce(public.my_dept(), '');
  v_hot  text;
  v_dept text := coalesce(p_dept, '');
  scoped boolean;
begin
  select * into cur from public.profiles where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if cur.role = 'supervisor' and p_role in ('staff','pending') then raise exception 'use_demote'; end if;
  scoped := cur.hotel = public.my_hotel()
            and (myd = '' or cur.dept = myd or (cur.role = 'pending' and cur.requested_dept = myd));
  if adm then
    v_hot := coalesce(nullif(p_hotel, ''), cur.hotel);
  elsif rl = 'gm' and cur.hotel = public.my_hotel() then
    if cur.role in ('admin','gm') or p_role in ('admin','gm') then raise exception 'supervisor_limit'; end if;
    v_hot := public.my_hotel();
  elsif rl = 'manager' and scoped then
    -- department manager: staff and supervisors of his scope
    if cur.role not in ('staff','pending','supervisor') or p_role not in ('staff','pending','supervisor') then raise exception 'supervisor_limit'; end if;
    v_hot := public.my_hotel();
    if myd <> '' then v_dept := myd; end if;
  else
    raise exception 'not_allowed';
  end if;
  if p_role not in ('admin','gm','supervisor','manager','staff','pending') then raise exception 'bad_role'; end if;
  if p_id = auth.uid() and (p_role <> cur.role or not p_active) then raise exception 'cannot_change_self'; end if;
  if p_role <> 'admin' and p_role <> 'pending' and p_active and v_hot is null then raise exception 'hotel_required'; end if;
  if v_hot is not null and not exists (select 1 from public.hotels where code = v_hot) then raise exception 'hotel_required'; end if;
  if v_dept <> '' and not exists (select 1 from public.departments where name = v_dept) then raise exception 'bad_dept'; end if;
  -- department manager: the direct manager must be himself or a supervisor inside his own scope
  if not adm and rl = 'manager' and p_reports_to is not null and p_reports_to <> auth.uid()
     and not exists (select 1 from public.profiles b where b.id = p_reports_to and b.role = 'supervisor' and public.in_my_scope(b.id)) then
    raise exception 'boss_not_manager';
  end if;
  if p_reports_to is not null then
    if p_reports_to = p_id or public.is_above(p_id, p_reports_to) then raise exception 'hierarchy_cycle'; end if;
    if not exists (select 1 from public.profiles
                   where id = p_reports_to and active
                     and (role = 'admin' or (role in ('gm','supervisor','manager') and hotel = v_hot))) then
      raise exception 'boss_not_manager';
    end if;
  end if;
  update public.profiles set
    role = p_role, dept = v_dept, title = left(coalesce(p_title, ''), 60),
    active = p_active, reports_to = p_reports_to, hotel = v_hot
  where id = p_id;
end $$;

