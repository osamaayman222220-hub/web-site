// ============================================================
// CareNest - Edge Function: verify-visit-code (Version 2 - Secure)
// Supabase Edge Function (Deno Runtime)
//
// المهام الأمنية:
// 1. تقييد CORS بنطاقات موثوقة حصراً (منع Wildcard * مع الرؤوس الحساسة).
// 2. التحقق من صحة JWT الممرض وهوية صاحب الطلب.
// 3. استدعاء المعاملة الذرية (verify_visit_code_atomic) داخل PostgreSQL.
// 4. لا يتم قراءة أو إرجاع أي كود صريح نهائياً في الاستجابة أو السجلات.
// ============================================================

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL              = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY         = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

// النطاقات المسموح بها لسياسة CORS
const ALLOWED_ORIGINS = [
  'https://carenest.app',
  'http://localhost:55645',
  'http://127.0.0.1:55645'
];

function getCorsHeaders(requestOrigin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin'
  };
  if (requestOrigin && ALLOWED_ORIGINS.includes(requestOrigin.trim().toLowerCase())) {
    headers['Access-Control-Allow-Origin'] = requestOrigin;
  }
  return headers;
}

serve(async (req: Request) => {
  const origin = req.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  // التعامل مع طلبات Preflight (OPTIONS)
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ success: false, error: 'طريقة الطلب غير مسموح بها. استخدم POST فقط.' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    // 1. التحقق من وجود مفاتيح التكوين
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      console.error('[verify-visit-code] البيئة تفتقر إلى مفاتيح الإعداد.');
      return new Response(
        JSON.stringify({ success: false, error: 'خدمة التحقق غير مهيأة بالشكل الصحيح على الخادم.' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 2. التحقق من رأس المصادقة JWT
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ success: false, error: 'يجب توفير تصريح تسجيل الدخول (Bearer Token).' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 3. التحقق من صحة جلسة وهوية الممرض
    const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false }
    });

    const { data: { user }, error: authError } = await authClient.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: 'انتهت صلاحية جلسة تسجيل الدخول. يرجى تسجيل الدخول مجدداً.' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 4. قراءة المدخلات والتحقق من صحتها
    let body: { booking_id?: string; code?: string; code_type?: string };
    try {
      body = await req.json();
    } catch {
      return new Response(
        JSON.stringify({ success: false, error: 'بيانات الطلب غير صالحة (JSON غير سليم).' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { booking_id, code, code_type } = body;

    if (!booking_id || typeof booking_id !== 'string') {
      return new Response(
        JSON.stringify({ success: false, error: 'معرف الحجز (booking_id) مطلوب.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!code || typeof code !== 'string' || !/^\d{6}$/.test(code.trim())) {
      return new Response(
        JSON.stringify({ success: false, error: 'الكود يجب أن يتكون من 6 أرقام فقط.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!code_type || !['start', 'end'].includes(code_type)) {
      return new Response(
        JSON.stringify({ success: false, error: 'نوع الكود غير صالح (يجب أن يكون start أو end).' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 5. استدعاء المعاملة الذرية الآمنة في PostgreSQL عبر Service Role
    // هذه الدالة تنفذ القفل والتأكد والترقية وإنشاء كود النهاية كعملية واحدة متكاملة
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false }
    });

    const { data: result, error: rpcError } = await adminClient.rpc('verify_visit_code_atomic', {
      p_booking_id: booking_id.trim(),
      p_entered_code: code.trim(),
      p_code_type: code_type,
      p_nurse_user_id: user.id
    });

    if (rpcError) {
      console.error('[verify-visit-code] خطأ استدعاء الدالة الذرية:', rpcError);
      return new Response(
        JSON.stringify({
          success: false,
          error: rpcError.message || 'فشل تنفيذ عملية التحقق في قاعدة البيانات.'
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const statusCode = result?.status_code || (result?.success ? 200 : 400);

    // إرجاع النتيجة للممرض دون أي بيانات حساسة
    return new Response(
      JSON.stringify({
        success: result.success,
        message: result.message || result.error,
        new_status: result.new_status || null
      }),
      { status: statusCode, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('[verify-visit-code] خطأ غير متوقع:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'حدث خطأ داخلي أثناء معالجة الطلب.' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
