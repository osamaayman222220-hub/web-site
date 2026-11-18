-- ============================================================
-- CareNest (رعاية) - Migration v11
-- نظام تسجيل عمولة الحجوزات النقدية فور قبول الممرض للحجز
-- ============================================================
-- القواعد المنفذة:
-- 1. عند اختيار المريض الدفع نقداً (cash) وقبول الممرض للحجز (accepted)،
--    تُسجل عمولة المنصة فوراً كمديونية على الممرض في محفظته (commission_debt).
-- 2. تظهر المديونية بالسالب في محفظة الممرض عبر الرصيد الصافي (balance = pending_payouts - commission_debt).
-- 3. لا يتم خصم أي مبلغ من المريض؛ المريض يدفع للممرض نقدياً بعد انتهاء الزيارة.
-- 4. تُحسب العمولة مرة واحدة فقط مع منع التكرار تماماً (Idempotent).
-- 5. إذا أُلغي الحجز بعد القبول وقبل التنفيذ، تُلغى المديونية تلقائياً من محفظة الممرض.
-- 6. عند اكتمال الزيارة (completed)، يتم تأكيد العمولة الموجودة بالفعل دون تسجيل عمولة ثانية.
-- 7. عدم تطبيق هذا التعديل على الدفع الإلكتروني (vodafone_cash / instapay).
-- 8. استخدام نسبة العمولة الحالية المخزنة في الحجز وإعدادات المنصة دون تغيير.
-- ============================================================

-- ------------------------------------------------------------
-- 1. تحديث تريجر حماية الحجوزات (trg_protect_booking_immutability)
-- السماح بتسجيل العمولة عند قبول الحجز النقدي أو اكتماله
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_protect_booking_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_role text;
  v_is_admin boolean;
  v_is_privileged boolean;
