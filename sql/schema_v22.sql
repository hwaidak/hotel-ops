-- v22: show emails on the team page; reset a password to the standard one and force a new one at next sign-in
alter table public.profiles add column if not exists must_change_password boolean not null default false;

-- can the caller manage this person (same rules as the team page)?
create or replace function public.can_manage_member(_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select _id <> auth.uid() and exists (
    select 1 from public.profiles p where p.id = _id and (
         public.is_admin()
      or (public.my_role() = 'gm' and p.hotel = public.my_hotel() and p.role not in ('admin','gm'))
      or (public.my_role() = 'manager' and p.hotel = public.my_hotel() and p.role in ('staff','pending','supervisor')
          and (coalesce(public.my_dept(),'') = '' or p.dept = public.my_dept()
               or (p.role = 'pending' and p.requested_dept = public.my_dept())))))
$$;

create or replace function public.team_emails() returns table(id uuid, email text)
language sql stable security definer set search_path = public, auth as $$
  select u.id, u.email::text from auth.users u
  where public.my_role() in ('admin','gm','manager')
    and (u.id = auth.uid() or public.can_manage_member(u.id))
$$;
revoke execute on function public.team_emails() from public, anon;
grant execute on function public.team_emails() to authenticated;

create or replace function public.admin_reset_password(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not public.can_manage_member(p_id) then raise exception 'not_allowed'; end if;
  update auth.users set encrypted_password = extensions.crypt('workflow2050', extensions.gen_salt('bf')),
                        updated_at = now()
  where id = p_id;
  if not found then raise exception 'not_found'; end if;
  -- sign the person out everywhere so the new password is needed
  delete from auth.refresh_tokens where user_id = p_id::text;
  delete from auth.sessions where user_id = p_id;
  update public.profiles set must_change_password = true where id = p_id;
end $$;
revoke execute on function public.admin_reset_password(uuid) from public, anon;
grant execute on function public.admin_reset_password(uuid) to authenticated;

-- clears the flag only when the password really is no longer the standard one
create or replace function public.password_changed() returns boolean
language plpgsql security definer set search_path = public, auth, extensions as $$
declare ok boolean;
begin
  select extensions.crypt('workflow2050', u.encrypted_password) <> u.encrypted_password into ok from auth.users u where u.id = auth.uid();
  if coalesce(ok, false) then update public.profiles set must_change_password = false where id = auth.uid(); end if;
  return coalesce(ok, false);
end $$;
revoke execute on function public.password_changed() from public, anon;
grant execute on function public.password_changed() to authenticated;
