-- ============================================================================
-- CareNest (رعاية) - Migration: Physiotherapist Admin Lifecycle & Contracts
-- File: sql/migration_physiotherapist_admin_management.sql
--
-- Description:
--   Establishes full administrative management for physiotherapists:
--   1. Independent physiotherapist_contracts table.
--   2. Strict RLS policies for physiotherapist documents, contracts, and profiles.
--   3. Secure Storage RLS policies for private-docs (verification & contracts).
--   4. Server-side RPC functions for contract submission, contract review, and profile verification.
--   5. Hardened triggers to prevent provider self-approval or tampering with review statuses.
--
-- Zero Breaking Changes:
--   - Does NOT touch nurse_profiles, nurse_contracts, or nurse_documents.
--   - Does NOT modify migration_v12 double-booking locks.
--   - Does NOT modify wallets, financial systems, or booking rules.
--
-- Safe Execution:
--   Run in Supabase SQL Editor. Wrapped in BEGIN...COMMIT transaction.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Preflight Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.profiles') IS NULL THEN
    v_missing := array_append(v_missing, 'public.profiles');
  END IF;
  IF to_regclass('public.physiotherapist_profiles') IS NULL THEN
    v_missing := array_append(v_missing, 'public.physiotherapist_profiles');
  END IF;
  IF to_regclass('public.physiotherapist_documents') IS NULL THEN
    v_missing := array_append(v_missing, 'public.physiotherapist_documents');
  END IF;
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    v_missing := array_append(v_missing, 'public.is_admin()');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'CareNest Physiotherapist Admin Preflight failed. Missing dependencies: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Extend contract_status Constraint on physiotherapist_profiles
-- ---------------------------------------------------------------------------
ALTER TABLE public.physiotherapist_profiles
  ADD COLUMN IF NOT EXISTS contract_reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS contract_reviewed_at timestamptz;

DO $$
BEGIN
  ALTER TABLE public.physiotherapist_profiles
    DROP CONSTRAINT IF EXISTS physiotherapist_profiles_contract_status_check;

  ALTER TABLE public.physiotherapist_profiles
    ADD CONSTRAINT physiotherapist_profiles_contract_status_check
    CHECK (contract_status IN ('not_uploaded', 'draft', 'pending', 'pending_review', 'approved', 'rejected'));
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Dedicated physiotherapist_contracts Table (Strictly Sovereign)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.physiotherapist_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physio_id uuid NOT NULL REFERENCES public.physiotherapist_profiles(id) ON DELETE CASCADE,
  physio_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  file_path text,
  file_name text NOT NULL,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('not_uploaded', 'pending_review', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_physio_contracts_user
  ON public.physiotherapist_contracts(physio_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_physio_contracts_status
  ON public.physiotherapist_contracts(status);

ALTER TABLE public.physiotherapist_contracts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Physiotherapists can view own contracts" ON public.physiotherapist_contracts;
CREATE POLICY "Physiotherapists can view own contracts"
  ON public.physiotherapist_contracts FOR SELECT TO authenticated
  USING (physio_user_id = auth.uid());

DROP POLICY IF EXISTS "Physiotherapists can submit own contracts" ON public.physiotherapist_contracts;
CREATE POLICY "Physiotherapists can submit own contracts"
  ON public.physiotherapist_contracts FOR INSERT TO authenticated
  WITH CHECK (
    physio_user_id = auth.uid()
    AND status = 'pending_review'
    AND reviewed_by IS NULL
    AND reviewed_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.physiotherapist_profiles pp
      WHERE pp.id = physio_id AND pp.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Admins can view and manage all physio contracts" ON public.physiotherapist_contracts;
CREATE POLICY "Admins can view and manage all physio contracts"
  ON public.physiotherapist_contracts FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------------
-- 4. Document Update Guard & RLS for physiotherapist_documents
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_guard_physio_document_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- Ensure provider owns this document
  IF NOT EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = OLD.physio_id AND pp.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'غير مصرح بتعديل هذا المستند.';
  END IF;

  -- Provider can only replace the file: reset review state to pending
  NEW.review_status := 'pending';
  NEW.rejection_reason := NULL;
  NEW.reviewed_by := NULL;
  NEW.reviewed_at := NULL;
  NEW.physio_id := OLD.physio_id;
  NEW.document_type := OLD.document_type;
  NEW.created_at := now();

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  ALTER TABLE public.physiotherapist_documents
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DROP TRIGGER IF EXISTS trg_guard_physio_document_update ON public.physiotherapist_documents;
CREATE TRIGGER trg_guard_physio_document_update
BEFORE UPDATE ON public.physiotherapist_documents
FOR EACH ROW EXECUTE FUNCTION public.trg_guard_physio_document_update();

DROP POLICY IF EXISTS v14_physio_documents_update ON public.physiotherapist_documents;
CREATE POLICY v14_physio_documents_update
ON public.physiotherapist_documents FOR UPDATE TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physio_id AND pp.user_id = auth.uid()
  )
)
WITH CHECK (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physio_id AND pp.user_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- 5. Storage RLS Policies for private-docs (Physio Docs & Contracts)
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('private-docs', 'private-docs', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "Physiotherapists can upload verification docs" ON storage.objects;
CREATE POLICY "Physiotherapists can upload verification docs"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'private-docs'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR ((storage.foldername(name))[1] = 'contracts' AND (storage.foldername(name))[2] = auth.uid()::text)
    )
  );

DROP POLICY IF EXISTS "Physiotherapists and admins read verification docs" ON storage.objects;
CREATE POLICY "Physiotherapists and admins read verification docs"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'private-docs'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR ((storage.foldername(name))[1] = 'contracts' AND (storage.foldername(name))[2] = auth.uid()::text)
      OR public.is_admin()
    )
  );

