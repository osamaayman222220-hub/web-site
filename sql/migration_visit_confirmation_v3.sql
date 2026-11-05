-- ============================================================
-- CareNest - Visit Confirmation & Anti-Bypass Architecture (v3)
-- File: migration_visit_confirmation_v3.sql
-- 
-- المميزات الأمنية الأساسية في v3:
-- 1. لا وجود لأي مفتاح سري ثابت (Hardcoded Secret) في كود SQL؛ المفتاح يُستخرج من إعدادات الخادم أو Vault.
-- 2. سحب صلاحية EXECUTE عن الدوال الحساسة من PUBLIC و anon و authenticated، وتخصيصها لـ service_role فقط.
-- 3. منع تزوير تغيير حالة الحجز عبر REST API باستخدام التحقق من الدور التنفيذي ومطابقة سجل visit_codes الفعلي.
-- 4. فرض مرور 90 دقيقة على موعد الزيارة داخل قاعدة البيانات عبر Trigger صارم لمنع البلاغات الكيدية قبل الموعد.
-- 5. معاملة ذرية متكاملة (ACID Transaction) بقفل السجلات FOR UPDATE لمنع التضارب وتكرار المحاولات.
-- 6. تشفير متناظر للأكواد عبر pgcrypto مع تجزئة SHA-256 وSalt عشوائي فريد لكل كود.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------
-- 1. جدول visit_codes (بدون أي نص صريح للأكواد)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.visit_codes (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id     uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  code_type      text        NOT NULL CHECK (code_type IN ('start', 'end')),
  code_hash      text        NOT NULL,           -- SHA-256(code || salt)
  salt           text        NOT NULL,           -- 16 بايت CSPRNG مشفرة hex
  encrypted_code text        NOT NULL,           -- مشفر بـ pgp_sym_encrypt للمريض فقط
  is_used        boolean     NOT NULL DEFAULT false,
  used_at        timestamptz,
  expires_at     timestamptz NOT NULL,           -- موعد الزيارة + 12 ساعة على الأقل
  attempts       int         NOT NULL DEFAULT 0,
  is_locked      boolean     NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now(),

  UNIQUE (booking_id, code_type)
);

COMMENT ON TABLE public.visit_codes IS 'أكواد تأكيد الزيارات - مشفرة ولا تحتوي نصوصاً صريحة';

-- ------------------------------------------------------------
-- 2. جدول absence_reports (بلاغات عدم الحضور)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.absence_reports (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id    uuid        NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  patient_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nurse_id      uuid        NOT NULL,           -- nurse_profiles.id
  report_time   timestamptz NOT NULL DEFAULT now(),
  patient_note  text,
  admin_action  text        CHECK (admin_action IN ('dismissed', 'warning', 'suspended', 'refunded')),
  admin_note    text,
  reviewed_by   uuid        REFERENCES public.profiles(id),
  reviewed_at   timestamptz,
  status        text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'resolved')),

  UNIQUE (booking_id)
);

-- ------------------------------------------------------------
-- 3. تفعيل RLS وسياسات الأمان
-- ------------------------------------------------------------
ALTER TABLE public.visit_codes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.absence_reports ENABLE ROW LEVEL SECURITY;

-- visit_codes: لا يُسمح بالقراءة المباشرة إلا للمشرف (المريض يقرأ كوده عبر دالة RPC موثقة فقط)
DROP POLICY IF EXISTS "admin_read_all_visit_codes" ON public.visit_codes;
CREATE POLICY "admin_read_all_visit_codes" ON public.visit_codes
  FOR SELECT USING (public.is_admin());

-- absence_reports: سياسات الوصول
DROP POLICY IF EXISTS "patient_read_own_absence_reports" ON public.absence_reports;
CREATE POLICY "patient_read_own_absence_reports" ON public.absence_reports
  FOR SELECT USING (patient_id = auth.uid());

DROP POLICY IF EXISTS "patient_insert_absence_report" ON public.absence_reports;
CREATE POLICY "patient_insert_absence_report" ON public.absence_reports
  FOR INSERT WITH CHECK (patient_id = auth.uid());

DROP POLICY IF EXISTS "admin_manage_absence_reports" ON public.absence_reports;
CREATE POLICY "admin_manage_absence_reports" ON public.absence_reports
  FOR ALL USING (public.is_admin());

