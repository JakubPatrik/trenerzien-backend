-- Double opt-in: cron pre prepadnuté držania (edge function booking-holds)
--
-- Každých 5 min uvoľní prepadnuté držania (expired_opt_in_holds() z 12.sql) a ak
-- treba niekomu poslať meeting-nudge, cez pg_net zavolá booking-holds. Bez práce
-- sa funkcia nevolá.
--
-- Vault (nastavuje 24-booking-opt-in.sh):
--   booking_holds_url     https://<ref>.supabase.co/functions/v1/booking-holds
--   booking_holds_secret  = secret BOOKING_HOLDS_SECRET funkcie
--
-- Potrebuje 12.sql. Spúšťaj cez 24-booking-opt-in.sh. Re-runnable.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- Vracia id pg_net požiadavky (odpoveď v net._http_response), NULL keď nie je čo poslať.
CREATE OR REPLACE FUNCTION public.booking_holds_tick()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  _url text;
  _secret text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.expired_opt_in_holds()) THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO _url FROM vault.decrypted_secrets WHERE name = 'booking_holds_url';
  SELECT decrypted_secret INTO _secret FROM vault.decrypted_secrets WHERE name = 'booking_holds_secret';
  IF _url IS NULL OR _secret IS NULL THEN
    RAISE EXCEPTION 'booking_holds_tick: vault secrets booking_holds_url / _secret missing';
  END IF;

  RETURN net.http_post(
    url := _url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || _secret),
    body := '{"action":"tick"}'::jsonb,
    timeout_milliseconds := 60000
  );
END
$function$;

REVOKE ALL ON FUNCTION public.booking_holds_tick() FROM PUBLIC, anon, authenticated;

-- Rovnaký názov = prepíše existujúci job.
SELECT cron.schedule('booking-holds', '*/5 * * * *', 'SELECT public.booking_holds_tick()');
