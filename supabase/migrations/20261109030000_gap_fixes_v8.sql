-- ============================================================================
-- CareNest (رعاية) - Migration v8: GPS Coordinates + Critical Gap Fixes
-- File: supabase/migrations/20261109030000_gap_fixes_v8.sql
--
-- الملخص:
--   1. إضافة latitude/longitude إلى bookings (اختياريان، مع قيود نطاق جغرافي)
--   2. إنشاء جدول user_national_ids (مطلوب من Edge Function save-national-id)
--   3. إضافة DB.supabase getter في JS (ملف JS فقط - موثق هنا للمرجعية)
--   4. تصحيح سياسات RLS: bookings يشمل nurse_profile_id
--   5. إضافة سياسات notifications المفقودة
--   6. إضافة سياسة الإدارة على profiles
--   7. تصحيح price column في bookings (مكرر مع total_price - يُضاف إذا لم يكن موجوداً)
-- ============================================================================

-- ============================================================================
-- 1. BOOKINGS: إحداثيات GPS المريض (اختيارية، مع حماية خصوصية كاملة)
-- ============================================================================

-- الإحداثيات تخص موقع المريض وقت الحجز وتُرسل فقط بموافقته الصريحة.
-- تُعرض للممرض فقط بعد قبول الحجز (محميًا بـ DB function get_nurse_patient_profiles).
-- القيود الجغرافية: مصر تقع في نطاق lat [22, 32] و lng [25, 37] - لكن نسمح بالنطاق العالمي
-- لأن Supabase لا يملك إمكانية محدودية جغرافية على المستوى الدولي.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS latitude  numeric(10,7)
    CONSTRAINT chk_booking_latitude  CHECK (latitude  IS NULL OR (latitude  BETWEEN -90.0  AND 90.0)),
  ADD COLUMN IF NOT EXISTS longitude numeric(10,7)
    CONSTRAINT chk_booking_longitude CHECK (longitude IS NULL OR (longitude BETWEEN -180.0 AND 180.0));

-- إضافة عمود price إذا لم يكن موجوداً (يُستخدم في JS كبديل لـ total_price)
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS price numeric(10,2) DEFAULT 0.00;

-- تعليق توضيحي للأعمدة الجديدة
COMMENT ON COLUMN public.bookings.latitude  IS 'إحداثيات GPS المريض (خط العرض) - اختيارية، بموافقة المستخدم فقط';
COMMENT ON COLUMN public.bookings.longitude IS 'إحداثيات GPS المريض (خط الطول) - اختيارية، بموافقة المستخدم فقط';
COMMENT ON COLUMN public.bookings.price     IS 'سعر الزيارة (مرادف لـ total_price للتوافق مع JS القديم)';

-- ============================================================================
-- 2. USER NATIONAL IDs TABLE (Edge Function save-national-id تكتب هنا)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_national_ids (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  national_id_hash      text        NOT NULL UNIQUE,  -- HMAC-SHA256 للكشف عن التكرار
  encrypted_national_id text        NOT NULL,          -- AES-256-GCM مشفر
  encryption_iv         text        NOT NULL,          -- IV للتشفير
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- RLS: فقط service_role (Edge Functions) تستطيع القراءة والكتابة
ALTER TABLE public.user_national_ids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Only service_role can manage national IDs" ON public.user_national_ids;
CREATE POLICY "Only service_role can manage national IDs"
  ON public.user_national_ids FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Trigger: تحديث updated_at
CREATE OR REPLACE FUNCTION public.trg_set_updated_at_national_ids()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

-- ============================================================================
-- 3. BOOKINGS RLS: تصحيح سياسة SELECT لتشمل nurse_profile_id
-- ============================================================================

-- حذف السياسة القديمة وإنشاء بديل أشمل
DROP POLICY IF EXISTS "Users can view their related bookings" ON public.bookings;
CREATE POLICY "Users can view their related bookings"
  ON public.bookings FOR SELECT
  USING (
    auth.uid() = patient_id
    OR auth.uid() = nurse_id
    OR auth.uid() IN (
      SELECT user_id FROM public.nurse_profiles WHERE id = nurse_profile_id
    )
    OR public.is_admin()
    OR auth.role() = 'service_role'
  );

-- ============================================================================
-- 4. BOOKINGS RLS: تصحيح سياسة UPDATE للممرض لتشمل nurse_profile_id
-- ============================================================================

DROP POLICY IF EXISTS "Nurses can update booking operational status" ON public.bookings;
CREATE POLICY "Nurses can update booking operational status"
  ON public.bookings FOR UPDATE
  USING (
    (
      auth.uid() = nurse_id
      OR auth.uid() IN (
        SELECT user_id FROM public.nurse_profiles WHERE id = nurse_profile_id
      )
    )
    AND status IN ('pending', 'accepted', 'in_progress')
    AND NOT public.is_admin()
  )
  WITH CHECK (
    (
      auth.uid() = nurse_id
      OR auth.uid() IN (
        SELECT user_id FROM public.nurse_profiles WHERE id = nurse_profile_id
      )
    )
    AND status IN ('accepted', 'rejected', 'in_progress', 'completed', 'cancelled')
  );

-- ============================================================================
-- 5. NOTIFICATIONS: إضافة سياسات مفقودة
-- ============================================================================

-- الإدارة والخادم يستطيعان إرسال إشعارات لأي مستخدم
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
-- 6. PROFILES: سياسة الإدارة لرؤية جميع الملفات الشخصية
-- ============================================================================

DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles"
  ON public.profiles FOR SELECT
  USING (public.is_admin() OR auth.role() = 'service_role');

-- ============================================================================
-- 7. REVIEWS: منح المرضى صلاحية SELECT (للتحقق من التقييم السابق قبل الإرسال)
-- ============================================================================

-- السياسة الموجودة "Reviews are viewable by everyone" تكفي - فقط نتأكد من وجودها
DROP POLICY IF EXISTS "Reviews are viewable by everyone" ON public.reviews;
CREATE POLICY "Reviews are viewable by everyone"
  ON public.reviews FOR SELECT
  USING (true);

-- ============================================================================
-- 8. SERVICES: التأكد من سياسة القراءة العامة (للزوار غير المسجلين)
-- ============================================================================

DROP POLICY IF EXISTS "Services are viewable by everyone" ON public.services;
CREATE POLICY "Services are viewable by everyone"
  ON public.services FOR SELECT
  USING (is_active = true);

-- ============================================================================
-- 9. OWNER + EXECUTE permissions للدالة الجديدة
-- ============================================================================

ALTER FUNCTION public.trg_set_updated_at_national_ids() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.trg_set_updated_at_national_ids() FROM PUBLIC;
