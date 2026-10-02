-- monthly_themes was never captured in any of the 59 klub migration files
-- (same gap as inactive_members()/my_last_activity() — must have been added
-- by hand in the source project's SQL editor). Reconstructed here from the
-- exported data shape, modeled directly on coaching_modules' pattern (same
-- author, same era, same RLS style) since no authoritative DDL exists.
CREATE TABLE IF NOT EXISTS public.monthly_themes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  month date NOT NULL UNIQUE,
  title text NOT NULL,
  subtitle text,
  description text,
  youtube_id text,
  tasks jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_published boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.monthly_themes TO authenticated;
GRANT ALL ON public.monthly_themes TO service_role;

ALTER TABLE public.monthly_themes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members can view published monthly themes" ON public.monthly_themes;
CREATE POLICY "Members can view published monthly themes" ON public.monthly_themes
  FOR SELECT TO authenticated
  USING (is_published = true OR public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Admins manage monthly themes" ON public.monthly_themes;
CREATE POLICY "Admins manage monthly themes" ON public.monthly_themes
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP TRIGGER IF EXISTS touch_monthly_themes ON public.monthly_themes;
CREATE TRIGGER touch_monthly_themes BEFORE UPDATE ON public.monthly_themes
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
