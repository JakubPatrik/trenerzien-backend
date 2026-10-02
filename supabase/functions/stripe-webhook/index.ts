// Stripe webhook for KLUB subscriptions → public.memberships.
//
// Endpoint: https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test|live
// Deployed with --no-verify-jwt (Stripe sends no Supabase token; we verify the
// Stripe signature instead).
//
// Secrets:
//   STRIPE_WEBHOOK_SECRET_TEST / _LIVE        whsec_… of THIS endpoint
//   STRIPE_SECRET_KEY_TEST / _LIVE            restricted key, Subscriptions + Customers: read
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   built in
//
// Every handled event is reduced to a subscription id; the subscription is
// re-fetched from Stripe and its current state written to memberships (see
// membership.ts). That makes processing idempotent and order-independent.
//
// Responses: 400 for a bad request/signature, 500 when not configured or when
// processing fails (the stripe_events row is removed, so Stripe's automatic
// retries — and "Resend" — process it again). Everything else 200.

import { createClient } from "npm:@supabase/supabase-js@2";
import { type Env, type StripeObject, stripeGet, verifyStripeSignature } from "../_shared/stripe.ts";
import { syncSubscription } from "./membership.ts";

const SUBSCRIPTION_EVENTS = new Set([
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
]);
const INVOICE_EVENTS = new Set([
  "invoice.paid",
  "invoice.payment_failed",
]);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function idOf(ref: unknown): string | null {
  if (typeof ref === "string") return ref;
  if (ref && typeof ref === "object" && typeof (ref as StripeObject).id === "string") {
    return (ref as StripeObject).id;
  }
  return null;
}

// The event body's shape follows the endpoint's API version, so read the
// subscription id from both the basil+ and the legacy location.
function subscriptionIdOf(event: StripeObject): string | null {
  const obj = event.data?.object ?? {};
  if (SUBSCRIPTION_EVENTS.has(event.type)) return idOf(obj.id);
  if (INVOICE_EVENTS.has(event.type)) {
    return idOf(obj.parent?.subscription_details?.subscription) ?? idOf(obj.subscription);
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const envParam = new URL(req.url).searchParams.get("env");
  if (envParam !== "test" && envParam !== "live") {
    return json(400, { error: "missing or invalid ?env=test|live" });
  }
  const env: Env = envParam;
  const suffix = env.toUpperCase();

  const webhookSecret = Deno.env.get(`STRIPE_WEBHOOK_SECRET_${suffix}`);
  const stripeKey = Deno.env.get(`STRIPE_SECRET_KEY_${suffix}`);
  if (!webhookSecret || !stripeKey) {
    // Misconfiguration: answer 500 so Stripe keeps retrying until secrets exist.
    console.error(`[config] STRIPE_WEBHOOK_SECRET_${suffix} or STRIPE_SECRET_KEY_${suffix} not set`);
    return json(500, { error: "not configured" });
  }

  const rawBody = await req.text();
  const valid = await verifyStripeSignature(rawBody, req.headers.get("stripe-signature"), webhookSecret);
  if (!valid) {
    console.warn("[stripe] invalid signature");
    return json(400, { error: "invalid signature" });
  }

  const event = JSON.parse(rawBody);
  console.log(`[stripe] ${event.id} ${event.type} (${env})`);

  if (event.livemode !== (env === "live")) {
    console.warn(`[stripe] ${event.id} livemode=${event.livemode} but env=${env}`);
  }

  if (!SUBSCRIPTION_EVENTS.has(event.type) && !INVOICE_EVENTS.has(event.type)) {
    return json(200, { received: true, ignored: event.type });
  }

  const subscriptionId = subscriptionIdOf(event);
  if (!subscriptionId) {
    // e.g. a one-off invoice not tied to a subscription.
    return json(200, { received: true, ignored: "no subscription" });
  }

  // Idempotency: first writer wins, repeats are skipped.
  const { error: insertError } = await supabase
    .from("stripe_events")
    .insert({ id: event.id, type: event.type, livemode: event.livemode ?? null });
  if (insertError) {
    if (insertError.code === "23505") {
      console.log(`[stripe] ${event.id} already processed`);
      return json(200, { received: true, duplicate: true });
    }
    // Can't record the event — still process; the sync is idempotent.
    console.error(`[db] stripe_events insert failed: ${insertError.message}`);
  }

  try {
    const sub = await stripeGet(
      `subscriptions/${encodeURIComponent(subscriptionId)}?expand[]=customer`,
      stripeKey,
    );
    const result = await syncSubscription(supabase, sub);
    if (result.action === "skipped") {
      console.log(`[sync] ${subscriptionId} skipped (${result.reason})`);
    } else {
      console.log(`[sync] ${subscriptionId} → ${result.status} until ${result.ends_at} (user ${result.user_id})`);
    }
    return json(200, { received: true, ...result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[sync] ${event.id} ${subscriptionId}: ${message}`);
    await supabase.from("stripe_events").delete().eq("id", event.id);
    return json(500, { error: message });
  }
});
