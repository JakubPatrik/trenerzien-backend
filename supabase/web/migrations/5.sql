-- Sprievodkyne klubu nastavujú dostupnosť v KLUBe (stránka „Moja dostupnosť“)
--
--   helper_availability.date   konkrétny deň (Europe/Bratislava). Riadok má buď
--                              date (KLUB: jeden časový slot v daný deň), alebo
--                              day_of_week (týždenné okno, 10-add-helper.sh).
--                              Dátum len od dnes do dnes + horizon_days.
--   booking_slots()            ponúka sloty z oboch druhov riadkov
--   is_guide() + trigger       aktívne členstvo 'Sprievodkyňa klubu' → riadok v helpers
--                              (vytvorí / prepojí podľa e-mailu / active = true|false)
--   booking_settings           horizont 21 → 31 dní (sprievodkyne plánujú mesiac dopredu)
--
-- Spúšťa sa po 4.sql (08-apply-booking.sh spúšťa obe). Re-runnable.

-- 1. Dostupnosť na konkrétny dátum ---------------------------------------------------

ALTER TABLE public.helper_availability ADD COLUMN IF NOT EXISTS date date;
ALTER TABLE public.helper_availability ALTER COLUMN day_of_week DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'helper_availability_day_or_date') THEN
    ALTER TABLE public.helper_availability
      ADD CONSTRAINT helper_availability_day_or_date CHECK ((day_of_week IS NULL) <> (date IS NULL));
  END IF;
END $$;