-- ------------------------------------------------------------
-- 4. استخراج مفتاح التشفير الآمن ديناميكياً (بدون نصوص ثابتة)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._get_visit_encryption_key()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_key text;
BEGIN
  -- المحاولة 1: قراءة المفتاح من إعداد قاعدة البيانات السري (تحدده في Supabase Dashboard -> Database Settings)
  v_key := current_setting('app.settings.visit_secret_key', true);

  -- المحاولة 2: في حال عدم ضبط الإعداد، استخدام سر مشتق من سر Supabase الداخلي
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    v_key := current_setting('app.settings.jwt_secret', true);
  END IF;

  -- الحماية: رفض التشفير إذا لم يتوفر مفتاح قوي
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    RAISE EXCEPTION 'مفتاح التشفير السري غير مهيأ في إعدادات قاعدة البيانات. يرجى ضبط app.settings.visit_secret_key.';
  END IF;

  RETURN v_key;
END;
$$;

-- حظر استدعاء دالة المفتاح من المستخدمين
REVOKE ALL ON FUNCTION public._get_visit_encryption_key() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._get_visit_encryption_key() TO service_role;

-- ------------------------------------------------------------
-- 5. دالة توليد وتخزين الكود ذرياً (CSPRNG)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._generate_and_store_code(
  p_booking_id uuid,
  p_code_type  text,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_raw_int       bigint;
  v_code          text;
  v_salt          text;
  v_hash          text;
  v_enc           text;
  v_enc_key       text;
BEGIN
  -- 1. توليد كود قوي عشوائياً (6 أرقام) باستخدام CSPRNG من نواة النظام
  v_raw_int := (abs(get_byte(gen_random_bytes(4), 0) * 16777216 +
                     get_byte(gen_random_bytes(4), 1) * 65536 +
                     get_byte(gen_random_bytes(4), 2) * 256 +
                     get_byte(gen_random_bytes(4), 3)) % 900000) + 100000;
  v_code := v_raw_int::text;

  -- 2. توليد Salt عشوائي فريد (16 بايت مشفرة hex)
  v_salt := encode(gen_random_bytes(16), 'hex');

  -- 3. حساب تجزئة SHA-256 للمقارنة الآمنة
  v_hash := encode(digest(v_code || v_salt, 'sha256'), 'hex');

  -- 4. جلب المفتاح وتشفير الكود
  v_enc_key := public._get_visit_encryption_key();
  v_enc := encode(pgp_sym_encrypt(v_code, v_enc_key), 'base64');

  -- 5. إدراج أو تحديث الكود
  INSERT INTO public.visit_codes (
    booking_id,
    code_type,
    code_hash,
    salt,
    encrypted_code,
    expires_at
  ) VALUES (
    p_booking_id,
    p_code_type,
    v_hash,
    v_salt,
    v_enc,
    p_expires_at
  )
  ON CONFLICT (booking_id, code_type) DO UPDATE
    SET code_hash      = EXCLUDED.code_hash,
        salt           = EXCLUDED.salt,
        encrypted_code = EXCLUDED.encrypted_code,
        expires_at     = EXCLUDED.expires_at,
        is_used        = false,
        used_at        = null,
        attempts       = 0,
        is_locked      = false;
END;
$$;

-- حظر استدعاء دالة التوليد من المستخدمين
REVOKE ALL ON FUNCTION public._generate_and_store_code(uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._generate_and_store_code(uuid, text, timestamptz) TO service_role;

-- ------------------------------------------------------------
-- 6. دالة جلب الكود للمريض (قراءة وفك تشفير للمصرح له حصراً)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_patient_visit_code(
  p_booking_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_booking     public.bookings%ROWTYPE;
  v_code_rec    public.visit_codes%ROWTYPE;
  v_target_type text;
  v_plain_code  text;
  v_enc_key     text;
BEGIN
  -- 1. التأكد من وجود الحجز
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN
    RETURN json_build_object('available', false, 'error', 'الحجز غير موجود.');
  END IF;

  -- 2. التحقق الصارم من أن المستدعي هو المريض صاحب الحجز حصراً
  IF v_booking.patient_id <> auth.uid() AND NOT public.is_admin() THEN
    RETURN json_build_object('available', false, 'error', 'غير مصرح لك بالاطلاع على هذا الكود.');
  END IF;

  -- 3. تحديد نوع الكود المطلوب
  IF v_booking.status = 'accepted' THEN
    v_target_type := 'start';
  ELSIF v_booking.status = 'in_progress' THEN
    v_target_type := 'end';
  ELSE
    RETURN json_build_object('available', false, 'reason', 'لا توجد أكواد نشطة لهذه الحالة.');
  END IF;

  -- 4. جلب سجل الكود المشفر
  SELECT * INTO v_code_rec FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = v_target_type;

  IF NOT FOUND THEN
    RETURN json_build_object('available', false, 'reason', 'الكود قيد التجهيز.');
  END IF;

  IF v_code_rec.is_locked THEN
    RETURN json_build_object('available', false, 'is_locked', true, 'reason', 'تم إيقاف الكود لتجاوز عدد المحاولات.');
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('available', false, 'is_used', true, 'reason', 'تم استخدام الكود مسبقاً.');
  END IF;

  IF now() > v_code_rec.expires_at THEN
    RETURN json_build_object('available', false, 'expired', true, 'reason', 'انتهت صلاحية الكود.');
  END IF;

  -- 5. فك التشفير للمريض فقط
  v_enc_key := public._get_visit_encryption_key();
  v_plain_code := pgp_sym_decrypt(decode(v_code_rec.encrypted_code, 'base64'), v_enc_key);

  RETURN json_build_object(
    'available',  true,
    'code_type',  v_target_type,
    'code',       v_plain_code,
    'expires_at', v_code_rec.expires_at
  );
END;
$$;

-- منح حق الاستدعاء للمستخدم الموثق (والدالة بداخلها تقيد المريض فقط)
GRANT EXECUTE ON FUNCTION public.get_patient_visit_code(uuid) TO authenticated;

-- ------------------------------------------------------------
-- 7. الدالة الذرية الشاملة للتحقق والترقية (Atomic Verification)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_visit_code_atomic(
  p_booking_id      uuid,
  p_entered_code    text,
  p_code_type       text,
  p_nurse_user_id   uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_booking         public.bookings%ROWTYPE;
  v_nurse_profile   public.nurse_profiles%ROWTYPE;
  v_code_rec        public.visit_codes%ROWTYPE;
  v_computed_hash   text;
  v_now             timestamptz := now();
  v_visit_datetime  timestamptz;
  v_end_expires_at  timestamptz;
  v_remaining       int;
BEGIN
  -- أقفال السجلات FOR UPDATE لمنع التضارب المتزامن
  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'الحجز غير موجود.', 'status_code', 404);
  END IF;

  -- التحقق من هوية الممرض المسند إليه الحجز
  SELECT * INTO v_nurse_profile
  FROM public.nurse_profiles
  WHERE user_id = p_nurse_user_id;

  IF NOT FOUND OR v_nurse_profile.id <> v_booking.nurse_id THEN
    RETURN json_build_object('success', false, 'error', 'غير مصرح: الحجز غير مسند إلى حسابك.', 'status_code', 403);
  END IF;

  -- فحص الحالة الحالية
  IF p_code_type = 'start' AND v_booking.status <> 'accepted' THEN
    RETURN json_build_object('success', false, 'error', 'لا يمكن بدء زيارة إلا إذا كانت بحالة "مقبول".', 'status_code', 409);
  ELSIF p_code_type = 'end' AND v_booking.status <> 'in_progress' THEN
    RETURN json_build_object('success', false, 'error', 'لا يمكن إنهاء زيارة إلا إذا كانت جارية حالياً.', 'status_code', 409);
  END IF;

  -- قفل وجلب الكود
  SELECT * INTO v_code_rec
  FROM public.visit_codes
  WHERE booking_id = p_booking_id AND code_type = p_code_type
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'كود التأكيد غير متوفر.', 'status_code', 404);
  END IF;

  IF v_code_rec.is_locked THEN
    RETURN json_build_object('success', false, 'error', 'تم إيقاف الكود لتجاوز 5 محاولات خاطئة. تواصل مع الإدارة.', 'status_code', 423);
  END IF;

  IF v_code_rec.is_used THEN
    RETURN json_build_object('success', false, 'error', 'تم استخدام هذا الكود مسبقاً.', 'status_code', 409);
  END IF;

  IF v_now > v_code_rec.expires_at THEN
    RETURN json_build_object('success', false, 'error', 'انتهت صلاحية كود التأكيد.', 'status_code', 410);
  END IF;

  -- مطابقة تجزئة الكود
  v_computed_hash := encode(digest(trim(p_entered_code) || v_code_rec.salt, 'sha256'), 'hex');

  IF v_computed_hash <> v_code_rec.code_hash THEN
    UPDATE public.visit_codes
    SET attempts  = attempts + 1,
        is_locked = (attempts + 1 >= 5)
    WHERE id = v_code_rec.id;

    v_remaining := 5 - (v_code_rec.attempts + 1);
    IF v_remaining <= 0 THEN
      RETURN json_build_object('success', false, 'error', 'الكود غير صحيح. تم إيقاف الكود لتكرار الخطأ 5 مرات.', 'status_code', 423);
    ELSE
      RETURN json_build_object('success', false, 'error', format('الكود غير صحيح. متبقٍ %s محاولة/محاولات.', v_remaining), 'status_code', 400);
    END IF;
  END IF;

  -- وسم الكود كمستخدم
  UPDATE public.visit_codes
  SET is_used = true,
      used_at = v_now
  WHERE id = v_code_rec.id;

  -- ترقية الحجز وتوليد كود النهاية
  IF p_code_type = 'start' THEN
    UPDATE public.bookings
    SET status     = 'in_progress',
        updated_at = v_now
    WHERE id = p_booking_id;

    BEGIN
      v_visit_datetime := (v_booking.visit_date::date + COALESCE(v_booking.start_time::time, '00:00:00'::time))::timestamp AT TIME ZONE 'Africa/Cairo';
    EXCEPTION WHEN OTHERS THEN
      v_visit_datetime := v_now;
    END;

    -- صلاحية كود النهاية لا تقل عن 12 ساعة من لحظة البدء أو موعد الزيارة
    v_end_expires_at := GREATEST(v_now + INTERVAL '12 hours', v_visit_datetime + INTERVAL '18 hours');

    -- توليد وتخزين كود النهاية ذرياً (إذا فشل التوليد يتراجع التحديث كاملاً)
    PERFORM public._generate_and_store_code(p_booking_id, 'end', v_end_expires_at);

    RETURN json_build_object(
      'success', true,
      'message', 'تم تأكيد بداية الزيارة بنجاح وتم تجهيز كود إنهاء الزيارة للمريض.',
      'new_status', 'in_progress'
    );

  ELSIF p_code_type = 'end' THEN
    UPDATE public.bookings
    SET status     = 'completed',
        updated_at = v_now
    WHERE id = p_booking_id;

    RETURN json_build_object(
      'success', true,
      'message', 'تم تأكيد اكتمال الزيارة التمريضية بنجاح.',
      'new_status', 'completed'
    );
  END IF;

  RETURN json_build_object('success', false, 'error', 'نوع كود غير صالح.', 'status_code', 400);
END;
$$;

-- حماية مشددة: سحب حق الاستدعاء من PUBLIC والمستخدمين العاديين
REVOKE ALL ON FUNCTION public.verify_visit_code_atomic(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_visit_code_atomic(uuid, text, text, uuid) TO service_role;

-- ------------------------------------------------------------
-- 8. حماية حالات الحجز في الـ Trigger (Anti-Bypass Protection)
-- ------------------------------------------------------------
-- لا يعتمد على متغيرات يمكن للمستخدم ضبطها، بل يتحقق من:
-- أ. إذا كان الطلب من دور العميل العادي (authenticated/anon) يُحظر التحديث إلى in_progress أو completed فوراً.
-- ب. التحقق من وجود سجل مستهلك فعلي في visit_codes يثبت صحة الكود.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_booking_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_has_valid_start boolean := false;
  v_has_valid_end   boolean := false;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- المشرف يملك صلاحية كاملة
  IF public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  -- 1. حظر التحويل المباشر من واجهات الـ REST API العادية (التي تعمل كـ authenticated/anon)
  IF CURRENT_USER IN ('authenticated', 'anon') THEN
    IF (OLD.status = 'accepted' AND NEW.status = 'in_progress') OR
       (OLD.status = 'in_progress' AND NEW.status = 'completed') THEN
      RAISE EXCEPTION 'عملية غير مصرح بها: لا يمكن تغيير حالة الزيارة إلى (جارية) أو (مكتملة) مباشرة عبر الواجهة أو API. يجب إدخال كود التأكيد الصحيح.';
    END IF;
  END IF;

  -- 2. التحقق من وجود إثبات استهلاك الكود الفعلي في جدول visit_codes
  IF OLD.status = 'accepted' AND NEW.status = 'in_progress' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.visit_codes
      WHERE booking_id = NEW.id
        AND code_type = 'start'
        AND is_used = true
        AND used_at >= (now() - INTERVAL '5 minutes')
    ) INTO v_has_valid_start;

    IF NOT v_has_valid_start THEN
      RAISE EXCEPTION 'فشل التحقق: لا يوجد كود بداية معتمد ومستهلك لهذا الحجز.';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'in_progress' AND NEW.status = 'completed' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.visit_codes
      WHERE booking_id = NEW.id
        AND code_type = 'end'
        AND is_used = true
        AND used_at >= (now() - INTERVAL '5 minutes')
    ) INTO v_has_valid_end;

    IF NOT v_has_valid_end THEN
      RAISE EXCEPTION 'فشل التحقق: لا يوجد كود نهاية معتمد ومستهلك لهذا الحجز.';
    END IF;
    RETURN NEW;
  END IF;

  -- 3. العمليات الطبيعية المسموح بها للمريض والممرض
  -- قبول أو رفض أو اعتذار عن طلب جديد
  IF OLD.status = 'pending' AND NEW.status IN ('accepted', 'rejected', 'cancelled') THEN
    RETURN NEW;
  END IF;

  -- إلغاء حجز مقبول قبل بدئه
  IF OLD.status = 'accepted' AND NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'انتقال حالة الحجز غير مسموح من % إلى %', OLD.status, NEW.status;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_booking_updates ON public.bookings;
CREATE TRIGGER trg_protect_booking_updates
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_booking_updates();

-- ------------------------------------------------------------
-- 9. Trigger فرض شرط الـ 90 دقيقة لبلاغ عدم الحضور داخل قاعدة البيانات
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_enforce_absence_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_booking   public.bookings%ROWTYPE;
  v_visit_dt  timestamptz;
BEGIN
  -- جلب بيانات الحجز
  SELECT * INTO v_booking FROM public.bookings WHERE id = NEW.booking_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'الحجز المطلوب غير موجود.';
  END IF;

  -- التأكد من أن المستدعي هو المريض صاحب الحجز حصراً
  IF v_booking.patient_id <> auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'غير مصرح: المريض صاحب الحجز فقط يمكنه الإبلاغ عن عدم الحضور.';
  END IF;

  -- الحجز يجب أن يكون مقبولاً (accepted)
  IF v_booking.status <> 'accepted' THEN
    RAISE EXCEPTION 'لا يمكن الإبلاغ عن عدم الحضور إلا للحجوزات المقبولة (accepted).';
  END IF;

  -- حساب موعد بدء الزيارة بتوقيت مصر
  BEGIN
    v_visit_dt := (v_booking.visit_date::date + COALESCE(v_booking.start_time::time, '00:00:00'::time))::timestamp AT TIME ZONE 'Africa/Cairo';
  EXCEPTION WHEN OTHERS THEN
    v_visit_dt := v_booking.created_at;
  END IF;

  -- فرض مرور 90 دقيقة داخل قاعدة البيانات
  IF now() < (v_visit_dt + INTERVAL '90 minutes') THEN
    RAISE EXCEPTION 'لا يمكن تقديم بلاغ عدم الحضور إلا بعد مرور 90 دقيقة من موعد بدء الزيارة المحدد.';
  END IF;

  -- تثبيت المعرفات تلقائياً من الحجز لمنع التلاعب
  NEW.patient_id := v_booking.patient_id;
  NEW.nurse_id   := v_booking.nurse_id;
  NEW.report_time := now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_absence ON public.absence_reports;
CREATE TRIGGER trg_validate_absence
  BEFORE INSERT ON public.absence_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_absence_rules();

-- ------------------------------------------------------------
-- 10. Trigger توليد كود البداية تلقائياً عند قبول الحجز
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_generate_initial_visit_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_visit_datetime timestamptz;
  v_expires_at     timestamptz;
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS DISTINCT FROM 'accepted') THEN
    BEGIN
      v_visit_datetime := (NEW.visit_date::date + COALESCE(NEW.start_time::time, '00:00:00'::time))::timestamp AT TIME ZONE 'Africa/Cairo';
    EXCEPTION WHEN OTHERS THEN
      v_visit_datetime := now();
    END;

    v_expires_at := v_visit_datetime + INTERVAL '12 hours';
    IF v_expires_at <= now() THEN
      v_expires_at := now() + INTERVAL '12 hours';
    END IF;

    PERFORM public._generate_and_store_code(NEW.id, 'start', v_expires_at);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_start_visit_code ON public.bookings;
CREATE TRIGGER trg_auto_start_visit_code
  AFTER UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_generate_initial_visit_code();

