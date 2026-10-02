DROP FUNCTION IF EXISTS public.member_directory();

CREATE FUNCTION public.member_directory()
RETURNS TABLE(id uuid, full_name text, nickname text, avatar_url text, city text, region text, region_slug text, lat numeric, lng numeric, show_on_map boolean, joined_at timestamp with time zone, bio text, birth_year integer, goal text, founder_at timestamp with time zone)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  select p.id, p.full_name, p.nickname, p.avatar_url, p.city, p.region, p.region_slug,
         p.lat, p.lng, p.show_on_map, p.created_at as joined_at, p.bio,
         p.birth_year, p.goal, p.founder_at
  from public.profiles p
  where p.profile_completed_at is not null
$$;

REVOKE ALL ON FUNCTION public.member_directory() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.member_directory() TO authenticated, service_role;