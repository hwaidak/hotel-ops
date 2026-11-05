-- v25: HR discipline records (absences, notices, warnings, penalties)
create table if not exists public.disc_records(
  id bigserial primary key,
  hotel text not null,
  employee uuid not null references public.profiles(id) on delete cascade,
  dept text not null default '',
  kind text not null check (kind in ('absence','notice','warning','penalty')),
  on_date date not null default current_date,
  days numeric(5,2) not null default 0 check (days>=0 and days<=60),
  reason text not null default '' check (length(reason)<=1000),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists disc_records_emp on public.disc_records(employee,on_date);
create index if not exists disc_records_hotel on public.disc_records(hotel,on_date);
alter table public.disc_records enable row level security;
alter table public.settings add column if not exists disc_public boolean not null default false;
create or replace function public.disc_open() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select disc_public from public.settings where id=1),false);
$$;

-- HR staff (any role in the hr dept) of the same hotel, or admin
create or replace function public.is_hr_of(h text) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.role<>'pending'
    and (p.role='admin' or (public.disc_open() and p.dept='hr' and p.hotel=h)));
$$;

create or replace function public.can_see_disc(emp uuid, h text, d text) returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or (public.disc_open() and (emp=auth.uid() or public.is_hr_of(h) or exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.hotel=h
    and (p.role='gm' or (p.role in ('manager','supervisor') and (coalesce(p.dept,'')='' or p.dept=d))))));
$$;

drop policy if exists disc_read on public.disc_records;
create policy disc_read on public.disc_records for select using (public.can_see_disc(employee,hotel,dept));
drop policy if exists disc_ins on public.disc_records;
create policy disc_ins on public.disc_records for insert with check (public.is_hr_of(hotel)
  and exists(select 1 from public.profiles e where e.id=employee and e.hotel=disc_records.hotel));
drop policy if exists disc_upd on public.disc_records;
create policy disc_upd on public.disc_records for update using (public.is_hr_of(hotel)) with check (public.is_hr_of(hotel));
drop policy if exists disc_del on public.disc_records;
create policy disc_del on public.disc_records for delete using (public.is_hr_of(hotel));

-- dept + hotel always copied from the employee, creator stamped
create or replace function public.disc_fill() returns trigger language plpgsql security definer set search_path=public as $$
begin
  select coalesce(e.dept,''), e.hotel into new.dept, new.hotel from public.profiles e where e.id=new.employee;
  if tg_op='INSERT' then new.created_by:=auth.uid(); new.created_at:=now(); end if;
  if new.kind in ('notice','warning') then new.days:=0; end if;
  return new;
end $$;
drop trigger if exists disc_fill on public.disc_records;
create trigger disc_fill before insert or update on public.disc_records for each row execute function public.disc_fill();

-- people list for the discipline page (HR / GM / admin see the whole hotel, dept heads their dept, others themselves)
drop function if exists public.disc_people();
create or replace function public.disc_people() returns table(id uuid, full_name text, dept text, hotel text, role text, active boolean, reports_to uuid)
language sql stable security definer set search_path=public as $$
  select p.id,p.full_name,coalesce(p.dept,''),p.hotel,p.role,p.active,p.reports_to from public.profiles p, public.profiles me
  where me.id=auth.uid() and me.active and me.role<>'pending' and p.role not in ('pending','admin')
    and (me.role='admin' or (public.disc_open() and p.hotel=me.hotel and (me.dept='hr' or me.role='gm' or p.id=me.id
      or (me.role in ('manager','supervisor') and (coalesce(me.dept,'')='' or p.dept=me.dept)))));
$$;
grant execute on function public.disc_people() to authenticated;
grant select,insert,update,delete on public.disc_records to authenticated;
grant usage on sequence public.disc_records_id_seq to authenticated;

-- v25b: employee-hotel check must bypass profiles RLS (HR can't read other depts' profiles)
create or replace function public.emp_hotel(e uuid) returns text language sql stable security definer set search_path=public as $$ select hotel from public.profiles where id=e $$;
drop policy if exists disc_ins on public.disc_records;
create policy disc_ins on public.disc_records for insert with check (public.is_hr_of(hotel) and public.emp_hotel(employee)=hotel);
drop policy if exists disc_upd on public.disc_records;
create policy disc_upd on public.disc_records for update using (public.is_hr_of(hotel)) with check (public.is_hr_of(hotel) and public.emp_hotel(employee)=hotel);

-- v25c: supervisors see only themselves + their own team; managers see their department
create or replace function public.can_see_disc(emp uuid, h text, d text) returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or (public.disc_open() and (emp=auth.uid() or public.is_hr_of(h) or exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.hotel=h
    and (p.role='gm' or (p.role='manager' and (coalesce(p.dept,'')='' or p.dept=d)) or (p.role='supervisor' and public.is_above(p.id,emp))))));
$$;
create or replace function public.disc_people() returns table(id uuid, full_name text, dept text, hotel text, role text, active boolean, reports_to uuid)
language sql stable security definer set search_path=public as $$
  select p.id,p.full_name,coalesce(p.dept,''),p.hotel,p.role,p.active,p.reports_to from public.profiles p, public.profiles me
  where me.id=auth.uid() and me.active and me.role<>'pending' and p.role not in ('pending','admin')
    and (me.role='admin' or (public.disc_open() and p.hotel=me.hotel and (me.dept='hr' or me.role='gm' or p.id=me.id
      or (me.role='manager' and (coalesce(me.dept,'')='' or p.dept=me.dept))
      or (me.role='supervisor' and public.is_above(me.id,p.id)))));
$$;
