// Invitations to KLUB: email each member a link to set her password.
// (Moved from the Lovable app: sendInvitesBatch / sendInviteToEmail.)
//
// Endpoint: POST https://<ref>.supabase.co/functions/v1/send-invitations
//   headers: Authorization: Bearer <admin user access token>
//   body:    { mode: "batch", siteUrl?, limit?, audience?, group?, emails? }
//            → { sent, failed: [{ email, error }], remaining }
//            { mode: "single", siteUrl?, email, markInvited? }
//            → { ok: true, inviteUrl } | { ok: false, error }
// Deployed with --no-verify-jwt; the caller's token + admin role are verified here.
//
// Per recipient: auth.admin.generateLink({ type: "recovery" }) → hashed_token →
// <site>/nove-heslo?t=<hashed_token> → our own email via SmartEmailing
// (transactional, one recipient per request) → profiles.invitation = 'invited'.
// The link carries the hashed token, never action_link: mail scanners open links
// and would consume /auth/v1/verify. /nove-heslo verifies only on submit
// (verifyOtp({ token_hash, type: "recovery" })). Each generateLink invalidates the
// member's previous link. Link validity (7 days) = Supabase Auth email OTP expiry.
//
// Secrets: SMARTEMAILING_* (see _shared/smartemailing.ts); SUPABASE_URL,
// SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (built in).

import { createClient } from "npm:@supabase/supabase-js@2";
import { json as jsonFor, preflight } from "../_shared/http.ts";
import { sendEmail } from "../_shared/smartemailing.ts";
import { inviteEmail } from "./email.ts";

const PUBLIC_SITE_URL = "https://klub.trenerzien.sk";
const MAX_PER_CALL = 500;
const CONCURRENCY = 12;
const ID_CHUNK = 300; // .in() list length (URL limit)
const PAGE = 1000; // PostgREST row cap

// Club members = these memberships ∪ former members (profiles.membership_ends_on set).
const CLUB_MEMBERSHIPS = [
  "Zakladateľské členstvo — ročné",
  "Zakladateľské členstvo — mesačné",
  "Zakladateľské členstvo — prevodom",
  "Sprievodkyňa klubu",
];

const NOT_FOUND = "Takýto e-mail v klube nie je.";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Audience = "none" | "invited";
type Group = "founders_former" | "all";
type Failure = { email: string; error: string };

const json = (req: Request, status: number, body: Record<string, unknown>) =>
  jsonFor(req, status, body, { anyOrigin: true });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req, { anyOrigin: true });
  if (req.method !== "POST") return json(req, 405, { error: "Method not allowed" });

  // 1. Caller must be an admin.
  const userClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json(req, 401, { error: "Unauthorized" });
  const { data: isAdmin } = await userClient.rpc("has_role", { _user_id: user.id, _role: "admin" });
  if (!isAdmin) return json(req, 403, { error: "Forbidden" });

  // deno-lint-ignore no-explicit-any
  const body: any = await req.json().catch(() => null);
  if (!body || (body.mode !== "batch" && body.mode !== "single")) {
    return json(req, 400, { error: "mode musí byť 'batch' alebo 'single'." });
  }

  // Fail before generating links: a new link invalidates the member's previous one.
  if (!Deno.env.get("SMARTEMAILING_USERNAME") || !Deno.env.get("SMARTEMAILING_API_KEY") ||
    !Deno.env.get("SMARTEMAILING_SENDER_EMAIL")) {
    console.error("[invite] SmartEmailing credentials not configured");
    return json(req, 500, { error: "SmartEmailing nie je nastavený." });
  }

  // The app sends siteUrl (window.location.origin), but links always point to
  // production — never to a preview / localhost origin.
  const site = PUBLIC_SITE_URL;
  console.log(`[invite] ${body.mode} by ${user.email ?? user.id}`);
  return body.mode === "batch" ? await batch(req, body, site) : await single(req, body, site);
});

