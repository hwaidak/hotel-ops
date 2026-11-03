-- v14: monthly / weekly task targets for supervisors, set by the department manager, hotel manager or admin
create table if not exists public.sup_targets (
  supervisor uuid primary key references public.profiles(id) on delete cascade,
  hotel      text,
  period     text not null check (period in ('month','week')),
  target     int  not null check (target > 0 and target <= 10000),
  set_by     uuid,
  updated_at timestamptz not null default now()
);
alter table public.sup_targets enable row level security;
drop policy if exists sup_targets_read on public.sup_targets;
create policy sup_targets_read on public.sup_targets for select to authenticated
  using (public.is_admin() or (public.is_member() and hotel = public.my_hotel()));
grant select on public.sup_targets to authenticated;

create or replace function public.set_sup_target(p_sup uuid, p_period text, p_target int)
returns void language plpgsql security definer set search_path = public as $$
declare s public.profiles;
begin
  select * into s from public.profiles where id = p_sup;
  if not found or s.role <> 'supervisor' then raise exception 'not_found'; end if;
  if not (public.is_admin()
          or (public.my_role() = 'gm' and s.hotel = public.my_hotel())
          or (public.my_role() = 'manager' and public.in_my_scope(p_sup))) then
    raise exception 'not_allowed';
  end if;
  if p_target is null or p_target <= 0 then
    delete from public.sup_targets where supervisor = p_sup; return;
  end if;
  if p_period not in ('month','week') then raise exception 'bad_status'; end if;
  insert into public.sup_targets (supervisor, hotel, period, target, set_by, updated_at)
  values (p_sup, s.hotel, p_period, least(p_target, 10000), auth.uid(), now())
  on conflict (supervisor) do update set hotel = excluded.hotel, period = excluded.period,
    target = excluded.target, set_by = excluded.set_by, updated_at = now();
end $$;
grant execute on function public.set_sup_target(uuid, text, int) to authenticated;
