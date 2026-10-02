REVOKE EXECUTE ON FUNCTION public.group_authors() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_authors() TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.member_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_directory() TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.inactive_members(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.my_last_activity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;