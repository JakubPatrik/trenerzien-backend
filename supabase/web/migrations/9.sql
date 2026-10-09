-- Rola 'leader' a 'lider' → len 'lider'
--
--   user_roles                     každé 'leader' sa prepíše na 'lider' (kto má
--                                  obe, ostane mu len 'lider')
--   funkcie v public               literál 'leader' → 'lider' (is_club_member,
--                                  member_badges, regional_leaders,
--                                  set_club_event_people, ...); prepisujú sa
--                                  z aktuálnej definície v DB, takže aj tie,
--                                  ktoré vznikli mimo týchto migrácií
--   RLS politiky                   to isté (club_events ...)
--   trigger na user_roles          nové 'leader' (napr. starý frontend) sa
--                                  uloží ako 'lider', rozdelenie sa nevráti
--
-- Hodnota 'leader' v enume app_role ostáva — Postgres hodnotu z enumu odobrať
-- nevie a nový typ by znamenal prerobiť každú politiku s has_role(). Nikto ju
-- už nemá a nikde sa nepoužíva. Na konci kontrola, inak sa všetko vráti.
--
-- Spúšťaj cez 22-merge-leader-role.sh (jedna transakcia). Re-runnable.
-- 3.sql / 6.sql ešte 'leader' používajú — po tejto migrácii ich znova nespúšťaj
-- (8.sql už používa 'lider').

-- 1. Dáta ---------------------------------------------------------------------------------

DELETE FROM public.user_roles r
WHERE r.role::text = 'leader'
  AND EXISTS (SELECT 1 FROM public.user_roles l WHERE l.user_id = r.user_id AND l.role::text = 'lider');

UPDATE public.user_roles SET role = 'lider'::public.app_role WHERE role::text = 'leader';

-- 2. Funkcie ------------------------------------------------------------------------------

-- CREATE OR REPLACE ponechá vlastníka aj granty.
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND p.proname <> 'user_roles_leader_to_lider'
      AND pg_get_functiondef(p.oid) LIKE '%''leader''%'
  LOOP
    RAISE NOTICE 'function %: leader → lider', f.proname;
    EXECUTE replace(f.def, '''leader''', '''lider''');
  END LOOP;
END $$;

-- 3. RLS politiky -------------------------------------------------------------------------

DO $$
DECLARE
  p record;
  v_sql text;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname, qual, with_check
    FROM pg_policies
    WHERE coalesce(qual, '') || coalesce(with_check, '') LIKE '%''leader''%'
  LOOP
    RAISE NOTICE 'policy % on %.%: leader → lider', p.policyname, p.schemaname, p.tablename;
    v_sql := format('ALTER POLICY %I ON %I.%I', p.policyname, p.schemaname, p.tablename);
    IF p.qual IS NOT NULL THEN
      v_sql := v_sql || ' USING (' || replace(p.qual, '''leader''', '''lider''') || ')';
    END IF;
    IF p.with_check IS NOT NULL THEN
      v_sql := v_sql || ' WITH CHECK (' || replace(p.with_check, '''leader''', '''lider''') || ')';
    END IF;
    EXECUTE v_sql;
  END LOOP;
END $$;

-- 4. Nové 'leader' sa uloží ako 'lider' -------------------------------------------------------

CREATE OR REPLACE FUNCTION public.user_roles_leader_to_lider()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.role::text = 'leader' THEN
    NEW.role := 'lider'::public.app_role;
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION public.user_roles_leader_to_lider() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS user_roles_leader_to_lider ON public.user_roles;
CREATE TRIGGER user_roles_leader_to_lider
BEFORE INSERT OR UPDATE OF role ON public.user_roles
FOR EACH ROW EXECUTE FUNCTION public.user_roles_leader_to_lider();

-- 5. Kontrola -----------------------------------------------------------------------------

DO $$
DECLARE
  v_rows int;
  v_funcs text;
  v_policies text;
BEGIN
  SELECT count(*) INTO v_rows FROM public.user_roles WHERE role::text = 'leader';

  SELECT string_agg(p.proname, ', ') INTO v_funcs
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f'
    AND p.proname <> 'user_roles_leader_to_lider'
    AND pg_get_functiondef(p.oid) LIKE '%''leader''%';

  SELECT string_agg(policyname, ', ') INTO v_policies
  FROM pg_policies
  WHERE coalesce(qual, '') || coalesce(with_check, '') LIKE '%''leader''%';

  IF v_rows > 0 OR v_funcs IS NOT NULL OR v_policies IS NOT NULL THEN
    RAISE EXCEPTION 'leader still in use: % row(s), functions [%], policies [%]',
      v_rows, coalesce(v_funcs, ''), coalesce(v_policies, '');
  END IF;
END $$;