BEGIN
  BEGIN
    v_caller_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_caller_role := NULL;
  END;

  v_is_admin := public.is_admin();
  v_is_privileged := v_is_admin 
    OR v_caller_role = 'service_role' 
    OR (session_user IN ('postgres', 'supabase_admin') AND auth.uid() IS NULL);

  IF NOT v_is_privileged THEN
    -- أ) منع تعديل أطراف الحجز نهائياً
    IF NEW.patient_id IS DISTINCT FROM OLD.patient_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير المريض صاحب الحجز';
    END IF;

    IF NEW.nurse_id IS DISTINCT FROM OLD.nurse_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير الممرض المسند إليه الحجز';
    END IF;

    IF NEW.nurse_profile_id IS DISTINCT FROM OLD.nurse_profile_id THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تغيير الملف المهني للممرض المسند إليه الحجز';
    END IF;

    -- ب) منع الممرض من تعديل بيانات المريض وملاحظاته وعنوانه
    IF (auth.uid() = OLD.nurse_id OR auth.uid() IN (SELECT user_id FROM public.nurse_profiles WHERE id = OLD.nurse_profile_id)) THEN
      IF NEW.patient_name IS DISTINCT FROM OLD.patient_name OR
         NEW.patient_phone IS DISTINCT FROM OLD.patient_phone OR
         NEW.patient_address IS DISTINCT FROM OLD.patient_address OR
         NEW.governorate IS DISTINCT FROM OLD.governorate OR
         NEW.city IS DISTINCT FROM OLD.city OR
         NEW.notes IS DISTINCT FROM OLD.notes OR
         NEW.patient_notes IS DISTINCT FROM OLD.patient_notes THEN
        RAISE EXCEPTION 'غير مصرح للممرض بتعديل بيانات أو عنوان أو ملاحظات المريض';
      END IF;
    END IF;

    -- ج) منع تعديل الأسعار والمبالغ والنسب المالية مباشرة من العميل
    IF NEW.total_price IS DISTINCT FROM OLD.total_price OR
       NEW.price IS DISTINCT FROM OLD.price OR
       NEW.deposit_amount IS DISTINCT FROM OLD.deposit_amount OR
       (NEW.commission_rate IS DISTINCT FROM OLD.commission_rate AND OLD.commission_rate IS NOT NULL) OR
       (NEW.commission_amount IS DISTINCT FROM OLD.commission_amount AND OLD.commission_amount IS NOT NULL) OR
       (NEW.nurse_net_amount IS DISTINCT FROM OLD.nurse_net_amount AND OLD.nurse_net_amount IS NOT NULL) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل أسعار أو عمولات الحجز مباشرة من العميل';
    END IF;

    -- د) منع التلاعب بحالة الدفع ومؤشرات الصرف والاعتماد المالي
    IF (NEW.payment_status IS DISTINCT FROM OLD.payment_status AND NEW.payment_status IN ('verified', 'approved')) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن اعتماد دفع الحجز إلا من خلال إدارة النظام المعتمدة';
    END IF;

    IF (NEW.nurse_payout_credited IS DISTINCT FROM OLD.nurse_payout_credited AND NEW.nurse_payout_credited = true) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن إضافة مستحقات الممرض إلا من خلال إدارة النظام المعتمدة';
    END IF;

    IF (NEW.payment_reviewed_by IS DISTINCT FROM OLD.payment_reviewed_by OR NEW.payment_reviewed_at IS DISTINCT FROM OLD.payment_reviewed_at) THEN
      RAISE EXCEPTION 'غير مصرح: لا يمكن تعديل بيانات مراجعة الدفع إلا من قبل الإدارة';
    END IF;

    -- هـ) تسجيل العمولة: مسموح عند القبول (للحجوزات النقدية) أو أثناء وسريان واكتمال الحجز
    IF (NEW.commission_recorded IS DISTINCT FROM OLD.commission_recorded AND NEW.commission_recorded = true) THEN
      IF NEW.status NOT IN ('accepted', 'in_progress', 'completed') THEN
        RAISE EXCEPTION 'غير مصرح: لا يمكن تسجيل عمولة الحجز قبل قبول الزيارة أو اكتمالها';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 2. دالة وتريجر إدارة دورة حياة العمولة النقدية والمديونية
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_handle_booking_commission_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_nurse_profile_id uuid;
  v_nurse_user_id uuid;
  v_rate numeric(5,2);
  v_comm numeric(10,2);
  v_net numeric(10,2);
  v_setting jsonb;
  v_tx_exists boolean;
