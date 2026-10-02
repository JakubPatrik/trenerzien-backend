#!/usr/bin/env python3
"""
Transform klub's static export (supabase/klub/export/*.json) into the shape
of the shared target schema (vyzva project), and generate the SQL to sync it.

Identity merge: klub members whose email already exists in the target
profiles table (37 of 123, imported earlier via vyzva) get remapped onto
that EXISTING user_id instead of creating a duplicate auth account. The
other 86 keep their original klub id and need a new auth user created.

Inputs (all local, static — the only non-static input is
_target-profiles.json, itself a plain snapshot written by
01-fetch-target-profiles.sh):
  export/auth_users.json, profiles.json, user_roles.json, memberships.json
  export/_target-profiles.json

Outputs:
  export/raw/{profiles,user_roles,memberships}.json   (untouched originals, backed up)
  export/profiles.json, user_roles.json, memberships.json   (overwritten, transformed)
  export/id-map.json                  (klub_id -> target_id, for reference)
  bin/sql/02-profiles.sql, 03-user_roles.sql, 04-memberships.sql

04-import-users.sh derives the ~86 users needing a fresh auth account
directly from the transformed profiles.json (id+email) — no separate file,
since profiles.json already carries that data for every row; the merged
37 just get a harmless "already exists" from the Admin API.
"""
import json
import shutil
from pathlib import Path

KLUB_DIR = Path(__file__).resolve().parent.parent
EXPORT_DIR = KLUB_DIR / "export"
SQL_DIR = Path(__file__).resolve().parent / "sql"
RAW_DIR = EXPORT_DIR / "raw"


def load(name):
    with open(EXPORT_DIR / name) as f:
        return json.load(f)


def sql_lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v).replace("'", "''")
    return f"'{s}'"


