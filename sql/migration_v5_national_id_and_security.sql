-- ============================================================
-- CareNest - Migration V5: National ID Encrypted Storage & Security Hardening
-- منصة رعايه | CareNest - الترحيل الخامس: تأمين الرقم القومي وإحكام سياسات الأمان
-- ============================================================
-- Run this script in the Supabase SQL Editor:
-- https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql
--
-- Features of this migration:
-- 1. Idempotent & Non-destructive: preserves all existing users, bookings, and hashes.
-- 2. Adds AES-256-GCM encrypted storage columns to user_national_ids.
-- 3. Eliminates public profile leaks by replacing open SELECT policies.
-- 4. Prevents role escalation (users cannot self-promote to admin).
-- 5. Prevents nurse self-approval (nurses cannot set verified = true).
-- 6. Restricts service catalog management to authenticated admins.
-- 7. Hardens storage object policies to prevent cross-user file manipulation.
-- ============================================================

-- ------------------------------------------------------------
-- STEP 1: Admin Authorization Helper Function
-- ------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ------------------------------------------------------------
-- STEP 2: Extend National ID Table for Reversible Encrypted Storage
-- ------------------------------------------------------------
create table if not exists public.user_national_ids (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references public.profiles(id) on delete cascade,
  national_id_hash text unique not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.user_national_ids
  add column if not exists encrypted_national_id text,
  add column if not exists encryption_iv text;

-- Keep RLS enabled. Direct public access is completely blocked.
-- Access is strictly managed server-side by authenticated Edge Functions.
alter table public.user_national_ids enable row level security;

drop policy if exists "national_ids_no_public_read" on public.user_national_ids;
create policy "national_ids_no_public_read"
  on public.user_national_ids for select
  using (false);

drop policy if exists "national_ids_insert_own" on public.user_national_ids;
create policy "national_ids_insert_own"
  on public.user_national_ids for insert
  with check (auth.uid() = user_id);

drop policy if exists "national_ids_update_own" on public.user_national_ids;
create policy "national_ids_update_own"
  on public.user_national_ids for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ------------------------------------------------------------
-- STEP 3: Secure Profiles Table (Remove Broad Public Read Leak)
-- ------------------------------------------------------------
alter table public.profiles enable row level security;

-- Drop legacy open policies that allow unrestricted reading of all profiles
drop policy if exists "Profiles are viewable by everyone" on public.profiles;
drop policy if exists "Public profiles are viewable by everyone." on public.profiles;
drop policy if exists "Users can view own profile" on public.profiles;
drop policy if exists "Profiles select policy" on public.profiles;

-- Strict least-privilege SELECT policy:
-- 1. User reading their own profile
-- 2. Admin reading any profile
-- 3. Active booking parties (patient <-> nurse) viewing each other's relevant details
-- 4. Verified, active nurses visible for directory listing
create policy "Profiles select policy"
  on public.profiles for select
  using (
    auth.uid() = id
    or public.is_admin()
    or exists (
      select 1 from public.nurse_profiles np
      where np.user_id = public.profiles.id
        and np.verified = true
        and np.is_active = true
    )
    or exists (
      select 1 from public.bookings b
      where (b.patient_id = auth.uid() and b.nurse_id = public.profiles.id)
         or (b.nurse_id = auth.uid() and b.patient_id = public.profiles.id)
    )
  );

-- Users can insert their own profile upon signup
drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

-- Users can update their own profile
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

-- Trigger: Prevent privilege escalation on profiles
-- Normal users cannot self-promote to 'admin' or alter account role
create or replace function public.prevent_profile_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role then
    if not public.is_admin() then
      new.role := old.role;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_role_escalation on public.profiles;
create trigger trg_prevent_role_escalation
before update on public.profiles
for each row execute function public.prevent_profile_role_escalation();

-- ------------------------------------------------------------
-- STEP 4: Nurse Profiles Verification Hardening
-- ------------------------------------------------------------
alter table public.nurse_profiles enable row level security;

-- Trigger: Prevent nurse self-approval
-- A nurse cannot set verified = true or verification_status = 'approved'
create or replace function public.prevent_nurse_self_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.verified is distinct from old.verified) or
     (new.verification_status is distinct from old.verification_status) then
    if not public.is_admin() then
      new.verified := old.verified;
      new.verification_status := old.verification_status;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_nurse_self_approval on public.nurse_profiles;
create trigger trg_prevent_nurse_self_approval
before update on public.nurse_profiles
for each row execute function public.prevent_nurse_self_approval();

-- Policies on nurse_profiles
drop policy if exists "Nurse profiles are viewable by everyone" on public.nurse_profiles;
drop policy if exists "Nurse profiles select policy" on public.nurse_profiles;
create policy "Nurse profiles select policy"
  on public.nurse_profiles for select
  using (
    (verified = true and is_active = true)
    or auth.uid() = user_id
    or public.is_admin()
  );

drop policy if exists "Nurses can insert own nurse profile" on public.nurse_profiles;
drop policy if exists "Nurses insert own profile" on public.nurse_profiles;
create policy "Nurses insert own profile"
  on public.nurse_profiles for insert
  with check (auth.uid() = user_id or public.is_admin());

