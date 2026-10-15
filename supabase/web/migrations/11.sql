-- Pripomienka konzultácie (edge function consultation-reminder)
--
-- Každý deň o 8:00 (Europe/Bratislava) pg_cron skontroluje consultation_sessions
-- a ak je na dnešok konzultácia, cez pg_net zavolá funkciu. Tá pošle e-mail každej
-- aktívnej členke klubu (consultation_reminder_recipients) a každý zapíše do
-- notification_emails (kind 'consultation_reminder', ref = id konzultácie).
-- Opakované spustenie preto nič nepošle dvakrát, len dopošle tie, ktoré zlyhali.
--
-- pg_cron beží v UTC: job ide o 6:00 aj 7:00 UTC a pokračuje len vtedy, keď je
-- v Bratislave 8 hodín (letný / zimný čas).
--
-- Vault (nastavuje 23-consultation-reminder.sh):
--   consultation_reminder_url     https://<ref>.supabase.co/functions/v1/consultation-reminder
--   consultation_reminder_secret  = secret CONSULTATION_REMINDER_SECRET funkcie
--
-- Spúšťaj cez 23-consultation-reminder.sh. Re-runnable.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 1. Odhlásenie z pripomienok (chýbajúci riadok = zapnuté, ako pri ostatných) -------------

ALTER TABLE public.notification_prefs
  ADD COLUMN IF NOT EXISTS email_consultations boolean NOT NULL DEFAULT true;

-- 2. Komu poslať ------------------------------------------------------------------------------

-- Aktívne členky s e-mailom, bez pozastaveného členstva a vypnutých pripomienok,
-- ktorým pripomienka k tejto konzultácii ešte úspešne neodišla.
CREATE OR REPLACE FUNCTION public.consultation_reminder_recipients(_session_id uuid)
RETURNS TABLE (user_id uuid, email text, name text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.id, p.email, coalesce(nullif(btrim(p.nickname), ''), nullif(btrim(p.full_name), ''))
  FROM public.profiles p
  WHERE nullif(btrim(p.email), '') IS NOT NULL
    AND p.membership_paused_at IS NULL
    AND public.is_club_member(p.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.notification_prefs np
      WHERE np.user_id = p.id AND NOT np.email_consultations
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.notification_emails ne
      WHERE ne.user_id = p.id AND ne.kind = 'consultation_reminder'
        AND ne.ref = _session_id::text AND ne.error IS NULL
    )
  ORDER BY p.id
$function$;

REVOKE ALL ON FUNCTION public.consultation_reminder_recipients(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consultation_reminder_recipients(uuid) TO service_role;

-- 3. Denný job --------------------------------------------------------------------------------

-- Vracia id pg_net požiadavky (odpoveď v net._http_response), NULL keď nie je čo poslať.
CREATE OR REPLACE FUNCTION public.consultation_reminder_tick()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  _local timestamp := now() AT TIME ZONE 'Europe/Bratislava';
  _url text;
  _secret text;
BEGIN
  IF extract(hour FROM _local) <> 8 THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.consultation_sessions s WHERE s.held_on = _local::date) THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO _url FROM vault.decrypted_secrets WHERE name = 'consultation_reminder_url';
  SELECT decrypted_secret INTO _secret FROM vault.decrypted_secrets WHERE name = 'consultation_reminder_secret';
  IF _url IS NULL OR _secret IS NULL THEN
    RAISE EXCEPTION 'consultation_reminder_tick: vault secrets consultation_reminder_url / _secret missing';
  END IF;

  RETURN net.http_post(
    url := _url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || _secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 300000
  );
END
$function$;

REVOKE ALL ON FUNCTION public.consultation_reminder_tick() FROM PUBLIC, anon, authenticated;

-- Rovnaký názov = prepíše existujúci job.
SELECT cron.schedule('consultation-reminder', '0 6,7 * * *', 'SELECT public.consultation_reminder_tick()');
