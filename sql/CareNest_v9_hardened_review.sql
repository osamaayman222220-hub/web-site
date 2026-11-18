-- ============================================================================
-- IMPORTANT EXECUTION GATE:
-- This file is a hardened review candidate, NOT proof of production readiness.
-- Before applying it to any database, verify every referenced bookings column,
-- existing policies/GRANTs, function signatures/dependencies, and frontend query
-- paths against that database. Do not run on production without backup + explicit
-- approval. The nurse UI must use get_nurse_bookings() and must not query bookings
-- directly. Any legacy SELECT policy on profiles/bookings must be inventoried:
-- permissive policies combine with OR and can re-open access.
-- ============================================================================
-- ============================================================================
-- CareNest (رعاية) — Migration v9: Patient Privacy Protection (DB Level)
-- File: supabase/migrations/20261109040000_patient_privacy_v9.sql
-- الحجم: متكامل | مؤلف: مراجعة أمنية محلية | التاريخ: 2026-11-09
--
-- ════════════════════════════════════════════════════════════════════════════
-- الثغرات المكتشفة والمُصلَحة:
--
-- [ثغرة 1 - حرجة] profiles RLS — الممرض يقرأ ملف المريض كاملاً
--   • السياسة "Users can view profiles related to their bookings" (v1 line 572)
--     تُعيد الصف كاملاً (phone, address, email, governorate, city)
--     بمجرد وجود أي حجز، بغض النظر عن status الحجز.
--   • الإصلاح: استبدال بـ SECURITY DEFINER function تعيد حقولاً محددة فقط
--     مع فلترة phone/address بناءً على حالة الحجز.
--
-- [ثغرة 2 - حرجة] bookings SELECT — SELECT * يُرجع كل الأعمدة
--   • سياسة SELECT في v8 تسمح للممرض بقراءة patient_phone,
--     patient_address, latitude, longitude, patient_notes
--     حتى قبل قبول الحجز (status=pending).
--   • الإصلاح: دالة get_nurse_bookings() SECURITY DEFINER
--     تُخفي الحقول الحساسة بـ CASE WHEN status IN ('accepted',...).
--
-- [ثغرة 3 - متوسطة] get_nurse_patient_profiles() لا تشمل lat/lng/notes
--   • الإصلاح: إعادة بناء الدالة لإضافة الحقول الجديدة (v8 columns).
-- ════════════════════════════════════════════════════════════════════════════

-- ============================================================================
-- القسم 1: إصلاح سياسة profiles — منع الممرض من قراءة بيانات المريض الحساسة
--          قبل قبول الحجز عبر جدول profiles مباشرة
-- ============================================================================

-- نحذف السياسة القديمة التي تكشف كل بيانات profiles للممرض بمجرد وجود حجز
DROP POLICY IF EXISTS "Users can view profiles related to their bookings" ON public.profiles;

