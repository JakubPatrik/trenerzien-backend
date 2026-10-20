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

// Google throttles short bursts on one calendar (403 rateLimitExceeded, even at a few
// bookings a day; a retry seconds later goes through). Backoff ≈ 15 s in total. Every
// call here is safe to repeat: the event id makes creation idempotent (409 → read it).
const RETRY_DELAYS_MS = [1000, 2000, 4000, 8000];

async function call(method: string, url: string, body?: unknown): Promise<Response> {
  for (let attempt = 0;; attempt++) {
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${await accessToken()}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (attempt >= RETRY_DELAYS_MS.length || !(await isRateLimited(res))) return res;
    await res.body?.cancel();
    const wait = RETRY_DELAYS_MS[attempt] + Math.round(Math.random() * 500);
    console.warn(`[google] ${method} rate limited, retry ${attempt + 1} in ${wait} ms`);
    await new Promise((r) => setTimeout(r, wait));
  }
}

async function isRateLimited(res: Response): Promise<boolean> {
  if (res.status === 429) return true;
  if (res.status !== 403) return false;
  return /rateLimitExceeded|userRateLimitExceeded/.test(await res.clone().text());
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
  notify: Attendee[]; // Google emails them the invite
  silent: Attendee[]; // guests (Meet access, calendar entry) without any Google email
};

type Attendee = { email: string; displayName?: string };

// Creates the event with a Google Meet link. Google emails the invite only to
// `notify` (created with sendUpdates=all); `silent` guests are added afterwards
// with sendUpdates=none — they get our own SmartEmailing confirmation + .ics.
// Note: the calendar's own account is the organizer and never gets an invite email.
// Returns the event id, Meet link and the organizer (the calendar's account).
export type Meeting = { eventId: string; meetLink: string; organizerEmail: string | null };

export async function createMeeting(m: NewMeeting): Promise<Meeting> {
  const insert = (id: string) =>
    call("POST", calendarUrl("", { conferenceDataVersion: "1", sendUpdates: "all" }), {
      id,
      summary: m.summary,
      description: m.description,
      start: { dateTime: m.start, timeZone: m.timeZone },
      end: { dateTime: m.end, timeZone: m.timeZone },
      attendees: m.notify,
      guestsCanInviteOthers: false,
      reminders: { useDefault: true },
      extendedProperties: { private: { appointment_id: m.appointmentId } },
      conferenceData: {
        createRequest: { requestId: id, conferenceSolutionKey: { type: "hangoutsMeet" } },
      },
    });

  let eventId = eventIdFor(m.appointmentId);
  let res = await insert(eventId);
  let event: GoogleEvent;
  if (res.status === 409) {
    const existing = await call("GET", calendarUrl(`/${eventId}`, { conferenceDataVersion: "1" }));
    if (!existing.ok) await fail(existing, "event lookup");
    event = await existing.json();
    // A failed earlier attempt for this appointment deleted its event (double opt-in
    // retries the same appointment); a deleted event keeps its id, so start a new one.
    if (event.status === "cancelled") {
      eventId = `${eventId}r${Date.now().toString(32)}`;
      res = await insert(eventId);
      if (!res.ok) await fail(res, "event create");
      event = await res.json();
    }
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

  // Add the silent guests (merged, so a retry after 409 is a no-op).
  // deno-lint-ignore no-explicit-any
  const current: any[] = event.attendees ?? [];
  const known = new Set(current.map((a) => String(a.email).toLowerCase()));
  const added = m.silent.filter((a) => !known.has(a.email.toLowerCase()));
  if (added.length) {
    const patched = await call("PATCH", calendarUrl(`/${eventId}`, { sendUpdates: "none" }), {
      attendees: [...current, ...added],
    });
    if (!patched.ok) {
      await deleteMeeting(eventId).catch(() => {});
      await fail(patched, "adding guests");
    }
    await patched.body?.cancel();
  }

  return { eventId, meetLink, organizerEmail: event.organizer?.email ?? null };
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
