-- ============================================================
-- CareNest - Final Production Migration
-- Migration File: sql/migration_production_final_v1.sql
-- Description: Financial Engine, Nurse Wallets, Contracts Management,
--              Platform Documents, Booking Chat, Audit Logging & Hardened RLS.
-- Zero-Trust Security & Banking-Grade Integrity Model
-- ============================================================

-- ============================================================
-- 0. التهيئة الأمنية الأساسية وصلاحيات الإدارة (Zero-Trust Security Core)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- 0.0 مزامنة البنية الأساسية وتوحيد العلاقات (Baseline Synchronization)
-- يضمن التوافق التام 100% سواء تم التشغيل على قاعدة نظيفة أو بعد schema.sql
-- ============================================================

-- 1. مزامنة أعمدة جدول حسابات المستخدمين (public.profiles)
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS governorate text DEFAULT 'القاهرة';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS city text DEFAULT 'القاهرة';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS address text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_verified boolean DEFAULT false;

-- 2. مزامنة أعمدة جدول ملفات الممرضين المهنية (public.nurse_profiles)
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS specialization text DEFAULT 'تمريض عام';
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS qualifications text;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS experience_years integer DEFAULT 0;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS visit_price numeric(10,2) DEFAULT 150.00;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS hourly_rate numeric(10,2) DEFAULT 150.00;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS verified boolean DEFAULT false;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT false;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS verification_status text DEFAULT 'pending';
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS rejection_reason text;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES public.profiles(id);
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS contract_status text DEFAULT 'not_uploaded';
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS governorate text DEFAULT 'القاهرة';
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS city text DEFAULT 'القاهرة';
ALTER TABLE public.nurse_profiles ADD COLUMN IF NOT EXISTS languages text[] DEFAULT ARRAY['العربية'];

-- دالة وتريجر المزامنة الثنائية للترادف الحقيقي فقط (verified و experience_years)
-- مع الفصل التام بين visit_price و hourly_rate وبين is_active و accepting_bookings لمنع فقد البيانات
CREATE OR REPLACE FUNCTION public.trg_sync_nurse_profile_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- مزامنة التوثيق عند الإدراج الأولي فقط إذا أُرسل أحدهما فارغاً
    IF NEW.verified IS NOT NULL AND NEW.is_verified IS NULL THEN
      NEW.is_verified := NEW.verified;
    ELSIF NEW.is_verified IS NOT NULL AND NEW.verified IS NULL THEN
      NEW.verified := NEW.is_verified;
    END IF;

    -- مزامنة سنوات الخبرة عند الإدراج الأولي فقط إذا أُرسل أحدهما فارغاً
    IF NEW.experience_years IS NOT NULL AND NEW.years_experience IS NULL THEN
      NEW.years_experience := NEW.experience_years;
    ELSIF NEW.years_experience IS NOT NULL AND NEW.experience_years IS NULL THEN
      NEW.experience_years := NEW.years_experience;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- مزامنة التوثيق فقط عند تغيير أحدهما صراحة دون تغيير الآخر
    IF NEW.verified IS DISTINCT FROM OLD.verified AND NEW.is_verified IS NOT DISTINCT FROM OLD.is_verified THEN
      NEW.is_verified := NEW.verified;
    ELSIF NEW.is_verified IS DISTINCT FROM OLD.is_verified AND NEW.verified IS NOT DISTINCT FROM OLD.verified THEN
      NEW.verified := NEW.is_verified;
    END IF;

    -- مزامنة سنوات الخبرة فقط عند تغيير أحدهما صراحة دون تغيير الآخر
    IF NEW.experience_years IS DISTINCT FROM OLD.experience_years AND NEW.years_experience IS NOT DISTINCT FROM OLD.years_experience THEN
      NEW.years_experience := NEW.experience_years;
    ELSIF NEW.years_experience IS DISTINCT FROM OLD.years_experience AND NEW.experience_years IS NOT DISTINCT FROM OLD.experience_years THEN
      NEW.experience_years := NEW.years_experience;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_nurse_profile_columns_trg ON public.nurse_profiles;
CREATE TRIGGER sync_nurse_profile_columns_trg
BEFORE INSERT OR UPDATE ON public.nurse_profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_nurse_profile_columns();

-- 3. مزامنة أعمدة وعلاقات جدول الحجوزات (public.bookings)
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS service_id uuid REFERENCES public.services(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS service_name text DEFAULT 'تمريض عام';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS service_type text DEFAULT 'تمريض عام';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS visit_time time DEFAULT '10:00:00';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS start_time time DEFAULT '10:00:00';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS duration_hours numeric(4,2) DEFAULT 1.0;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS total_price numeric(10,2) DEFAULT 0.00;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS price numeric(10,2) DEFAULT 0.00;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS currency text DEFAULT 'EGP';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS patient_name text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS patient_phone text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS patient_address text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS country text DEFAULT 'Egypt';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS governorate text DEFAULT 'القاهرة';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS city text DEFAULT 'القاهرة';
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS patient_notes text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS nurse_profile_id uuid REFERENCES public.nurse_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS deposit_amount numeric(10,2) DEFAULT 0.00;

-- ضبط القيد المرجعي لـ nurse_id و patient_id ليطابق profiles(id) ومتطلبات PostgREST
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'bookings_nurse_id_fkey' 
      AND table_schema = 'public' 
      AND table_name = 'bookings'
  ) THEN
    ALTER TABLE public.bookings ADD CONSTRAINT bookings_nurse_id_fkey 
      FOREIGN KEY (nurse_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'bookings_patient_id_fkey' 
      AND table_schema = 'public' 
      AND table_name = 'bookings'
  ) THEN
    ALTER TABLE public.bookings ADD CONSTRAINT bookings_patient_id_fkey 
      FOREIGN KEY (patient_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
END;
$$;

-- ضمان وجود قيد الفرادة على اسم الخدمة لتمكين عمليات الـ upsert
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'services_name_ar_key' AND table_name = 'services' AND table_schema = 'public'
  ) THEN
    ALTER TABLE public.services ADD CONSTRAINT services_name_ar_key UNIQUE (name_ar);
  END IF;
END $$;

-- دالة وتريجر معالجة ومزامنة بيانات الحجز وتوحيد هوية الممرض وبيانات المريض الحقيقية
CREATE OR REPLACE FUNCTION public.trg_sync_booking_nurse_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_nurse_profile_id uuid;
  v_nurse_user_id uuid;
  v_service_record record;
  v_patient_name text;
  v_patient_phone text;
  v_patient_address text;
BEGIN
  -- أ) التحقق والربط المشترك لهوية الممرض
  IF NEW.nurse_id IS NOT NULL OR NEW.nurse_profile_id IS NOT NULL THEN
    -- البحث عن الملف المهني المطابق في nurse_profiles
    SELECT np.id, np.user_id INTO v_nurse_profile_id, v_nurse_user_id
    FROM public.nurse_profiles np
    WHERE np.id = COALESCE(NEW.nurse_profile_id, NEW.nurse_id)
       OR np.user_id = COALESCE(NEW.nurse_id, NEW.nurse_profile_id)
    LIMIT 1;

    IF FOUND THEN
      -- التحقق من عدم التناقض في حال إرسال الاثنين معاً
      IF NEW.nurse_id IS NOT NULL AND NEW.nurse_profile_id IS NOT NULL THEN
        IF NOT (
          (NEW.nurse_id = v_nurse_user_id AND NEW.nurse_profile_id = v_nurse_profile_id) OR
          (NEW.nurse_id = v_nurse_profile_id AND NEW.nurse_profile_id = v_nurse_profile_id)
        ) THEN
          RAISE EXCEPTION 'تعارض في بيانات الممرض: الملف المهني المحدد لا يتطابق مع حساب الممرض';
        END IF;
      END IF;

      NEW.nurse_id := v_nurse_user_id;            -- يضمن الإشارة دائماً إلى profiles(id)
      NEW.nurse_profile_id := v_nurse_profile_id; -- يضمن الإشارة دائماً إلى nurse_profiles(id)
    ELSE
      -- فحص وجود المستخدم في profiles بدور ممرض
      IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = COALESCE(NEW.nurse_id, NEW.nurse_profile_id) AND role = 'nurse') THEN
        RAISE EXCEPTION 'الممرض المحدد غير مسجل أو غير متاح في النظام';
      END IF;
      NEW.nurse_id := COALESCE(NEW.nurse_id, NEW.nurse_profile_id);
    END IF;
  END IF;

  -- ب) منع تعديل هوية الممرض أو الملف المهني بعد الإنشاء
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.nurse_id IS NOT NULL AND NEW.nurse_id IS DISTINCT FROM OLD.nurse_id) OR
       (OLD.nurse_profile_id IS NOT NULL AND NEW.nurse_profile_id IS DISTINCT FROM OLD.nurse_profile_id) THEN
      IF NOT (
        public.is_admin() 
        OR (auth.role() = 'service_role')
        OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)
      ) THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل الممرض المسند إليه الحجز بعد الإنشاء إلا بواسطة إدارة النظام';
      END IF;
    END IF;
  END IF;

  -- ج) مزامنة اسم ومعرف الخدمة
  IF NEW.service_id IS NOT NULL THEN
    SELECT * INTO v_service_record FROM public.services WHERE id = NEW.service_id;
    IF FOUND THEN
      NEW.service_name := COALESCE(NEW.service_name, v_service_record.name_ar);
      NEW.service_type := COALESCE(NEW.service_type, v_service_record.name_ar);
    END IF;
  ELSIF NEW.service_name IS NOT NULL OR NEW.service_type IS NOT NULL THEN
    SELECT * INTO v_service_record FROM public.services 
    WHERE name_ar = COALESCE(NEW.service_name, NEW.service_type) 
       OR name_en = COALESCE(NEW.service_name, NEW.service_type)
    LIMIT 1;
    IF FOUND THEN
      NEW.service_id   := v_service_record.id;
      NEW.service_name := v_service_record.name_ar;
      NEW.service_type := v_service_record.name_ar;
    END IF;
  END IF;

  -- د) جلب بيانات المريض من حسابه في profiles إن كانت الحقول فارغة
  IF NEW.patient_id IS NOT NULL AND (
    NEW.patient_name IS NULL OR TRIM(NEW.patient_name) = '' OR
    NEW.patient_phone IS NULL OR TRIM(NEW.patient_phone) = '' OR
    NEW.patient_address IS NULL OR TRIM(NEW.patient_address) = ''
  ) THEN
    SELECT p.full_name, p.phone, COALESCE(p.address, p.city)
    INTO v_patient_name, v_patient_phone, v_patient_address
    FROM public.profiles p
    WHERE p.id = NEW.patient_id;

    IF NEW.patient_name IS NULL OR TRIM(NEW.patient_name) = '' THEN
      NEW.patient_name := v_patient_name;
    END IF;
    IF NEW.patient_phone IS NULL OR TRIM(NEW.patient_phone) = '' THEN
      NEW.patient_phone := v_patient_phone;
    END IF;
    IF NEW.patient_address IS NULL OR TRIM(NEW.patient_address) = '' THEN
      NEW.patient_address := v_patient_address;
    END IF;
  END IF;

  -- هـ) التحقق الصارم من وجود بيانات المريض الحقيقية ومنع البيانات الوهمية تماماً
  IF TG_OP = 'INSERT' THEN
    IF NEW.patient_name IS NULL OR TRIM(NEW.patient_name) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: اسم المريض مطلوب لإتمام الحجز';
    END IF;
    IF NEW.patient_phone IS NULL OR TRIM(NEW.patient_phone) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: رقم هاتف التواصل مع المريض مطلوب لإتمام الحجز';
    END IF;
    IF NEW.patient_address IS NULL OR TRIM(NEW.patient_address) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: عنوان زيارة التمريض مطلوب لإتمام الحجز';
    END IF;
  END IF;

  -- و) مزامنة المسميات والأسعار والتوقيتات
  NEW.service_name  := COALESCE(NEW.service_name, NEW.service_type, 'تمريض عام');
  NEW.service_type  := COALESCE(NEW.service_type, NEW.service_name, 'تمريض عام');
  NEW.visit_time    := COALESCE(NEW.visit_time, NEW.start_time, '10:00:00'::time);
  NEW.start_time    := COALESCE(NEW.start_time, NEW.visit_time, '10:00:00'::time);
  NEW.total_price   := COALESCE(NEW.total_price, NEW.price, 0.00);
  NEW.price         := COALESCE(NEW.price, NEW.total_price, 0.00);
  NEW.notes         := COALESCE(NEW.notes, NEW.patient_notes);
  NEW.patient_notes := COALESCE(NEW.patient_notes, NEW.notes);
  NEW.currency      := COALESCE(NEW.currency, 'EGP');
  NEW.country       := COALESCE(NEW.country, 'Egypt');
  NEW.status        := COALESCE(NEW.status, 'pending');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_and_sync_booking ON public.bookings;
