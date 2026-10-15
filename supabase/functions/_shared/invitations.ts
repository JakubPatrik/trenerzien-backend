// KLUB invitation email: a link to <site>/nove-heslo where the member sets her
// password. Used by send-invitations (admin, by hand) and by the purchase
// webhooks (automatically, for accounts they created).
//
// generateLink({ type: "recovery" }) → hashed_token → <site>/nove-heslo?t=<hashed_token>
// → our own email via SmartEmailing. The link carries the hashed token, never
// action_link: mail scanners open links and would consume /auth/v1/verify.
// /nove-heslo verifies only on submit (verifyOtp({ token_hash, type: "recovery" })).
// Each generateLink invalidates the member's previous link. Link validity
// (7 days) = Supabase Auth email OTP expiry.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { inviteEmail } from "./invite-email.ts";
import { sendEmail } from "./smartemailing.ts";

// Links always point to production — never to a preview / localhost origin.
export const PUBLIC_SITE_URL = "https://klub.trenerzien.sk";

// app_metadata.created_by on auth users a purchase webhook created (see
// users.ts). Only those are invited automatically; accounts that existed
// before the purchase are left to the admin.
export type Creator = "stripe-webhook" | "fapi-webhook";

export type InviteResult =
  | { ok: true; userId: string; inviteUrl: string }
  | { ok: false; error: string; notFound: boolean };

// fullName null → read from profiles.
export async function sendInvite(
  supabase: SupabaseClient,
  email: string,
  fullName: string | null,
  site = PUBLIC_SITE_URL,
): Promise<InviteResult> {
  const { data: link, error } = await supabase.auth.admin.generateLink({
    type: "recovery",
    email,
    options: { redirectTo: `${site}/nove-heslo` },
  });
  const hashed = link?.properties?.hashed_token;
  if (!hashed || !link.user) {
    const notFound = !!error && (error.status === 404 || /not found/i.test(error.message));
    return { ok: false, error: error?.message ?? "Odkaz sa nepodarilo vytvoriť.", notFound };
  }
  const inviteUrl = `${site}/nove-heslo?t=${encodeURIComponent(hashed)}`;

  if (fullName === null) {
    const { data: profile } = await supabase.from("profiles").select("full_name").eq("id", link.user.id).maybeSingle();
    fullName = profile?.full_name ?? null;
  }

  try {
    await sendEmail(inviteEmail({ to: email, fullName: fullName ?? "", inviteUrl }));
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[invite] ${email}: ${message.slice(0, 800)}`);
    return { ok: false, error: message.slice(0, 300), notFound: false };
  }
  return { ok: true, userId: link.user.id, inviteUrl };
}

// Webhooks: invite a member whose account the purchase created, once. Returns
// the address invited, or null when there was nothing to do (account existed
// before, already invited, or she has signed in already). Throws on failure —
// the claim is released, so the webhook's retry sends it.
//
// The claim (profiles.invited_at null → now) makes concurrent events for the
// same purchase (Stripe sends subscription.* and invoice.paid together) send
// one email: a second generateLink would kill the first email's link.
export async function inviteIfCreatedBy(
  supabase: SupabaseClient,
  userId: string,
  creator: Creator,
): Promise<string | null> {
  const { data: u, error: uError } = await supabase.auth.admin.getUserById(userId);
  if (uError || !u?.user) throw new Error(`auth user ${userId} lookup failed: ${uError?.message ?? "not found"}`);
  const user = u.user;
  if (user.app_metadata?.created_by !== creator || user.last_sign_in_at || !user.email) return null;

  const { data: claimed, error: cError } = await supabase
    .from("profiles")
    .update({ invitation: "invited", invited_at: new Date().toISOString() })
    .eq("id", userId)
    .is("invited_at", null)
    .select("id");
  if (cError) throw new Error(`invitation claim failed for ${user.email}: ${cError.message}`);
  if (!claimed?.length) return null;

  const result = await sendInvite(supabase, user.email, null);
  if (!result.ok) {
    const { error: rError } = await supabase
      .from("profiles")
      .update({ invitation: "none", invited_at: null })
      .eq("id", userId);
    if (rError) console.error(`[invite] releasing claim for ${user.email} failed: ${rError.message}`);
    throw new Error(`invitation to ${user.email} failed: ${result.error}`);
  }
  return user.email;
}
