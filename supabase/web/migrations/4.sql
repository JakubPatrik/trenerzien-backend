-- Rezervácia pohovoru (krok 2 po dotazníku consultation_applications)
--
--   helpers               kto vedie pohovory (voliteľne prepojený na auth.users)
--   helper_availability   týždenné okná dostupnosti (ISO deň: 1 = pondelok … 7 = nedeľa)
--   helper_time_off       výnimky — dovolenka, voľno (blokuje sloty)
--   booking_settings      dĺžka pohovoru, krok slotov, min. predstih, horizont
--   appointments          rezervácie; dvojitú rezerváciu blokuje EXCLUDE constraint
--
--   booking_slots()       voľné termíny (verejné RPC, anon)
--   book_appointment()    atomická rezervácia (iba service_role → edge function book-meeting)
--
-- Re-runnable: IF NOT EXISTS / CREATE OR REPLACE / DROP … IF EXISTS.

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- 1. Tabuľky -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.helpers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    name text NOT NULL,
    email text NOT NULL,               -- dostane pozvánku do Google kalendára
    active boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS helpers_email_key ON public.helpers (lower(email));

CREATE TABLE IF NOT EXISTS public.helper_availability (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    helper_id uuid NOT NULL REFERENCES public.helpers(id) ON DELETE CASCADE,
    day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
    start_time time NOT NULL,
    end_time time NOT NULL,
    timezone text NOT NULL DEFAULT 'Europe/Bratislava',
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
CREATE INDEX IF NOT EXISTS helper_availability_helper_idx ON public.helper_availability (helper_id, day_of_week);

CREATE TABLE IF NOT EXISTS public.helper_time_off (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    helper_id uuid NOT NULL REFERENCES public.helpers(id) ON DELETE CASCADE,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    note text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at)
);
CREATE INDEX IF NOT EXISTS helper_time_off_helper_idx ON public.helper_time_off (helper_id, ends_at);

-- Jediný riadok (id = true).
CREATE TABLE IF NOT EXISTS public.booking_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    slot_minutes integer NOT NULL DEFAULT 60 CHECK (slot_minutes BETWEEN 15 AND 240),
    slot_step_minutes integer NOT NULL DEFAULT 60 CHECK (slot_step_minutes BETWEEN 5 AND 240),
    buffer_minutes integer NOT NULL DEFAULT 0 CHECK (buffer_minutes BETWEEN 0 AND 120),   -- pauza medzi pohovormi
    min_notice_minutes integer NOT NULL DEFAULT 1440 CHECK (min_notice_minutes >= 0),     -- najskôr o 24 h
    horizon_days integer NOT NULL DEFAULT 21 CHECK (horizon_days BETWEEN 1 AND 90),       -- najneskôr o 21 dní
    timezone text NOT NULL DEFAULT 'Europe/Bratislava',                                    -- pre e-maily / kalendár
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);
INSERT INTO public.booking_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.appointments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id uuid NOT NULL REFERENCES public.consultation_applications(id) ON DELETE CASCADE,
    helper_id uuid NOT NULL REFERENCES public.helpers(id) ON DELETE RESTRICT,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN (
        'pending',    -- slot držaný, Google udalosť sa vytvára (max. 10 min, potom expiruje)
        'confirmed',  -- udalosť + Meet link existujú
        'cancelled',
        'completed',  -- nastavuje helper po pohovore
        'no_show'     -- nastavuje helper po pohovore
    )),
    google_event_id text,
    meet_link text,
    helper_note text,
    confirmation_email_sent_at timestamp with time zone,
    email_error text,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at)
);

