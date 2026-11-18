-- ============================================================================
-- CareNest (رعاية) - Production Migration v6: Final Security & Integrity Patch
-- File: sql/migration_v6_final_security_and_reviews.sql
-- Description:
--   1. Secure user role protection (enforce role IN ('patient','nurse') on signup, prevent admin self-escalation)
--   2. Enforce strict match between nurse_id (profiles.id) and nurse_profile_id (nurse_profiles.id)
--   3. Protect booking patient PII and address from modifications by assigned nurses
--   4. Prevent unauthorized tampering with pricing, commission, and payment statuses
--   5. Full review lifecycle integrity: only completed visits, by booking patient, locking nurse_id, unique booking
--   6. Storage bucket 'profile-photos' setup with user-scoped isolation
-- ============================================================================

-- ============================================================================
-- 1. حماية دور ومعرف المستخدم (Profiles Role & Identity Escalation Guard)
-- ============================================================================
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
    -- إذا لم يكن المستدعي مصرحاً (مستخدم عادي يسجل)، يحظر عليه دور admin أو أي دور مخصص
    IF NOT v_is_authorized THEN
      IF NEW.role IS NULL OR NEW.role NOT IN ('patient', 'nurse') THEN
        NEW.role := 'patient';
      END IF;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- 1. حظر تعديل معرف المستخدم id نهائياً
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
END; $$;

DROP TRIGGER IF EXISTS enforce_profile_role_security_trg ON public.profiles;
CREATE TRIGGER enforce_profile_role_security_trg
BEFORE INSERT OR UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_profile_role_security();

-- تحديث دالة تسجيل المستخدم الجديد لضمان تعقيم role ومنع الاعتماد على أي قيمة admin
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

  -- إنشاء الحساب في profiles مع الحفاظ على البيانات الحالية
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
      'none',
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
END; $$;

-- إعادة ربط التريجر على auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================================
-- 2. تطابق وربط هوية الممرض (Bookings Nurse Identity Synchronization)
-- ============================================================================
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
      IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = NEW.nurse_id AND role = 'nurse') THEN
        RAISE EXCEPTION 'الممرض المحدد غير مسجل أو غير متاح في النظام';
      END IF;
    END IF;
  END IF;

  -- ب) منع تعديل هوية الممرض بعد الإنشاء
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.nurse_id IS NOT NULL AND NEW.nurse_id IS DISTINCT FROM OLD.nurse_id) OR
       (OLD.nurse_profile_id IS NOT NULL AND NEW.nurse_profile_id IS DISTINCT FROM OLD.nurse_profile_id) THEN
      IF NOT (
        public.is_admin() 
        OR (auth.role() = 'service_role')
        OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)
      ) THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل الممرض المسند إليه الحجز بعد الإنشاء إلا بواسطة الإدارة';
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

  -- هـ) التحقق الصارم من بيانات المريض الإلزامية عند الإنشاء
  IF TG_OP = 'INSERT' THEN
    IF NEW.patient_name IS NULL OR TRIM(NEW.patient_name) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: اسم المريض مطلوب لإتمام الحجز';
    END IF;
    IF NEW.patient_phone IS NULL OR TRIM(NEW.patient_phone) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: رقم هاتف التواصل مطلوب لإتمام الحجز';
    END IF;
    IF NEW.patient_address IS NULL OR TRIM(NEW.patient_address) = '' THEN
      RAISE EXCEPTION 'بيانات الحجز غير مكتملة: عنوان زيارة التمريض مطلوب لإتمام الحجز';
    END IF;
  END IF;

  -- و) القيم الافتراضية
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
END; $$;

DROP TRIGGER IF EXISTS sync_booking_nurse_identity_trg ON public.bookings;
CREATE TRIGGER sync_booking_nurse_identity_trg
BEFORE INSERT OR UPDATE ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_booking_nurse_identity();


