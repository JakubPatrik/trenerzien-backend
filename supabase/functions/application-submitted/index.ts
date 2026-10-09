// After the questionnaire (step 1): the lead imported into SmartEmailing list 609.
// No email is sent. Replaces the web's notifyApplicationSubmitted.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/application-submitted
//   body: { token }  (consultation_applications.token, generated in the browser)
//   → 200 { ok: true, status: "sent" | "already_processed", sync_error? }
//     400 bad body · 404 unknown token
// Deployed with --no-verify-jwt: called fire-and-forget from the public page; the
// application token is the authorization. A successful import marks the
// application synced_to_smartemailing; a failed one can be retried with the token
// (the import is an idempotent upsert).
//
// Secrets: SMARTEMAILING_USERNAME, SMARTEMAILING_API_KEY (see _shared/smartemailing.ts),
// BOOKING_ALLOWED_ORIGINS (see _shared/http.ts); SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json, preflight } from "../_shared/http.ts";
import { importContact } from "../_shared/smartemailing.ts";

const APPLICATIONS_LIST_ID = 609;
const TOKEN_RE = /^[0-9a-f]{16,128}$/i;

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  const token = body?.token;
  if (typeof token !== "string" || !TOKEN_RE.test(token)) return json(req, 400, { error: "invalid_request" });

  const { data: app, error } = await supabase.from("consultation_applications")
    .select("id, name, email, phone, synced_to_smartemailing")
    .eq("token", token).maybeSingle();
  if (error) {
    console.error(`application lookup: ${error.message}`);
    return json(req, 500, { error: "server_error" });
  }
  if (!app) return json(req, 404, { error: "application_not_found" });
  if (app.synced_to_smartemailing) return json(req, 200, { ok: true, status: "already_processed" });

  let syncError: string | null = null;
  try {
    await importContact({ email: app.email, name: app.name, phone: app.phone }, [APPLICATIONS_LIST_ID]);
  } catch (e) {
    syncError = e instanceof Error ? e.message : String(e);
    console.error(`application ${app.id} sync: ${syncError}`);
  }

  const { error: updateError } = await supabase.from("consultation_applications").update({
    synced_to_smartemailing: !syncError,
    sync_error: syncError,
  }).eq("id", app.id);
  if (updateError) console.error(`application ${app.id} update: ${updateError.message}`);

  return json(req, 200, { ok: true, status: "sent", ...(syncError ? { sync_error: true } : {}) });
});
