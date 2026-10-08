// Find or create the Supabase user for a purchase (profiles + auth.users).

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

async function findUserIdByEmail(supabase: SupabaseClient, email: string): Promise<string | null> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id")
    .ilike("email", escapeLike(email))
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(`profiles lookup failed: ${error.message}`);
  return data?.id ?? null;
}

// Existing account → its id. Otherwise create the auth user; the
// handle_new_user() trigger creates the profile + "user" role. The account has
// no password: the admin sends the invite from /admin/users ("Pozvať"), since
// profiles.invited_at stays null.
export async function findOrCreateUser(
  supabase: SupabaseClient,
  email: string,
  name: string | null,
): Promise<string> {
  const normalized = email.trim().toLowerCase();

  const found = await findUserIdByEmail(supabase, normalized);
  if (found) return found;

  const { data, error } = await supabase.auth.admin.createUser({
    email: normalized,
    email_confirm: true,
    user_metadata: name ? { display_name: name } : {},
  });
  if (!error && data.user) {
    console.log(`[access] created user ${data.user.id} for ${normalized}`);
    return data.user.id;
  }

  // Race / auth user without profile: the email is already registered.
  if (error && isEmailExists(error)) {
    const again = await findUserIdByEmail(supabase, normalized);
    if (again) return again;

    const authId = await findAuthUserIdByEmail(supabase, normalized);
    if (authId) {
      await ensureProfile(supabase, authId, normalized, name);
      console.log(`[access] linked existing auth user ${authId} for ${normalized} (profile was missing)`);
      return authId;
    }
  }
  throw new Error(`createUser failed for ${normalized}: ${error?.message ?? "no user returned"}`);
}

function isEmailExists(error: { code?: string; message?: string }): boolean {
  return error.code === "email_exists" || /already been registered/i.test(error.message ?? "");
}

// GoTrue's "already registered" also covers identity emails: after an email
// change the user's email identity can keep the old address. The admin API
// can't search either (listUsers omits identities), so this is SQL
// (web/migrations/6.sql).
async function findAuthUserIdByEmail(supabase: SupabaseClient, email: string): Promise<string | null> {
  const { data, error } = await supabase.rpc("find_auth_user_id_by_email", { p_email: email });
  if (error) throw new Error(`auth user lookup failed: ${error.message}`);
  return data ?? null;
}

// Backfill what handle_new_user() would have created (the account predates the
// trigger or the trigger failed). Existing rows are left untouched.
async function ensureProfile(
  supabase: SupabaseClient,
  id: string,
  email: string,
  name: string | null,
): Promise<void> {
  const { error: pError } = await supabase
    .from("profiles")
    .upsert({ id, email, full_name: name }, { onConflict: "id", ignoreDuplicates: true });
  if (pError) throw new Error(`profile backfill failed for ${email}: ${pError.message}`);

  const { error: rError } = await supabase
    .from("user_roles")
    .upsert({ user_id: id, role: "user" }, { onConflict: "user_id,role", ignoreDuplicates: true });
  if (rError) throw new Error(`user_roles backfill failed for ${email}: ${rError.message}`);
}
