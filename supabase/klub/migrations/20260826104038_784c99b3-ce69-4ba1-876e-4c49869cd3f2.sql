REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM anon;
REVOKE EXECUTE ON FUNCTION public.inactive_members(integer) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.my_last_activity() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.group_authors() FROM anon;
REVOKE EXECUTE ON FUNCTION public.member_directory() FROM anon;