// Double opt-in: the lead clicked the link in "Potvrď svoj e-mail" (BOOKING_OPT_IN.md).
// Called by the website page /pohovor/dakujem?t=<token>.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/confirm-meeting
//   body: { token }  (appointments.opt_in_token from the link)
//   → 200 { status: "confirmed", starts_at, ends_at, helper_name }
//     200 { status: "expired", rebook_token }   hold ran out; rebook_token = application token
//     200 { status: "not_found" }               unknown link, or the meeting was cancelled
//     400 { status: "error" }                   malformed token
//     502 { status: "error" }                   calendar / DB failed; the link works again until the hold ends
// Business outcomes are 200 so supabase.functions.invoke doesn't throw. Never returns
// the Meet link or contact details.
// Deployed with --no-verify-jwt: the link token is the authorization.
//
// Flow: claim_opt_in() (row lock; marks email_verified_at) → 'claimed': confirmBooking()
// (_shared/booking.ts: Google event, 'confirmed', lead / helper / owner emails, list 615);
// on failure release_claim() puts the hold back. 'processing' (a second call while the
// first one confirms: double click, StrictMode, a mail scanner): wait for its result.
//
// Secrets: BOOKING_ALLOWED_ORIGINS (see _shared/http.ts), the ones in _shared/booking.ts;
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json, preflight } from "../_shared/http.ts";
import { type Appointment, bookingTimeZone, confirmBooking, loadAppointment } from "../_shared/booking.ts";

const TOKEN_RE = /^[0-9a-f]{16,128}$/i;
const WAIT_MS = 15_000;
const POLL_MS = 1_000;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const CONFIRMED = new Set(["confirmed", "completed", "no_show"]);

const confirmedBody = (a: Appointment) => ({
  status: "confirmed",
  starts_at: a.starts_at,
  ends_at: a.ends_at,
  helper_name: a.helper.name,
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return json(req, 405, { status: "error" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  const token = body?.token;
  if (typeof token !== "string" || !TOKEN_RE.test(token)) return json(req, 400, { status: "error" });

  const { data, error } = await supabase.rpc("claim_opt_in", { p_token: token.toLowerCase() });
  const claim = (data as { outcome: string; appointment_id: string | null; rebook_token: string | null }[] | null)?.[0];
  if (error || !claim) {
    console.error(`[confirm] claim failed: ${error?.message ?? "no row"}`);
    return json(req, 502, { status: "error" });
  }
  console.log(`[confirm] ${claim.appointment_id ?? "-"} ${claim.outcome}`);

  switch (claim.outcome) {
    case "not_found":
      return json(req, 200, { status: "not_found" });
    case "expired":
      return json(req, 200, { status: "expired", rebook_token: claim.rebook_token });
    case "confirmed": {
      const a = await loadAppointment(supabase, claim.appointment_id!);
      return a ? json(req, 200, confirmedBody(a)) : json(req, 502, { status: "error" });
    }
    case "processing":
      return await waitForOther(req, claim.appointment_id!);
    case "claimed":
      break;
    default:
      console.error(`[confirm] unexpected outcome ${claim.outcome}`);
      return json(req, 502, { status: "error" });
  }

  const appointment = await loadAppointment(supabase, claim.appointment_id!);
  if (!appointment) {
    await supabase.rpc("release_claim", { p_appointment_id: claim.appointment_id });
    return json(req, 502, { status: "error" });
  }

  const result = await confirmBooking(supabase, appointment, await bookingTimeZone(supabase));
  if (!result.ok) {
    const { error: releaseError } = await supabase.rpc("release_claim", { p_appointment_id: appointment.id });
    if (releaseError) console.error(`[confirm] release ${appointment.id} failed: ${releaseError.message}`);
    await supabase.from("appointments").update({
      email_error: `confirm: ${result.reason}: ${result.message}`.slice(0, 1000),
    }).eq("id", appointment.id);
    return json(req, 502, { status: "error" });
  }
  return json(req, 200, confirmedBody(appointment));
});

// Another call is confirming this appointment. Report "confirmed" only once it is.
async function waitForOther(req: Request, id: string): Promise<Response> {
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    const a = await loadAppointment(supabase, id);
    if (!a) break;
    if (CONFIRMED.has(a.status)) return json(req, 200, confirmedBody(a));
    if (a.status !== "pending") break; // released back to the hold, or cancelled
  }
  return json(req, 502, { status: "error" });
}
