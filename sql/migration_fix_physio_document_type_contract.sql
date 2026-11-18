-- ============================================================================
-- CareNest (رعاية) - Comprehensive Physiotherapist Foundation & Documents Fix
-- Description:
--   1. Ensures `physiotherapist_documents` constraint allows 'platform_contract'
--      along with all existing and registration document types.
--   2. Ensures RLS policies on `physiotherapist_documents` allow authenticated
--      physiotherapists to select, insert, and update their own documents.
--   3. Ensures `physiotherapist_profiles` has all required review and contract columns.
--   4. Ensures `bookings` has `physio_id` and RLS policy allows physiotherapists
--      to view their own assigned sessions.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. إصلاح CHECK Constraint لجدول physiotherapist_documents
-- ---------------------------------------------------------------------------
-- إسقاط القيد الحالي أياً كان اسمه لضمان عدم حدوث تعارض
DO $$
DECLARE
  con_record RECORD;
BEGIN
  FOR con_record IN
    SELECT constraint_name
    FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name = 'physiotherapist_documents'
      AND constraint_type = 'CHECK'
      AND (
        constraint_name LIKE '%document_type%'
        OR constraint_name = 'physiotherapist_documents_document_type_check'
      )
  LOOP
    EXECUTE format('ALTER TABLE public.physiotherapist_documents DROP CONSTRAINT IF EXISTS %I', con_record.constraint_name);
  END LOOP;
END $$;

-- إعادة إضافة القيد متضمناً جميع الأنواع القديمة + عقد المنصة
ALTER TABLE public.physiotherapist_documents
  ADD CONSTRAINT physiotherapist_documents_document_type_check
  CHECK (
    document_type IN (
      'national_id',        -- بطاقة الرقم القومي (الوجهين أو مجمعة)
      'national_id_front',  -- بطاقة الرقم القومي (الوجه الأمامي)
      'national_id_back',   -- بطاقة الرقم القومي (الوجه الخلفي)
      'syndicate_card',     -- كارنيه نقابة العلاج الطبيعي
      'practice_license',   -- ترخيص مزاولة المهنة
      'qualification_cert', -- شهادة التخرج / المؤهل الدراسي
      'experience_cert',    -- شهادة خبرة إضافية (إن وجدت)
      'platform_contract'   -- عقد المنصة الرسمي الموقع
    )
  );

-- التأكد من وجود عمود updated_at
ALTER TABLE public.physiotherapist_documents
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- ---------------------------------------------------------------------------
-- 2. ضبط سياسات RLS لجدول physiotherapist_documents
-- ---------------------------------------------------------------------------
ALTER TABLE public.physiotherapist_documents ENABLE ROW LEVEL SECURITY;

-- السماح للأخصائي بقراءة مستنداته وللإدارة بقراءة كل المستندات
DROP POLICY IF EXISTS "v14_physio_documents_select" ON public.physiotherapist_documents;
DROP POLICY IF EXISTS "physio_documents_select_policy" ON public.physiotherapist_documents;
CREATE POLICY "v14_physio_documents_select"
ON public.physiotherapist_documents FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physiotherapist_documents.physio_id AND pp.user_id = auth.uid()
  )
);

-- السماح للأخصائي بإدراج مستند جديد بحالة pending فقط
DROP POLICY IF EXISTS "v14_physio_documents_insert" ON public.physiotherapist_documents;
DROP POLICY IF EXISTS "physio_documents_insert_policy" ON public.physiotherapist_documents;
CREATE POLICY "v14_physio_documents_insert"
ON public.physiotherapist_documents FOR INSERT TO authenticated
WITH CHECK (
  review_status = 'pending'
  AND reviewed_by IS NULL
  AND reviewed_at IS NULL
  AND EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physiotherapist_documents.physio_id AND pp.user_id = auth.uid()
  )
);

-- السماح للأخصائي والإدارة بتحديث المستندات
DROP POLICY IF EXISTS "v14_physio_documents_update" ON public.physiotherapist_documents;
DROP POLICY IF EXISTS "physio_documents_update_policy" ON public.physiotherapist_documents;
CREATE POLICY "v14_physio_documents_update"
ON public.physiotherapist_documents FOR UPDATE TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physiotherapist_documents.physio_id AND pp.user_id = auth.uid()
  )
)
WITH CHECK (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physiotherapist_documents.physio_id AND pp.user_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- 3. دالة Trigger حماية تعديلات المستندات
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_guard_physio_document_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- إذا كان المعدل مسؤولاً (Admin) يُسمح له بتغيير الحالة وسبب الرفض
  IF public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- التأكد من أن الأخصائي يملك المستند
  IF NOT EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = OLD.physio_id AND pp.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'غير مصرح بتعديل هذا المستند.';
  END IF;

  -- عند استبدال الأخصائي للملف: إعادة ضبط حالة المراجعة تلقائياً إلى pending ومسح سبب الرفض القديم
  NEW.review_status := 'pending';
  NEW.rejection_reason := NULL;
  NEW.reviewed_by := NULL;
  NEW.reviewed_at := NULL;
  NEW.physio_id := OLD.physio_id;
  NEW.document_type := OLD.document_type;
  NEW.created_at := now();
  NEW.updated_at := now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_physio_document_update ON public.physiotherapist_documents;
CREATE TRIGGER trg_guard_physio_document_update
BEFORE UPDATE ON public.physiotherapist_documents
FOR EACH ROW EXECUTE FUNCTION public.trg_guard_physio_document_update();

-- ---------------------------------------------------------------------------
-- 4. التأكد من أعمدة جدول الحجوزات وسياسة قراءة الأخصائي لجلساته
-- ---------------------------------------------------------------------------
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS physio_id uuid REFERENCES public.physiotherapist_profiles(id) ON DELETE RESTRICT;

-- إضافة سياسة اختيار جلسات الأخصائي دون التأثير على سياسات الممرضين أو المرضى
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'bookings'
      AND policyname = 'Physiotherapists can view assigned sessions'
  ) THEN
    CREATE POLICY "Physiotherapists can view assigned sessions"
      ON public.bookings FOR SELECT TO authenticated
      USING (
        physio_id IN (
          SELECT pp.id FROM public.physiotherapist_profiles pp WHERE pp.user_id = auth.uid()
        )
      );
  END IF;
END $$;

COMMIT;
