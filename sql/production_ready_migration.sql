-- ============================================================
-- CareNest (رعاية) - Comprehensive Production Ready Migration
-- Version: Production v1.0 (Idempotent & Data-Safe)
-- ============================================================
-- Instructions:
-- 1. Open Supabase Dashboard -> SQL Editor
-- 2. Paste and run this script.
-- 3. It will safely update schemas, triggers, RLS policies,
--    and storage policies without losing any existing data.
-- ============================================================

-- ------------------------------------------------------------
-- الخطوة 1: دالة التحقق من صلاحية المدير (Admin Helper Function)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'user_metadata' ->> 'role') = 'admin',
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    ),
    false
  );
$$;

-- ------------------------------------------------------------
-- الخطوة 2: مزامنة وتأكيد أعمدة الجداول الأساسية
-- ------------------------------------------------------------

-- أ) جدول الملفات الشخصية (profiles)
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  full_name text,
  phone text,
  role text DEFAULT 'patient' CHECK (role IN ('patient', 'nurse', 'admin')),
  avatar_url text,
  country text DEFAULT 'Egypt',
  governorate text,
  city text,
  address text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS role text DEFAULT 'patient',
  ADD COLUMN IF NOT EXISTS country text DEFAULT 'Egypt',
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- ب) جدول بيانات الممرضين المهنية (nurse_profiles)
CREATE TABLE IF NOT EXISTS public.nurse_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  specialization text DEFAULT 'تمريض عام',
  specialties text[] DEFAULT '{}',
  qualifications text,
  license_number text,
  experience_years int DEFAULT 0,
  years_experience int DEFAULT 0,
  visit_price numeric(10,2) DEFAULT 150.00,
  hourly_rate numeric(10,2) DEFAULT 150.00,
  country text DEFAULT 'Egypt',
  currency text DEFAULT 'EGP',
  governorate text,
  city text,
  address text,
  governorates text[] DEFAULT array['القاهرة', 'الجيزة'],
  service_areas text[] DEFAULT '{}',
  bio text,
  languages text[] DEFAULT array['العربية'],
  verified boolean DEFAULT false,
  is_verified boolean DEFAULT false,
  is_active boolean DEFAULT false,
  accepting_bookings boolean DEFAULT true,
  verification_status text DEFAULT 'pending',
  rejection_reason text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS specialization text DEFAULT 'تمريض عام',
  ADD COLUMN IF NOT EXISTS qualifications text,
  ADD COLUMN IF NOT EXISTS experience_years int DEFAULT 0,
  ADD COLUMN IF NOT EXISTS visit_price numeric(10,2) DEFAULT 150.00,
  ADD COLUMN IF NOT EXISTS verified boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS accepting_bookings boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS verification_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS rejection_reason text,
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- ج) جدول الخدمات (services)
CREATE TABLE IF NOT EXISTS public.services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar text NOT NULL,
  name_en text NOT NULL,
  description_ar text,
  description_en text,
  icon text DEFAULT '🩺',
  base_price numeric(10,2) NOT NULL DEFAULT 100.00,
  duration_minutes int NOT NULL DEFAULT 60,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- د) جدول الحجوزات (bookings)
CREATE TABLE IF NOT EXISTS public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nurse_id uuid NOT NULL,
  service_id uuid REFERENCES public.services(id) ON DELETE SET NULL,
  service_type text NOT NULL,
  service_name text,
  visit_date date NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  duration_hours numeric(4,2) DEFAULT 1.00,
  price numeric(10,2) NOT NULL DEFAULT 0.00,
  total_price numeric(10,2) NOT NULL DEFAULT 0.00,
  currency text DEFAULT 'EGP',
  country text DEFAULT 'Egypt',
  governorate text,
  city text,
  patient_name text,
  patient_phone text,
  patient_address text,
  patient_notes text,
  notes text,
  latitude numeric(10,6),
  longitude numeric(10,6),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected', 'in_progress', 'completed', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS service_name text,
  ADD COLUMN IF NOT EXISTS duration_hours numeric(4,2) DEFAULT 1.00,
  ADD COLUMN IF NOT EXISTS price numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS total_price numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'EGP',
  ADD COLUMN IF NOT EXISTS country text DEFAULT 'Egypt',
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS patient_name text,
  ADD COLUMN IF NOT EXISTS patient_phone text,
  ADD COLUMN IF NOT EXISTS patient_address text,
  ADD COLUMN IF NOT EXISTS patient_notes text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS latitude numeric(10,6),
  ADD COLUMN IF NOT EXISTS longitude numeric(10,6),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- هـ) جدول تقييمات الزيارات (reviews)
