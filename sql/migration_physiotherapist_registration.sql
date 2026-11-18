-- ============================================================================
-- CareNest (رعاية) - Migration: Independent Physiotherapist Registration
-- File: sql/migration_physiotherapist_registration.sql
--
-- Description:
--   Enables independent registration for physiotherapists ('physiotherapist'):
--   1. Safely updates profiles_role_check to allow 'physiotherapist'.
--   2. Updates trg_enforce_profile_role_security() on public.profiles to permit 'physiotherapist'.
--   3. Updates public.handle_new_user() trigger on auth.users to:
--      - Permit 'physiotherapist' role.
--      - Auto-create independent physiotherapist_profiles record with pending/unverified state.
--      - Strictly skip nurse_profiles for physiotherapists.
--      - Preserve existing patient and nurse registration logic 100% unchanged.
--   4. Ensures physiotherapist_profiles and physiotherapist_documents tables exist with RLS.
--   5. Configures Storage RLS policies on 'private-docs' for physiotherapist document uploads.
--
-- Zero Breaking Changes:
--   - Does NOT touch migration_v12 double booking locks or triggers.
--   - Does NOT touch nurse_wallets, commissions, bookings, or financial systems.
--   - Does NOT alter existing nurse or patient records.
--
-- Safe Execution:
--   Run in Supabase SQL Editor. Rolls back on any error.
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
  IF to_regclass('public.nurse_profiles') IS NULL THEN
    v_missing := array_append(v_missing, 'public.nurse_profiles');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Preflight failed: Missing required tables: %', array_to_string(v_missing, ', ');
  END IF;

  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'Preflight failed: public.is_admin() function is missing.';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Safely Update profiles_role_check Constraint
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text;

DO $$
DECLARE
  c record;
  has_physio boolean := false;