BEGIN
  -- تحديد هوية الممرض (الملف المهني وحساب المستخدم)
  SELECT np.id, np.user_id INTO v_nurse_profile_id, v_nurse_user_id
  FROM public.nurse_profiles np
  WHERE np.id = COALESCE(NEW.nurse_profile_id, NEW.nurse_id)
     OR np.user_id = COALESCE(NEW.nurse_id, NEW.nurse_profile_id)
  LIMIT 1;

  -- =========================================================================
  -- الحالة الأولى: قبول الحجز النقدي (Transition: pending -> accepted)
  -- =========================================================================
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status <> 'accepted') THEN
    IF NEW.payment_method = 'cash' AND NOT COALESCE(OLD.commission_recorded, false) THEN
      -- استخراج أو تثبيت نسبة العمولة المعتمدة
      IF NEW.commission_rate IS NOT NULL AND NEW.commission_rate > 0 THEN
        v_rate := NEW.commission_rate;
      ELSE
        SELECT value INTO v_setting 
        FROM public.platform_settings 
        WHERE key IN ('commission_rate', 'platform_commission') 
        ORDER BY key = 'commission_rate' DESC 
        LIMIT 1;

        IF v_setting IS NOT NULL THEN
          v_rate := COALESCE((v_setting->>'percent')::numeric, (v_setting->>'rate')::numeric, 15.00);
        ELSE
          v_rate := 15.00;
        END IF;
      END IF;

      -- احتساب قيمة العمولة وصافي الممرض
      v_comm := COALESCE(NEW.commission_amount, ROUND((NEW.total_price * (v_rate / 100.0)), 2));
      v_net  := COALESCE(NEW.nurse_net_amount, ROUND(NEW.total_price - v_comm, 2));

      NEW.commission_rate := v_rate;
      NEW.commission_amount := v_comm;
      NEW.nurse_net_amount := v_net;
      NEW.commission_recorded := true;

      -- التحقق من عدم وجود معاملة عمولة مسجلة مسبقاً لهذا الحجز (منع التكرار الصارم)
      SELECT EXISTS (
        SELECT 1 FROM public.financial_transactions 
        WHERE booking_id = NEW.id 
          AND type = 'platform_commission' 
          AND status IN ('pending_review', 'completed', 'approved')
      ) INTO v_tx_exists;

      IF NOT v_tx_exists AND v_nurse_profile_id IS NOT NULL AND v_comm > 0 THEN
        -- 1. إضافة المديونية فوراً إلى محفظة الممرض
        INSERT INTO public.nurse_wallets (
          nurse_id,
          nurse_user_id,
          commission_debt,
          pending_payouts,
          total_paid_payouts,
          total_settled_commissions,
          total_visits_revenue,
          total_commissions_due,
          updated_at
        ) VALUES (
          v_nurse_profile_id,
          v_nurse_user_id,
          v_comm,
          0.00,
          0.00,
          0.00,
          0.00,
          v_comm,
          now()
        )
        ON CONFLICT (nurse_id) DO UPDATE SET
          commission_debt = public.nurse_wallets.commission_debt + v_comm,
          total_commissions_due = public.nurse_wallets.total_commissions_due + v_comm,
          updated_at = now();

        -- 2. تسجيل قيد الحركة في جدول المعاملات المالية
        INSERT INTO public.financial_transactions (
          booking_id,
          nurse_id,
          nurse_user_id,
          patient_id,
          type,
          amount,
          status,
          payment_method,
          notes
        ) VALUES (
          NEW.id,
          v_nurse_profile_id,
          v_nurse_user_id,
          NEW.patient_id,
          'platform_commission',
          v_comm,
          'pending_review',
          'cash',
          'مديونية عمولة نقدية مستحقة عند قبول الزيارة رقم ' || substring(NEW.id::text, 1, 8)
        )
        ON CONFLICT (booking_id) WHERE (type = 'platform_commission') DO NOTHING;
      END IF;
    END IF;

  -- =========================================================================
  -- الحالة الثانية: إلغاء الحجز أو الاعتذار عنه (Transition: accepted/in_progress -> cancelled/rejected)
  -- =========================================================================
  ELSIF NEW.status IN ('cancelled', 'rejected') AND OLD.status IN ('accepted', 'in_progress') THEN
    IF OLD.payment_method = 'cash' AND COALESCE(OLD.commission_recorded, false) = true THEN
      v_comm := COALESCE(OLD.commission_amount, 0.00);
      IF v_comm <= 0 THEN
        SELECT amount INTO v_comm 
        FROM public.financial_transactions 
        WHERE booking_id = NEW.id AND type = 'platform_commission' AND status != 'rejected'
        LIMIT 1;
      END IF;

      -- إلغاء المديونية من محفظة الممرض تلقائياً
      IF v_nurse_profile_id IS NOT NULL AND v_comm > 0 THEN
        UPDATE public.nurse_wallets
        SET
          commission_debt = GREATEST(0.00, commission_debt - v_comm),
          total_commissions_due = GREATEST(0.00, total_commissions_due - v_comm),
          updated_at = now()
        WHERE nurse_id = v_nurse_profile_id;
      END IF;

      -- تحديث حالة المعاملة المالية إلى مرفوضة / ملغاة
      UPDATE public.financial_transactions
      SET
        status = 'rejected',
        notes = 'تم إلغاء مديونية العمولة تلقائياً بسبب إلغاء الحجز رقم ' || substring(NEW.id::text, 1, 8),
        updated_at = now()
      WHERE booking_id = NEW.id AND type = 'platform_commission';

      NEW.commission_recorded := false;
    END IF;

  -- =========================================================================
  -- الحالة الثالثة: اكتمال الزيارة (Transition: in_progress -> completed)
  -- =========================================================================
  ELSIF NEW.status = 'completed' AND OLD.status <> 'completed' THEN
    IF NEW.payment_method = 'cash' THEN
      v_comm := COALESCE(NEW.commission_amount, OLD.commission_amount, ROUND((NEW.total_price * (COALESCE(NEW.commission_rate, 15.00) / 100.0)), 2));
      
      IF COALESCE(OLD.commission_recorded, false) = true THEN
        -- العمولة مسجلة بالفعل عند القبول: تأكيدها فقط دون تسجيل عمولة ثانية
        UPDATE public.financial_transactions
        SET
          status = 'completed',
          notes = 'تم تأكيد عمولة منصة رعاية بعد اكتمال الزيارة رقم ' || substring(NEW.id::text, 1, 8),
          updated_at = now()
        WHERE booking_id = NEW.id AND type = 'platform_commission';

        -- إضافة إجمالي دخل الزيارة إلى محفظة الممرض دون مضاعفة الدين
        IF v_nurse_profile_id IS NOT NULL THEN
          UPDATE public.nurse_wallets
          SET
            total_visits_revenue = total_visits_revenue + NEW.total_price,
            updated_at = now()
          WHERE nurse_id = v_nurse_profile_id;
        END IF;

        NEW.commission_recorded := true;
      ELSE
        -- حجز نقدي سابق لم تُسجل عمولته عند القبول (توافق مع الحجوزات القديمة)
        NEW.commission_recorded := true;
        IF v_nurse_profile_id IS NOT NULL AND v_comm > 0 THEN
          INSERT INTO public.nurse_wallets (
            nurse_id, nurse_user_id, commission_debt, total_visits_revenue, total_commissions_due, updated_at
          ) VALUES (
            v_nurse_profile_id, v_nurse_user_id, v_comm, NEW.total_price, v_comm, now()
          )
          ON CONFLICT (nurse_id) DO UPDATE SET
            commission_debt = public.nurse_wallets.commission_debt + v_comm,
            total_visits_revenue = public.nurse_wallets.total_visits_revenue + NEW.total_price,
            total_commissions_due = public.nurse_wallets.total_commissions_due + v_comm,
            updated_at = now();

          INSERT INTO public.financial_transactions (
            booking_id, nurse_id, nurse_user_id, patient_id, type, amount, status, payment_method, notes
          ) VALUES (
            NEW.id, v_nurse_profile_id, v_nurse_user_id, NEW.patient_id, 'platform_commission', v_comm, 'completed', 'cash',
            'عمولة منصة رعاية عن الزيارة رقم ' || substring(NEW.id::text, 1, 8)
          )
          ON CONFLICT (booking_id) WHERE (type = 'platform_commission') DO NOTHING;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 3. ربط التريجر بجدول bookings
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS booking_commission_lifecycle_trg ON public.bookings;
CREATE TRIGGER booking_commission_lifecycle_trg
BEFORE UPDATE OF status ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.trg_handle_booking_commission_lifecycle();