CREATE TABLE IF NOT EXISTS public.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
  patient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nurse_id uuid NOT NULL,
  rating int NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- و) جدول مستندات الممرضين (nurse_documents)
CREATE TABLE IF NOT EXISTS public.nurse_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nurse_id uuid NOT NULL REFERENCES public.nurse_profiles(id) ON DELETE CASCADE,
  document_type text NOT NULL,
  storage_path text NOT NULL,
  review_status text NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending', 'approved', 'rejected')),
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ز) جدول تشفير الرقم القومي الآمن (user_national_ids)
CREATE TABLE IF NOT EXISTS public.user_national_ids (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  national_id_hash text UNIQUE NOT NULL,
  encrypted_national_id text NOT NULL,
  encryption_iv text NOT NULL,
  updated_at timestamptz DEFAULT now()
);

-- ------------------------------------------------------------
-- الخطوة 3: منع تكرار الخدمات عند تشغيل الـ Migration (M12)
-- ------------------------------------------------------------
INSERT INTO public.services (name_ar, name_en, description_ar, description_en, icon, base_price, duration_minutes, is_active)
SELECT s.name_ar, s.name_en, s.description_ar, s.description_en, s.icon, s.base_price, s.duration_minutes, true
FROM (
  VALUES
    ('العناية بالجروح وتغيير الغيار', 'Wound Care & Dressing', 'تنظيف وتعقيم الجروح بعد العمليات وتغيير الغيارات الطبية المعقمة', 'Sterile post-surgical wound cleaning, disinfection, and dressing changes', '🩹', 120.00, 45),
    ('إعطاء الحقن والمحاليل الوريدية', 'Injections & IV Therapy', 'إعطاء الحقن العضلية والوريدية وتركيب المحاليل بإشراف وتمريض مؤهل', 'Administration of IM/IV injections and IV fluids setup by certified nurses', '💉', 90.00, 30),
    ('رعاية كبار السن المنزلية', 'Elderly Home Care', 'رعاية تمريضية متكاملة ومتابعة العلامات الحيوية والنظافة الشخصية للمسنين', 'Comprehensive nursing care, vital signs monitoring, and support for the elderly', '🩺', 250.00, 120),
    ('رعاية ما بعد العمليات الجراحية', 'Post-Operative Care', 'متابعة ما بعد الجراحة وإدارة الألم والوقاية من المضاعفات ومراقبة الأجهزة', 'Post-surgical monitoring, pain management, and complication prevention', '🏥', 200.00, 90),
    ('رعاية الأم وحديثي الولادة', 'Mother & Newborn Care', 'العناية بالطفل حديث الولادة ومتابعة صحة الأم بعد الولادة الطبيعية أو القيصرية', 'Newborn nursing, maternal post-natal care, and infant health checks', '👶', 180.00, 60),
    ('جلسات العلاج الطبيعي والتأهيل', 'Physiotherapy & Rehabilitation', 'جلسات علاج طبيعي منزلية وتأهيل حركي بعد الإصابات والجلطات والعمليات', 'In-home physiotherapy sessions and physical rehabilitation', '🏃', 300.00, 60)
) AS s(name_ar, name_en, description_ar, description_en, icon, base_price, duration_minutes)
WHERE NOT EXISTS (
  SELECT 1 FROM public.services WHERE public.services.name_ar = s.name_ar
);

-- ------------------------------------------------------------
-- الخطوة 4: تنظيف وإصلاح التريجرات الحمائية
-- ------------------------------------------------------------

