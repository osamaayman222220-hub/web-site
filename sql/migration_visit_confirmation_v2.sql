-- ============================================================
-- CareNest - Visit Confirmation System (Version 2 - Secure Architecture)
-- File: migration_visit_confirmation_v2.sql
-- 
-- المميزات الأمنية الأساسية:
-- 1. لا وجود لعمود code_plain نهائياً في أي جدول.
-- 2. تخزين code_hash (SHA-256) مع Salt عشوائي فريد لكل كود لمنع Rainbow Tables.
-- 3. تخزين encrypted_code (مشفر بـ AES عبر pgcrypto) لعرضه للمريض المصرح له فقط.
-- 4. التحقق والترقية وإنشاء كود النهاية في عملية ذرية واحدة (Atomic Transaction).
-- 5. إغلاق الكود بعد 5 محاولات فاشلة (Locking) وصلاحية 12 ساعة من موعد الزيارة.
-- 6. حظر الممرض تماماً من قراءة الأكواد عبر RLS ودوال مقيدة.
-- ============================================================

-- تفعيل ملحق التشفير pgcrypto
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------
-- 1. جدول visit_codes المحدّث بدون code_plain
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.visit_codes (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id     uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  code_type      text        NOT NULL CHECK (code_type IN ('start', 'end')),
  code_hash      text        NOT NULL,           -- SHA-256(code || salt)
  salt           text        NOT NULL,           -- قيمة عشوائية 16 بايت مشفرة hex
  encrypted_code text        NOT NULL,           -- الكود مشفر عبر pgp_sym_encrypt للمريض فقط
  is_used        boolean     NOT NULL DEFAULT false,
  used_at        timestamptz,
  expires_at     timestamptz NOT NULL,           -- موعد الزيارة المحدد + 12 ساعة
  attempts       int         NOT NULL DEFAULT 0,
  is_locked      boolean     NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now(),

  UNIQUE (booking_id, code_type)
);

COMMENT ON TABLE public.visit_codes IS 'أكواد تأكيد الزيارات مشفرة وبدون نصوص صريحة';
COMMENT ON COLUMN public.visit_codes.code_hash IS 'تجزئة SHA-256 آمنة مع salt';
COMMENT ON COLUMN public.visit_codes.encrypted_code IS 'كود مشفر للمريض فقط لا يظهر للممرض';

-- ------------------------------------------------------------
-- 2. جدول absence_reports لبلاغات عدم الحضور
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.absence_reports (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id    uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  patient_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nurse_id      uuid        NOT NULL,
  report_time   timestamptz NOT NULL DEFAULT now(),
  patient_note  text,
  admin_action  text        CHECK (admin_action IN ('dismissed', 'warning', 'suspended', 'refunded')),
  admin_note    text,
  reviewed_by   uuid        REFERENCES public.profiles(id),
  reviewed_at   timestamptz,
  status        text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'resolved')),

  UNIQUE (booking_id)
);

-- ------------------------------------------------------------
-- 3. تفعيل RLS وسياسات الوصول الصارمة
-- ------------------------------------------------------------
ALTER TABLE public.visit_codes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.absence_reports ENABLE ROW LEVEL SECURITY;

-- حذف أي سياسات قديمة
DROP POLICY IF EXISTS "no_direct_read_visit_codes" ON public.visit_codes;
DROP POLICY IF EXISTS "patient_read_own_visit_codes" ON public.visit_codes;
DROP POLICY IF EXISTS "admin_read_all_visit_codes" ON public.visit_codes;
DROP POLICY IF EXISTS "patient_insert_absence_report" ON public.absence_reports;
DROP POLICY IF EXISTS "patient_read_own_absence_reports" ON public.absence_reports;
DROP POLICY IF EXISTS "admin_manage_absence_reports" ON public.absence_reports;

-- المبدأ الأمني: لا يُسمح بالقراءة المباشرة من جدول visit_codes للمستخدمين العاديين
-- القراءة تتم حصراً عبر الدالة الآمنة get_patient_visit_code للمريض فقط
CREATE POLICY "admin_read_all_visit_codes" ON public.visit_codes
  FOR SELECT USING (public.is_admin());

