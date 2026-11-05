// CareNest Edge Function: save-national-id
// Deploy with: supabase functions deploy save-national-id
// Required secrets:
// - SUPABASE_URL
// - SUPABASE_ANON_KEY
// - SUPABASE_SERVICE_ROLE_KEY
// - NATIONAL_ID_ENCRYPTION_KEY (AES-256-GCM encryption for secure reversible retrieval)
// - NATIONAL_ID_SALT or NATIONAL_ID_HASH_SECRET (Keyed HMAC-SHA-256 fingerprint for duplicate detection)
// Never log or persist the national ID in plaintext.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeNationalId(value: unknown): string {
  return String(value ?? "")
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (digit) => String(digit.charCodeAt(0) - 0x06F0))
    .replace(/[\s-]/g, "")
    .trim();
}

function toHex(buffer: Uint8Array): string {
  return Array.from(buffer)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function getHmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function hashNationalId(nationalId: string, secret: string): Promise<string> {
  const key = await getHmacKey(secret);
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(nationalId),
  );
  return toHex(new Uint8Array(signature));
}

async function getAesGcmKey(rawSecret: string): Promise<CryptoKey> {
  const trimmed = rawSecret.trim();
  let keyBytes: Uint8Array;

  // If provided as a 64-character hex string (32 bytes)
  if (/^[0-9a-fA-F]{64}$/.test(trimmed)) {
    keyBytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      keyBytes[i] = parseInt(trimmed.substring(i * 2, i * 2 + 2), 16);
    }
  } else {
    // Deterministically derive a 256-bit key from the secret string via SHA-256
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(trimmed));
    keyBytes = new Uint8Array(hash);
  }

  return await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "AES-GCM" },
    false,
    ["encrypt", "decrypt"],
  );
}

async function encryptNationalId(
  nationalId: string,
  key: CryptoKey,
): Promise<{ encrypted: string; iv: string }> {
  // 12-byte (96-bit) standard nonce for AES-GCM
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(nationalId);

  const cipherBuffer = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    plaintext,
  );

  return {
    encrypted: toHex(new Uint8Array(cipherBuffer)),
    iv: toHex(iv),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const encryptionKeySecret = Deno.env.get("NATIONAL_ID_ENCRYPTION_KEY");
  const hashSecret = Deno.env.get("NATIONAL_ID_SALT") || Deno.env.get("NATIONAL_ID_HASH_SECRET");

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return jsonResponse(
      { success: false, error: "Supabase service configuration is incomplete" },
      500,
    );
  }

  // Encryption key is strictly required — never allow hashing without encryption
  if (!encryptionKeySecret) {
    return jsonResponse(
      { success: false, error: "مفتاح تشفير الرقم القومي غير مهيأ على الخادم." },
      500,
    );
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return jsonResponse({ success: false, error: "Authentication required" }, 401);
  }

  try {
    // 1. Authenticate user from the verified bearer token
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData, error: userError } = await userClient.auth.getUser();
    const user = userData?.user;
    if (userError || !user) {
      return jsonResponse({ success: false, error: "Invalid or expired session" }, 401);
    }

    // 2. Parse & normalize request body
    const body = await req.json().catch(() => null);
    const rawInput = body?.national_id ?? body?.nationalId;
    const nationalId = normalizeNationalId(rawInput);

    if (!/^[0-9]{14}$/.test(nationalId)) {
      return jsonResponse(
        { success: false, error: "الرقم القومي يجب أن يتكون من 14 رقمًا." },
        400,
      );
    }

    // 3. Compute keyed HMAC-SHA-256 fingerprint for duplicate detection
    const effectiveHashSecret = hashSecret || encryptionKeySecret;
    const nationalIdHash = await hashNationalId(nationalId, effectiveHashSecret);

    // 4. Compute authenticated AES-256-GCM ciphertext (strictly required)
    let encryptedHex: string;
    let ivHex: string;
    try {
      const encKey = await getAesGcmKey(encryptionKeySecret);
      const encResult = await encryptNationalId(nationalId, encKey);
      encryptedHex = encResult.encrypted;
      ivHex = encResult.iv;
    } catch (encErr) {
      console.error(
        "save-national-id encryption error:",
        encErr instanceof Error ? encErr.message : "unknown",
      );
      return jsonResponse(
        { success: false, error: "فشل تشفير الرقم القومي. لم يتم حفظ أي بيانات." },
        500,
      );
    }

    if (!encryptedHex || !ivHex) {
      return jsonResponse(
        { success: false, error: "تعذر إتمام تشفير الرقم القومي بشكل آمن." },
        500,
      );
    }

    // 5. Upsert into public.user_national_ids using service-role client
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const payload = {
      user_id: user.id,
      national_id_hash: nationalIdHash,
      encrypted_national_id: encryptedHex,
      encryption_iv: ivHex,
      updated_at: new Date().toISOString(),
    };

    const { error: saveError } = await adminClient
      .from("user_national_ids")
      .upsert(payload, { onConflict: "user_id" });

    if (saveError) {
      console.error("save-national-id database error:", saveError.code);
      if (saveError.code === "23505") {
        return jsonResponse(
          { success: false, error: "هذا الرقم القومي مرتبط بحساب آخر مسجل بالفعل." },
          409,
        );
      }
      return jsonResponse(
        { success: false, error: "تعذر حفظ الرقم القومي بشكل آمن في قاعدة البيانات." },
        500,
      );
    }

    return jsonResponse({ success: true });
  } catch (error) {
    console.error(
      "save-national-id unexpected error:",
      error instanceof Error ? error.message : "unknown",
    );
    return jsonResponse({ success: false, error: "تعذر معالجة الطلب." }, 500);
  }
});
