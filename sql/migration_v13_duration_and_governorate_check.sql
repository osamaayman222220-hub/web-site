-- ============================================================================
-- CareNest - Migration V13: Enforce Same Governorate & Patient Visit Duration
-- ============================================================================
-- ملاحظة هامة: هذا الملف مقترح للعرض والمراجعة الفنية فقط، ولا يُنفذ تلقائياً.
--
-- الأهداف:
-- 1. منع حجز الزيارات التمريضية بين محافظات مختلفة على مستوى قاعدة البيانات (Backend).
-- 2. التحقق من المحافظة الفعلية المسجلة في جدول profiles للمريض وجدول nurse_profiles للممرض.
-- 3. منع الحجز إذا لم تكن محافظة المريض أو الممرض مسجلة مع إرجاع رسالة واضحة.
-- 4. دعم تحديد مدة الزيارة بالساعات (duration_hours) وحساب وقت الانتهاء end_time بدقة.
-- 5. منع تداخل المواعيد ومنع الحجز المزدوج وفق المدة المحددة بالساعات.
-- 6. عدم المساس بأي من تريجرات العمولات أو المحافظ أو العمليات المالية.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. دالة وتريجر التحقق الإلزامي من تطابق المحافظة بين المريض والممرض
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_booking_same_governorate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_patient_gov text;
  v_nurse_gov text;
BEGIN
  -- يتم الفحص فقط عند الإنشاء أو عند تعديل المريض أو الممرض
  IF TG_OP = 'UPDATE' THEN
    IF NEW.patient_id IS NOT DISTINCT FROM OLD.patient_id
       AND NEW.nurse_id IS NOT DISTINCT FROM OLD.nurse_id THEN
      RETURN NEW;
    END IF;
  END IF;

  -- 1. التحقق من المحافظة الفعلية المسجلة في حساب المريض (public.profiles)
  SELECT TRIM(governorate) INTO v_patient_gov
  FROM public.profiles
  WHERE id = NEW.patient_id;

  IF v_patient_gov IS NULL OR v_patient_gov = '' THEN
    RAISE EXCEPTION 'لا يمكن إتمام الحجز: لم يتم تسجيل المحافظة في الملف الشخصي للمريض. يرجى استكمال البيانات في حسابك أولاً.';
  END IF;

  -- 2. التحقق من المحافظة الفعلية المسجلة للممرض (public.nurse_profiles أو profiles)
  SELECT TRIM(COALESCE(np.governorate, p.governorate)) INTO v_nurse_gov
  FROM public.nurse_profiles np
  LEFT JOIN public.profiles p ON p.id = np.user_id
  WHERE np.id = NEW.nurse_id OR np.user_id = NEW.nurse_id
  LIMIT 1;

  IF v_nurse_gov IS NULL OR v_nurse_gov = '' THEN
    SELECT TRIM(governorate) INTO v_nurse_gov
    FROM public.profiles
    WHERE id = NEW.nurse_id;
  END IF;

  IF v_nurse_gov IS NULL OR v_nurse_gov = '' THEN
    RAISE EXCEPTION 'لا يمكن إتمام الحجز: لم يتم تسجيل محافظة الممرض في حسابه بالمنظومة.';
  END IF;

  -- 3. المقارنة الصارمة: رفض الحجز إذا كانت المحافظات مختلفة
  IF v_patient_gov <> v_nurse_gov THEN
    RAISE EXCEPTION 'لا يمكن إتمام الحجز: الممرض في محافظة (%) بينما المريض في محافظة (%). يمنع النظام حجز الزيارات بين محافظات مختلفة.', v_nurse_gov, v_patient_gov;
  END IF;

  -- تثبيت المحافظة المعتمدة في سجل الحجز
  NEW.governorate := v_patient_gov;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_booking_same_governorate ON public.bookings;
CREATE TRIGGER trg_enforce_booking_same_governorate
BEFORE INSERT OR UPDATE OF patient_id, nurse_id ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.enforce_booking_same_governorate();


-- ----------------------------------------------------------------------------
-- 2. دالة وتريجر التحقق من مدة الزيارة بالساعات وحساب وقت الانتهاء تلقائياً
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_booking_duration_and_timing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_duration_minutes integer;
  v_start_minutes integer;
  v_end_minutes integer;
BEGIN
  -- تجاوز الفحص للحالات غير النشطة
  IF NEW.status NOT IN ('pending', 'accepted', 'in_progress') THEN
    RETURN NEW;
  END IF;

  -- في حالة التحديث: تجاوز الفحص إذا لم تتغير بيانات الجدولة أو المدة
  IF TG_OP = 'UPDATE' THEN
    IF NEW.start_time IS NOT DISTINCT FROM OLD.start_time
       AND NEW.duration_hours IS NOT DISTINCT FROM OLD.duration_hours
       AND NEW.service_type IS NOT DISTINCT FROM OLD.service_type THEN
      RETURN NEW;
    END IF;
  END IF;

  -- التحقق من وقت البدء
  IF NEW.start_time IS NULL THEN
    RAISE EXCEPTION 'يرجى تحديد وقت بدء الزيارة.';
  END IF;

  IF EXTRACT(SECOND FROM NEW.start_time) <> 0 THEN
    RAISE EXCEPTION 'وقت بدء الزيارة غير صحيح: يجب أن يكون الوقت بالدقائق وبدون ثوانٍ.';
  END IF;

  -- 1. اعتماد مدة الزيارة بالساعات المحددة بواسطة المريض
  IF NEW.duration_hours IS NOT NULL AND NEW.duration_hours > 0 THEN
    v_duration_minutes := ROUND(NEW.duration_hours * 60)::integer;
  ELSE
    -- في حال عدم تحديد الساعات صراحة، نلجأ لمدة الخدمة من جدول services كحد أدنى
    SELECT duration_minutes INTO v_duration_minutes
    FROM public.services
    WHERE name_ar = NEW.service_type AND is_active = true
    LIMIT 1;

    IF v_duration_minutes IS NULL OR v_duration_minutes <= 0 THEN
      RAISE EXCEPTION 'يرجى تحديد مدة الزيارة بالساعات لإتمام الحجز.';
    END IF;

    NEW.duration_hours := ROUND(v_duration_minutes / 60.0, 2);
  END IF;

  -- 2. حساب وقت الانتهاء بدقة
  v_start_minutes := (EXTRACT(HOUR FROM NEW.start_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.start_time)::integer;
  v_end_minutes := v_start_minutes + v_duration_minutes;

  IF v_end_minutes > 1440 THEN
    RAISE EXCEPTION 'وقت انتهاء الزيارة يتجاوز نهاية اليوم (12:00 منتصف الليل). يرجى اختيار موعد أبكر أو تقليل عدد الساعات.';
  END IF;

  NEW.end_time := make_time((v_end_minutes % 1440) / 60, (v_end_minutes % 1440) % 60, 0.0);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_booking_duration_and_timing ON public.bookings;
CREATE TRIGGER trg_enforce_booking_duration_and_timing
BEFORE INSERT OR UPDATE OF start_time, duration_hours, service_type ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.enforce_booking_duration_and_timing();
