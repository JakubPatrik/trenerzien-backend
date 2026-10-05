// After the questionnaire (step 1): "Nová prihláška" email to the team + the lead
// imported into SmartEmailing list 609. Replaces the web's notifyApplicationSubmitted.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/application-submitted
//   body: { token }  (consultation_applications.token, generated in the browser)
//   → 200 { ok: true, status: "sent" | "already_processed", email_error?, sync_error? }
//     400 bad body · 404 unknown token
// Deployed with --no-verify-jwt: called fire-and-forget from the public page; the
// application token is the authorization, and each application is processed once
// (synced_to_smartemailing), so a token can't be replayed to spam the inbox.
//
// The team email goes to SMARTEMAILING_REPLY_TO (fallback SMARTEMAILING_SENDER_EMAIL).
// Secrets: SMARTEMAILING_* (see _shared/smartemailing.ts), BOOKING_ALLOWED_ORIGINS
// (see _shared/http.ts); SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json, preflight } from "../_shared/http.ts";
import { importContact, sendEmail } from "../_shared/smartemailing.ts";
import { type Application, applicationEmail } from "./email.ts";

const APPLICATIONS_LIST_ID = 609;
const TOKEN_RE = /^[0-9a-f]{16,128}$/i;

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  const token = body?.token;
  if (typeof token !== "string" || !TOKEN_RE.test(token)) return json(req, 400, { error: "invalid_request" });

  const { data: app, error } = await supabase.from("consultation_applications")
    .select("id, name, email, phone, age, current_weight, target_weight, health_issues, occupation, hobbies, genetics, life_changes, obstacles, vision_one_year, expectations, qualified, created_at, synced_to_smartemailing")
    .eq("token", token).maybeSingle();
  if (error) {
    console.error(`application lookup: ${error.message}`);
    return json(req, 500, { error: "server_error" });
  }
  if (!app) return json(req, 404, { error: "application_not_found" });
  if (app.synced_to_smartemailing) return json(req, 200, { ok: true, status: "already_processed" });

  const to = Deno.env.get("SMARTEMAILING_REPLY_TO") || Deno.env.get("SMARTEMAILING_SENDER_EMAIL") || "";
  const [mail, sync] = await Promise.allSettled([
    sendEmail(applicationEmail(app as Application, to)),
    importContact({ email: app.email, name: app.name, phone: app.phone }, [APPLICATIONS_LIST_ID]),
  ]);
  const emailError = mail.status === "rejected" ? errorMessage(mail.reason) : null;
  const syncError = sync.status === "rejected" ? errorMessage(sync.reason) : null;
  if (emailError) console.error(`application ${app.id} email: ${emailError}`);
  if (syncError) console.error(`application ${app.id} sync: ${syncError}`);

  // Marked processed once anything went out, so a retry can't send the team email twice.
  const { error: updateError } = await supabase.from("consultation_applications").update({
    synced_to_smartemailing: !syncError || !emailError,
    sync_error: [emailError && `email: ${emailError}`, syncError && `sync: ${syncError}`].filter(Boolean).join("\n") ||
      null,
  }).eq("id", app.id);
  if (updateError) console.error(`application ${app.id} update: ${updateError.message}`);

  return json(req, 200, {
    ok: true,
    status: "sent",
    ...(emailError ? { email_error: true } : {}),
    ...(syncError ? { sync_error: true } : {}),
  });
});
