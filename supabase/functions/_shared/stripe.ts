// Shared Stripe helpers: signature verification + a minimal GET client.
// No Stripe SDK — plain fetch + Web Crypto keeps the functions small.

export type Env = "test" | "live";

const STRIPE_API = "https://api.stripe.com/v1";
// Pinned so object shapes don't change under us (independent of the API
// version configured on the webhook endpoint).
// basil+ moved subscription periods to items.data[].current_period_* and
// invoice.subscription to invoice.parent.subscription_details.subscription.
export const STRIPE_VERSION = "2025-03-31.basil";
const TOLERANCE_SECONDS = 300;

const encoder = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Header format: "t=1492774577,v1=5257a8...,v1=...,v0=..."
// Stripe may send several v1 signatures during secret rotation; any match is OK.
export async function verifyStripeSignature(
  rawBody: string,
  header: string | null,
  secret: string,
): Promise<boolean> {
  if (!header) return false;

  let timestamp: string | null = null;
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2).map((s) => s.trim());
    if (k === "t") timestamp = v;
    else if (k === "v1" && v) signatures.push(v);
  }
  if (!timestamp || signatures.length === 0) return false;

  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) return false;
  if (Math.abs(Date.now() / 1000 - ts) > TOLERANCE_SECONDS) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${rawBody}`));
  const expected = toHex(mac);

  return signatures.some((sig) => timingSafeEqual(sig, expected));
}

// deno-lint-ignore no-explicit-any
export type StripeObject = Record<string, any>;

// GET https://api.stripe.com/v1/<path>; throws with Stripe's message on non-2xx.
export async function stripeGet(path: string, secretKey: string): Promise<StripeObject> {
  const res = await fetch(`${STRIPE_API}/${path}`, {
    headers: {
      Authorization: `Bearer ${secretKey}`,
      "Stripe-Version": STRIPE_VERSION,
    },
  });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`Stripe GET ${path.split("?")[0]} failed (${res.status}): ${body?.error?.message ?? "unknown"}`);
  }
  return body;
}
