// Booking of the consultation call (after the consultation_applications form and, with
// BOOKING_DEPOSIT_REQUIRED, the deposit).
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/book-meeting
//   body: { token, starts_at, helper_id? }  (token = consultation_applications.token,
//         starts_at/helper_id from booking_slots(); helper_id omitted = "anyone")
// Deployed with --no-verify-jwt: called from the public page; the application
// token is the authorization.
//
// BOOKING_DOUBLE_OPT_IN=true (BOOKING_OPT_IN.md): hold_appointment() holds the slot
// ('pending_opt_in', booking_settings.opt_in_hold_minutes) and the lead gets only the
// "Potvrď svoj e-mail" link; confirm-meeting sends the invitation after the click. If
// that email fails right away, the owner gets a meeting-nudge to call her.
// → 200 { appointment: { …, status: "pending_opt_in", meet_link: null, opt_in_expires_at } }
//
// Otherwise: book_appointment() reserves the slot atomically ('pending', the DB
// refuses double bookings) → confirmBooking() (_shared/booking.ts): Google event,
// 'confirmed', emails to the lead, the helper and the owner, list 615.
// → 200 { appointment: { …, status: "confirmed", meet_link } }
//
// BOOKING_DEPOSIT_REQUIRED=true (supabase/web/LOVABLE_ZALOHA.md): only an application
// with the refundable deposit paid (deposit_paid, set by stripe-webhook) can book →
// otherwise 402 deposit_required. An application that already has a booking skips the
// check, so already_booked works as before.
//
// Secrets: BOOKING_DOUBLE_OPT_IN (optional, "true" = double opt-in), BOOKING_DEPOSIT_REQUIRED
// (optional, "true" = deposit first), BOOKING_ALLOWED_ORIGINS (see _shared/http.ts), the
// ones in _shared/booking.ts; SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json, preflight } from "../_shared/http.ts";
import {
  bookingTimeZone,
  confirmBooking,
  findByApplicationToken,
  loadAppointment,
  nudgeTargetOf,
  publicView,
  sendNudge,
  sendOptIn,
} from "../_shared/booking.ts";

const DOUBLE_OPT_IN = Deno.env.get("BOOKING_DOUBLE_OPT_IN") === "true";
const DEPOSIT_REQUIRED = Deno.env.get("BOOKING_DEPOSIT_REQUIRED") === "true";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

// book_appointment() error message → HTTP status + text for the page.
const ERRORS: Record<string, { status: number; message: string }> = {
  invalid_request: { status: 400, message: "Neplatná požiadavka." },
  application_not_found: { status: 404, message: "Prihláška sa nenašla. Vyplň prosím dotazník znova." },
  not_qualified: { status: 403, message: "Na pohovor sa momentálne nedá rezervovať." },
  deposit_required: { status: 402, message: "Pred výberom termínu je potrebné uhradiť vratnú zálohu 100 €." },
  already_booked: { status: 409, message: "Termín už máš rezervovaný." },
  slot_unavailable: { status: 409, message: "Tento termín už nie je voľný. Vyber si prosím iný." },
  calendar_unavailable: { status: 502, message: "Termín sa nepodarilo potvrdiť. Skús to prosím znova o chvíľu." },
  server_error: { status: 500, message: "Niečo sa pokazilo. Skús to prosím znova." },
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function fail(req: Request, code: keyof typeof ERRORS, extra: Record<string, unknown> = {}): Response {
  const { status, message } = ERRORS[code];
  return json(req, status, { error: code, message, ...extra });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return json(req, 405, { error: "method not allowed" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail(req, "invalid_request");
  }
  const token = body?.token;
  const startsAt = new Date(body?.starts_at);
  const helperId = body?.helper_id ?? null;
  if (
    typeof token !== "string" || token.length < 8 || token.length > 128 ||
    typeof body?.starts_at !== "string" || Number.isNaN(startsAt.getTime()) ||
    (helperId !== null && (typeof helperId !== "string" || !UUID_RE.test(helperId)))
  ) {
    return fail(req, "invalid_request");
  }

  // 0. Deposit paid? (Not for an existing booking: that one answers already_booked below.)
  if (DEPOSIT_REQUIRED) {
    const { data: app, error } = await supabase.from("consultation_applications").select("id, deposit_paid")
      .eq("token", token).maybeSingle();
    if (error) {
      console.error(`[book] deposit check failed: ${error.message}`);
      return fail(req, "server_error");
    }
    if (!app) return fail(req, "application_not_found");
    if (!app.deposit_paid && !(await findByApplicationToken(supabase, token))) {
      console.log(`[book] ${app.id} deposit not paid`);
      return fail(req, "deposit_required");
    }
  }

  // 1. Reserve (atomic; validates grid, availability, notice, horizon, overlaps).
  const { data: appointmentId, error: rpcError } = await supabase.rpc(
    DOUBLE_OPT_IN ? "hold_appointment" : "book_appointment",
    { p_token: token, p_starts_at: startsAt.toISOString(), p_helper_id: helperId },
  );
  if (rpcError) {
    const code = rpcError.message in ERRORS ? rpcError.message : "server_error";
    if (code === "server_error") console.error(`[book] reserve failed: ${rpcError.message}`);
    if (code === "already_booked") {
      // Double click / reload: hand back the existing booking (or hold) so the page can show it.
      const existing = await findByApplicationToken(supabase, token);
      return fail(req, code, existing ? { appointment: publicView(existing) } : {});
    }
    return fail(req, code as keyof typeof ERRORS);
  }

  const appointment = await loadAppointment(supabase, appointmentId as string);
  if (!appointment) {
    console.error(`[book] appointment ${appointmentId} vanished`);
    return fail(req, "server_error");
  }
  console.log(`[book] ${appointment.id} ${appointment.status} ${appointment.starts_at} with ${appointment.helper.name}`);

  const timeZone = await bookingTimeZone(supabase);

  // 2a. Double opt-in: only the confirmation link now. If it can't be sent (e.g. a
  // mistyped domain), the owner calls her while the slot is still held.
  if (DOUBLE_OPT_IN) {
    const sendError = await sendOptIn(supabase, appointment, timeZone);
    if (sendError) await sendNudge(supabase, nudgeTargetOf(appointment), "email_failed", timeZone);
    return json(req, 200, { appointment: publicView(appointment) });
  }

  // 2b. Direct: Google event + emails now. On failure release the slot.
  const result = await confirmBooking(supabase, appointment, timeZone);
  if (!result.ok) {
    await supabase.from("appointments").update({
      status: "cancelled",
      cancelled_at: new Date().toISOString(),
      cancel_reason: `${result.reason === "calendar" ? "calendar_error" : "confirm_error"}: ${result.message}`.slice(0, 1000),
    }).eq("id", appointment.id).eq("status", "pending");
    return fail(req, result.reason === "calendar" ? "calendar_unavailable" : "server_error");
  }
  return json(req, 200, { appointment: publicView(appointment) });
});
