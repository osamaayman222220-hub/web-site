-- CareNest Migration V4: repair auth/profile consistency and booking fallback issues
-- Run AFTER schema.sql and migration_v2_complete.sql (and existing booking migrations).
-- Idempotent. Does not delete data.
--
-- Important: the old handle_new_user() swallowed all exceptions and returned NEW.
-- That allowed auth.users rows to be created while public.profiles remained empty.
-- This migration repairs existing rows and makes future profile creation fail loudly
-- if the schema is inconsistent, instead of silently creating ghost accounts.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_full_name text;
  v_phone text;
  v_governorate text;
  v_city text;
  v_address text;
begin
  v_role := coalesce(new.raw_user_meta_data->>'role', 'patient');
  -- Public sign-up may create patient or nurse only. Admin must be provisioned privately.
  if v_role not in ('patient', 'nurse') then
    v_role := 'patient';
  end if;

  v_full_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', '')), '');
  if v_full_name is null then
    v_full_name := coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'مستخدم');
  end if;

  v_phone := nullif(trim(coalesce(new.raw_user_meta_data->>'phone', '')), '');
  v_governorate := coalesce(nullif(trim(new.raw_user_meta_data->>'governorate'), ''), 'القاهرة');
  v_city := coalesce(nullif(trim(new.raw_user_meta_data->>'city'), ''), 'القاهرة');
  v_address := nullif(trim(coalesce(new.raw_user_meta_data->>'address', '')), '');

  insert into public.profiles
    (id, email, full_name, phone, role, country, governorate, city, address)
  values
    (new.id, coalesce(new.email, ''), v_full_name, v_phone, v_role, 'Egypt', v_governorate, v_city, v_address)
  on conflict (id) do update set
    email = excluded.email,
    full_name = coalesce(nullif(public.profiles.full_name, ''), excluded.full_name),
    phone = coalesce(public.profiles.phone, excluded.phone),
    country = 'Egypt',
    governorate = coalesce(public.profiles.governorate, excluded.governorate),
    city = coalesce(public.profiles.city, excluded.city),
    address = coalesce(public.profiles.address, excluded.address);

  if v_role = 'nurse' then
    insert into public.nurse_profiles
      (user_id, full_name, governorate, city, verified, is_active, verification_status, visit_price, experience_years)
    values
      (new.id, v_full_name, v_governorate, v_city, false, false, 'pending', 0.00, 0)
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Repair auth users that were created while the old trigger swallowed profile errors.
-- Existing profile roles are preserved, especially manually provisioned administrators.
insert into public.profiles
  (id, email, full_name, phone, role, country, governorate, city)
select
  u.id,
  coalesce(u.email, ''),
  coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'), ''),
           nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
           'مستخدم'),
  nullif(trim(coalesce(u.raw_user_meta_data->>'phone', '')), ''),
  case when u.raw_user_meta_data->>'role' = 'nurse' then 'nurse' else 'patient' end,
  'Egypt',
  coalesce(nullif(trim(u.raw_user_meta_data->>'governorate'), ''), 'القاهرة'),
  coalesce(nullif(trim(u.raw_user_meta_data->>'city'), ''), 'القاهرة')
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- Create missing nurse profile rows for users whose stored role is nurse.
insert into public.nurse_profiles
  (user_id, full_name, governorate, city, verified, is_active, verification_status, visit_price, experience_years)
select
  p.id, p.full_name, coalesce(p.governorate, 'القاهرة'), coalesce(p.city, 'القاهرة'),
  false, false, 'pending', 0.00, 0
from public.profiles p
left join public.nurse_profiles np on np.user_id = p.id
where p.role = 'nurse' and np.user_id is null
on conflict (user_id) do nothing;

-- Report remaining auth users without profiles; ideally this query returns zero.
select
  count(*) as auth_users_without_profiles
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;
