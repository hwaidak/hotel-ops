-- v26: HR registry (all employees, with or without an app account), positions catalog, KPI sheets,
--      evaluations (manager KPI sheet, upward, self, probation), frozen results. Admin-only until eval_public.

-- departments: match the hotel structure
update public.departments set label_en='Management',label_ar='الإدارة العليا' where name='administration';
update public.departments set label_en='Front Office',label_ar='المكاتب الأمامية (الاستقبال)' where name='reception';
update public.departments set label_en='Housekeeping',label_ar='الهاوس كيبينج' where name='housekeeping';
update public.departments set label_en='Finance & Admin',label_ar='المالية والإدارة' where name='finance';
update public.departments set label_en='I.T',label_ar='تكنولوجيا المعلومات' where name='it';
update public.departments set label_en='Human Resources',label_ar='الموارد البشرية (HR)' where name='hr';
update public.departments set label_en='Gardeners',label_ar='الحدائق والزراعة' where name='agriculture';
insert into public.departments(name,label_en,label_ar,sort) values
 ('fb','Food & Beverage','الأغذية والمشروبات',20),('kitchen','Kitchen','المطبخ',21),('steward','Steward','الاستيوارد',22),
 ('recreation','Recreation','الترفيه والأنشطة',23),('engineering','Engineering','الهندسة والصيانة',24),('security','Security','الأمن',25),('drivers','Drivers','السائقين',26)
on conflict (name) do nothing;

alter table public.settings add column if not exists eval_public boolean not null default false;
create or replace function public.eval_open() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select eval_public from public.settings where id=1),false); $$;

create table if not exists public.positions(
  id bigserial primary key, dept text not null, title text not null check (length(title) between 1 and 120), title_ar text not null default '',
  section text not null default '', level text not null check (level in ('managerial','supervisory','operational')),
  sort int not null default 0, active boolean not null default true, unique(dept,title));

create table if not exists public.kpis(
  id bigserial primary key, dept text not null, level text not null check (level in ('managerial','supervisory','operational')),
  position_id bigint references public.positions(id) on delete cascade,
  name text not null check (length(name) between 1 and 200), definition text not null default '', formula text not null default '',
  freq text not null default 'monthly' check (freq in ('monthly','quarterly')),
  target numeric not null default 100, unit text not null default 'pct' check (unit in ('pct','min','hours','days','count')),
  dir text not null default 'up' check (dir in ('up','down')), green numeric not null default 100, yellow numeric not null default 90,
  weight numeric not null default 0 check (weight>=0 and weight<=100),
  source text not null default 'manual' check (source in ('manual','tasks_ontime','tasks_done','sup_target')),
  sort int not null default 0, active boolean not null default true);
create index if not exists kpis_set on public.kpis(dept,level,position_id);

create table if not exists public.employees(
  id uuid primary key default gen_random_uuid(), code text, full_name text not null check (length(full_name) between 1 and 120),
  hotel text references public.hotels(code) on update cascade, dept text not null default '',
  position_id bigint references public.positions(id) on delete set null, hire_date date,
  manager_id uuid references public.employees(id) on delete set null, profile_id uuid unique references public.profiles(id) on delete set null,
  phone text not null default '', probation_days int not null default 90 check (probation_days between 0 and 365),
  active boolean not null default true, notes text not null default '', created_at timestamptz not null default now());
create unique index if not exists employees_code on public.employees(hotel,code) where code is not null and code<>'';