-- ------------------------------------------------------------
-- 4. تحديث دالة record_visit_commission لمنع أي تكرار وتأكيد العمولة بدقة
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_visit_commission(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_booking record;
  v_nurse record;
  v_rate numeric(5,2);
  v_comm numeric(10,2);
  v_net numeric(10,2);
  v_is_admin boolean;
  v_credit_payout boolean := false;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يجب تسجيل الدخول أولاً');
  END IF;

  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الحجز غير موجود');
  END IF;

  IF v_booking.status != 'completed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن تأكيد العمولة إلا بعد اكتمال الزيارة بنجاح');
  END IF;

  SELECT (role = 'admin') INTO v_is_admin FROM public.profiles WHERE id = v_caller_id;
  IF NOT COALESCE(v_is_admin, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.nurse_profiles 
      WHERE (id = v_booking.nurse_id OR user_id = v_booking.nurse_id) 
        AND user_id = v_caller_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'غير مصرح لك بتسجيل العمولة لهذا الحجز');
    END IF;
  END IF;

  -- إذا كانت العمولة مسجلة مسبقاً (عند القبول للحجز النقدي) يتم فقط تأكيدها دون أي مضاعفة
  IF v_booking.commission_recorded THEN
    UPDATE public.financial_transactions
    SET status = 'completed', updated_at = now()
    WHERE booking_id = p_booking_id AND type = 'platform_commission' AND status != 'completed';

    RETURN jsonb_build_object('success', true, 'message', 'تم تأكيد العمولة بنجاح دون تكرار');
  END IF;

  SELECT * INTO v_nurse FROM public.nurse_profiles WHERE id = v_booking.nurse_id;
  IF NOT FOUND THEN
    SELECT * INTO v_nurse FROM public.nurse_profiles WHERE user_id = v_booking.nurse_id;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الملف المهني للممرض غير موجود');
  END IF;

  v_rate := COALESCE(v_booking.commission_rate, 15.00);
  v_comm := COALESCE(v_booking.commission_amount, ROUND((v_booking.total_price * (v_rate / 100.0)), 2));
  v_net := COALESCE(v_booking.nurse_net_amount, ROUND(v_booking.total_price - v_comm, 2));

  IF v_booking.payment_method IN ('vodafone_cash', 'instapay') AND v_booking.payment_status = 'verified' AND NOT v_booking.nurse_payout_credited THEN
    v_credit_payout := true;
  END IF;

  UPDATE public.bookings
  SET 
    commission_rate = v_rate,
    commission_amount = v_comm,
    nurse_net_amount = v_net,
    commission_recorded = true,
    nurse_payout_credited = CASE WHEN v_credit_payout THEN true ELSE nurse_payout_credited END,
    updated_at = now()
  WHERE id = p_booking_id;

  INSERT INTO public.nurse_wallets (
    nurse_id, nurse_user_id, commission_debt, pending_payouts, total_visits_revenue, total_commissions_due, updated_at
  ) VALUES (
    v_nurse.id,
    v_nurse.user_id,
    CASE WHEN v_booking.payment_method = 'cash' THEN v_comm ELSE 0.00 END,
    CASE WHEN v_credit_payout THEN v_net ELSE 0.00 END,
    v_booking.total_price,
    v_comm,
    now()
  )
  ON CONFLICT (nurse_id) DO UPDATE SET 
    commission_debt = public.nurse_wallets.commission_debt + (CASE WHEN v_booking.payment_method = 'cash' THEN v_comm ELSE 0.00 END),
    pending_payouts = public.nurse_wallets.pending_payouts + (CASE WHEN v_credit_payout THEN v_net ELSE 0.00 END),
    total_visits_revenue = public.nurse_wallets.total_visits_revenue + v_booking.total_price,
    total_commissions_due = public.nurse_wallets.total_commissions_due + v_comm,
    updated_at = now();

  INSERT INTO public.financial_transactions (
    booking_id, nurse_id, nurse_user_id, patient_id, type, amount, status, payment_method, notes
  ) VALUES (
    v_booking.id, v_nurse.id, v_nurse.user_id, v_booking.patient_id, 'platform_commission', v_comm, 'completed', v_booking.payment_method,
    'عمولة منصة رعاية عن الزيارة رقم ' || substring(v_booking.id::text, 1, 8)
  )
  ON CONFLICT (booking_id) WHERE (type = 'platform_commission') DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'commission_rate', v_rate,
    'commission_amount', v_comm,
    'nurse_net_amount', v_net,
    'nurse_payout_credited', v_credit_payout
  );
END;
$$;

-- ------------------------------------------------------------
-- 5. ضبط الصلاحيات والمالكين
-- ------------------------------------------------------------
ALTER FUNCTION public.trg_protect_booking_immutability() OWNER TO postgres;
ALTER FUNCTION public.trg_handle_booking_commission_lifecycle() OWNER TO postgres;
ALTER FUNCTION public.record_visit_commission(uuid) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.record_visit_commission(uuid) TO authenticated;

