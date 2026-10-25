// Refundable 100 € deposit before booking a call (supabase/web/LOVABLE_ZALOHA.md).
// Shared by stripe-webhook (marks it paid) and book-meeting (requires it).
//
// The lead pays on the website's own payment page (Lovable). The session must carry the
// questionnaire token as client_reference_id; stripe-webhook sees the paid session with
// the deposit price (lookup key below) and marks that application paid.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { StripeObject } from "./stripe.ts";

export const DEPOSIT_LOOKUP_KEY = "vstupny_pohovor_zaloha_100";

// `session` must be fetched with expand[]=line_items.
export function isDeposit(session: StripeObject): boolean {
  // deno-lint-ignore no-explicit-any
  return (session.line_items?.data ?? []).some((i: any) => i.price?.lookup_key === DEPOSIT_LOOKUP_KEY);
}

// Marks the application of a paid deposit session. True when it's marked now or was
// already. Idempotent; a second paid session for the same application is only logged
// (support refunds it), as is a session that can't be matched (retrying won't help).
// Throws on a DB failure.
export async function markDepositPaid(supabase: SupabaseClient, session: StripeObject): Promise<boolean> {
  if (session.payment_status !== "paid") return false;
  const token = session.client_reference_id;
  if (typeof token !== "string" || !token) {
    console.error(`[deposit] ${session.id} (${session.customer_details?.email}) has no client_reference_id — not linked to an application`);
    return false;
  }
  const paymentIntent = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;

  const { data, error } = await supabase.from("consultation_applications").update({
    deposit_paid: true,
    deposit_paid_at: new Date().toISOString(),
    deposit_session_id: session.id,
    deposit_payment_intent_id: paymentIntent ?? null,
  }).eq("token", token).eq("deposit_paid", false).select("id");
  if (error) throw new Error(`deposit update failed: ${error.message}`);
  if (data?.length) {
    console.log(`[deposit] ${data[0].id} paid (${session.id})`);
    return true;
  }

  const { data: app } = await supabase.from("consultation_applications").select("id, deposit_session_id")
    .eq("token", token).maybeSingle();
  if (!app) {
    console.error(`[deposit] ${session.id} (${session.customer_details?.email}): no application with that token`);
    return false;
  }
  if (app.deposit_session_id !== session.id) {
    console.warn(`[deposit] ${app.id} paid twice: ${app.deposit_session_id} and ${session.id} (${paymentIntent}) — refund one`);
  }
  return true;
}