DROP TRIGGER IF EXISTS sync_booking_nurse_identity_trg ON public.bookings;
CREATE TRIGGER sync_booking_nurse_identity_trg
BEFORE INSERT OR UPDATE ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_booking_nurse_identity();

-- 4. جدول الأرقام القومية المشفرة (public.user_national_ids)
CREATE TABLE IF NOT EXISTS public.user_national_ids (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  national_id_hash text UNIQUE NOT NULL,
  encrypted_national_id text,
  encryption_iv text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_national_ids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "national_ids_no_public_read" ON public.user_national_ids;
CREATE POLICY "national_ids_no_public_read"
  ON public.user_national_ids FOR SELECT
  USING (false);

DROP POLICY IF EXISTS "national_ids_service_only" ON public.user_national_ids;
CREATE POLICY "national_ids_service_only"
  ON public.user_national_ids FOR ALL
  USING (
    (auth.role() = 'service_role')
    OR (current_user IN ('postgres', 'service_role', 'supabase_admin') AND auth.uid() IS NULL)
  )
  WITH CHECK (
    (auth.role() = 'service_role')
    OR (current_user IN ('postgres', 'service_role', 'supabase_admin') AND auth.uid() IS NULL)
  );

-- دالة التحقق من صلاحيات المدير الآمنة (لا تعتمد على user_metadata نهائياً)
-- محصنة ضد هجمات Search Path والتصعيد الذاتي والدوران اللانهائي في RLS
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, anon;

-- تريجر منع ترقية المستخدم لدور مدير ذاتياً (Prevent Role Escalation)
CREATE OR REPLACE FUNCTION public.trg_enforce_profile_role_security()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_authorized boolean;
  v_caller_role text;
BEGIN
  -- تحديد صلاحية المستدعي الحقيقي دون الاعتماد على current_user
  BEGIN
    v_caller_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_caller_role := NULL;
  END;

  v_is_authorized := (
    public.is_admin()
    OR v_caller_role = 'service_role'
    OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)
  );

  IF TG_OP = 'INSERT' THEN
    -- حظر أي دور غير مصرح به للمستخدم العادي عند التسجيل
    IF NOT v_is_authorized THEN
      IF NEW.role IS NULL OR NEW.role NOT IN ('patient', 'nurse') THEN
        NEW.role := 'patient';
      END IF;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- 1. حظر تعديل معرف المستخدم id نهائياً (Immutable Account Identity)
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل المعرف الأساسي للحساب (id)';
    END IF;

    -- 2. حظر تعديل الدور role إلا بواسطة جهة مصرحة
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF NOT v_is_authorized THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل صلاحيات المستخدم أو الترقية لدور مدير إلا بواسطة إدارة النظام';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_profile_role_security_trg ON public.profiles;
CREATE TRIGGER enforce_profile_role_security_trg
BEFORE INSERT OR UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_profile_role_security();

-- تحديث دالة تسجيل المستخدم الجديد لمنع التوثيق التلقائي وضبط الإعدادات الأمنية
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
BEGIN
  -- حظر أي دور admin أو قيمة غير معروفة من الميتاداتا
  user_role := COALESCE(new.raw_user_meta_data->>'role', 'patient');
  IF user_role NOT IN ('patient', 'nurse') THEN
    user_role := 'patient';
  END IF;

  full_name := COALESCE(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  phone_num := new.raw_user_meta_data->>'phone';
  user_gov  := COALESCE(new.raw_user_meta_data->>'governorate', 'القاهرة');
  user_city := COALESCE(new.raw_user_meta_data->>'city', 'القاهرة');
  user_addr := new.raw_user_meta_data->>'address';

  -- إنشاء الحساب في profiles
  INSERT INTO public.profiles (id, email, full_name, phone, role, country, governorate, city, address)
  VALUES (new.id, new.email, full_name, phone_num, user_role, 'Egypt', user_gov, user_city, user_addr)
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
    phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
    country = 'Egypt',
    governorate = COALESCE(EXCLUDED.governorate, public.profiles.governorate, 'القاهرة'),
    city = COALESCE(EXCLUDED.city, public.profiles.city, 'القاهرة'),
    address = COALESCE(EXCLUDED.address, public.profiles.address);

  -- إذا كان المستخدم ممرضاً، ينشأ له ملف مهني بحالة غير معتمد وبانتظار مراجعة الإدارة
  IF user_role = 'nurse' THEN
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
      city
    ) VALUES (
      new.id,
      false,
      false,
      false,
      false,
      'pending',
      'not_uploaded',
      0,
      0,
      150.00,
      150.00,
      'Egypt',
      'EGP',
      user_gov,
      user_city
    )
    ON CONFLICT (user_id) DO NOTHING;
  END IF;

  RETURN new;
END;
$$;

-- تريجر حماية حسابات الممرضين ومنع الاعتماد والتفعيل الذاتي (Prevent Nurse Self-Approval)
CREATE OR REPLACE FUNCTION public.trg_prevent_nurse_self_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_authorized boolean;
  v_caller_role text;
BEGIN
  BEGIN
    v_caller_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_caller_role := NULL;
  END;

  v_is_authorized := (
    public.is_admin()
    OR v_caller_role = 'service_role'
    OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)
  );

  IF TG_OP = 'INSERT' THEN
    IF NOT v_is_authorized THEN
      NEW.verified := false;
      NEW.is_verified := false;
      NEW.is_active := false;
      NEW.verification_status := 'pending';
      NEW.contract_status := 'not_uploaded';
      NEW.reviewed_by := NULL;
      NEW.reviewed_at := NULL;
      NEW.contract_reviewed_by := NULL;
      NEW.contract_reviewed_at := NULL;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF (NEW.verified IS DISTINCT FROM OLD.verified) OR
       (NEW.is_verified IS DISTINCT FROM OLD.is_verified) OR
       (NEW.is_active IS DISTINCT FROM OLD.is_active) OR
       (NEW.verification_status IS DISTINCT FROM OLD.verification_status) OR
       (NEW.contract_status IS DISTINCT FROM OLD.contract_status) OR
       (NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by) OR
       (NEW.contract_reviewed_by IS DISTINCT FROM OLD.contract_reviewed_by) THEN
      IF NOT v_is_authorized THEN
        NEW.verified := OLD.verified;
        NEW.is_verified := OLD.is_verified;
        NEW.is_active := OLD.is_active;
        NEW.verification_status := OLD.verification_status;
        NEW.contract_status := OLD.contract_status;
        NEW.reviewed_by := OLD.reviewed_by;
        NEW.reviewed_at := OLD.reviewed_at;
        NEW.contract_reviewed_by := OLD.contract_reviewed_by;
        NEW.contract_reviewed_at := OLD.contract_reviewed_at;
      END IF;
    END IF;

    -- لا يمكن تفعيل الممرض إلا بعد اعتماد عقده وتوثيق حسابه
    IF NEW.is_active = true AND (NEW.contract_status IS DISTINCT FROM 'approved' OR (NEW.verified IS NOT TRUE AND NEW.is_verified IS NOT TRUE)) THEN
      NEW.is_active := false;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_nurse_self_approval_trg ON public.nurse_profiles;
CREATE TRIGGER prevent_nurse_self_approval_trg
BEFORE INSERT OR UPDATE ON public.nurse_profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_prevent_nurse_self_approval();

-- تأمين جدول profiles وسياسات حماية البيانات الشخصية للمرضى (PII Data Protection)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Profiles select policy" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Public profiles are viewable by everyone." ON public.profiles;

CREATE POLICY "Users can view own profile"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id OR public.is_admin());

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id OR public.is_admin())
  WITH CHECK (auth.uid() = id OR public.is_admin());

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile"
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can view profiles related to their bookings" ON public.profiles;
CREATE POLICY "Users can view profiles related to their bookings"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE (b.patient_id = auth.uid() AND (b.nurse_id = public.profiles.id OR b.nurse_profile_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = public.profiles.id)))
         OR ((b.nurse_id = auth.uid() OR b.nurse_profile_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())) AND b.patient_id = public.profiles.id)
    )
  );

-- ------------------------------------------------------------
-- 1.2 سياسات أمان ملفات الممرضين المهنية (public.nurse_profiles RLS)
-- ------------------------------------------------------------
ALTER TABLE public.nurse_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Nurse profiles are viewable by everyone" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Public can view approved nurse profiles" ON public.nurse_profiles;
CREATE POLICY "Public can view approved nurse profiles"
  ON public.nurse_profiles FOR SELECT
  USING (
    (verified = true AND is_active = true AND (verification_status = 'approved' OR verification_status IS NULL))
    OR auth.uid() = user_id
    OR public.is_admin()
  );

