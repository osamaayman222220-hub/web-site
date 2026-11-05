// ============================================================
// CareNest - Excel Sync Edge Function
// Supabase Edge Function: excel-sync
// Receives Database Webhook events and updates OneDrive Excel
// Runtime: Deno (Supabase Edge Functions)
// ============================================================

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  schema: string;
  record: Record<string, unknown> | null;
  old_record: Record<string, unknown> | null;
}

interface GraphTokenResponse {
  access_token: string;
  expires_in: number;
  token_type: string;
}

// ---------------------------------------------------------------------------
// Configuration — all values come from Supabase Secrets (never hardcoded)
// ---------------------------------------------------------------------------
const AZURE_CLIENT_ID     = Deno.env.get('AZURE_CLIENT_ID')     ?? '';
const AZURE_CLIENT_SECRET = Deno.env.get('AZURE_CLIENT_SECRET') ?? '';
const MS_REFRESH_TOKEN    = Deno.env.get('MS_REFRESH_TOKEN')    ?? '';
const EXCEL_FILE_ID       = Deno.env.get('EXCEL_FILE_ID')       ?? '';
const SUPABASE_URL        = Deno.env.get('SUPABASE_URL')        ?? '';
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// Microsoft consumer (personal accounts) token endpoint
const MS_TOKEN_URL = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
const GRAPH_BASE   = 'https://graph.microsoft.com/v1.0';

// Map each Supabase table → Excel worksheet name
const TABLE_TO_SHEET: Record<string, string> = {
  profiles:       'Users',
  nurse_profiles: 'Nurses',
  bookings:       'Bookings',
  services:       'Services',
  reviews:        'Reviews',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Refresh the Microsoft Graph access token using the stored refresh token */
async function getAccessToken(): Promise<string> {
  const body = new URLSearchParams({
    client_id:     AZURE_CLIENT_ID,
    client_secret: AZURE_CLIENT_SECRET,
    grant_type:    'refresh_token',
    refresh_token: MS_REFRESH_TOKEN,
    scope:         'https://graph.microsoft.com/Files.ReadWrite offline_access',
  });

  const res = await fetch(MS_TOKEN_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body:    body.toString(),
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`MS token refresh failed (${res.status}): ${txt}`);
  }

  const data: GraphTokenResponse = await res.json();
  return data.access_token;
}

