ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS birth_year integer,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS bio text,
  ADD COLUMN IF NOT EXISTS goal text,
  ADD COLUMN IF NOT EXISTS motivation text,
  ADD COLUMN IF NOT EXISTS profile_completed_at timestamptz;

CREATE TABLE IF NOT EXISTS public.community_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id uuid NOT NULL REFERENCES public.regional_communities(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (community_id, user_id)
);

GRANT SELECT, INSERT, DELETE ON public.community_members TO authenticated;
GRANT ALL ON public.community_members TO service_role;

ALTER TABLE public.community_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view community memberships"
  ON public.community_members FOR SELECT TO authenticated USING (true);

CREATE POLICY "Members can join communities"
  ON public.community_members FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Members can leave communities"
  ON public.community_members FOR DELETE TO authenticated USING (auth.uid() = user_id);

DROP FUNCTION IF EXISTS public.member_directory();

CREATE FUNCTION public.member_directory()
RETURNS TABLE(id uuid, full_name text, avatar_url text, city text, region text, lat numeric, lng numeric, show_on_map boolean, joined_at timestamp with time zone, bio text, birth_year integer, goal text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p.id, p.full_name, p.avatar_url, p.city, p.region,
         CASE WHEN p.show_on_map THEN p.lat END,
         CASE WHEN p.show_on_map THEN p.lng END,
         p.show_on_map, p.created_at, p.bio, p.birth_year, p.goal
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
  ORDER BY p.created_at
$$;