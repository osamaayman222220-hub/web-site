-- ============================================================
-- رعايه | CareNest - Supabase Database Schema & RLS Policies
-- ============================================================
-- Run this script in the Supabase Dashboard SQL Editor
-- (https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql)
-- ============================================================

-- 1. EXTENSIONS
create extension if not exists "uuid-ossp";

-- 2. ENUM-LIKE CONSTRAINTS (Using TEXT with CHECK constraints)

-- 3. PROFILES TABLE
-- Linked 1-to-1 with auth.users
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  role text not null check (role in ('patient', 'nurse', 'admin')) default 'patient',
  avatar_url text,
  address text,
  country text default 'Egypt',
  governorate text default 'القاهرة',
  city text default 'القاهرة',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4. NURSE PROFILES TABLE
-- Extended information for nurse accounts
create table if not exists public.nurse_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references public.profiles(id) on delete cascade,
  specialties text[] default '{}',
  license_number text,
  years_experience int default 0,
  hourly_rate numeric(10,2) default 150.00,
  country text default 'Egypt',
  currency text default 'EGP',
  governorates text[] default array['القاهرة', 'الجيزة'],
  bio text,
  service_areas text[] default '{}',
  is_verified boolean default false,
  accepting_bookings boolean default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 5. SERVICES TABLE
-- Catalog of available home nursing services
create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null unique,
  name_en text not null,
  description_ar text,
  description_en text,
  icon text default '🩺',
  base_price numeric(10,2) not null default 100.00,
  duration_minutes int not null default 60,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 6. BOOKINGS TABLE
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  nurse_id uuid not null references public.profiles(id) on delete cascade,
  service_id uuid references public.services(id) on delete set null,
  service_name text not null,
  visit_date date not null,
  visit_time time not null,
  duration_hours numeric(4,2) not null default 1.0,
  total_price numeric(10,2) not null default 0.00,
  currency text not null default 'EGP',
  patient_name text not null,
  patient_phone text not null,
  patient_address text not null,
  country text default 'Egypt',
  governorate text default 'القاهرة',
  city text default 'القاهرة',
  notes text,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'in_progress', 'completed', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 7. REVIEWS TABLE
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid unique references public.bookings(id) on delete cascade,
  patient_id uuid not null references public.profiles(id) on delete cascade,
  nurse_id uuid not null references public.profiles(id) on delete cascade,
  rating int not null check (rating >= 1 and rating <= 5),
  comment text,
  created_at timestamptz not null default now()
);

-- 8. NURSE AVAILABILITY TABLE
create table if not exists public.nurse_availability (
  id uuid primary key default gen_random_uuid(),
  nurse_id uuid not null references public.profiles(id) on delete cascade,
  day_of_week int not null check (day_of_week between 0 and 6), -- 0=Sunday, 6=Saturday
  start_time time not null default '08:00',
  end_time time not null default '20:00',
  is_available boolean not null default true,
  created_at timestamptz not null default now()
);

-- 9. NOTIFICATIONS TABLE
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  message text not null,
  type text not null default 'info',
  link text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- 10. NURSE DOCUMENTS TABLE
