// Consultation reminder: on the day of a consultation (consultation_sessions.held_on),
// email every active club member that it starts tonight.
//
// Called by pg_cron at 8:00 Europe/Bratislava (web/migrations/11.sql →
// consultation_reminder_tick() → pg_net), only when there is a session today.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/consultation-reminder
//   headers: Authorization: Bearer <CONSULTATION_REMINDER_SECRET>
//   body:    {}                                  today's session → all recipients
//            { date: "YYYY-MM-DD" }              that day's session instead of today's
//            { test_to: "a@b.sk" }               one email to that address for the session on
//                                                `date` / today, or the next one; not logged
//   → 200 { ok: true, status: "no_session" } | { ok: true, status: "done", session, sent, failed }
//     401 wrong secret · 400 bad body · 500 lookup failed
// Deployed with --no-verify-jwt; the shared secret is checked here.
//
// Recipients: consultation_reminder_recipients() — is_club_member, not paused, has an email,
// notification_prefs.email_consultations, not yet sent for this session. Every send is
// logged to notification_emails (kind 'consultation_reminder', ref = session id), failures
// with the error, so running it again only retries the failed ones.
//
// Secrets: CONSULTATION_REMINDER_SECRET, CLUB_PUBLIC_URL (optional), SMARTEMAILING_*;
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json } from "../_shared/http.ts";
import { sendEmail } from "../_shared/smartemailing.ts";
import { reminderEmail } from "./email.ts";

const TIME_ZONE = "Europe/Bratislava";
const KIND = "consultation_reminder";
const BASE_URL = (Deno.env.get("CLUB_PUBLIC_URL") || "https://klub.trenerzien.sk").replace(/\/+$/, "");
const CONCURRENCY = 8;
const PAGE = 1000; // PostgREST row cap
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Session = { id: string; held_on: string; starts_at: string | null };
type Recipient = { user_id: string; email: string; name: string | null };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(req, 405, { error: "method not allowed" });

  const secret = Deno.env.get("CONSULTATION_REMINDER_SECRET");
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!secret || !safeEqual(token, secret)) return json(req, 401, { error: "unauthorized" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => ({}));
  const date = body?.date ?? today();
  const testTo = typeof body?.test_to === "string" ? body.test_to.trim() : null;
  if (typeof date !== "string" || !DATE_RE.test(date) || (testTo !== null && !testTo.includes("@"))) {
    return json(req, 400, { error: "bad_request" });
  }

  try {
    let query = admin.from("consultation_sessions").select("id, held_on, starts_at");
    query = testTo ? query.gte("held_on", date).order("held_on").limit(1) : query.eq("held_on", date);
    const { data: sessions, error } = await query;
    if (error) throw new Error(`session lookup: ${error.message}`);
    const session = sessions?.[0] as Session | undefined;
    if (!session) {
      console.log(`[consultation] ${date}: no session`);
      return json(req, 200, { ok: true, status: "no_session" });
    }
    const startsAt = startOf(session);

    if (testTo) {
      await sendEmail(reminderEmail({
        to: testTo,
        recipientName: null,
        startsAt,
        timeZone: TIME_ZONE,
        baseUrl: BASE_URL,
      }));
      console.log(`[consultation] test for ${session.held_on} → ${testTo}`);
      return json(req, 200, { ok: true, status: "done", session: session.held_on, sent: 1, failed: 0 });
    }

    const recipients = await loadRecipients(session.id);
    let sent = 0;
    let failed = 0;
    await mapLimit(recipients, CONCURRENCY, async (r) => {
      let error: string | null = null;
      try {
        await sendEmail(reminderEmail({
          to: r.email,
          recipientName: r.name,
          startsAt,
          timeZone: TIME_ZONE,
            baseUrl: BASE_URL,
        }));
        sent++;
      } catch (err) {
        error = (err instanceof Error ? err.message : String(err)).slice(0, 500);
        failed++;
        console.error(`[consultation] → ${r.user_id}: ${error}`);
      }
      const { error: logError } = await admin.from("notification_emails")
        .insert({ user_id: r.user_id, kind: KIND, ref: session.id, error });
      if (logError) console.error(`[consultation] log failed for ${r.user_id}: ${logError.message}`);
    });

    console.log(`[consultation] ${session.held_on}: sent ${sent}, failed ${failed}`);
    return json(req, 200, { ok: true, status: "done", session: session.held_on, sent, failed });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[consultation] ${message}`);
    return json(req, 500, { error: "server_error" });
  }
});

// Loaded in full before sending: sending logs rows, which shrinks the result between pages.
async function loadRecipients(sessionId: string): Promise<Recipient[]> {
  const out: Recipient[] = [];
  for (let from = 0;; from += PAGE) {
    const { data, error } = await admin.rpc("consultation_reminder_recipients", { _session_id: sessionId })
      .range(from, from + PAGE - 1);
    if (error) throw new Error(`recipients: ${error.message}`);
    out.push(...(data as Recipient[]));
    if (data.length < PAGE) return out;
  }
}

// YYYY-MM-DD in Bratislava.
function today(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TIME_ZONE }).format(new Date());
}

// starts_at, or 19:00 Bratislava on held_on for rows without it.
function startOf(s: Session): Date {
  if (s.starts_at) return new Date(s.starts_at);
  const utc = new Date(`${s.held_on}T19:00:00Z`);
  const local = new Date(utc.toLocaleString("en-US", { timeZone: TIME_ZONE }));
  const utcAsLocal = new Date(utc.toLocaleString("en-US", { timeZone: "UTC" }));
  return new Date(utc.getTime() - (local.getTime() - utcAsLocal.getTime()));
}

function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function mapLimit<T>(items: T[], n: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]);
  };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
}