create table if not exists public.eval_entries(
  id bigserial primary key, period text not null check (period ~ '^([0-9]{4}-Q[1-4]|PROB)$'),
  emp_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('down','up','self','prob')),
  rater uuid references public.profiles(id) on delete set null default auth.uid(),
  on_behalf uuid references public.employees(id) on delete set null,
  vals jsonb not null default '{}'::jsonb, note text not null default '' check (length(note)<=3000),
  recommendation text check (recommendation in ('confirm','extend','terminate')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create unique index if not exists eval_one_sheet on public.eval_entries(period,emp_id,kind) where kind in ('down','self','prob');
create unique index if not exists eval_one_up on public.eval_entries(period,emp_id,rater,coalesce(on_behalf,'00000000-0000-0000-0000-000000000000'::uuid)) where kind='up';

create table if not exists public.eval_results(
  id bigserial primary key, period text not null, emp_id uuid not null references public.employees(id) on delete cascade,
  score numeric, grade text, data jsonb not null default '{}'::jsonb,
  published_by uuid references public.profiles(id) on delete set null default auth.uid(), published_at timestamptz not null default now(),
  unique(period,emp_id));

-- discipline now points at the registry (keeps the account id too, so reports keep working)
alter table public.disc_records add column if not exists emp_id uuid references public.employees(id) on delete cascade;
alter table public.disc_records alter column employee drop not null;

-- ---------- helpers ----------
create or replace function public.my_emp() returns uuid language sql stable security definer set search_path=public as $$
  select id from public.employees where profile_id=auth.uid() $$;
create or replace function public.emp_above(_boss uuid, _emp uuid) returns boolean language sql stable security definer set search_path=public as $$
  with recursive ch(id,d) as (select e.manager_id,1 from public.employees e where e.id=_emp
    union all select e.manager_id,c.d+1 from public.employees e join ch c on e.id=c.id where c.id is not null and c.d<25)
  select _boss is not null and _emp is not null and exists(select 1 from ch where id=_boss) $$;
create or replace function public.emp_row_hotel(e uuid) returns text language sql stable security definer set search_path=public as $$ select hotel from public.employees where id=e $$;
-- who may see an employee record: admin; HR / GM of the hotel; manager of the dept; anyone above in the chain; the person himself
create or replace function public.can_see_emp(e uuid) returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or exists(select 1 from public.employees x, public.profiles me where x.id=e and me.id=auth.uid() and me.active
    and (x.profile_id=me.id or (x.hotel=me.hotel and (me.dept='hr' or me.role='gm' or (me.role='manager' and (coalesce(me.dept,'')='' or me.dept=x.dept))))
      or public.emp_above(public.my_emp(),x.id) or public.emp_above(x.id,public.my_emp()))) $$;

alter table public.positions enable row level security; alter table public.kpis enable row level security;
alter table public.employees enable row level security; alter table public.eval_entries enable row level security; alter table public.eval_results enable row level security;
drop policy if exists pos_read on public.positions; create policy pos_read on public.positions for select using (public.is_member());
drop policy if exists pos_write on public.positions; create policy pos_write on public.positions for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists kpi_read on public.kpis; create policy kpi_read on public.kpis for select using (public.is_member());
drop policy if exists kpi_write on public.kpis; create policy kpi_write on public.kpis for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists emp_read on public.employees; create policy emp_read on public.employees for select using (public.is_admin() or ((public.eval_open() or public.disc_open()) and public.can_see_emp(id)));
drop policy if exists emp_write on public.employees; create policy emp_write on public.employees for all using (public.is_admin()) with check (public.is_admin());

-- who may write a sheet: admin always (also on behalf of a paper form); when open: the boss chain (down/prob), the team (up, about a boss above them), the person (self)
create or replace function public.can_rate(e uuid, k text) returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or (public.eval_open() and case k
    when 'self' then exists(select 1 from public.employees x where x.id=e and x.profile_id=auth.uid())
    when 'up' then public.emp_above(e, public.my_emp())
    else public.emp_above(public.my_emp(), e) end) $$;
drop policy if exists ev_read on public.eval_entries; create policy ev_read on public.eval_entries for select using (
  public.is_admin() or (public.eval_open() and (rater=auth.uid() or (kind<>'up' and public.emp_above(public.my_emp(),emp_id)))));
drop policy if exists ev_ins on public.eval_entries; create policy ev_ins on public.eval_entries for insert with check (rater=auth.uid() and public.can_rate(emp_id,kind)
  and (public.is_admin() or period='PROB' or period in (to_char(now(),'YYYY-"Q"Q'), to_char(now()-interval '3 months','YYYY-"Q"Q'))));
drop policy if exists ev_upd on public.eval_entries; create policy ev_upd on public.eval_entries for update using (public.is_admin() or (rater=auth.uid() and public.eval_open()))
  with check (public.can_rate(emp_id,kind) and (public.is_admin() or rater=auth.uid()));
drop policy if exists ev_del on public.eval_entries; create policy ev_del on public.eval_entries for delete using (public.is_admin() or (rater=auth.uid() and public.eval_open()));
drop policy if exists er_read on public.eval_results; create policy er_read on public.eval_results for select using (public.is_admin() or (public.eval_open() and public.can_see_emp(emp_id)));
drop policy if exists er_write on public.eval_results; create policy er_write on public.eval_results for all using (public.is_admin()) with check (public.is_admin());
create or replace function public.ev_touch() returns trigger language plpgsql as $$ begin new.updated_at:=now(); if tg_op='INSERT' then new.created_at:=now(); end if; return new; end $$;
drop trigger if exists ev_touch on public.eval_entries; create trigger ev_touch before insert or update on public.eval_entries for each row execute function public.ev_touch();

grant select,insert,update,delete on public.positions,public.kpis,public.employees,public.eval_entries,public.eval_results to authenticated;
grant usage on all sequences in schema public to authenticated;

-- ---------- keep the registry in step with app accounts ----------
create or replace function public.sync_emp_from_profile() returns trigger language plpgsql security definer set search_path=public as $$
declare boss uuid;
begin
  if new.role in ('pending','admin') then return new; end if;
  select id into boss from public.employees where profile_id=new.reports_to;
  if exists(select 1 from public.employees where profile_id=new.id) then
    update public.employees set full_name=new.full_name, hotel=new.hotel, dept=coalesce(new.dept,''), active=new.active,
      manager_id=coalesce(boss,manager_id) where profile_id=new.id;
  else
    insert into public.employees(full_name,hotel,dept,hire_date,profile_id,manager_id,active)
      values(new.full_name,new.hotel,coalesce(new.dept,''),new.created_at::date,new.id,boss,new.active);
  end if;
  return new;
end $$;
drop trigger if exists sync_emp on public.profiles;
create trigger sync_emp after insert or update of full_name,hotel,dept,role,active,reports_to on public.profiles for each row execute function public.sync_emp_from_profile();

-- ---------- discipline on the registry ----------
create or replace function public.disc_fill() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.emp_id is null and new.employee is not null then select id into new.emp_id from public.employees where profile_id=new.employee; end if;
  select coalesce(e.dept,''), e.hotel, e.profile_id into new.dept, new.hotel, new.employee from public.employees e where e.id=new.emp_id;
  if tg_op='INSERT' then new.created_by:=auth.uid(); new.created_at:=now(); end if;
  if new.kind in ('notice','warning') then new.days:=0; end if;
  return new;
end $$;
create or replace function public.can_see_disc2(e uuid, h text, d text) returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or (public.disc_open() and (public.is_hr_of(h) or exists(select 1 from public.employees x where x.id=e and x.profile_id=auth.uid())
    or exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.hotel=h and (p.role='gm' or (p.role='manager' and (coalesce(p.dept,'')='' or p.dept=d))))
    or public.emp_above(public.my_emp(),e))) $$;