-- ============================================================================
-- 3. حماية بيانات الحجوزات والبيانات المالية ومنع تعديل بيانات المريض (Immutability)
-- ============================================================================
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
         NEW.service_id IS DISTINCT FROM OLD.service_id OR
         NEW.service_name IS DISTINCT FROM OLD.service_name OR
         NEW.notes IS DISTINCT FROM OLD.notes OR
         NEW.patient_notes IS DISTINCT FROM OLD.patient_notes THEN
        RAISE EXCEPTION 'غير مصرح: لا يحق للممرض تعديل بيانات المريض أو عنوان وموقع وملاحظات الزيارة';
      END IF;
    END IF;

    -- 3. منع تعديل الأسعار والمبالغ والنسب المالية مباشرة من غير الإدارة
    IF NEW.total_price IS DISTINCT FROM OLD.total_price OR
       NEW.price IS DISTINCT FROM OLD.price OR
       NEW.deposit_amount IS DISTINCT FROM OLD.deposit_amount OR
       (NEW.commission_rate IS DISTINCT FROM OLD.commission_rate AND OLD.commission_rate IS NOT NULL) OR
       (NEW.commission_amount IS DISTINCT FROM OLD.commission_amount AND OLD.commission_amount IS NOT NULL) OR
       (NEW.nurse_net_amount IS DISTINCT FROM OLD.nurse_net_amount AND OLD.nurse_net_amount IS NOT NULL) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل أسعار أو عمولات الحجز مباشرة';
    END IF;

    -- 4. منع التلاعب بحالة الدفع ومؤشرات الصرف
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
END; $$;

DROP TRIGGER IF EXISTS protect_booking_immutability_trg ON public.bookings;
CREATE TRIGGER protect_booking_immutability_trg
BEFORE UPDATE ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_booking_immutability();


-- ============================================================================
-- 4. تأمين وحماية التقييمات دورة الحياة والنزاهة (Reviews Integrity & Security)
-- ============================================================================
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

-- قيد منع التقييم المكرر لنفس الحجز
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'reviews_booking_id_key'
      AND table_schema = 'public'
      AND table_name = 'reviews'
  ) THEN
    ALTER TABLE public.reviews ADD CONSTRAINT reviews_booking_id_key UNIQUE (booking_id);
  END IF;
END; $$;

-- فهارس التقييمات لتحسين الأداء
CREATE INDEX IF NOT EXISTS idx_reviews_nurse_id ON public.reviews (nurse_id);
CREATE INDEX IF NOT EXISTS idx_reviews_booking_id ON public.reviews (booking_id);

-- سياسات RLS للتقييمات
DROP POLICY IF EXISTS "Reviews are viewable by everyone" ON public.reviews;
CREATE POLICY "Reviews are viewable by everyone"
  ON public.reviews FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Patients can insert reviews" ON public.reviews;
CREATE POLICY "Patients can insert reviews"
  ON public.reviews FOR INSERT
  WITH CHECK (
    auth.uid() = patient_id 
    AND auth.role() = 'authenticated'
  );

DROP POLICY IF EXISTS "Admins can manage all reviews" ON public.reviews;
CREATE POLICY "Admins can manage all reviews"
  ON public.reviews FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

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
END; $$;

DROP TRIGGER IF EXISTS trg_validate_review_before_insert ON public.reviews;
CREATE TRIGGER trg_validate_review_before_insert
BEFORE INSERT ON public.reviews
FOR EACH ROW
EXECUTE FUNCTION public.trg_validate_review_integrity();


-- ============================================================================
-- 5. إعداد حاوية الصور الشخصية (Storage: profile-photos)
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'profile-photos', 
  'profile-photos', 
  true, 
  2097152, -- 2MB max
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET 
  public = true,
  file_size_limit = 2097152,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

-- سياسات تخزين الصور الشخصية
DROP POLICY IF EXISTS "Public can view profile photos" ON storage.objects;
CREATE POLICY "Public can view profile photos"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'profile-photos');

DROP POLICY IF EXISTS "Users can upload their own profile photo" ON storage.objects;
CREATE POLICY "Users can upload their own profile photo"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "Users can update their own profile photo" ON storage.objects;
CREATE POLICY "Users can update their own profile photo"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'profile-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  )
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "Users can delete their own profile photo" ON storage.objects;
CREATE POLICY "Users can delete their own profile photo"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'profile-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- ضبط ملاك الدوال لحساب postgres
ALTER FUNCTION public.trg_enforce_profile_role_security() OWNER TO postgres;
ALTER FUNCTION public.trg_sync_booking_nurse_identity() OWNER TO postgres;
ALTER FUNCTION public.trg_protect_booking_immutability() OWNER TO postgres;
ALTER FUNCTION public.trg_validate_review_integrity() OWNER TO postgres;