-- سياسات بلاغات عدم الحضور
CREATE POLICY "patient_insert_absence_report" ON public.absence_reports
  FOR INSERT WITH CHECK (
    patient_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = absence_reports.booking_id AND b.patient_id = auth.uid()
    )
  );

CREATE POLICY "patient_read_own_absence_reports" ON public.absence_reports
  FOR SELECT USING (patient_id = auth.uid());

CREATE POLICY "admin_manage_absence_reports" ON public.absence_reports
  FOR ALL USING (public.is_admin());

-- ------------------------------------------------------------
-- 4. مفتاح تشفير الأكواد الداخلي (Server Secret)
-- يتم تخزينه في إعداد مخصص أو استخدام معرف سري ثابت
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._get_internal_code_key()
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  -- مفتاح تشفير متناظر داخلي لحماية الأكواد عند التخزين
  SELECT 'CareNest_SecKey_2026_VisitVerificationSalt!#99';
$$;

-- ------------------------------------------------------------
-- 5. دالة ذرية لتوليد كود تأكيد وتخزين الـ Hash الخاص به
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._generate_and_store_code(
  p_booking_id uuid,
  p_code_type text,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_raw_int       bigint;
  v_code          text;
  v_salt          text;
  v_hash          text;
  v_enc           text;
  v_enc_key       text;
BEGIN
  -- 1. توليد كود قوي عشوائياً (6 أرقام) باستخدام بذور معماة cryptographically secure
  v_raw_int := (abs(get_byte(gen_random_bytes(4), 0) * 16777216 +
                     get_byte(gen_random_bytes(4), 1) * 65536 +
                     get_byte(gen_random_bytes(4), 2) * 256 +
                     get_byte(gen_random_bytes(4), 3)) % 900000) + 100000;
  v_code := v_raw_int::text;

  -- 2. توليد Salt عشوائي فريد (16 بايت)
  v_salt := encode(gen_random_bytes(16), 'hex');

  -- 3. حساب تجزئة SHA-256 الآمنة
  v_hash := encode(digest(v_code || v_salt, 'sha256'), 'hex');

  -- 4. تشفير الكود ليتمكن المريض المصرح له فقط من فكه
  v_enc_key := public._get_internal_code_key();
  v_enc := encode(pgp_sym_encrypt(v_code, v_enc_key), 'base64');

  -- 5. الإدراج في جدول visit_codes (بدون أي عمود نصي صريح)
  INSERT INTO public.visit_codes (
    booking_id,
    code_type,
    code_hash,
    salt,
    encrypted_code,
    expires_at
  ) VALUES (
    p_booking_id,
    p_code_type,
    v_hash,
    v_salt,
    v_enc,
    p_expires_at
  )
  ON CONFLICT (booking_id, code_type) DO UPDATE
    SET code_hash      = EXCLUDED.code_hash,
        salt           = EXCLUDED.salt,
        encrypted_code = EXCLUDED.encrypted_code,
        expires_at     = EXCLUDED.expires_at,
        is_used        = false,
        used_at        = null,
        attempts       = 0,
        is_locked      = false;
END;
$$;

-- ------------------------------------------------------------
-- 6. دالة جلب الكود للمريض حصراً (قراءة آمنة وفك تشفير)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_patient_visit_code(
  p_booking_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_booking    public.bookings%ROWTYPE;
  v_code_rec   public.visit_codes%ROWTYPE;
  v_target_type text;
  v_plain_code  text;
  v_enc_key     text;
BEGIN
  -- 1. التأكد من هوية المستدعي وأنه المريض صاحب الحجز
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'الحجز غير موجود.';
  END IF;

  IF v_booking.patient_id <> auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'غير مصرح: لا يمكنك الاطلاع إلا على أكواد حجوزاتك الخاصة.';
  END IF;

  -- 2. تحديد نوع الكود المطلوب حسب مرحلة الزيارة
  IF v_booking.status = 'accepted' THEN
    v_target_type := 'start';
  ELSIF v_booking.status = 'in_progress' THEN
    v_target_type := 'end';
  ELSE
    RETURN json_build_object('available', false, 'reason', 'لا توجد أكواد نشطة لهذه الحالة.');
  END IF;

  -- 3. جلب سجل الكود المشفر
  SELECT * INTO v_code_rec FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = v_target_type;

  IF NOT FOUND THEN
    RETURN json_build_object('available', false, 'reason', 'الكود غير متوفر حالياً.');
  END IF;

  IF v_code_rec.is_locked THEN
    RETURN json_build_object('available', false, 'is_locked', true, 'reason', 'تم قفل الكود لكثرة المحاولات الخاطئة.');
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('available', false, 'is_used', true, 'reason', 'تم استخدام هذا الكود مسبقاً.');
  END IF;

  IF now() > v_code_rec.expires_at THEN
    RETURN json_build_object('available', false, 'expired', true, 'reason', 'انتهت صلاحية الكود.');
  END IF;

  -- 4. فك تشفير الكود للمريض فقط
  v_enc_key := public._get_internal_code_key();
  v_plain_code := pgp_sym_decrypt(decode(v_code_rec.encrypted_code, 'base64'), v_enc_key);

  RETURN json_build_object(
    'available',  true,
    'code_type',  v_target_type,
    'code',       v_plain_code,
    'expires_at', v_code_rec.expires_at
  );
END;
$$;

-- ------------------------------------------------------------
-- 7. الدالة الذرية الرئيسية للتحقق وترقية الحجز (Atomic Transaction)
-- تُنفذ في عملية واحدة: التحقق، القفل، التحديث، وإنشاء كود النهاية
-- إذا فشلت أي خطوة تتراجع العملية بالكامل (Rollback)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_visit_code_atomic(
  p_booking_id      uuid,
  p_entered_code    text,
  p_code_type       text,
  p_nurse_user_id   uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_booking         public.bookings%ROWTYPE;
  v_nurse_profile   public.nurse_profiles%ROWTYPE;
  v_code_rec        public.visit_codes%ROWTYPE;
  v_computed_hash   text;
  v_now             timestamptz := now();
  v_visit_datetime  timestamptz;
  v_end_expires_at  timestamptz;
  v_remaining       int;
BEGIN
  -- 1. قفل صف الحجز لمنع التضارب المتزامن (Row-level lock)
  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'الحجز غير موجود.', 'status_code', 404);
  END IF;

  -- 2. التحقق من صلاحية الممرض المعين للحجز
  SELECT * INTO v_nurse_profile
  FROM public.nurse_profiles
  WHERE user_id = p_nurse_user_id;

  IF NOT FOUND OR v_nurse_profile.id <> v_booking.nurse_id THEN
    RETURN json_build_object('success', false, 'error', 'غير مصرح لك بتنفيذ إجراءات على هذا الحجز.', 'status_code', 403);
  END IF;

  -- 3. مطابقة حالة الحجز مع نوع الكود
  IF p_code_type = 'start' AND v_booking.status <> 'accepted' THEN
    RETURN json_build_object('success', false, 'error', 'لا يمكن بدء زيارة إلا إذا كانت بحالة "مقبول" (accepted).', 'status_code', 409);
  ELSIF p_code_type = 'end' AND v_booking.status <> 'in_progress' THEN
    RETURN json_build_object('success', false, 'error', 'لا يمكن إنهاء زيارة إلا إذا كانت بحالة "جارية" (in_progress).', 'status_code', 409);
  END IF;

  -- 4. قفل وجلب سجل الكود
  SELECT * INTO v_code_rec
  FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = p_code_type
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'لم يتم العثور على كود التأكيد الخاص بهذه المرحلة.', 'status_code', 404);
  END IF;

  -- 5. التحقق من حالة القفل والصلاحية والاستخدام
  IF v_code_rec.is_locked THEN
    RETURN json_build_object('success', false, 'error', 'تم قفل الكود نهائياً لتجاوز الحد الأقصى للمحاولات (5 محاولات). تواصل مع الإدارة.', 'status_code', 423);
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('success', false, 'error', 'تم استخدام هذا الكود مسبقاً ولا يمكن تكراره.', 'status_code', 409);
  END IF;

  IF v_now > v_code_rec.expires_at THEN
    RETURN json_build_object('success', false, 'error', 'انتهت صلاحية الكود (تجاوز 12 ساعة من موعد الزيارة).', 'status_code', 410);
  END IF;

  -- 6. مطابقة تجزئة الكود (Hash verification)
  v_computed_hash := encode(digest(trim(p_entered_code) || v_code_rec.salt, 'sha256'), 'hex');

  IF v_computed_hash <> v_code_rec.code_hash THEN
    -- زيادة عدد المحاولات الخاطئة وقفل الكود عند الوصول إلى 5
    UPDATE public.visit_codes
    SET attempts  = attempts + 1,
        is_locked = (attempts + 1 >= 5)
    WHERE id = v_code_rec.id;

    v_remaining := 5 - (v_code_rec.attempts + 1);
    IF v_remaining <= 0 THEN
      RETURN json_build_object('success', false, 'error', 'الكود غير صحيح. تم قفل الكود نهائياً لتكرار الخطأ 5 مرات.', 'status_code', 423);
    ELSE
      RETURN json_build_object('success', false, 'error', format('الكود غير صحيح. متبقٍ %s محاولات قبل الإيقاف.', v_remaining), 'status_code', 400);
    END IF;
  END IF;

  -- 7. الكود صحيح! تنفيذ التحديثات في نفس المعاملة (Atomic)
  -- أ. تسجيل استخدام الكود الحالي
  UPDATE public.visit_codes
  SET is_used = true,
      used_at = v_now
  WHERE id = v_code_rec.id;

  -- ب. التعامل مع بداية الزيارة: ترقية الحالة وإنشاء كود النهاية
  IF p_code_type = 'start' THEN
    -- تحديث الحجز إلى in_progress
    UPDATE public.bookings
    SET status     = 'in_progress',
        updated_at = v_now
    WHERE id = p_booking_id;

    -- حساب صلاحية كود النهاية (موعد الزيارة + 12 ساعة)
    BEGIN
      v_visit_datetime := (v_booking.visit_date::date + COALESCE(v_booking.start_time::time, '00:00:00'::time))::timestamp AT TIME ZONE 'Africa/Cairo';
    EXCEPTION WHEN OTHERS THEN
      v_visit_datetime := v_now;
    END;
    v_end_expires_at := v_visit_datetime + INTERVAL '12 hours';
    IF v_end_expires_at <= v_now THEN
      v_end_expires_at := v_now + INTERVAL '12 hours';
    END IF;

    -- إنشاء كود النهاية ذرياً (إذا فشل يتراجع التحديث بأكمله تلقائياً)
    PERFORM public._generate_and_store_code(p_booking_id, 'end', v_end_expires_at);

    RETURN json_build_object(
      'success', true,
      'message', 'تم تأكيد بداية الزيارة بنجاح وتم توليد كود إنهاء الزيارة للمريض.',
      'new_status', 'in_progress'
    );

  -- ج. التعامل مع انتهاء الزيارة: ترقية الحالة إلى completed
  ELSIF p_code_type = 'end' THEN
    UPDATE public.bookings
    SET status     = 'completed',
        updated_at = v_now
    WHERE id = p_booking_id;

    RETURN json_build_object(
      'success', true,
      'message', 'تم تأكيد اكتمال الزيارة التمريضية بنجاح.',
      'new_status', 'completed'
    );
  END IF;

  RETURN json_build_object('success', false, 'error', 'نوع الكود غير معروف.', 'status_code', 400);
END;
$$;

-- ------------------------------------------------------------
-- 8. Trigger توليد كود البداية تلقائياً عند قبول الحجز
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_generate_initial_visit_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_visit_datetime timestamptz;
  v_expires_at     timestamptz;
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS DISTINCT FROM 'accepted') THEN
    BEGIN
      v_visit_datetime := (NEW.visit_date::date + COALESCE(NEW.start_time::time, '00:00:00'::time))::timestamp AT TIME ZONE 'Africa/Cairo';
    EXCEPTION WHEN OTHERS THEN
      v_visit_datetime := now();
    END;

    v_expires_at := v_visit_datetime + INTERVAL '12 hours';
    IF v_expires_at <= now() THEN
      v_expires_at := now() + INTERVAL '12 hours';
    END IF;

    PERFORM public._generate_and_store_code(NEW.id, 'start', v_expires_at);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_start_visit_code ON public.bookings;
CREATE TRIGGER trg_auto_start_visit_code
  AFTER UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_generate_initial_visit_code();

