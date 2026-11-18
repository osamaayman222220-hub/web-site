-- ============================================================================
-- CareNest (رعاية) - V14 SAFE FOUNDATION
-- Schema-only migration for physiotherapy, reserved appointment windows,
-- actual visit timestamps, medical-supplies requests, and provider-aware reviews.
--
-- IMPORTANT:
-- This is intentionally a SAFE FOUNDATION migration, not the final activation
-- of physiotherapy bookings. It does NOT replace or disable existing nurse
-- triggers/functions, wallet logic, visit-code RPCs, or storage policies.
-- Existing nurse booking flow is preserved.
--
-- Do NOT enable physiotherapy bookings in the website until the separate
-- provider-aware booking/acceptance/commission/visit-code/RLS migration is
-- installed and tested. The current bookings_before_insert(),
-- prevent_nurse_double_booking(), protect_booking_updates(),
-- record_booking_commission(), and verify_visit_code_atomic() are nurse-only.
--
-- Scheduling model:
--   reserved_start_at / reserved_end_at = calendar time blocked for booking.
--   actual_started_at / actual_ended_at = actual clinical visit timestamps.
-- No duration_minutes or 60-minute fallback is used to invent a visit length.
-- A future overlap-prevention trigger must require an explicit reserved end.
--
-- Run once in Supabase SQL Editor only after a database backup. Transaction rolls back on any error.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Preflight: verify the live tables/columns this migration relies on.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.profiles') IS NULL THEN
    missing := array_append(missing, 'public.profiles');
  END IF;
  IF to_regclass('public.bookings') IS NULL THEN
    missing := array_append(missing, 'public.bookings');
  END IF;
  IF to_regclass('public.reviews') IS NULL THEN
    missing := array_append(missing, 'public.reviews');
  END IF;
  IF to_regclass('public.nurse_profiles') IS NULL THEN
    missing := array_append(missing, 'public.nurse_profiles');
  END IF;
  IF to_regclass('public.services') IS NULL THEN
    missing := array_append(missing, 'public.services');
  END IF;

  IF cardinality(missing) > 0 THEN
    RAISE EXCEPTION 'CareNest V14 preflight failed. Missing tables: %',
      array_to_string(missing, ', ');
  END IF;

  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'CareNest V14 preflight failed: public.is_admin() is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='profiles' AND column_name='id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='profiles' AND column_name='role'
  ) THEN
    RAISE EXCEPTION 'CareNest V14 preflight failed: profiles.id/role are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='patient_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='nurse_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='visit_date'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='start_time'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='end_time'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='status'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bookings' AND column_name='price'
  ) THEN
    RAISE EXCEPTION 'CareNest V14 preflight failed: expected bookings columns are missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='reviews' AND column_name='booking_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='reviews' AND column_name='nurse_id'
  ) THEN
    RAISE EXCEPTION 'CareNest V14 preflight failed: reviews.booking_id/nurse_id are required.';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Profile location fields and physiotherapist role.
-- Do not drop/recreate an unknown role constraint. Add a separate compatible
-- constraint after discovering any existing role CHECK constraints.
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text;

DO $$
DECLARE
  c record;
  has_physio boolean := false;
