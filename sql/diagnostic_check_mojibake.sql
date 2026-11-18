-- ============================================================
-- CareNest - فحص ومعاينة البيانات بحثاً عن أي نصوص مشوهة (Mojibake)
-- ============================================================

-- 1. فحص جدول الحسابات الشخصية (profiles)
SELECT id, full_name, phone, governorate, city, role, created_at
FROM profiles
WHERE full_name LIKE '%Ø%' 
   OR full_name LIKE '%Ù%'
   OR governorate LIKE '%Ø%'
   OR city LIKE '%Ø%';

-- 2. فحص جدول ملفات الممرضين (nurse_profiles)
SELECT id, user_id, specialization, qualifications, governorate, city
FROM nurse_profiles
WHERE specialization LIKE '%Ø%'
   OR specialization LIKE '%Ù%'
   OR qualifications LIKE '%Ø%'
   OR qualifications LIKE '%Ù%'
   OR bio LIKE '%Ø%'
   OR bio LIKE '%Ù%';

-- 3. فحص جدول ملفات أخصائيي العلاج الطبيعي (physiotherapist_profiles)
SELECT id, user_id, specialization, qualifications, governorate, city
FROM physiotherapist_profiles
WHERE specialization LIKE '%Ø%'
   OR specialization LIKE '%Ù%'
   OR qualifications LIKE '%Ø%'
   OR qualifications LIKE '%Ù%'
   OR bio LIKE '%Ø%'
   OR bio LIKE '%Ù%';

-- 4. فحص جدول الحجوزات (bookings)
SELECT id, service_type, patient_address, patient_notes, payment_rejection_reason
FROM bookings
WHERE service_type LIKE '%Ø%'
   OR service_type LIKE '%Ù%'
   OR patient_address LIKE '%Ø%'
   OR patient_notes LIKE '%Ø%';

-- 5. فحص جدول الخدمات (services) إن وجد
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'services') THEN
        PERFORM id, name, description FROM services WHERE name LIKE '%Ø%' OR name LIKE '%Ù%';
    END IF;
END $$;