-- إزالة أي تريجر حجوزات رُبط بالخطأ بجدول profiles أو nurse_profiles
DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.profiles;
DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.nurse_profiles;
DROP TRIGGER IF EXISTS protect_booking_updates_trigger ON public.profiles;

-- 1. حماية دور وحساب المستخدم في profiles
CREATE OR REPLACE FUNCTION public.protect_profile_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'لا يمكن تعديل المعرف الأساسي للملف الشخصي';
  END IF;

  IF (NEW.role IS DISTINCT FROM OLD.role) THEN
    IF NOT public.is_admin() THEN
      NEW.role := OLD.role;
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_profile_role ON public.profiles;
CREATE TRIGGER trg_protect_profile_role
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_profile_role();

-- 2. حماية بيانات اعتماد الممرضين في nurse_profiles (C3 & M1)
CREATE OR REPLACE FUNCTION public.protect_nurse_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    -- لا يمكن لغير المدير تعديل حالة الاعتماد أو سبب الرفض
    NEW.verified := OLD.verified;
    NEW.verification_status := OLD.verification_status;
    NEW.rejection_reason := OLD.rejection_reason;
    NEW.reviewed_by := OLD.reviewed_by;
    NEW.reviewed_at := OLD.reviewed_at;

    -- الممرض غير المعتمد لا يمكنه تفعيل استقبال الزيارات
    IF OLD.verified IS NOT TRUE AND OLD.verification_status <> 'approved' THEN
      NEW.is_active := false;
      NEW.accepting_bookings := false;
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_nurse_status ON public.nurse_profiles;
CREATE TRIGGER trg_protect_nurse_status
  BEFORE UPDATE ON public.nurse_profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_nurse_status();

-- 3. حماية دورة حياة وانتقالات الحجوزات في bookings (C5 & M2)
CREATE OR REPLACE FUNCTION public.protect_booking_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- إذا لم تتغير الحالة، يُسمح بالتحديث
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- الأدمن يملك صلاحية كاملة
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- دورة حياة الحجز المسموحة:
  -- pending -> accepted | rejected | cancelled
  IF OLD.status = 'pending' AND NEW.status IN ('accepted', 'rejected', 'cancelled') THEN
    RETURN NEW;
  -- accepted -> in_progress | cancelled
  ELSIF OLD.status = 'accepted' AND NEW.status IN ('in_progress', 'cancelled') THEN
    RETURN NEW;
  -- in_progress -> completed
  ELSIF OLD.status = 'in_progress' AND NEW.status = 'completed' THEN
    RETURN NEW;
  ELSE
    RAISE EXCEPTION 'انتقال حالة الحجز غير مسموح';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.bookings;
CREATE TRIGGER trg_protect_booking_updates
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.protect_booking_updates();

-- 4. حماية مراجعة واعتماد مستندات الممرضين (H5)
CREATE OR REPLACE FUNCTION public.protect_nurse_documents()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    -- الممرض لا يستطيع اعتماد مستنداته بنفسه
    NEW.review_status := OLD.review_status;
    NEW.rejection_reason := OLD.rejection_reason;
    -- عند إعادة رفع المستند يُعاد تلقائياً لحالة الانتظار
    IF NEW.storage_path IS DISTINCT FROM OLD.storage_path THEN
      NEW.review_status := 'pending';
      NEW.rejection_reason := NULL;
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_nurse_documents ON public.nurse_documents;
CREATE TRIGGER trg_protect_nurse_documents
  BEFORE UPDATE ON public.nurse_documents
  FOR EACH ROW EXECUTE FUNCTION public.protect_nurse_documents();

-- 5. التحقق من اكتمال الزيارة وصلاحية التقييم (M3)
CREATE OR REPLACE FUNCTION public.check_review_booking_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_patient uuid;
BEGIN
  SELECT status, patient_id INTO v_status, v_patient FROM public.bookings WHERE id = NEW.booking_id;
  IF v_status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'لا يمكن تقييم الزيارة إلا بعد اكتمالها بنجاح';
  END IF;
  IF v_patient IS DISTINCT FROM auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'لا يحق إلا لصاحب الحجز كتابة التقييم';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_review_booking_completed ON public.reviews;
