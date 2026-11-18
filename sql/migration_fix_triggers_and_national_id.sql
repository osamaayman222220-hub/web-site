-- ============================================================
-- منصة رعايه | CareNest - مراجعة وتدقيق تريجرات الأمان والحجوزات
-- ملف الترحيل: migration_fix_triggers_and_national_id.sql
-- ============================================================
-- تنبيه مهم للمطور / المشرف:
-- 1. لا تقم بتشغيل هذا الملف إلا إذا كانت قاعدة البيانات تحتوي بالفعل على
--    تريجرات قديمة متداخلة تطلق الخطأ أثناء التحديث.
-- 2. هذا السكريبت غير مدمّر (Non-destructive) ويحافظ على سلامة البيانات وسياسات RLS.
-- ============================================================

-- ------------------------------------------------------------
-- الخطوة 1: التأكد من دالة التحقق من صلاحية المدير (Admin Helper)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- ------------------------------------------------------------
-- الخطوة 2: إزالة أي تريجرات للحجوزات رُبطت بالخطأ بجداول أخرى
-- ------------------------------------------------------------
-- التأكد من عدم وجود تريجر الحجوزات على جدول profiles أو nurse_profiles
DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.profiles;
DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.nurse_profiles;

-- ------------------------------------------------------------
-- الخطوة 3: حماية جدول الملفات الشخصية (profiles)
-- ------------------------------------------------------------
-- الدالة guard_profiles تحمي فقط الحقول السيادية للحساب:
-- - تمنع تعديل id أو email
-- - تمنع المستخدم العادي من ترقية دور حسابه إلى admin
-- - لا تلمس جدول bookings ولا تعترض تحديث الاسم، الهاتف، العنوان، أو المحافظة.
CREATE OR REPLACE FUNCTION public.guard_profiles()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- تثبيت المعرف والبريد الإلكتروني
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    NEW.id := OLD.id;
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    NEW.email := OLD.email;
  END IF;

  -- منع المستخدم العادي من تصعيد الصلاحيات
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    IF NOT public.is_admin() THEN
      NEW.role := OLD.role;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_profiles ON public.profiles;
CREATE TRIGGER trg_guard_profiles
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profiles();

-- ------------------------------------------------------------
-- الخطوة 4: حماية بيانات اعتماد الممرضين (nurse_profiles)
-- ------------------------------------------------------------
-- الدالة protect_nurse_status تمنع الممرض من اعتماد نفسه (verified = true)
-- دون موافقة الإدارة، وتسمح له بتحديث البيانات المهنية (السعر، التخصص، الخبرة، الموقع)
CREATE OR REPLACE FUNCTION public.protect_nurse_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- منع تغيير حالة الاعتماد لغير الأدمن
  IF (NEW.verified IS DISTINCT FROM OLD.verified) THEN
    IF NOT public.is_admin() THEN
      NEW.verified := OLD.verified;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_nurse_status ON public.nurse_profiles;
CREATE TRIGGER trg_protect_nurse_status
  BEFORE UPDATE ON public.nurse_profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_nurse_status();

-- ------------------------------------------------------------
-- الخطوة 5: حماية انتقالات حالات الحجز (bookings)
-- ------------------------------------------------------------
-- الدالة protect_booking_updates تطابق دورة الحياة الفعلية للحجز في CareNest:
-- 1. إذا لم تتغير الحالة (status)، يُسمح بالتحديث مباشرة دون قيود.
-- 2. للأدمن: صلاحية كاملة لإدارة الحالات.
-- 3. للمريض والممرض:
--    - pending     -> accepted (قبول من الممرض) | rejected (رفض من الممرض) | cancelled (إلغاء من المريض)
--    - accepted    -> in_progress (بدء الزيارة من الممرض) | cancelled (إلغاء)
--    - in_progress -> completed (إكمال الزيارة من الممرض)
-- 4. أي انتقال غير ذلك يُرفض ويصدر الخطأ: 'انتقال حالة الحجز غير مسموح'.
CREATE OR REPLACE FUNCTION public.protect_booking_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- إذا لم تتغير الحالة، اسمح بتحديث الحقول الأخرى (ملاحظات، وقت، عنوان، إلخ)
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- الأدمن يملك صلاحية تغيير الحالة استثنائياً
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- التحقق من الانتقالات المسموح بها نظامياً
  -- 1. من انتظار (pending): قبول أو رفض من الممرض، أو إلغاء
  IF OLD.status = 'pending' AND NEW.status IN ('accepted', 'rejected', 'cancelled') THEN
    RETURN NEW;
  -- 2. من مقبول (accepted): بدء الزيارة (in_progress) أو في الطريق (on_the_way) أو إلغاء
  ELSIF OLD.status = 'accepted' AND NEW.status IN ('in_progress', 'on_the_way', 'cancelled') THEN
    RETURN NEW;
  -- 3. من في الطريق (on_the_way): بدء الزيارة (in_progress) أو إلغاء
  ELSIF OLD.status = 'on_the_way' AND NEW.status IN ('in_progress', 'cancelled') THEN
    RETURN NEW;
  -- 4. من جارية (in_progress): إكمال الزيارة (completed)
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