drop policy if exists "Nurses can update own nurse profile" on public.nurse_profiles;
drop policy if exists "Nurses update own profile" on public.nurse_profiles;
create policy "Nurses update own profile"
  on public.nurse_profiles for update
  using (auth.uid() = user_id or public.is_admin())
  with check (auth.uid() = user_id or public.is_admin());

-- ------------------------------------------------------------
-- STEP 5: Services Catalog Security
-- ------------------------------------------------------------
alter table public.services enable row level security;

drop policy if exists "Services are viewable by everyone" on public.services;
create policy "Services are viewable by everyone"
  on public.services for select
  using (true);

drop policy if exists "Admins can manage services" on public.services;
create policy "Admins can manage services"
  on public.services for all
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- STEP 6: Bookings Table Least-Privilege Policies
-- ------------------------------------------------------------
alter table public.bookings enable row level security;

drop policy if exists "Users can view their related bookings" on public.bookings;
drop policy if exists "Users can view their own bookings" on public.bookings;
create policy "Users can view their own bookings"
  on public.bookings for select
  using (
    auth.uid() = patient_id
    or auth.uid() = nurse_id
    or public.is_admin()
  );

drop policy if exists "Authenticated patients can insert bookings" on public.bookings;
create policy "Authenticated patients can insert bookings"
  on public.bookings for insert
  with check (
    auth.uid() = patient_id
    and auth.role() = 'authenticated'
  );

drop policy if exists "Users can update their bookings" on public.bookings;
drop policy if exists "Patients can cancel own pending bookings" on public.bookings;
drop policy if exists "Nurses can update their booking status" on public.bookings;
drop policy if exists "Nurses can update assigned bookings" on public.bookings;
drop policy if exists "Admins manage all bookings" on public.bookings;

-- Patients can cancel their own pending bookings
create policy "Patients can cancel own pending bookings"
  on public.bookings for update
  using (auth.uid() = patient_id and status = 'pending')
  with check (auth.uid() = patient_id and status = 'cancelled');

-- Nurses can update the status of bookings assigned to them
create policy "Nurses can update assigned bookings"
  on public.bookings for update
  using (auth.uid() = nurse_id or public.is_admin())
  with check (auth.uid() = nurse_id or public.is_admin());

-- ------------------------------------------------------------
-- STEP 7: Storage Objects Hardening
-- ------------------------------------------------------------
-- Ensure buckets exist
insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('private-docs', 'private-docs', false)
on conflict (id) do update set public = false;

-- Profile photos policies (public view, user-folder upload/delete)
drop policy if exists "Public can view profile photos" on storage.objects;
create policy "Public can view profile photos"
  on storage.objects for select
  using (bucket_id = 'profile-photos');

drop policy if exists "Users can upload their own profile photo" on storage.objects;
create policy "Users can upload their own profile photo"
  on storage.objects for insert
  with check (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can update or delete their own profile photo" on storage.objects;
drop policy if exists "Users can manage own profile photo" on storage.objects;
create policy "Users can manage own profile photo"
  on storage.objects for update
  using (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can delete own profile photo" on storage.objects;
create policy "Users can delete own profile photo"
  on storage.objects for delete
  using (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Private docs policies (private view and upload restricted to owner and admin)
drop policy if exists "Nurses can upload private docs" on storage.objects;
create policy "Nurses can upload private docs"
  on storage.objects for insert
  with check (
    bucket_id = 'private-docs'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Nurses and admins read private docs" on storage.objects;
create policy "Nurses and admins read private docs"
  on storage.objects for select
  using (
    bucket_id = 'private-docs'
    and auth.role() = 'authenticated'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

drop policy if exists "Nurses and admins delete private docs" on storage.objects;
create policy "Nurses and admins delete private docs"
  on storage.objects for delete
  using (
    bucket_id = 'private-docs'
    and auth.role() = 'authenticated'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

-- ------------------------------------------------------------
-- STEP 8: Refresh public_nurses View
-- ------------------------------------------------------------
-- The view exposes only active, approved, verified nurse details.
drop view if exists public.public_nurses;
create view public.public_nurses with (security_invoker = false) as
  select
    np.id,
    np.user_id,
    p.full_name,
    p.avatar_url,
    np.specialization,
    np.qualifications,
    np.experience_years,
    np.visit_price,
    np.bio,
    np.governorate,
    np.city,
    np.languages,
    np.verified,
    np.is_active,
    np.verification_status,
    np.created_at,
    coalesce(avg_r.avg_rating, 0.0) as avg_rating,
    coalesce(avg_r.review_count, 0) as review_count
  from public.nurse_profiles np
  join public.profiles p on p.id = np.user_id
  left join (
    select
      nurse_id,
      round(avg(rating)::numeric, 1) as avg_rating,
      count(*) as review_count
    from public.reviews
    group by nurse_id
  ) avg_r on avg_r.nurse_id = np.user_id
  where
    np.verified = true
    and np.is_active = true
    and np.verification_status = 'approved';
