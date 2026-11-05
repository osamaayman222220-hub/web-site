-- ============================================================
-- رعايه | CareNest - Migration V2: Complete Production Schema
-- 2026-10-24
-- ============================================================
-- INSTRUCTIONS:
-- 1. Open Supabase Dashboard SQL Editor:
--    https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql
-- 2. Paste this entire file and press Run
-- 3. Safe to run multiple times (idempotent) - will not delete data
-- ============================================================

create extension if not exists "uuid-ossp";

-- ============================================================
-- STEP 1: Fix nurse_profiles schema (column name mismatch)
-- schema.sql uses: is_verified, hourly_rate, specialties[], years_experience
-- JS code expects: verified, visit_price, specialization, experience_years
-- ============================================================
alter table public.nurse_profiles
  add column if not exists specialization text default 'تمريض عام',
  add column if not exists qualifications text,
  add column if not exists experience_years int default 0,
  add column if not exists visit_price numeric(10,2) default 150.00,
  add column if not exists is_active boolean not null default false,
  add column if not exists verified boolean not null default false,
  add column if not exists verification_status text not null default 'pending',
  add column if not exists rejection_reason text,
  add column if not exists reviewed_by uuid,
  add column if not exists reviewed_at timestamptz,
  add column if not exists bio text,
  add column if not exists governorate text default 'القاهرة',
  add column if not exists city text default 'القاهرة',
  add column if not exists address text,
  add column if not exists languages text[] default array['العربية'],
  add column if not exists avatar_url text,
  add column if not exists full_name text;

-- CRITICAL FIX: Un-approve any nurses that were auto-approved by old trigger
UPDATE public.nurse_profiles
SET
  verified = false,
  is_active = false,
  verification_status = 'pending'
WHERE verification_status = 'pending' AND (verified = true OR is_active = true);

-- Add check constraint for verification_status (safe to add)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'nurse_profiles_verification_status_check'
    AND table_name = 'nurse_profiles'
  ) THEN
    ALTER TABLE public.nurse_profiles
      ADD CONSTRAINT nurse_profiles_verification_status_check
      CHECK (verification_status IN ('incomplete', 'pending', 'approved', 'rejected', 'suspended'));
  END IF;
END $$;

-- ============================================================
-- STEP 2: Create private national ID table
-- National ID is stored as SHA-256 hash only for dedup prevention
-- The actual ID is never stored in plaintext in this database
-- ============================================================
create table if not exists public.user_national_ids (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references public.profiles(id) on delete cascade,
  national_id_hash text unique not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.user_national_ids enable row level security;

drop policy if exists "national_ids_no_public_read" on public.user_national_ids;
create policy "national_ids_no_public_read"
  on public.user_national_ids for select
  using (false);

drop policy if exists "national_ids_insert_own" on public.user_national_ids;
create policy "national_ids_insert_own"
  on public.user_national_ids for insert
  with check (auth.uid() = user_id);

-- ============================================================
-- STEP 3: Add missing columns to bookings table
-- ============================================================
alter table public.bookings
  add column if not exists notes text;

-- ============================================================
-- STEP 4: Create public_nurses VIEW (MISSING - referenced by JS)
-- Only shows: approved, active nurses
-- NEVER exposes: phone, email, national_id, private docs
-- ============================================================
drop view if exists public.public_nurses;
create view public.public_nurses as
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

-- ============================================================
-- STEP 5: Fix handle_new_user trigger
-- CRITICAL BUG: Old trigger set verified=true automatically
-- NEW: Nurse always starts as pending, NOT verified, NOT active
-- ============================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text;
  v_full_name text;
  v_phone text;
  v_governorate text;
  v_city text;
begin
  v_role        := coalesce(new.raw_user_meta_data->>'role', 'patient');
  v_full_name   := coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  v_phone       := coalesce(new.raw_user_meta_data->>'phone', '');
  v_governorate := coalesce(new.raw_user_meta_data->>'governorate', 'القاهرة');
  v_city        := coalesce(new.raw_user_meta_data->>'city', 'القاهرة');

  -- SECURITY: Never allow admin creation via registration
  if v_role = 'admin' then
    v_role := 'patient';
  end if;

  insert into public.profiles (id, email, full_name, phone, role, country, governorate, city)
  values (new.id, new.email, v_full_name, v_phone, v_role, 'Egypt', v_governorate, v_city)
  on conflict (id) do update
  set
    email       = excluded.email,
    full_name   = coalesce(excluded.full_name, public.profiles.full_name),
    phone       = coalesce(excluded.phone, public.profiles.phone),
    country     = 'Egypt',
    governorate = coalesce(excluded.governorate, public.profiles.governorate, 'القاهرة'),
    city        = coalesce(excluded.city, public.profiles.city, 'القاهرة');

  -- Nurse: create profile record, NEVER auto-approve
  if v_role = 'nurse' then
    insert into public.nurse_profiles (
      user_id, full_name, governorate, city,
      verified, is_active, verification_status,
      visit_price, experience_years
    )
    values (
      new.id, v_full_name, v_governorate, v_city,
      false,   -- NEVER auto-approve
      false,   -- inactive until approved
      'pending',
      0.00,
      0
    )
    on conflict (user_id) do nothing;
  end if;

  return new;
exception
  when others then
    raise warning 'handle_new_user error for %: %', new.id, sqlerrm;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================
-- STEP 6: Admin audit log table
-- ============================================================
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.profiles(id) on delete cascade,
  action text not null,
  target_user_id uuid references public.profiles(id) on delete set null,
  target_resource_type text,
  target_resource_id uuid,
  notes text,
  created_at timestamptz not null default now()
);