-- ------------------------------------------------------------
-- الخطوة 6: سياسات الأمان RLS المحدثة لجدول الحجوزات (bookings)
-- ------------------------------------------------------------
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

-- أ) قراءة الحجوزات: المريض أو الممرض المسند إليه الحجز أو الأدمن
DROP POLICY IF EXISTS "Users can view their own bookings" ON public.bookings;
DROP POLICY IF EXISTS "Users can view their related bookings" ON public.bookings;
CREATE POLICY "Users can view their own bookings"
  ON public.bookings FOR SELECT
  USING (
    auth.uid() = patient_id 
    OR auth.uid() = nurse_id
    OR nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())
    OR public.is_admin()
  );

-- ب) تحديث حالة الحجز: الممرض المسند إليه الحجز أو إلغاء المريض للحجز المعلق أو الأدمن
DROP POLICY IF EXISTS "Nurses can update assigned bookings" ON public.bookings;
DROP POLICY IF EXISTS "Nurses can update their booking status" ON public.bookings;
DROP POLICY IF EXISTS "Patients can cancel own pending bookings" ON public.bookings;
DROP POLICY IF EXISTS "Users can update their bookings" ON public.bookings;

CREATE POLICY "Patients can cancel own pending bookings"
  ON public.bookings FOR UPDATE
  USING (auth.uid() = patient_id AND status = 'pending')
  WITH CHECK (auth.uid() = patient_id AND status = 'cancelled');

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

-- ------------------------------------------------------------
-- الخطوة 7: تحديث سياسة قراءة الملفات الشخصية (profiles)
-- تمكين الممرض من قراءة هاتف وبيانات المريض المسند إليه الحجز
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Profiles select policy" ON public.profiles;
CREATE POLICY "Profiles select policy"
  ON public.profiles FOR SELECT
  USING (
    -- 1. صاحب الحساب نفسه
    auth.uid() = id
    -- 2. المشرف / المدير
    OR public.is_admin()
    -- 3. دليل الممرضين المعتمدين والنشطين للعامة
    OR EXISTS (
      SELECT 1 FROM public.nurse_profiles np
      WHERE np.user_id = public.profiles.id
        AND np.verified = true
        AND np.is_active = true
    )
    -- 4. طرفا الحجز المشترك (المريض والممرض المصرح لهما فقط)
    OR EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE (
        -- مريض الحجز يرى ممرضه
        (b.patient_id = auth.uid() AND (b.nurse_id = public.profiles.id OR b.nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = public.profiles.id)))
        OR
        -- ممرض الحجز يرى مريضه
        ((b.nurse_id = auth.uid() OR b.nurse_id IN (SELECT id FROM public.nurse_profiles WHERE user_id = auth.uid())) AND b.patient_id = public.profiles.id)
      )
    );

-- ------------------------------------------------------------
-- الخطوة 8: إضافة أعمدة الإحداثيات الجغرافية (GPS) وبيانات الزيارة
-- ------------------------------------------------------------
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS latitude double precision,
  ADD COLUMN IF NOT EXISTS longitude double precision,
  ADD COLUMN IF NOT EXISTS duration_hours numeric(4,2) DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS total_price numeric(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS governorate text DEFAULT 'الفيوم',
  ADD COLUMN IF NOT EXISTS city text DEFAULT 'الفيوم';

-- ------------------------------------------------------------
-- الخطوة 9: دعم لوحة تحكم الإدارة (Admin Dashboard) وسياسات RLS
-- ------------------------------------------------------------

-- أ) إضافة أعمدة حالة المراجعة وسبب الرفض لملف الممرض إن لم تكن موجودة
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS verification_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS rejection_reason text;

