-- Nájdenie existujúceho účtu podľa e-mailu pre stripe-webhook (findOrCreateUser)
--
--   find_auth_user_id_by_email()   hľadá v auth.users.email aj v auth.identities
--                                  (po zmene e-mailu môže identita ostať na starej
--                                  adrese a GoTrue potom createUser odmietne
--                                  „already been registered“). Admin API listUsers
--                                  identity nevracia, preto SQL.
--
-- Len pre service_role. Re-runnable.

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