-- Žiadny helper nemá dva prekrývajúce sa aktívne pohovory — vynútené databázou.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'appointments_no_overlap') THEN
    ALTER TABLE public.appointments
      ADD CONSTRAINT appointments_no_overlap
      EXCLUDE USING gist (helper_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
      WHERE (status IN ('pending', 'confirmed'));
  END IF;
END $$;

-- Jedna prihláška = najviac jeden (nezrušený) pohovor.
CREATE UNIQUE INDEX IF NOT EXISTS appointments_one_per_application
  ON public.appointments (application_id) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS appointments_helper_time_idx ON public.appointments (helper_id, starts_at);

-- 2. Triggery ------------------------------------------------------------------
-- (public.update_updated_at_column() je definovaná v 0.sql)

DROP TRIGGER IF EXISTS update_helpers_updated_at ON public.helpers;
CREATE TRIGGER update_helpers_updated_at BEFORE UPDATE ON public.helpers
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_appointments_updated_at ON public.appointments;
CREATE TRIGGER update_appointments_updated_at BEFORE UPDATE ON public.appointments
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_booking_settings_updated_at ON public.booking_settings;
CREATE TRIGGER update_booking_settings_updated_at BEFORE UPDATE ON public.booking_settings
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Neplatná časová zóna by rozbila booking_slots() pre všetkých — odmietni ju hneď.
CREATE OR REPLACE FUNCTION public.validate_timezone()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM now() AT TIME ZONE NEW.timezone;
  RETURN NEW;
EXCEPTION WHEN invalid_parameter_value THEN
  RAISE EXCEPTION 'invalid timezone: %', NEW.timezone USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS validate_helper_availability_timezone ON public.helper_availability;
CREATE TRIGGER validate_helper_availability_timezone BEFORE INSERT OR UPDATE OF timezone ON public.helper_availability
FOR EACH ROW EXECUTE FUNCTION public.validate_timezone();

DROP TRIGGER IF EXISTS validate_booking_settings_timezone ON public.booking_settings;
CREATE TRIGGER validate_booking_settings_timezone BEFORE INSERT OR UPDATE OF timezone ON public.booking_settings
FOR EACH ROW EXECUTE FUNCTION public.validate_timezone();

-- 3. Pomocná funkcia pre RLS ------------------------------------------------------
-- SECURITY DEFINER: číta helpers bez RLS, aby politiky na iných tabuľkách
-- nespôsobovali rekurziu.
CREATE OR REPLACE FUNCTION public.is_helper(_helper_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.helpers WHERE id = _helper_id AND user_id = auth.uid())
$$;

-- 4. Voľné termíny -------------------------------------------------------------------
-- Sloty sa generujú v lokálnom čase helpera (správne cez letný/zimný čas),
-- ohraničené min. predstihom a horizontom z booking_settings. Vynechá sloty
-- prekryté voľnom alebo aktívnym pohovorom (+ buffer). 'pending' starší ako
-- 10 min sa ignoruje (edge function spadla počas vytvárania udalosti).
-- Vracia jeden riadok na (termín, helper) — frontend zoskupí podľa času.
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
      AND extract(isodow FROM d) = a.day_of_week
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

-- 5. Rezervácia ---------------------------------------------------------------------------
-- Volá iba edge function book-meeting (service_role). Vytvorí 'pending'
-- rezerváciu; edge function ju po vytvorení Google udalosti potvrdí.
-- Chyby (message → HTTP v edge function):
--   application_not_found, not_qualified, already_booked, slot_unavailable
CREATE OR REPLACE FUNCTION public.book_appointment(
    p_token text,
    p_starts_at timestamp with time zone,
    p_helper_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_app public.consultation_applications%ROWTYPE;
  v_candidate record;
  v_id uuid;
BEGIN
  -- Rezervácie idú prísne za sebou (jeden transakčný zámok pre celé
  -- rezervovanie). Pri pár rezerváciách denne je to zanedbateľné a výber
  -- slotu nižšie tak nemôže súbežne vybrať ten istý slot ani sa zaseknúť
  -- (deadlock) pri "ktokoľvek" — EXCLUDE constraint ostáva ako poistka.
  PERFORM pg_advisory_xact_lock(hashtextextended('public.book_appointment', 0));

  SELECT * INTO v_app FROM public.consultation_applications WHERE token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found';
  END IF;
  IF NOT v_app.qualified THEN
    RAISE EXCEPTION 'not_qualified';
  END IF;

  -- Opustené 'pending' (edge function spadla) uvoľnia slot aj prihlášku.
  UPDATE public.appointments
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'expired'
   WHERE status = 'pending' AND created_at <= now() - interval '10 minutes';

  IF EXISTS (SELECT 1 FROM public.appointments WHERE application_id = v_app.id AND status <> 'cancelled') THEN
    RAISE EXCEPTION 'already_booked';
  END IF;

  -- booking_slots() overí mriežku, dostupnosť, voľno, buffer, predstih aj
  -- horizont. Konkrétny helper, alebo pri "ktokoľvek" najmenej vyťažený.
  SELECT sl.helper_id, sl.ends_at INTO v_candidate
  FROM public.booking_slots(p_starts_at, p_starts_at) sl
  WHERE sl.starts_at = p_starts_at
    AND (p_helper_id IS NULL OR sl.helper_id = p_helper_id)
  ORDER BY (
    SELECT count(*) FROM public.appointments ap
    WHERE ap.helper_id = sl.helper_id AND ap.status IN ('pending', 'confirmed')
      AND ap.starts_at > now() - interval '7 days' AND ap.starts_at < now() + interval '14 days'
  ), random()
  LIMIT 1;

  IF FOUND THEN
    BEGIN
      INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status)
      VALUES (v_app.id, v_candidate.helper_id, p_starts_at, v_candidate.ends_at, 'pending')
      RETURNING id INTO v_id;
      RETURN v_id;
    EXCEPTION WHEN exclusion_violation OR unique_violation THEN
      NULL;  -- poistka (zápis mimo tejto funkcie); padne na slot_unavailable
    END;
  END IF;

  RAISE EXCEPTION 'slot_unavailable';
END;
$$;

-- 6. Prístupové práva ----------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE ON public.helpers, public.helper_availability, public.helper_time_off TO authenticated;
GRANT SELECT ON public.booking_settings TO anon, authenticated;
GRANT UPDATE (slot_minutes, slot_step_minutes, buffer_minutes, min_notice_minutes, horizon_days, timezone)
  ON public.booking_settings TO authenticated;
GRANT SELECT ON public.appointments TO authenticated;
-- Klienti menia iba stav po pohovore a poznámku; rušenie ide cez edge function
-- cancel-meeting (zmaže aj Google udalosť).
GRANT UPDATE (status, helper_note) ON public.appointments TO authenticated;
GRANT ALL ON public.helpers, public.helper_availability, public.helper_time_off,
             public.booking_settings, public.appointments TO service_role;

REVOKE ALL ON FUNCTION public.book_appointment(text, timestamp with time zone, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.book_appointment(text, timestamp with time zone, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.booking_slots(timestamp with time zone, timestamp with time zone) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_helper(uuid) TO authenticated, service_role;

ALTER TABLE public.helpers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.helper_availability ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.helper_time_off ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments ENABLE ROW LEVEL SECURITY;

-- 7. RLS politiky -------------------------------------------------------------------------------
-- Verejnosť (anon) nevidí žiadnu tabuľku priamo — voľné termíny a mená
-- helperov idú cez booking_slots().

-- helpers: admin všetko, helper číta svoj riadok
DROP POLICY IF EXISTS "Admins manage helpers" ON public.helpers;
CREATE POLICY "Admins manage helpers" ON public.helpers
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role))
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Helpers read own row" ON public.helpers;
CREATE POLICY "Helpers read own row" ON public.helpers
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- helper_availability / helper_time_off: helper spravuje svoje (helpers.user_id = auth.uid()), admin všetko
DROP POLICY IF EXISTS "Helpers manage own availability" ON public.helper_availability;
CREATE POLICY "Helpers manage own availability" ON public.helper_availability
FOR ALL TO authenticated
USING (public.is_helper(helper_id))
WITH CHECK (public.is_helper(helper_id));

DROP POLICY IF EXISTS "Admins manage availability" ON public.helper_availability;
CREATE POLICY "Admins manage availability" ON public.helper_availability
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role))
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Helpers manage own time off" ON public.helper_time_off;
CREATE POLICY "Helpers manage own time off" ON public.helper_time_off
FOR ALL TO authenticated
USING (public.is_helper(helper_id))
WITH CHECK (public.is_helper(helper_id));