-- مزامنة الحالات القديمة تلقائياً مع الأعمدة المنطقية (verified و is_active)
UPDATE public.nurse_profiles
SET verification_status = CASE
  WHEN verified = true AND is_active = true THEN 'approved'
  WHEN verified = true AND is_active = false THEN 'suspended'
  ELSE COALESCE(verification_status, 'pending')
END
WHERE verification_status IS NULL OR verification_status = 'pending';

-- ب) تحديث سياسات RLS لجدول nurse_profiles لتمكين الأدمن من قراءة وتعديل جميع الممرضين
DROP POLICY IF EXISTS "Admins can manage all nurse profiles" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Nurse profiles select policy" ON public.nurse_profiles;
DROP POLICY IF EXISTS "Nurse profiles are viewable by everyone" ON public.nurse_profiles;

CREATE POLICY "Nurse profiles select policy"
  ON public.nurse_profiles FOR SELECT
  USING (
    -- 1. الأدمن يرى جميع الملفات
    public.is_admin()
    -- 2. الممرض يرى ملفه الشخصي
    OR auth.uid() = user_id
    -- 3. الممرضون المعتمدون والنشطون متاحون للعامة والبحث
    OR (verified = true AND is_active = true)
    -- 4. طرفا الحجز المشترك
    OR EXISTS (
      SELECT 1 FROM public.bookings b 
      WHERE (b.nurse_id = public.nurse_profiles.id OR b.nurse_id = public.nurse_profiles.user_id) 
        AND b.patient_id = auth.uid()
    )
  );

CREATE POLICY "Admins can manage all nurse profiles"
  ON public.nurse_profiles FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ج) التأكد من سياسة الإدارة الكاملة لجدول الحجوزات (bookings)
DROP POLICY IF EXISTS "Admins manage all bookings" ON public.bookings;
CREATE POLICY "Admins manage all bookings"
  ON public.bookings FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ------------------------------------------------------------
-- الخطوة 10: إنشاء وضبط جدول مستندات الممرضين (nurse_documents) وسياسات RLS
-- ------------------------------------------------------------
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

-- ضمان وجود وتوافق الأعمدة في حال كان الجدول منشأ سابقاً
ALTER TABLE public.nurse_documents
  ADD COLUMN IF NOT EXISTS nurse_id uuid REFERENCES public.nurse_profiles(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS storage_path text,
  ADD COLUMN IF NOT EXISTS review_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS rejection_reason text,
  ADD COLUMN IF NOT EXISTS document_type text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

ALTER TABLE public.nurse_documents ENABLE ROW LEVEL SECURITY;

-- 1. صلاحيات كاملة لمديري النظام لإدارة واعتماد ورفض المستندات
DROP POLICY IF EXISTS "Admins manage all nurse documents" ON public.nurse_documents;
CREATE POLICY "Admins manage all nurse documents"
  ON public.nurse_documents FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 2. الممرض يستعرض مستنداته الخاصة فقط
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

-- 3. الممرض يرفع ويسجل مستنداته الخاصة فقط
DROP POLICY IF EXISTS "Nurses insert own documents" ON public.nurse_documents;
CREATE POLICY "Nurses insert own documents"
  ON public.nurse_documents FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.nurse_profiles np 
      WHERE np.id = public.nurse_documents.nurse_id 
        AND np.user_id = auth.uid()
    )
  );

-- 4. الممرض يحدث مسار المستند الخاص به عند إعادة الرفع
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
  );

-- ------------------------------------------------------------
-- الخطوة 11: التأكد من وجود وعاء التخزين الخاص (private-docs) وسياسات الأمان
-- ------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('private-docs', 'private-docs', false)
ON CONFLICT (id) DO UPDATE SET public = false;

INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-photos', 'profile-photos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- سياسات تخزين مستندات الممرضين الخاصة (private-docs)
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





