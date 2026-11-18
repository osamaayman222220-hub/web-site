-- ============================================================================
-- CareNest - Migration V12: Prevent Nurse Double-Booking & Concurrent Locks
-- ============================================================================
-- ملاحظة هامة: هذا الملف مقترح للعرض والمراجعة الفنية فقط، ولم يتم تنفيذه على قاعدة البيانات.
--
-- الضوابط والالتزامات:
-- 1. لا يحذف ولا يعطل أياً من التريجرز المالية أو التأسيسية القائمة في النظام:
--    - trg_bookings_before_insert / bookings_before_insert()
--    - trg_protect_booking_updates / protect_booking_updates()
--    - trg_record_booking_commission / record_booking_commission()
--    - trg_generate_initial_visit_code / trg_auto_start_visit_code
-- 2. يعتمد حصراً على الأعمدة الفعلية المؤكدة في جدول bookings:
--    (id, nurse_id, visit_date, start_time, end_time, status, service_type).
--    وجداول services: (name_ar, duration_minutes, is_active).
-- 3. العلاقة المعتمدة: bookings.nurse_id يرتبط مباشرة بـ nurse_profiles.id.
-- 4. استخدام مفتاح قفل معاملات 64-بت صحيح عبر hashtextextended و pg_advisory_xact_lock.
-- 5. ترتيب الأقفال تصاعدياً عند تعديل الممرض أو التاريخ لمنع الـ Deadlocks.
-- 6. حساب دقيق للأوقات بالدقائق منذ منتصف الليل، ورفض الثواني غير الصفرية، ومنع تجاوز نهاية اليوم (1440 دقيقة).
-- 7. عدم إعادة حساب NEW.end_time دون داعٍ والحفاظ عليه، وحسابه فقط عند الإنشاء أو تعديل بيانات المدة.
-- 8. عدم استخدام أي مدة افتراضية إطلاقاً والتحقق من services مع is_active = true.
-- 9. تطبيق نظام الفترات [start, end) ومنع التداخل مع الحالات النشطة (pending, accepted, in_progress).
-- 10. التحقق الآمن من وجود التريجر دون استخدام DROP TRIGGER IF EXISTS.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.prevent_nurse_double_booking()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_new_lock_key bigint;
  v_old_lock_key bigint;
  v_duration_minutes integer;
  v_start_minutes integer;
  v_end_minutes integer;
  v_expected_end_time time;
  v_conflict record;