create table if not exists public.nurse_documents (
  id uuid primary key default gen_random_uuid(),
  nurse_id uuid not null references public.nurse_profiles(id) on delete cascade,
  document_type text not null,
  storage_path text not null,
  review_status text not null default 'pending' check (review_status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- AUTOMATED TRIGGERS
-- ============================================================

-- Function: Handle new user registration from Supabase Auth
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public, pg_temp
as $$
declare
  user_role text;
  full_name text;
  phone_num text;
  user_gov text;
  user_city text;
begin
  user_role := CASE
  WHEN new.raw_user_meta_data->>'role' = 'nurse' THEN 'nurse'
  ELSE 'patient'
END;
  full_name := coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  phone_num := new.raw_user_meta_data->>'phone';
  user_gov  := coalesce(new.raw_user_meta_data->>'governorate', 'القاهرة');
  user_city := coalesce(new.raw_user_meta_data->>'city', 'القاهرة');

  -- Insert profile
  insert into public.profiles (id, email, full_name, phone, role, country, governorate, city)
  values (new.id, new.email, full_name, phone_num, user_role, 'Egypt', user_gov, user_city)
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    phone = coalesce(excluded.phone, public.profiles.phone),
    country = 'Egypt',
    governorate = coalesce(excluded.governorate, public.profiles.governorate, 'القاهرة'),
    city = coalesce(excluded.city, public.profiles.city, 'القاهرة');

  -- If user is a nurse, create nurse_profile automatically in pending/unverified state
  if user_role = 'nurse' then
    insert into public.nurse_profiles (user_id, is_verified, accepting_bookings, years_experience, hourly_rate, country, currency, governorates)
    values (new.id, false, false, 0, 150.00, 'Egypt', 'EGP', array[user_gov])
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

-- Trigger on auth.users
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Trigger for updated_at timestamps
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger set_profiles_updated_at before update on public.profiles
  for each row execute procedure public.set_updated_at();

create trigger set_nurse_profiles_updated_at before update on public.nurse_profiles
  for each row execute procedure public.set_updated_at();

create trigger set_bookings_updated_at before update on public.bookings
  for each row execute procedure public.set_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================

alter table public.profiles enable row level security;
alter table public.nurse_profiles enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.nurse_availability enable row level security;
alter table public.notifications enable row level security;
alter table public.nurse_documents enable row level security;

-- PROFILES POLICIES
-- Users can view their own profile
create policy "Users can view own profile"
  on public.profiles for select
  using (auth.uid() = id);

-- Users can insert their own profile
create policy "Users can insert own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

-- Users can update their own profile
create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- NURSE PROFILES POLICIES
-- Public can view active verified nurse profiles only
create policy "Nurse profiles are viewable by everyone"
  on public.nurse_profiles for select
  using ((is_verified = true and accepting_bookings = true) or auth.uid() = user_id);

-- Nurses can insert their own nurse profile
create policy "Nurses can insert own nurse profile"
  on public.nurse_profiles for insert
  with check (auth.uid() = user_id);

-- Nurses can update their own nurse profile
create policy "Nurses can update own nurse profile"
  on public.nurse_profiles for update
  using (auth.uid() = user_id);

-- SERVICES POLICIES
-- Anyone can view active services
create policy "Services are viewable by everyone"
  on public.services for select
  using (is_active = true);

-- Authenticated admins and service_role can manage services
create policy "Admins can manage services"
  on public.services for all
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  )
  with check (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  );

-- BOOKINGS POLICIES
-- Patients and Nurses can view their related bookings
create policy "Users can view their related bookings"
  on public.bookings for select
  using (
    auth.uid() = patient_id
    or auth.uid() = nurse_id
    or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- Authenticated patients can insert bookings
create policy "Authenticated patients can insert bookings"
  on public.bookings for insert
  with check (
    auth.uid() = patient_id
    and status = 'pending'
  );

-- Patients can cancel their pending bookings
create policy "Patients can cancel own pending bookings"
  on public.bookings for update
  using (
    auth.uid() = patient_id
    and status in ('pending', 'accepted')
  )
  with check (
    auth.uid() = patient_id
    and status = 'cancelled'
  );

-- Nurses can update operational status for their assigned bookings
create policy "Nurses can update booking operational status"
  on public.bookings for update
  using (
    auth.uid() = nurse_id
    and status in ('pending', 'accepted', 'in_progress')
  )
  with check (
    auth.uid() = nurse_id
    and status in ('accepted', 'rejected', 'in_progress', 'completed')
  );

-- Admins can manage all bookings
create policy "Admins manage all bookings"
  on public.bookings for all
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  )
  with check (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  );

-- REVIEWS POLICIES
-- Anyone can view reviews
create policy "Reviews are viewable by everyone"
  on public.reviews for select
  using (true);

-- Patients can insert reviews for their bookings
create policy "Patients can insert reviews"
  on public.reviews for insert
  with check (auth.uid() = patient_id);

-- AVAILABILITY POLICIES
-- Anyone can view availability
create policy "Availability viewable by everyone"
  on public.nurse_availability for select
  using (true);

-- Nurses can manage their own availability
create policy "Nurses can manage their own availability"
  on public.nurse_availability for all
  using (auth.uid() = nurse_id)
  with check (auth.uid() = nurse_id);

-- NOTIFICATIONS POLICIES
-- Users can view their own notifications
create policy "Users can view own notifications"
  on public.notifications for select
  using (auth.uid() = user_id);

-- Users can update their own notifications
create policy "Users can update own notifications"
  on public.notifications for update
  using (auth.uid() = user_id);

-- NURSE DOCUMENTS POLICIES
create policy "Admins manage all nurse documents"
  on public.nurse_documents for all
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  )
  with check (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    or auth.role() = 'service_role'
  );

