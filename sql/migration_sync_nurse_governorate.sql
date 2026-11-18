-- ===========================================================================
-- CareNest - مزامنة وتوحيد محافظة ومدينة الممرضين
-- الملف: sql/migration_sync_nurse_governorate.sql
-- ===========================================================================

-- 1. مزامنة المحافظة والمدينة من profiles إلى nurse_profiles للحسابات الحالية التي تفتقدها
UPDATE public.nurse_profiles np
SET
  governorate = p.governorate,
  city = COALESCE(NULLIF(np.city, ''), p.city)
FROM public.profiles p
WHERE np.user_id = p.id
  AND (np.governorate IS NULL OR np.governorate = '')
  AND (p.governorate IS NOT NULL AND p.governorate <> '');

-- 2. مزامنة المحافظة والمدينة من nurse_profiles إلى profiles للحسابات التي تفتقدها
UPDATE public.profiles p
SET
  governorate = np.governorate,
  city = COALESCE(NULLIF(p.city, ''), np.city)
FROM public.nurse_profiles np
WHERE p.id = np.user_id
  AND (p.governorate IS NULL OR p.governorate = '')
  AND (np.governorate IS NOT NULL AND np.governorate <> '');

-- 3. تحديث دالة handle_new_user() لضمان حفظ المحافظة والمدينة في nurse_profiles تلقائياً عند التسجيل
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  user_role text;
  full_name text;
  phone_num text;
  user_gov text;
  user_city text;
  user_addr text;
  v_spec text;
  v_qual text;
  v_exp_yrs integer;
  v_lic text;
BEGIN
  -- تحديد الدور
  user_role := COALESCE(new.raw_user_meta_data->>'role', 'patient');
  IF user_role NOT IN ('patient', 'nurse', 'physiotherapist') THEN
    user_role := 'patient';
  END IF;

  full_name := COALESCE(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  phone_num := new.raw_user_meta_data->>'phone';
  user_gov  := NULLIF(TRIM(new.raw_user_meta_data->>'governorate'), '');
  user_city := NULLIF(TRIM(new.raw_user_meta_data->>'city'), '');
  user_addr := new.raw_user_meta_data->>'address';

  -- إدخال أو تحديث الملف الأساسي في profiles
  INSERT INTO public.profiles (id, email, full_name, phone, role, country, governorate, city, address)
  VALUES (new.id, new.email, full_name, phone_num, user_role, 'Egypt', user_gov, user_city, user_addr)
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
    phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
    country = 'Egypt',
    governorate = COALESCE(EXCLUDED.governorate, public.profiles.governorate),
    city = COALESCE(EXCLUDED.city, public.profiles.city),
    address = COALESCE(EXCLUDED.address, public.profiles.address);

  -- مسار الممرض: حفظ المحافظة والمدينة والبيانات المهنية
  IF user_role = 'nurse' THEN
    v_spec    := COALESCE(new.raw_user_meta_data->>'specialization', 'تمريض عام');
    v_qual    := new.raw_user_meta_data->>'qualifications';
    v_exp_yrs := COALESCE((new.raw_user_meta_data->>'experience_years')::integer, 0);
    v_lic     := new.raw_user_meta_data->>'license_number';

    INSERT INTO public.nurse_profiles (
      user_id,
      verified,
      is_verified,
      is_active,
      accepting_bookings,
      verification_status,
      contract_status,
      experience_years,
      years_experience,
      visit_price,
      hourly_rate,
      country,
      currency,
      governorate,
      city,
      specialization,
      qualifications,
      license_number
    ) VALUES (
      new.id,
      false,
      false,
      false,
      false,
      'pending',
      'not_uploaded',
      v_exp_yrs,
      v_exp_yrs,
      150.00,
      150.00,
      'Egypt',
      'EGP',
      user_gov,
      user_city,
      v_spec,
      v_qual,
      v_lic
    )
    ON CONFLICT (user_id) DO UPDATE
    SET
      governorate = COALESCE(EXCLUDED.governorate, public.nurse_profiles.governorate),
      city = COALESCE(EXCLUDED.city, public.nurse_profiles.city),
      specialization = COALESCE(EXCLUDED.specialization, public.nurse_profiles.specialization),
      qualifications = COALESCE(EXCLUDED.qualifications, public.nurse_profiles.qualifications),
      experience_years = COALESCE(EXCLUDED.experience_years, public.nurse_profiles.experience_years);
  END IF;

  -- مسار أخصائي العلاج الطبيعي
  IF user_role = 'physiotherapist' THEN
    v_spec    := COALESCE(new.raw_user_meta_data->>'specialization', 'العلاج الطبيعي والتأهيل');
    v_qual    := new.raw_user_meta_data->>'qualifications';
    v_exp_yrs := COALESCE((new.raw_user_meta_data->>'experience_years')::integer, 0);
    v_lic     := new.raw_user_meta_data->>'license_number';

    INSERT INTO public.physiotherapist_profiles (
      user_id,
      specialization,
      qualifications,
      experience_years,
      license_number,
      governorate,
      city,
      verified,
      is_active,
      accepting_bookings,
      verification_status,
      contract_status,
      session_price
    ) VALUES (
      new.id,
      v_spec,
      v_qual,
      v_exp_yrs,
      v_lic,
      user_gov,
      user_city,
      false,
      false,
      false,
      'pending',
      'pending',
      0
    )
    ON CONFLICT (user_id) DO UPDATE
    SET
      governorate = COALESCE(EXCLUDED.governorate, public.physiotherapist_profiles.governorate),
      city = COALESCE(EXCLUDED.city, public.physiotherapist_profiles.city);
  END IF;

  RETURN new;
END;
$$;
