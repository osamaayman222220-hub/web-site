-- ============================================================
-- CareNest Migration: Nurse Professional Data + Platform Settings
-- تاريخ: 2026-11-18
-- ============================================================
-- تعليمات التنفيذ:
-- 1. افتح Supabase Dashboard → SQL Editor
-- 2. انسخ هذا الملف كاملاً وشغّله
-- 3. كل أمر مؤمّن بـ IF NOT EXISTS أو DO $$...EXCEPTION
--    لذلك التنفيذ المتكرر آمن تماماً
-- ============================================================

-- =========================================
-- 1. إضافة عمود license_number إلى nurse_profiles
-- =========================================
-- إذا لم يكن الجدول يحتوي على العمود بالفعل
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS license_number text;

COMMENT ON COLUMN public.nurse_profiles.license_number IS
  'رقم ترخيص مزاولة المهنة الصادر من وزارة الصحة (اختياري)';

-- =========================================
-- 2. إنشاء جدول platform_settings إذا لم يكن موجوداً
-- =========================================
CREATE TABLE IF NOT EXISTS public.platform_settings (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key         text NOT NULL UNIQUE,
  value       jsonb,
  description text,
  is_public   boolean NOT NULL DEFAULT false,
  updated_at  timestamptz DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.platform_settings IS
  'إعدادات منصة CareNest: بيانات الدفع، معدلات العمولة، وغيرها';

-- =========================================
-- 3. تفعيل RLS على platform_settings
-- =========================================
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

-- السماح للجميع بقراءة الإعدادات العامة (is_public = true)
DROP POLICY IF EXISTS "public_can_read_public_settings" ON public.platform_settings;
CREATE POLICY "public_can_read_public_settings"
  ON public.platform_settings
  FOR SELECT
  USING (is_public = true);

-- السماح للمصادقين بقراءة جميع الإعدادات (للمريض والممرض)
DROP POLICY IF EXISTS "authenticated_can_read_settings" ON public.platform_settings;
CREATE POLICY "authenticated_can_read_settings"
  ON public.platform_settings
  FOR SELECT
  TO authenticated
  USING (true);

-- السماح فقط للمدراء بالتعديل
DROP POLICY IF EXISTS "admin_can_modify_settings" ON public.platform_settings;
CREATE POLICY "admin_can_modify_settings"
  ON public.platform_settings
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- =========================================
-- 4. إدراج الإعدادات الافتراضية للدفع (فارغة - تُملأ من الإدارة)
-- =========================================
INSERT INTO public.platform_settings (key, value, description, is_public)
VALUES
  (
    'payment_methods',
    '{"vodafone_cash": {"enabled": false, "phone": "", "name": "منصة رعاية"}, "instapay": {"enabled": false, "handle": "", "name": "منصة رعاية", "instructions": ""}}'::jsonb,
    'طرق الدفع الإلكتروني المتاحة (فودافون كاش وإنستاباي)',
    true
  ),
  (
    'platform_commission',
    '{"rate": 15, "description": "نسبة عمولة المنصة من الزيارات المكتملة"}'::jsonb,
    'معدل عمولة المنصة بالنسبة المئوية',
    false
  )
ON CONFLICT (key) DO NOTHING;

-- =========================================
-- 5. التحقق من وجود عمود specialization في nurse_profiles
-- =========================================
-- إضافة عمود specialization إذا لم يكن موجوداً
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS specialization text;

-- إضافة عمود qualifications إذا لم يكن موجوداً
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS qualifications text;

-- إضافة عمود experience_years إذا لم يكن موجوداً
ALTER TABLE public.nurse_profiles
  ADD COLUMN IF NOT EXISTS experience_years integer DEFAULT 0;

-- =========================================
-- 6. تحقق نهائي: عرض بنية الجداول المحدّثة
-- =========================================
-- يمكنك تشغيل الاستعلامات التالية يدوياً للتحقق:
/*
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'nurse_profiles'
ORDER BY ordinal_position;

SELECT key, value, is_public FROM platform_settings ORDER BY key;
*/

-- ============================================================
-- انتهت عمليات الترحيل بنجاح ✅
-- ============================================================