BEGIN
  -- The known live constraint is profiles_role_check. Replace only that
  -- exact constraint; stop if an additional role CHECK is present.
  FOR c IN
    SELECT conname, pg_get_constraintdef(oid) AS definition
    FROM pg_constraint
    WHERE conrelid='public.profiles'::regclass
      AND contype='c'
      AND pg_get_constraintdef(oid) ILIKE '%role%'
  LOOP
    IF c.conname = 'profiles_role_check' THEN
      IF lower(c.definition) LIKE '%physiotherapist%' THEN
        has_physio := true;
      END IF;
    ELSIF lower(c.definition) NOT LIKE '%physiotherapist%' THEN
      RAISE EXCEPTION
        'Cannot safely extend roles: additional constraint "%" also restricts profiles.role. Review it before retrying.',
        c.conname;
    ELSE
      has_physio := true;
    END IF;
  END LOOP;

  IF NOT has_physio THEN
    ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_role_check
      CHECK (role IN ('patient','nurse','admin','physiotherapist'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Independent physiotherapist profiles.
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

-- Protect approval, identity, pricing and activation fields from self-editing.
-- Profile owners may edit only their descriptive profile fields; admins alone
-- may change verification, activation, contract review and pricing fields.
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

-- A newly registered provider must never self-approve during INSERT.
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
-- 3. Separate physiotherapist document metadata.
-- Actual file access must be implemented with carefully scoped Storage
-- policies in the activation migration; do not assume table RLS secures files.
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
-- 4. Additive booking columns only. Do not make nurse_id nullable yet:
-- current nurse triggers assume nurse_id is present.
-- ---------------------------------------------------------------------------
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS provider_type text NOT NULL DEFAULT 'nurse',
  ADD COLUMN IF NOT EXISTS physio_id uuid
    REFERENCES public.physiotherapist_profiles(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS governorate text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS medical_supplies_choice text,
  ADD COLUMN IF NOT EXISTS reserved_start_at timestamptz,
  ADD COLUMN IF NOT EXISTS reserved_end_at timestamptz,
  ADD COLUMN IF NOT EXISTS actual_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS actual_ended_at timestamptz;

-- Validate existing records without forcing historical data to be rewritten.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.bookings'::regclass
      AND conname='v14_booking_provider_type_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT v14_booking_provider_type_check
      CHECK (provider_type IN ('nurse','physiotherapist')) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.bookings'::regclass
      AND conname='v14_booking_supplies_choice_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT v14_booking_supplies_choice_check
      CHECK (
        medical_supplies_choice IS NULL
        OR medical_supplies_choice IN ('patient_has_supplies','provider_brings_supplies')
      ) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.bookings'::regclass
      AND conname='v14_booking_provider_identity_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT v14_booking_provider_identity_check
      CHECK (
        (provider_type='nurse' AND nurse_id IS NOT NULL AND physio_id IS NULL)
        OR
        (provider_type='physiotherapist' AND nurse_id IS NULL AND physio_id IS NOT NULL)
      ) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.bookings'::regclass
      AND conname='v14_booking_reserved_window_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT v14_booking_reserved_window_check
      CHECK (
        (reserved_start_at IS NULL AND reserved_end_at IS NULL)
        OR
        (reserved_start_at IS NOT NULL
         AND reserved_end_at IS NOT NULL
         AND reserved_end_at > reserved_start_at)
      ) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.bookings'::regclass
      AND conname='v14_booking_actual_visit_window_check'
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT v14_booking_actual_visit_window_check
      CHECK (
        (actual_started_at IS NULL AND actual_ended_at IS NULL)
        OR
        (actual_started_at IS NOT NULL
         AND (actual_ended_at IS NULL OR actual_ended_at >= actual_started_at))
      ) NOT VALID;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_v14_bookings_physio_status
  ON public.bookings(physio_id, status, visit_date)
  WHERE physio_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_v14_bookings_reserved_window
  ON public.bookings(reserved_start_at, reserved_end_at)
  WHERE status IN ('accepted','in_progress');

-- ---------------------------------------------------------------------------
-- 5. Medical supplies request ledger. This is deliberately isolated from
-- financial_transactions, nurse_wallets, commission and booking.price.
-- The activation migration must add strict transition RPCs before UI writes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.medical_supplies_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE RESTRICT,
  patient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  provider_type text NOT NULL CHECK (provider_type IN ('nurse','physiotherapist')),
  provider_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','approved','rejected','purchased','cancelled')),
  items jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(items)='array'),
  proposed_total numeric(10,2) NOT NULL DEFAULT 0
    CHECK (proposed_total >= 0),
  approved_total numeric(10,2),
  actual_total numeric(10,2),
  patient_approved_at timestamptz,
  purchased_at timestamptz,
  receipt_storage_path text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (approved_total IS NULL OR approved_total >= 0),
  CHECK (actual_total IS NULL OR actual_total >= 0),
  CHECK (
    status NOT IN ('approved','purchased')
    OR (approved_total IS NOT NULL AND patient_approved_at IS NOT NULL)
  ),
  CHECK (
    status <> 'purchased'
    OR (actual_total IS NOT NULL AND purchased_at IS NOT NULL AND receipt_storage_path IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_medical_supplies_booking
  ON public.medical_supplies_requests(booking_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_medical_supplies_patient
  ON public.medical_supplies_requests(patient_id, created_at DESC);

ALTER TABLE public.medical_supplies_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS v14_supplies_select ON public.medical_supplies_requests;
CREATE POLICY v14_supplies_select
ON public.medical_supplies_requests FOR SELECT TO authenticated
USING (
  patient_id = auth.uid()
  OR public.is_admin()
  OR (
    provider_type='nurse'
    AND EXISTS (
      SELECT 1 FROM public.nurse_profiles np
      WHERE np.id=provider_id AND np.user_id=auth.uid()
    )
  )
  OR (
    provider_type='physiotherapist'
    AND EXISTS (
      SELECT 1 FROM public.physiotherapist_profiles pp
      WHERE pp.id=provider_id AND pp.user_id=auth.uid()
    )
  )
);

-- No direct INSERT/UPDATE/DELETE policy is created intentionally.
-- Writes must go through validated SECURITY DEFINER RPCs in the activation
-- migration so the patient cannot silently approve altered prices/items.

-- ---------------------------------------------------------------------------
-- 6. Reviews: add physio reference without changing nurse_id nullability yet.
-- Existing nurse review insert policies and legacy data remain intact.
-- ---------------------------------------------------------------------------
ALTER TABLE public.reviews
  ADD COLUMN IF NOT EXISTS physio_id uuid
    REFERENCES public.physiotherapist_profiles(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_reviews_physio
  ON public.reviews(physio_id)
  WHERE physio_id IS NOT NULL;

-- The nurse_id NOT NULL constraint is intentionally preserved in this
-- foundation. A later activation migration will safely alter it after
-- installing provider-aware review policies and RPCs.

-- ---------------------------------------------------------------------------
-- 7. Service catalog metadata. Add columns only; do not assume descriptions
-- are required and do not overwrite existing nursing services/prices.
-- ---------------------------------------------------------------------------
ALTER TABLE public.services
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS provider_type text NOT NULL DEFAULT 'nurse',
  ADD COLUMN IF NOT EXISTS price_type text NOT NULL DEFAULT 'fixed',
  ADD COLUMN IF NOT EXISTS migration_source text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.services'::regclass
      AND conname='v14_services_provider_type_check'
  ) THEN
    ALTER TABLE public.services
      ADD CONSTRAINT v14_services_provider_type_check
      CHECK (provider_type IN ('nurse','physiotherapist','both')) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.services'::regclass
      AND conname='v14_services_price_type_check'
  ) THEN
    ALTER TABLE public.services
      ADD CONSTRAINT v14_services_price_type_check
      CHECK (price_type IN ('fixed','custom_quote')) NOT VALID;
  END IF;
END $$;

-- No service rows are inserted in this foundation. This avoids assuming
-- whether the live services.duration_minutes column is nullable/required and
-- prevents a catalog duration from being mistaken for a clinical appointment
-- duration. Physiotherapy services are added during the activation migration.
COMMIT;

-- ============================================================================
-- POST-RUN VERIFICATION (run separately after successful COMMIT)
-- ============================================================================
-- SELECT column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema='public' AND table_name='bookings'
--   AND column_name IN ('provider_type','physio_id','reserved_start_at',
--                       'reserved_end_at','actual_started_at','actual_ended_at')
-- ORDER BY column_name;
--
-- SELECT role FROM public.profiles GROUP BY role ORDER BY role;
-- SELECT provider_type, count(*) FROM public.services GROUP BY provider_type;
-- SELECT count(*) AS physiotherapist_profiles FROM public.physiotherapist_profiles;
--
-- THIS FOUNDATION DOES NOT YET ENABLE PHYSIOTHERAPY BOOKING CREATION.
-- Keep the current site on nurse-only bookings until the activation migration
-- has been prepared, reviewed, and tested.
