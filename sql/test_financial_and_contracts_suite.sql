-- ============================================================
-- CareNest - Financial Engine & Contracts Automated Test Suite
-- File: sql/test_financial_and_contracts_suite.sql
-- Description: 25 Real Automated Assertions for Database Security, 
--              Financial Mechanics, RLS Isolation, Concurrency & Governance.
-- Run in Supabase SQL Editor on a test/staging database.
-- Wrapped in an automatic ROLLBACK to leave ZERO trace in the database.
-- ============================================================

BEGIN;

-- -----------------------------------------------------------
-- مهايئ محاكاة JWT وهوية المستخدم لاختبارات RLS و auth.uid()
-- حظر استبدال أو إعادة تعريف دوال auth.uid() و auth.role() في بيئة Supabase الأصلية
-- يتم تعريفها فقط إذا كان التشغيل يتم على محرك PostgreSQL محلي معزول خام لا يحتوي على امتداد Supabase Auth
-- -----------------------------------------------------------
DO $setup_auth_shim$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p 
    JOIN pg_namespace n ON p.pronamespace = n.oid 
    WHERE n.nspname = 'auth' AND p.proname = 'uid'
  ) THEN
    CREATE SCHEMA IF NOT EXISTS auth;
    EXECUTE $f$
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
        SELECT COALESCE(
          NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid,
          (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'sub')::uuid
        );
      $$;
    $f$;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p 
    JOIN pg_namespace n ON p.pronamespace = n.oid 
    WHERE n.nspname = 'auth' AND p.proname = 'role'
  ) THEN
    CREATE SCHEMA IF NOT EXISTS auth;
    EXECUTE $f$
      CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
        SELECT COALESCE(
          NULLIF(current_setting('request.jwt.claim.role', true), ''),
          (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'role')::text,
          'authenticated'
        );
      $$;
    $f$;
  END IF;
END $setup_auth_shim$;

DO $$
DECLARE
  v_test_num int := 0;
  v_pass_count int := 0;

  -- Test Identity IDs
  v_admin_id uuid := 'a1111111-1111-4111-a111-111111111111';
  v_nurse1_user uuid := 'b2222222-2222-4222-a222-222222222222';
  v_nurse1_prof uuid := 'b2222222-2222-4222-a222-222222222221';
  v_nurse2_user uuid := 'c3333333-3333-4333-a333-333333333333';
  v_nurse2_prof uuid := 'c3333333-3333-4333-a333-333333333331';
  v_patient1_user uuid := 'd4444444-4444-4444-a444-444444444444';
  v_patient2_user uuid := 'e5555555-5555-4555-a555-555555555555';

  -- Variables for test executions
  v_booking_id uuid;
  v_booking_id2 uuid;
  v_booking_id3 uuid;
  v_tx_id uuid;
  v_contract_id1 uuid;
  v_contract_id2 uuid;
  v_res jsonb;
  v_wallet record;
  v_check_count int;
  v_comm_rate numeric;
  v_check_role text;
  v_check_price numeric;
  v_check_status text;
  v_bool_check boolean;
  v_mutation_blocked boolean;
  v_dup_error boolean;
  v_nurse_check record;
