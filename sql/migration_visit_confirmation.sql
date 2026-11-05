-- ============================================================
-- CareNest - Visit Confirmation System
-- Migration: visit_confirmation_v1
-- الجداول الجديدة: visit_codes, absence_reports
-- التعديلات: تعديل trigger protect_booking_updates
--
-- تعليمات التطبيق:
-- 1. انسخ هذا الكود إلى Supabase → SQL Editor
-- 2. شغّله بأكمله دفعةً واحدة
-- 3. تأكد من نجاح كل جملة قبل الانتقال للتالية
-- ============================================================


-- ----------------------------------------------------------------
-- القسم 1: إنشاء جدول visit_codes
-- يخزن الأكواد السرية لتأكيد بداية الزيارة ونهايتها
-- ----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.visit_codes (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id  uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  code_type   text        NOT NULL CHECK (code_type IN ('start', 'end')),
  code_plain  text        NOT NULL,
    -- الكود المكوّن من 6 أرقام، مرئي للمريض فقط بواسطة RLS
    -- لا نخزن hash بل نخزن الكود الأصلي وتحكم RLS في من يراه
  is_used     boolean     NOT NULL DEFAULT false,
  used_at     timestamptz,
  expires_at  timestamptz NOT NULL,
    -- يُحسب من: موعد الزيارة (visit_date + start_time) + 12 ساعة
    -- إذا كان الموعد لم يأتِ بعد، الكود صالح حتى 12 ساعة بعد بدء الزيارة
  attempts    int         NOT NULL DEFAULT 0,
  is_locked   boolean     NOT NULL DEFAULT false,
    -- يصبح true بعد 5 محاولات فاشلة متتالية
  created_at  timestamptz NOT NULL DEFAULT now(),

  -- قيد: كود واحد لكل نوع لكل حجز
  UNIQUE (booking_id, code_type)
);

COMMENT ON TABLE public.visit_codes IS 'أكواد تأكيد بداية ونهاية الزيارات - مرئية للمريض فقط';
COMMENT ON COLUMN public.visit_codes.code_plain IS 'الكود الأصلي (6 أرقام) - RLS تمنع الممرض من قراءته';
COMMENT ON COLUMN public.visit_codes.expires_at IS 'موعد الزيارة + 12 ساعة (تُحسب من بداية الزيارة لا من إنشاء الكود)';
COMMENT ON COLUMN public.visit_codes.is_locked IS 'يُغلق الكود تلقائياً بعد 5 محاولات فاشلة';


-- ----------------------------------------------------------------
-- القسم 2: إنشاء جدول absence_reports
-- يسجّل بلاغات عدم حضور الممرض
-- ----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.absence_reports (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id    uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  patient_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nurse_id      uuid        NOT NULL,
    -- يشير إلى nurse_profiles.id (وليس profiles.id)
  report_time   timestamptz NOT NULL DEFAULT now(),
  patient_note  text,
    -- ملاحظة اختيارية من المريض
  admin_action  text CHECK (admin_action IN ('dismissed', 'warning', 'suspended', 'refunded')),
    -- الإجراء الإداري: تجاهل | تحذير | إيقاف | تعويض مالي
  admin_note    text,
  reviewed_by   uuid REFERENCES public.profiles(id),
  reviewed_at   timestamptz,
  status        text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'reviewed', 'resolved')),

  -- قيد: بلاغ واحد لكل حجز
  UNIQUE (booking_id)
);

COMMENT ON TABLE public.absence_reports IS 'بلاغات عدم حضور الممرض - تُقدَّم بعد 90 دقيقة من موعد الزيارة';


-- ----------------------------------------------------------------
-- القسم 3: تفعيل RLS على الجدولين الجديدين
-- ----------------------------------------------------------------

ALTER TABLE public.visit_codes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.absence_reports ENABLE ROW LEVEL SECURITY;


-- ----------------------------------------------------------------
-- القسم 4: سياسات RLS لجدول visit_codes
-- ----------------------------------------------------------------

-- حذف السياسات القديمة إن وجدت
DROP POLICY IF EXISTS "patient_read_own_visit_codes"   ON public.visit_codes;
DROP POLICY IF EXISTS "admin_read_all_visit_codes"     ON public.visit_codes;

-- المريض يرى كود البداية فقط عندما تكون الزيارة مقبولة
-- المريض يرى كود النهاية فقط عندما تكون الزيارة جارية
-- الممرض لا يملك أي سياسة SELECT → لا يستطيع القراءة إطلاقاً
CREATE POLICY "patient_read_own_visit_codes" ON public.visit_codes
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = visit_codes.booking_id
        AND b.patient_id = auth.uid()
        AND (
          (visit_codes.code_type = 'start' AND b.status = 'accepted')
          OR
          (visit_codes.code_type = 'end'   AND b.status = 'in_progress')
        )
    )
  );

-- الأدمن يرى جميع الأكواد (للمراجعة عند الحاجة)
CREATE POLICY "admin_read_all_visit_codes" ON public.visit_codes
  FOR SELECT USING (public.is_admin());

-- لا توجد سياسات INSERT/UPDATE/DELETE من العميل
-- التعديلات تتم فقط عبر Edge Function باستخدام service_role


-- ----------------------------------------------------------------
-- القسم 5: سياسات RLS لجدول absence_reports
-- ----------------------------------------------------------------

DROP POLICY IF EXISTS "patient_insert_absence_report"   ON public.absence_reports;
DROP POLICY IF EXISTS "patient_read_own_absence_reports" ON public.absence_reports;
DROP POLICY IF EXISTS "admin_manage_absence_reports"     ON public.absence_reports;

