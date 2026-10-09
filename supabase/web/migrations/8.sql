-- Rola „Sprievodkyňa“ v user_roles — nahrádza členstvo 'Sprievodkyňa klubu'
--
--   app_role 'sprievodkyna'        rola v user_roles (ako 'lider' / 'personalistka');
--                                  kombinuje sa s ostatnými
--   backfill                       aktívne členstvo 'Sprievodkyňa klubu' (podmienka
--                                  is_guide() z 5.sql) → rola; kontrola, že ju má
--                                  každá dnešná sprievodkyňa, inak sa nič neprepne
--   is_guide()                     podľa roly, nie členstva (písmenko S v
--                                  member_badges() ide cez is_guide())
--   is_club_member()               rola 'sprievodkyna' dáva prístup do KLUBu ako
--                                  'lider'; členstvo 'Sprievodkyňa klubu' ostáva
--                                  v zozname, nikto prístup nestratí
--   RLS user_roles                 admin pridáva / odoberá rolu 'sprievodkyna'
--
-- Členstvo 'Sprievodkyňa klubu' už sprievodkyňu neurčuje (ostáva len kvôli
-- prístupu). Novú sprievodkyňu pridá admin v KLUBe alebo
-- 19-add-roles.sh <email> sprievodkyna.
--
-- ADD VALUE musí byť commitnuté skôr, než sa nová hodnota použije (inak
-- „unsafe use of new value“) — spúšťaj cez psql -f bez --single-transaction
-- (21-apply-guide-role.sh), každý príkaz sa commitne zvlášť. Re-runnable.

ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'sprievodkyna';

-- 1. Dnešné sprievodkyne dostanú rolu ---------------------------------------------------

INSERT INTO public.user_roles (user_id, role)
SELECT DISTINCT m.user_id, 'sprievodkyna'::public.app_role
FROM public.memberships m
WHERE m.name = 'Sprievodkyňa klubu'
  AND m.status::text = 'active'
  AND (m.ends_at IS NULL OR m.ends_at > now())
  AND m.user_id IS NOT NULL
ON CONFLICT (user_id, role) DO NOTHING;

-- Pred prepnutím is_guide(): nikto, kto je dnes sprievodkyňa, nesmie ostať bez roly.
DO $$
DECLARE
  v_missing int;
BEGIN
  SELECT count(DISTINCT m.user_id) INTO v_missing
  FROM public.memberships m
  WHERE m.name = 'Sprievodkyňa klubu'
    AND m.status::text = 'active'
    AND (m.ends_at IS NULL OR m.ends_at > now())
    AND m.user_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.user_roles r
      WHERE r.user_id = m.user_id AND r.role::text = 'sprievodkyna'
    );
  IF v_missing > 0 THEN
    RAISE EXCEPTION '% guide(s) without the sprievodkyna role, is_guide() not switched', v_missing;
  END IF;
END $$;

-- 2. Sprievodkyňa = rola --------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_guide(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles r
    WHERE r.user_id = _user_id AND r.role::text = 'sprievodkyna'
  )
$$;

-- Ako 6.sql, rola 'sprievodkyna' dáva prístup do KLUBu rovnako ako 'lider'.
CREATE OR REPLACE FUNCTION public.is_club_member(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT _user_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = _user_id AND r.role::text IN ('admin','lider','personalistka','sprievodkyna'))
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

REVOKE ALL ON FUNCTION public.is_guide(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_guide(uuid) TO authenticated, service_role;

-- 3. Admin v KLUBe pridáva / odoberá sprievodkyne --------------------------------------

DROP POLICY IF EXISTS "Admins add guide role" ON public.user_roles;
CREATE POLICY "Admins add guide role" ON public.user_roles
FOR INSERT TO authenticated
WITH CHECK (role::text = 'sprievodkyna' AND public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Admins remove guide role" ON public.user_roles;
CREATE POLICY "Admins remove guide role" ON public.user_roles
FOR DELETE TO authenticated
USING (role::text = 'sprievodkyna' AND public.has_role(auth.uid(), 'admin'::app_role));