DROP POLICY IF EXISTS "Nurses can insert own nurse profile" ON public.nurse_profiles;
CREATE POLICY "Nurses can insert own nurse profile"
  ON public.nurse_profiles FOR INSERT
  WITH CHECK (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "Nurses can update own nurse profile" ON public.nurse_profiles;
CREATE POLICY "Nurses can update own nurse profile"
  ON public.nurse_profiles FOR UPDATE
  USING (auth.uid() = user_id OR public.is_admin())
  WITH CHECK (auth.uid() = user_id OR public.is_admin());

-- تريجر حماية الحجوزات من التلاعب المالي أو تغيير أطراف الزيارة
CREATE OR REPLACE FUNCTION public.trg_protect_booking_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_role text;
  v_is_admin boolean;
  v_is_privileged boolean;
BEGIN
  BEGIN
    v_caller_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_caller_role := NULL;
  END;

  v_is_admin := public.is_admin();
  v_is_privileged := v_is_admin 
    OR v_caller_role = 'service_role' 
    OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL);

  IF NOT v_is_privileged THEN
    -- 1. منع تعديل أطراف الحجز نهائياً
    IF NEW.patient_id IS DISTINCT FROM OLD.patient_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير المريض صاحب الحجز';
    END IF;

    IF NEW.nurse_id IS DISTINCT FROM OLD.nurse_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير الممرض المسند إليه الحجز';
    END IF;

    IF NEW.nurse_profile_id IS DISTINCT FROM OLD.nurse_profile_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير الملف المهني للممرض المسند إليه الحجز';
    END IF;

    -- 2. منع الممرض من تعديل بيانات المريض وملاحظاته وعنوانه
    IF (auth.uid() = OLD.nurse_id OR auth.uid() IN (SELECT user_id FROM public.nurse_profiles WHERE id = OLD.nurse_profile_id)) THEN
      IF NEW.patient_name IS DISTINCT FROM OLD.patient_name OR
         NEW.patient_phone IS DISTINCT FROM OLD.patient_phone OR
         NEW.patient_address IS DISTINCT FROM OLD.patient_address OR
         NEW.governorate IS DISTINCT FROM OLD.governorate OR
         NEW.city IS DISTINCT FROM OLD.city OR
         NEW.notes IS DISTINCT FROM OLD.notes OR
         NEW.patient_notes IS DISTINCT FROM OLD.patient_notes THEN
        RAISE EXCEPTION 'غير مصرح للممرض بتعديل بيانات أو عنوان أو ملاحظات المريض';
      END IF;
    END IF;

    -- 3. منع تعديل الأسعار والمبالغ والنسب المالية مباشرة من العميل
    IF NEW.total_price IS DISTINCT FROM OLD.total_price OR
       NEW.price IS DISTINCT FROM OLD.price OR
       NEW.deposit_amount IS DISTINCT FROM OLD.deposit_amount OR
       (NEW.commission_rate IS DISTINCT FROM OLD.commission_rate AND OLD.commission_rate IS NOT NULL) OR
       (NEW.commission_amount IS DISTINCT FROM OLD.commission_amount AND OLD.commission_amount IS NOT NULL) OR
       (NEW.nurse_net_amount IS DISTINCT FROM OLD.nurse_net_amount AND OLD.nurse_net_amount IS NOT NULL) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل أسعار أو عمولات الحجز مباشرة من العميل';
    END IF;

    -- 4. منع التلاعب بحالة الدفع ومؤشرات الصرف والاعتماد المالي
    IF (NEW.payment_status IS DISTINCT FROM OLD.payment_status AND NEW.payment_status IN ('verified', 'approved')) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن اعتماد دفع الحجز إلا من خلال إدارة النظام المعتمدة';
    END IF;

    IF (NEW.nurse_payout_credited IS DISTINCT FROM OLD.nurse_payout_credited AND NEW.nurse_payout_credited = true) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن إضافة مستحقات الممرض إلا من خلال إدارة النظام المعتمدة';
    END IF;

    IF (NEW.payment_reviewed_by IS DISTINCT FROM OLD.payment_reviewed_by OR NEW.payment_reviewed_at IS DISTINCT FROM OLD.payment_reviewed_at) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل بيانات مراجعة الدفع إلا من قبل الإدارة';
    END IF;

    -- 5. تسجيل العمولة: لا يمكن تسجيلها إلا إذا كانت الزيارة مكتملة
    IF (NEW.commission_recorded IS DISTINCT FROM OLD.commission_recorded AND NEW.commission_recorded = true) THEN
      IF OLD.status != 'completed' AND NEW.status != 'completed' THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تسجيل عمولة الحجز قبل اكتمال الزيارة';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_booking_immutability_trg ON public.bookings;
CREATE TRIGGER protect_booking_immutability_trg
BEFORE UPDATE ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_booking_immutability();

-- سياسات RLS المحكمة لجدول الحجوزات (bookings)
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view related bookings" ON public.bookings;
DROP POLICY IF EXISTS "Users can view their related bookings" ON public.bookings;
DROP POLICY IF EXISTS "Users can view their own bookings" ON public.bookings;
CREATE POLICY "Users can view related bookings"
  ON public.bookings FOR SELECT
  USING (
    auth.uid() = patient_id
    OR auth.uid() = nurse_id
    OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())
    OR public.is_admin()
  );

DROP POLICY IF EXISTS "Authenticated patients can insert bookings" ON public.bookings;
DROP POLICY IF EXISTS "Patients can insert their own bookings" ON public.bookings;
CREATE POLICY "Patients can insert their own bookings"
  ON public.bookings FOR INSERT
  WITH CHECK (
    auth.uid() = patient_id
    AND status = 'pending'
  );

-- حذف السياسة القديمة المتساهلة التي تسمح للمستخدم بتعديل كامل الحجز
DROP POLICY IF EXISTS "Users can update their bookings" ON public.bookings;
DROP POLICY IF EXISTS "Patients can cancel own pending bookings" ON public.bookings;
DROP POLICY IF EXISTS "Patients can cancel own bookings" ON public.bookings;
CREATE POLICY "Patients can cancel own pending bookings"
  ON public.bookings FOR UPDATE
  USING (auth.uid() = patient_id AND status IN ('pending', 'accepted'))
  WITH CHECK (auth.uid() = patient_id AND status = 'cancelled');

DROP POLICY IF EXISTS "Nurses can update assigned bookings" ON public.bookings;
DROP POLICY IF EXISTS "Nurses can update booking operational status" ON public.bookings;
CREATE POLICY "Nurses can update booking operational status"
  ON public.bookings FOR UPDATE
  USING (
    (auth.uid() = nurse_id OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid()))
    AND status IN ('pending', 'accepted', 'in_progress')
  )
  WITH CHECK (
    (auth.uid() = nurse_id OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid()))
    AND status IN ('accepted', 'rejected', 'in_progress', 'completed')
  );

DROP POLICY IF EXISTS "Admins manage all bookings" ON public.bookings;
CREATE POLICY "Admins manage all bookings"
  ON public.bookings FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ------------------------------------------------------------
-- 1.3 تأمين جدول الخدمات وسياسات RLS (public.services RLS)
-- حظر التعديل أو الحذف من المستخدمين العاديين وحصره بالإدارة المعتمدة
-- ------------------------------------------------------------
ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Services are viewable by everyone" ON public.services;
DROP POLICY IF EXISTS "Admins can manage services" ON public.services;
DROP POLICY IF EXISTS "All users can modify services" ON public.services;

CREATE POLICY "Services are viewable by everyone"
  ON public.services FOR SELECT
  USING (
    is_active = true 
    OR public.is_admin() 
    OR auth.role() = 'service_role'
  );

CREATE POLICY "Admins can manage services"
  ON public.services FOR ALL
  USING (
    public.is_admin() 
    OR auth.role() = 'service_role'
  )
  WITH CHECK (
    public.is_admin() 
    OR auth.role() = 'service_role'
  );


-- ------------------------------------------------------------
-- 1. جدول إعدادات المنصة (Platform Settings)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.platform_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  description text,
  is_public boolean DEFAULT false, -- عزل الإعدادات العامة عن السرية
  updated_at timestamptz DEFAULT now(),
  updated_by uuid REFERENCES public.profiles(id)
);

ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

