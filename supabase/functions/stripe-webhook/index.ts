// Stripe webhook for KLUB subscriptions → public.memberships.
//
// Endpoint: https://<ref>.supabase.co/functions/v1/stripe-webhook?env=test|live
// Deployed with --no-verify-jwt (Stripe sends no Supabase token; we verify the
// Stripe signature instead).
//
// Secrets:
//   STRIPE_WEBHOOK_SECRET_TEST / _LIVE        whsec_… of THIS endpoint
//   STRIPE_SECRET_KEY_TEST / _LIVE            secret key (reads subscriptions + customers,
//                                             sets cancel_at_period_end on yearly ones)
//   SMARTEMAILING_USERNAME, SMARTEMAILING_API_KEY   contact list sync + invitation
//   SMARTEMAILING_SENDER_EMAIL                invitation sender
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   built in
//
// Every handled event is reduced to a subscription id; the subscription is
// re-fetched from Stripe and its current state written to memberships (see
// membership.ts). That makes processing idempotent and order-independent.
// On invoice.paid (first payment and every renewal) the customer is also put
// on the plan's SmartEmailing contact list; when access is revoked (membership
// no longer active), they're taken off all KLUB lists. A member whose account
// this webhook created gets the KLUB invitation (set-password link) once the
// membership is active — once, see _shared/invitations.ts.
// checkout.session.completed / async_payment_succeeded with the refundable call deposit
// price (_shared/deposit.ts) marks the application (client_reference_id = questionnaire
// token) paid; other checkout sessions are ignored.
// The yearly membership is sold as one year, not a renewing plan: a yearly
// subscription is set to cancel at period end,
// so Stripe ends it after a year (subscription.deleted → membership ended).
//
// Responses: 400 for a bad request/signature, 500 when not configured or when
// processing fails (the stripe_events row is removed, so Stripe's automatic
// retries — and "Resend" — process it again). Everything else 200.

import { createClient } from "npm:@supabase/supabase-js@2";
import { isDeposit, markDepositPaid } from "../_shared/deposit.ts";
import { inviteIfCreatedBy } from "../_shared/invitations.ts";
import { importContact, removeFromContactlists } from "../_shared/smartemailing.ts";
import { type Env, type StripeObject, stripeGet, stripePost, verifyStripeSignature } from "../_shared/stripe.ts";
import { KLUB_CONTACTLISTS, syncSubscription } from "./membership.ts";

// Lookup keys sold as a single year.
const ONE_YEAR_LOOKUP_KEYS = new Set(["klub_rocne_clenstvo"]);

const SUBSCRIPTION_EVENTS = new Set([
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
]);
const INVOICE_EVENTS = new Set([
  "invoice.paid",
  "invoice.payment_failed",
]);
const CHECKOUT_EVENTS = new Set([
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
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

function shouldEndAfterOneYear(sub: StripeObject): boolean {
  if (sub.status !== "active" && sub.status !== "trialing") return false;
  if (sub.cancel_at_period_end || sub.cancel_at) return false;
  // deno-lint-ignore no-explicit-any
  return (sub.items?.data ?? []).some((i: any) => ONE_YEAR_LOOKUP_KEYS.has(i.price?.lookup_key));
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

// Idempotency: first writer wins. False = already processed, skip it.
async function claimEvent(event: StripeObject): Promise<boolean> {
  const { error } = await supabase
    .from("stripe_events")
    .insert({ id: event.id, type: event.type, livemode: event.livemode ?? null });
  if (!error) return true;
  if (error.code === "23505") {
    console.log(`[stripe] ${event.id} already processed`);
    return false;
  }
  // Can't record the event — still process; the handlers are idempotent.
  console.error(`[db] stripe_events insert failed: ${error.message}`);
  return true;
}

// Refundable call deposit paid → consultation_applications.deposit_paid.
async function handleDeposit(event: StripeObject, stripeKey: string): Promise<Response> {
  const obj = event.data?.object ?? {};
  if (obj.mode !== "payment") return json(200, { received: true, ignored: "not a payment" });
  if (!(await claimEvent(event))) return json(200, { received: true, duplicate: true });
  try {
    const session = await stripeGet(`checkout/sessions/${encodeURIComponent(obj.id)}?expand[]=line_items`, stripeKey);
    if (!isDeposit(session)) return json(200, { received: true, ignored: "not a deposit" });
    const paid = await markDepositPaid(supabase, session);
    if (!paid) console.log(`[deposit] ${session.id} not marked (${session.payment_status})`);
    return json(200, { received: true, deposit_paid: paid });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[deposit] ${event.id} ${obj.id}: ${message}`);
    await supabase.from("stripe_events").delete().eq("id", event.id);
    return json(500, { error: message });
  }
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

  if (CHECKOUT_EVENTS.has(event.type)) return await handleDeposit(event, stripeKey);

  if (!SUBSCRIPTION_EVENTS.has(event.type) && !INVOICE_EVENTS.has(event.type)) {
    return json(200, { received: true, ignored: event.type });
  }

  const subscriptionId = subscriptionIdOf(event);
  if (!subscriptionId) {
    // e.g. a one-off invoice not tied to a subscription.
    return json(200, { received: true, ignored: "no subscription" });
  }

  if (!(await claimEvent(event))) return json(200, { received: true, duplicate: true });

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

    // Fires customer.subscription.updated, which re-syncs and then skips this.
    if (shouldEndAfterOneYear(sub)) {
      await stripePost(`subscriptions/${encodeURIComponent(subscriptionId)}`, { cancel_at_period_end: "true" }, stripeKey);
      console.log(`[stripe] ${subscriptionId} set to cancel at period end (one-year membership)`);
    }

    // A failure throws → 500, Stripe retries; the sync above is idempotent.
    const customer = sub.customer;
    if (result.action === "synced" && customer?.email) {
      if (result.status !== "active") {
        await removeFromContactlists(customer.email, KLUB_CONTACTLISTS);
        console.log(`[smartemailing] ${customer.email} removed from lists ${KLUB_CONTACTLISTS.join(",")}`);
      } else if (event.type === "invoice.paid") {
        await importContact(
          { email: customer.email, name: customer.name ?? undefined, phone: customer.phone ?? undefined },
          [result.contactlist_id],
        );
        console.log(`[smartemailing] ${customer.email} → list ${result.contactlist_id}`);
      }
    }

    if (result.action === "synced" && result.status === "active") {
      const invited = await inviteIfCreatedBy(supabase, result.user_id, "stripe-webhook");
      if (invited) console.log(`[invite] ${invited} invited (user ${result.user_id})`);
    }

    return json(200, { received: true, ...result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[sync] ${event.id} ${subscriptionId}: ${message}`);
    await supabase.from("stripe_events").delete().eq("id", event.id);
    return json(500, { error: message });
  }
});
