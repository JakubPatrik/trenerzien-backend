-- Pridanie / odobratie personalistky podľa e-mailu cez RPC (to, čo robí 18-recruiter.sh)
--
--   add_recruiter(p_email)       rola 'personalistka' pre existujúci účet (aj e-mail
--                                z auth.identities, find_auth_user_id_by_email()).
--                                Trigger zo 6.sql vytvorí / aktivuje riadok v helpers.
--                                Už je personalistka → nič, vráti ten istý výsledok.
--   remove_recruiter(p_email)    rolu odoberie, helper → active = false
--
-- Volá len admin (has_role 'admin'), inak 'forbidden'. Neexistujúci účet →
-- 'user_not_found' (účty vznikajú cez Stripe / pozvánku v KLUBe, nie tu).
-- Vracia jsonb { user_id, email, full_name, is_recruiter, helper_active }.
--
--   supabase.rpc('add_recruiter', { p_email: 'jana@example.sk' })
--
-- Spúšťa sa po 6.sql (20-apply-recruiter-rpc.sh). Re-runnable.

CREATE OR REPLACE FUNCTION public.set_recruiter(p_email text, p_recruiter boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid;
  v_result jsonb;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_user_id := public.find_auth_user_id_by_email(p_email);
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'user_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_recruiter THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (v_user_id, 'personalistka')
    ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    DELETE FROM public.user_roles WHERE user_id = v_user_id AND role::text = 'personalistka';
  END IF;

  SELECT jsonb_build_object(
           'user_id', u.id,
           'email', u.email,
           'full_name', p.full_name,
           'is_recruiter', public.is_recruiter(u.id),
           'helper_active', h.active)
  INTO v_result
  FROM auth.users u
  LEFT JOIN public.profiles p ON p.id = u.id
  LEFT JOIN public.helpers h ON h.user_id = u.id
  WHERE u.id = v_user_id;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_recruiter(p_email text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$ SELECT public.set_recruiter(p_email, true) $$;

CREATE OR REPLACE FUNCTION public.remove_recruiter(p_email text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$ SELECT public.set_recruiter(p_email, false) $$;

REVOKE ALL ON FUNCTION public.set_recruiter(text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.add_recruiter(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_recruiter(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_recruiter(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_recruiter(text) TO authenticated;
