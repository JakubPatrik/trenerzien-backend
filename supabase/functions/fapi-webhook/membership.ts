// Paid FAPI invoice → one memberships row (keyed by fapi_invoice_id).
// A FAPI purchase is a one-off payment for a fixed period, so the row is
// written once; later notifications for the same invoice leave it alone.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { FapiObject } from "../_shared/fapi.ts";
import { findOrCreateUser } from "../_shared/users.ts";

export type Plan = { name: string; months: number; contactlistId: number };

// Routed by the ?plan= query param — each FAPI product has its own
// notification URL. FAPI sells no monthly membership.
// Names must match public.is_club_member() — it grants KLUB access by name.
// contactlistId: SmartEmailing list "… členstvo - KLUB ODM - aktívne členky".
export const PLANS: Record<string, Plan> = {
  "3m": { name: "Členstvo — štvrťročné", months: 3, contactlistId: 618 }, // 293713 Spolupráca s trénerom ŽIEN + KLUB ODM (3 mesiace)
  "1y": { name: "Členstvo — ročné", months: 12, contactlistId: 621 }, // 293719 Spolupráca s trénerom ŽIEN + KLUB ODM (1 rok)
};

const PLAN_NAMES = [...new Set(Object.values(PLANS).map((p) => p.name))];

// A problem with the invoice itself, not a transient one: FAPI shouldn't retry,
// the notification shows as failed in FAPI and can be resent after a fix.
export class RejectedInvoice extends Error {}

export type SyncResult =
  | { action: "exists"; user_id: string }
  | { action: "granted"; name: string; starts_at: string; ends_at: string; user_id: string };

// Calendar months in UTC, clamped to the last day (31 Jan + 1 → 28/29 Feb).
function addMonths(date: Date, months: number): Date {
  const d = new Date(date);
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, lastDay));
  return d;
}

// paid_on is "YYYY-MM-DD HH:MM:SS"; fall back to now.
function paidAt(invoice: FapiObject): Date {
  const d = invoice.paid_on ? new Date(String(invoice.paid_on).replace(" ", "T")) : new Date(NaN);
  return Number.isNaN(d.getTime()) ? new Date() : d;
}

export function customerName(customer: FapiObject): string | null {
  const full = [customer.first_name, customer.last_name].filter(Boolean).join(" ").trim();
  return full || customer.name || null;
}

// `invoice` must be paid and verified; `plan` from the ?plan= query param.
export async function grantMembership(supabase: SupabaseClient, invoice: FapiObject, plan: Plan): Promise<SyncResult> {
  const invoiceId = String(invoice.id);

  const { data: existing, error: selError } = await supabase
    .from("memberships")
    .select("user_id")
    .eq("fapi_invoice_id", invoiceId)
    .maybeSingle();
  if (selError) throw new Error(`memberships lookup failed: ${selError.message}`);
  if (existing) return { action: "exists", user_id: existing.user_id };

  const customer = invoice.customer ?? {};
  if (!customer.email) throw new RejectedInvoice(`invoice ${invoice.number} has no customer e-mail — cannot link a user`);
  const userId = await findOrCreateUser(supabase, customer.email, customerName(customer));

  // Renewal paid before the current period ends: the new one follows it.
  const { data: latest, error: latestError } = await supabase
    .from("memberships")
    .select("ends_at")
    .eq("user_id", userId)
    .eq("source", "fapi")
    .in("name", PLAN_NAMES)
    .not("ends_at", "is", null)
    .order("ends_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (latestError) throw new Error(`memberships lookup failed: ${latestError.message}`);

  const paid = paidAt(invoice);
  const currentEnd = latest?.ends_at ? new Date(latest.ends_at) : null;
  const start = currentEnd && currentEnd > paid ? currentEnd : paid;
  const startsAt = start.toISOString();
  const endsAt = addMonths(start, plan.months).toISOString();

  const { error } = await supabase.from("memberships").insert({
    fapi_invoice_id: invoiceId,
    user_id: userId,
    name: plan.name,
    status: "active",
    starts_at: startsAt,
    ends_at: endsAt,
    source: "fapi",
    note: `FAPI faktúra ${invoice.number}`,
  });
  if (error) {
    // Concurrent notification for the same invoice won the insert.
    if (error.code === "23505") return { action: "exists", user_id: userId };
    throw new Error(`memberships insert failed: ${error.message}`);
  }

  return { action: "granted", name: plan.name, starts_at: startsAt, ends_at: endsAt, user_id: userId };
}
