-- Overený e-mail členky KLUBu (klik na pozvánku → /nove-heslo)
--
-- Pozvánka ide e-mailom; /nove-heslo po uložení hesla nastaví
-- profiles.invitation = 'accepted'. To dokazuje, že e-mail je skutočný a jej, rovnako
-- ako klik na odkaz pri rezervácii (consultation_applications.email_verified_at, 12.sql).
--
--   profiles.email_verified_at   prvé 'accepted'; potom sa už nemení
--   trigger set_email_verified_at   nastaví ho databáza, členka ho sama zmeniť nemôže
--                                   (admin a service role áno)
--   backfill                     už prijaté pozvánky: čas presne nepoznáme, berie sa
--                                invited_at (overila sa najskôr vtedy), inak updated_at
--
-- SmartEmailing sa nemení: kontakt ide na zoznam členstva už pri platbe (Stripe / FAPI).
-- Frontend sa nemení. Re-runnable.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email_verified_at timestamp with time zone;

CREATE OR REPLACE FUNCTION public.set_email_verified_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND auth.uid() IS NOT NULL AND NOT public.has_role(auth.uid(), 'admin'::public.app_role) THEN
    NEW.email_verified_at := OLD.email_verified_at;  -- members can't set it themselves
  END IF;
  IF NEW.invitation = 'accepted' AND NEW.email_verified_at IS NULL
     AND (TG_OP = 'INSERT' OR OLD.invitation IS DISTINCT FROM 'accepted') THEN
    NEW.email_verified_at := now();
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_email_verified_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS set_email_verified_at ON public.profiles;
CREATE TRIGGER set_email_verified_at BEFORE INSERT OR UPDATE OF invitation, email_verified_at ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.set_email_verified_at();

UPDATE public.profiles
   SET email_verified_at = coalesce(invited_at, updated_at, now())
 WHERE invitation = 'accepted' AND email_verified_at IS NULL;
