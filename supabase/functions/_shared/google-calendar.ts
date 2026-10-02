// Google Calendar via the master account's OAuth refresh token.
//
// Secrets: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//          (scope calendar.events), GOOGLE_CALENDAR_ID (default "primary").
// Get the refresh token with supabase/web/bin/11-google-refresh-token.sh.

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const CALENDAR_API = "https://www.googleapis.com/calendar/v3";

let cached: { token: string; expiresAt: number } | null = null;

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`${name} not set`);
  return v;
}

async function accessToken(): Promise<string> {
  if (cached && cached.expiresAt > Date.now() + 60_000) return cached.token;

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env("GOOGLE_CLIENT_ID"),
      client_secret: env("GOOGLE_CLIENT_SECRET"),
      refresh_token: env("GOOGLE_REFRESH_TOKEN"),
      grant_type: "refresh_token",
    }),
  });
  const body = await res.json();
  if (!res.ok) {
    // invalid_grant = refresh token revoked/expired → run 11-google-refresh-token.sh again.
    throw new Error(`Google token refresh failed (${res.status}): ${body.error ?? ""} ${body.error_description ?? ""}`);
  }
  cached = { token: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return cached.token;
}

function calendarUrl(path: string, params: Record<string, string> = {}): string {
  const calendarId = encodeURIComponent(Deno.env.get("GOOGLE_CALENDAR_ID") || "primary");
  const qs = new URLSearchParams(params).toString();
  return `${CALENDAR_API}/calendars/${calendarId}/events${path}${qs ? `?${qs}` : ""}`;
}

async function call(method: string, url: string, body?: unknown): Promise<Response> {
  return fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${await accessToken()}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function fail(res: Response, what: string): Promise<never> {
  const text = await res.text();
  throw new Error(`Google ${what} failed (${res.status}): ${text.slice(0, 500)}`);
}

// deno-lint-ignore no-explicit-any
type GoogleEvent = Record<string, any>;

function meetLinkOf(event: GoogleEvent): string | null {
  return event.hangoutLink ??
    // deno-lint-ignore no-explicit-any
    event.conferenceData?.entryPoints?.find((e: any) => e.entryPointType === "video")?.uri ??
    null;
}

// Google event ids allow only [a-v0-9]; a UUID without dashes fits, which
// makes creation idempotent: a retry for the same appointment gets 409 and
// reads the existing event instead of creating a second one.
export function eventIdFor(appointmentId: string): string {
  return appointmentId.replaceAll("-", "").toLowerCase();
}

export type NewMeeting = {
  appointmentId: string;
  summary: string;
  description: string;
  start: string; // ISO
  end: string; // ISO
  timeZone: string;
  attendees: { email: string; displayName?: string }[];
};

// Creates the event with a Google Meet link; Google emails the invite to the
// attendees (sendUpdates=all). Returns the event id + Meet link.
export async function createMeeting(m: NewMeeting): Promise<{ eventId: string; meetLink: string }> {
  const eventId = eventIdFor(m.appointmentId);
  const res = await call("POST", calendarUrl("", { conferenceDataVersion: "1", sendUpdates: "all" }), {
    id: eventId,
    summary: m.summary,
    description: m.description,
    start: { dateTime: m.start, timeZone: m.timeZone },
    end: { dateTime: m.end, timeZone: m.timeZone },
    attendees: m.attendees,
    guestsCanInviteOthers: false,
    reminders: { useDefault: true },
    extendedProperties: { private: { appointment_id: m.appointmentId } },
    conferenceData: {
      createRequest: { requestId: m.appointmentId, conferenceSolutionKey: { type: "hangoutsMeet" } },
    },
  });

  let event: GoogleEvent;
  if (res.status === 409) {
    const existing = await call("GET", calendarUrl(`/${eventId}`, { conferenceDataVersion: "1" }));
    if (!existing.ok) await fail(existing, "event lookup");
    event = await existing.json();
  } else {
    if (!res.ok) await fail(res, "event create");
    event = await res.json();
  }

  // Meet creation can be asynchronous ("pending") — poll briefly.
  for (let i = 0; i < 4 && !meetLinkOf(event); i++) {
    await new Promise((r) => setTimeout(r, 750 * (i + 1)));
    const again = await call("GET", calendarUrl(`/${eventId}`, { conferenceDataVersion: "1" }));
    if (!again.ok) await fail(again, "event lookup");
    event = await again.json();
  }

  const meetLink = meetLinkOf(event);
  if (!meetLink) {
    await deleteMeeting(eventId).catch(() => {});
    throw new Error(`Google event ${eventId} has no Meet link (conference status: ${
      event.conferenceData?.createRequest?.status?.statusCode ?? "?"
    })`);
  }
  return { eventId, meetLink };
}

// Deletes the event and emails the cancellation to attendees. Already-deleted
// events count as success.
export async function deleteMeeting(eventId: string): Promise<void> {
  const res = await call("DELETE", calendarUrl(`/${encodeURIComponent(eventId)}`, { sendUpdates: "all" }));
  if (res.ok || res.status === 404 || res.status === 410) {
    await res.body?.cancel();
    return;
  }
  await fail(res, "event delete");
}