BEGIN
  FOR c IN
    SELECT conname, pg_get_constraintdef(oid) AS definition
    FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%role%'
  LOOP
    IF c.conname = 'profiles_role_check' THEN
      IF lower(c.definition) LIKE '%physiotherapist%' THEN
        has_physio := true;
      END IF;
    ELSIF lower(c.definition) NOT LIKE '%physiotherapist%' THEN
      RAISE EXCEPTION
        'Cannot safely extend roles: additional constraint "%" also restricts profiles.role.',
        c.conname;
    ELSE
      has_physio := true;
    END IF;
  END LOOP;

  IF NOT has_physio THEN
    ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_role_check
      CHECK (role IN ('patient', 'nurse', 'admin', 'physiotherapist'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Update trg_enforce_profile_role_security() on public.profiles
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_enforce_profile_role_security()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_role text;
  v_is_authorized boolean := false;
BEGIN
  v_caller_role := COALESCE(
    current_setting('request.jwt.claim.role', true),
    auth.role()
  );

  v_is_authorized := (
    public.is_admin()
    OR v_caller_role = 'service_role'
    OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL)
  );

  IF TG_OP = 'INSERT' THEN
    -- Allow patient, nurse, or physiotherapist during public sign-up
    IF NOT v_is_authorized THEN
      IF NEW.role IS NULL OR NEW.role NOT IN ('patient', 'nurse', 'physiotherapist') THEN
        NEW.role := 'patient';
      END IF;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- Immutable Account Identity: block changing profile id
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل المعرف الأساسي للحساب (id)';
    END IF;

    -- Role modification restricted to authorized administrators
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF NOT v_is_authorized THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل صلاحيات المستخدم أو الترقية لدور مدير إلا بواسطة إدارة النظام';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_profile_role_security_trg ON public.profiles;
CREATE TRIGGER enforce_profile_role_security_trg
BEFORE INSERT OR UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_profile_role_security();

-- ---------------------------------------------------------------------------
-- 4. Ensure Independent physiotherapist_profiles Table Exists
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.physiotherapist_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  specialization text NOT NULL DEFAULT 'العلاج الطبيعي والتأهيل',
  qualifications text,
  license_number text,
  experience_years integer NOT NULL DEFAULT 0
    CHECK (experience_years >= 0),
  session_price numeric(10,2) NOT NULL DEFAULT 0
    CHECK (session_price >= 0),
  governorate text,
  city text,
  bio text,
  verified boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT false,
  accepting_bookings boolean NOT NULL DEFAULT false,
  verification_status text NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending','approved','rejected')),
  contract_status text NOT NULL DEFAULT 'pending'
    CHECK (contract_status IN ('draft','pending','approved','rejected')),
  contract_rejection_reason text,
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_physio_profiles_location
  ON public.physiotherapist_profiles(governorate, city);
CREATE INDEX IF NOT EXISTS idx_physio_profiles_public
  ON public.physiotherapist_profiles(verified, is_active, verification_status, contract_status, accepting_bookings);

-- Prevent unauthorized self-modification of verification / status
CREATE OR REPLACE FUNCTION public.v14_guard_physio_profile_changes()
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

  IF auth.uid() IS NULL OR OLD.user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to modify this physiotherapist profile.';
  END IF;

  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.verified IS DISTINCT FROM OLD.verified
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.accepting_bookings IS DISTINCT FROM OLD.accepting_bookings
     OR NEW.verification_status IS DISTINCT FROM OLD.verification_status
     OR NEW.contract_status IS DISTINCT FROM OLD.contract_status
     OR NEW.contract_rejection_reason IS DISTINCT FROM OLD.contract_rejection_reason
     OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.session_price IS DISTINCT FROM OLD.session_price THEN
    RAISE EXCEPTION 'Only an administrator can change verification, activation, contract review, or session price.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_v14_guard_physio_profile_changes ON public.physiotherapist_profiles;
CREATE TRIGGER trg_v14_guard_physio_profile_changes
BEFORE UPDATE ON public.physiotherapist_profiles
FOR EACH ROW EXECUTE FUNCTION public.v14_guard_physio_profile_changes();

-- Prevent self-approval during INSERT
CREATE OR REPLACE FUNCTION public.v14_guard_physio_profile_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NULL OR NEW.user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to create this physiotherapist profile.';
  END IF;
  NEW.verified := false;
  NEW.is_active := false;
  NEW.accepting_bookings := false;
  NEW.verification_status := 'pending';
  NEW.contract_status := 'pending';
  NEW.contract_rejection_reason := NULL;
  NEW.rejection_reason := NULL;
  NEW.reviewed_by := NULL;
  NEW.reviewed_at := NULL;
  NEW.session_price := 0;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_v14_guard_physio_profile_insert ON public.physiotherapist_profiles;
CREATE TRIGGER trg_v14_guard_physio_profile_insert
BEFORE INSERT ON public.physiotherapist_profiles
FOR EACH ROW EXECUTE FUNCTION public.v14_guard_physio_profile_insert();

ALTER TABLE public.physiotherapist_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS v14_physio_profiles_select ON public.physiotherapist_profiles;
CREATE POLICY v14_physio_profiles_select
ON public.physiotherapist_profiles FOR SELECT TO anon, authenticated
USING (
  (verified = true AND is_active = true
   AND verification_status = 'approved'
   AND contract_status = 'approved'
   AND accepting_bookings = true)
  OR user_id = auth.uid()
  OR public.is_admin()
);

DROP POLICY IF EXISTS v14_physio_profiles_insert ON public.physiotherapist_profiles;
CREATE POLICY v14_physio_profiles_insert
ON public.physiotherapist_profiles FOR INSERT TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'physiotherapist'
  )
);

DROP POLICY IF EXISTS v14_physio_profiles_update ON public.physiotherapist_profiles;
CREATE POLICY v14_physio_profiles_update
ON public.physiotherapist_profiles FOR UPDATE TO authenticated
USING (user_id = auth.uid() OR public.is_admin())
WITH CHECK (user_id = auth.uid() OR public.is_admin());

-- ---------------------------------------------------------------------------
-- 5. Ensure Independent physiotherapist_documents Table Exists
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.physiotherapist_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physio_id uuid NOT NULL
    REFERENCES public.physiotherapist_profiles(id) ON DELETE CASCADE,
  document_type text NOT NULL,
  storage_path text NOT NULL,
  review_status text NOT NULL DEFAULT 'pending'
    CHECK (review_status IN ('pending','approved','rejected')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (storage_path)
);

