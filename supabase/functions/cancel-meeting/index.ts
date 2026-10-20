// Cancel a booked consultation call: an admin (any active booking, incl. an unconfirmed
// double opt-in hold), or the personalistka it belongs to (her own confirmed meeting that
// hasn't started; her helper record must be active).
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/cancel-meeting
//   headers: Authorization: Bearer <user access token>
//   body:    { appointment_id, reason? }
//   → 200 { cancelled: true }
//     400 invalid_request · 401 unauthorized · 403 forbidden · 404 not_found
//     409 { error: "not_active", status } | { error: "already_started" }
//     502 calendar_unavailable (nothing changed, try again) · 500 server_error
// Deployed with --no-verify-jwt; the user's token is verified here via Auth.
// Any origin (CORS): called from KLUB (klub.trenerzien.sk) and the WEB admin; the
// JWT is the authorization.
//
// Deletes the Google event (Google emails the cancellation to the lead and the
// helper), marks the appointment 'cancelled' — the slot is free again — and
// clears the booking_* columns on the application, so the lead can book anew.

import { createClient } from "npm:@supabase/supabase-js@2";
import { json as jsonFor, preflight } from "../_shared/http.ts";
import { deleteMeeting } from "../_shared/google-calendar.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const json = (req: Request, status: number, body: Record<string, unknown>) =>
  jsonFor(req, status, body, { anyOrigin: true });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req, { anyOrigin: true });
  if (req.method !== "POST") return json(req, 405, { error: "method not allowed" });

  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return json(req, 401, { error: "unauthorized" });
  const { data: auth, error: authError } = await supabase.auth.getUser(jwt);
  if (authError || !auth.user) return json(req, 401, { error: "unauthorized" });
  const userId = auth.user.id;

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  const appointmentId = body?.appointment_id;
  const reason = typeof body?.reason === "string" ? body.reason.slice(0, 1000) : null;
  if (typeof appointmentId !== "string") return json(req, 400, { error: "invalid_request" });

  const { data: appt, error } = await supabase
    .from("appointments")
    .select("id, status, starts_at, google_event_id, application_id, helper:helpers(user_id, active)")
    .eq("id", appointmentId)
    .maybeSingle<{
      id: string;
      status: string;
      starts_at: string;
      google_event_id: string | null;
      application_id: string;
      helper: { user_id: string | null; active: boolean };
    }>();
  if (error) {
    console.error(`[cancel] lookup ${appointmentId} failed: ${error.message}`);
    return json(req, 500, { error: "server_error" });
  }
  if (!appt) return json(req, 404, { error: "not_found" });

  const { data: isAdmin } = await supabase.rpc("has_role", { _user_id: userId, _role: "admin" });
  const isHelper = !isAdmin && appt.helper.user_id === userId && appt.helper.active;
  if (!isAdmin && !isHelper) return json(req, 403, { error: "forbidden" });

  // A personalistka only sees (and cancels) confirmed meetings; an admin also stuck or held ones.
  const cancellable = isAdmin ? ["confirmed", "pending", "pending_opt_in"] : ["confirmed"];
  if (!cancellable.includes(appt.status)) {
    return json(req, 409, { error: "not_active", status: appt.status });
  }
  if (isHelper && new Date(appt.starts_at) <= new Date()) {
    return json(req, 409, { error: "already_started" });
  }

  if (appt.google_event_id) {
    try {
      await deleteMeeting(appt.google_event_id);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[google] cancel ${appt.id}: ${message}`);
      return json(req, 502, { error: "calendar_unavailable" });
    }
  }

  const { error: updError } = await supabase.from("appointments").update({
    status: "cancelled",
    cancelled_at: new Date().toISOString(),
    cancel_reason: reason ?? `cancelled by ${isHelper ? "helper" : "admin"} ${userId}`,
  }).eq("id", appt.id);
  if (updError) {
    console.error(`[cancel] update ${appt.id} failed: ${updError.message}`);
    return json(req, 500, { error: "server_error" });
  }

  await supabase.from("consultation_applications")
    .update({ booking_start: null, booking_event_id: null, booking_meet_url: null })
    .eq("id", appt.application_id)
    .eq("booking_event_id", appt.google_event_id ?? "");

  console.log(`[cancel] ${appt.id} cancelled by ${userId}`);
  return json(req, 200, { cancelled: true });
});
