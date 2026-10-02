REVOKE EXECUTE ON FUNCTION public.is_pair_member(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_pair_member(uuid, uuid) TO authenticated;