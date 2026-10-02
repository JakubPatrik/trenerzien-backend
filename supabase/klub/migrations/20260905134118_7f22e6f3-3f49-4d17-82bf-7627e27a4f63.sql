ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS founder_at timestamptz;

DROP FUNCTION IF EXISTS public.member_directory();

CREATE OR REPLACE FUNCTION public.member_directory()
 RETURNS TABLE(id uuid, full_name text, avatar_url text, city text, region text, lat numeric, lng numeric, show_on_map boolean, joined_at timestamp with time zone, bio text, birth_year integer, goal text, founder_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.id, p.full_name, p.avatar_url, p.city, p.region,
         CASE WHEN p.show_on_map THEN p.lat END,
         CASE WHEN p.show_on_map THEN p.lng END,
         p.show_on_map, p.created_at, p.bio, p.birth_year, p.goal, p.founder_at
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
  ORDER BY p.created_at
$function$;