-- Jeden slot v daný deň a čas najviac raz (dvojklik na čip v UI).
CREATE UNIQUE INDEX IF NOT EXISTS helper_availability_date_slot_key
  ON public.helper_availability (helper_id, date, start_time) WHERE date IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validate_timezone_name(_tz text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM now() AT TIME ZONE _tz;
EXCEPTION WHEN invalid_parameter_value THEN
  RAISE EXCEPTION 'invalid timezone: %', _tz USING ERRCODE = 'check_violation';
END;
$$;

-- Dátum musí byť od dnes do konca horizontu (nie do minulosti, nie na
-- neobmedzene dlho dopredu). Staré riadky ostávajú, booking_slots() ich ignoruje.
CREATE OR REPLACE FUNCTION public.validate_availability_date()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_today date;
  v_horizon integer;
BEGIN
  IF NEW.date IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM public.validate_timezone_name(NEW.timezone);
  v_today := (now() AT TIME ZONE NEW.timezone)::date;
  v_horizon := (SELECT horizon_days FROM public.booking_settings WHERE id);
  IF NEW.date < v_today OR NEW.date > v_today + v_horizon THEN
    RAISE EXCEPTION 'availability date % is outside % – %', NEW.date, v_today, v_today + v_horizon
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_helper_availability_date ON public.helper_availability;
CREATE TRIGGER validate_helper_availability_date BEFORE INSERT OR UPDATE OF date, timezone ON public.helper_availability
FOR EACH ROW EXECUTE FUNCTION public.validate_availability_date();

-- 2. Voľné termíny (rovnaké ako v 4.sql + riadky s date) ---------------------------------
CREATE OR REPLACE FUNCTION public.booking_slots(
    p_from timestamp with time zone DEFAULT now(),
    p_to timestamp with time zone DEFAULT NULL
)
RETURNS TABLE (starts_at timestamp with time zone, ends_at timestamp with time zone, helper_id uuid, helper_name text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH s AS (
    SELECT
      make_interval(mins => slot_minutes) AS slot,
      make_interval(mins => slot_step_minutes) AS step,
      make_interval(mins => buffer_minutes) AS buffer,
      greatest(coalesce(p_from, now()), now() + make_interval(mins => min_notice_minutes)) AS lo,
      least(coalesce(p_to, 'infinity'), now() + make_interval(days => horizon_days)) AS hi
    FROM public.booking_settings
    WHERE id
  ),
  windows AS (
    SELECT h.id AS helper_id, h.name AS helper_name, h.sort_order, a.start_time, a.end_time, a.timezone, d::date AS local_day
    FROM s
    CROSS JOIN public.helpers h
    JOIN public.helper_availability a ON a.helper_id = h.id
    CROSS JOIN LATERAL generate_series(
      (s.lo AT TIME ZONE a.timezone)::date,
      (s.hi AT TIME ZONE a.timezone)::date,
      interval '1 day'
    ) AS d
    WHERE h.active
      AND s.lo <= s.hi
      AND (a.date = d::date OR (a.date IS NULL AND extract(isodow FROM d) = a.day_of_week))
  ),
  candidates AS (
    SELECT DISTINCT
      w.helper_id,
      w.helper_name,
      w.sort_order,
      (t AT TIME ZONE w.timezone) AS starts_at,
      (t AT TIME ZONE w.timezone) + s.slot AS ends_at
    FROM windows w
    CROSS JOIN s
    CROSS JOIN LATERAL generate_series(
      w.local_day + w.start_time,
      w.local_day + w.end_time - s.slot,
      s.step
    ) AS t
  )
  SELECT c.starts_at, c.ends_at, c.helper_id, c.helper_name
  FROM candidates c
  CROSS JOIN s
  WHERE c.starts_at BETWEEN s.lo AND s.hi
    AND NOT EXISTS (
      SELECT 1 FROM public.helper_time_off o
      WHERE o.helper_id = c.helper_id
        AND tstzrange(o.starts_at, o.ends_at, '[)') && tstzrange(c.starts_at, c.ends_at, '[)')
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.appointments ap
      WHERE ap.helper_id = c.helper_id
        AND (ap.status = 'confirmed' OR (ap.status = 'pending' AND ap.created_at > now() - interval '10 minutes'))
        AND tstzrange(ap.starts_at - s.buffer, ap.ends_at + s.buffer, '[)') && tstzrange(c.starts_at, c.ends_at, '[)')
    )
  ORDER BY c.starts_at, c.sort_order, c.helper_name
$$;

-- 3. Sprievodkyne → helpers ----------------------------------------------------------------
-- Členstvo rozhoduje (nie rola leader). Dnes doživotné, nastavované ručne; ak
-- pribudnú časovo obmedzené, treba denný pg_cron so sync_guide_helper() pre všetky.

CREATE OR REPLACE FUNCTION public.is_guide(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = _user_id
      AND m.name = 'Sprievodkyňa klubu'
      AND m.status::text = 'active'
      AND (m.ends_at IS NULL OR m.ends_at > now())
  )
$$;

-- Sprievodkyňa: riadok v helpers existuje a je active (prepojí helpera pridaného
-- skriptom podľa e-mailu). Nie je sprievodkyňa: existujúci riadok → active = false,
-- dostupnosť ostane uložená a booking_slots() ju neponúka.
CREATE OR REPLACE FUNCTION public.sync_guide_helper(_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_guide boolean := public.is_guide(_user_id);
BEGIN
  IF _user_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.helpers WHERE user_id = _user_id) THEN
    UPDATE public.helpers SET active = v_guide WHERE user_id = _user_id AND active <> v_guide;
  ELSIF v_guide THEN
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

CREATE OR REPLACE FUNCTION public.sync_guide_helper_on_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP <> 'INSERT' AND OLD.name = 'Sprievodkyňa klubu' THEN
    PERFORM public.sync_guide_helper(OLD.user_id);
  END IF;
  IF TG_OP <> 'DELETE' AND NEW.name = 'Sprievodkyňa klubu'
     AND (TG_OP = 'INSERT' OR NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.name IS DISTINCT FROM OLD.name
          OR NEW.status IS DISTINCT FROM OLD.status OR NEW.ends_at IS DISTINCT FROM OLD.ends_at) THEN
    PERFORM public.sync_guide_helper(NEW.user_id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS sync_guide_helper ON public.memberships;
CREATE TRIGGER sync_guide_helper AFTER INSERT OR UPDATE OR DELETE ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public.sync_guide_helper_on_membership();

REVOKE ALL ON FUNCTION public.is_guide(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_guide(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_guide_helper(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_guide_helper(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.sync_guide_helper_on_membership() FROM PUBLIC, anon, authenticated;

-- Dnešné sprievodkyne. (Helperi mimo klubu z 10-add-helper.sh sa nemenia.)
DO $$ BEGIN
  PERFORM public.sync_guide_helper(user_id)
  FROM (SELECT DISTINCT user_id FROM public.memberships WHERE name = 'Sprievodkyňa klubu') x;
END $$;

-- 4. Horizont: celý mesiac dopredu (len ak ho admin medzitým nezmenil) -----------------------
UPDATE public.booking_settings SET horizon_days = 31 WHERE id AND horizon_days = 21;
