-- Double opt-in pred pozvánkou na pohovor (BOOKING_OPT_IN.md)
--
-- Termín sa najprv len podrží ('pending_opt_in', 2 h). Pozvánka (Google udalosť,
-- e-maily) odíde až keď leadka klikne na odkaz v e-maile → confirm-meeting.
--
--   appointments.status 'pending_opt_in'   termín držaný, čaká sa na klik v e-maile
--   appointments.opt_in_*                  token z odkazu, koniec držania, odoslanie e-mailu
--   appointments.pending_at                kedy sa potvrdenie začalo (claim); 10-min pravidlo
--                                          pre zaseknuté 'pending' ide odtiaľto, nie z created_at
--   appointments.nudge_sent_at             upozornenie pre pohovory@ (meeting-nudge) odišlo
--   consultation_applications.email_verified_at   prvý klik na odkaz
--   booking_settings.opt_in_hold_minutes   dĺžka držania (default 120)
--
--   hold_appointment()       ako book_appointment(), ale 'pending_opt_in' + token
--   claim_opt_in(token)      klik na odkaz: claimed / processing / confirmed / expired / not_found
--   release_claim(id)        Google zlyhal → späť na 'pending_opt_in', odkaz funguje ďalej
--   reissue_opt_in(id, e-mail?)   podpora: nový odkaz (+ oprava e-mailu), držanie znova 2 h
--   expired_opt_in_holds()   uvoľní prepadnuté držania, vráti tie, ktorým treba poslať nudge
--   release_stale_holds()    spoločné upratovanie (volajú ho funkcie vyššie)
--
-- RLS: personalistka nevidí nepotvrdené termíny ('pending_opt_in' ani prepadnuté) ani
-- ich dotazník. Admin vidí všetko.
--
-- Nahrádza booking_slots() z 5.sql a book_appointment() zo 4.sql — po opätovnom
-- spustení 4.sql / 5.sql treba spustiť aj 12.sql (08-apply-booking.sh to robí).
-- Re-runnable.

-- 1. Stĺpce ----------------------------------------------------------------------------------

ALTER TABLE public.consultation_applications
  ADD COLUMN IF NOT EXISTS email_verified_at timestamp with time zone;

ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS opt_in_token text,
  ADD COLUMN IF NOT EXISTS opt_in_expires_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS opt_in_email_sent_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS nudge_sent_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS pending_at timestamp with time zone;

CREATE UNIQUE INDEX IF NOT EXISTS appointments_opt_in_token_key
  ON public.appointments (opt_in_token) WHERE opt_in_token IS NOT NULL;

ALTER TABLE public.booking_settings
  ADD COLUMN IF NOT EXISTS opt_in_hold_minutes integer NOT NULL DEFAULT 120
    CHECK (opt_in_hold_minutes BETWEEN 15 AND 1440);
GRANT UPDATE (opt_in_hold_minutes) ON public.booking_settings TO authenticated;

-- 2. Stavy a constrainty -----------------------------------------------------------------------

ALTER TABLE public.appointments DROP CONSTRAINT IF EXISTS appointments_status_check;
ALTER TABLE public.appointments ADD CONSTRAINT appointments_status_check CHECK (status IN (
  'pending_opt_in', -- termín držaný, čaká sa na klik v e-maile (max. opt_in_hold_minutes)
  'pending',        -- slot držaný, Google udalosť sa vytvára (max. 10 min od pending_at / created_at)
  'confirmed',      -- udalosť + Meet link existujú
  'cancelled',
  'completed',      -- nastavuje helper po pohovore
  'no_show'         -- nastavuje helper po pohovore
));

ALTER TABLE public.appointments DROP CONSTRAINT IF EXISTS appointments_opt_in_fields;
ALTER TABLE public.appointments ADD CONSTRAINT appointments_opt_in_fields
  CHECK (status <> 'pending_opt_in' OR (opt_in_token IS NOT NULL AND opt_in_expires_at IS NOT NULL));

