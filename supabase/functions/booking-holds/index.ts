// Double opt-in holds (BOOKING_OPT_IN.md): nudges for expired holds + support resend.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/booking-holds
//   headers: Authorization: Bearer <BOOKING_HOLDS_SECRET>
//   body: { action: "tick" }
//           pg_cron every 5 min (web/migrations/13.sql → booking_holds_tick() → pg_net),
//           only when expired_opt_in_holds() has rows: one meeting-nudge per expired hold
//           to the owner, marks nudge_sent_at (a failed one is retried on the next tick)
//           → 200 { ok: true, nudged, failed }
//         { action: "resend", appointment_id, email? }
//           support (25-resend-opt-in.sh): reissue_opt_in() — new link, hold again from
//           now, optionally a corrected email — then the "Potvrď svoj e-mail" email
//           → 200 { ok: true, email, opt_in_expires_at }
//             409 { error: "expired" | "not_pending" } · 404 not_found · 400 invalid_email / bad_request
//             502 { error: "send_failed", message } (the new link is issued, retry resends it)
//   401 wrong secret
// Deployed with --no-verify-jwt; the shared secret is checked here.
//
// Secrets: BOOKING_HOLDS_SECRET, the ones in _shared/booking.ts; SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json } from "../_shared/http.ts";
import { bookingTimeZone, loadAppointment, type NudgeTarget, sendNudge, sendOptIn } from "../_shared/booking.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REISSUE_ERRORS: Record<string, number> = { not_found: 404, expired: 409, not_pending: 409, invalid_email: 400 };

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(req, 405, { error: "method not allowed" });

  const secret = Deno.env.get("BOOKING_HOLDS_SECRET");
  const auth = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!secret || !safeEqual(auth, secret)) return json(req, 401, { error: "unauthorized" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => ({}));
  const timeZone = await bookingTimeZone(supabase);

  if (body?.action === "tick") {
    const { data, error } = await supabase.rpc("expired_opt_in_holds");
    if (error) {
      console.error(`[holds] expired_opt_in_holds failed: ${error.message}`);
      return json(req, 500, { error: "server_error" });
    }
    let nudged = 0, failed = 0;
    for (const row of (data ?? []) as (Omit<NudgeTarget, "id"> & { appointment_id: string })[]) {
      (await sendNudge(supabase, { ...row, id: row.appointment_id }, "expired", timeZone)) ? nudged++ : failed++;
    }
    console.log(`[holds] tick: nudged ${nudged}, failed ${failed}`);
    return json(req, 200, { ok: true, nudged, failed });
  }

  if (body?.action === "resend") {
    const id = body.appointment_id;
    const email = body.email ?? null;
    if (typeof id !== "string" || !UUID_RE.test(id) || (email !== null && typeof email !== "string")) {
      return json(req, 400, { error: "bad_request" });
    }
    const { data, error } = await supabase.rpc("reissue_opt_in", { p_appointment_id: id, p_email: email });
    if (error) {
      const status = REISSUE_ERRORS[error.message];
      if (!status) console.error(`[holds] reissue ${id} failed: ${error.message}`);
      return json(req, status ?? 500, { error: status ? error.message : "server_error" });
    }
    const issued = (data as { opt_in_expires_at: string; email: string }[])[0];
    const appointment = await loadAppointment(supabase, id);
    if (!appointment) return json(req, 500, { error: "server_error" });
    const sendError = await sendOptIn(supabase, appointment, timeZone);
    if (sendError) return json(req, 502, { error: "send_failed", message: sendError });
    console.log(`[holds] resent opt-in for ${id} to ${issued.email}`);
    return json(req, 200, { ok: true, email: issued.email, opt_in_expires_at: issued.opt_in_expires_at });
  }

  return json(req, 400, { error: "bad_request" });
});

function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}
