-- ============================================================================
-- CareNest (رعاية) — Migration v10: Chat System, Notifications & Admin Monitoring
-- File: supabase/migrations/20261111000000_chat_notifications_v10.sql
-- التاريخ: 2026-11-12
-- ============================================================================

-- 1. جدول محادثات الزيارات (booking_messages) والفهارس
CREATE TABLE IF NOT EXISTS public.booking_messages (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id  uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  sender_id   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  message     text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_booking_messages_booking_created 
  ON public.booking_messages(booking_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_booking_messages_sender_id 
  ON public.booking_messages(sender_id);

ALTER TABLE public.booking_messages ENABLE ROW LEVEL SECURITY;

-- 2. ضبط الصلاحيات (GRANT & REVOKE) لمنع التعديل والحذف تماماً
REVOKE ALL ON public.booking_messages FROM PUBLIC, anon;
REVOKE UPDATE, DELETE ON public.booking_messages FROM authenticated;
GRANT SELECT, INSERT ON public.booking_messages TO authenticated;
GRANT ALL ON public.booking_messages TO service_role;

-- 3. تنظيف أي سياسات سابقة والتأكد من عدم وجود أي ثغرة تجاوز
DROP POLICY IF EXISTS "Participants and admins can view booking messages" ON public.booking_messages;
DROP POLICY IF EXISTS "Participants can send booking messages" ON public.booking_messages;
DROP POLICY IF EXISTS "Admins can view all booking messages" ON public.booking_messages;
DROP POLICY IF EXISTS "Users can view booking messages" ON public.booking_messages;
DROP POLICY IF EXISTS "Users can insert booking messages" ON public.booking_messages;

-- أ. سياسة القراءة (SELECT):
CREATE POLICY "Participants and admins can view booking messages"
  ON public.booking_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_id
        AND (
          b.patient_id = auth.uid()
          OR b.nurse_id = auth.uid()
          OR EXISTS (
            SELECT 1 FROM public.nurse_profiles np
            WHERE (np.id = b.nurse_profile_id OR np.id = b.nurse_id)
              AND np.user_id = auth.uid()
          )
        )
    )
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
    OR auth.role() = 'service_role'
  );

-- ب. سياسة الإرسال (INSERT):
CREATE POLICY "Participants can send booking messages"
  ON public.booking_messages FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    -- 1. حظر قاطع لأي حساب مدير من إرسال رسائل
    AND NOT EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
    -- 2. التحقق الحصري من أن المرسل طرف فعلي في هذا الحجز
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_id
        AND (
          b.patient_id = auth.uid()
          OR b.nurse_id = auth.uid()
          OR EXISTS (
            SELECT 1 FROM public.nurse_profiles np
            WHERE (np.id = b.nurse_profile_id OR np.id = b.nurse_id)
              AND np.user_id = auth.uid()
          )
        )
    )
  );

-- 4. دالة Trigger: إرسال إشعار للطرف الآخر تلقائياً
CREATE OR REPLACE FUNCTION public.trg_notify_booking_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_booking       public.bookings;
  v_sender_name   text;
  v_recipient_id  uuid;
  v_msg_preview   text;
  v_notif_link    text;
