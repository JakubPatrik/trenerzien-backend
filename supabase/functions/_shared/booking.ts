// Booking core shared by book-meeting, confirm-meeting and booking-holds.
//
// confirmBooking(): Google Calendar event with Meet link (Google emails the invite
// only to the owner; lead + helper are added silently) → appointment 'confirmed' +
// booking_* columns on the application → SmartEmailing emails with pozvanka.ics to
// the lead and the helper, a summary to the owner, and the lead imported into
// SmartEmailing list 615 (failures are logged on the appointment, never fail the
// booking).
//
// Double opt-in (BOOKING_OPT_IN.md): sendOptIn() emails the lead the confirmation
// link for a 'pending_opt_in' hold; sendNudge() tells the owner to call her.
//
// Secrets: GOOGLE_* (see google-calendar.ts), SMARTEMAILING_* (see smartemailing.ts),
// BOOKING_OWNER_EMAIL (optional, default pohovory@trenerzien.sk; gets Google's
// invite, the owner email and the nudges), BOOKING_SITE_URL (optional, default
// https://trenerzien.sk; base of the confirmation link).

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createMeeting, deleteMeeting, type Meeting } from "./google-calendar.ts";
import { importContact, NotConfiguredError, sendEmail } from "./smartemailing.ts";
import { ANSWER_COLUMNS, type Answers } from "./application.ts";
import { type BookingData, helperEmail, leadEmail, nudgeEmail, optInEmail, ownerEmail } from "./booking-email.ts";

export const OWNER_EMAIL = Deno.env.get("BOOKING_OWNER_EMAIL") || "pohovory@trenerzien.sk";
const SITE_URL = (Deno.env.get("BOOKING_SITE_URL") || "https://trenerzien.sk").replace(/\/+$/, "");
// SmartEmailing list of leads who booked a call (the questionnaire puts them on 609).
const BOOKED_LIST_ID = 615;

export type Appointment = {
  id: string;
  starts_at: string;
  ends_at: string;
  status: string;
  meet_link: string | null;
  opt_in_token: string | null;
  opt_in_expires_at: string | null;
  helper: { name: string; email: string };
  application: Answers & { id: string; name: string; email: string; phone: string };
};

const APPOINTMENT_SELECT =
  `id, starts_at, ends_at, status, meet_link, opt_in_token, opt_in_expires_at, helper:helpers(name, email), application:consultation_applications(id, name, email, phone, ${ANSWER_COLUMNS})`;

// What the website may see (no contact details, no token).
export function publicView(a: Appointment) {
  return {
    id: a.id,
    starts_at: a.starts_at,
    ends_at: a.ends_at,
    status: a.status,
    helper_name: a.helper.name,
    meet_link: a.meet_link,
    opt_in_expires_at: a.opt_in_expires_at,
  };
}

export async function loadAppointment(supabase: SupabaseClient, id: string): Promise<Appointment | null> {
  const { data, error } = await supabase.from("appointments").select(APPOINTMENT_SELECT).eq("id", id)
    .maybeSingle<Appointment>();
  if (error) console.error(`[db] appointment ${id} load failed: ${error.message}`);
  return data ?? null;
}

// The application's active (not cancelled) appointment.
export async function findByApplicationToken(supabase: SupabaseClient, token: string): Promise<Appointment | null> {
  const { data: app } = await supabase.from("consultation_applications").select("id").eq("token", token)
    .maybeSingle();
  if (!app) return null;
  const { data } = await supabase.from("appointments").select(APPOINTMENT_SELECT)
    .eq("application_id", app.id).neq("status", "cancelled").maybeSingle<Appointment>();
  return data ?? null;
}

export async function bookingTimeZone(supabase: SupabaseClient): Promise<string> {
  const { data } = await supabase.from("booking_settings").select("timezone").maybeSingle();
  return data?.timezone ?? "Europe/Bratislava";
}

export type ConfirmResult = { ok: true } | { ok: false; reason: "calendar" | "db"; message: string };