CREATE TRIGGER trg_check_review_booking_completed
  BEFORE INSERT ON public.reviews
  FOR EACH ROW EXECUTE FUNCTION public.check_review_booking_completed();

-- ------------------------------------------------------------
-- الخطوة 5: سياسات الأمان على مستوى الصفوف (Row Level Security - RLS)
-- ------------------------------------------------------------

-- 1. جدول profiles (H2: حماية بيانات المستخدمين ومنع التسريب العام)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
DROP POLICY IF EXISTS "Profiles select policy" ON public.profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
DROP POLICY IF EXISTS "Admins can manage all profiles" ON public.profiles;

CREATE POLICY "Profiles select policy"
  ON public.profiles FOR SELECT
  USING (
    -- أ) المستخدم يرى ملفه الشخصي كاملاً
    auth.uid() = id
    -- ب) مدير النظام يرى جميع الحسابات
    OR public.is_admin()
    -- ج) طرفا الزيارة المشتركة فقط بعد تأكيد/قبول الحجز (H2 & H3)
    OR EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE (
        (b.patient_id = auth.uid() AND (b.nurse_id = public.profiles.id OR b.nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = public.profiles.id)))
        OR
        ((b.nurse_id = auth.uid() OR b.nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())) AND b.patient_id = public.profiles.id)
      )
      AND b.status IN ('accepted', 'in_progress', 'completed')
    )
  );

CREATE POLICY "Users can update their own profile"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Admins can manage all profiles"
  ON public.profiles FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 2. جدول nurse_profiles (C3 & M1)
ALTER TABLE public.nurse_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Nurse profiles select policy" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Nurse profiles are viewable by everyone" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Nurses can update own profile" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Admins can manage all nurse profiles" ON public.nurse_profiles;

CREATE POLICY "Nurse profiles select policy"
  ON public.nurse_profiles FOR SELECT
  USING (
    public.is_admin()
    OR auth.uid() = user_id
    OR (verified = true AND is_active = true)
    OR EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE (b.nurse_id = public.nurse_profiles.id OR b.nurse_id = public.nurse_profiles.user_id)
        AND b.patient_id = auth.uid()
    )
  );

CREATE POLICY "Nurses can update own profile"
  ON public.nurse_profiles FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Nurses can insert own profile"
  ON public.nurse_profiles FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can manage all nurse profiles"
  ON public.nurse_profiles FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 3. جدول services (M12)
ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Services are viewable by everyone" ON public.services;
DROP POLICY IF EXISTS "Admins can manage services" ON public.services;

CREATE POLICY "Services are viewable by everyone"
  ON public.services FOR SELECT
  USING (is_active = true OR public.is_admin());

CREATE POLICY "Admins can manage services"
  ON public.services FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 4. جدول bookings (C5 & M2)
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own bookings" ON public.bookings;
DROP POLICY IF EXISTS "Users can view their related bookings" ON public.bookings;
DROP POLICY IF EXISTS "Authenticated patients can insert bookings" ON public.bookings;
DROP POLICY IF EXISTS "Patients can cancel own bookings" ON public.bookings;
DROP POLICY IF EXISTS "Patients can cancel own pending bookings" ON public.bookings;
DROP POLICY IF EXISTS "Nurses can update assigned bookings" ON public.bookings;
DROP POLICY IF EXISTS "Admins manage all bookings" ON public.bookings;