-- ═══════════════════════════════════════════════════════════════════════════
-- دالة get_booking_counterpart_profile()
-- تُرجع بيانات الطرف الآخر في الحجز (المريض للممرض / الممرض للمريض)
-- مع إخفاء phone/address للمريض عن الممرض قبل قبول الحجز
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_booking_counterpart_profile(
  p_booking_id uuid
)
RETURNS TABLE (
  profile_id    uuid,
  full_name     text,
  email         text,     -- يُخفى دائماً عن الممرض (للمريض فقط)
  phone         text,     -- يُخفى عن الممرض قبل قبول الحجز
  address       text,     -- يُخفى عن الممرض قبل قبول الحجز
  governorate   text,
  city          text,
  avatar_url    text,
  role          text,
  counterpart   text      -- 'patient' أو 'nurse'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id  uuid;
  v_is_admin   boolean;
  v_booking    public.bookings;
  v_is_patient boolean;
  v_is_nurse   boolean;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR p_booking_id IS NULL THEN RETURN; END IF;

  SELECT (role = 'admin') INTO v_is_admin
  FROM public.profiles WHERE id = v_caller_id;
  v_is_admin := COALESCE(v_is_admin, false);

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_is_patient := (v_booking.patient_id = v_caller_id);
  v_is_nurse   := (
    v_booking.nurse_id = v_caller_id
    OR v_booking.nurse_profile_id IN (
      SELECT np.id FROM public.nurse_profiles np WHERE np.user_id = v_caller_id
    )
  );

  IF NOT (v_is_admin OR v_is_patient OR v_is_nurse) THEN
    RETURN; -- ليس طرفاً في هذا الحجز
  END IF;

  IF v_is_admin OR v_is_patient THEN
    -- المريض والإدارة: يريان الملف الكامل للطرف الآخر (الممرض)
    RETURN QUERY
    SELECT
      p.id,
      p.full_name,
      CASE WHEN v_is_admin THEN p.email ELSE NULL END,
      p.phone,
      p.address,
      p.governorate,
      p.city,
      p.avatar_url,
      p.role,
      'nurse'::text
    FROM public.profiles p
    WHERE p.id = v_booking.nurse_id
       OR p.id IN (
         SELECT np.user_id FROM public.nurse_profiles np
         WHERE np.id = v_booking.nurse_profile_id
       );
  ELSE
    -- الممرض: يرى بيانات المريض مع إخفاء حسب حالة الحجز
    RETURN QUERY
    SELECT
      p.id,
      p.full_name,
      NULL::text AS email,  -- الإيميل محجوب عن الممرض دائماً
      CASE
        WHEN v_booking.status IN ('accepted', 'in_progress', 'completed')
        THEN p.phone ELSE NULL
      END AS phone,
      CASE
        WHEN v_booking.status IN ('accepted', 'in_progress', 'completed')
        THEN COALESCE(v_booking.patient_address, p.address) ELSE NULL
      END AS address,
      COALESCE(v_booking.governorate, p.governorate) AS governorate,
      COALESCE(v_booking.city, p.city)               AS city,
      p.avatar_url,
      p.role,
      'patient'::text
    FROM public.profiles p
    WHERE p.id = v_booking.patient_id;
  END IF;
END;
$$;

ALTER FUNCTION public.get_booking_counterpart_profile(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_booking_counterpart_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_booking_counterpart_profile(uuid) TO authenticated;

-- لا نسمح بقراءة ملفات الأطراف الأخرى مباشرة من جدول profiles.
-- بيانات الطرف الآخر تُطلب عبر get_booking_counterpart_profile() فقط.
-- نُبقي سياسات "ملفي الشخصي" و"الإدارة" منفصلة.
DROP POLICY IF EXISTS "Users can view booking counterpart profile" ON public.profiles;


-- ============================================================================
-- القسم 2: إعادة بناء دالة get_nurse_bookings() مع حماية كاملة
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_nurse_bookings(
  p_status text DEFAULT NULL
)
RETURNS TABLE (
  -- هوية الحجز
  id                  uuid,
  status              text,
  created_at          timestamptz,
  updated_at          timestamptz,
  -- هوية الأطراف (عامة دائماً)
  patient_id          uuid,
  patient_name        text,
  nurse_id            uuid,
  nurse_profile_id    uuid,
  -- تفاصيل الخدمة
  service_id          uuid,
  service_name        text,
  service_type        text,
  visit_date          date,
  visit_time          time,
  start_time          time,
  duration_hours      numeric,
  -- الموقع العام (دائماً مرئي للممرض)
  country             text,
  governorate         text,
  city                text,
  -- الأسعار (مرئية للممرض)
  price               numeric,
  total_price         numeric,
  currency            text,
  -- حالة الدفع (بدون تفاصيل مالية داخلية)
  payment_method      text,
  payment_status      text,
  deposit_amount      numeric,
  -- ════════════════════════════════════════════════
  -- الحقول الحساسة: NULL قبل قبول الحجز
  -- ════════════════════════════════════════════════
  patient_phone       text,       -- NULL إذا status = 'pending'
  patient_address     text,       -- NULL إذا status = 'pending'
  latitude            numeric,    -- NULL إذا status = 'pending'
  longitude           numeric,    -- NULL إذا status = 'pending'
  patient_notes       text,       -- NULL إذا status = 'pending'
  notes               text,       -- NULL إذا status = 'pending'
  -- حقل مساعد للواجهة
  is_patient_masked   boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id uuid;
  v_is_admin  boolean;
  v_role      text;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN RETURN; END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_caller_id;
  v_is_admin := (v_role = 'admin');

  -- الدالة مخصصة للممرضين والإدارة فقط
  IF NOT (v_is_admin OR v_role = 'nurse') THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.status,
    b.created_at,
    b.updated_at,
    -- أطراف الحجز
    b.patient_id,
    COALESCE(b.patient_name, 'مريض')                   AS patient_name,
    b.nurse_id,
    b.nurse_profile_id,
    -- الخدمة
    b.service_id,
    COALESCE(b.service_name, b.service_type, 'تمريض عام') AS service_name,
    COALESCE(b.service_type, b.service_name, 'تمريض عام') AS service_type,
    b.visit_date,
    COALESCE(b.visit_time, b.start_time, '10:00:00'::time) AS visit_time,
    COALESCE(b.start_time, b.visit_time, '10:00:00'::time) AS start_time,
    COALESCE(b.duration_hours, 1.0)                       AS duration_hours,
    -- الموقع العام
    COALESCE(b.country, 'Egypt')                          AS country,
    COALESCE(b.governorate, '')                           AS governorate,
    COALESCE(b.city, '')                                  AS city,
    -- الأسعار
    COALESCE(b.price, b.total_price, 0.00)                AS price,
    COALESCE(b.total_price, b.price, 0.00)                AS total_price,
    COALESCE(b.currency, 'EGP')                           AS currency,
    -- الدفع
    b.payment_method,
    b.payment_status,
    COALESCE(b.deposit_amount, 0.00)                      AS deposit_amount,

    -- ════════════════════════════════════════════════
    -- الحماية: الحقول الحساسة مشروطة بحالة الحجز
    -- ════════════════════════════════════════════════
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.patient_phone   ELSE NULL END AS patient_phone,

    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.patient_address ELSE NULL END AS patient_address,

    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.latitude        ELSE NULL END AS latitude,

    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.longitude       ELSE NULL END AS longitude,

    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN COALESCE(b.patient_notes, b.notes)   ELSE NULL END AS patient_notes,

    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN COALESCE(b.notes, b.patient_notes)   ELSE NULL END AS notes,

    -- is_patient_masked = true عندما تكون البيانات مخفية
    NOT (v_is_admin OR b.status IN ('accepted','in_progress','completed'))
      AS is_patient_masked

  FROM public.bookings b
  WHERE
    -- الممرض يرى حجوزاته فقط / الإدارة ترى الكل
    (
      v_is_admin
      OR b.nurse_id = v_caller_id
      OR b.nurse_profile_id IN (
        SELECT np.id FROM public.nurse_profiles np WHERE np.user_id = v_caller_id
      )
    )
    AND (p_status IS NULL OR p_status = 'all' OR b.status = p_status)
  ORDER BY b.visit_date ASC, b.created_at DESC;
END;
$$;

ALTER FUNCTION public.get_nurse_bookings(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_nurse_bookings(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_nurse_bookings(text) TO authenticated;


-- ============================================================================
-- القسم 3: دالة get_booking_details() — تفاصيل حجز واحد بحماية كاملة
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_booking_details(
  p_booking_id uuid
)
RETURNS TABLE (
  id                uuid,
  status            text,
  created_at        timestamptz,
  updated_at        timestamptz,
  patient_id        uuid,
  patient_name      text,
  nurse_id          uuid,
  nurse_profile_id  uuid,
  service_id        uuid,
  service_name      text,
  service_type      text,
  visit_date        date,
  visit_time        time,
  start_time        time,
  duration_hours    numeric,
  country           text,
  governorate       text,
  city              text,
  price             numeric,
  total_price       numeric,
  currency          text,
  payment_method    text,
  payment_status    text,
  deposit_amount    numeric,
  patient_phone     text,
  patient_address   text,
  latitude          numeric,
  longitude         numeric,
  patient_notes     text,
  notes             text,
  is_patient_masked boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id  uuid;
  v_is_admin   boolean;
  v_booking    public.bookings;
  v_is_patient boolean;
  v_is_nurse   boolean;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR p_booking_id IS NULL THEN RETURN; END IF;

  SELECT (role = 'admin') INTO v_is_admin
  FROM public.profiles WHERE id = v_caller_id;
  v_is_admin := COALESCE(v_is_admin, false);

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_is_patient := (v_booking.patient_id = v_caller_id);
  v_is_nurse   := (
    v_booking.nurse_id = v_caller_id
    OR v_booking.nurse_profile_id IN (
      SELECT np.id FROM public.nurse_profiles np WHERE np.user_id = v_caller_id
    )
  );

  IF NOT (v_is_admin OR v_is_patient OR v_is_nurse) THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    v_booking.id,
    v_booking.status,
    v_booking.created_at,
    v_booking.updated_at,
    v_booking.patient_id,
    v_booking.patient_name,
    v_booking.nurse_id,
    v_booking.nurse_profile_id,
    v_booking.service_id,
    COALESCE(v_booking.service_name, v_booking.service_type, 'تمريض عام'),
    COALESCE(v_booking.service_type, v_booking.service_name, 'تمريض عام'),
    v_booking.visit_date,
    COALESCE(v_booking.visit_time, v_booking.start_time, '10:00:00'::time),
    COALESCE(v_booking.start_time, v_booking.visit_time, '10:00:00'::time),
    COALESCE(v_booking.duration_hours, 1.0),
    COALESCE(v_booking.country, 'Egypt'),
    COALESCE(v_booking.governorate, ''),
    COALESCE(v_booking.city, ''),
    COALESCE(v_booking.price, v_booking.total_price, 0.00),
    COALESCE(v_booking.total_price, v_booking.price, 0.00),
    COALESCE(v_booking.currency, 'EGP'),
    v_booking.payment_method,
    v_booking.payment_status,
    COALESCE(v_booking.deposit_amount, 0.00),
    -- ═══ الحقول الحساسة ═══
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN v_booking.patient_phone   ELSE NULL END,
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN v_booking.patient_address ELSE NULL END,
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN v_booking.latitude        ELSE NULL END,
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN v_booking.longitude       ELSE NULL END,
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN COALESCE(v_booking.patient_notes, v_booking.notes) ELSE NULL END,
    CASE WHEN v_is_admin OR v_is_patient
              OR v_booking.status IN ('accepted','in_progress','completed')
         THEN COALESCE(v_booking.notes, v_booking.patient_notes) ELSE NULL END,
    NOT (v_is_admin OR v_is_patient
         OR v_booking.status IN ('accepted','in_progress','completed'))
      AS is_patient_masked;
END;
$$;

ALTER FUNCTION public.get_booking_details(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_booking_details(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_booking_details(uuid) TO authenticated;


-- ============================================================================
-- القسم 4: إعادة بناء دالة get_nurse_patient_profiles()
--          (موجودة في v1) — إضافة latitude/longitude/patient_notes + nurse_profile_id
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_nurse_patient_profiles()
RETURNS TABLE (
  booking_id      uuid,
  patient_id      uuid,
  full_name       text,
  phone           text,       -- NULL إذا status = 'pending'
  patient_address text,       -- NULL إذا status = 'pending'
  governorate     text,
  city            text,
  latitude        numeric,    -- NULL إذا status = 'pending' (أُضيف في v8)
  longitude       numeric,    -- NULL إذا status = 'pending' (أُضيف في v8)
  patient_notes   text        -- NULL إذا status = 'pending' (أُضيف في v8)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_is_admin  boolean := false;
BEGIN
  IF v_caller_id IS NULL THEN RETURN; END IF;

  SELECT (role = 'admin') INTO v_is_admin
  FROM public.profiles WHERE id = v_caller_id;
  v_is_admin := COALESCE(v_is_admin, false);

  RETURN QUERY
  SELECT
    b.id AS booking_id,
    p.id AS patient_id,
    p.full_name,
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN p.phone ELSE NULL END AS phone,
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN COALESCE(b.patient_address, p.address) ELSE NULL END AS patient_address,
    COALESCE(b.governorate, p.governorate) AS governorate,
    COALESCE(b.city, p.city)               AS city,
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.latitude  ELSE NULL END AS latitude,
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN b.longitude ELSE NULL END AS longitude,
    CASE WHEN v_is_admin OR b.status IN ('accepted','in_progress','completed')
         THEN COALESCE(b.patient_notes, b.notes) ELSE NULL END AS patient_notes
  FROM public.bookings b
  JOIN public.profiles p ON p.id = b.patient_id
  WHERE
    v_is_admin
    OR b.nurse_id = v_caller_id
    OR b.nurse_profile_id IN (
      SELECT np.id FROM public.nurse_profiles np WHERE np.user_id = v_caller_id
    )
    OR EXISTS (
      SELECT 1 FROM public.nurse_profiles np
      WHERE np.id = b.nurse_id AND np.user_id = v_caller_id
    );
END;
$$;

ALTER FUNCTION public.get_nurse_patient_profiles() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_nurse_patient_profiles() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_nurse_patient_profiles() TO authenticated;


-- ============================================================================
-- القسم 5: إعادة بناء سياسات SELECT على bookings
--          (نحذف السياسة الموجودة في v8 ونستبدلها بثلاث سياسات منفصلة وواضحة)
-- ============================================================================

-- حذف السياسة القديمة الشاملة (أُنشئت في v1 وعُدِّلت في v8)
DROP POLICY IF EXISTS "Users can view related bookings"           ON public.bookings;
DROP POLICY IF EXISTS "Users can view their related bookings"     ON public.bookings;
DROP POLICY IF EXISTS "Users can view booking counterpart profile" ON public.bookings;

-- سياسات SELECT: المريض والإدارة فقط يقرآن الجدول مباشرة.
-- الممرض يحصل على نسخة مُفلترة من خلال RPC get_nurse_bookings().
DROP POLICY IF EXISTS "Patient can view own bookings" ON public.bookings;
DROP POLICY IF EXISTS "Admin and service role can view all bookings" ON public.bookings;
DROP POLICY IF EXISTS "Nurse can view assigned bookings" ON public.bookings;

CREATE POLICY "Patient can view own bookings"
  ON public.bookings FOR SELECT
  USING (auth.uid() = patient_id);

CREATE POLICY "Admin and service role can view all bookings"
  ON public.bookings FOR SELECT
  USING (public.is_admin() OR auth.role() = 'service_role');

-- لا تنشئ سياسة SELECT للممرض هنا؛ RLS لا تستطيع إخفاء أعمدة الصف.
-- يجب أن تعتمد واجهة الممرض على RPC get_nurse_bookings() فقط.


-- تأكد من وجود الجدول قبل تفعيل RLS أو إنشاء السياسات عليه.
-- يبقى تعريف CREATE TABLE الأصلي في القسم 11 كتعريف توثيقي idempotent.
CREATE TABLE IF NOT EXISTS public.user_national_ids (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  national_id_hash      text        NOT NULL UNIQUE,
  encrypted_national_id text        NOT NULL,
  encryption_iv         text        NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- القسم 6: جدول user_national_ids — تأكيد الأمان
-- (أُنشئ في v8، نتأكد من صحة السياسات)
-- ============================================================================

-- حذف السياسة القديمة وإعادة إنشائها بوضوح
DROP POLICY IF EXISTS "Only service_role can manage national IDs"     ON public.user_national_ids;
DROP POLICY IF EXISTS "national_ids_no_public_read"                   ON public.user_national_ids;
DROP POLICY IF EXISTS "national_ids_service_only"                     ON public.user_national_ids;

-- نفعّل RLS ونمنع صلاحيات الجدول المباشرة عن الأدوار العامة والمستخدمين.
ALTER TABLE public.user_national_ids ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_national_ids FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.user_national_ids TO service_role;

-- سياسة وحيدة: service_role فقط (Edge Functions).
DROP POLICY IF EXISTS "national_ids_service_role_only" ON public.user_national_ids;
CREATE POLICY "national_ids_service_role_only"
  ON public.user_national_ids FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);


-- ============================================================================
-- القسم 7: سياسات notifications المفقودة (من v8 — تأكيد وجودها)
-- ============================================================================

DROP POLICY IF EXISTS "Admins and service role can insert notifications" ON public.notifications;
CREATE POLICY "Admins and service role can insert notifications"
  ON public.notifications FOR INSERT
  WITH CHECK (
    public.is_admin()
    OR auth.role() = 'service_role'
    OR auth.uid() = user_id
  );

DROP POLICY IF EXISTS "Service role can manage all notifications" ON public.notifications;
CREATE POLICY "Service role can manage all notifications"
  ON public.notifications FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);


-- ============================================================================
-- القسم 8: سياسة الإدارة على profiles (من v8 — تأكيد)
-- ============================================================================

DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles"
  ON public.profiles FOR SELECT
  USING (public.is_admin() OR auth.role() = 'service_role');


-- ============================================================================
-- القسم 9: Reviews و Services (تأكيد السياسات)
-- ============================================================================

DROP POLICY IF EXISTS "Reviews are viewable by everyone" ON public.reviews;
CREATE POLICY "Reviews are viewable by everyone"
  ON public.reviews FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Services are viewable by everyone" ON public.services;
CREATE POLICY "Services are viewable by everyone"
  ON public.services FOR SELECT
  USING (is_active = true);


-- ============================================================================
-- القسم 10: إضافة إحداثيات GPS وعمود price (من v8 — تأكيد إذا لم تُطبق)
-- ============================================================================

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS latitude  numeric(10,7)
    CONSTRAINT chk_booking_latitude  CHECK (latitude  IS NULL OR latitude  BETWEEN -90.0  AND  90.0),
  ADD COLUMN IF NOT EXISTS longitude numeric(10,7)
    CONSTRAINT chk_booking_longitude CHECK (longitude IS NULL OR longitude BETWEEN -180.0 AND 180.0);

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS price numeric(10,2) DEFAULT 0.00;

COMMENT ON COLUMN public.bookings.latitude  IS 'GPS المريض (خط العرض) — اختياري، بموافقة المستخدم فقط';
COMMENT ON COLUMN public.bookings.longitude IS 'GPS المريض (خط الطول) — اختياري، بموافقة المستخدم فقط';
COMMENT ON COLUMN public.bookings.price     IS 'مرادف لـ total_price للتوافق مع JS (العمود المرجعي: total_price)';


-- ============================================================================
-- القسم 11: إنشاء جدول user_national_ids إذا لم يكن موجوداً
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_national_ids (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  national_id_hash      text        NOT NULL UNIQUE,
  encrypted_national_id text        NOT NULL,
  encryption_iv         text        NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- trigger updated_at
CREATE OR REPLACE FUNCTION public.trg_set_updated_at_national_ids()
RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_national_ids_updated_at ON public.user_national_ids;
CREATE TRIGGER set_national_ids_updated_at
  BEFORE UPDATE ON public.user_national_ids
  FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at_national_ids();

ALTER FUNCTION public.trg_set_updated_at_national_ids() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.trg_set_updated_at_national_ids() FROM PUBLIC;
