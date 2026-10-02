revoke execute on function public.match_odm_knowledge(vector, integer) from public, anon;
grant execute on function public.match_odm_knowledge(vector, integer) to authenticated, service_role;