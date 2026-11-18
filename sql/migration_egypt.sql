-- ============================================================
-- رعايه | CareNest - Egypt Migration Script
-- ترحيل قاعدة بيانات Supabase للعمل في جمهورية مصر العربية
-- ============================================================
-- تعليمات التشغيل:
-- 1. افتح Supabase Dashboard الخاصة بمشروعك:
--    https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql
-- 2. الصق هذا الكود واضغط Run
-- 3. هذا الاسكريبت آمن تماماً (Idempotent): لا يحذف أي جداول أو بيانات سابقة
-- ============================================================

-- 1. تحديث جدول الملفات الشخصية (profiles)
alter table public.profiles
  add column if not exists country text default 'Egypt',
  add column if not exists governorate text default 'القاهرة';

-- تحديث السجلات الحالية لتكون مصر والقاهرة بدلاً من الرياض
update public.profiles
set country = 'Egypt'
where country is null or country = 'Saudi Arabia' or country = 'KSA';

update public.profiles
set governorate = 'القاهرة'
where governorate is null;

update public.profiles
set city = 'القاهرة'
where city is null or city = 'Riyadh' or city = 'الرياض' or city = 'جدة' or city = 'الدمام';

alter table public.profiles
  alter column city set default 'القاهرة';

-- 2. تحديث جدول بيانات الممرضين (nurse_profiles)
alter table public.nurse_profiles
  add column if not exists country text default 'Egypt',
  add column if not exists governorates text[] default array['القاهرة', 'الجيزة'],
  add column if not exists currency text default 'EGP';

-- تحديث أسعار الممرضين الافتراضية
alter table public.nurse_profiles
  alter column hourly_rate set default 150.00;

update public.nurse_profiles
set country = 'Egypt', currency = 'EGP'
where country is null or currency is null;

-- 3. تحديث جدول الحجوزات (bookings)
alter table public.bookings
  add column if not exists country text default 'Egypt',
  add column if not exists governorate text default 'القاهرة',
  add column if not exists city text default 'القاهرة',
  add column if not exists currency text default 'EGP';

update public.bookings
set country = 'Egypt', currency = 'EGP'
where country is null or currency is null;

-- 4. تحديث دالة تسجيل المستخدم الجديد التلقائية لتشمل مصر
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
  phone_num := new.raw_user_meta_data->>'phone';
  user_gov  := coalesce(new.raw_user_meta_data->>'governorate', 'القاهرة');
  user_city := coalesce(new.raw_user_meta_data->>'city', 'القاهرة');

  -- Insert profile with Egypt defaults
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

  -- If user is a nurse, create nurse_profile automatically with Egypt defaults
  if user_role = 'nurse' then
    insert into public.nurse_profiles (
      user_id,
      is_verified,
      accepting_bookings,
      years_experience,
      hourly_rate,
      country,
      currency,
      governorates
    )
    values (
      new.id,
      true,
      true,
      2,
      150.00,
      'Egypt',
      'EGP',
      array[user_gov]
    )
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

-- 5. تحديث أسعار الخدمات في جدول services بالجنيه المصري EGP
insert into public.services (name_ar, name_en, description_ar, description_en, icon, base_price, duration_minutes)
values
  ('رعاية كبار السن', 'Elderly Care', 'رعاية شاملة ومرافقة صحية لكبار السن لمساعدتهم على الحياة اليومية بأمان.', 'Comprehensive daily care and health monitoring for elderly individuals.', '🧓', 250.00, 120),
  ('العناية بالجروح وتغيير الضمادات', 'Wound Care & Dressing', 'تنظيف وتضميد الجروح بعد العمليات أو الإصابات بأعلى معايير التعقيم.', 'Post-surgery wound cleaning, dressing changes, and sterile infection prevention.', '🩹', 180.00, 45),
  ('إعطاء الحقن والمحاليل الوريدية', 'Injections & IV Therapy', 'إعطاء الحقن العضلية والوريدية وتركيب المحاليل بإشراف ممرض مرخص.', 'Administering prescribed intramuscular/IV medications and fluid therapy.', '💉', 120.00, 30),
  ('رعاية ما بعد العمليات الجراحية', 'Post-Operative Care', 'متابعة المؤشرات الحيوية وإدارة الألم والرعاية السريرية بعد الخروج من المستشفى.', 'Vital signs monitoring, pain management, and recovery assistance post-hospital discharge.', '🏥', 300.00, 90),
  ('متابعة العلامات الحيوية والسكر', 'Vital Signs & Diabetes Check', 'قياس الضغط والنبض والأكسجين ومستوى السكر وتقديم تقرير مفصل للطبيب.', 'Accurate blood pressure, pulse, oxygen saturation, and glucose monitoring.', '🩺', 100.00, 30),
  ('رعاية الأم وحديثي الولادة', 'Mother & Newborn Care', 'دعم الأمهات الجدد في رعاية الرضيع والرضاعة الطبيعية ومتابعة صحة الأم.', 'Specialized support for new mothers and newborn wellness and routine checks.', '👶', 220.00, 90)
on conflict do nothing;