-- الزوار والمستخدمون يمكنهم قراءة الإعدادات العامة فقط (نسبة العمولة، السياسات، القواعد)
DROP POLICY IF EXISTS "Public can view public settings only" ON public.platform_settings;
CREATE POLICY "Public can view public settings only"
  ON public.platform_settings FOR SELECT
  USING (
    is_public = true 
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS "Admins can manage all platform settings" ON public.platform_settings;
CREATE POLICY "Admins can manage all platform settings"
  ON public.platform_settings FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- الإعدادات الأولية (أرقام الدفع فارغة تماماً ولا تحتوي على أرقام تجريبية حتى يدخلها المدير بنفسه)
INSERT INTO public.platform_settings (key, value, description, is_public)
VALUES 
  ('commission_rate', '{"percent": 15.00}'::jsonb, 'نسبة عمولة منصة رعاية على الزيارات', true),
  ('payment_methods', '{"vodafone_cash": {"number": "", "name": ""}, "instapay": {"handle": "", "name": ""}}'::jsonb, 'بيانات التحويل الرسمي للدفع الإلكتروني', false),
  ('platform_contract', '{"file_path": "", "file_name": "", "updated_at": null}'::jsonb, 'العقد الرسمي المعتمد للممرضين', false),
  ('privacy_policy', '{"file_path": "", "file_name": "", "updated_at": null}'::jsonb, 'ملف سياسة الخصوصية المعتمد', true),
  ('platform_guidelines', '{"file_path": "", "file_name": "", "updated_at": null}'::jsonb, 'ملف تعليمات وقواعد استخدام المنصة', true)
ON CONFLICT (key) DO UPDATE
SET is_public = EXCLUDED.is_public, description = EXCLUDED.description;

-- ------------------------------------------------------------
-- 2. تحديث جدول الحجوزات (bookings) بالأعمدة المالية ومؤشرات الأمان
-- ------------------------------------------------------------
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS payment_method text DEFAULT 'cash' CHECK (payment_method IN ('cash', 'vodafone_cash', 'instapay')),
  ADD COLUMN IF NOT EXISTS payment_status text DEFAULT 'pending' CHECK (payment_status IN ('pending', 'pending_review', 'verified', 'approved', 'rejected', 'unpaid')),
  ADD COLUMN IF NOT EXISTS payment_receipt_path text,
  ADD COLUMN IF NOT EXISTS payment_reviewed_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS payment_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_rejection_reason text,
  ADD COLUMN IF NOT EXISTS commission_rate numeric(5,2) DEFAULT 15.00,
  ADD COLUMN IF NOT EXISTS commission_amount numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS nurse_net_amount numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS commission_recorded boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS nurse_payout_credited boolean DEFAULT false;

-- ------------------------------------------------------------
-- 3. تحديث جدول بيانات الممرضين (nurse_profiles) بحالة العقد
-- ------------------------------------------------------------
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS contract_status text DEFAULT 'not_uploaded' CHECK (contract_status IN ('not_uploaded', 'pending_review', 'approved', 'rejected')),
  ADD COLUMN IF NOT EXISTS contract_reviewed_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS contract_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS contract_rejection_reason text;

-- ------------------------------------------------------------
-- 4. جدول محفظة الممرض المالية (nurse_wallets)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.nurse_wallets (
  nurse_id uuid PRIMARY KEY REFERENCES public.nurse_profiles(id) ON DELETE CASCADE,
  nurse_user_id uuid UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  commission_debt numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (commission_debt >= 0),
  pending_payouts numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (pending_payouts >= 0),
  total_paid_payouts numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (total_paid_payouts >= 0),
  total_settled_commissions numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (total_settled_commissions >= 0),
  total_visits_revenue numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (total_visits_revenue >= 0),
  total_commissions_due numeric(10,2) NOT NULL DEFAULT 0.00 CHECK (total_commissions_due >= 0),
  balance numeric(10,2) GENERATED ALWAYS AS (pending_payouts - commission_debt) STORED,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.nurse_wallets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Nurses can read own wallet" ON public.nurse_wallets;
CREATE POLICY "Nurses can read own wallet"
  ON public.nurse_wallets FOR SELECT
  USING (nurse_user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can view and manage all wallets" ON public.nurse_wallets;
CREATE POLICY "Admins can view and manage all wallets"
  ON public.nurse_wallets FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ------------------------------------------------------------
-- 5. جدول سجل العمليات المالية (financial_transactions)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.financial_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid REFERENCES public.bookings(id) ON DELETE SET NULL,
  nurse_id uuid REFERENCES public.nurse_profiles(id) ON DELETE SET NULL,
  nurse_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  patient_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  type text NOT NULL CHECK (type IN ('platform_commission', 'commission_settlement', 'patient_payment', 'nurse_payout')),
  amount numeric(10,2) NOT NULL CHECK (amount > 0),
  status text NOT NULL DEFAULT 'pending_review' CHECK (status IN ('pending_review', 'approved', 'rejected', 'completed')),
  payment_method text CHECK (payment_method IN ('cash', 'vodafone_cash', 'instapay', 'bank_transfer')),
  receipt_path text,
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  rejection_reason text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- منع احتساب عمولة الزيارة مرتين نهائياً
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_booking_commission 
  ON public.financial_transactions (booking_id) 
  WHERE (type = 'platform_commission');

ALTER TABLE public.financial_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Nurses can view their own financial transactions" ON public.financial_transactions;
CREATE POLICY "Nurses can view their own financial transactions"
  ON public.financial_transactions FOR SELECT
  USING (nurse_user_id = auth.uid());

DROP POLICY IF EXISTS "Patients can view their own payments" ON public.financial_transactions;
CREATE POLICY "Patients can view their own payments"
  ON public.financial_transactions FOR SELECT
  USING (patient_id = auth.uid());

DROP POLICY IF EXISTS "Admins can view and manage all transactions" ON public.financial_transactions;
CREATE POLICY "Admins can view and manage all transactions"
  ON public.financial_transactions FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ------------------------------------------------------------
-- 6. جدول عقود الممرضين الموقعة (nurse_contracts)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.nurse_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nurse_id uuid NOT NULL REFERENCES public.nurse_profiles(id) ON DELETE CASCADE,
  nurse_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  file_path text,
  file_name text NOT NULL,
  status text NOT NULL DEFAULT 'pending_review' CHECK (status IN ('not_uploaded', 'pending_review', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.nurse_contracts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Nurses can view own contracts" ON public.nurse_contracts;
CREATE POLICY "Nurses can view own contracts"
  ON public.nurse_contracts FOR SELECT
  USING (nurse_user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can view and manage all contracts" ON public.nurse_contracts;
CREATE POLICY "Admins can view and manage all contracts"
  ON public.nurse_contracts FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ------------------------------------------------------------
-- 6.1 جدول مستندات وتراخيص الممرضين (nurse_documents)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.nurse_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nurse_id uuid NOT NULL REFERENCES public.nurse_profiles(id) ON DELETE CASCADE,
  document_type text NOT NULL,
  storage_path text NOT NULL,
  review_status text NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.nurse_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage all nurse documents" ON public.nurse_documents;
CREATE POLICY "Admins manage all nurse documents"
  ON public.nurse_documents FOR ALL
  USING (public.is_admin() OR auth.role() = 'service_role')
  WITH CHECK (public.is_admin() OR auth.role() = 'service_role');

DROP POLICY IF EXISTS "Nurses view own documents" ON public.nurse_documents;
CREATE POLICY "Nurses view own documents"
  ON public.nurse_documents FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Nurses insert own documents" ON public.nurse_documents;
CREATE POLICY "Nurses insert own documents"
  ON public.nurse_documents FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
    AND review_status = 'pending'
  );

DROP POLICY IF EXISTS "Nurses update own documents" ON public.nurse_documents;
CREATE POLICY "Nurses update own documents"
  ON public.nurse_documents FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
    AND review_status = 'pending'
  );

-- تريجر حماية حالة مراجعة المستندات من الاعتماد الذاتي
CREATE OR REPLACE FUNCTION public.trg_protect_nurse_document_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT (public.is_admin() OR auth.role() = 'service_role' OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)) THEN
    IF NEW.review_status IS DISTINCT FROM OLD.review_status THEN
      IF NEW.review_status != 'pending' THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن اعتماد أو رفض المستند إلا من قبل إدارة النظام';
      END IF;
    END IF;
    IF NEW.nurse_id IS DISTINCT FROM OLD.nurse_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير صاحب المستند';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_nurse_document_status_trg ON public.nurse_documents;
CREATE TRIGGER protect_nurse_document_status_trg
BEFORE UPDATE ON public.nurse_documents
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_nurse_document_status();

-- ------------------------------------------------------------
-- ============================================================
-- 6.2 حماية ونزاهة تقييمات الزيارات (Reviews Integrity & Completion Guard)
-- ============================================================
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "reviews_public_read" ON public.reviews;
CREATE POLICY "reviews_public_read"
  ON public.reviews FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "reviews_patient_insert" ON public.reviews;
CREATE POLICY "reviews_patient_insert"
  ON public.reviews FOR INSERT
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND patient_id = auth.uid()
  );

DROP POLICY IF EXISTS "reviews_admin_all" ON public.reviews;
CREATE POLICY "reviews_admin_all"
  ON public.reviews FOR ALL
  USING (public.is_admin());

-- قيد الفرادة لمنع تكرار تقييم الحجز الواحد
CREATE UNIQUE INDEX IF NOT EXISTS reviews_booking_id_unique ON public.reviews (booking_id);

-- تريجر التحقق من نزاهة وصحة التقييم قبل الإدخال
CREATE OR REPLACE FUNCTION public.trg_validate_review_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_booking record;
BEGIN
  -- جلب بيانات الحجز المرتبط
  SELECT id, status, patient_id, nurse_id, nurse_profile_id 
  INTO v_booking
  FROM public.bookings
  WHERE id = NEW.booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'الحجز المرتبط بهذا التقييم غير موجود في النظام';
  END IF;

  -- 1. لا يُسمح بالتقييم إلا بعد اكتمال الزيارة بنجاح
  IF v_booking.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'لا يمكن تقييم الزيارة إلا بعد اكتمالها بنجاح (حالة الحجز الحالية: %)', v_booking.status;
  END IF;

  -- 2. يجب أن يكون المستخدم هو صاحب الحجز (أو مدير النظام)
  IF NOT (v_booking.patient_id = auth.uid() OR public.is_admin()) THEN
    RAISE EXCEPTION 'غير مصرح: لا يحق إلا للمريض صاحب الحجز كتابة التقييم';
  END IF;

  -- 3. مطابقة وتأمين معرف الممرض آلياً ليكون هو نفس ممرض الحجز المعتمد
  NEW.patient_id := v_booking.patient_id;
  NEW.nurse_id   := v_booking.nurse_id;

  -- 4. التحقق من صحة عدد النجوم (1 إلى 5)
  IF NEW.rating < 1 OR NEW.rating > 5 THEN
    RAISE EXCEPTION 'قيمة التقييم غير صالحة: يجب أن تكون بين 1 و 5 نجوم';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_review_before_insert ON public.reviews;
CREATE TRIGGER trg_validate_review_before_insert
BEFORE INSERT ON public.reviews
FOR EACH ROW
EXECUTE FUNCTION public.trg_validate_review_integrity();

ALTER FUNCTION public.trg_validate_review_integrity() OWNER TO postgres;
ALTER FUNCTION public.trg_protect_nurse_document_status() OWNER TO postgres;

-- 7. جدول محادثات الزيارات (booking_messages)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.booking_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  message text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.booking_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Participants and admins can view booking messages" ON public.booking_messages;
CREATE POLICY "Participants and admins can view booking messages"
  ON public.booking_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_id
        AND (
          b.patient_id = auth.uid()
          OR b.nurse_id = auth.uid()
          OR EXISTS (SELECT 1 FROM public.nurse_profiles np WHERE np.id = b.nurse_id AND np.user_id = auth.uid())
          OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
        )
    )
  );

DROP POLICY IF EXISTS "Participants can send booking messages" ON public.booking_messages;
CREATE POLICY "Participants can send booking messages"
  ON public.booking_messages FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_id
        AND (
          b.patient_id = auth.uid()
          OR b.nurse_id = auth.uid()
          OR EXISTS (SELECT 1 FROM public.nurse_profiles np WHERE np.id = b.nurse_id AND np.user_id = auth.uid())
          OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
        )
    )
  );


-- ------------------------------------------------------------
-- 7.1 جدول سجل تدقيق الإجراءات الإدارية والمالية (admin_audit_logs)
-- سجل غير قابل للتعديل أو الحذف (Immutable Append-Only Audit Trail)
-- ------------------------------------------------------------
-- إعادة تسمية الجدول القديم admin_audit_log إذا وجد للحفاظ على البيانات التاريخية
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'admin_audit_log')
     AND NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'admin_audit_logs') THEN
    ALTER TABLE public.admin_audit_log RENAME TO admin_audit_logs;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  action text NOT NULL,
  target_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  target_resource_type text,
  target_resource_id uuid,
  entity_type text,
  entity_id text,
  details jsonb DEFAULT '{}'::jsonb,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ضمان وجود كافة الأعمدة المطلوبة بالتوافق التام مع السجلات القديمة والجديدة
ALTER TABLE public.admin_audit_logs
  ADD COLUMN IF NOT EXISTS target_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS target_resource_type text,
  ADD COLUMN IF NOT EXISTS target_resource_id uuid,
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id text,
  ADD COLUMN IF NOT EXISTS details jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS notes text;

-- View للتوافق العكسي مع أي استعلامات قديمة تستخدم admin_audit_log
CREATE OR REPLACE VIEW public.admin_audit_log AS SELECT * FROM public.admin_audit_logs;