// ── batch ────────────────────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function batch(req: Request, body: any, site: string): Promise<Response> {
  const limit = body.limit === undefined ? MAX_PER_CALL : Number(body.limit);
  const audience: Audience = body.audience ?? "none";
  const group: Group = body.group ?? "founders_former";
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_PER_CALL) {
    return json(req, 400, { error: `limit musí byť celé číslo 1–${MAX_PER_CALL}.` });
  }
  if (audience !== "none" && audience !== "invited") return json(req, 400, { error: "Neplatné audience." });
  if (group !== "founders_former" && group !== "all") return json(req, 400, { error: "Neplatná group." });
  if (body.emails !== undefined && !Array.isArray(body.emails)) {
    return json(req, 400, { error: "emails musí byť pole." });
  }
  const only = body.emails
    ? new Set((body.emails as unknown[]).map((e) => String(e).trim().toLowerCase()).filter(Boolean))
    : null;

  try {
    const memberIds = await clubMemberIds();
    const recipients = await selectRecipients(memberIds, audience, group, limit);

    const sentIds: string[] = [];
    const failed: Failure[] = [];
    await mapLimit(recipients, CONCURRENCY, async (p) => {
      let email = p.id;
      try {
        const { data: u } = await admin.auth.admin.getUserById(p.id);
        if (!u?.user?.email) return; // no auth account / no email → skip silently
        email = u.user.email.toLowerCase();
        if (only && !only.has(email)) return;
        const result = await invite(email, p.full_name, site);
        if (result.ok) sentIds.push(p.id);
        else failed.push({ email, error: result.error });
      } catch (err) {
        // Never abort the batch: already-sent members must still be marked invited.
        failed.push({ email, error: err instanceof Error ? err.message : String(err) });
      }
    });

    await markInvited(sentIds);
    const remaining = await countRemaining(memberIds, audience, group);
    console.log(`[invite] batch: sent ${sentIds.length}, failed ${failed.length}, remaining ${remaining}`);
    return json(req, 200, { sent: sentIds.length, failed, remaining });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[invite] batch failed: ${message}`);
    return json(req, 500, { error: message });
  }
}

async function clubMemberIds(): Promise<string[]> {
  const ids = new Set<string>();
  for (let from = 0;; from += PAGE) {
    const { data, error } = await admin.from("memberships").select("user_id")
      .in("name", CLUB_MEMBERSHIPS).order("user_id").range(from, from + PAGE - 1);
    if (error) throw new Error(`memberships: ${error.message}`);
    for (const r of data) if (r.user_id) ids.add(r.user_id);
    if (data.length < PAGE) break;
  }
  for (let from = 0;; from += PAGE) {
    const { data, error } = await admin.from("profiles").select("id")
      .not("membership_ends_on", "is", null).order("id").range(from, from + PAGE - 1);
    if (error) throw new Error(`profiles: ${error.message}`);
    for (const r of data) ids.add(r.id);
    if (data.length < PAGE) break;
  }
  return [...ids];
}

type Recipient = { id: string; full_name: string | null };

// deno-lint-ignore no-explicit-any
function audienceFilter<Q extends { eq: any; or: any }>(q: Q, audience: Audience, group: Group): Q {
  q = q.eq("invitation", audience);
  return group === "founders_former" ? q.or("founder_at.not.is.null,membership_ends_on.not.is.null") : q;
}

async function selectRecipients(ids: string[], audience: Audience, group: Group, limit: number) {
  const out: Recipient[] = [];
  for (const chunk of chunks(ids, ID_CHUNK)) {
    if (out.length >= limit) break;
    const { data, error } = await audienceFilter(
      admin.from("profiles").select("id, full_name").in("id", chunk),
      audience,
      group,
    ).limit(limit - out.length);
    if (error) throw new Error(`profiles: ${error.message}`);
    out.push(...(data as Recipient[]));
  }
  return out;
}

async function countRemaining(ids: string[], audience: Audience, group: Group): Promise<number> {
  let total = 0;
  for (const chunk of chunks(ids, ID_CHUNK)) {
    const { count, error } = await audienceFilter(
      admin.from("profiles").select("id", { count: "exact", head: true }).in("id", chunk),
      audience,
      group,
    );
    if (error) throw new Error(`profiles count: ${error.message}`);
    total += count ?? 0;
  }
  return total;
}

async function markInvited(ids: string[]): Promise<void> {
  const invitedAt = new Date().toISOString();
  for (const chunk of chunks(ids, ID_CHUNK)) {
    const { error } = await admin.from("profiles").update({ invitation: "invited", invited_at: invitedAt })
      .in("id", chunk);
    // Emails are out already; log and keep going (they'd only be re-sent with audience 'none').
    if (error) console.error(`[invite] marking ${chunk.length} invited failed: ${error.message}`);
  }
}

// ── single ───────────────────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function single(req: Request, body: any, site: string): Promise<Response> {
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email.includes("@")) return json(req, 400, { ok: false, error: "Neplatný e-mail." });
  const markAsInvited = body.markInvited !== false;

  const result = await invite(email, null, site, true);
  if (!result.ok) return json(req, 200, { ok: false, error: result.error });

  if (markAsInvited) await markInvited([result.userId]);
  console.log(`[invite] single ${email}${markAsInvited ? "" : " (test, not marked)"}`);
  return json(req, 200, { ok: true, inviteUrl: result.inviteUrl });
}

// ── one recipient ────────────────────────────────────────────────────────────

type InviteResult = { ok: true; userId: string; inviteUrl: string } | { ok: false; error: string };

// fullName null → read from profiles (single mode).
async function invite(email: string, fullName: string | null, site: string, single = false): Promise<InviteResult> {
  const { data: link, error } = await admin.auth.admin.generateLink({
    type: "recovery",
    email,
    options: { redirectTo: `${site}/nove-heslo` },
  });
  const hashed = link?.properties?.hashed_token;
  if (!hashed || !link.user) {
    if (single && error && (error.status === 404 || /not found/i.test(error.message))) {
      return { ok: false, error: NOT_FOUND };
    }
    return { ok: false, error: error?.message ?? "Odkaz sa nepodarilo vytvoriť." };
  }
  const inviteUrl = `${site}/nove-heslo?t=${encodeURIComponent(hashed)}`;

  if (fullName === null) {
    const { data: profile } = await admin.from("profiles").select("full_name").eq("id", link.user.id).maybeSingle();
    fullName = profile?.full_name ?? null;
  }

  try {
    await sendEmail(inviteEmail({ to: email, fullName: fullName ?? "", inviteUrl }));
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[invite] ${email}: ${message.slice(0, 800)}`);
    return { ok: false, error: message.slice(0, 300) };
  }
  return { ok: true, userId: link.user.id, inviteUrl };
}

// ── helpers ──────────────────────────────────────────────────────────────────

function chunks<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

async function mapLimit<T>(items: T[], n: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]);
  };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
}
