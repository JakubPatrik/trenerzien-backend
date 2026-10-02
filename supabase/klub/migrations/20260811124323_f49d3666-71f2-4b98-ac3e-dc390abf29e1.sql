REVOKE ALL ON FUNCTION public.group_authors() FROM anon;
REVOKE ALL ON FUNCTION public.group_authors() FROM public;
GRANT EXECUTE ON FUNCTION public.group_authors() TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_authors() TO service_role;