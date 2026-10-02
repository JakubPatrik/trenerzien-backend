REVOKE EXECUTE ON FUNCTION public.member_directory() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.member_directory() TO authenticated, service_role;