-- ---------------------------------------------------------------------------
-- 6. RPC: submit_physiotherapist_contract
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_physiotherapist_contract(
  p_storage_path text,
  p_file_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_physio record;
  v_contract_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  IF p_storage_path IS NULL OR trim(p_storage_path) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار ملف العقد مطلوب');
  END IF;

  -- Validate path format: contracts/{userId}/... or {userId}/...
  IF NOT (
    p_storage_path LIKE 'contracts/' || v_user_id::text || '/%'
    OR p_storage_path LIKE v_user_id::text || '/%'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'مسار العقد غير صالح أو لا يتبع حسابك');
  END IF;

  -- Verify object exists in storage
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE bucket_id = 'private-docs' AND name = p_storage_path
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ملف العقد غير موجود في مساحة التخزين الخاصة');
  END IF;

  SELECT * INTO v_physio FROM public.physiotherapist_profiles WHERE user_id = v_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الملف المهني لأخصائي العلاج الطبيعي غير موجود');
  END IF;

  INSERT INTO public.physiotherapist_contracts (
    physio_id, physio_user_id, storage_path, file_path, file_name, status
  ) VALUES (
    v_physio.id,
    v_user_id,
    p_storage_path,
    p_storage_path,
    COALESCE(p_file_name, 'physio_signed_contract.pdf'),
    'pending_review'
  ) RETURNING id INTO v_contract_id;

  UPDATE public.physiotherapist_profiles
  SET 
    contract_status = 'pending_review',
    contract_rejection_reason = NULL,
    updated_at = now()
  WHERE id = v_physio.id;

  RETURN jsonb_build_object('success', true, 'contract_id', v_contract_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. RPC: admin_review_physiotherapist_contract
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_review_physiotherapist_contract(
  p_contract_id uuid,
  p_new_status text,
  p_rejection_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_contract record;
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'حالة المراجعة يجب أن تكون إما approved أو rejected');
  END IF;

  IF p_new_status = 'rejected' AND (p_rejection_reason IS NULL OR trim(p_rejection_reason) = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'سبب الرفض إلزامي عند رفض العقد');
  END IF;

  SELECT * INTO v_contract FROM public.physiotherapist_contracts WHERE id = p_contract_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'العقد غير موجود');
  END IF;

  -- Prevent approving older versions if a newer contract was uploaded
  IF EXISTS (
    SELECT 1 FROM public.physiotherapist_contracts
    WHERE physio_id = v_contract.physio_id
      AND created_at > v_contract.created_at
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن اعتماد أو مراجعة هذا العقد لوجود نسخة أحدث قام الأخصائي برفعها');
  END IF;

  UPDATE public.physiotherapist_contracts
  SET 
    status = p_new_status,
    rejection_reason = CASE WHEN p_new_status = 'rejected' THEN p_rejection_reason ELSE NULL END,
    reviewed_by = v_admin_id,
    reviewed_at = now(),
    updated_at = now()
  WHERE id = p_contract_id;

  UPDATE public.physiotherapist_profiles
  SET 
    contract_status = p_new_status,
    contract_reviewed_by = v_admin_id,
    contract_reviewed_at = now(),
    contract_rejection_reason = CASE WHEN p_new_status = 'rejected' THEN p_rejection_reason ELSE NULL END,
    updated_at = now()
  WHERE id = v_contract.physio_id;

  RETURN jsonb_build_object('success', true, 'status', p_new_status);
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. RPC: admin_update_physiotherapist_status
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_update_physiotherapist_status(
  p_physio_user_id uuid,
  p_action text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_physio record;
  v_unapproved_mandatory_count integer;
  v_contract_approved boolean;
BEGIN
  IF v_admin_id IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'غير مصرح: العملية تتطلب صلاحية مدير');
  END IF;

  IF p_action NOT IN ('approved', 'rejected', 'suspended', 'pending') THEN
    RETURN jsonb_build_object('success', false, 'error', 'إجراء غير صالح');
  END IF;

  SELECT * INTO v_physio
  FROM public.physiotherapist_profiles
  WHERE user_id = p_physio_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الملف المهني لأخصائي العلاج الطبيعي غير موجود');
  END IF;

  -- STRICT APPROVAL PREREQUISITES
  IF p_action = 'approved' THEN
    -- 1. Check mandatory documents: national_id, syndicate_card, practice_license, qualification_cert
    SELECT count(*) INTO v_unapproved_mandatory_count
    FROM (VALUES ('national_id'), ('syndicate_card'), ('practice_license'), ('qualification_cert')) AS m(doc_type)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.physiotherapist_documents pd
      WHERE pd.physio_id = v_physio.id
        AND pd.document_type = m.doc_type
        AND pd.review_status = 'approved'
    );

    IF v_unapproved_mandatory_count > 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'لا يمكن اعتماد الأخصائي قبل رفع واعتماد كافة المستندات الإلزامية (الرقم القومي، كارنيه النقابة، ترخيص مزاولة المهنة، والمؤهل الدراسي).'
      );
    END IF;

    -- 2. Check platform contract
    v_contract_approved := (v_physio.contract_status = 'approved');
    IF NOT v_contract_approved THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'لا يمكن اعتماد الأخصائي قبل مراجعة واعتماد عقد حماية المنصة الخاص به.'
      );
    END IF;

    -- Update to approved state
    UPDATE public.physiotherapist_profiles
    SET 
      verified = true,
      is_active = true,
      accepting_bookings = true,
      verification_status = 'approved',
      rejection_reason = NULL,
      reviewed_by = v_admin_id,
      reviewed_at = now(),
      updated_at = now()
    WHERE id = v_physio.id;

  ELSIF p_action = 'rejected' THEN
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'سبب الرفض إلزامي عند رفض الطلب');
    END IF;

    UPDATE public.physiotherapist_profiles
    SET 
      verified = false,
      is_active = false,
      accepting_bookings = false,
      verification_status = 'rejected',
      rejection_reason = p_reason,
      reviewed_by = v_admin_id,
      reviewed_at = now(),
      updated_at = now()
    WHERE id = v_physio.id;

  ELSIF p_action = 'suspended' THEN
    UPDATE public.physiotherapist_profiles
    SET 
      is_active = false,
      accepting_bookings = false,
      verification_status = 'suspended',
      updated_at = now()
    WHERE id = v_physio.id;

  ELSIF p_action = 'pending' THEN
    UPDATE public.physiotherapist_profiles
    SET 
      verified = false,
      is_active = false,
      accepting_bookings = false,
      verification_status = 'pending',
      updated_at = now()
    WHERE id = v_physio.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'action', p_action);
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Permissions & Execution Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.submit_physiotherapist_contract(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_review_physiotherapist_contract(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_physiotherapist_status(uuid, text, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.submit_physiotherapist_contract(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_physiotherapist_contract(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_physiotherapist_status(uuid, text, text) TO authenticated;

COMMIT;
