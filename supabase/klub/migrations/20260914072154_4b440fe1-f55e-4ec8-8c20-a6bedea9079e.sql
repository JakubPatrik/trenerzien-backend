ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS region_slug text;

CREATE INDEX IF NOT EXISTS profiles_region_slug_idx ON public.profiles (region_slug);
CREATE INDEX IF NOT EXISTS profiles_postal_code_idx ON public.profiles (postal_code);