CREATE INDEX IF NOT EXISTS idx_physio_documents_profile
  ON public.physiotherapist_documents(physio_id, created_at DESC);

ALTER TABLE public.physiotherapist_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS v14_physio_documents_select ON public.physiotherapist_documents;
CREATE POLICY v14_physio_documents_select
ON public.physiotherapist_documents FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physio_id AND pp.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS v14_physio_documents_insert ON public.physiotherapist_documents;
CREATE POLICY v14_physio_documents_insert
ON public.physiotherapist_documents FOR INSERT TO authenticated
WITH CHECK (
  review_status = 'pending'
  AND reviewed_by IS NULL
  AND reviewed_at IS NULL
  AND EXISTS (
    SELECT 1 FROM public.physiotherapist_profiles pp
    WHERE pp.id = physio_id AND pp.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS v14_physio_documents_update ON public.physiotherapist_documents;
CREATE POLICY v14_physio_documents_update
ON public.physiotherapist_documents FOR UPDATE TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS v14_physio_documents_delete ON public.physiotherapist_documents;
CREATE POLICY v14_physio_documents_delete
ON public.physiotherapist_documents FOR DELETE TO authenticated
USING (public.is_admin());

-- ---------------------------------------------------------------------------
-- 6. Update handle_new_user() on auth.users
-- ---------------------------------------------------------------------------
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
  v_spec text;
  v_qual text;
  v_exp_yrs integer;
  v_lic text;
BEGIN
  -- Strict role filtering: allow patient, nurse, or physiotherapist
  user_role := COALESCE(new.raw_user_meta_data->>'role', 'patient');
  IF user_role NOT IN ('patient', 'nurse', 'physiotherapist') THEN
    user_role := 'patient';
  END IF;

  full_name := COALESCE(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1));
  phone_num := new.raw_user_meta_data->>'phone';
  user_gov  := COALESCE(new.raw_user_meta_data->>'governorate', 'القاهرة');
  user_city := COALESCE(new.raw_user_meta_data->>'city', 'القاهرة');
  user_addr := new.raw_user_meta_data->>'address';

  -- Upsert base profile
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

  -- 1) NURSE REGISTRATION FLOW (100% PRESERVED AND UNCHANGED)
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
      'not_uploaded',
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

  -- 2) PHYSIOTHERAPIST REGISTRATION FLOW (INDEPENDENT - NEVER TOUCHES nurse_profiles)
  IF user_role = 'physiotherapist' THEN
    v_spec := COALESCE(NULLIF(TRIM(new.raw_user_meta_data->>'specialization'), ''), 'العلاج الطبيعي والتأهيل');
    v_qual := NULLIF(TRIM(new.raw_user_meta_data->>'qualifications'), '');
    v_lic  := NULLIF(TRIM(new.raw_user_meta_data->>'license_number'), '');
    BEGIN
      v_exp_yrs := COALESCE((new.raw_user_meta_data->>'experience_years')::integer, 0);
      IF v_exp_yrs < 0 THEN v_exp_yrs := 0; END IF;
    EXCEPTION WHEN OTHERS THEN
      v_exp_yrs := 0;
    END;

    INSERT INTO public.physiotherapist_profiles (
      user_id,
      specialization,
      qualifications,
      experience_years,
      license_number,
      governorate,
      city,
      verified,
      is_active,
      accepting_bookings,
      verification_status,
      contract_status,
      session_price
    ) VALUES (
      new.id,
      v_spec,
      v_qual,
      v_exp_yrs,
      v_lic,
      user_gov,
      user_city,
      false,
      false,
      false,
      'pending',
      'pending',
      0
    )
    ON CONFLICT (user_id) DO NOTHING;
  END IF;

  RETURN new;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- 7. Storage RLS Policies for private-docs (Physiotherapist Verification Docs)
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('private-docs', 'private-docs', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "Physiotherapists can upload verification docs" ON storage.objects;
CREATE POLICY "Physiotherapists can upload verification docs"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'private-docs'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Physiotherapists and admins read verification docs" ON storage.objects;
CREATE POLICY "Physiotherapists and admins read verification docs"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'private-docs'
    AND (
      (storage.foldername(name))[1] = auth.uid()::text
      OR public.is_admin()
    )
  );

COMMIT;
