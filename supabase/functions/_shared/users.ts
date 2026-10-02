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
  if (error?.code === "email_exists") {
    const again = await findUserIdByEmail(supabase, normalized);
    if (again) return again;
  }
  throw new Error(`createUser failed for ${normalized}: ${error?.message ?? "no user returned"}`);
}