/** Call Microsoft Graph API with automatic retry on 401 */
async function graphRequest(
  method: string,
  path: string,
  body?: unknown,
  token?: string
): Promise<Response> {
  const accessToken = token ?? (await getAccessToken());
  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
  };

  const res = await fetch(`${GRAPH_BASE}${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  return res;
}

/** Get the named table range address in Excel sheet (for finding a row by ID) */
function getTableName(sheetName: string): string {
  // Excel table name must match what was created in the Excel file
  // Convention: Table_Users, Table_Nurses, etc.
  return `Table_${sheetName}`;
}

/** Format a Supabase record row for the given table into an array of cell values */
function formatRow(table: string, record: Record<string, unknown>): unknown[] {
  switch (table) {
    case 'profiles':
      return [
        record.id ?? '',
        record.full_name ?? '',
        record.email ?? '',
        record.phone ?? '',
        record.role ?? '',
        record.governorate ?? '',
        record.city ?? '',
        record.created_at ? new Date(record.created_at as string).toLocaleDateString('ar-EG') : '',
      ];

    case 'nurse_profiles':
      return [
        record.id ?? '',
        record.user_id ?? '',
        record.specialization ?? '',
        record.experience_years ?? '',
        record.visit_price ?? '',
        record.governorate ?? '',
        record.city ?? '',
        record.verified ? 'معتمد' : 'غير معتمد',
        record.is_active ? 'نشط' : 'غير نشط',
        record.created_at ? new Date(record.created_at as string).toLocaleDateString('ar-EG') : '',
      ];

    case 'bookings':
      return [
        record.id ?? '',
        record.patient_id ?? '',
        record.nurse_id ?? '',
        record.service_type ?? '',
        record.visit_date ?? '',
        record.start_time ?? '',
        record.price ?? '',
        record.status ?? '',
        record.patient_address ?? '',
        record.patient_notes ?? '',
        record.created_at ? new Date(record.created_at as string).toLocaleDateString('ar-EG') : '',
      ];

    case 'services':
      return [
        record.id ?? '',
        record.name_ar ?? '',
        record.name_en ?? '',
        record.base_price ?? '',
        record.duration_minutes ?? '',
        record.is_active ? 'نشط' : 'غير نشط',
        record.created_at ? new Date(record.created_at as string).toLocaleDateString('ar-EG') : '',
      ];

    case 'reviews':
      return [
        record.id ?? '',
        record.booking_id ?? '',
        record.patient_id ?? '',
        record.nurse_id ?? '',
        record.rating ?? '',
        record.comment ?? '',
        record.created_at ? new Date(record.created_at as string).toLocaleDateString('ar-EG') : '',
      ];

    default:
      return Object.values(record);
  }
}

/** Log sync event to excel_sync_log table */
async function logSyncEvent(
  sb: ReturnType<typeof createClient>,
  event: {
    table_name: string;
    event_type: string;
    record_id: string | null;
    status: 'success' | 'failed' | 'skipped';
    error_message?: string;
    retry_count?: number;
  }
) {
  try {
    await sb.from('excel_sync_log').insert({
      table_name:    event.table_name,
      event_type:    event.event_type,
      record_id:     event.record_id,
      status:        event.status,
      error_message: event.error_message ?? null,
      retry_count:   event.retry_count ?? 0,
      synced_at:     new Date().toISOString(),
    });
  } catch (logErr) {
    // Don't crash the main function just because logging failed
    console.error('Failed to log sync event:', logErr);
  }
}

// ---------------------------------------------------------------------------
// Core sync operations
// ---------------------------------------------------------------------------

/** INSERT: Add a new row to the Excel table */
async function syncInsert(
  token: string,
  sheetName: string,
  tableName: string,
  rowValues: unknown[]
): Promise<void> {
  const path = `/me/drive/items/${EXCEL_FILE_ID}/workbook/tables/${tableName}/rows`;
  const res = await graphRequest('POST', path, { values: [rowValues] }, token);

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`Graph INSERT failed (${res.status}): ${txt}`);
  }
}

/** UPDATE: Find row by ID (column 0) and update it */
async function syncUpdate(
  token: string,
  sheetName: string,
  tableName: string,
  recordId: string,
  rowValues: unknown[]
): Promise<void> {
  // First, get all rows to find the row index
  const getPath = `/me/drive/items/${EXCEL_FILE_ID}/workbook/tables/${tableName}/rows`;
  const getRes = await graphRequest('GET', getPath, undefined, token);

  if (!getRes.ok) {
    const txt = await getRes.text();
    throw new Error(`Graph GET rows failed (${getRes.status}): ${txt}`);
  }

  const data = await getRes.json();
  const rows: Array<{ index: number; values: unknown[][] }> = data.value ?? [];

  // Find the row where the first column (ID) matches
  const targetRow = rows.find((r) => {
    const rowId = r.values?.[0]?.[0];
    return String(rowId) === String(recordId);
  });

  if (!targetRow) {
    // Row not found — insert instead
    console.warn(`Row with ID ${recordId} not found in ${tableName}, inserting instead`);
    await syncInsert(token, sheetName, tableName, rowValues);
    return;
  }

  // Update the specific row by index
  const updatePath = `/me/drive/items/${EXCEL_FILE_ID}/workbook/tables/${tableName}/rows/itemAt(index=${targetRow.index})`;
  const updateRes = await graphRequest('PATCH', updatePath, { values: [rowValues] }, token);

  if (!updateRes.ok) {
    const txt = await updateRes.text();
    throw new Error(`Graph UPDATE failed (${updateRes.status}): ${txt}`);
  }
}

/** DELETE: Find row by ID and delete it */
async function syncDelete(
  token: string,
  sheetName: string,
  tableName: string,
  recordId: string
): Promise<void> {
  // Get all rows to find the row index
  const getPath = `/me/drive/items/${EXCEL_FILE_ID}/workbook/tables/${tableName}/rows`;
  const getRes = await graphRequest('GET', getPath, undefined, token);

  if (!getRes.ok) {
    const txt = await getRes.text();
    throw new Error(`Graph GET rows for delete failed (${getRes.status}): ${txt}`);
  }

  const data = await getRes.json();
  const rows: Array<{ index: number; values: unknown[][] }> = data.value ?? [];

  const targetRow = rows.find((r) => {
    const rowId = r.values?.[0]?.[0];
    return String(rowId) === String(recordId);
  });

  if (!targetRow) {
    console.warn(`Row with ID ${recordId} not found in ${tableName} for deletion — skipping`);
    return;
  }

  const deletePath = `/me/drive/items/${EXCEL_FILE_ID}/workbook/tables/${tableName}/rows/itemAt(index=${targetRow.index})`;
  const deleteRes = await graphRequest('DELETE', deletePath, undefined, token);

  if (!deleteRes.ok && deleteRes.status !== 404) {
    const txt = await deleteRes.text();
    throw new Error(`Graph DELETE failed (${deleteRes.status}): ${txt}`);
  }
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------
serve(async (req: Request) => {
  // Health check
  if (req.method === 'GET') {
    return new Response(JSON.stringify({ status: 'ok', function: 'excel-sync' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  // Validate required secrets are configured
  if (!AZURE_CLIENT_ID || !AZURE_CLIENT_SECRET || !MS_REFRESH_TOKEN || !EXCEL_FILE_ID) {
    console.error('Missing required secrets: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, MS_REFRESH_TOKEN, EXCEL_FILE_ID');
    return new Response(
      JSON.stringify({ error: 'Excel sync not configured — missing Supabase Secrets' }),
      { status: 503, headers: { 'Content-Type': 'application/json' } }
    );
  }

  // Parse webhook payload
  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response('Invalid JSON payload', { status: 400 });
  }

  const { type, table, record, old_record } = payload;
  console.log(`[excel-sync] ${type} on ${table}`);

  // Check if we handle this table
  const sheetName = TABLE_TO_SHEET[table];
  if (!sheetName) {
    console.log(`[excel-sync] Table "${table}" not mapped — skipping`);
    return new Response(JSON.stringify({ status: 'skipped', reason: 'table not mapped' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Initialize Supabase client for logging (uses service role key — server-side only)
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  const activeRecord = record ?? old_record;
  const recordId = String(activeRecord?.id ?? '');
  const tableName = getTableName(sheetName);

  try {
    // Get fresh access token
    const token = await getAccessToken();

    if (type === 'INSERT' && record) {
      const rowValues = formatRow(table, record);
      await syncInsert(token, sheetName, tableName, rowValues);

    } else if (type === 'UPDATE' && record) {
      const rowValues = formatRow(table, record);
      await syncUpdate(token, sheetName, tableName, recordId, rowValues);

    } else if (type === 'DELETE' && old_record) {
      await syncDelete(token, sheetName, tableName, recordId);

    } else {
      console.warn(`[excel-sync] Unexpected combination: type=${type}, record=${!!record}, old_record=${!!old_record}`);
    }

    // Log success
    await logSyncEvent(sb, {
      table_name: table,
      event_type: type,
      record_id:  recordId,
      status:     'success',
    });

    return new Response(
      JSON.stringify({ status: 'success', type, table, record_id: recordId }),
      { headers: { 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[excel-sync] Error:`, message);

    // Log failure
    await logSyncEvent(sb, {
      table_name:    table,
      event_type:    type,
      record_id:     recordId,
      status:        'failed',
      error_message: message,
    });

    return new Response(
      JSON.stringify({ status: 'error', error: message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});

