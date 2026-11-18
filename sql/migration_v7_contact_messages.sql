-- ============================================================================
-- CareNest (رعاية) - Migration v7: Contact Messages Table with Anti-Spam & RLS
-- File: sql/migration_v7_contact_messages.sql
-- Description:
--   1. Create public.contact_messages table for the homepage inquiry form
--   2. Strict validation and anti-spam constraints (rate & length limits)
--   3. Row Level Security:
--      - Anyone (anon and authenticated) can INSERT valid contact messages
--      - Only admins (public.is_admin() = true) can SELECT, UPDATE, or DELETE messages
--      - Public and regular users CANNOT read, update, or delete any messages
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.contact_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_name text NOT NULL,
  sender_phone text NOT NULL,
  sender_email text,
  subject text NOT NULL DEFAULT 'inquiry',
  message text NOT NULL,
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'read', 'replied', 'archived')),
  admin_notes text,
  replied_by uuid REFERENCES public.profiles(id),
  replied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- Anti-Spam Constraints: Minimum and Maximum length guards
  CONSTRAINT chk_contact_name_len CHECK (char_length(trim(sender_name)) BETWEEN 3 AND 100),
  CONSTRAINT chk_contact_phone_len CHECK (char_length(trim(sender_phone)) BETWEEN 10 AND 20),
  CONSTRAINT chk_contact_message_len CHECK (char_length(trim(message)) BETWEEN 10 AND 2000)
);

-- Index for admin sorting and filtering by status and date
CREATE INDEX IF NOT EXISTS idx_contact_messages_created_at ON public.contact_messages (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_contact_messages_status ON public.contact_messages (status);

-- Enable Row Level Security
ALTER TABLE public.contact_messages ENABLE ROW LEVEL SECURITY;

-- 1. INSERT Policy: Allow anyone (anon & authenticated visitors) to send messages
DROP POLICY IF EXISTS "Public visitors can insert contact messages" ON public.contact_messages;
CREATE POLICY "Public visitors can insert contact messages"
  ON public.contact_messages FOR INSERT
  WITH CHECK (
    char_length(trim(sender_name)) >= 3
    AND char_length(trim(sender_phone)) >= 10
    AND char_length(trim(message)) >= 10
    AND (status = 'new' OR status IS NULL)
  );

-- 2. SELECT Policy: Only system admins can view contact messages
DROP POLICY IF EXISTS "Admins can view contact messages" ON public.contact_messages;
CREATE POLICY "Admins can view contact messages"
  ON public.contact_messages FOR SELECT
  USING (public.is_admin());

-- 3. UPDATE Policy: Only system admins can update contact messages (change status, add notes)
DROP POLICY IF EXISTS "Admins can update contact messages" ON public.contact_messages;
CREATE POLICY "Admins can update contact messages"
  ON public.contact_messages FOR UPDATE
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 4. DELETE Policy: Only system admins can delete contact messages
DROP POLICY IF EXISTS "Admins can delete contact messages" ON public.contact_messages;
CREATE POLICY "Admins can delete contact messages"
  ON public.contact_messages FOR DELETE
  USING (public.is_admin());

-- Anti-Spam Trigger: Prevent repeated flooding from the same phone number within 60 seconds
CREATE OR REPLACE FUNCTION public.trg_check_contact_spam_flood()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Trim all text fields
  NEW.sender_name  := trim(NEW.sender_name);
  NEW.sender_phone := trim(NEW.sender_phone);
  NEW.message      := trim(NEW.message);
  NEW.status       := 'new';

  -- Check for duplicate submission with the same phone in the last 60 seconds
  IF EXISTS (
    SELECT 1 FROM public.contact_messages
    WHERE sender_phone = NEW.sender_phone
      AND created_at > (now() - interval '60 seconds')
  ) THEN
    RAISE EXCEPTION 'يرجى الانتظار دقيقة واحدة قبل إرسال استفسار جديد لمنع التكرار';
  END IF;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_contact_spam_flood_guard ON public.contact_messages;
CREATE TRIGGER trg_contact_spam_flood_guard
BEFORE INSERT ON public.contact_messages
FOR EACH ROW
EXECUTE FUNCTION public.trg_check_contact_spam_flood();

ALTER FUNCTION public.trg_check_contact_spam_flood() OWNER TO postgres;

