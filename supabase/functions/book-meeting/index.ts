// Booking of the consultation call (step 2 after the consultation_applications form).
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/book-meeting
//   body: { token, starts_at, helper_id? }  (token = consultation_applications.token,
//         starts_at/helper_id from booking_slots(); helper_id omitted = "anyone")
// Deployed with --no-verify-jwt: called from the public page; the application
// token is the authorization.
//
// Flow: book_appointment() reserves the slot atomically ('pending', the DB
// refuses double bookings) → Google Calendar event with Meet link (Google emails
// the invite only to the owner; lead + helper are added silently) → appointment
// 'confirmed' + booking_* columns on the application → SmartEmailing emails with
// pozvanka.ics to the lead and the helper, a summary to the owner, and the lead
// imported into SmartEmailing list 615 (failures are logged on the appointment,
// never fail the booking).
//
// Secrets: GOOGLE_* (see _shared/google-calendar.ts), SMARTEMAILING_* (see
// _shared/smartemailing.ts), BOOKING_ALLOWED_ORIGINS (see _shared/http.ts),
// BOOKING_OWNER_EMAIL (optional, default pohovory@trenerzien.sk; gets Google's
// invite and the owner email),
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json, preflight } from "../_shared/http.ts";
import { createMeeting, deleteMeeting, type Meeting } from "../_shared/google-calendar.ts";
import { importContact, NotConfiguredError, sendEmail } from "../_shared/smartemailing.ts";
import { ANSWER_COLUMNS, type Answers } from "../_shared/application.ts";
import { type BookingData, helperEmail, leadEmail, ownerEmail } from "./email.ts";

// Gets Google's own invite and the owner email for every booking.
const OWNER_EMAIL = Deno.env.get("BOOKING_OWNER_EMAIL") || "pohovory@trenerzien.sk";
// SmartEmailing list of leads who booked a call (the questionnaire puts them on 609).
const BOOKED_LIST_ID = 615;

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

type Appointment = {
  id: string;
  starts_at: string;
  ends_at: string;
  status: string;
  meet_link: string | null;
  helper: { name: string; email: string };
  application: Answers & { id: string; name: string; email: string; phone: string };
};

const APPOINTMENT_SELECT =
  `id, starts_at, ends_at, status, meet_link, helper:helpers(name, email), application:consultation_applications(id, name, email, phone, ${ANSWER_COLUMNS})`;

