// One-time (re-runnable) sync: bring memberships in line with Stripe using the
// SAME logic as the stripe-webhook function (membership.ts), e.g. after the
// backfill linked rows that were still "lifetime", or after missed events.
//
// Run via 13-sync-stripe-memberships.sh (dry run first, then --apply).
//
//   --apply            write changes (otherwise only report)
//   --create-missing   also create memberships for live subscriptions that have
//                      none (user matched by customer email, created if absent)
//
// Env: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_SECRET_KEY (service role).

import { createClient } from "npm:@supabase/supabase-js@2";
import { type StripeObject, stripeGet } from "../../functions/_shared/stripe.ts";
import { membershipState, resolvePlan, syncSubscription } from "../../functions/stripe-webhook/membership.ts";

const apply = Deno.args.includes("--apply");
const createMissing = Deno.args.includes("--create-missing");

const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const supabaseKey = Deno.env.get("SUPABASE_SECRET_KEY");
if (!stripeKey || !supabaseUrl || !supabaseKey) {
  console.error("STRIPE_SECRET_KEY, SUPABASE_URL and SUPABASE_SECRET_KEY must be set");
  Deno.exit(1);
}
const supabase = createClient(supabaseUrl, supabaseKey, { auth: { persistSession: false, autoRefreshToken: false } });

const LIVE_STATUSES = new Set(["active", "trialing", "past_due", "unpaid", "paused"]);
const mode = stripeKey.includes("_live_") ? "LIVE" : "TEST";

function day(iso: string | null): string {
  if (!iso) return "lifetime";
  return new Intl.DateTimeFormat("sk-SK", { timeZone: "Europe/Bratislava", dateStyle: "medium" }).format(new Date(iso));
}

function sameInstant(a: string | null, b: string | null): boolean {
  if (a === null || b === null) return a === b;
  return new Date(a).getTime() === new Date(b).getTime();
}

function planOf(sub: StripeObject): string | null {
  try {
    return resolvePlan(sub).name;
  } catch {
    return null;
  }
}

// --- load -----------------------------------------------------------------------

const subs: StripeObject[] = [];
for (let after: string | null = null;;) {
  const page = await stripeGet(
    `subscriptions?status=all&limit=100&expand[]=data.customer${after ? `&starting_after=${after}` : ""}`,
    stripeKey,
  );
  subs.push(...page.data);
  if (!page.has_more) break;
  after = page.data[page.data.length - 1].id;
}
const byId = new Map(subs.map((s) => [s.id as string, s]));

type Row = { id: string; user_id: string; name: string; status: string; ends_at: string | null; stripe_subscription_id: string };
const { data: rows, error } = await supabase
  .from("memberships")
  .select("id, user_id, name, status, ends_at, stripe_subscription_id")
  .not("stripe_subscription_id", "is", null)
  .range(0, 9999)
  .returns<Row[]>();
if (error) throw new Error(`memberships load failed: ${error.message}`);
const linked = new Set(rows.map((r) => r.stripe_subscription_id));

// --- compare --------------------------------------------------------------------

type Change = { row: Row; sub: StripeObject; to: { name: string; status: string; ends_at: string } };
const changes: Change[] = [];
const problems: string[] = [];
let unchanged = 0;

for (const row of rows) {
  const sub = byId.get(row.stripe_subscription_id);
  if (!sub) {
    problems.push(`${row.stripe_subscription_id}: not in this Stripe account (${mode}) — membership ${row.id}`);
    continue;
  }
  const state = membershipState(sub);
  const plan = planOf(sub);
  if (!state) {
    problems.push(`${sub.id}: status ${sub.status} — left as is`);
    continue;
  }
  if (!plan) {
    problems.push(`${sub.id}: unknown lookup_key ${sub.items?.data?.[0]?.price?.lookup_key ?? "(none)"} — add it to PLANS`);
    continue;
  }
  if (row.name === plan && row.status === state.status && sameInstant(row.ends_at, state.ends_at)) {
    unchanged++;
  } else {
    changes.push({ row, sub, to: { name: plan, ...state } });
  }
}

const missing = subs.filter((s) => !linked.has(s.id) && LIVE_STATUSES.has(s.status));

// --- report ---------------------------------------------------------------------

console.log(`Stripe mode: ${mode}`);
console.log(`Linked memberships: ${rows.length} — unchanged ${unchanged}, to update ${changes.length}, problems ${problems.length}`);
console.log("");
console.log(`== UPDATE: ${changes.length}`);
for (const c of changes) {
  const email = c.sub.customer?.email ?? "?";
  const from = `${c.row.status}, ${day(c.row.ends_at)}`;
  const to = `${c.to.status}, ${day(c.to.ends_at)}`;
  const name = c.row.name === c.to.name ? "" : `  name: ${c.row.name} → ${c.to.name}`;
  console.log(`  ${email.padEnd(38)} [stripe: ${c.sub.status}]  ${from} → ${to}${name}`);
}
console.log("");
console.log(`== PROBLEMS: ${problems.length}`);
for (const p of problems) console.log(`  ${p}`);
console.log("");
console.log(`== LIVE SUBSCRIPTIONS WITHOUT A MEMBERSHIP: ${missing.length}${createMissing ? " (will be created)" : " (use --create-missing)"}`);
for (const s of missing) {
  const email: string | null = s.customer?.email ?? null;
  let owner = "no email — cannot create";
  if (email) {
    const { data: profile } = await supabase.from("profiles").select("id").ilike("email", email.replace(/[\\%_]/g, (c) => `\\${c}`)).limit(1).maybeSingle();
    owner = profile ? "existing account" : "NEW account would be created";
  }
  console.log(`  ${(email ?? "?").padEnd(38)} ${s.id} [${s.status}] ${planOf(s) ?? "UNKNOWN PLAN"} — ${owner}`);
}

// --- apply ----------------------------------------------------------------------

if (!apply) {
  console.log("\nDry run — nothing written.");
  Deno.exit(0);
}

let ok = 0;
let failed = 0;
const targets = [...changes.map((c) => c.sub), ...(createMissing ? missing : [])];
for (const sub of targets) {
  try {
    await syncSubscription(supabase, sub);
    ok++;
  } catch (err) {
    failed++;
    console.error(`  ${sub.id}: ${err instanceof Error ? err.message : err}`);
  }
}
console.log(`\nApplied: ${ok} synced, ${failed} failed.`);
if (failed) Deno.exit(1);
