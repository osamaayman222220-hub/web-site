-- ============================================================================
-- CareNest (رعاية) - Platform Default Seed Data
-- File: supabase/seed.sql
-- Description:
--   Seed default medical services and platform configuration settings.
--   Does NOT insert any mock users, nurses, or personal data.
-- ============================================================================

-- 1. Services Catalog (قائمة الخدمات الطبية والتمريضية الأساسية)
INSERT INTO public.services (name_ar, name_en, description_ar, base_price, duration_minutes, icon, is_active)
VALUES
  ('رعاية كبار السن والمزمنين', 'Elderly & Chronic Care', 'متابعة العلامات الحيوية، قياس السكر والضغط، وإعطاء الأدوية لكبار السن وأصحاب الأمراض المزمنة.', 250.00, 120, '👵', true),
  ('العناية بالجروح والقرح الفراشية', 'Wound Care & Dressing', 'تطهير وتضميد الجروح الجراحية وقرح الفراش والقدم السكري بأدوات معقمة.', 200.00, 60, '🩹', true),
  ('إعطاء الحقن والمحاليل الطبية', 'Injections & IV Fluids', 'تركيب الكانيولا، تعليق المحاليل الوريدية، والحقن العضلي وتحت الجلد.', 150.00, 45, '💉', true),
  ('رعاية ما بعد العمليات الجراحية', 'Post-Surgical Care', 'متابعة خراطيم الدرنقة، الغيار الجراحي، وتسكين الألم بعد الخروج من المستشفى.', 300.00, 90, '🏥', true),
  ('رعاية الأم وحديثي الولادة', 'Mother & Newborn Care', 'رعاية السرة والصفراء لحديثي الولادة ومساعدة الأم بعد الولادة الطبيعية أو القيصرية.', 250.00, 90, '👶', true),
  ('سحب العينات للتحاليل المخبرية', 'Lab Sample Collection', 'سحب عينات الدم وسوائل الجسم من المنزل لنقلها للمختبر المعتمد.', 150.00, 30, '🧪', true),
  ('جلسات العلاج الطبيعي والتأهيل', 'Physical Therapy & Rehab', 'تمارين التأهيل الحركي لتحسين التوازن واستعادة وظائف العضلات بعد الجلطات والكسور.', 350.00, 60, '🩺', true),
  ('تركيب وتغيير القسطرة والرايل', 'Catheter & Ryle Tube', 'تركيب وتغيير قسطرة البول وأنبوب التغذية الأنفي المعدي بطريقة طبية معقمة.', 250.00, 60, '🚰', true)
ON CONFLICT (name_ar) DO UPDATE SET
  base_price = EXCLUDED.base_price,
  duration_minutes = EXCLUDED.duration_minutes,
  description_ar = EXCLUDED.description_ar,
  icon = EXCLUDED.icon,
  is_active = true;

-- 2. Platform Settings (إعدادات المنصة الرسمية)
INSERT INTO public.platform_settings (key, value, description)
VALUES
  ('commission_rate', '{"rate": 15.00}'::jsonb, 'نسبة عمولة المنصة المقتطعة من أرباح الزيارات التمريضية (15%)'),
  ('payment_accounts', '{"vodafone_cash": "01000000000", "instapay": "carenest@instapay"}'::jsonb, 'حسابات الدفع الإلكتروني المعتمدة للمنصة لتلقي التحويلات'),
  ('operational_regions', '{"governorates": ["القاهرة", "الجيزة", "الدقهلية", "البحيرة", "الغربية", "الفيوم", "بني سويف"]}'::jsonb, 'المحافظات المصرية المغطاة تشغيلياً')
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description;