BEGIN
  -- 1. تنفيذ فحص منع التداخل فقط للحالات النشطة (pending, accepted, in_progress)
  --    أي حالة أخرى (completed, cancelled, rejected, ...) تتجاوز الفحص فوراً
  IF NEW.status NOT IN ('pending', 'accepted', 'in_progress') THEN
    RETURN NEW;
  END IF;

  -- 2. في حالة UPDATE: تجاوز الفحص إذا لم تتغير أي من بيانات الموعد أو الممرض أو الحالة
  --    (حماية التحديثات المالية أو الإدارية من إعادة فحص الجدولة، بما فيها الحجوزات القديمة)
  IF TG_OP = 'UPDATE' THEN
    IF NEW.nurse_id IS NOT DISTINCT FROM OLD.nurse_id
       AND NEW.visit_date IS NOT DISTINCT FROM OLD.visit_date
       AND NEW.start_time IS NOT DISTINCT FROM OLD.start_time
       AND NEW.end_time IS NOT DISTINCT FROM OLD.end_time
       AND NEW.service_type IS NOT DISTINCT FROM OLD.service_type
       AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
      RETURN NEW;
    END IF;
  END IF;

  -- 3. التحقق من وجود الممرض وتاريخ ووقت الزيارة
  IF NEW.nurse_id IS NULL THEN
    RETURN NEW; -- إذا لم يُحدد ممرض (حجز عام تحت التوزيع)، نتجاوز فحص الممرض
  END IF;

  IF NEW.visit_date IS NULL OR NEW.start_time IS NULL THEN
    RAISE EXCEPTION 'يرجى تحديد تاريخ ووقت الزيارة لإتمام الحجز.';
  END IF;

  -- 4. توحيد حساب الوقت مع الواجهة ورفض الثواني غير الصفرية برسالة واضحة
  IF EXTRACT(SECOND FROM NEW.start_time) <> 0 THEN
    RAISE EXCEPTION 'وقت بدء الزيارة غير صحيح: يجب أن يكون الوقت بالدقائق وبدون ثوانٍ.';
  END IF;

  -- 5. فرض قفل المعاملة (Advisory Lock) باستخدام hashtextextended
  --    المفتاح مرتبط بمعرف الممرض (nurse_profiles.id) وتاريخ الزيارة (visit_date)
  --    القفل يستمر حتى نهاية المعاملة (COMMIT أو ROLLBACK) تلقائياً
  v_new_lock_key := hashtextextended('carenest_lock_' || NEW.nurse_id::text || '_' || NEW.visit_date::text, 0);

  IF TG_OP = 'UPDATE' AND (OLD.nurse_id IS DISTINCT FROM NEW.nurse_id OR OLD.visit_date IS DISTINCT FROM NEW.visit_date) THEN
    -- عند تعديل الممرض أو التاريخ، نقفل الموعد القديم والجديد بترتيب ثابت تصاعدياً منعاً للـ Deadlocks
    v_old_lock_key := hashtextextended('carenest_lock_' || OLD.nurse_id::text || '_' || OLD.visit_date::text, 0);
    IF v_old_lock_key < v_new_lock_key THEN
      PERFORM pg_advisory_xact_lock(v_old_lock_key);
      PERFORM pg_advisory_xact_lock(v_new_lock_key);
    ELSIF v_old_lock_key > v_new_lock_key THEN
      PERFORM pg_advisory_xact_lock(v_new_lock_key);
      PERFORM pg_advisory_xact_lock(v_old_lock_key);
    ELSE
      PERFORM pg_advisory_xact_lock(v_new_lock_key);
    END IF;
  ELSE
    PERFORM pg_advisory_xact_lock(v_new_lock_key);
  END IF;

  -- 6. حساب وقت الانتهاء والتحقق من صحته:
  --    - فصل كامل بين INSERT و UPDATE لضمان عدم قراءة OLD نهائياً أثناء INSERT.
  --    - عند INSERT: حساب end_time تلقائياً من مدة الخدمة الفعلية.
  --    - عند UPDATE:
  --        * إذا تغيّر start_time أو service_type: إعادة حساب end_time تلقائياً.
  --        * إذا تغيّر end_time وحده: التحقق الصارم من مطابقته للمدة الفعلية ورفض أي قيمة مخالفة.
  --        * تحديثات الحالة والبيانات المالية دون تغيير بيانات الموعد: الحفاظ على end_time دون استعلام إضافي.
  --    - السماح بانتهاء الزيارة عند منتصف الليل تمامًا (1440 دقيقة) ومنع تجاوزه.
  IF TG_OP = 'INSERT' THEN
    -- اعتماد مدة الزيارة بالساعات إن حُددت بواسطة المريض، أو جلبها من جدول services
    IF NEW.duration_hours IS NOT NULL AND NEW.duration_hours > 0 THEN
      v_duration_minutes := ROUND(NEW.duration_hours * 60)::integer;
    ELSE
      SELECT duration_minutes INTO v_duration_minutes
      FROM public.services
      WHERE name_ar = NEW.service_type AND is_active = true
      LIMIT 1;

      IF v_duration_minutes IS NULL OR v_duration_minutes <= 0 THEN
        RAISE EXCEPTION 'لم يتم العثور على مدة صالحة للخدمة المحددة (%) أو أن الخدمة غير نشطة.', COALESCE(NEW.service_type, 'غير محددة');
      END IF;

      NEW.duration_hours := ROUND(v_duration_minutes / 60.0, 2);
    END IF;

    v_start_minutes := (EXTRACT(HOUR FROM NEW.start_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.start_time)::integer;
    v_end_minutes := v_start_minutes + v_duration_minutes;

    IF v_end_minutes > 1440 THEN
      RAISE EXCEPTION 'وقت انتهاء الزيارة يتجاوز نهاية اليوم. يرجى اختيار موعد أبكر.';
    END IF;

    NEW.end_time := make_time((v_end_minutes % 1440) / 60, (v_end_minutes % 1440) % 60, 0.0);

  ELSIF TG_OP = 'UPDATE' THEN
    -- إذا تغيّر وقت البداية أو نوع الخدمة أو عدد الساعات فعلياً: يُعاد حساب وقت الانتهاء
    IF OLD.start_time IS DISTINCT FROM NEW.start_time
       OR OLD.service_type IS DISTINCT FROM NEW.service_type
       OR OLD.duration_hours IS DISTINCT FROM NEW.duration_hours THEN

      IF NEW.duration_hours IS NOT NULL AND NEW.duration_hours > 0 THEN
        v_duration_minutes := ROUND(NEW.duration_hours * 60)::integer;
      ELSE
        SELECT duration_minutes INTO v_duration_minutes
        FROM public.services
        WHERE name_ar = NEW.service_type AND is_active = true
        LIMIT 1;

        IF v_duration_minutes IS NULL OR v_duration_minutes <= 0 THEN
          RAISE EXCEPTION 'لم يتم العثور على مدة صالحة للخدمة المحددة (%) أو أن الخدمة غير نشطة.', COALESCE(NEW.service_type, 'غير محددة');
        END IF;

        NEW.duration_hours := ROUND(v_duration_minutes / 60.0, 2);
      END IF;

      v_start_minutes := (EXTRACT(HOUR FROM NEW.start_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.start_time)::integer;
      v_end_minutes := v_start_minutes + v_duration_minutes;

      IF v_end_minutes > 1440 THEN
        RAISE EXCEPTION 'وقت انتهاء الزيارة يتجاوز نهاية اليوم. يرجى اختيار موعد أبكر.';
      END IF;

      NEW.end_time := make_time((v_end_minutes % 1440) / 60, (v_end_minutes % 1440) % 60, 0.0);

    -- إذا تغيّر وقت الانتهاء وحده صراحةً: نتحقق من مطابقته التامة للمدة الفعلية
    ELSIF OLD.end_time IS DISTINCT FROM NEW.end_time THEN

      SELECT duration_minutes INTO v_duration_minutes
      FROM public.services
      WHERE name_ar = NEW.service_type AND is_active = true
      LIMIT 1;

      IF v_duration_minutes IS NULL OR v_duration_minutes <= 0 THEN
        RAISE EXCEPTION 'لم يتم العثور على مدة صالحة للخدمة المحددة (%) أو أن الخدمة غير نشطة.', COALESCE(NEW.service_type, 'غير محددة');
      END IF;

      v_start_minutes := (EXTRACT(HOUR FROM NEW.start_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.start_time)::integer;
      v_end_minutes := v_start_minutes + v_duration_minutes;

      IF v_end_minutes > 1440 THEN
        RAISE EXCEPTION 'وقت انتهاء الزيارة يتجاوز نهاية اليوم. يرجى اختيار موعد أبكر.';
      END IF;

      v_expected_end_time := make_time((v_end_minutes % 1440) / 60, (v_end_minutes % 1440) % 60, 0.0);

      IF NEW.end_time IS DISTINCT FROM v_expected_end_time THEN
        RAISE EXCEPTION 'وقت انتهاء الزيارة المحدد (%) لا يطابق مدة الخدمة الفعلية (% دقيقة). الوقت المتوقع هو %.', NEW.end_time, v_duration_minutes, v_expected_end_time;
      END IF;

    -- في حال كانت التحديثات للحالة أو للبيانات المالية دون مساس ببيانات الموعد:
    -- يتم الحفاظ على NEW.end_time دون أي استعلام إضافي
    END IF;
  END IF;

  -- التحقق من وجود وقت انتهاء الزيارة للحجوزات النشطة وصحة الثواني
  IF NEW.end_time IS NULL THEN
    IF NEW.status IN ('pending', 'accepted', 'in_progress') AND NEW.nurse_id IS NOT NULL THEN
      RAISE EXCEPTION 'لا يمكن تحديث الحجز النشط بدون وقت انتهاء الزيارة. يرجى تصحيح وقت انتهاء الزيارة.';
    END IF;
  ELSIF EXTRACT(SECOND FROM NEW.end_time) <> 0 THEN
    RAISE EXCEPTION 'وقت انتهاء الزيارة غير صحيح: يجب أن يكون الوقت بالدقائق وبدون ثوانٍ.';
  END IF;

  -- حالة خاصة: إذا كان وقت الانتهاء 00:00:00 (منتصف الليل) فهو نهاية اليوم وليس بدايته
  -- لذا نتجاوز فحص end_time <= start_time في هذه الحالة فقط
  IF NEW.end_time = '00:00:00'::time THEN
    -- منتصف الليل تمامًا: مقبول فقط إذا كان وقت البداية قبله (أي start_time > 00:00:00)
    IF NEW.start_time = '00:00:00'::time THEN
      RAISE EXCEPTION 'وقت الزيارة غير صحيح: لا يمكن أن يكون وقت البداية والانتهاء منتصف الليل معًا.';
    END IF;
  ELSIF NEW.end_time <= NEW.start_time THEN
    RAISE EXCEPTION 'وقت الزيارة غير صحيح: وقت الانتهاء يجب أن يكون بعد وقت البداية.';
  END IF;

  -- 7. إعادة فحص الحجوزات النشطة بعد حيازة القفل لمنع التسابق (Race Conditions)
  --    الحالات المانعة: pending, accepted, in_progress
  --    يتم استثناء الحجز نفسه عند الـ UPDATE باستخدام id
  SELECT b.id, b.start_time, b.end_time, b.status
  INTO v_conflict
  FROM public.bookings b
  WHERE b.nurse_id = NEW.nurse_id
    AND b.visit_date = NEW.visit_date
    AND b.status IN ('pending', 'accepted', 'in_progress')
    AND (NEW.id IS NULL OR b.id <> NEW.id)
    AND (
      -- أ) إذا وُجد حجز نشط قديم بلا وقت انتهاء أو بأوقات غير صحيحة (بما في ذلك ثوانٍ غير صفرية)، نمنع الحجز الجديد احتياطياً
      b.end_time IS NULL 
      OR b.start_time IS NULL 
      OR EXTRACT(SECOND FROM b.start_time) <> 0
      OR EXTRACT(SECOND FROM b.end_time) <> 0
      OR (b.end_time <= b.start_time AND b.end_time <> '00:00:00'::time)
      OR (b.end_time = '00:00:00'::time AND b.start_time = '00:00:00'::time)
      -- ب) فحص التداخل بنظام الفترات [start, end) بعد تحويل الأوقات إلى دقائق منذ منتصف الليل
      --    اعتبار end_time = 00:00:00 مساوياً لـ 1440 دقيقة (نهاية اليوم) للحجز الجديد أو القائم
      OR (
        ((EXTRACT(HOUR FROM NEW.start_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.start_time)::integer)
        <
        (CASE WHEN b.end_time = '00:00:00'::time THEN 1440 ELSE ((EXTRACT(HOUR FROM b.end_time)::integer * 60) + EXTRACT(MINUTE FROM b.end_time)::integer) END)
        AND
        (CASE WHEN NEW.end_time = '00:00:00'::time THEN 1440 ELSE ((EXTRACT(HOUR FROM NEW.end_time)::integer * 60) + EXTRACT(MINUTE FROM NEW.end_time)::integer) END)
        >
        ((EXTRACT(HOUR FROM b.start_time)::integer * 60) + EXTRACT(MINUTE FROM b.start_time)::integer)
      )
    )
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'هذا الممرض لديه حجز آخر في هذا الموعد، يرجى اختيار موعد مختلف أو ممرض آخر.';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.prevent_nurse_double_booking() OWNER TO postgres;

-- 8. تثبيت التريجر على جدول bookings بطريقة آمنة تتحقق من عدم وجوده مسبقاً دون DROP TRIGGER IF EXISTS
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_prevent_nurse_double_booking'
      AND tgrelid = 'public.bookings'::regclass
      AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER trg_prevent_nurse_double_booking
    BEFORE INSERT OR UPDATE
    ON public.bookings
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_nurse_double_booking();
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.prevent_nurse_double_booking() FROM PUBLIC;