// Turns a 'pending' appointment into 'confirmed' and sends everything. On failure nothing
// is confirmed and no Google event is left behind; the caller decides what happens to the
// slot (book-meeting cancels, confirm-meeting goes back to the hold).
export async function confirmBooking(
  supabase: SupabaseClient,
  appointment: Appointment,
  timeZone: string,
): Promise<ConfirmResult> {
  // 1. Google Calendar event + Meet link.
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
    return { ok: false, reason: "calendar", message };
  }

  // 2. Confirm.
  const { data: confirmed, error: confirmError } = await supabase.from("appointments").update({
    status: "confirmed",
    google_event_id: meeting.eventId,
    meet_link: meeting.meetLink,
  }).eq("id", appointment.id).eq("status", "pending").select("id");
  if (confirmError || !confirmed?.length) {
    const message = confirmError?.message ?? "appointment is no longer pending";
    console.error(`[book] confirm ${appointment.id} failed: ${message}`);
    await deleteMeeting(meeting.eventId).catch((e) => console.error(`[google] cleanup failed: ${e}`));
    return { ok: false, reason: "db", message };
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

  // 3. Emails to the lead, the helper and the owner + the lead on list 615 — best
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
  return { ok: true };
}

export const optInLink = (token: string) => `${SITE_URL}/pohovor/dakujem?t=${encodeURIComponent(token)}`;

// The confirmation link to the lead of a 'pending_opt_in' hold. Marks
// opt_in_email_sent_at, or email_error on failure. Returns the error message, or null.
export async function sendOptIn(supabase: SupabaseClient, a: Appointment, timeZone: string): Promise<string | null> {
  if (!a.opt_in_token || !a.opt_in_expires_at) return "appointment has no opt-in token";
  try {
    const id = await sendEmail(optInEmail({
      start: new Date(a.starts_at),
      end: new Date(a.ends_at),
      timeZone,
      expiresAt: new Date(a.opt_in_expires_at),
      link: optInLink(a.opt_in_token),
      lead: { name: a.application.name, email: a.application.email },
      helper: { name: a.helper.name },
    }));
    console.log(`[smartemailing] ${a.id} opt-in ok${id ? ` (${id})` : ""}`);
    await supabase.from("appointments").update({ opt_in_email_sent_at: new Date().toISOString(), email_error: null })
      .eq("id", a.id);
    return null;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    (err instanceof NotConfiguredError ? console.warn : console.error)(`[smartemailing] ${a.id} opt-in: ${message}`);
    await supabase.from("appointments").update({ email_error: `opt-in: ${message}`.slice(0, 1000) }).eq("id", a.id);
    return message;
  }
}

export type NudgeTarget = {
  id: string;
  starts_at: string;
  ends_at: string;
  opt_in_expires_at: string;
  helper_name: string;
  lead_name: string;
  lead_email: string;
  lead_phone: string | null;
};

export const nudgeTargetOf = (a: Appointment): NudgeTarget => ({
  id: a.id,
  starts_at: a.starts_at,
  ends_at: a.ends_at,
  opt_in_expires_at: a.opt_in_expires_at ?? a.starts_at,
  helper_name: a.helper.name,
  lead_name: a.application.name,
  lead_email: a.application.email,
  lead_phone: a.application.phone,
});

// meeting-nudge to the owner. Marks nudge_sent_at on success. Returns whether it was sent.
export async function sendNudge(
  supabase: SupabaseClient,
  t: NudgeTarget,
  reason: "expired" | "email_failed",
  timeZone: string,
): Promise<boolean> {
  try {
    await sendEmail(nudgeEmail({
      reason,
      start: new Date(t.starts_at),
      end: new Date(t.ends_at),
      timeZone,
      expiresAt: new Date(t.opt_in_expires_at),
      lead: { name: t.lead_name, email: t.lead_email, phone: t.lead_phone },
      helper: { name: t.helper_name },
    }, OWNER_EMAIL));
    await supabase.from("appointments").update({ nudge_sent_at: new Date().toISOString() }).eq("id", t.id);
    console.log(`[nudge] ${t.id} ${reason} → ${OWNER_EMAIL}`);
    return true;
  } catch (err) {
    console.error(`[nudge] ${t.id} ${reason}: ${err instanceof Error ? err.message : String(err)}`);
    return false;
  }
}
