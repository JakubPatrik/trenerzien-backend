// KLUB notification emails (new chat message, pair request, pair accepted).
// The club only reports the event; preferences, throttling, recipient lookup,
// templates, sending and logging all live here.
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/notify-emails
//   headers: Authorization: Bearer <acting member's access token>
//   body:    { kind: "message" | "pair_request" | "pair_accepted", recipient_id, actor_id, ref }
//            ref = pair_requests.id (a chat is an accepted pair request: direct_messages.pair_id)
//   → 200 { ok: true, status: "sent" | "skipped_pref" | "skipped_throttle" | "skipped_no_email" }
//     400 bad body · 401 invalid JWT · 403 caller ≠ actor / not a member / not their pair
//     502 SmartEmailing failed (details only in logs + notification_emails.error)
// Deployed with --no-verify-jwt; the token is verified here.
//
// Order: auth → validate → pair check → notification_prefs → throttle (notification_emails
// in the last 60 min for messages, 5 min for pair kinds, same ref) → lookup → send → log.
// Failures are logged too, so the throttle also covers retries.
//
// Secrets: SMARTEMAILING_* (see _shared/smartemailing.ts), CLUB_PUBLIC_URL (optional,
// default https://klub.trenerzien.sk); SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json as jsonFor, preflight } from "../_shared/http.ts";
import { sendEmail } from "../_shared/smartemailing.ts";
import { type Kind, KINDS, notificationEmail } from "./email.ts";

const BASE_URL = (Deno.env.get("CLUB_PUBLIC_URL") || "https://klub.trenerzien.sk").replace(/\/+$/, "");
const THROTTLE_MINUTES: Record<Kind, number> = { message: 60, pair_request: 5, pair_accepted: 5 };
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const json = (req: Request, status: number, body: Record<string, unknown>) =>
  jsonFor(req, status, body, { anyOrigin: true });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req, { anyOrigin: true });
  if (req.method !== "POST") return json(req, 405, { error: "method not allowed" });

  // 1. Auth: the caller is the actor.
  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return json(req, 401, { error: "unauthorized" });
  const { data: auth, error: authError } = await admin.auth.getUser(jwt);
  if (authError || !auth.user) return json(req, 401, { error: "unauthorized" });

  // 2. Validate.
  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  const kind = body?.kind as Kind;
  const recipientId = body?.recipient_id;
  const actorId = body?.actor_id;
  const ref = body?.ref;
  if (
    !KINDS.includes(kind) ||
    typeof recipientId !== "string" || !UUID_RE.test(recipientId) ||
    typeof actorId !== "string" || !UUID_RE.test(actorId) ||
    recipientId === actorId ||
    typeof ref !== "string" || !UUID_RE.test(ref)
  ) {
    return json(req, 400, { error: "bad_request" });
  }
  if (auth.user.id !== actorId) return json(req, 403, { error: "forbidden" });

  const { data: actor, error: actorError } = await admin.from("profiles")
    .select("full_name, nickname, membership_paused_at").eq("id", actorId).maybeSingle();
  if (actorError) return serverError(req, `actor lookup: ${actorError.message}`);
  if (!actor || actor.membership_paused_at) return json(req, 403, { error: "not_a_member" });

  // The pair request / chat must be between these two (pair kinds: in the right direction).
  const { data: pair, error: pairError } = await admin.from("pair_requests")
    .select("from_user, to_user").eq("id", ref).maybeSingle();
  if (pairError) return serverError(req, `pair lookup: ${pairError.message}`);
  const related = pair && (
    kind === "pair_request"
      ? pair.from_user === actorId && pair.to_user === recipientId
      : kind === "pair_accepted"
      ? pair.from_user === recipientId && pair.to_user === actorId
      : (pair.from_user === actorId && pair.to_user === recipientId) ||
        (pair.from_user === recipientId && pair.to_user === actorId)
  );
  if (!related) return json(req, 403, { error: "not_related" });

  // 3. Preferences (missing row = enabled).
  const { data: prefs, error: prefsError } = await admin.from("notification_prefs")
    .select("email_messages, email_pairs").eq("user_id", recipientId).maybeSingle();
  if (prefsError) return serverError(req, `prefs lookup: ${prefsError.message}`);
  if (prefs && !(kind === "message" ? prefs.email_messages : prefs.email_pairs)) {
    return json(req, 200, { ok: true, status: "skipped_pref" });
  }

  // 4. Throttle.
  const since = new Date(Date.now() - THROTTLE_MINUTES[kind] * 60_000).toISOString();
  const { count, error: countError } = await admin.from("notification_emails")
    .select("id", { count: "exact", head: true })
    .eq("user_id", recipientId).eq("kind", kind).eq("ref", ref).gte("sent_at", since);
  if (countError) return serverError(req, `throttle: ${countError.message}`);
  if ((count ?? 0) > 0) return json(req, 200, { ok: true, status: "skipped_throttle" });

  // 5. Lookup.
  const { data: recipient, error: recipientError } = await admin.from("profiles")
    .select("email, full_name, nickname").eq("id", recipientId).maybeSingle();
  if (recipientError) return serverError(req, `recipient lookup: ${recipientError.message}`);
  if (!recipient?.email) return json(req, 200, { ok: true, status: "skipped_no_email" });

  // 6. Send + 7. log.
  const email = notificationEmail({
    kind,
    to: recipient.email,
    recipientName: recipient.nickname || recipient.full_name || null,
    actorName: actor.full_name || actor.nickname || "Členka klubu",
    ref,
    baseUrl: BASE_URL,
  });
  let error: string | null = null;
  try {
    await sendEmail(email);
  } catch (err) {
    error = (err instanceof Error ? err.message : String(err)).slice(0, 500);
    console.error(`[notify] ${kind} → ${recipientId}: ${error}`);
  }
  const { error: logError } = await admin.from("notification_emails")
    .insert({ user_id: recipientId, kind, ref, error });
  if (logError) console.error(`[notify] log failed: ${logError.message}`);

  if (error) return json(req, 502, { ok: false, status: "failed" });
  console.log(`[notify] ${kind} → ${recipientId} sent`);
  return json(req, 200, { ok: true, status: "sent" });
});

function serverError(req: Request, message: string): Response {
  console.error(`[notify] ${message}`);
  return json(req, 500, { error: "server_error" });
}
