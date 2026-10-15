// FAPI webhook for KLUB purchases → public.memberships.
//
// Endpoint: https://<ref>.supabase.co/functions/v1/fapi-webhook?plan=3m|1y
// — one URL per FAPI product, plans in membership.ts.
// Deployed with --no-verify-jwt (FAPI sends no Supabase token; we verify the
// FAPI security hash instead). Set on each sales form as the "after payment"
// action "spustit programový skript" (URL notification).
//
// Secrets:
//   FAPI_USERNAME, FAPI_PASSWORD              FAPI login e-mail + API key
//   FAPI_ACCEPT_TEST                          "true" → also process test invoices
//   SMARTEMAILING_USERNAME, SMARTEMAILING_API_KEY   contact list sync + invitation
//   SMARTEMAILING_SENDER_EMAIL                invitation sender
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   built in
//
// FAPI posts only the invoice id + time + security (form-urlencoded). The
// invoice is fetched from the FAPI API, the hash checked against it, and only
// a paid final document grants access (see membership.ts). FAPI notifies once
// per document, so a paid proforma and its invoice would otherwise grant twice.
// The customer is then put on the plan's SmartEmailing contact list — also for
// an already granted invoice, so a retry / resend repairs a failed import — and,
// if this webhook created her account, sent the KLUB invitation (set-password
// link) once (_shared/invitations.ts); a retry sends one that failed.
//
// Responses: FAPI retries only 429 / 5xx (3× within ~15 s); any other non-2xx
// shows as a failed notification in FAPI and can be resent from there.
//   400  bad request / ?plan, invalid security, not paid, no e-mail
//   500  not configured, FAPI API, database, SmartEmailing or invitation failure
//   200  granted, already granted, or skipped (proforma, cancelled, test)

import { createClient } from "npm:@supabase/supabase-js@2";
import { FapiError, fapiGet, isInvoiceSecurityValid } from "../_shared/fapi.ts";
import { inviteIfCreatedBy } from "../_shared/invitations.ts";
import { importContact } from "../_shared/smartemailing.ts";
import { customerName, grantMembership, PLANS, RejectedInvoice } from "./membership.ts";

// Documents issued once the order is paid. Proforma precedes the invoice;
// payment_confirmation accompanies it (VAT payers); credit_note is a refund.
const FINAL_TYPES = new Set(["invoice", "simplified_invoice"]);

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

function failed(status: number, message: string): Response {
  return json(status, { status: "FAILED", message });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return failed(405, "method not allowed");

  const planParam = new URL(req.url).searchParams.get("plan") ?? "";
  const plan = Object.hasOwn(PLANS, planParam) ? PLANS[planParam] : null;
  if (!plan) return failed(400, `missing or invalid ?plan=${Object.keys(PLANS).join("|")}`);

  const username = Deno.env.get("FAPI_USERNAME");
  const password = Deno.env.get("FAPI_PASSWORD");
  if (!username || !password) {
    console.error("[config] FAPI_USERNAME or FAPI_PASSWORD not set");
    return failed(500, "not configured");
  }

  let form: URLSearchParams;
  try {
    form = new URLSearchParams(await req.text());
  } catch {
    return failed(400, "unreadable body");
  }
  // Some FAPI places send `invoice` instead of `id`.
  const invoiceId = form.get("id") ?? form.get("invoice");
  const time = Number.parseInt(form.get("time") ?? "", 10);
  const security = form.get("security");
  if (!invoiceId || !/^\d+$/.test(invoiceId) || !Number.isFinite(time) || !security) {
    return failed(400, "expected id (or invoice), time, security");
  }

  let invoice;
  try {
    invoice = await fapiGet(`invoices/${invoiceId}`, username, password);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[fapi] ${invoiceId}: ${message}`);
    // Unknown invoice → bad notification; anything else (auth, outage) → retry.
    return err instanceof FapiError && err.status === 404 ? failed(400, "invoice not found") : failed(500, message);
  }

  if (!isInvoiceSecurityValid(invoice, time, security)) {
    console.warn(`[fapi] ${invoiceId} invalid security`);
    return failed(400, "invalid security");
  }

  console.log(`[fapi] invoice ${invoice.id} (${invoice.number}) ${invoice.type} paid=${invoice.paid}`);

  if (invoice.is_test && Deno.env.get("FAPI_ACCEPT_TEST") !== "true") {
    return json(200, { status: "SKIPPED", message: "test invoice" });
  }
  if (!FINAL_TYPES.has(invoice.type)) {
    return json(200, { status: "SKIPPED", message: `${invoice.type} is not a final invoice` });
  }
  if (invoice.cancelled) {
    return json(200, { status: "SKIPPED", message: "invoice is cancelled" });
  }
  if (!invoice.paid) return failed(400, "invoice is not paid");

  let result;
  try {
    result = await grantMembership(supabase, invoice, plan);
    if (result.action === "exists") {
      console.log(`[grant] ${invoice.number} already granted (user ${result.user_id})`);
    } else {
      console.log(`[grant] ${invoice.number} → ${result.name} ${result.starts_at} – ${result.ends_at} (user ${result.user_id})`);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[grant] ${invoice.number}: ${message}`);
    return failed(err instanceof RejectedInvoice ? 400 : 500, message);
  }

  // Access is granted at this point; a failure here only makes FAPI retry,
  // which finds the membership and repeats just the import.
  const listId = plan.contactlistId;
  const customer = invoice.customer;
  try {
    await importContact(
      { email: customer.email, name: customerName(customer) ?? undefined, phone: customer.phone ?? undefined },
      [listId],
    );
    console.log(`[smartemailing] ${customer.email} → list ${listId}`);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[smartemailing] ${invoice.number}: ${message}`);
    return failed(500, `access granted, SmartEmailing import failed: ${message}`);
  }

  let invited: string | null;
  try {
    invited = await inviteIfCreatedBy(supabase, result.user_id, "fapi-webhook");
    if (invited) console.log(`[invite] ${invited} invited (user ${result.user_id})`);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[invite] ${invoice.number}: ${message}`);
    return failed(500, `access granted, ${message}`);
  }

  return json(200, { status: "OK", membership: result, contactlist: listId, invited });
});
