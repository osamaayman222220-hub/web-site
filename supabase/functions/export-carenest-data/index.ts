// ------------------------------------------------------------
// Supabase Edge Function: export-carenest-data
// ------------------------------------------------------------
// Purpose: Export selected data (profiles, nurse_profiles, bookings, services)
//          for consumption by Excel Power Query.
// ------------------------------------------------------------

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------
// Environment variables (managed via Supabase Secrets)
// ---------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EXPORT_TOKEN = Deno.env.get("CARENEST_EXPORT_TOKEN") ?? ""; // secret, never exposed

// ---------------------------------------------------------------------
// CORS configuration – allow only trusted origins
// ---------------------------------------------------------------------
const ALLOWED_ORIGINS = [
  "https://carenest.app",
  "http://localhost:55645",
  "http://127.0.0.1:55645",
];

function getCorsHeaders(requestOrigin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
  if (requestOrigin && ALLOWED_ORIGINS.includes(requestOrigin.trim().toLowerCase())) {
    headers["Access-Control-Allow-Origin"] = requestOrigin;
  }
  return headers;
}

// ---------------------------------------------------------------------
// Helper: verify export token
// ---------------------------------------------------------------------
function isAuthorized(req: Request): boolean {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7).trim();
  return token === EXPORT_TOKEN && token.length > 0;
}

// ---------------------------------------------------------------------
// Helper: fetch all rows with pagination (max 1000 per page)
// ---------------------------------------------------------------------
async function fetchAll<T>(
  client: any,
  table: string,
  select: string,
  orderColumn = "id",
): Promise<T[]> {
  const pageSize = 1000;
  let from = 0;
  const all: T[] = [];
  while (true) {
    const { data, error } = await client
      .from(table)
      .select(select)
      .order(orderColumn, { ascending: true })
      .range(from, from + pageSize - 1);
    if (error) throw error;
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

// ---------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------
serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  const corsHeaders = getCorsHeaders(origin);

  // Pre‑flight handling
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "GET") {
    return new Response(
      JSON.stringify({ success: false, error: "Only GET requests are allowed." }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // -----------------------------------------------------------------
  // Authorization (export token)
  // -----------------------------------------------------------------
  if (!isAuthorized(req)) {
    return new Response(
      JSON.stringify({ success: false, error: "Invalid or missing export token." }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // -----------------------------------------------------------------
  // Initialise Supabase client (service role – full access)
  // -----------------------------------------------------------------
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ success: false, error: "Supabase configuration missing." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  try {
    // ---------------------------------------------------------------
    // 1️⃣ profiles – full safe fields (including role & created_at)
    // ---------------------------------------------------------------
    const profiles = await fetchAll<any>(admin, "profiles", "id, full_name, email, phone, role, created_at");
    const profilesById = new Map<string, any>();
    profiles.forEach(p => profilesById.set(p.id, p));

    // ---------------------------------------------------------------
    // 2️⃣ nurse_profiles – defined fields + link to profiles for contact info
    // ---------------------------------------------------------------
    const rawNurses = await fetchAll<any>(
      admin,
      "nurse_profiles",
      "id, user_id, specialization, experience_years, qualifications, bio, visit_price, governorate, city, verified, is_active, created_at",
    );
    const nurses = rawNurses.map(np => {
      const profile = profilesById.get(np.user_id) || {};
      return {
        ...np,
        nurse_name: profile.full_name ?? null,
        nurse_email: profile.email ?? null,
        nurse_phone: profile.phone ?? null,
      };
    });
    const nursesById = new Map<string, any>();
    nurses.forEach(n => nursesById.set(n.id, n));

    // ---------------------------------------------------------------
    // 3️⃣ services – full definition
    // ---------------------------------------------------------------
    const services = await fetchAll<any>(
      admin,
      "services",
      "id, name_ar, name_en, base_price, duration_minutes, is_active, created_at",
    );
    const servicesById = new Map<string, any>();
    services.forEach(s => servicesById.set(s.id, s));
    // Helper map for text‑based service lookup (name_ar / name_en) – normalized (no spaces, lower‑case)
    const servicesByName = new Map<string, any>();
    services.forEach(s => {
      if (s.name_ar) servicesByName.set(s.name_ar.replace(/\s+/g, "").toLowerCase(), s);
      if (s.name_en) servicesByName.set(s.name_en.replace(/\s+/g, "").toLowerCase(), s);
    });

    // ---------------------------------------------------------------
    // 4️⃣ bookings – enrich with patient & nurse & service info
    // ---------------------------------------------------------------
    const rawBookings = await fetchAll<any>(
      admin,
      "bookings",
      "id, patient_id, nurse_id, service_type, visit_date, start_time, end_time, price, status, created_at",
    );
    const bookings = rawBookings.map(b => {
      const patient = profilesById.get(b.patient_id) || {};
      const nurse = nursesById.get(b.nurse_id) || {};
      const serviceKey = b.service_type ? b.service_type.replace(/\s+/g, "").toLowerCase() : "";
      const service = servicesByName.get(serviceKey) || {};
      return {
        ...b,
        patient_name: patient.full_name ?? null,
        patient_email: patient.email ?? null,
        patient_phone: patient.phone ?? null,
        nurse_name: nurse.nurse_name ?? null,
        nurse_email: nurse.nurse_email ?? null,
        nurse_phone: nurse.nurse_phone ?? null,
        service_name_ar: service.name_ar ?? null,
        service_name_en: service.name_en ?? null,
        service_base_price: service.base_price ?? null,
        service_duration_minutes: service.duration_minutes ?? null,
      };
    });

    // ---------------------------------------------------------------
    // Successful response – ready for Power Query (plain JSON)
    // ---------------------------------------------------------------
    const payload = {
      success: true,
      data: {
        profiles,
        nurses,
        bookings,
        services,
      },
    };
    return new Response(JSON.stringify(payload), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("[export-carenest-data] Unexpected error", e);
    return new Response(
      JSON.stringify({ success: false, error: "Internal server error." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