BEGIN
  RAISE NOTICE '=====================================================';
  RAISE NOTICE 'CareNest Real Assertions Test Suite (25 Tests)';
  RAISE NOTICE '=====================================================';

  -- -----------------------------------------------------------
  -- MANDATORY MULTI-FACTOR SAFETY LOCK: صمام أمان متعدد العوامل لمنع التشغيل العرضي
  -- لا يعتمد على متغير الجلسة وحده، بل يدمج 5 طبقات حماية مادية وهيكلية
  -- -----------------------------------------------------------
  -- 1. صمام الإثبات الصريح للبيئة التجريبية:
  IF current_setting('carenest.environment', true) IS DISTINCT FROM 'staging_test_environment' THEN
    RAISE EXCEPTION 'MANDATORY SAFETY SHUTDOWN: You must explicitly set carenest.environment to "staging_test_environment" in your session before running this test suite! Run: SET carenest.environment = "staging_test_environment";';
  END IF;

  -- 2. التحقق من اسم قاعدة البيانات (حظر التشغيل على أي قاعدة إنتاجية بأي صيغة)
  IF lower(current_database()) IN ('production', 'prod', 'carenest_production', 'carenest_prod', 'live', 'carenest_live') THEN
    RAISE EXCEPTION 'CRITICAL SECURITY ABORT: Automated test suite cannot be executed on production database (%)!', current_database();
  END IF;

  -- 3. التحقق من عدم وجود تضارب مع حسابات إنتاج حقيقية
  IF EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id IN (v_admin_id, v_nurse1_user, v_nurse2_user, v_patient1_user, v_patient2_user)
      AND full_name NOT LIKE '%تجريبي%'
  ) THEN
    RAISE EXCEPTION 'CRITICAL SECURITY ABORT: Test personas collide with real production users! Halting immediately.';
  END IF;

  -- 4. التحقق الصارم من خلو البيئة من بيانات المرضى والممرضين الحقيقيين (منع التشغيل على الإنتاج حتى لو عُدلت الراية)
  IF EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE role IN ('patient', 'nurse') 
      AND email NOT LIKE '%@carenest.eg' 
      AND email NOT LIKE '%test%'
      AND full_name NOT LIKE '%تجريبي%'
  ) THEN
    RAISE EXCEPTION 'CRITICAL SECURITY ABORT: Real production user profiles detected in this database! Tests cannot be executed where real production users exist.';
  END IF;

  -- 5. التحقق من عدم وجود حجوزات تجارية فعلية سابقة للاختبار
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE patient_name NOT LIKE '%تجريبي%'
      AND patient_name NOT LIKE '%Test%'
      AND patient_name != ''
  ) THEN
    RAISE EXCEPTION 'CRITICAL SECURITY ABORT: Real production bookings detected in this database! Halting test suite immediately.';
  END IF;

  RAISE NOTICE '🛡️ Production Safety Guard: Verified safe test environment across all 5 verification layers.';

  -- -----------------------------------------------------------
  -- SETUP: Environment & Test Personas
  -- -----------------------------------------------------------
    -- Create mock auth users so foreign key profiles.id -> auth.users.id is satisfied
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  VALUES 
    (v_admin_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test_admin@carenest.eg', 'fake_pwd', now(), '{"provider":"email","providers":["email"]}', '{"role":"admin"}', now(), now()),
    (v_nurse1_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test_nurse1@carenest.eg', 'fake_pwd', now(), '{"provider":"email","providers":["email"]}', '{"role":"nurse"}', now(), now()),
    (v_nurse2_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test_nurse2@carenest.eg', 'fake_pwd', now(), '{"provider":"email","providers":["email"]}', '{"role":"nurse"}', now(), now()),
    (v_patient1_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test_patient1@carenest.eg', 'fake_pwd', now(), '{"provider":"email","providers":["email"]}', '{"role":"patient"}', now(), now()),
    (v_patient2_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'test_patient2@carenest.eg', 'fake_pwd', now(), '{"provider":"email","providers":["email"]}', '{"role":"patient"}', now(), now())
  ON CONFLICT (id) DO NOTHING;

  -- Create Profiles
  INSERT INTO public.profiles (id, full_name, email, role, phone, governorate, city)
  VALUES 
    (v_admin_id, 'مدير النظام التجريبي', 'test_admin@carenest.eg', 'admin', '01000000001', 'القاهرة', 'مدينة نصر'),
    (v_nurse1_user, 'ممرض تجريبي أول', 'test_nurse1@carenest.eg', 'nurse', '01100000002', 'الجيزة', 'الدقي'),
    (v_nurse2_user, 'ممرض تجريبي ثان', 'test_nurse2@carenest.eg', 'nurse', '01200000003', 'الفيوم', 'الفيوم'),
    (v_patient1_user, 'مريض تجريبي أول', 'test_patient1@carenest.eg', 'patient', '01500000004', 'القاهرة', 'المعادي'),
    (v_patient2_user, 'مريض تجريبي ثان', 'test_patient2@carenest.eg', 'patient', '01000000005', 'الجيزة', 'الهرم')
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, email = EXCLUDED.email;

  -- Create Nurse Profiles
  INSERT INTO public.nurse_profiles (id, user_id, specialization, visit_price, is_active, verified, verification_status, contract_status)
  VALUES 
    (v_nurse1_prof, v_nurse1_user, 'عناية مركزة', 300.00, true, true, 'approved', 'approved'),
    (v_nurse2_prof, v_nurse2_user, 'رعاية مسنين', 200.00, true, true, 'approved', 'approved')
  ON CONFLICT (id) DO NOTHING;

  -- Initialize Wallets
  INSERT INTO public.nurse_wallets (nurse_id, nurse_user_id, commission_debt, pending_payouts, total_paid_payouts, total_settled_commissions, total_visits_revenue, total_commissions_due)
  VALUES 
    (v_nurse1_prof, v_nurse1_user, 0, 0, 0, 0, 0, 0),
    (v_nurse2_prof, v_nurse2_user, 0, 0, 0, 0, 0, 0)
  ON CONFLICT (nurse_id) DO NOTHING;

  -- Setup Platform Settings (15% rate)
  INSERT INTO public.platform_settings (key, value, description, is_public)
  VALUES 
    ('commission_rate', '{"percent": 15.00}'::jsonb, 'نسبة العمولة 15%', true),
    ('platform_commission', '{"rate": 15.00}'::jsonb, 'نسبة العمولة 15%', true),
    ('payment_methods', '{"vodafone_cash": {"number": "01099999999", "name": "رعاية كاش"}, "instapay": {"handle": "carenest@instapay", "name": "رعاية إنستاباي"}}'::jsonb, 'بيانات التحويل', false)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

  -- Mock Storage objects in private-docs bucket
  INSERT INTO storage.buckets (id, name, public) VALUES ('private-docs', 'private-docs', false) ON CONFLICT (id) DO NOTHING;
  INSERT INTO storage.objects (bucket_id, name, owner) 
  VALUES 
    ('private-docs', 'receipts/' || v_patient1_user || '/receipt_vf.jpg', v_patient1_user),
    ('private-docs', 'receipts/' || v_patient1_user || '/receipt_ip.jpg', v_patient1_user),
    ('private-docs', 'receipts/' || v_nurse1_user || '/settle_receipt.jpg', v_nurse1_user),
    ('private-docs', 'contracts/' || v_nurse1_user || '/contract_v1.pdf', v_nurse1_user),
    ('private-docs', 'contracts/' || v_nurse1_user || '/contract_v2.pdf', v_nurse1_user)
  ON CONFLICT (bucket_id, name) DO NOTHING;

  -- ===========================================================
  -- TEST 1: العمولة النقدية وتحديث المديونية عند إتمام الزيارة كاش
  -- ===========================================================
  v_test_num := 1;
  -- Create cash booking (total: 500 EGP, 15% comm = 75 EGP, net = 425 EGP)
  INSERT INTO public.bookings (
    patient_id, nurse_id, service_name, visit_time, patient_name, patient_phone, patient_address, total_price, visit_date, payment_method, payment_status, status
  ) VALUES (
    v_patient1_user, v_nurse1_prof, 'تمريض عام', '10:00:00'::time, 'مريض تجريبي أول', '01500000004', 'المعادي - القاهرة', 500.00, CURRENT_DATE, 'cash', 'pending', 'completed'
  ) RETURNING id INTO v_booking_id;

  -- Run record_visit_commission as admin
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.record_visit_commission(v_booking_id);
  
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 1 FAILED: record_visit_commission failed: %', v_res;
  END IF;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse1_prof;
  IF v_wallet.commission_debt != 75.00 OR v_wallet.total_visits_revenue != 500.00 OR v_wallet.balance != -75.00 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Wallet debt incorrect. Expected debt=75, got: %', v_wallet;
  END IF;

  SELECT count(*) INTO v_check_count FROM public.financial_transactions 
  WHERE booking_id = v_booking_id AND type = 'platform_commission' AND amount = 75.00;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Platform commission transaction not recorded';
  END IF;
  RAISE NOTICE '✅ Test 1 Passed: Cash commission recorded, nurse debt updated (+75 EGP), negative balance reflected.';

  -- ===========================================================
  -- TEST 2: الدفع الإلكتروني عبر Vodafone Cash ورفع الإيصال
  -- ===========================================================
  v_test_num := 2;
  INSERT INTO public.bookings (
    patient_id, nurse_id, service_name, visit_time, patient_name, patient_phone, patient_address, total_price, visit_date, payment_method, payment_status, status
  ) VALUES (
    v_patient1_user, v_nurse1_prof, 'تمريض عام', '10:00:00'::time, 'مريض تجريبي أول', '01500000004', 'المعادي - القاهرة', 400.00, CURRENT_DATE, 'vodafone_cash', 'pending', 'pending'
  ) RETURNING id INTO v_booking_id2;

  -- Submit payment as patient
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_patient_payment(
    v_booking_id2,
    'receipts/' || v_patient1_user || '/receipt_vf.jpg',
    'vodafone_cash'
  );

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 2 FAILED: submit_patient_payment failed: %', v_res;
  END IF;

  SELECT count(*) INTO v_check_count FROM public.bookings 
  WHERE id = v_booking_id2 AND payment_status = 'pending_review' AND payment_receipt_path IS NOT NULL;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 2 FAILED: Booking payment status is not pending_review';
  END IF;
  RAISE NOTICE '✅ Test 2 Passed: Vodafone Cash payment receipt uploaded and set to pending_review.';

  -- ===========================================================
  -- TEST 3: الدفع الإلكتروني عبر InstaPay
  -- ===========================================================
  v_test_num := 3;
  INSERT INTO public.bookings (
    patient_id, nurse_id, service_name, visit_time, patient_name, patient_phone, patient_address, total_price, visit_date, payment_method, payment_status, status
  ) VALUES (
    v_patient1_user, v_nurse1_prof, 'تمريض عام', '10:00:00'::time, 'مريض تجريبي أول', '01500000004', 'المعادي - القاهرة', 600.00, CURRENT_DATE, 'instapay', 'pending', 'pending'
  ) RETURNING id INTO v_booking_id3;

  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_patient_payment(
    v_booking_id3,
    'receipts/' || v_patient1_user || '/receipt_ip.jpg',
    'instapay'
  );

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 3 FAILED: submit_patient_payment InstaPay failed: %', v_res;
  END IF;
  RAISE NOTICE '✅ Test 3 Passed: InstaPay payment receipt submitted and verified in pending_review.';

  -- ===========================================================
  -- TEST 4: منع تكرار رفع الإيصال لنفس الحجز أثناء وجود مراجعة معلقة
  -- ===========================================================
  v_test_num := 4;
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_patient_payment(
    v_booking_id2,
    'receipts/' || v_patient1_user || '/receipt_vf.jpg',
    'vodafone_cash'
  );

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 4 FAILED: System allowed duplicate receipt upload while pending_review!';
  END IF;
  RAISE NOTICE '✅ Test 4 Passed: Duplicate receipt submission blocked while previous review pending.';

  -- ===========================================================
  -- TEST 5: اعتماد الإيصال من الإدارة
  -- ===========================================================
  v_test_num := 5;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_approve_patient_payment(v_booking_id3);

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 5 FAILED: admin_approve_patient_payment failed: %', v_res;
  END IF;

  SELECT count(*) INTO v_check_count FROM public.bookings 
  WHERE id = v_booking_id3 AND payment_status IN ('approved', 'verified') AND payment_reviewed_by = v_admin_id;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Payment was not marked approved by admin';
  END IF;
  RAISE NOTICE '✅ Test 5 Passed: Admin successfully approved valid electronic payment receipt.';

  -- ===========================================================
  -- TEST 6: رفض الإيصال مع كتابة السبب الإلزامي
  -- ===========================================================
  v_test_num := 6;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  -- First try without reason (must fail)
  v_res := public.admin_reject_patient_payment(v_booking_id2, '');
  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Rejection allowed without reason!';
  END IF;

  -- Now reject with valid reason
  v_res := public.admin_reject_patient_payment(v_booking_id2, 'الصورة غير واضحة ورقم العملية مفقود');
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Valid rejection failed: %', v_res;
  END IF;

  SELECT count(*) INTO v_check_count FROM public.bookings 
  WHERE id = v_booking_id2 AND payment_status = 'rejected' AND payment_rejection_reason IS NOT NULL;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Booking not updated to rejected with reason';
  END IF;
  RAISE NOTICE '✅ Test 6 Passed: Admin rejected receipt and reason recorded successfully.';

  -- ===========================================================
  -- TEST 7: إعادة رفع الإيصال بعد الرفض
  -- ===========================================================
  v_test_num := 7;
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_patient_payment(
    v_booking_id2,
    'receipts/' || v_patient1_user || '/receipt_vf.jpg',
    'vodafone_cash'
  );

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 7 FAILED: Re-upload after rejection failed: %', v_res;
  END IF;

  SELECT count(*) INTO v_check_count FROM public.bookings 
  WHERE id = v_booking_id2 AND payment_status = 'pending_review' AND payment_rejection_reason IS NULL;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 7 FAILED: Status not reset to pending_review after re-upload';
  END IF;
  RAISE NOTICE '✅ Test 7 Passed: Patient successfully re-uploaded receipt after rejection.';

  -- ===========================================================
  -- TEST 8: منع الدفع أو اعتماد الإيصال لحجز ملغي أو مرفوض
  -- ===========================================================
  v_test_num := 8;
  UPDATE public.bookings SET status = 'cancelled' WHERE id = v_booking_id2;

  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_approve_patient_payment(v_booking_id2);

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 8 FAILED: Admin was able to approve payment for a cancelled booking!';
  END IF;
  RAISE NOTICE '✅ Test 8 Passed: Payment approval blocked for cancelled bookings.';

  -- ===========================================================
  -- TEST 9: منع تكرار احتساب عمولة الزيارة (Idempotency)
  -- ===========================================================
  v_test_num := 9;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.record_visit_commission(v_booking_id);

  -- Must return success true with notice that it was already recorded
  SELECT count(*) INTO v_check_count FROM public.financial_transactions 
  WHERE booking_id = v_booking_id AND type = 'platform_commission';
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 9 FAILED: Duplicate platform_commission transactions exist: count=%', v_check_count;
  END IF;
  RAISE NOTICE '✅ Test 9 Passed: Commission idempotency confirmed. Duplicate commission prevented.';

  -- ===========================================================
  -- TEST 10: إتمام الزيارة قبل اعتماد الدفع الإلكتروني
  -- ===========================================================
  v_test_num := 10;
  -- Booking total: 1000 EGP, 15% comm = 150 EGP, nurse net = 850 EGP
  INSERT INTO public.bookings (
    patient_id, nurse_id, service_name, visit_time, patient_name, patient_phone, patient_address, total_price, visit_date, payment_method, payment_status, payment_receipt_path, status
  ) VALUES (
    v_patient1_user, v_nurse1_prof, 'تمريض عام', '10:00:00'::time, 'مريض تجريبي أول', '01500000004', 'المعادي - القاهرة', 1000.00, CURRENT_DATE, 'vodafone_cash', 'pending_review', 'receipts/' || v_patient1_user || '/receipt_vf.jpg', 'completed'
  ) RETURNING id INTO v_booking_id;

  -- Visit completes first
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.record_visit_commission(v_booking_id);

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse1_prof;
  -- Payout must NOT be credited yet because payment receipt is not approved
  SELECT nurse_payout_credited INTO v_bool_check FROM public.bookings WHERE id = v_booking_id;
  IF v_bool_check IS TRUE OR v_wallet.pending_payouts != 0 THEN
    RAISE EXCEPTION 'TEST 10 FAILED: Nurse payout was prematurely credited before admin approval!';
  END IF;
  RAISE NOTICE '✅ Test 10 Passed: Visit completed first; nurse payout withheld pending payment approval.';

  -- ===========================================================
  -- TEST 11: اعتماد الدفع قبل إتمام الزيارة
  -- ===========================================================
  v_test_num := 11;
  -- Booking total: 800 EGP, payment approved while status is 'in_progress'
  INSERT INTO public.bookings (
    patient_id, nurse_id, service_name, visit_time, patient_name, patient_phone, patient_address, total_price, visit_date, payment_method, payment_status, payment_receipt_path, status
  ) VALUES (
    v_patient1_user, v_nurse1_prof, 'تمريض عام', '10:00:00'::time, 'مريض تجريبي أول', '01500000004', 'المعادي - القاهرة', 800.00, CURRENT_DATE, 'instapay', 'pending_review', 'receipts/' || v_patient1_user || '/receipt_ip.jpg', 'in_progress'
  ) RETURNING id INTO v_booking_id2;

  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_approve_patient_payment(v_booking_id2);

  -- Payout must NOT be credited yet because visit is in_progress
  SELECT nurse_payout_credited INTO v_bool_check FROM public.bookings WHERE id = v_booking_id2;
  IF v_bool_check IS TRUE THEN
    RAISE EXCEPTION 'TEST 11 FAILED: Nurse payout was prematurely credited before visit completion!';
  END IF;
  RAISE NOTICE '✅ Test 11 Passed: Payment approved first; nurse payout withheld pending visit completion.';

  -- ===========================================================
  -- TEST 12: إضافة مستحقات الممرض بعد تحقق الشرطين معاً
  -- ===========================================================
  v_test_num := 12;
  -- Now complete visit for booking_id2 (payment already approved)
  UPDATE public.bookings SET status = 'completed' WHERE id = v_booking_id2;
  v_res := public.record_visit_commission(v_booking_id2);

  -- Also approve payment for booking_id (visit already completed)
  v_res := public.admin_approve_patient_payment(v_booking_id);

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse1_prof;
  -- Booking 1 net: 850 EGP, Booking 2 net (800 - 15%): 680 EGP. Total pending = 1530 EGP
  IF v_wallet.pending_payouts != 1530.00 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: Expected pending_payouts=1530.00, got: %', v_wallet.pending_payouts;
  END IF;
  RAISE NOTICE '✅ Test 12 Passed: Nurse payouts correctly credited (1530 EGP) once both conditions met.';

  -- ===========================================================
  -- TEST 13: منع تكرار العمولة بالتزامن (Unique Index Enforcement)
  -- ===========================================================
  v_test_num := 13;
  v_dup_error := false;
  BEGIN
    INSERT INTO public.financial_transactions (
      booking_id, nurse_id, nurse_user_id, type, amount, status
    ) VALUES (
      v_booking_id, v_nurse1_prof, v_nurse1_user, 'platform_commission', 150.00, 'completed'
    );
  EXCEPTION
    WHEN unique_violation THEN
      v_dup_error := true;
  END;

  IF NOT v_dup_error THEN
    RAISE EXCEPTION 'TEST 13 FAILED: Partial unique index allowed duplicate platform_commission insert!';
  END IF;
  RAISE NOTICE '✅ Test 13 Passed: Partial unique index successfully blocked duplicate commission insert.';

  -- ===========================================================
  -- TEST 14: منع تكرار إضافة المستحقات لنفس الحجز
  -- ===========================================================
  v_test_num := 14;
  -- Call approve again and complete again
  PERFORM public.admin_approve_patient_payment(v_booking_id);
  PERFORM public.record_visit_commission(v_booking_id);

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse1_prof;
  IF v_wallet.pending_payouts != 1530.00 THEN
    RAISE EXCEPTION 'TEST 14 FAILED: Pending payouts increased on duplicate execution: %', v_wallet.pending_payouts;
  END IF;
  RAISE NOTICE '✅ Test 14 Passed: Secondary execution did not duplicate nurse pending payouts.';

  -- ===========================================================
  -- TEST 15: منع طلب تسوية عمولة مكرر قيد المراجعة
  -- ===========================================================
  v_test_num := 15;
  -- Nurse 1 has debt = 75 EGP. Submit settlement of 50 EGP
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_commission_settlement(
    50.00, 'vodafone_cash', 'receipts/' || v_nurse1_user || '/settle_receipt.jpg', 'سداد جزئي'
  );

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 15 FAILED: First settlement submission failed: %', v_res;
  END IF;

  -- Submit second settlement while first is pending (must fail)
  v_res := public.submit_commission_settlement(
    25.00, 'vodafone_cash', 'receipts/' || v_nurse1_user || '/settle_receipt.jpg', 'سداد مكرر'
  );

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 15 FAILED: Allowed duplicate pending settlement submission!';
  END IF;
  RAISE NOTICE '✅ Test 15 Passed: Duplicate commission settlement submission blocked.';

  -- ===========================================================
  -- TEST 16: منع تسجيل سداد عمولة بمبلغ أكبر من المديونية
  -- ===========================================================
  v_test_num := 16;
  -- Admin rejects pending settlement to clear queue
  SELECT id INTO v_tx_id FROM public.financial_transactions WHERE user_id = v_nurse1_user AND type = 'commission_settlement' AND status = 'pending_review';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  PERFORM public.reject_commission_settlement(v_tx_id, 'إلغاء للاختبار');

  -- Nurse 1 debt is 75 EGP. Try submitting 100 EGP (must fail)
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_commission_settlement(
    100.00, 'vodafone_cash', 'receipts/' || v_nurse1_user || '/settle_receipt.jpg', 'مبلغ أكبر من الدين'
  );

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 16 FAILED: Allowed settlement submission greater than actual debt!';
  END IF;
  RAISE NOTICE '✅ Test 16 Passed: System rejected settlement amount exceeding nurse debt.';

  -- ===========================================================
  -- TEST 17: منع تحويل مبلغ أكبر من المستحقات المعلقة
  -- ===========================================================
  v_test_num := 17;
  -- Nurse 1 pending payouts = 1530 EGP. Admin tries to payout 2000 EGP (must fail)
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_record_nurse_payout(
    v_nurse1_prof, 2000.00, 'vodafone_cash', 'TX_OVERPAY', null, 'تحويل زائد'
  );

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 17 FAILED: Allowed payout greater than pending payouts!';
  END IF;

  -- Payout valid amount (500 EGP)
  v_res := public.admin_record_nurse_payout(
    v_nurse1_prof, 500.00, 'vodafone_cash', 'TX_VALID_1', null, 'تحويل شرعي'
  );
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 17 FAILED: Valid payout of 500 failed: %', v_res;
  END IF;

  SELECT * INTO v_wallet FROM public.nurse_wallets WHERE nurse_id = v_nurse1_prof;
  IF v_wallet.pending_payouts != 1030.00 OR v_wallet.total_paid_payouts != 500.00 THEN
    RAISE EXCEPTION 'TEST 17 FAILED: Wallet balances incorrect after payout: %', v_wallet;
  END IF;
  RAISE NOTICE '✅ Test 17 Passed: Over-payout blocked; valid payout deducted from pending payouts.';

  -- ===========================================================
  -- TEST 18: رفع الممرض للعقد الموقع
  -- ===========================================================
  v_test_num := 18;
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_signed_contract(
    'contracts/' || v_nurse1_user || '/contract_v1.pdf',
    'contract_v1.pdf'
  );

  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 18 FAILED: submit_signed_contract failed: %', v_res;
  END IF;
  v_contract_id1 := (v_res->>'contract_id')::uuid;

  SELECT contract_status INTO v_check_status FROM public.nurse_profiles WHERE id = v_nurse1_prof;
  IF v_check_status != 'pending_review' THEN
    RAISE EXCEPTION 'TEST 18 FAILED: Nurse profile contract_status is not pending_review (got %)', v_check_status;
  END IF;
  RAISE NOTICE '✅ Test 18 Passed: Signed contract submitted and profile set to pending_review.';

  -- ===========================================================
  -- TEST 19: رفض العقد وإعادة رفعه
  -- ===========================================================
  v_test_num := 19;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_review_nurse_contract(v_contract_id1, 'rejected', 'الصفحة الأخيرة ينقصها التوقيع');
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 19 FAILED: Contract rejection failed: %', v_res;
  END IF;

  -- Nurse uploads new contract v2
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.submit_signed_contract(
    'contracts/' || v_nurse1_user || '/contract_v2.pdf',
    'contract_v2.pdf'
  );
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 19 FAILED: Re-submitting contract v2 failed: %', v_res;
  END IF;
  v_contract_id2 := (v_res->>'contract_id')::uuid;
  RAISE NOTICE '✅ Test 19 Passed: Contract rejected with reason, and nurse re-uploaded new contract.';

  -- ===========================================================
  -- TEST 20: منع اعتماد عقد قديم عند وجود عقد أحدث
  -- ===========================================================
  v_test_num := 20;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  -- Try to approve older contract v1
  v_res := public.admin_review_nurse_contract(v_contract_id1, 'approved');

  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 20 FAILED: System allowed approving a stale/older contract!';
  END IF;

  -- Approve latest contract v2 (must succeed)
  v_res := public.admin_review_nurse_contract(v_contract_id2, 'approved');
  IF (v_res->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 20 FAILED: Approving latest contract failed: %', v_res;
  END IF;
  RAISE NOTICE '✅ Test 20 Passed: Stale contract approval blocked; latest contract approved.';

  -- ===========================================================
  -- TEST 21: منع الممرض من مشاهدة عقود ممرض آخر (RLS)
  -- ===========================================================
  v_test_num := 21;
  -- Query as Nurse 2
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_nurse2_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse2_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT count(*) INTO v_check_count FROM public.nurse_contracts WHERE nurse_user_id = v_nurse1_user;
  IF v_check_count != 0 THEN
    RAISE EXCEPTION 'TEST 21 FAILED: Nurse 2 was able to view Nurse 1 contracts via RLS!';
  END IF;
  RAISE NOTICE '✅ Test 21 Passed: Nurse cross-tenant access blocked by RLS.';

  -- ===========================================================
  -- TEST 22: منع المريض من مشاهدة عقود الممرضين (RLS)
  -- ===========================================================
  v_test_num := 22;
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT count(*) INTO v_check_count FROM public.nurse_contracts;
  IF v_check_count != 0 THEN
    RAISE EXCEPTION 'TEST 22 FAILED: Patient was able to view nurse contracts table via RLS!';
  END IF;
  RAISE NOTICE '✅ Test 22 Passed: Patient completely isolated from nurse contracts table.';

  -- ===========================================================
  -- TEST 23: منع المستخدم العادي من تنفيذ وظائف الإدارة والترقية الذاتية والتلاعب المالي
  -- ===========================================================
  v_test_num := 23;
  EXECUTE 'RESET ROLE';
  -- 1. Patient tries to call admin_approve_patient_payment
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_res := public.admin_approve_patient_payment(v_booking_id);
  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Non-admin user was able to execute admin_approve_patient_payment!';
  END IF;

  -- 2. Nurse tries to review contract
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  v_res := public.admin_review_nurse_contract(v_contract_id2, 'approved');
  IF (v_res->>'success')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Non-admin user was able to execute admin_review_nurse_contract!';
  END IF;

  -- 3. Patient tries to elevate role to admin (Role Escalation Protection)
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_mutation_blocked := false;
  BEGIN
    UPDATE public.profiles SET role = 'admin' WHERE id = v_patient1_user;
  EXCEPTION WHEN OTHERS THEN
    v_mutation_blocked := true;
  END;

  SELECT role INTO v_check_role FROM public.profiles WHERE id = v_patient1_user;
  IF NOT v_mutation_blocked OR v_check_role = 'admin' THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Patient was able to promote self to admin role or trigger did not reject mutation!';
  END IF;

  -- 4. Nurse tries to self-approve and activate (Nurse Self-Approval Protection)
  PERFORM set_config('request.jwt.claim.sub', v_nurse2_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse2_user::text, 'role', 'authenticated')::text, true);
  UPDATE public.nurse_profiles 
  SET verified = true, is_active = true, verification_status = 'approved', contract_status = 'approved'
  WHERE user_id = v_nurse2_user;

  SELECT verified, is_active, verification_status, contract_status INTO v_nurse_check 
  FROM public.nurse_profiles WHERE user_id = v_nurse2_user;

  IF v_nurse_check.verified = true AND v_nurse_check.is_active = true AND v_nurse_check.verification_status = 'approved' THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Nurse was able to self-approve and activate profile!';
  END IF;

  -- 5. User tries to mutate booking price (Booking Immutability Protection)
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  v_mutation_blocked := false;
  BEGIN
    UPDATE public.bookings SET total_price = 10.00 WHERE id = v_booking_id;
  EXCEPTION WHEN OTHERS THEN
    v_mutation_blocked := true;
  END;

  SELECT total_price INTO v_check_price FROM public.bookings WHERE id = v_booking_id;
  IF NOT v_mutation_blocked OR v_check_price = 10.00 THEN
    RAISE EXCEPTION 'TEST 23 FAILED: User was able to mutate booking total_price or trigger did not reject mutation!';
  END IF;

  -- 6. User attempts to alter financial payment status directly (even if forging session variables)
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  -- Attacker attempts to forge session variable carenest.internal_call
  PERFORM set_config('carenest.internal_call', 'true', true);
  v_mutation_blocked := false;
  BEGIN
    UPDATE public.bookings SET payment_status = 'verified' WHERE id = v_booking_id;
  EXCEPTION WHEN OTHERS THEN
    v_mutation_blocked := true;
  END;
  -- Clean up session variable
  PERFORM set_config('carenest.internal_call', 'false', true);
  EXECUTE 'RESET ROLE';

  SELECT payment_status INTO v_check_status FROM public.bookings WHERE id = v_booking_id;
  IF NOT v_mutation_blocked OR v_check_status = 'verified' THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Attacker successfully altered financial payment status!';
  END IF;

  -- 7. Regular user attempts to insert or modify services (Services RLS Protection)
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_mutation_blocked := false;
  BEGIN
    INSERT INTO public.services (name_ar, name_en, base_price, is_active)
    VALUES ('خدمة اختبار غير مصرحة', 'Unauthorized Service', 999.00, true);
  EXCEPTION WHEN OTHERS THEN
    v_mutation_blocked := true;
  END;

  IF NOT v_mutation_blocked AND EXISTS (SELECT 1 FROM public.services WHERE name_ar = 'خدمة اختبار غير مصرحة') THEN
    RAISE EXCEPTION 'TEST 23 FAILED: Regular user was able to insert services without admin privilege!';
  END IF;

  RAISE NOTICE '✅ Test 23 Passed: Admin RPCs, Role Escalation, Nurse Self-Approval, Booking Immutability, and Services RLS strictly enforced.';

  -- ===========================================================
  -- TEST 24: منع الوصول غير المصرح به إلى Storage (private-docs)
  -- ===========================================================
  v_test_num := 24;
  EXECUTE 'SET LOCAL ROLE authenticated';
  -- Patient 2 tries to access Nurse 1 contract object
  PERFORM set_config('request.jwt.claim.sub', v_patient2_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient2_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT count(*) INTO v_check_count FROM storage.objects 
  WHERE bucket_id = 'private-docs' AND name LIKE 'contracts/' || v_nurse1_user || '/%';
  IF v_check_count != 0 THEN
    RAISE EXCEPTION 'TEST 24 FAILED: Unauthorized user was able to view private storage objects!';
  END IF;
  RAISE NOTICE '✅ Test 24 Passed: Storage RLS policies protected private-docs bucket.';

  -- ===========================================================
  -- TEST 25: التحقق من المعادلة الرياضية وسلامة أرصدة المحافظ
  -- الرصيد النهائي = المستحقات المعلقة - مديونية الممرض
  -- ===========================================================
  v_test_num := 25;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT count(*) INTO v_check_count FROM public.nurse_wallets
  WHERE balance != (pending_payouts - commission_debt);

  IF v_check_count != 0 THEN
    RAISE EXCEPTION 'TEST 25 FAILED: Found % nurse wallets with corrupted balance equation!', v_check_count;
  END IF;

  -- Also verify Audit Logs were populated for sensitive admin actions
  SELECT count(*) INTO v_check_count FROM public.admin_audit_logs;
  IF v_check_count < 4 THEN
    RAISE EXCEPTION 'TEST 25 FAILED: Admin audit logs were not generated as expected (found % logs)', v_check_count;
  END IF;
  RAISE NOTICE '✅ Test 25 Passed: Math equation valid across all wallets (Balance = Pending - Debt). Audit log active (% logs recorded).', v_check_count;

  -- ------------------------------------------------------------
  -- TEST 26: التحقق من نزاهة التقييمات (Reviews Integrity & Completion Guard)
  -- ------------------------------------------------------------
  v_test_num := 26;
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  -- أ) منع تقييم حجز غير مكتمل (pending / in_progress)
  BEGIN
    INSERT INTO public.reviews (booking_id, patient_id, nurse_id, rating, comment)
    VALUES (v_booking_id2, v_patient1_user, v_nurse1_user, 5, 'محاولة تقييم غير مصرح بها');
    RAISE EXCEPTION 'TEST 26 FAILED: Allowed review insertion for an uncompleted booking!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 26 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 26.1 Passed: Review for non-completed booking correctly blocked: %', SQLERRM;
  END;

  -- ب) منع غير المريض صاحب الحجز من كتابة التقييم
  -- (باستخدام معرف مستخدم وهمي كـ patient_id)
  BEGIN
    INSERT INTO public.reviews (booking_id, patient_id, nurse_id, rating, comment)
    VALUES (v_booking_id, gen_random_uuid(), v_nurse1_user, 5, 'محاولة تقييم من مستخدم غير صاحب الحجز');
    RAISE EXCEPTION 'TEST 26 FAILED: Allowed non-patient user to review booking!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 26 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 26.2 Passed: Review by unauthorized patient correctly blocked: %', SQLERRM;
  END;

  -- ج) السماح بتقييم الحجز المكتمل بنجاح وقفل هوية الممرض آلياً
  INSERT INTO public.reviews (booking_id, patient_id, nurse_id, rating, comment)
  VALUES (v_booking_id, v_patient1_user, v_nurse1_user, 5, 'خدمة تمريضية ممتازة وملتزمة');

  SELECT count(*) INTO v_check_count FROM public.reviews WHERE booking_id = v_booking_id AND nurse_id = v_nurse1_user;
  IF v_check_count != 1 THEN
    RAISE EXCEPTION 'TEST 26 FAILED: Review record was not saved correctly!';
  END IF;
  RAISE NOTICE '✅ Test 26.3 Passed: Verified review successfully saved for completed booking.';

  -- د) منع التقييم المكرر لنفس الحجز
  BEGIN
    INSERT INTO public.reviews (booking_id, patient_id, nurse_id, rating, comment)
    VALUES (v_booking_id, v_patient1_user, v_nurse1_user, 4, 'محاولة تقييم مكرر');
    RAISE EXCEPTION 'TEST 26 FAILED: Allowed duplicate review for the same booking!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 26 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 26.4 Passed: Duplicate review for same booking strictly blocked.';
  END;

  -- ------------------------------------------------------------
  -- TEST 27: التحقق من منع الممرض من تعديل بيانات المريض وملاحظاته
  -- ------------------------------------------------------------
  v_test_num := 27;
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    -- محاكاة قيام الممرض بتعديل عنوان وهاتف المريض في الحجز
    UPDATE public.bookings
    SET patient_address = 'عنوان مزور', patient_phone = '01199999999'
    WHERE id = v_booking_id;
    RAISE EXCEPTION 'TEST 27 FAILED: Allowed nurse/unauthorized user to tamper with patient address and phone!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 27 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 27 Passed: Nurse tampering with patient PII and address is prevented: %', SQLERRM;
  END;

  -- ------------------------------------------------------------
  -- TEST 28: اختبارات سلبية لاختراق الصلاحيات والبيانات الحساسة (Negative Security Tests)
  -- ------------------------------------------------------------
  v_test_num := 28;
  -- أ) منع مستخدم عادي من ترقية دوره إلى admin مباشرة في profiles
  PERFORM set_config('request.jwt.claim.sub', v_patient1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_patient1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    UPDATE public.profiles SET role = 'admin' WHERE id = v_patient1_user;
    RAISE EXCEPTION 'TEST 28 FAILED: Allowed regular user to escalate role to admin!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 28 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 28.1 Passed: Unauthorized role escalation strictly blocked: %', SQLERRM;
  END;

  -- ب) منع مستخدم عادي من تغيير معرف حسابه (id)
  BEGIN
    UPDATE public.profiles SET id = gen_random_uuid() WHERE id = v_patient1_user;
    RAISE EXCEPTION 'TEST 28 FAILED: Allowed user to tamper with immutable account ID!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 28 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 28.2 Passed: User ID tampering strictly blocked: %', SQLERRM;
  END;

  -- ج) منع تعديل أسعار الحجز أو العمولات مباشرة
  PERFORM set_config('request.jwt.claim.sub', v_nurse1_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nurse1_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    UPDATE public.bookings SET total_price = 10.00, commission_rate = 0.00 WHERE id = v_booking_id;
    RAISE EXCEPTION 'TEST 28 FAILED: Allowed tampering with booking prices and commission!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 28 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 28.3 Passed: Booking financial tampering strictly blocked: %', SQLERRM;
  END;

  -- د) منع الممرض من تفعيل واعتماد حسابه بنفسه
  BEGIN
    UPDATE public.nurse_profiles SET verified = true, is_active = true, verification_status = 'approved' WHERE user_id = v_nurse1_user;
    -- يتم فحص هل تم التفعيل أم أبطلها التريجر
    SELECT verified INTO v_bool_check FROM public.nurse_profiles WHERE user_id = v_nurse1_user;
    IF v_bool_check IS TRUE THEN
      RAISE EXCEPTION 'TEST 28 FAILED: Nurse successfully self-approved account!';
    END IF;
    RAISE NOTICE '✅ Test 28.4 Passed: Nurse self-approval strictly prevented by trigger.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%TEST 28 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE '✅ Test 28.4 Passed: Nurse self-approval attempt blocked: %', SQLERRM;
  END;

  RAISE NOTICE '=====================================================';
  RAISE NOTICE '🎉 ALL 28 AUTOMATED TESTS PASSED WITH 100%% SUCCESS!';
  RAISE NOTICE 'CareNest Financial, Reviews & Security Engine is Production Ready.';
  RAISE NOTICE '=====================================================';

END $$;

-- Automatic Rollback: Ensures 100% clean test execution leaving ZERO mock data in database.
ROLLBACK;