CREATE INDEX IF NOT EXISTS idx_audit_logs_admin_created ON public.admin_audit_logs (admin_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action_created ON public.admin_audit_logs (action, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON public.admin_audit_logs (entity_type, entity_id);

ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view audit logs" ON public.admin_audit_logs;
CREATE POLICY "Admins can view audit logs"
  ON public.admin_audit_logs FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ------------------------------------------------------------
-- 7.2 قفل وتثبيت نسبة العمولة على الحجز وقت إنشائه (Snapshot Trigger)
-- يمنع تغيير نسبة العمولة بأثر رجعي على الحجوزات السابقة
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_set_booking_commission_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_setting jsonb;
  v_rate numeric(5,2);
BEGIN
  IF NEW.commission_rate IS NULL THEN
    SELECT value INTO v_setting 
    FROM public.platform_settings 
    WHERE key IN ('commission_rate', 'platform_commission') 
    ORDER BY key = 'commission_rate' DESC 
    LIMIT 1;

    IF v_setting IS NOT NULL THEN
      v_rate := COALESCE((v_setting->>'percent')::numeric, (v_setting->>'rate')::numeric, 15.00);
    ELSE
      v_rate := 15.00;
    END IF;

    NEW.commission_rate := v_rate;
  END IF;

  IF NEW.total_price IS NOT NULL AND NEW.total_price > 0 THEN
    NEW.commission_amount := ROUND((NEW.total_price * (NEW.commission_rate / 100.0)), 2);
    NEW.nurse_net_amount := ROUND(NEW.total_price - NEW.commission_amount, 2);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_booking_commission_snapshot_trg ON public.bookings;
CREATE TRIGGER set_booking_commission_snapshot_trg
BEFORE INSERT ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_set_booking_commission_snapshot();

-- ------------------------------------------------------------
-- 8. تحديث عرض الممرضين المتاحين للجمهور (public_nurses VIEW)
-- اشتراط: معتمد + نشط + عقده معتمد رسمياً من الإدارة
-- ------------------------------------------------------------
DROP VIEW IF EXISTS public.public_nurses;
CREATE VIEW public.public_nurses WITH (security_invoker = false) AS
  SELECT
    np.id,
    np.user_id,
    p.full_name,
    p.avatar_url,
    np.specialization,
    np.qualifications,
    np.experience_years,
    np.visit_price,
    np.hourly_rate,
    np.bio,
    np.governorate,
    np.city,
    np.languages,
    np.verified,
    np.is_active,
    np.verification_status,
    np.contract_status,
    np.created_at,
    COALESCE(avg_r.avg_rating, 0.0) AS avg_rating,
    COALESCE(avg_r.review_count, 0) AS review_count
  FROM public.nurse_profiles np
  JOIN public.profiles p ON p.id = np.user_id
  LEFT JOIN (
    SELECT
      nurse_id,
      ROUND(AVG(rating)::numeric, 1) AS avg_rating,
      COUNT(*) AS review_count
    FROM public.reviews
    GROUP BY nurse_id
  ) avg_r ON (avg_r.nurse_id = np.user_id OR avg_r.nurse_id = np.id)
  WHERE np.verified = true 
    AND np.is_active = true 
    AND np.contract_status = 'approved';

-- ============================================================
-- 9. الدوال الذرية الآمنة (SECURITY DEFINER FUNCTIONS)
-- ============================================================

-- أ) دالة جلب بيانات الدفع الرسمية الخاصة بحجز معين (حماية ضد التسريب)
CREATE OR REPLACE FUNCTION public.get_booking_payment_details(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_booking record;
  v_is_admin boolean;
  v_setting jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  SELECT (role = 'admin') INTO v_is_admin FROM public.profiles WHERE id = v_user_id;

  -- السماح فقط للمريض صاحب الحجز أو المدير
  IF NOT COALESCE(v_is_admin, false) AND v_booking.patient_id != v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح لك باستعراض بيانات هذا الحجز');
  END IF;

  SELECT value INTO v_setting FROM public.platform_settings WHERE key = 'payment_methods';
  
  RETURN jsonb_build_object(
    'success', true,
    'payment_methods', v_setting,
    'total_price', v_booking.total_price,
    'booking_status', v_booking.status,
    'payment_status', v_booking.payment_status
  );
END;
$$;

-- ب) دالة احتساب عمولة الزيارة (record_visit_commission)
CREATE OR REPLACE FUNCTION public.record_visit_commission(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_booking record;
  v_nurse record;
  v_rate numeric(5,2);
  v_comm numeric(10,2);
  v_net numeric(10,2);
  v_setting jsonb;
  v_is_admin boolean;
  v_credit_payout boolean := false;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  -- 1. لا تحتسب العمولة إلا إذا كانت الزيارة مكتملة فعلياً
  IF v_booking.status != 'completed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن احتساب العمولة إلا بعد اكتمال الزيارة بنجاح');
  END IF;

  -- 2. التحقق من صلاحية المنفذ (المدير أو الممرض المسؤول عن الزيارة)
  SELECT (role = 'admin') INTO v_is_admin FROM public.profiles WHERE id = v_caller_id;
  IF NOT COALESCE(v_is_admin, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.nurse_profiles 
      WHERE (id = v_booking.nurse_id OR user_id = v_booking.nurse_id) 
        AND user_id = v_caller_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'غير مصرح لك بتسجيل العمولة لهذا الحجز');
    END IF;
  END IF;

  -- 3. منع التكرار
  IF v_booking.commission_recorded THEN
    RETURN jsonb_build_object('success', true, 'message', 'تم تسجيل العمولة مسبقاً لهذا الحجز');
  END IF;

  -- 4. جلب سجل الممرض
  SELECT * INTO v_nurse FROM public.nurse_profiles WHERE id = v_booking.nurse_id;
  IF NOT FOUND THEN
    SELECT * INTO v_nurse FROM public.nurse_profiles WHERE user_id = v_booking.nurse_id;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الملف المهني للممرض غير موجود');
  END IF;

  -- 5. اعتماد نسبة العمولة المثبتة على الحجز وقت إنشائه لمنع التغيير بأثر رجعي
  IF v_booking.commission_rate IS NOT NULL AND v_booking.commission_rate > 0 THEN
    v_rate := v_booking.commission_rate;
  ELSE
    SELECT value INTO v_setting FROM public.platform_settings WHERE key IN ('commission_rate', 'platform_commission') ORDER BY key = 'commission_rate' DESC LIMIT 1;
    IF v_setting IS NOT NULL THEN
      v_rate := COALESCE((v_setting->>'percent')::numeric, (v_setting->>'rate')::numeric, 15.00);
    ELSE
      v_rate := 15.00;
    END IF;
  END IF;

  -- 6. احتساب الأرقام وتثبيتها
  v_comm := ROUND((v_booking.total_price * (v_rate / 100.0)), 2);
  v_net := ROUND(v_booking.total_price - v_comm, 2);

  -- التحقق من إضافة مستحقات الدفع الإلكتروني: تشترط اكتمال الزيارة + اعتماد الإيصال مسبقاً
  IF v_booking.payment_method IN ('vodafone_cash', 'instapay') AND v_booking.payment_status = 'verified' AND NOT v_booking.nurse_payout_credited THEN
    v_credit_payout := true;
  END IF;

  UPDATE public.bookings
  SET 
    commission_rate = v_rate,
    commission_amount = v_comm,
    nurse_net_amount = v_net,
    commission_recorded = true,
    nurse_payout_credited = CASE WHEN v_credit_payout THEN true ELSE nurse_payout_credited END,
    updated_at = now()
  WHERE id = p_booking_id;

  -- 7. تحديث محفظة الممرض
  INSERT INTO public.nurse_wallets (
    nurse_id, 
    nurse_user_id, 
    commission_debt, 
    pending_payouts, 
    total_visits_revenue, 
    total_commissions_due, 
    updated_at
  ) VALUES (
    v_nurse.id,
    v_nurse.user_id,
    CASE WHEN v_booking.payment_method = 'cash' THEN v_comm ELSE 0.00 END,
    CASE WHEN v_credit_payout THEN v_net ELSE 0.00 END,
    v_booking.total_price,
    v_comm,
    now()
  )
  ON CONFLICT (nurse_id) DO UPDATE
  SET 
    commission_debt = public.nurse_wallets.commission_debt + (CASE WHEN v_booking.payment_method = 'cash' THEN v_comm ELSE 0.00 END),
    pending_payouts = public.nurse_wallets.pending_payouts + (CASE WHEN v_credit_payout THEN v_net ELSE 0.00 END),
    total_visits_revenue = public.nurse_wallets.total_visits_revenue + v_booking.total_price,
    total_commissions_due = public.nurse_wallets.total_commissions_due + v_comm,
    updated_at = now();

  -- 8. قيد العملية في المعاملات المالية
  INSERT INTO public.financial_transactions (
    booking_id, nurse_id, nurse_user_id, patient_id, type, amount, status, payment_method, notes
  ) VALUES (
    v_booking.id,
    v_nurse.id,
    v_nurse.user_id,
    v_booking.patient_id,
    'platform_commission',
    v_comm,
    'completed',
    v_booking.payment_method,
    'عمولة منصة رعاية عن الزيارة رقم ' || substring(v_booking.id::text, 1, 8)
  );

  RETURN jsonb_build_object(
    'success', true,
    'commission_rate', v_rate,
    'commission_amount', v_comm,
    'nurse_net_amount', v_net,
    'nurse_payout_credited', v_credit_payout
  );
END;
$$;

-- ج) دالة تقديم المريض لإيصال دفع الزيارة إلكترونياً
CREATE OR REPLACE FUNCTION public.submit_patient_payment(
  p_booking_id uuid,
  p_payment_method text,
  p_receipt_path text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_booking record;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  IF v_booking.patient_id != v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح لك بسداد هذا الحجز');
  END IF;

  -- 1. منع التكرار إذا كان مدفوعاً أو قيد المراجعة
  IF v_booking.payment_status = 'verified' THEN
    RETURN jsonb_build_object('success', false, 'error', 'تم تأكيد دفع هذا الحجز مسبقاً ولا يمكن رفع إيصال جديد');
  END IF;

  IF v_booking.payment_status = 'pending_review' THEN
    RETURN jsonb_build_object('success', false, 'error', 'يوجد إيصال دفع قيد المراجعة لهذا الحجز بالفعل، يرجى انتظار قرار الإدارة');
  END IF;

  IF p_payment_method NOT IN ('vodafone_cash', 'instapay') THEN
    RETURN jsonb_build_object('success', false, 'error', 'طريقة الدفع غير صالحة');
  END IF;

  IF p_receipt_path IS NULL OR trim(p_receipt_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'صورة إيصال التحويل مطلوبة');
  END IF;

  -- 2. التحقق من أن مسار الملف يخص المريض نفسه
  IF NOT (p_receipt_path LIKE 'receipts/' || v_user_id::text || '/%') THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار إيصال التحويل غير صالح أو لا ينتمي إلى حسابك');
  END IF;

  -- 3. التحقق من وجود الملف فعلياً في Storage
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects 
    WHERE bucket_id = 'private-docs' AND name = p_receipt_path
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ملف الإيصال غير موجود في مساحة التخزين الخاصة');
  END IF;

  -- تحديث الحجز
  UPDATE public.bookings
  SET 
    payment_method = p_payment_method,
    payment_status = 'pending_review',
    payment_receipt_path = p_receipt_path,
    payment_rejection_reason = null,
    updated_at = now()
  WHERE id = p_booking_id;

  -- تسجيل المعاملة
  INSERT INTO public.financial_transactions (
    booking_id, patient_id, type, amount, status, payment_method, receipt_path, notes
  ) VALUES (
    p_booking_id,
    v_user_id,
    'patient_payment',
    v_booking.total_price,
    'pending_review',
    p_payment_method,
    p_receipt_path,
    'سداد إلكتروني لحجز الزيارة عبر ' || p_payment_method
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- د) دالة تقديم الممرض لطلب سداد عمولة (مع قفل المحفظة والتحقق من وجود الملف)
CREATE OR REPLACE FUNCTION public.submit_commission_settlement(
  p_amount numeric,
  p_payment_method text,
  p_receipt_path text,
  p_notes text DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_nurse record;
  v_wallet record;
  v_tx_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'مبلغ السداد يجب أن يكون أكبر من صفر');
  END IF;

  IF p_payment_method NOT IN ('vodafone_cash', 'instapay') THEN
    RETURN jsonb_build_object('success', false, 'error', 'طريقة الدفع غير صالحة');
  END IF;

  IF p_receipt_path IS NULL OR trim(p_receipt_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'صورة إيصال التحويل مطلوبة');
  END IF;

  -- 1. التحقق من مسار الملف وأنه يخص الممرض
  IF NOT (p_receipt_path LIKE 'receipts/' || v_user_id::text || '/%') THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار إيصال التحويل غير صالح أو لا ينتمي إلى حسابك');
  END IF;

  -- 2. التحقق من وجود الملف فعلياً في Storage
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects 
    WHERE bucket_id = 'private-docs' AND name = p_receipt_path
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ملف الإيصال غير موجود في مساحة التخزين الخاصة');
  END IF;

  SELECT * INTO v_nurse FROM public.nurse_profiles WHERE user_id = v_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'حساب الممرض غير موجود');
  END IF;

  -- 3. قفل المحفظة (FOR UPDATE) لمنع الطلبات المتزامنة
  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse.id FOR UPDATE;
  IF NOT FOUND OR v_wallet.commission_debt <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا توجد مديونية عمولات مستحقة للسداد على حسابك');
  END IF;

  -- 4. التحقق من عدم تجاوز المديونية
  IF p_amount > v_wallet.commission_debt THEN
    RETURN jsonb_build_object('success', false, 'error', 'مبلغ السداد المطلوب (' || p_amount || ' ج.م) أكبر من إجمالي المديونية المستحقة (' || v_wallet.commission_debt || ' ج.م)');
  END IF;

  -- 5. منع تكرار الطلبات المعلقة
  IF EXISTS (
    SELECT 1 FROM public.financial_transactions 
    WHERE nurse_user_id = v_user_id 
      AND type = 'commission_settlement' 
      AND status = 'pending_review'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'لديك طلب سداد سابق قيد المراجعة بالفعل، يرجى انتظار قرار الإدارة');
  END IF;

  INSERT INTO public.financial_transactions (
    nurse_id, nurse_user_id, type, amount, status, payment_method, receipt_path, notes
  ) VALUES (
    v_nurse.id,
    v_user_id,
    'commission_settlement',
    p_amount,
    'pending_review',
    p_payment_method,
    p_receipt_path,
    p_notes
  ) RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$$;

