ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS region text,
  ADD COLUMN IF NOT EXISTS lat numeric,
  ADD COLUMN IF NOT EXISTS lng numeric,
  ADD COLUMN IF NOT EXISTS show_on_map boolean NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS public.regional_communities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  region text NOT NULL,
  city text,
  lead_name text,
  description text,
  contact_url text,
  member_count integer NOT NULL DEFAULT 0,
  lat numeric,
  lng numeric,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.regional_communities TO authenticated;
GRANT ALL ON public.regional_communities TO service_role;
ALTER TABLE public.regional_communities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view active communities"
  ON public.regional_communities FOR SELECT TO authenticated
  USING (is_active = true);

CREATE TRIGGER touch_regional_communities
  BEFORE UPDATE ON public.regional_communities
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE OR REPLACE FUNCTION public.member_directory()
RETURNS TABLE (
  id uuid,
  full_name text,
  avatar_url text,
  city text,
  region text,
  lat numeric,
  lng numeric,
  show_on_map boolean,
  joined_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.full_name, p.avatar_url, p.city, p.region,
         CASE WHEN p.show_on_map THEN p.lat END,
         CASE WHEN p.show_on_map THEN p.lng END,
         p.show_on_map, p.created_at
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
  ORDER BY p.created_at
$$;

REVOKE ALL ON FUNCTION public.member_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_directory() TO authenticated;