BEGIN
  -- 1. جلب بيانات الحجز
  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = NEW.booking_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- 2. جلب اسم المرسل
  SELECT full_name INTO v_sender_name
  FROM public.profiles
  WHERE id = NEW.sender_id;

  v_sender_name := COALESCE(NULLIF(TRIM(v_sender_name), ''), 'مستخدم');

  -- 3. تحديد المستلم وفق البنية الفعلية للربط:
  -- أ) إذا أرسل المريض -> المستلم هو الممرض
  IF NEW.sender_id = v_booking.patient_id THEN
    IF v_booking.nurse_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = v_booking.nurse_id) THEN
      v_recipient_id := v_booking.nurse_id;
    ELSIF v_booking.nurse_id IS NOT NULL THEN
      SELECT user_id INTO v_recipient_id
      FROM public.nurse_profiles
      WHERE id = v_booking.nurse_id;
    END IF;

    IF v_recipient_id IS NULL AND v_booking.nurse_profile_id IS NOT NULL THEN
      SELECT user_id INTO v_recipient_id
      FROM public.nurse_profiles
      WHERE id = v_booking.nurse_profile_id;
    END IF;

  -- ب) إذا أرسل الممرض -> المستلم هو المريض
  ELSIF NEW.sender_id = v_booking.nurse_id
        OR EXISTS (
          SELECT 1 FROM public.nurse_profiles
          WHERE (id = v_booking.nurse_id OR id = v_booking.nurse_profile_id)
            AND user_id = NEW.sender_id
        ) THEN
    v_recipient_id := v_booking.patient_id;
  ELSE
    RETURN NEW;
  END IF;

  -- 4. تجنب إرسال إشعار للمرسل نفسه
  IF v_recipient_id IS NULL OR v_recipient_id = NEW.sender_id THEN
    RETURN NEW;
  END IF;

  -- 5. تجهيز المقتطف والرابط
  v_msg_preview := LEFT(NEW.message, 80);
  IF char_length(NEW.message) > 80 THEN
    v_msg_preview := v_msg_preview || '...';
  END IF;

  v_notif_link := 'booking:' || NEW.booking_id::text;

  -- 6. إدراج الإشعار الداخلي
  INSERT INTO public.notifications (
    user_id,
    title,
    message,
    type,
    link,
    is_read,
    created_at
  ) VALUES (
    v_recipient_id,
    'رسالة جديدة من ' || v_sender_name,
    v_msg_preview,
    'message',
    v_notif_link,
    false,
    now()
  );

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NEW;
END;
$$;

ALTER FUNCTION public.trg_notify_booking_message() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.trg_notify_booking_message() FROM PUBLIC, anon, authenticated;

-- تفعيل Trigger
DROP TRIGGER IF EXISTS on_booking_message_insert ON public.booking_messages;
CREATE TRIGGER on_booking_message_insert
  AFTER INSERT ON public.booking_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_notify_booking_message();

-- 5. دالة get_bookings_with_messages() للأدمن
CREATE OR REPLACE FUNCTION public.get_bookings_with_messages()
RETURNS TABLE (
  booking_id      uuid,
  patient_name    text,
  nurse_name      text,
  service_name    text,
  visit_date      date,
  status          text,
  message_count   bigint,
  last_message_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  ) AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'غير مصرح لك بهذه العملية: مخصصة لإدارة النظام فقط';
  END IF;

  RETURN QUERY
  SELECT
    b.id                                                                                            AS booking_id,
    COALESCE(NULLIF(TRIM(pat.full_name), ''), b.patient_name, 'مريض')                              AS patient_name,
    COALESCE(NULLIF(TRIM(nurse_prof.full_name), ''), NULLIF(TRIM(np_prof.full_name), ''), 'ممرض') AS nurse_name,
    b.service_name,
    b.visit_date,
    b.status,
    COUNT(bm.id)::bigint                                                                            AS message_count,
    MAX(bm.created_at)                                                                              AS last_message_at
  FROM public.bookings b
  INNER JOIN public.booking_messages bm ON bm.booking_id = b.id
  LEFT JOIN public.profiles pat ON pat.id = b.patient_id
  LEFT JOIN public.profiles nurse_prof ON nurse_prof.id = b.nurse_id
  LEFT JOIN public.nurse_profiles np ON np.id = b.nurse_profile_id
  LEFT JOIN public.profiles np_prof ON np_prof.id = np.user_id
  GROUP BY b.id, pat.full_name, b.patient_name, nurse_prof.full_name, np_prof.full_name, b.service_name, b.visit_date, b.status
  ORDER BY MAX(bm.created_at) DESC;
END;
$$;

ALTER FUNCTION public.get_bookings_with_messages() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_bookings_with_messages() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_bookings_with_messages() TO authenticated, service_role;