-- هـ) دالة تقديم الممرض لنسخة العقد الموقع (مع التحقق من وجود الملف في Storage)
CREATE OR REPLACE FUNCTION public.submit_signed_contract(
  p_storage_path text,
  p_file_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_nurse record;
  v_contract_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  IF p_storage_path IS NULL OR trim(p_storage_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار ملف العقد مطلوب');
  END IF;

  -- 1. التحقق من أن مسار العقد يتبع مجلد الممرض
  IF NOT (p_storage_path LIKE 'contracts/' || v_user_id::text || '/%') THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار العقد غير صالح أو لا يتبع حسابك');
  END IF;

  -- 2. التحقق من وجود الملف فعلياً في Storage
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects 
    WHERE bucket_id = 'private-docs' AND name = p_storage_path
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ملف العقد غير موجود في مساحة التخزين الخاصة');
  END IF;

  SELECT * INTO v_nurse FROM public.nurse_profiles WHERE user_id = v_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الملف المهني للممرض غير موجود');
  END IF;

  INSERT INTO public.nurse_contracts (
    nurse_id, nurse_user_id, storage_path, file_path, file_name, status
  ) VALUES (
    v_nurse.id,
    v_user_id,
    p_storage_path,
    p_storage_path,
    COALESCE(p_file_name, 'signed_contract.pdf'),
    'pending_review'
  ) RETURNING id INTO v_contract_id;

  UPDATE public.nurse_profiles
  SET 
    contract_status = 'pending_review',
    contract_rejection_reason = null,
    updated_at = now()
  WHERE id = v_nurse.id;

  RETURN jsonb_build_object('success', true, 'contract_id', v_contract_id);
END;
$$;

-- و) دالة اعتماد المدير لسداد عمولة الممرض (بدون GREATEST وفحص المديونية بدقة)
CREATE OR REPLACE FUNCTION public.approve_commission_settlement(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_tx record;
  v_wallet record;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير موثقة');
  END IF;

  SELECT * INTO v_tx FROM public.financial_transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'المعاملة غير موجودة');
  END IF;

  IF v_tx.status != 'pending_review' THEN
    RETURN jsonb_build_object('success', false, 'error', 'هذه المعاملة ليست قيد المراجعة (الحالة الحالية: ' || v_tx.status || ')');
  END IF;

  IF v_tx.receipt_path IS NULL OR trim(v_tx.receipt_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد سداد بدون إيصال تحويل');
  END IF;

  -- قفل المحفظة والتحقق من المديونية الحقيقية
  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_tx.nurse_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'محفظة الممرض غير موجودة');
  END IF;

  -- رفض صريح بدلاً من GREATEST إذا كان المبلغ أكبر من المديونية الحالية
  IF v_tx.amount > v_wallet.commission_debt THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد السداد: مبلغ المعاملة (' || v_tx.amount || ' ج.م) أكبر من مديونية الممرض الفعلية الحالية (' || v_wallet.commission_debt || ' ج.م)');
  END IF;

  UPDATE public.financial_transactions
  SET 
    status = 'approved',
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE id = p_transaction_id;

  -- خصم دقيق ومباشر
  UPDATE public.nurse_wallets
  SET 
    commission_debt = commission_debt - v_tx.amount,
    total_settled_commissions = total_settled_commissions + v_tx.amount,
    updated_at = now()
  WHERE nurse_id = v_tx.nurse_id;

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'approve_commission_settlement', v_tx.nurse_user_id, 'اعتماد إيصال سداد عمولة بمبلغ: ' || v_tx.amount || ' ج.م');

  RETURN jsonb_build_object('success', true, 'settled_amount', v_tx.amount);
END;
$$;

-- ز) دالة رفض المدير لإيصال سداد عمولة الممرض
CREATE OR REPLACE FUNCTION public.reject_commission_settlement(
  p_transaction_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_tx record;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'سبب الرفض إلزامي عند رفض الإيصال');
  END IF;

  SELECT * INTO v_tx FROM public.financial_transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'المعاملة غير موجودة');
  END IF;

  IF v_tx.status != 'pending_review' THEN
    RETURN jsonb_build_object('success', false, 'error', 'هذه المعاملة ليست قيد المراجعة حالياً');
  END IF;

  UPDATE public.financial_transactions
  SET 
    status = 'rejected',
    rejection_reason = p_reason,
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE id = p_transaction_id;

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'reject_commission_settlement', v_tx.nurse_user_id, 'رفض إيصال سداد عمولة بسبب: ' || p_reason);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ح) دالة اعتماد المدير لدفع المريض إلكترونياً (مع فحص اكتمال الزيارة لإضافة المستحقات)
CREATE OR REPLACE FUNCTION public.admin_approve_patient_payment(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_booking record;
  v_nurse record;
  v_credit_payout boolean := false;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  -- منع اعتماد دفع لحجز ملغي أو مرفوض
  IF v_booking.status IN ('cancelled', 'rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد دفع لحجز ملغي أو مرفوض');
  END IF;

  IF v_booking.payment_status IN ('verified', 'approved') THEN
    RETURN jsonb_build_object('success', true, 'message', 'تم تأكيد دفع هذا الحجز مسبقاً');
  END IF;

  IF v_booking.payment_status != 'pending_review' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يوجد إيصال دفع قيد المراجعة لهذا الحجز');
  END IF;

  IF v_booking.payment_receipt_path IS NULL OR trim(v_booking.payment_receipt_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد الدفع بدون وجود إيصال تحويل مسجل');
  END IF;

  -- إذا كانت الزيارة مكتملة مسبقاً والعمولة مسجلة، ولم تكن المستحقات قد أضيفت: تضاف الآن حصراً
  IF v_booking.status = 'completed' AND v_booking.commission_recorded AND NOT v_booking.nurse_payout_credited THEN
    v_credit_payout := true;
  END IF;

  UPDATE public.bookings
  SET 
    payment_status = 'verified',
    payment_reviewed_by = v_admin_id,
    payment_reviewed_at = now(),
    nurse_payout_credited = CASE WHEN v_credit_payout THEN true ELSE nurse_payout_credited END,
    updated_at = now()
  WHERE id = p_booking_id;

  UPDATE public.financial_transactions
  SET 
    status = 'approved',
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE booking_id = p_booking_id AND type = 'patient_payment' AND status = 'pending_review';

  -- إضافة مستحقات الممرض إذا استوفت الزيارة شرط الاكتمال
  IF v_credit_payout THEN
    SELECT * INTO v_nurse FROM public.nurse_profiles WHERE id = v_booking.nurse_id OR user_id = v_booking.nurse_id;
    IF FOUND THEN
      UPDATE public.nurse_wallets
      SET 
        pending_payouts = pending_payouts + v_booking.nurse_net_amount,
        updated_at = now()
      WHERE nurse_id = v_nurse.id;
    END IF;
  END IF;

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'approve_patient_payment', v_booking.patient_id, 'تأكيد استلام دفع الزيارة إلكترونياً للحجز رقم: ' || p_booking_id || CASE WHEN v_credit_payout THEN ' (وإضافة المستحقات للممرض لاكتمال الزيارة)' ELSE '' END);

  RETURN jsonb_build_object('success', true, 'nurse_payout_credited', v_credit_payout);
END;
$$;

-- ط) دالة رفض المدير لدفع المريض إلكترونياً
CREATE OR REPLACE FUNCTION public.admin_reject_patient_payment(
  p_booking_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_booking record;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'سبب الرفض إلزامي');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  UPDATE public.bookings
  SET 
    payment_status = 'rejected',
    payment_rejection_reason = p_reason,
    payment_reviewed_by = v_admin_id,
    payment_reviewed_at = now(),
    updated_at = now()
  WHERE id = p_booking_id;

  UPDATE public.financial_transactions
  SET 
    status = 'rejected',
    rejection_reason = p_reason,
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE booking_id = p_booking_id AND type = 'patient_payment' AND status = 'pending_review';

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'reject_patient_payment', v_booking.patient_id, 'رفض إيصال دفع الزيارة بسبب: ' || p_reason);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ي) دالة تسجيل تحويل مستحقات الممرض (مع التحقق الصارم من المستحقات الفعلية)
CREATE OR REPLACE FUNCTION public.admin_record_nurse_payout(
  p_nurse_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_receipt_path text DEFAULT null,
  p_notes text DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_nurse record;
  v_wallet record;
  v_tx_id uuid;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'المبلغ المحول يجب أن يكون أكبر من صفر');
  END IF;

  SELECT * INTO v_nurse FROM public.nurse_profiles WHERE id = p_nurse_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الممرض غير موجود');
  END IF;

  -- التحقق من إيصال التحويل إن وُجد
  IF p_receipt_path IS NOT NULL AND trim(p_receipt_path) != '' THEN
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects 
      WHERE bucket_id = 'private-docs' AND name = p_receipt_path
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'ملف إيصال تحويل المستحقات غير موجود في مساحة التخزين');
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse.id FOR UPDATE;
  IF NOT FOUND OR v_wallet.pending_payouts <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا توجد مستحقات معلقة قابلة للصرف لهذا الممرض');
  END IF;

  IF p_amount > v_wallet.pending_payouts THEN
    RETURN jsonb_build_object('success', false, 'error', 'المبلغ المطلوب تحويله (' || p_amount || ' ج.م) أكبر من إجمالي مستحقات الممرض المعلقة (' || v_wallet.pending_payouts || ' ج.م)');
  END IF;

  INSERT INTO public.financial_transactions (
    nurse_id, nurse_user_id, type, amount, status, payment_method, receipt_path, reviewed_by, reviewed_at, notes
  ) VALUES (
    v_nurse.id,
    v_nurse.user_id,
    'nurse_payout',
    p_amount,
    'completed',
    p_payment_method,
    p_receipt_path,
    v_admin_id,
    now(),
    p_notes
  ) RETURNING id INTO v_tx_id;

  UPDATE public.nurse_wallets
  SET 
    pending_payouts = pending_payouts - p_amount,
    total_paid_payouts = total_paid_payouts + p_amount,
    updated_at = now()
  WHERE nurse_id = v_nurse.id;

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'nurse_payout', v_nurse.user_id, 'تسجيل تحويل مستحقات صافية للممرض بمبلغ: ' || p_amount || ' ج.م عبر ' || p_payment_method);

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$$;