drop policy if exists disc_read on public.disc_records; create policy disc_read on public.disc_records for select using (public.can_see_disc2(emp_id,hotel,dept));
drop policy if exists disc_ins on public.disc_records; create policy disc_ins on public.disc_records for insert with check (public.is_hr_of(hotel) and public.emp_row_hotel(emp_id)=hotel);
drop policy if exists disc_upd on public.disc_records; create policy disc_upd on public.disc_records for update using (public.is_hr_of(hotel)) with check (public.is_hr_of(hotel) and public.emp_row_hotel(emp_id)=hotel);

drop function if exists public.disc_people();
create or replace function public.disc_people() returns table(id uuid, full_name text, dept text, hotel text, role text, active boolean, reports_to uuid, profile_id uuid, code text, position_id bigint)
language sql stable security definer set search_path=public as $$
  select x.id,x.full_name,x.dept,x.hotel,
    coalesce((select p.role from public.profiles p where p.id=x.profile_id and p.role not in ('pending','admin')),
      case (select level from public.positions q where q.id=x.position_id) when 'managerial' then 'manager' when 'supervisory' then 'supervisor' else 'staff' end),
    x.active,x.manager_id,x.profile_id,x.code,x.position_id
  from public.employees x, public.profiles me
  where me.id=auth.uid() and me.active and me.role<>'pending'
    and (me.role='admin' or (public.disc_open() and x.hotel=me.hotel and (me.dept='hr' or me.role='gm' or x.profile_id=me.id
      or (me.role='manager' and (coalesce(me.dept,'')='' or x.dept=me.dept)) or public.emp_above(public.my_emp(),x.id)))) $$;
grant execute on function public.disc_people() to authenticated;
