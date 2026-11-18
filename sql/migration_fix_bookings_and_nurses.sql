-- ============================================================
-- منصة رعايه | CareNest
-- سكريبت إصلاح جدول الحجوزات وربط الممرضين (Booking & Nurses Fix)
-- ============================================================
-- INSTRUCTIONS FOR USER / تعليمات التنفيذ:
-- 1. افتح لوحة تحكم Supabase لمشروعك:
--    https://supabase.com/dashboard/project/tfolrgauojmbeofartaq/sql
-- 2. انسخ هذا الكود بالكامل والصقه في SQL Editor ثم اضغط Run.
-- 3. هذا السكريبت آمن 100% ولا يحذف أي بيانات سابقة.
-- ============================================================

-- 1. إضافة كافة الأعمدة المفقودة لجدول الحجوزات bookings
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS service_id uuid REFERENCES public.services(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS service_name text,
  ADD COLUMN IF NOT EXISTS service_type text,
  ADD COLUMN IF NOT EXISTS visit_time time,
  ADD COLUMN IF NOT EXISTS duration_hours numeric(4,2) DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS total_price numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'EGP',
  ADD COLUMN IF NOT EXISTS patient_name text,
  ADD COLUMN IF NOT EXISTS patient_phone text,
  ADD COLUMN IF NOT EXISTS country text DEFAULT 'Egypt',
  ADD COLUMN IF NOT EXISTS governorate text DEFAULT 'القاهرة',
  ADD COLUMN IF NOT EXISTS city text DEFAULT 'القاهرة',
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS patient_notes text;

-- 2. إصلاح القيد المرجعي لـ nurse_id
-- القيد القديم كان يربط nurse_id بـ nurse_profiles(id) مما يسبب تعارضاً مع حساب الممرض profiles(id)
ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_nurse_id_fkey;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_nurse_id_fkey 
  FOREIGN KEY (nurse_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

-- 3. دالة معالجة ومزامنة بيانات الحجز قبل الإدراج أو التحديث
CREATE OR REPLACE FUNCTION public.validate_and_sync_booking()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_nurse_user_id uuid;
  v_nurse_active boolean := true;
  v_nurse_verified boolean := true;
  v_service_record record;
BEGIN
  -- أ) مزامنة اسم ومعرف الخدمة
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

  -- ب) التحقق من وجود ونشاط الممرض وقبول المعرف سواء كان profiles.id أو nurse_profiles.id
  SELECT user_id, is_active, verified
  INTO v_nurse_user_id, v_nurse_active, v_nurse_verified
  FROM public.nurse_profiles
  WHERE user_id = NEW.nurse_id OR id = NEW.nurse_id
  LIMIT 1;

  IF FOUND THEN
    NEW.nurse_id := v_nurse_user_id; -- توحيد المعرف دائماً إلى user_id
    IF v_nurse_active = false OR v_nurse_verified = false THEN
      RAISE EXCEPTION 'الممرض غير متاح حالياً لاستقبال الحجوزات';
    END IF;
  ELSE
    -- فحص ما إذا كان المستخدم موجوداً في profiles بدور ممرض
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = NEW.nurse_id AND role = 'nurse') THEN
      RAISE EXCEPTION 'الممرض غير متاح حالياً';
    END IF;
  END IF;

  -- ج) مزامنة المبالغ والأوقات والملاحظات
  NEW.total_price   := COALESCE(NEW.total_price, NEW.price, 0.00);
  NEW.price         := COALESCE(NEW.price, NEW.total_price, 0.00);
  NEW.visit_time    := COALESCE(NEW.visit_time, NEW.start_time, '10:00:00'::time);
  NEW.start_time    := COALESCE(NEW.start_time, NEW.visit_time, '10:00:00'::time);
  NEW.notes         := COALESCE(NEW.notes, NEW.patient_notes);
  NEW.patient_notes := COALESCE(NEW.patient_notes, NEW.notes);
  NEW.currency      := COALESCE(NEW.currency, 'EGP');
  NEW.country       := COALESCE(NEW.country, 'Egypt');
  NEW.status        := COALESCE(NEW.status, 'pending');

  RETURN NEW;
END;
$$;

-- ربط التريجر بجدول bookings
DROP TRIGGER IF EXISTS trg_validate_and_sync_booking ON public.bookings;
CREATE TRIGGER trg_validate_and_sync_booking
  BEFORE INSERT OR UPDATE ON public.bookings
  FOR EACH ROW EXECUTE PROCEDURE public.validate_and_sync_booking();

-- 4. تحديث الـ View العامة public_nurses لتضمن فقط الممرضين المعتمدين والنشطين
CREATE OR REPLACE VIEW public.public_nurses AS
  SELECT
    np.id,
    np.user_id,
    p.full_name,
    p.avatar_url,
    np.specialization,
    np.qualifications,
    np.experience_years,
    np.visit_price,
    np.bio,
    COALESCE(np.governorate, p.governorate, 'القاهرة') as governorate,
    COALESCE(np.city, p.city, 'القاهرة') as city,
    np.languages,
    np.verified,
    np.is_active,
    np.verification_status,
    np.created_at,
    COALESCE(avg_r.avg_rating, 0.0) as avg_rating,
    COALESCE(avg_r.review_count, 0) as review_count
  FROM public.nurse_profiles np
  JOIN public.profiles p ON p.id = np.user_id
  LEFT JOIN (
    SELECT
      nurse_id,
      ROUND(AVG(rating)::numeric, 1) as avg_rating,
      COUNT(*) as review_count
    FROM public.reviews
    GROUP BY nurse_id
  ) avg_r ON avg_r.nurse_id = np.user_id
  WHERE
    np.verified = true
    AND np.is_active = true
    AND (np.verification_status = 'approved' OR np.verification_status IS NULL);

-- 5. تحديث سياسات الحجز في RLS
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated patients can insert bookings" ON public.bookings;
CREATE POLICY "Authenticated patients can insert bookings"
  ON public.bookings FOR INSERT
  WITH CHECK (auth.uid() = patient_id AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "Users can view their own bookings" ON public.bookings;
CREATE POLICY "Users can view their own bookings"
  ON public.bookings FOR SELECT
  USING (
    auth.uid() = patient_id 
    OR auth.uid() = nurse_id
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS "Nurses can update assigned bookings" ON public.bookings;
CREATE POLICY "Nurses can update assigned bookings"
  ON public.bookings FOR UPDATE
  USING (
    auth.uid() = nurse_id
    OR (auth.uid() = patient_id AND status = 'pending')
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );
