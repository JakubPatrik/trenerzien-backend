-- 1. Nájdenie existujúceho účtu podľa e-mailu pre stripe-webhook (findOrCreateUser)
--
--   find_auth_user_id_by_email()   hľadá v auth.users.email aj v auth.identities
--                                  (po zmene e-mailu môže identita ostať na starej
--                                  adrese a GoTrue potom createUser odmietne
--                                  „already been registered“). Admin API listUsers
--                                  identity nevracia, preto SQL.
--                                  Len pre service_role.
--
-- 2. Rola „Personalistka“ (KLUB) — pohovory vedú len personalistky
--
--   app_role 'personalistka'       rola v user_roles (ako 'leader'); kombinuje sa
--                                  s ostatnými (RL, Z, S, P)
--   is_recruiter() + trigger       rola 'personalistka' → riadok v helpers (active);
--                                  nahrádza väzbu na 'Sprievodkyňa klubu' z 5.sql —
--                                  sprievodkyne už dostupnosť nenastavujú
--   is_helper()                    len aktívny helper (deaktivovaná sprievodkyňa
--                                  nemôže zapisovať dostupnosť cez API)
--   is_club_member()               personalistka má prístup do KLUBu ako lídrka
--   member_badges()                písmenká pri mene v členskej sekcii: RL, Z, S, P
--   RLS user_roles                 admin pridáva / odoberá rolu 'personalistka'
--
-- Spúšťať cez psql (autocommit): ADD VALUE musí byť commitnuté pred použitím.
-- Re-runnable.

CREATE OR REPLACE FUNCTION public.find_auth_user_id_by_email(p_email text)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT id FROM (
    SELECT u.id, 0 AS rank FROM auth.users u
    WHERE lower(u.email) = lower(trim(p_email))
    UNION ALL
    SELECT i.user_id, 1 FROM auth.identities i
    WHERE lower(i.identity_data ->> 'email') = lower(trim(p_email))
  ) m
  ORDER BY rank
  LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.find_auth_user_id_by_email(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.find_auth_user_id_by_email(text) TO service_role;

-- 2. Personalistka ------------------------------------------------------------------------

ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'personalistka';

CREATE OR REPLACE FUNCTION public.is_recruiter(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles r
    WHERE r.user_id = _user_id AND r.role::text = 'personalistka'
  )
$$;

-- Personalistka: riadok v helpers existuje a je active (prepojí helpera pridaného
-- skriptom podľa e-mailu). Nie je personalistka: existujúci riadok → active = false,
-- dostupnosť ostane uložená a booking_slots() ju neponúka.
CREATE OR REPLACE FUNCTION public.sync_recruiter_helper(_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_recruiter boolean := public.is_recruiter(_user_id);
BEGIN
  IF _user_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.helpers WHERE user_id = _user_id) THEN
    UPDATE public.helpers SET active = v_recruiter WHERE user_id = _user_id AND active <> v_recruiter;
  ELSIF v_recruiter THEN
    INSERT INTO public.helpers (user_id, name, email, active)
    SELECT u.id, coalesce(nullif(trim(p.full_name), ''), split_part(u.email, '@', 1)), lower(u.email), true
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    WHERE u.id = _user_id AND u.email IS NOT NULL
    ON CONFLICT (lower(email)) DO UPDATE
      SET user_id = EXCLUDED.user_id, active = true
      WHERE public.helpers.user_id IS NULL;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_recruiter_helper_on_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP <> 'INSERT' AND OLD.role::text = 'personalistka' THEN
    PERFORM public.sync_recruiter_helper(OLD.user_id);
  END IF;
  IF TG_OP <> 'DELETE' AND NEW.role::text = 'personalistka' THEN
    PERFORM public.sync_recruiter_helper(NEW.user_id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS sync_recruiter_helper ON public.user_roles;
CREATE TRIGGER sync_recruiter_helper AFTER INSERT OR UPDATE OR DELETE ON public.user_roles
FOR EACH ROW EXECUTE FUNCTION public.sync_recruiter_helper_on_role();

-- Členstvo 'Sprievodkyňa klubu' už helpers neriadi (is_guide() ostáva — písmenko S).
DROP TRIGGER IF EXISTS sync_guide_helper ON public.memberships;
DROP FUNCTION IF EXISTS public.sync_guide_helper_on_membership();
DROP FUNCTION IF EXISTS public.sync_guide_helper(uuid);

-- Neaktívny helper nič nezapisuje ani nečíta (dostupnosť, voľno, pohovory, dotazníky).
CREATE OR REPLACE FUNCTION public.is_helper(_helper_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.helpers WHERE id = _helper_id AND user_id = auth.uid() AND active)
$$;

-- Ako 3.sql, rola 'personalistka' dáva prístup do KLUBu rovnako ako 'leader'.
CREATE OR REPLACE FUNCTION public.is_club_member(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT _user_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = _user_id AND r.role::text IN ('admin','leader','personalistka'))
    OR EXISTS (
      SELECT 1 FROM public.memberships m
      WHERE m.user_id = _user_id AND m.source IS NOT NULL
        AND m.name IN (
          'Zakladateľské členstvo — ročné',
          'Zakladateľské členstvo — mesačné',
          'Zakladateľské členstvo — prevodom',
          'Sprievodkyňa klubu',
          'Členstvo — mesačné',
          'Členstvo — štvrťročné',
          'Členstvo — ročné'
        )
        AND (m.ends_at IS NULL OR m.ends_at > now())
    )
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.membership_ends_on >= current_date)
  )
$function$;

-- Písmenká pri mene (hodnosti, kombinujú sa), vždy v poradí RL, Z, S, P:
--   RL  legionárna líderka    user_roles 'leader' (ako regional_leaders())
--   Z   zakladateľka          profiles.founder_at (ako member_directory())
--   S   sprievodkyňa          aktívne členstvo 'Sprievodkyňa klubu' (is_guide())
--   P   personalistka         user_roles 'personalistka'
-- Len ženy s aspoň jedným písmenkom.
CREATE OR REPLACE FUNCTION public.member_badges()
RETURNS TABLE (user_id uuid, badges text[])
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT b.user_id, b.badges
  FROM (
    SELECT p.id AS user_id,
           array_remove(ARRAY[
             CASE WHEN EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role::text = 'leader') THEN 'RL' END,
             CASE WHEN p.founder_at IS NOT NULL THEN 'Z' END,
             CASE WHEN public.is_guide(p.id) THEN 'S' END,
             CASE WHEN public.is_recruiter(p.id) THEN 'P' END
           ], NULL) AS badges
    FROM public.profiles p
  ) b
  WHERE auth.uid() IS NOT NULL AND cardinality(b.badges) > 0
$$;

REVOKE ALL ON FUNCTION public.is_recruiter(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_recruiter(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_recruiter_helper(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_recruiter_helper(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.sync_recruiter_helper_on_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.member_badges() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.member_badges() TO authenticated, service_role;

-- Admin v KLUBe pridáva / odoberá personalistky (ostatné roly ďalej len SQL).
DROP POLICY IF EXISTS "Admins add recruiter role" ON public.user_roles;
CREATE POLICY "Admins add recruiter role" ON public.user_roles
FOR INSERT TO authenticated
WITH CHECK (role::text = 'personalistka' AND public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Admins remove recruiter role" ON public.user_roles;
CREATE POLICY "Admins remove recruiter role" ON public.user_roles
FOR DELETE TO authenticated
USING (role::text = 'personalistka' AND public.has_role(auth.uid(), 'admin'::app_role));

-- Dnešní helperi s kontom: personalistky → active, sprievodkyne bez roly → active = false.
-- (Helperi mimo klubu z 10-add-helper.sh bez tejto väzby sa nemenia.)
DO $$ BEGIN
  PERFORM public.sync_recruiter_helper(user_id)
  FROM (
    SELECT user_id FROM public.user_roles WHERE role::text = 'personalistka'
    UNION
    SELECT user_id FROM public.memberships WHERE name = 'Sprievodkyňa klubu'
  ) x;
END $$;