-- المريض يستطيع تقديم بلاغ لحجوزاته فقط
CREATE POLICY "patient_insert_absence_report" ON public.absence_reports
  FOR INSERT WITH CHECK (
    patient_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = absence_reports.booking_id
        AND b.patient_id = auth.uid()
    )
  );

-- المريض يرى بلاغاته الخاصة فقط
CREATE POLICY "patient_read_own_absence_reports" ON public.absence_reports
  FOR SELECT USING (patient_id = auth.uid());

-- الأدمن يملك صلاحية كاملة على البلاغات
CREATE POLICY "admin_manage_absence_reports" ON public.absence_reports
  FOR ALL USING (public.is_admin());


-- ----------------------------------------------------------------
-- القسم 6: دالة إنشاء كود بداية الزيارة تلقائياً
-- تُستدعى بواسطة trigger عند تغيير حالة الحجز إلى accepted
-- ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generate_visit_start_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code           text;
  v_visit_datetime timestamptz;
BEGIN
  -- تعمل فقط عند الانتقال إلى حالة accepted
  IF NEW.status = 'accepted' AND (OLD.status IS DISTINCT FROM 'accepted') THEN

    -- توليد كود من 6 أرقام (مع padding من اليسار)
    v_code := lpad(floor(random() * 999999 + 1)::bigint::text, 6, '0');

    -- حساب موعد الزيارة بدمج visit_date + start_time
    BEGIN
      v_visit_datetime := (
        NEW.visit_date::date + COALESCE(NEW.start_time::time, '00:00:00'::time)
      )::timestamp AT TIME ZONE 'Africa/Cairo';
    EXCEPTION WHEN OTHERS THEN
      -- في حالة خطأ التحويل، استخدم الوقت الحالي كأساس
      v_visit_datetime := now();
    END;

    -- إدراج كود البداية — ينتهي بعد 12 ساعة من بداية الزيارة
    INSERT INTO public.visit_codes (
      booking_id,
      code_type,
      code_plain,
      expires_at
    ) VALUES (
      NEW.id,
      'start',
      v_code,
      v_visit_datetime + INTERVAL '12 hours'
    )
    ON CONFLICT (booking_id, code_type) DO NOTHING;
    -- (ON CONFLICT: إذا انُشئ الكود مسبقاً لا تعيد الإنشاء)

  END IF;

  RETURN NEW;
END;
$$;

-- إنشاء الـ trigger
DROP TRIGGER IF EXISTS trg_generate_visit_start_code ON public.bookings;
CREATE TRIGGER trg_generate_visit_start_code
  AFTER UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.generate_visit_start_code();


-- ----------------------------------------------------------------
-- القسم 7: تعديل trigger protect_booking_updates
-- إضافة قيد: accepted→in_progress و in_progress→completed
-- لا يُسمح إلا عبر Edge Function (service_role → auth.uid() IS NULL)
-- ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.protect_booking_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- لا تغيير في الحالة → لا قيود
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- الأدمن يملك صلاحية كاملة على جميع الانتقالات
  IF public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- ─── Service Role (Edge Function) ───────────────────────────
  -- عند استخدام service_role key، تكون auth.uid() = NULL
  -- نسمح لـ Edge Function بأي انتقال (لأنها تحققت من الكود بالفعل)
  IF auth.uid() IS NULL THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- ─── المستخدمون العاديون (مريض أو ممرض) ────────────────────

  -- الممرض يقبل / يرفض / يعتذر عن الحجز الجديد
  IF OLD.status = 'pending' AND NEW.status IN ('accepted', 'rejected', 'cancelled') THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- الممرض أو المريض يلغي الحجز المقبول (قبل البدء)
  IF OLD.status = 'accepted' AND NEW.status = 'cancelled' THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- المريض يلغي حجزه في أي وقت مبكر
  IF OLD.status = 'pending' AND NEW.status = 'cancelled' THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- ─── انتقالات محظورة بدون كود ───────────────────────────────

  -- accepted → in_progress: يجب المرور عبر Edge Function + كود البداية
  IF OLD.status = 'accepted' AND NEW.status = 'in_progress' THEN
    RAISE EXCEPTION
      'visit_code_required_start: يجب إدخال كود تأكيد بداية الزيارة من المريض أولاً.'
      USING ERRCODE = 'P0001';
  END IF;

  -- in_progress → completed: يجب المرور عبر Edge Function + كود النهاية
  IF OLD.status = 'in_progress' AND NEW.status = 'completed' THEN
    RAISE EXCEPTION
      'visit_code_required_end: يجب إدخال كود تأكيد انتهاء الزيارة من المريض أولاً.'
      USING ERRCODE = 'P0001';
  END IF;

  -- أي انتقال آخر غير مسموح
  RAISE EXCEPTION
    'انتقال حالة الحجز غير مسموح: من % إلى %', OLD.status, NEW.status
    USING ERRCODE = 'P0001';

END;
$$;

-- إعادة إنشاء الـ trigger
DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.bookings;
CREATE TRIGGER trg_protect_booking_updates
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_booking_updates();


-- ----------------------------------------------------------------
-- القسم 8: فهارس الأداء (Indexes)
-- ----------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_visit_codes_booking_id
  ON public.visit_codes (booking_id);

CREATE INDEX IF NOT EXISTS idx_visit_codes_booking_type
  ON public.visit_codes (booking_id, code_type);

CREATE INDEX IF NOT EXISTS idx_absence_reports_booking_id
  ON public.absence_reports (booking_id);

CREATE INDEX IF NOT EXISTS idx_absence_reports_status
  ON public.absence_reports (status)
  WHERE status = 'pending';


-- ----------------------------------------------------------------
-- ✅ انتهى SQL — للتحقق من نجاح التطبيق:
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public'
-- AND table_name IN ('visit_codes', 'absence_reports');
-- يجب أن يُرجع سطرين.
-- ----------------------------------------------------------------