create policy "Nurses view own documents"
  on public.nurse_documents for select
  using (
    exists (
      select 1 from public.nurse_profiles np 
      where np.id = public.nurse_documents.nurse_id 
        and np.user_id = auth.uid()
    )
  );

create policy "Nurses insert own documents"
  on public.nurse_documents for insert
  with check (
    exists (
      select 1 from public.nurse_profiles np 
      where np.id = public.nurse_documents.nurse_id 
        and np.user_id = auth.uid()
    )
    and review_status = 'pending'
  );

create policy "Nurses update own documents"
  on public.nurse_documents for update
  using (
    exists (
      select 1 from public.nurse_profiles np 
      where np.id = public.nurse_documents.nurse_id 
        and np.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.nurse_profiles np 
      where np.id = public.nurse_documents.nurse_id 
        and np.user_id = auth.uid()
    )
    and review_status = 'pending'
  );

-- ============================================================
-- SEED DATA: SERVICES CATALOG
-- ============================================================
insert into public.services (name_ar, name_en, description_ar, description_en, icon, base_price, duration_minutes)
values
  ('رعاية كبار السن', 'Elderly Care', 'رعاية شاملة ومرافقة صحية لكبار السن لمساعدتهم على الحياة اليومية بأمان.', 'Comprehensive daily care and health monitoring for elderly individuals.', '🧓', 180.00, 120),
  ('العناية بالجروح وتغيير الضمادات', 'Wound Care & Dressing', 'تنظيف وتضميد الجروح بعد العمليات أو الإصابات بأعلى معايير التعقيم.', 'Post-surgery wound cleaning, dressing changes, and sterile infection prevention.', '🩹', 120.00, 45),
  ('إعطاء الحقن والمحاليل الوريدية', 'Injections & IV Therapy', 'إعطاء الحقن العضلية والوريدية وتركيب المحاليل بإشراف ممرض مرخص.', 'Administering prescribed intramuscular/IV medications and fluid therapy.', '💉', 90.00, 30),
  ('رعاية ما بعد العمليات الجراحية', 'Post-Operative Care', 'متابعة المؤشرات الحيوية وإدارة الألم والرعاية السريرية بعد الخروج من المستشفى.', 'Vital signs monitoring, pain management, and recovery assistance post-hospital discharge.', '🏥', 200.00, 90),
  ('متابعة العلامات الحيوية والسكر', 'Vital Signs & Diabetes Check', 'قياس الضغط والنبض والأكسجين ومستوى السكر وتقديم تقرير مفصل للطبيب.', 'Accurate blood pressure, pulse, oxygen saturation, and glucose monitoring.', '🩺', 75.00, 30),
  ('رعاية الأم وحديثي الولادة', 'Mother & Newborn Care', 'دعم الأمهات الجدد في رعاية الرضيع والرضاعة الطبيعية ومتابعة صحة الأم.', 'Specialized support for new mothers and newborn wellness and routine checks.', '👶', 160.00, 90)
on conflict do nothing;

-- ============================================================
-- STORAGE BUCKETS (Create in Supabase Dashboard > Storage if not existing)
-- Bucket name: 'user-files' (Public)
-- Bucket name: 'private-docs' (Private)
-- ============================================================