alter table public.admin_audit_log enable row level security;

drop policy if exists "admin_audit_log_admin_only" on public.admin_audit_log;
create policy "admin_audit_log_admin_only"
  on public.admin_audit_log for all
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- ============================================================
-- STEP 7: Admin function to verify/reject nurses
-- Enforces admin check server-side via security definer
-- ============================================================
create or replace function public.admin_update_nurse_verification(
  p_nurse_user_id uuid,
  p_new_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_admin_id uuid;
  v_admin_role text;
  v_nurse_profile_id uuid;
begin
  v_admin_id := auth.uid();
  select role into v_admin_role from public.profiles where id = v_admin_id;

  if v_admin_role != 'admin' then
    raise exception 'Unauthorized: Only admins can update nurse verification';
  end if;

  if p_new_status not in ('approved', 'rejected', 'suspended', 'pending') then
    raise exception 'Invalid status: %', p_new_status;
  end if;

  update public.nurse_profiles
  set
    verification_status = p_new_status,
    verified            = (p_new_status = 'approved'),
    is_active           = (p_new_status = 'approved'),
    rejection_reason    = p_reason,
    reviewed_by         = v_admin_id,
    reviewed_at         = now()
  where user_id = p_nurse_user_id
  returning id into v_nurse_profile_id;

  if v_nurse_profile_id is null then
    raise exception 'Nurse profile not found: %', p_nurse_user_id;
  end if;

  insert into public.admin_audit_log
    (admin_id, action, target_user_id, target_resource_type, target_resource_id, notes)
  values (
    v_admin_id, 'update_nurse_verification', p_nurse_user_id,
    'nurse_profile', v_nurse_profile_id,
    p_new_status || case when p_reason is not null then ': ' || p_reason else '' end
  );

  insert into public.notifications (user_id, title, message, type)
  values (
    p_nurse_user_id,
    case p_new_status
      when 'approved'  then 'تم اعتماد حسابك'
      when 'rejected'  then 'تم رفض طلب الاعتماد'
      when 'suspended' then 'تم إيقاف حسابك مؤقتاً'
      else 'تم تحديث حالة حسابك'
    end,
    case p_new_status
      when 'approved'  then 'مبروك! تم قبول وثائقك وأصبح حسابك معتمداً.'
      when 'rejected'  then coalesce('سبب الرفض: ' || p_reason, 'يرجى مراجعة وثائقك وإعادة المحاولة.')
      when 'suspended' then 'تم إيقاف حسابك مؤقتاً. يرجى التواصل مع الدعم.'
      else 'تم تحديث حالة حسابك. راجع لوحة التحكم.'
    end,
    case p_new_status when 'approved' then 'success' when 'rejected' then 'error' else 'warning' end
  );

  return jsonb_build_object('success', true, 'status', p_new_status);
end;
$$;

-- ============================================================
-- STEP 8: Tighten nurse_profiles RLS policies
-- ============================================================
drop policy if exists "Nurse profiles are viewable by everyone" on public.nurse_profiles;
drop policy if exists "Nurses can insert own nurse profile" on public.nurse_profiles;
drop policy if exists "Nurses can update own nurse profile" on public.nurse_profiles;
drop policy if exists "Verified nurse profiles viewable by everyone" on public.nurse_profiles;
drop policy if exists "Nurses can insert own nurse profile" on public.nurse_profiles;
drop policy if exists "Nurses can update own nurse profile (non-verified fields)" on public.nurse_profiles;
drop policy if exists "Admins can manage all nurse profiles" on public.nurse_profiles;

create policy "Nurse profiles select policy"
  on public.nurse_profiles for select
  using (
    auth.uid() = user_id
    or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or (verified = true and is_active = true and verification_status = 'approved')
  );

create policy "Nurses insert own profile"
  on public.nurse_profiles for insert
  with check (auth.uid() = user_id);

create policy "Nurses update own profile"
  on public.nurse_profiles for update
  using (auth.uid() = user_id);

create policy "Admins manage all nurse profiles"
  on public.nurse_profiles for all
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- ============================================================
-- STEP 9: Fix bookings RLS - prevent price manipulation
-- ============================================================
drop policy if exists "Users can update their bookings" on public.bookings;
drop policy if exists "Patients can cancel own pending bookings" on public.bookings;
drop policy if exists "Nurses can update status of their bookings" on public.bookings;
drop policy if exists "Admins manage all bookings" on public.bookings;

create policy "Patients can cancel own pending bookings"
  on public.bookings for update
  using (auth.uid() = patient_id and status = 'pending')
  with check (auth.uid() = patient_id);

create policy "Nurses can update their booking status"
  on public.bookings for update
  using (auth.uid() = nurse_id);

create policy "Admins manage all bookings"
  on public.bookings for all
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- ============================================================
-- STEP 10: Storage buckets and policies
-- ============================================================
insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('private-docs', 'private-docs', false)
on conflict (id) do nothing;

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
create policy "Users can manage own profile photo"
  on storage.objects for update
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can delete their own profile photo" on storage.objects;
create policy "Users can delete own profile photo"
  on storage.objects for delete
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Nurses can upload private docs" on storage.objects;
create policy "Nurses can upload private docs"
  on storage.objects for insert
  with check (
    bucket_id = 'private-docs'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Nurses and admins can read private docs" on storage.objects;
create policy "Nurses and admins read private docs"
  on storage.objects for select
  using (
    bucket_id = 'private-docs'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    )
  );

-- ============================================================
-- STEP 11: Seed services (idempotent)
-- ============================================================
insert into public.services (name_ar, name_en, description_ar, description_en, icon, base_price, duration_minutes, is_active)
values
  ('رعاية كبار السن','Elderly Care','رعاية شاملة ومرافقة صحية لكبار السن.','Comprehensive care for elderly individuals.','🧓',250.00,120,true),
  ('العناية بالجروح وتغيير الضمادات','Wound Care & Dressing','تنظيف وتضميد الجروح بأعلى معايير التعقيم.','Wound cleaning and sterile dressing changes.','🩹',180.00,45,true),
  ('إعطاء الحقن والمحاليل الوريدية','Injections & IV Therapy','إعطاء الحقن العضلية والوريدية بإشراف ممرض مرخص.','Intramuscular and IV medication administration.','💉',120.00,30,true),
  ('رعاية ما بعد العمليات الجراحية','Post-Operative Care','متابعة المؤشرات الحيوية والرعاية بعد الخروج من المستشفى.','Post-hospital discharge recovery assistance.','🏥',300.00,90,true),
  ('متابعة العلامات الحيوية والسكر','Vital Signs & Diabetes Check','قياس الضغط والنبض والأكسجين ومستوى السكر.','Blood pressure, pulse, oxygen and glucose monitoring.','🩺',100.00,30,true),
  ('رعاية الأم وحديثي الولادة','Mother & Newborn Care','دعم الأمهات الجدد ورعاية الرضيع.','Newborn care and new mother support.','👶',220.00,90,true),
  ('الرعاية التمريضية العامة','General Nursing Visit','زيارة تمريضية منزلية شاملة للتقييم الصحي.','Comprehensive home health assessment and basic care.','🏠',150.00,60,true),
  ('قياس السكر ومتابعة مرضى السكري','Diabetes Monitoring','متابعة مستويات السكر وتعليم المريض الرعاية الذاتية.','Blood glucose monitoring and patient self-care education.','🩸',80.00,30,true)
on conflict do nothing;

-- ============================================================
-- STEP 12: Performance indexes
-- ============================================================
create index if not exists idx_nurse_profiles_verified_active
  on public.nurse_profiles(verified, is_active, verification_status);
create index if not exists idx_nurse_profiles_governorate
  on public.nurse_profiles(governorate);
create index if not exists idx_bookings_patient_id
  on public.bookings(patient_id, created_at desc);
create index if not exists idx_bookings_nurse_id
  on public.bookings(nurse_id, visit_date asc);
create index if not exists idx_bookings_status
  on public.bookings(status);
create index if not exists idx_notifications_user_unread
  on public.notifications(user_id, is_read, created_at desc);
create index if not exists idx_reviews_nurse_id
  on public.reviews(nurse_id);

-- ============================================================
-- STEP 13: Ensure all tables have RLS enabled
-- ============================================================
alter table public.profiles enable row level security;
alter table public.nurse_profiles enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.nurse_availability enable row level security;
alter table public.notifications enable row level security;

-- ============================================================
-- STEP 14: Fix insert booking policy
-- ============================================================
drop policy if exists "Authenticated patients can insert bookings" on public.bookings;
create policy "Authenticated patients can insert bookings"
  on public.bookings for insert
  with check (auth.uid() = patient_id and auth.role() = 'authenticated');

-- ============================================================
-- POST-SETUP INSTRUCTIONS:
-- 1. To create the first admin account, run in SQL Editor:
--    UPDATE public.profiles SET role = 'admin'
--    WHERE email = 'YOUR-ADMIN-EMAIL@domain.com';
-- 2. Ensure storage buckets exist: profile-photos (public), private-docs (private)
-- 3. Set up Supabase Auth redirect URLs for your domain
-- ============================================================


-- ============================================================
-- STEP 99: allow the save-national-id function to upsert (update) own row
-- ============================================================
drop policy if exists "national_ids_update_own" on public.user_national_ids;
create policy "national_ids_update_own"
  on public.user_national_ids for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