def main():
    # Back up untouched originals FIRST (before anything below might read
    # export/profiles.json etc, which a previous run may have already
    # overwritten with transformed/remapped data) — raw/ is always the
    # pristine source of truth for re-runs.
    RAW_DIR.mkdir(exist_ok=True)
    for name in ("profiles.json", "user_roles.json", "memberships.json"):
        dst = RAW_DIR / name
        if not dst.exists():
            shutil.copy(EXPORT_DIR / name, dst)

    auth_users = load("auth_users.json")
    profiles = json.load(open(RAW_DIR / "profiles.json"))
    user_roles = json.load(open(RAW_DIR / "user_roles.json"))
    memberships = json.load(open(RAW_DIR / "memberships.json"))
    target_profiles = load("_target-profiles.json")

    email_by_klub_id = {u["id"]: (u.get("email") or "").strip() for u in auth_users}
    target_id_by_email = {
        (p["email"] or "").strip().lower(): p["id"]
        for p in target_profiles
        if p.get("email")
    }

    id_map = {}
    new_auth_users = []
    for u in auth_users:
        email = email_by_klub_id[u["id"]]
        existing = target_id_by_email.get(email.lower())
        if existing:
            id_map[u["id"]] = existing
        else:
            id_map[u["id"]] = u["id"]
            new_auth_users.append({"id": u["id"], "email": email})

    merged = sum(1 for k, v in id_map.items() if k != v)
    print(f"Identity map: {len(id_map)} klub users, {merged} merged onto existing "
          f"target accounts, {len(new_auth_users)} need a new auth account "
          f"(04-import-users.sh derives this straight from profiles.json, "
          f"which already carries id+email for everyone).")

    with open(EXPORT_DIR / "id-map.json", "w") as f:
        json.dump(id_map, f, indent=2, ensure_ascii=False)

    # --- profiles ---
    profile_cols = [
        "id", "email", "full_name", "created_at", "updated_at", "avatar_url",
        "challenge_start_date", "city", "region", "lat", "lng", "show_on_map",
        "birth_year", "phone", "bio", "goal", "motivation", "profile_completed_at",
        "height_cm", "weight_kg", "health_notes", "target_weight_kg",
        "target_waist_cm", "founder_at", "invitation", "admin_note",
        "membership_ends_on", "nickname", "postal_code", "region_slug",
    ]
    # On conflict (identity merge), never touch the columns the existing
    # (vyzva) account already owns — only fill in klub-introduced columns.
    profile_preserve_on_conflict = {"id", "email", "full_name", "created_at", "invited_at"}
    profile_update_cols = [c for c in profile_cols if c not in profile_preserve_on_conflict]

    new_profiles = []
    profile_rows_sql = []
    for row in profiles:
        new_id = id_map[row["id"]]
        out = {
            "id": new_id,
            "email": email_by_klub_id.get(row["id"]),
            "full_name": row.get("full_name"),
            "created_at": row.get("created_at"),
            "updated_at": row.get("updated_at"),
            "avatar_url": row.get("avatar_url"),
            "challenge_start_date": row.get("challenge_start_date"),
            "city": row.get("city"),
            "region": row.get("region"),
            "lat": row.get("lat"),
            "lng": row.get("lng"),
            "show_on_map": row.get("show_on_map"),
            "birth_year": row.get("birth_year"),
            "phone": row.get("phone"),
            "bio": row.get("bio"),
            "goal": row.get("goal"),
            "motivation": row.get("motivation"),
            "profile_completed_at": row.get("profile_completed_at"),
            "height_cm": row.get("height_cm"),
            "weight_kg": row.get("weight_kg"),
            "health_notes": row.get("health_notes"),
            "target_weight_kg": row.get("target_weight_kg"),
            "target_waist_cm": row.get("target_waist_cm"),
            "founder_at": row.get("founder_at"),
            "invitation": row.get("invitation"),
            "admin_note": row.get("admin_note"),
            "membership_ends_on": row.get("membership_ends_on"),
            "nickname": row.get("nickname"),
            "postal_code": row.get("postal_code"),
            "region_slug": row.get("region_slug"),
        }
        new_profiles.append(out)
        profile_rows_sql.append(
            "    (" + ", ".join(sql_lit(out[c]) for c in profile_cols) + ")"
        )

    with open(EXPORT_DIR / "profiles.json", "w") as f:
        json.dump(new_profiles, f, indent=2, ensure_ascii=False)

    profiles_sql = (
        "-- Generated by 02-transform.py from supabase/klub/export/{profiles,auth_users}.json.\n"
        "-- On identity-merge conflicts (id already exists, from vyzva), only the\n"
        "-- klub-introduced columns are updated; email/full_name/created_at/invited_at\n"
        "-- on the existing account are left untouched.\n"
        "INSERT INTO public.profiles (\n"
        "    " + ", ".join(profile_cols) + "\n"
        ") VALUES\n"
        + ",\n".join(profile_rows_sql) + "\n"
        "ON CONFLICT (id) DO UPDATE SET\n"
        + ",\n".join(f"    {c} = excluded.{c}" for c in profile_update_cols) + ";\n"
    )
    (SQL_DIR / "02-profiles.sql").write_text(profiles_sql)

    # --- user_roles ---
    role_cols = ["id", "user_id", "role", "created_at"]
    # klub's role enum uses 'client'; the shared target enum uses 'user' for
    # the same meaning — map onto the existing value, no new enum label needed.
    role_value_map = {"client": "user", "admin": "admin"}

    new_roles = []
    role_rows_sql = []
    for row in user_roles:
        out = {
            "id": row["id"],
            "user_id": id_map[row["user_id"]],
            "role": role_value_map.get(row["role"], row["role"]),
            "created_at": row.get("created_at"),
        }
        new_roles.append(out)
        role_rows_sql.append("    (" + ", ".join(sql_lit(out[c]) for c in role_cols) + ")")

    with open(EXPORT_DIR / "user_roles.json", "w") as f:
        json.dump(new_roles, f, indent=2, ensure_ascii=False)

    roles_sql = (
        "-- Generated by 02-transform.py from supabase/klub/export/user_roles.json.\n"
        "-- Bare ON CONFLICT DO NOTHING (no target column): catches a\n"
        "-- violation of EITHER unique constraint (id, or (user_id, role) —\n"
        "-- e.g. a merged user who is 'admin' in both apps), so this stays\n"
        "-- safely re-runnable rather than only guarding the one target named.\n"
        "INSERT INTO public.user_roles (\n"
        "    " + ", ".join(role_cols) + "\n"
        ") VALUES\n"
        + ",\n".join(role_rows_sql) + "\n"
        "ON CONFLICT DO NOTHING;\n"
    )
    (SQL_DIR / "03-user_roles.sql").write_text(roles_sql)

    # --- memberships ---
    membership_cols = [
        "id", "user_id", "name", "status", "starts_at", "ends_at",
        "source", "note", "created_at", "updated_at",
    ]
    new_memberships = []
    membership_rows_sql = []
    for row in memberships:
        is_lifetime = bool(row.get("is_lifetime"))
        ends_at = None if is_lifetime else row.get("ends_on")
        out = {
            "id": row["id"],
            "user_id": id_map[row["user_id"]],
            "name": row.get("plan"),
            "status": "active",
            # starts_at is NOT NULL on the target table; klub has 1 row with
            # no started_on (an old imported record) — fall back to created_at.
            "starts_at": row.get("started_on") or row.get("created_at"),
            "ends_at": ends_at,
            "source": row.get("source") or "fapi",
            "note": row.get("note"),
            "created_at": row.get("created_at"),
            "updated_at": row.get("updated_at"),
        }
        new_memberships.append(out)
        membership_rows_sql.append(
            "    (" + ", ".join(sql_lit(out[c]) for c in membership_cols) + ")"
        )

    with open(EXPORT_DIR / "memberships.json", "w") as f:
        json.dump(new_memberships, f, indent=2, ensure_ascii=False)

    memberships_sql = (
        "-- Generated by 02-transform.py from supabase/klub/export/memberships.json.\n"
        "-- plan->name, started_on/ends_on->starts_at/ends_at, status is always\n"
        "-- 'active' (klub source has no status column), is_lifetime dropped —\n"
        "-- folded into ends_at IS NULL instead, source defaults to 'fapi' when\n"
        "-- missing (none were, as of this export, but kept for safety).\n"
        "-- Bare DO NOTHING (no target): safe against id AND any other unique\n"
        "-- constraint on this table on a re-run.\n"
        "INSERT INTO public.memberships (\n"
        "    " + ", ".join(membership_cols) + "\n"
        ") VALUES\n"
        + ",\n".join(membership_rows_sql) + "\n"
        "ON CONFLICT DO NOTHING;\n"
    )
    (SQL_DIR / "04-memberships.sql").write_text(memberships_sql)

    print(f"profiles: {len(new_profiles)} rows -> {SQL_DIR / '02-profiles.sql'}")
    print(f"user_roles: {len(new_roles)} rows -> {SQL_DIR / '03-user_roles.sql'}")
    print(f"memberships: {len(new_memberships)} rows -> {SQL_DIR / '04-memberships.sql'}")
    print(f"new auth users needed: {len(new_auth_users)} (created by 04-import-users.sh from profiles.json)")


if __name__ == "__main__":
    main()