function publicView(a: Appointment) {
  return {
    id: a.id,
    starts_at: a.starts_at,
    ends_at: a.ends_at,
    status: a.status,
    helper_name: a.helper.name,
    meet_link: a.meet_link,
  };
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

  // 1. Reserve (atomic; validates grid, availability, notice, horizon, overlaps).
  const { data: appointmentId, error: rpcError } = await supabase.rpc("book_appointment", {
    p_token: token,
    p_starts_at: startsAt.toISOString(),
    p_helper_id: helperId,
  });
  if (rpcError) {
    const code = rpcError.message in ERRORS ? rpcError.message : "server_error";
    if (code === "server_error") console.error(`[book] book_appointment failed: ${rpcError.message}`);
    if (code === "already_booked") {
      // Double click / reload: hand back the existing booking so the page can show it.
      const existing = await findByToken(token);
      return fail(req, code, existing ? { appointment: publicView(existing) } : {});
    }
    return fail(req, code as keyof typeof ERRORS);
  }

  const appointment = await load(appointmentId as string);
  if (!appointment) {
    console.error(`[book] appointment ${appointmentId} vanished`);
    return fail(req, "server_error");
  }
  console.log(`[book] ${appointment.id} reserved ${appointment.starts_at} with ${appointment.helper.name}`);

  const { data: settings } = await supabase.from("booking_settings").select("timezone").maybeSingle();
  const timeZone = settings?.timezone ?? "Europe/Bratislava";

  // 2. Google Calendar event + Meet link. On failure release the slot.
  let meeting: Meeting;
  const lead = appointment.application;
  try {
    meeting = await createMeeting({
      appointmentId: appointment.id,
      summary: `Pohovor: ${lead.name} × ${appointment.helper.name}`,
      description: [
        "Pohovor Tréner ŽIEN.",
        "",
        `Klientka: ${lead.name}`,
        `E-mail: ${lead.email}`,
        ...(lead.phone ? [`Telefón: ${lead.phone}`] : []),
        "",
        "Rezervácia termínu je záväzná.",
      ].join("\n"),
      start: appointment.starts_at,
      end: appointment.ends_at,
      timeZone,
      notify: [{ email: OWNER_EMAIL }],
      silent: [
        { email: lead.email, displayName: lead.name },
        { email: appointment.helper.email, displayName: appointment.helper.name },
      ],
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[google] ${appointment.id}: ${message}`);
    await supabase.from("appointments").update({
      status: "cancelled",
      cancelled_at: new Date().toISOString(),
      cancel_reason: `calendar_error: ${message}`.slice(0, 1000),
    }).eq("id", appointment.id);
    return fail(req, "calendar_unavailable");
  }

  // 3. Confirm.
  const { error: confirmError } = await supabase.from("appointments").update({
    status: "confirmed",
    google_event_id: meeting.eventId,
    meet_link: meeting.meetLink,
  }).eq("id", appointment.id).eq("status", "pending");
  if (confirmError) {
    console.error(`[book] confirm ${appointment.id} failed: ${confirmError.message}`);
    await deleteMeeting(meeting.eventId).catch((e) => console.error(`[google] cleanup failed: ${e}`));
    return fail(req, "server_error");
  }
  appointment.status = "confirmed";
  appointment.meet_link = meeting.meetLink;

  // Legacy columns on the application (admin overview).
  const { error: appError } = await supabase.from("consultation_applications").update({
    booking_start: appointment.starts_at,
    booking_event_id: meeting.eventId,
    booking_meet_url: meeting.meetLink,
  }).eq("id", appointment.application.id);
  if (appError) console.error(`[book] application ${appointment.application.id} update failed: ${appError.message}`);

  // 4. Emails to the lead, the helper and the owner + the lead on list 615 — best
  // effort. confirmation_email_sent_at tracks the lead's email; any failure goes
  // to email_error.
  const data: BookingData = {
    eventId: meeting.eventId,
    organizerEmail: meeting.organizerEmail,
    start: new Date(appointment.starts_at),
    end: new Date(appointment.ends_at),
    timeZone,
    meetLink: meeting.meetLink,
    lead: { name: lead.name, email: lead.email, phone: lead.phone, answers: lead },
    helper: appointment.helper,
  };
  const [leadResult, helperResult, ownerResult, listResult] = await Promise.allSettled([
    sendEmail(leadEmail(data)),
    sendEmail(helperEmail(data)),
    sendEmail(ownerEmail(data, OWNER_EMAIL)),
    importContact({ email: lead.email, name: lead.name, phone: lead.phone }, [BOOKED_LIST_ID]),
  ]);
  const errors: string[] = [];
  for (
    const [who, r] of [
      ["lead", leadResult],
      ["helper", helperResult],
      ["owner", ownerResult],
      [`list ${BOOKED_LIST_ID}`, listResult],
    ] as const
  ) {
    if (r.status === "fulfilled") {
      console.log(`[smartemailing] ${appointment.id} ${who} ok${r.value ? ` (${r.value})` : ""}`);
      continue;
    }
    const message = r.reason instanceof Error ? r.reason.message : String(r.reason);
    (r.reason instanceof NotConfiguredError ? console.warn : console.error)(`[smartemailing] ${appointment.id} ${who}: ${message}`);
    errors.push(`${who}: ${message}`);
  }
  await supabase.from("appointments").update({
    ...(leadResult.status === "fulfilled" ? { confirmation_email_sent_at: new Date().toISOString() } : {}),
    email_error: errors.length ? errors.join(" | ").slice(0, 1000) : null,
  }).eq("id", appointment.id);

  console.log(`[book] ${appointment.id} confirmed`);
  return json(req, 200, { appointment: publicView(appointment) });
});

async function load(id: string): Promise<Appointment | null> {
  const { data, error } = await supabase.from("appointments").select(APPOINTMENT_SELECT).eq("id", id)
    .maybeSingle<Appointment>();
  if (error) console.error(`[db] appointment ${id} load failed: ${error.message}`);
  return data ?? null;
}

async function findByToken(token: string): Promise<Appointment | null> {
  const { data: app } = await supabase.from("consultation_applications").select("id").eq("token", token)
    .maybeSingle();
  if (!app) return null;
  const { data } = await supabase.from("appointments").select(APPOINTMENT_SELECT)
    .eq("application_id", app.id).neq("status", "cancelled").maybeSingle<Appointment>();
  return data ?? null;
}