CREATE POLICY "Users can view their own bookings"
  ON public.bookings FOR SELECT
  USING (
    auth.uid() = patient_id 
    OR auth.uid() = nurse_id
    OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "Authenticated patients can insert bookings"
  ON public.bookings FOR INSERT
  WITH CHECK (auth.uid() = patient_id);

-- السماح للمريض بإلغاء الحجز المعلق أو المقبول قبل بدئه (M2)
CREATE POLICY "Patients can cancel own bookings"
  ON public.bookings FOR UPDATE
  USING (auth.uid() = patient_id AND status IN ('pending', 'accepted'))
  WITH CHECK (auth.uid() = patient_id AND status = 'cancelled');

-- السماح للممرض بتحديث وإدارة الحجوزات المسندة إليه
CREATE POLICY "Nurses can update assigned bookings"
  ON public.bookings FOR UPDATE
  USING (
    auth.uid() = nurse_id
    OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())
    OR public.is_admin()
  )
  WITH CHECK (
    auth.uid() = nurse_id
    OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "Admins manage all bookings"
  ON public.bookings FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5. جدول reviews (M3)
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Reviews are viewable by everyone" ON public.reviews;
DROP POLICY IF EXISTS "Patients can insert reviews" ON public.reviews;
DROP POLICY IF EXISTS "Admins manage reviews" ON public.reviews;

CREATE POLICY "Reviews are viewable by everyone"
  ON public.reviews FOR SELECT
  USING (true);

CREATE POLICY "Patients can insert reviews"
  ON public.reviews FOR INSERT
  WITH CHECK (auth.uid() = patient_id);

CREATE POLICY "Admins manage reviews"
  ON public.reviews FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 6. جدول nurse_documents (H5)
ALTER TABLE public.nurse_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage all nurse documents" ON public.nurse_documents;
DROP POLICY IF EXISTS "Nurses view own documents" ON public.nurse_documents;
DROP POLICY IF EXISTS "Nurses insert own documents" ON public.nurse_documents;
DROP POLICY IF EXISTS "Nurses update own documents" ON public.nurse_documents;

CREATE POLICY "Admins manage all nurse documents"
  ON public.nurse_documents FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "Nurses view own documents"
  ON public.nurse_documents FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
  );

CREATE POLICY "Nurses insert own documents"
  ON public.nurse_documents FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
  );

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
  );

-- 7. جدول user_national_ids (C4 & H4: مشفر وخاص بالخادم)
ALTER TABLE public.user_national_ids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "national_ids_no_public_read" ON public.user_national_ids;
DROP POLICY IF EXISTS "national_ids_service_only" ON public.user_national_ids;

-- منع القراءة المباشرة من المتصفح (الوصول محصور بـ Edge Functions ذات المفتاح الخادمي)
CREATE POLICY "national_ids_service_only"
  ON public.user_national_ids FOR ALL
  USING (false);

-- ------------------------------------------------------------
-- الخطوة 6: الـ View العامة للممرضين المعتمدين (public_nurses)
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
  WHERE np.verified = true AND np.is_active = true;

-- ------------------------------------------------------------
-- الخطوة 7: أوعية التخزين وسياسات الأمان (Storage Buckets & Policies)
-- ------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-photos', 'profile-photos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

INSERT INTO storage.buckets (id, name, public)
VALUES ('private-docs', 'private-docs', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- سياسات الصور الشخصية (profile-photos)
DROP POLICY IF EXISTS "Public can view profile photos" ON storage.objects;
CREATE POLICY "Public can view profile photos"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'profile-photos');

DROP POLICY IF EXISTS "Users can upload their own profile photo" ON storage.objects;
CREATE POLICY "Users can upload their own profile photo"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Users can manage own profile photo" ON storage.objects;
CREATE POLICY "Users can manage own profile photo"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'profile-photos'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Users can delete own profile photo" ON storage.objects;
CREATE POLICY "Users can delete own profile photo"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'profile-photos'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- سياسات مستندات الممرضين الخاصة (private-docs)
DROP POLICY IF EXISTS "Nurses can upload private docs" ON storage.objects;
CREATE POLICY "Nurses can upload private docs"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'private-docs'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Nurses and admins read private docs" ON storage.objects;
CREATE POLICY "Nurses and admins read private docs"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'private-docs'
    AND auth.role() = 'authenticated'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR public.is_admin()
    )
  );

DROP POLICY IF EXISTS "Nurses and admins delete private docs" ON storage.objects;
CREATE POLICY "Nurses and admins delete private docs"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'private-docs'
    AND auth.role() = 'authenticated'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR public.is_admin()
    )
  );

-- ============================================================
-- نهاية ملف الـ Migration الشامل - تم بنجاح
-- ============================================================