-- Držaný termín blokuje slot rovnako ako potvrdený.
ALTER TABLE public.appointments DROP CONSTRAINT IF EXISTS appointments_no_overlap;
ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_no_overlap
  EXCLUDE USING gist (helper_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
  WHERE (status IN ('pending_opt_in', 'pending', 'confirmed'));

-- 3. Upratovanie -----------------------------------------------------------------------------

-- Volá sa pod zámkom rezervácie aj z cronu. booking_slots() rovnaké pravidlá len
-- filtruje (je STABLE), takže voľné sloty sedia aj medzi behmi.
CREATE OR REPLACE FUNCTION public.release_stale_holds()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  -- Prepadnuté držanie (aj potvrdenie, ktoré sa zaseklo až po konci držania).
  UPDATE public.appointments
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'opt_in_expired', pending_at = NULL
   WHERE opt_in_token IS NOT NULL AND opt_in_expires_at <= now()
     AND (status = 'pending_opt_in' OR (status = 'pending' AND pending_at <= now() - interval '10 minutes'));

  -- Zaseknuté potvrdenie počas platného držania → späť na držanie, odkaz funguje znova.
  UPDATE public.appointments
     SET status = 'pending_opt_in', pending_at = NULL
   WHERE status = 'pending' AND opt_in_token IS NOT NULL AND opt_in_expires_at > now()
     AND pending_at <= now() - interval '10 minutes';

  -- Opustené 'pending' bez opt-inu (edge function spadla) uvoľnia slot aj prihlášku.
  UPDATE public.appointments
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'expired'
   WHERE status = 'pending' AND opt_in_token IS NULL
     AND coalesce(pending_at, created_at) <= now() - interval '10 minutes';
$function$;

-- 4. Voľné sloty (5.sql + držané termíny) ------------------------------------------------------

CREATE OR REPLACE FUNCTION public.booking_slots(
  p_from timestamp with time zone DEFAULT now(),
  p_to timestamp with time zone DEFAULT NULL::timestamp with time zone
)
RETURNS TABLE(starts_at timestamp with time zone, ends_at timestamp with time zone, helper_id uuid, helper_name text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
        AND (ap.status = 'confirmed'
             OR (ap.status = 'pending_opt_in' AND ap.opt_in_expires_at > now())
             OR (ap.status = 'pending' AND (coalesce(ap.pending_at, ap.created_at) > now() - interval '10 minutes'
                                            OR ap.opt_in_expires_at > now())))
        AND tstzrange(ap.starts_at - s.buffer, ap.ends_at + s.buffer, '[)') && tstzrange(c.starts_at, c.ends_at, '[)')
    )
  ORDER BY c.starts_at, c.sort_order, c.helper_name
$function$;

-- 5. Rezervácia ------------------------------------------------------------------------------

-- Spoločné jadro book_appointment() / hold_appointment(). Volá iba edge function
-- book-meeting (service_role).
CREATE OR REPLACE FUNCTION public.reserve_appointment(
  p_token text,
  p_starts_at timestamp with time zone,
  p_helper_id uuid,
  p_opt_in boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_app public.consultation_applications%ROWTYPE;
  v_candidate record;
  v_hold integer;
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

  -- Prepadnuté držania a opustené 'pending' uvoľnia slot aj prihlášku.
  PERFORM public.release_stale_holds();

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
    WHERE ap.helper_id = sl.helper_id AND ap.status IN ('pending_opt_in', 'pending', 'confirmed')
      AND ap.starts_at > now() - interval '7 days' AND ap.starts_at < now() + interval '14 days'
  ), random()
  LIMIT 1;

  IF FOUND THEN
    SELECT opt_in_hold_minutes INTO v_hold FROM public.booking_settings WHERE id;
    BEGIN
      IF p_opt_in THEN
        INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status, opt_in_token, opt_in_expires_at)
        VALUES (v_app.id, v_candidate.helper_id, p_starts_at, v_candidate.ends_at, 'pending_opt_in',
                encode(extensions.gen_random_bytes(32), 'hex'), now() + make_interval(mins => coalesce(v_hold, 120)))
        RETURNING id INTO v_id;
      ELSE
        INSERT INTO public.appointments (application_id, helper_id, starts_at, ends_at, status)
        VALUES (v_app.id, v_candidate.helper_id, p_starts_at, v_candidate.ends_at, 'pending')
        RETURNING id INTO v_id;
      END IF;
      RETURN v_id;
    EXCEPTION WHEN exclusion_violation OR unique_violation THEN
      NULL;  -- poistka (zápis mimo tejto funkcie); padne na slot_unavailable
    END;
  END IF;

  RAISE EXCEPTION 'slot_unavailable';
