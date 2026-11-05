-- ============================================================
-- منصة رعايه | CareNest - سكريبت التثبيت والإصلاحات لقاعدة البيانات
-- Run this script in Supabase SQL Editor:
-- https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql
-- ============================================================

-- 1. التأكد من وجود أعمدة الموقع في جدول profiles
alter table public.profiles add column if not exists address text;
alter table public.profiles add column if not exists country text default 'Egypt';
alter table public.profiles add column if not exists governorate text default 'القاهرة';
alter table public.profiles add column if not exists city text default 'القاهرة';

-- 2. التأكد من سياسات الأمان (RLS) لجدول profiles
alter table public.profiles enable row level security;

-- السماح للجميع بقراءة بيانات الملفات العامة (الاسم والصورة) لعرض الممرضين وتفاصيل الحجوزات
drop policy if exists "Profiles are viewable by everyone" on public.profiles;
create policy "Profiles are viewable by everyone"
  on public.profiles for select
  using (true);

-- السماح لكل مستخدم بإدراج ملفه الشخصي عند التسجيل
drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

-- السماح لكل مستخدم بتعديل بيانات ملفه الشخصي فقط
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- 3. سياسات الأمان (RLS) لجدول nurse_profiles
alter table public.nurse_profiles enable row level security;

-- السماح للجميع بقراءة ملفات الممرضين المعتمدين والمتاحين
drop policy if exists "Nurse profiles are viewable by everyone" on public.nurse_profiles;
create policy "Nurse profiles are viewable by everyone"
  on public.nurse_profiles for select
  using (true);

-- السماح للممرض بإنشاء سجله المهني
drop policy if exists "Nurses can insert own nurse profile" on public.nurse_profiles;
create policy "Nurses can insert own nurse profile"
  on public.nurse_profiles for insert
  with check (auth.uid() = user_id);

-- السماح للممرض بتحديث سجله المهني وسعر الزيارة والتخصص
drop policy if exists "Nurses can update own nurse profile" on public.nurse_profiles;
create policy "Nurses can update own nurse profile"
  on public.nurse_profiles for update
  using (auth.uid() = user_id);

-- 4. إعداد حاوية تخزين الصور الشخصية (Supabase Storage: profile-photos)
-- إنشاء الـ Bucket إذا لم يكن موجوداً
insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', true)
on conflict (id) do update set public = true;

-- سياسة السماح للجميع بمشاهدة الصور الشخصية (Public Read)
drop policy if exists "Public can view profile photos" on storage.objects;
create policy "Public can view profile photos"
  on storage.objects for select
  using (bucket_id = 'profile-photos');

-- سياسة السماح للمستخدم بتسجيل الدخول برفع صورته فقط
drop policy if exists "Users can upload their own profile photo" on storage.objects;
create policy "Users can upload their own profile photo"
  on storage.objects for insert
  with check (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
  );

-- سياسة السماح للمستخدم بتعديل أو حذف صورته فقط
drop policy if exists "Users can update or delete their own profile photo" on storage.objects;
create policy "Users can update or delete their own profile photo"
  on storage.objects for update
  using (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
  );

-- 5. التريجر التلقائي لإنشاء الملف الشخصي فور التسجيل في Supabase Auth (بأعلى معايير الأمان)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  user_role text;
  full_name text;
  phone_num text;
  user_gov text;
  user_city text;
begin
  user_role := coalesce(new.raw_user_meta_data->>'role', 'patient');
  full_name := coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  phone_num := coalesce(new.raw_user_meta_data->>'phone', '');
  user_gov  := coalesce(new.raw_user_meta_data->>'governorate', 'القاهرة');
  user_city := coalesce(new.raw_user_meta_data->>'city', 'القاهرة');

  -- إنشاء سجل المستخدم في profiles
  insert into public.profiles (id, email, full_name, phone, role, country, governorate, city)
  values (new.id, new.email, full_name, phone_num, user_role, 'Egypt', user_gov, user_city)
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    phone = coalesce(excluded.phone, public.profiles.phone);

  -- إذا كان نوع الحساب ممرض، يتم إنشاء سجله في nurse_profiles تلقائياً ليظهر فوراً في الدليل
  if user_role = 'nurse' then
    insert into public.nurse_profiles (
      user_id,
      specialization,
      qualifications,
      experience_years,
      bio,
      governorate,
      city,
      address,
      visit_price,
      is_active,
      verified
    )
    values (
      new.id,
      'رعاية تمريضية شاملة',
      'بكالوريوس / دبلوم تمريض معتمد',
      3,
      'أخصائي تمريض منزلي معتمد بمصر ومؤهل لتقديم الرعاية الطبية والزيارات المنزلية.',
      user_gov,
      user_city,
      user_gov || ' - ' || user_city,
      200.00,
      true,
      true
    )
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

-- ربط الدالة بجدول المستخدمين auth.users
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