DROP POLICY IF EXISTS "Admins manage time off" ON public.helper_time_off;
CREATE POLICY "Admins manage time off" ON public.helper_time_off
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role))
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

-- booking_settings: čítať môže každý, meniť admin
DROP POLICY IF EXISTS "Anyone reads booking settings" ON public.booking_settings;
CREATE POLICY "Anyone reads booking settings" ON public.booking_settings
FOR SELECT TO anon, authenticated
USING (true);

DROP POLICY IF EXISTS "Admins update booking settings" ON public.booking_settings;
CREATE POLICY "Admins update booking settings" ON public.booking_settings
FOR UPDATE TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role))
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

-- appointments: admin a helper (svoje) čítajú; po pohovore nastavia
-- completed / no_show (alebo vrátia na confirmed). Vkladanie len cez book_appointment().
DROP POLICY IF EXISTS "Admins read appointments" ON public.appointments;
CREATE POLICY "Admins read appointments" ON public.appointments
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Helpers read own appointments" ON public.appointments;
CREATE POLICY "Helpers read own appointments" ON public.appointments
FOR SELECT TO authenticated
USING (public.is_helper(helper_id));

DROP POLICY IF EXISTS "Admins and helpers set outcome" ON public.appointments;
CREATE POLICY "Admins and helpers set outcome" ON public.appointments
FOR UPDATE TO authenticated
USING (
  status IN ('confirmed', 'completed', 'no_show')
  AND (public.is_helper(helper_id) OR public.has_role(auth.uid(), 'admin'::app_role))
)
WITH CHECK (
  status IN ('confirmed', 'completed', 'no_show')
  AND (public.is_helper(helper_id) OR public.has_role(auth.uid(), 'admin'::app_role))
);

-- consultation_applications: helper vidí dotazník leadov, s ktorými má pohovor
-- (na prípravu rozhovoru).
DROP POLICY IF EXISTS "Helpers read applications of their appointments" ON public.consultation_applications;
CREATE POLICY "Helpers read applications of their appointments" ON public.consultation_applications
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.appointments ap
  WHERE ap.application_id = consultation_applications.id
    AND ap.status <> 'cancelled'
    AND public.is_helper(ap.helper_id)
));