END;
$function$;

-- Priama rezervácia ('pending' → book-meeting hneď vytvorí udalosť). Rovnaká signatúra ako v 4.sql.
CREATE OR REPLACE FUNCTION public.book_appointment(
  p_token text,
  p_starts_at timestamp with time zone,
  p_helper_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.reserve_appointment(p_token, p_starts_at, p_helper_id, false)
$function$;

-- Double opt-in: termín sa len podrží, pozvánka až po kliku v e-maile.
CREATE OR REPLACE FUNCTION public.hold_appointment(
  p_token text,
  p_starts_at timestamp with time zone,
  p_helper_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.reserve_appointment(p_token, p_starts_at, p_helper_id, true)
$function$;

-- 6. Klik na odkaz ---------------------------------------------------------------------------

-- outcome:
--   claimed     držanie platí → 'pending'; volajúci vytvorí udalosť a potvrdí (alebo release_claim)
--   processing  iné volanie práve potvrdzuje (dvojklik, skener pošty)
--   confirmed   už potvrdené (idempotentné)
--   expired     držanie prepadlo; rebook_token = token prihlášky na novú rezerváciu
--   not_found   neznámy token, alebo termín zrušený inak (cancel-meeting, chyba kalendára)
CREATE OR REPLACE FUNCTION public.claim_opt_in(p_token text)
RETURNS TABLE (outcome text, appointment_id uuid, rebook_token text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  a public.appointments%ROWTYPE;
  v_app_token text;
BEGIN
  SELECT * INTO a FROM public.appointments ap WHERE ap.opt_in_token = p_token FOR UPDATE;
  IF NOT FOUND OR (a.status = 'cancelled' AND a.cancel_reason IS DISTINCT FROM 'opt_in_expired') THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  -- Odkaz z e-mailu funguje → e-mail je skutočný, aj keď držanie prepadlo.
  UPDATE public.consultation_applications
     SET email_verified_at = coalesce(email_verified_at, now())
   WHERE id = a.application_id
  RETURNING token INTO v_app_token;

  IF a.status IN ('confirmed', 'completed', 'no_show') THEN
    RETURN QUERY SELECT 'confirmed'::text, a.id, NULL::text;
    RETURN;
  END IF;

  IF a.status = 'pending' AND a.pending_at > now() - interval '10 minutes' THEN
    RETURN QUERY SELECT 'processing'::text, a.id, NULL::text;
    RETURN;
  END IF;

  IF a.status = 'cancelled' OR a.opt_in_expires_at <= now() THEN
    UPDATE public.appointments
       SET status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
           cancel_reason = 'opt_in_expired', pending_at = NULL
     WHERE id = a.id AND status <> 'cancelled';
    RETURN QUERY SELECT 'expired'::text, a.id, v_app_token;
    RETURN;
  END IF;

  -- 'pending_opt_in', alebo zaseknuté potvrdenie (> 10 min) počas platného držania.
  UPDATE public.appointments SET status = 'pending', pending_at = now() WHERE id = a.id;
  RETURN QUERY SELECT 'claimed'::text, a.id, NULL::text;
END;
$function$;

-- Potvrdenie zlyhalo (Google / DB) → späť na držanie; odkaz funguje až do konca držania.
CREATE OR REPLACE FUNCTION public.release_claim(p_appointment_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  UPDATE public.appointments
     SET status = 'pending_opt_in', pending_at = NULL
   WHERE id = p_appointment_id AND status = 'pending' AND opt_in_token IS NOT NULL;
$function$;

-- 7. Podpora: nový odkaz ---------------------------------------------------------------------

-- Len pre platné držanie. Nový token (starý odkaz prestane fungovať), držanie znova
-- opt_in_hold_minutes od teraz, voliteľne opravený e-mail prihlášky.
-- Chyby: not_found, expired, not_pending, invalid_email.
CREATE OR REPLACE FUNCTION public.reissue_opt_in(p_appointment_id uuid, p_email text DEFAULT NULL)
RETURNS TABLE (opt_in_token text, opt_in_expires_at timestamp with time zone, email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  a public.appointments%ROWTYPE;
  v_email text := lower(btrim(p_email));
  v_hold integer;
BEGIN
  PERFORM public.release_stale_holds();

  SELECT * INTO a FROM public.appointments ap WHERE ap.id = p_appointment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
  IF a.status = 'cancelled' AND a.cancel_reason = 'opt_in_expired' THEN
    RAISE EXCEPTION 'expired';
  END IF;
  IF a.status <> 'pending_opt_in' THEN
    RAISE EXCEPTION 'not_pending';
  END IF;

  IF v_email IS NOT NULL THEN
    IF v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 255 THEN
      RAISE EXCEPTION 'invalid_email';
    END IF;
    UPDATE public.consultation_applications SET email = v_email, email_verified_at = NULL WHERE id = a.application_id;
  END IF;

  SELECT opt_in_hold_minutes INTO v_hold FROM public.booking_settings WHERE id;
  UPDATE public.appointments
     SET opt_in_token = encode(extensions.gen_random_bytes(32), 'hex'),
         opt_in_expires_at = now() + make_interval(mins => coalesce(v_hold, 120)),
         opt_in_email_sent_at = NULL, nudge_sent_at = NULL, email_error = NULL
   WHERE id = a.id;

  RETURN QUERY
  SELECT ap.opt_in_token, ap.opt_in_expires_at, c.email
  FROM public.appointments ap JOIN public.consultation_applications c ON c.id = ap.application_id
  WHERE ap.id = a.id;
END;
$function$;

-- 8. Cron: komu poslať meeting-nudge ---------------------------------------------------------

-- Uvoľní prepadnuté držania a vráti tie, ktorým ešte neodišiel nudge (max. deň staré,
-- a len keď leadka medzitým nemá iný aktívny termín). Odoslanie zapisuje
-- booking-holds do appointments.nudge_sent_at.
CREATE OR REPLACE FUNCTION public.expired_opt_in_holds()
RETURNS TABLE (
  appointment_id uuid,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  opt_in_expires_at timestamp with time zone,
  helper_name text,
  lead_name text,
  lead_email text,
  lead_phone text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.release_stale_holds();

  RETURN QUERY
  SELECT a.id, a.starts_at, a.ends_at, a.opt_in_expires_at, h.name, c.name, c.email, c.phone
  FROM public.appointments a
  JOIN public.helpers h ON h.id = a.helper_id
  JOIN public.consultation_applications c ON c.id = a.application_id
  WHERE a.status = 'cancelled' AND a.cancel_reason = 'opt_in_expired'
    AND a.nudge_sent_at IS NULL
    AND a.opt_in_expires_at > now() - interval '1 day'
    AND NOT EXISTS (
      SELECT 1 FROM public.appointments o
      WHERE o.application_id = a.application_id AND o.status <> 'cancelled'
    )
  ORDER BY a.opt_in_expires_at;
END;
$function$;

-- 9. RLS: personalistka nevidí nepotvrdené termíny ------------------------------------------------

DROP POLICY IF EXISTS "Helpers read own appointments" ON public.appointments;
CREATE POLICY "Helpers read own appointments" ON public.appointments
  FOR SELECT TO authenticated
  USING (public.is_helper(helper_id) AND status <> 'pending_opt_in'
         AND cancel_reason IS DISTINCT FROM 'opt_in_expired');

DROP POLICY IF EXISTS "Helpers read applications of their appointments" ON public.consultation_applications;
CREATE POLICY "Helpers read applications of their appointments" ON public.consultation_applications
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.appointments ap
    WHERE ap.application_id = consultation_applications.id
      AND ap.status NOT IN ('cancelled', 'pending_opt_in')
      AND public.is_helper(ap.helper_id)
  ));

-- 10. Práva ----------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.release_stale_holds() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reserve_appointment(text, timestamp with time zone, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.book_appointment(text, timestamp with time zone, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hold_appointment(text, timestamp with time zone, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_opt_in(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_claim(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reissue_opt_in(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.expired_opt_in_holds() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.release_stale_holds() TO service_role;
GRANT EXECUTE ON FUNCTION public.reserve_appointment(text, timestamp with time zone, uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.book_appointment(text, timestamp with time zone, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.hold_appointment(text, timestamp with time zone, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_opt_in(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_claim(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.reissue_opt_in(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.expired_opt_in_holds() TO service_role;
GRANT EXECUTE ON FUNCTION public.booking_slots(timestamp with time zone, timestamp with time zone) TO anon, authenticated, service_role;
