-- Reconcile the shared profiles/user_roles/memberships tables (currently
-- vyzva-shaped, already holding 3211/3211/3250 live rows) so klub's data can
-- be merged in. Every ADD COLUMN is IF NOT EXISTS / guarded, so this file is
-- safe to re-run.
--
-- Note: klub's role enum uses 'client' where vyzva's uses 'user' for the
-- same meaning — 02-transform.py maps 'client' -> 'user' in the data, so no
-- new app_role enum label is needed here.

-- 1. invitation_state enum (klub-only, new).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invitation_state') THEN
    CREATE TYPE public.invitation_state AS ENUM ('none', 'invited', 'accepted');
  END IF;
END $$;

-- 2. profiles: rename display_name -> full_name (klub's naming), then add
-- every klub-only column (union of both apps' profile fields).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'display_name'
  ) THEN
    ALTER TABLE public.profiles RENAME COLUMN display_name TO full_name;
  END IF;
END $$;

-- handle_new_user() (the auth.users trigger) still inserts into the
-- now-nonexistent `display_name` column — every brand-new signup fails with
-- a generic 500 "Database error creating new user" until this is fixed.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data ->> 'display_name', NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name')
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'user')
  ON CONFLICT (user_id, role) DO NOTHING;

  RETURN NEW;
END;
$function$;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_url text,
  ADD COLUMN IF NOT EXISTS challenge_start_date date,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS region text,
  ADD COLUMN IF NOT EXISTS lat numeric,
  ADD COLUMN IF NOT EXISTS lng numeric,
  ADD COLUMN IF NOT EXISTS show_on_map boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS birth_year integer,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS bio text,
  ADD COLUMN IF NOT EXISTS goal text,
  ADD COLUMN IF NOT EXISTS motivation text,
  ADD COLUMN IF NOT EXISTS profile_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS height_cm numeric,
  ADD COLUMN IF NOT EXISTS weight_kg numeric,
  ADD COLUMN IF NOT EXISTS health_notes text,
  ADD COLUMN IF NOT EXISTS target_weight_kg numeric,
  ADD COLUMN IF NOT EXISTS target_waist_cm numeric,
  ADD COLUMN IF NOT EXISTS founder_at timestamptz,
  ADD COLUMN IF NOT EXISTS invitation public.invitation_state NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS admin_note text,
  ADD COLUMN IF NOT EXISTS membership_ends_on date,
  ADD COLUMN IF NOT EXISTS nickname text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS region_slug text;

-- 3. memberships: drop plan_name (verified byte-identical to the existing
-- 'name' column across all 3250 current rows, so this loses nothing), add
-- klub's updated_at/source/note. is_lifetime is intentionally NOT added —
-- per instruction, ends_at IS NULL carries that meaning instead.
ALTER TABLE public.memberships DROP COLUMN IF EXISTS plan_name;
ALTER TABLE public.memberships
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS source text,
  ADD COLUMN IF NOT EXISTS note text;