-- ك) دالة مراجعة واعتماد/رفض عقد الممرض
CREATE OR REPLACE FUNCTION public.admin_review_nurse_contract(
  p_contract_id uuid,
  p_new_status text,
  p_rejection_reason text DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_contract record;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'حالة المراجعة يجب أن تكون إما approved أو rejected');
  END IF;

  IF p_new_status = 'rejected' AND (p_rejection_reason IS NULL OR trim(p_rejection_reason) = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'سبب الرفض إلزامي عند رفض العقد');
  END IF;

  SELECT * INTO v_contract FROM public.nurse_contracts WHERE id = p_contract_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'العقد غير موجود');
  END IF;

  -- منع اعتماد عقد قديم إذا قام الممرض برفع عقد أحدث
  IF EXISTS (
    SELECT 1 FROM public.nurse_contracts 
    WHERE nurse_id = v_contract.nurse_id 
      AND created_at > v_contract.created_at
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد أو مراجعة هذا العقد لوجود نسخة أحدث قام الممرض برفعها');
  END IF;

  UPDATE public.nurse_contracts
  SET 
    status = p_new_status,
    rejection_reason = CASE WHEN p_new_status = 'rejected' THEN p_rejection_reason ELSE null END,
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE id = p_contract_id;

  UPDATE public.nurse_profiles
  SET 
    contract_status = p_new_status,
    contract_reviewed_by = v_admin_id,
    contract_reviewed_at = now(),
    contract_rejection_reason = CASE WHEN p_new_status = 'rejected' THEN p_rejection_reason ELSE null END,
    updated_at = now()
  WHERE id = v_contract.nurse_id;

  INSERT INTO public.admin_audit_logs (admin_id, action, target_user_id, notes)
  VALUES (v_admin_id, 'review_nurse_contract', v_contract.nurse_user_id, 'مراجعة عقد الممرض، النتيجة: ' || p_new_status);

  RETURN jsonb_build_object('success', true, 'status', p_new_status);
END;
$$;

-- ------------------------------------------------------------
-- 10. ضبط الصلاحيات الدقيقة على الدوال (Permissions Hardening)
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.get_booking_payment_details(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_visit_commission(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_commission_settlement(numeric, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_signed_contract(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_patient_payment(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.approve_commission_settlement(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reject_commission_settlement(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_approve_patient_payment(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_reject_patient_payment(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_record_nurse_payout(uuid, numeric, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_review_nurse_contract(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_booking_payment_details(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_visit_commission(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_commission_settlement(numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_signed_contract(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_patient_payment(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_commission_settlement(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_commission_settlement(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_patient_payment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_patient_payment(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_record_nurse_payout(uuid, numeric, text, text, text) TO authenticated;

-- ك) دالة جلب بيانات المرضى الخاصة بحجوزات الممرض مع تطبيق قاعدة الحماية H3
CREATE OR REPLACE FUNCTION public.get_nurse_patient_profiles()
RETURNS TABLE (
  booking_id uuid,
  patient_id uuid,
  full_name text,
  phone text,
  patient_address text,
  governorate text,
  city text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_is_admin boolean := false;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  SELECT (role = 'admin') INTO v_is_admin FROM public.profiles WHERE id = v_caller_id;

  RETURN QUERY
  SELECT
    b.id AS booking_id,
    p.id AS patient_id,
    p.full_name,
    CASE 
      WHEN v_is_admin OR b.status IN ('accepted', 'in_progress', 'completed') THEN p.phone
      ELSE NULL
    END AS phone,
    CASE 
      WHEN v_is_admin OR b.status IN ('accepted', 'in_progress', 'completed') THEN COALESCE(b.patient_address, p.address)
      ELSE NULL
    END AS patient_address,
    COALESCE(b.governorate, p.governorate) AS governorate,
    COALESCE(b.city, p.city) AS city
  FROM public.bookings b
  JOIN public.profiles p ON p.id = b.patient_id
  WHERE 
    v_is_admin
    OR b.nurse_id = v_caller_id
    OR EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = b.nurse_id AND np.user_id = v_caller_id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_review_nurse_contract(uuid, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_nurse_patient_profiles() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_nurse_patient_profiles() TO authenticated;
GRANT SELECT ON public.admin_audit_logs TO authenticated;


-- ============================================================
-- 10.1 تثبيت ملكية جميع الدوال الحساسة لصالح postgres وضبط الصلاحيات
-- ============================================================
ALTER FUNCTION public.trg_sync_nurse_profile_columns() OWNER TO postgres;
ALTER FUNCTION public.trg_sync_booking_nurse_identity() OWNER TO postgres;
ALTER FUNCTION public.handle_new_user() OWNER TO postgres;
ALTER FUNCTION public.is_admin() OWNER TO postgres;
ALTER FUNCTION public.trg_enforce_profile_role_security() OWNER TO postgres;
ALTER FUNCTION public.trg_prevent_nurse_self_approval() OWNER TO postgres;
ALTER FUNCTION public.trg_protect_booking_immutability() OWNER TO postgres;
ALTER FUNCTION public.trg_set_booking_commission_snapshot() OWNER TO postgres;
ALTER FUNCTION public.get_booking_payment_details(uuid) OWNER TO postgres;
ALTER FUNCTION public.record_visit_commission(uuid) OWNER TO postgres;
ALTER FUNCTION public.submit_patient_payment(uuid, text, text) OWNER TO postgres;
ALTER FUNCTION public.submit_commission_settlement(numeric, text, text, text) OWNER TO postgres;
ALTER FUNCTION public.submit_signed_contract(text, text) OWNER TO postgres;
ALTER FUNCTION public.approve_commission_settlement(uuid) OWNER TO postgres;
ALTER FUNCTION public.reject_commission_settlement(uuid, text) OWNER TO postgres;
ALTER FUNCTION public.admin_approve_patient_payment(uuid) OWNER TO postgres;
ALTER FUNCTION public.admin_reject_patient_payment(uuid, text) OWNER TO postgres;
ALTER FUNCTION public.admin_record_nurse_payout(uuid, numeric, text, text, text) OWNER TO postgres;
ALTER FUNCTION public.admin_review_nurse_contract(uuid, text, text) OWNER TO postgres;
ALTER FUNCTION public.get_nurse_patient_profiles() OWNER TO postgres;
ALTER FUNCTION public.admin_approve_commission_settlement(uuid, uuid) OWNER TO postgres;
ALTER FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) OWNER TO postgres;
ALTER FUNCTION public._get_visit_encryption_key() OWNER TO postgres;
ALTER FUNCTION public._generate_and_store_code(uuid, text) OWNER TO postgres;
ALTER FUNCTION public.get_patient_visit_code(uuid) OWNER TO postgres;
ALTER FUNCTION public.verify_visit_code_atomic(uuid, text, text) OWNER TO postgres;
ALTER FUNCTION public.trg_generate_initial_visit_code() OWNER TO postgres;

-- حظر الدوال الداخلية تماماً عن الجمهور والمستخدمين
REVOKE ALL ON FUNCTION public._get_visit_encryption_key() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._generate_and_store_code(uuid, text) FROM PUBLIC, anon, authenticated;

-- حظر الدوال الإدارية والحساسة عن anon والجمهور العام
REVOKE ALL ON FUNCTION public.admin_approve_commission_settlement(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_patient_visit_code(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_visit_code_atomic(uuid, text, text) FROM PUBLIC, anon;

-- منح الصلاحيات للأدوار المصرحة حصراً
GRANT EXECUTE ON FUNCTION public.admin_approve_commission_settlement(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_patient_visit_code(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_visit_code_atomic(uuid, text, text) TO authenticated;

-- ============================================================
-- 11. سياسات الأمان لمساحة التخزين الخاصة (Storage RLS Policies)
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('private-docs', 'private-docs', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- سياسة رفع وقراءة إيصالات التحويل (receipts)
DROP POLICY IF EXISTS "Users can upload their own receipts" ON storage.objects;
CREATE POLICY "Users can upload their own receipts"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'private-docs' 
    AND (storage.foldername(name))[1] = 'receipts'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Users and admins can view receipts" ON storage.objects;
CREATE POLICY "Users and admins can view receipts"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = 'receipts'
    AND (
      (storage.foldername(name))[2] = auth.uid()::text
      OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    )
  );

-- سياسة رفع وقراءة عقود الممرضين الموقعة (contracts)
DROP POLICY IF EXISTS "Nurses can upload their signed contracts" ON storage.objects;
CREATE POLICY "Nurses can upload their signed contracts"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = 'contracts'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Nurses and admins can view contracts" ON storage.objects;
CREATE POLICY "Nurses and admins can view contracts"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = 'contracts'
    AND (
      (storage.foldername(name))[2] = auth.uid()::text
      OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    )
  );

-- سياسة إدارة المستندات الرسمية للمنصة
DROP POLICY IF EXISTS "Admins can manage platform official documents" ON storage.objects;
CREATE POLICY "Admins can manage platform official documents"
  ON storage.objects FOR ALL
  USING (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = 'platform_docs'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS "Authenticated users can read platform official documents" ON storage.objects;
CREATE POLICY "Authenticated users can read platform official documents"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = 'platform_docs'
    AND auth.uid() IS NOT NULL
  );


-- دوال مرادفة للاعتماد والرفض بالاسم الإداري لدعم مختلف توقيعات الاستدعاء (Overloads)
CREATE OR REPLACE FUNCTION public.admin_approve_commission_settlement(
  p_transaction_id uuid DEFAULT null,
  p_settlement_id uuid DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid := COALESCE(p_transaction_id, p_settlement_id);
BEGIN
  RETURN public.approve_commission_settlement(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_approve_commission_settlement(
  p_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.approve_commission_settlement(p_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_commission_settlement(
  p_transaction_id uuid DEFAULT null,
  p_reason text DEFAULT null,
  p_settlement_id uuid DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid := COALESCE(p_transaction_id, p_settlement_id);
BEGIN
  RETURN public.reject_commission_settlement(v_id, p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_commission_settlement(
  p_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.reject_commission_settlement(p_id, p_reason);
END;
$$;

ALTER FUNCTION public.admin_approve_commission_settlement(uuid, uuid) OWNER TO postgres;
ALTER FUNCTION public.admin_approve_commission_settlement(uuid) OWNER TO postgres;
ALTER FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) OWNER TO postgres;
ALTER FUNCTION public.admin_reject_commission_settlement(uuid, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.admin_approve_commission_settlement(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_approve_commission_settlement(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reject_commission_settlement(uuid, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_approve_commission_settlement(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_commission_settlement(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_commission_settlement(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_commission_settlement(uuid, text) TO authenticated;

-- حاوية الصور الشخصية للمستخدمين (profile-photos)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'profile-photos', 
  'profile-photos', 
  true, 
  2097152, -- 2MB
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET 
  public = true,
  file_size_limit = 2097152,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

DROP POLICY IF EXISTS "profile_photos_public_read" ON storage.objects;
CREATE POLICY "profile_photos_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'profile-photos');

DROP POLICY IF EXISTS "profile_photos_user_manage" ON storage.objects;
CREATE POLICY "profile_photos_user_manage"
  ON storage.objects FOR ALL
  USING (
    bucket_id = 'profile-photos'
    AND (
      (storage.foldername(name))[1] = 'avatars'
      AND (storage.foldername(name))[2] = auth.uid()::text
      OR public.is_admin()
    )
  )
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND (
      (storage.foldername(name))[1] = 'avatars'
      AND (storage.foldername(name))[2] = auth.uid()::text
      OR public.is_admin()
    )
  );

-- 12. منظومة أكواد تأكيد الزيارة المشفرة (Visit Confirmation System)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.visit_codes (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id     uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  code_type      text        NOT NULL CHECK (code_type IN ('start', 'end')),
  code_hash      text        NOT NULL,
  salt           text        NOT NULL,
  encrypted_code text        NOT NULL,
  is_used        boolean     NOT NULL DEFAULT false,
  used_at        timestamptz,
  expires_at     timestamptz NOT NULL,
  attempts       int         NOT NULL DEFAULT 0,
  is_locked      boolean     NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booking_id, code_type)
);

ALTER TABLE public.visit_codes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "No direct public access to visit_codes" ON public.visit_codes;
CREATE POLICY "No direct public access to visit_codes"
  ON public.visit_codes FOR ALL
  USING (false);

-- مفتاح تشفير كود الزيارة المشتق خادمياً من Supabase Vault أو الإعدادات المشفرة
-- محصن بدون أي قيم ثابتة نهائياً (Fail-Closed)
CREATE OR REPLACE FUNCTION public._get_visit_encryption_key()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret text := null;
BEGIN
  -- 1. محاولة القراءة الآمنة من Supabase Vault (decrypted_secrets)
  IF EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'vault' AND table_name = 'decrypted_secrets'
  ) THEN
    BEGIN
      EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = ''visit_encryption_key'' LIMIT 1'
      INTO v_secret;
    EXCEPTION WHEN OTHERS THEN
      v_secret := null;
    END;
  END IF;

  -- 2. بديل آمن: قراءة متغير الجلسة المهيأ في البيئة إن وُجد
  IF v_secret IS NULL OR length(trim(v_secret)) < 16 THEN
    v_secret := current_setting('app.settings.visit_secret_key', true);
  END IF;

  IF v_secret IS NULL OR length(trim(v_secret)) < 16 THEN
    v_secret := current_setting('app.settings.jwt_secret', true);
  END IF;

  -- 3. في حال غياب المفتاح: إيقاف العملية فوراً برمي استثناء صريح (Fail-Closed)
  IF v_secret IS NULL OR length(trim(v_secret)) < 16 THEN
    RAISE EXCEPTION 'CRITICAL SECURITY ERROR: Visit code encryption key is missing from Supabase Vault (visit_encryption_key) or app.settings.visit_secret_key. Operation aborted.';
  END IF;

  RETURN encode(extensions.digest(v_secret || '_visit_codes_salt', 'sha256'), 'hex');
END;
$$;

-- توليد كود التحقق وتخزينه مشفراً
CREATE OR REPLACE FUNCTION public._generate_and_store_code(
  p_booking_id uuid,
  p_code_type  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_raw_code   text;
  v_salt       text;
  v_hash       text;
  v_enc_key    text;
  v_encrypted  text;
  v_expires_at timestamptz;
  v_visit_date date;
BEGIN
  SELECT visit_date INTO v_visit_date FROM public.bookings WHERE id = p_booking_id;
  IF v_visit_date IS NOT NULL THEN
    v_expires_at := (v_visit_date + interval '1 day' + interval '6 hours')::timestamptz;
  ELSE
    v_expires_at := now() + interval '24 hours';
  END IF;

  v_raw_code  := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  v_salt      := encode(extensions.gen_random_bytes(16), 'hex');
  v_hash      := encode(extensions.digest(v_raw_code || v_salt, 'sha256'), 'hex');
  v_enc_key   := public._get_visit_encryption_key();
  v_encrypted := encode(extensions.pgp_sym_encrypt(v_raw_code, v_enc_key), 'base64');

  INSERT INTO public.visit_codes (
    booking_id, code_type, code_hash, salt, encrypted_code, expires_at
  ) VALUES (
    p_booking_id, p_code_type, v_hash, v_salt, v_encrypted, v_expires_at
  )
  ON CONFLICT (booking_id, code_type) DO UPDATE SET
    code_hash      = EXCLUDED.code_hash,
    salt           = EXCLUDED.salt,
    encrypted_code = EXCLUDED.encrypted_code,
    expires_at     = EXCLUDED.expires_at,
    is_used        = false,
    used_at        = null,
    attempts       = 0,
    is_locked      = false;
END;
$$;

-- جلب كود التحقق للمريض فقط
CREATE OR REPLACE FUNCTION public.get_patient_visit_code(p_booking_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_booking     public.bookings%ROWTYPE;
  v_code_rec    public.visit_codes%ROWTYPE;
  v_target_type text;
  v_plain_code  text;
  v_enc_key     text;
BEGIN
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN
    RETURN json_build_object('available', false, 'error', 'الحجز غير موجود.');
  END IF;

  IF v_booking.patient_id <> auth.uid() AND NOT public.is_admin() THEN
    RETURN json_build_object('available', false, 'error', 'غير مصرح لك بالاطلاع على هذا الكود.');
  END IF;

  IF v_booking.status = 'accepted' THEN
    v_target_type := 'start';
  ELSIF v_booking.status = 'in_progress' THEN
    v_target_type := 'end';
  ELSE
    RETURN json_build_object('available', false, 'reason', 'لا توجد أكواد نشطة لهذه الحالة.');
  END IF;

  SELECT * INTO v_code_rec FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = v_target_type;

  IF NOT FOUND THEN
    RETURN json_build_object('available', false, 'reason', 'الكود قيد التجهيز.');
  END IF;

  IF v_code_rec.is_locked THEN
    RETURN json_build_object('available', false, 'is_locked', true, 'reason', 'تم إيقاف الكود لتجاوز عدد المحاولات.');
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('available', false, 'is_used', true, 'reason', 'تم استخدام الكود مسبقاً.');
  END IF;

  IF now() > v_code_rec.expires_at THEN
    RETURN json_build_object('available', false, 'expired', true, 'reason', 'انتهت صلاحية الكود.');
  END IF;

  v_enc_key := public._get_visit_encryption_key();
  v_plain_code := extensions.pgp_sym_decrypt(decode(v_code_rec.encrypted_code, 'base64'), v_enc_key);

  RETURN json_build_object(
    'available',  true,
    'code_type',  v_target_type,
    'code',       v_plain_code,
    'expires_at', v_code_rec.expires_at
  );
END;
$$;

-- التحقق الذري من كود الزيارة وتحديث حالة الحجز
CREATE OR REPLACE FUNCTION public.verify_visit_code_atomic(
  p_booking_id uuid,
  p_input_code text,
  p_code_type  text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_booking     public.bookings%ROWTYPE;
  v_code_rec    public.visit_codes%ROWTYPE;
  v_nurse_rec   public.nurse_profiles%ROWTYPE;
  v_computed    text;
BEGIN
  IF p_code_type NOT IN ('start', 'end') THEN
    RETURN json_build_object('success', false, 'error', 'نوع الكود غير صالح.');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'الحجز غير موجود.');
  END IF;

  SELECT * INTO v_nurse_rec FROM public.nurse_profiles
  WHERE id = v_booking.nurse_id OR user_id = v_booking.nurse_id;

  IF (v_booking.nurse_id <> auth.uid() AND v_nurse_rec.user_id <> auth.uid()) AND NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'error', 'غير مصرح لك بتأكيد هذا الحجز.');
  END IF;

  IF p_code_type = 'start' AND v_booking.status <> 'accepted' THEN
    RETURN json_build_object('success', false, 'error', 'الحجز ليس في حالة مقبولة لبدء الزيارة.');
  END IF;

  IF p_code_type = 'end' AND v_booking.status <> 'in_progress' THEN
    RETURN json_build_object('success', false, 'error', 'الزيارة لم تبدأ بعد لتتمكن من إنهائها.');
  END IF;

  SELECT * INTO v_code_rec FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = p_code_type
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'سجل كود التحقق غير موجود.');
  END IF;

  IF v_code_rec.is_locked THEN
    RETURN json_build_object('success', false, 'error', 'تم قفل الكود لتكرار المحاولات الخاطئة.');
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('success', false, 'error', 'تم استخدام هذا الكود مسبقاً.');
  END IF;

  IF now() > v_code_rec.expires_at THEN
    RETURN json_build_object('success', false, 'error', 'انتهت صلاحية كود التحقق.');
  END IF;

  v_computed := encode(extensions.digest(p_input_code || v_code_rec.salt, 'sha256'), 'hex');

  IF v_computed <> v_code_rec.code_hash THEN
    UPDATE public.visit_codes
    SET
      attempts  = attempts + 1,
      is_locked = (attempts + 1 >= 5)
    WHERE id = v_code_rec.id;

    RETURN json_build_object(
      'success', false,
      'error', 'كود التحقق غير صحيح.',
      'attempts_left', GREATEST(0, 5 - (v_code_rec.attempts + 1))
    );
  END IF;

  UPDATE public.visit_codes
  SET is_used = true, used_at = now()
  WHERE id = v_code_rec.id;

  IF p_code_type = 'start' THEN
    UPDATE public.bookings SET status = 'in_progress', updated_at = now() WHERE id = p_booking_id;
    PERFORM public._generate_and_store_code(p_booking_id, 'end');
    RETURN json_build_object('success', true, 'new_status', 'in_progress');
  ELSE
    UPDATE public.bookings SET status = 'completed', updated_at = now() WHERE id = p_booking_id;
    RETURN json_build_object('success', true, 'new_status', 'completed');
  END IF;
END;
$$;

-- تريجر توليد كود البدء تلقائياً عند قبول الحجز
CREATE OR REPLACE FUNCTION public.trg_generate_initial_visit_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status <> 'accepted') THEN
    PERFORM public._generate_and_store_code(NEW.id, 'start');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_generate_initial_visit_code ON public.bookings;
CREATE TRIGGER trg_generate_initial_visit_code
AFTER INSERT OR UPDATE OF status ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_generate_initial_visit_code();

GRANT EXECUTE ON FUNCTION public.get_patient_visit_code(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_visit_code_atomic(uuid, text, text) TO authenticated;
