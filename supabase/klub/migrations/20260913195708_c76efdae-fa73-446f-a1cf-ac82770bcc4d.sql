GRANT EXECUTE ON FUNCTION public.member_directory() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.member_directory() FROM anon;