-- ============================================================
-- CareNest - Test Suite for Migration v11 (Cash Commission on Acceptance)
-- File: sql/test_v11_cash_commission_suite.sql
-- ============================================================
-- Run this test in Supabase SQL Editor on a staging/test database.
-- Wrapped in an automatic ROLLBACK to leave ZERO trace in the database.
-- ============================================================

DO $$
DECLARE
  v_nurse_user_id uuid := gen_random_uuid();
  v_nurse_profile_id uuid := gen_random_uuid();
  v_patient_user_id uuid := gen_random_uuid();
  v_booking_id uuid := gen_random_uuid();
  v_booking_id2 uuid := gen_random_uuid();
  v_booking_id3 uuid := gen_random_uuid();
  
  v_wallet record;
  v_tx_count int;
  v_tx record;
  v_bk record;
BEGIN
  RAISE NOTICE '====================================================';
  RAISE NOTICE '🚀 بدء فحص واختبار نظام عمولة الحجوزات النقدية (v11)';
  RAISE NOTICE '====================================================';

  -- 1. إنشاء حسابات وهمية للاختبار
  INSERT INTO public.profiles (id, full_name, email, role, phone)
  VALUES 
    (v_nurse_user_id, 'ممرض اختبار العمولات', 'nurse_comm_test@carenest.eg', 'nurse', '01011111111'),
    (v_patient_user_id, 'مريض اختبار العمولات', 'patient_comm_test@carenest.eg', 'patient', '01022222222');

  INSERT INTO public.nurse_profiles (id, user_id, full_name, phone, is_active)
  VALUES (v_nurse_profile_id, v_nurse_user_id, 'ممرض اختبار العمولات', '01011111111', true);

  -- =========================================================================
  -- اختبار 1: قبول الحجز النقدي واحتساب المديونية فوراً بالسالب
  -- =========================================================================
  RAISE NOTICE '--- [اختبار 1]: إنشاء حجز نقدي بقيمة 200 ج.م وقبوله من الممرض ---';

  INSERT INTO public.bookings (
    id, patient_id, nurse_id, nurse_profile_id, service_name, visit_date, visit_time,
    total_price, payment_method, status, commission_rate, commission_amount, nurse_net_amount
  ) VALUES (
    v_booking_id, v_patient_user_id, v_nurse_user_id, v_nurse_profile_id, 'زيارة تمريضية نقدية',
    CURRENT_DATE, '10:00:00', 200.00, 'cash', 'pending', 15.00, 30.00, 170.00
  );

  -- الممرض يضغط «قبول الحجز»
  UPDATE public.bookings
  SET status = 'accepted', updated_at = now()
  WHERE id = v_booking_id;

  -- التحقق من جدول bookings
  SELECT * INTO v_bk FROM public.bookings WHERE id = v_booking_id;
  ASSERT v_bk.commission_recorded = true, '❌ فشل اختبار 1: commission_recorded يجب أن تصبح true عند القبول';
  ASSERT v_bk.commission_amount = 30.00, '❌ فشل اختبار 1: قيمة العمولة يجب أن تكون 30.00 ج.م';

  -- التحقق من محفظة الممرض nurse_wallets
  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse_profile_id;
  ASSERT v_wallet.commission_debt = 30.00, '❌ فشل اختبار 1: مديونية الممرض يجب أن تكون 30.00 ج.م';
  ASSERT v_wallet.balance = -30.00, '❌ فشل اختبار 1: صافي رصيد المحفظة يجب أن يظهر بالسالب (-30.00 ج.م)';

  -- التحقق من المعاملات المالية financial_transactions
  SELECT * INTO v_tx FROM public.financial_transactions WHERE booking_id = v_booking_id AND type = 'platform_commission';
  ASSERT v_tx.amount = 30.00, '❌ فشل اختبار 1: مبلغ المعاملة المالية يجب أن يكون 30.00 ج.م';
  ASSERT v_tx.status = 'pending_review', '❌ فشل اختبار 1: حالة العمولة عند القبول يجب أن تكون معلقة لحين انتهاء الزيارة';

  RAISE NOTICE '✅ [نجاح اختبار 1]: تم تسجيل عمولة 30 ج.م وظهرت مديونية بالسالب (-30 ج.م) في المحفظة فور القبول.';

  -- =========================================================================
  -- اختبار 2: منع تكرار احتساب العمولة عند تحديث الحالة مجدداً
  -- =========================================================================
  RAISE NOTICE '--- [اختبار 2]: محاولة قبول الحجز مرة أخرى للتحقق من منع التكرار ---';

  UPDATE public.bookings
  SET status = 'accepted', updated_at = now()
  WHERE id = v_booking_id;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse_profile_id;
  ASSERT v_wallet.commission_debt = 30.00, '❌ فشل اختبار 2: تم تكرار العمولة! المديونية يجب أن تظل 30.00 ج.م';
  ASSERT v_wallet.balance = -30.00, '❌ فشل اختبار 2: الرصيد تضاعف بالخطأ!';

  SELECT count(*) INTO v_tx_count FROM public.financial_transactions WHERE booking_id = v_booking_id AND type = 'platform_commission';
  ASSERT v_tx_count = 1, '❌ فشل اختبار 2: تم إنشاء أكثر من قيد مالي لنفس الحجز!';

  RAISE NOTICE '✅ [نجاح اختبار 2]: منع التكرار يعمل بدقة 100%% ولم يتم مضاعفة الدين.';

  -- =========================================================================
  -- اختبار 3: إلغاء الحجز بعد القبول وإسقاط المديونية تلقائياً
  -- =========================================================================
  RAISE NOTICE '--- [اختبار 3]: إلغاء الحجز والتحقق من تصفير المديونية تلقائياً ---';

  UPDATE public.bookings
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_booking_id;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse_profile_id;
  ASSERT v_wallet.commission_debt = 0.00, '❌ فشل اختبار 3: لم يتم إلغاء المديونية من المحفظة!';
  ASSERT v_wallet.balance = 0.00, '❌ فشل اختبار 3: رصيد المحفظة لم يعد إلى 0.00 بعد الإلغاء!';

  SELECT * INTO v_tx FROM public.financial_transactions WHERE booking_id = v_booking_id AND type = 'platform_commission';
  ASSERT v_tx.status = 'rejected', '❌ فشل اختبار 3: حالة الحركة المالية لم تُحوّل إلى مرفوضة / ملغاة!';

  RAISE NOTICE '✅ [نجاح اختبار 3]: تم إسقاط المديونية من محفظة الممرض وتصفير الحساب تلقائياً عند الإلغاء.';

  -- =========================================================================
  -- اختبار 4: اكتمال الزيارة وتأكيد العمولة دون مضاعفة الدين
  -- =========================================================================
  RAISE NOTICE '--- [اختبار 4]: تنفيذ دورة حجز كاملة (قبول -> جارية -> اكتمال) ---';

  INSERT INTO public.bookings (
    id, patient_id, nurse_id, nurse_profile_id, service_name, visit_date, visit_time,
    total_price, payment_method, status, commission_rate, commission_amount, nurse_net_amount
  ) VALUES (
    v_booking_id2, v_patient_user_id, v_nurse_user_id, v_nurse_profile_id, 'زيارة تمريضية مكتملة',
    CURRENT_DATE, '10:00:00', 200.00, 'cash', 'pending', 15.00, 30.00, 170.00
  );

  -- 1. قبول الحجز
  UPDATE public.bookings SET status = 'accepted', updated_at = now() WHERE id = v_booking_id2;
  -- 2. بدء الزيارة
  UPDATE public.bookings SET status = 'in_progress', updated_at = now() WHERE id = v_booking_id2;
  -- 3. اكتمال الزيارة
  UPDATE public.bookings SET status = 'completed', updated_at = now() WHERE id = v_booking_id2;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse_profile_id;
  ASSERT v_wallet.commission_debt = 30.00, '❌ فشل اختبار 4: المديونية يجب أن تكون 30.00 ج.م فقط (غير مكررة)';
  ASSERT v_wallet.total_visits_revenue = 200.00, '❌ فشل اختبار 4: إجمالي دخل الزيارات يجب أن يكون 200.00 ج.م';

  SELECT * INTO v_tx FROM public.financial_transactions WHERE booking_id = v_booking_id2 AND type = 'platform_commission';
  ASSERT v_tx.status = 'completed', '❌ فشل اختبار 4: حالة العمولة يجب أن تصبح completed بعد اكتمال الزيارة';

  SELECT count(*) INTO v_tx_count FROM public.financial_transactions WHERE booking_id = v_booking_id2 AND type = 'platform_commission';
  ASSERT v_tx_count = 1, '❌ فشل اختبار 4: يجب أن توجد حركة عمولة واحدة فقط!';

  RAISE NOTICE '✅ [نجاح اختبار 4]: تم تأكيد العمولة بعد اكتمال الزيارة دون تسجيل عمولة ثانية وبنجاح تام.';

  -- =========================================================================
  -- اختبار 5: عزل الدفع الإلكتروني (عدم تطبيق مديونية نقدية عند القبول)
  -- =========================================================================
  RAISE NOTICE '--- [اختبار 5]: فحص حجز دفع إلكتروني (فودافون كاش) للتأكد من عدم تسجيل مديونية ---';

  INSERT INTO public.bookings (
    id, patient_id, nurse_id, nurse_profile_id, service_name, visit_date, visit_time,
    total_price, payment_method, status, commission_rate, commission_amount, nurse_net_amount
  ) VALUES (
    v_booking_id3, v_patient_user_id, v_nurse_user_id, v_nurse_profile_id, 'زيارة تمريضية إلكترونية',
    CURRENT_DATE, '10:00:00', 300.00, 'vodafone_cash', 'pending', 15.00, 45.00, 255.00
  );

  -- قبول الحجز الإلكتروني
  UPDATE public.bookings SET status = 'accepted', updated_at = now() WHERE id = v_booking_id3;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse_profile_id;
  -- المديونية يجب أن تظل 30.00 ج.م فقط من الحجز النقدي السابق، ولم تتأثر بالحجز الإلكتروني!
  ASSERT v_wallet.commission_debt = 30.00, '❌ فشل اختبار 5: الدفع الإلكتروني أضاف مديونية بالخطأ!';

  SELECT count(*) INTO v_tx_count FROM public.financial_transactions WHERE booking_id = v_booking_id3 AND type = 'platform_commission';
  ASSERT v_tx_count = 0, '❌ فشل اختبار 5: لا يجب تسجيل حركة عمولة عند القبول للدفع الإلكتروني!';

  RAISE NOTICE '✅ [نجاح اختبار 5]: تم عزل الدفع الإلكتروني تماماً ولم تُسجل عليه أي مديونية عند القبول.';

  RAISE NOTICE '====================================================';
  RAISE NOTICE '🎉 اكتملت جميع اختبارات Migration v11 بنجاح 100%%';
  RAISE NOTICE '====================================================';

  -- التراجع التلقائي لضمان نظافة قاعدة البيانات تماماً
  RAISE EXCEPTION 'TEST_TRANSACTION_ROLLBACK_SAFE_EXIT';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM = 'TEST_TRANSACTION_ROLLBACK_SAFE_EXIT' THEN
    RAISE NOTICE '🧹 تم التراجع عن بيانات الاختبار بنجاح (Clean Rollback).';
  ELSE
    RAISE;
  END IF;
END;
$$;

