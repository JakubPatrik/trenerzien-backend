// Stripe subscription → one memberships row (keyed by stripe_subscription_id).
// The row always mirrors the subscription's *current* state, so the order,
// repetition or type of the triggering event doesn't matter.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { StripeObject } from "../_shared/stripe.ts";
import { findOrCreateUser } from "../_shared/users.ts";

type Plan = { name: string };

// Routed by Stripe price lookup_key (same in test and live).
// Names must match public.is_club_member() — it grants KLUB access by name.
const PLANS: Record<string, Plan> = {
  // Founder prices (live, 49 €/month, 497 €/year) — names of the imported klub rows.
  zk_klub_mesacne_clenstvo: { name: "Zakladateľské členstvo — mesačné" },
  zk_klub_rocne_clenstvo: { name: "Zakladateľské členstvo — ročné" },
  zk_klub_mesacne: { name: "Zakladateľské členstvo — mesačné" }, // same offer, older price
  zk_klub_rocne: { name: "Zakladateľské členstvo — ročné" },
  klub_mesacne_clenstvo: { name: "Členstvo — mesačné" },
  klub_stvrtrocne_clenstvo: { name: "Členstvo — štvrťročné" },
  klub_rocne_clenstvo: { name: "Členstvo — ročné" },
};

type MembershipStatus = "active" | "paused" | "ended";

export type SyncResult =
  | { action: "skipped"; reason: string }
  | { action: "synced"; status: MembershipStatus; ends_at: string; user_id: string };

function isoFromUnix(seconds: number): string {
  return new Date(seconds * 1000).toISOString();
}

export function resolvePlan(sub: StripeObject): Plan {
  // deno-lint-ignore no-explicit-any
  const keys: (string | null)[] = (sub.items?.data ?? []).map((i: any) => i.price?.lookup_key ?? null);
  for (const key of keys) {
    if (key && PLANS[key]) return PLANS[key];
  }
  throw new Error(`unknown lookup_key: ${keys.map((k) => k ?? "(none)").join(",") || "(no items)"}`);
}

// Since basil the billing period lives on the subscription items.
function period(sub: StripeObject): { start: number; end: number } {
  // deno-lint-ignore no-explicit-any
  const items: any[] = sub.items?.data ?? [];
  const starts = items.map((i) => i.current_period_start).filter(Number.isFinite);
  const ends = items.map((i) => i.current_period_end).filter(Number.isFinite);
  if (starts.length === 0 || ends.length === 0) throw new Error("subscription items have no current period");
  return { start: Math.min(...starts), end: Math.max(...ends) };
}

// ends_at NULL means "lifetime" in memberships, so a Stripe row always gets a date.
//   active / trialing  → paid up to the end of the current period
//   past_due           → renewal failed, Stripe is retrying: keep access, but
//                        only up to the end of the last paid period (= start
//                        of the current, unpaid one)
//   paused             → no access; keep the last paid date for reference
//   unpaid / canceled / incomplete_expired → Stripe gave up / cancelled
export function membershipState(sub: StripeObject): { status: MembershipStatus; ends_at: string } | null {
  const { start, end } = period(sub);
  switch (sub.status) {
    case "active":
    case "trialing":
      return { status: "active", ends_at: isoFromUnix(end) };
    case "past_due":
      return { status: "active", ends_at: isoFromUnix(start) };
    case "paused":
      return { status: "paused", ends_at: isoFromUnix(start) };
    case "unpaid":
    case "canceled":
    case "incomplete_expired":
      return { status: "ended", ends_at: isoFromUnix(sub.ended_at ?? start) };
    default:
      // "incomplete": first payment not done yet — invoice.paid will follow.
      return null;
  }
}

// `sub` must be fetched with expand[]=customer.
export async function syncSubscription(supabase: SupabaseClient, sub: StripeObject): Promise<SyncResult> {
  const state = membershipState(sub);
  if (!state) return { action: "skipped", reason: `status ${sub.status}` };

  const plan = resolvePlan(sub);

  const customer = sub.customer;
  if (!customer || typeof customer !== "object") throw new Error("subscription fetched without expanded customer");

  // An existing row keeps its owner: the Stripe customer email may differ from
  // the account email (linked by hand) or change later. Only a new
  // subscription is matched by email.
  const { data: existing, error: selError } = await supabase
    .from("memberships")
    .select("user_id")
    .eq("stripe_subscription_id", sub.id)
    .maybeSingle();
  if (selError) throw new Error(`memberships lookup failed: ${selError.message}`);

  let userId: string | null = existing?.user_id ?? null;
  if (!userId) {
    if (customer.deleted) throw new Error(`customer ${customer.id} is deleted`);
    if (!customer.email) throw new Error(`customer ${customer.id} has no email — cannot link a user`);
    userId = await findOrCreateUser(supabase, customer.email, customer.name ?? null);
  }

  const { error } = await supabase.from("memberships").upsert(
    {
      stripe_subscription_id: sub.id,
      stripe_customer_id: customer.id,
      user_id: userId,
      name: plan.name,
      status: state.status,
      starts_at: isoFromUnix(sub.start_date),
      ends_at: state.ends_at,
      source: "stripe",
    },
    { onConflict: "stripe_subscription_id" },
  );
  if (error) throw new Error(`memberships upsert failed: ${error.message}`);

  return { action: "synced", ...state, user_id: userId };
}
