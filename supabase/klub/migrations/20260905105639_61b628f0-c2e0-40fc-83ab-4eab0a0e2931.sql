CREATE TABLE public.member_recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  category_slug text NOT NULL,
  intro text,
  ingredients text NOT NULL,
  steps text NOT NULL,
  tip text,
  image_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.member_recipes TO authenticated;
GRANT ALL ON public.member_recipes TO service_role;

ALTER TABLE public.member_recipes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members read recipes" ON public.member_recipes
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Members create own recipe" ON public.member_recipes
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = author_id);

CREATE POLICY "Author or admin updates recipe" ON public.member_recipes
  FOR UPDATE TO authenticated
  USING (auth.uid() = author_id OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (auth.uid() = author_id OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Author or admin deletes recipe" ON public.member_recipes
  FOR DELETE TO authenticated
  USING (auth.uid() = author_id OR public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER touch_member_recipes BEFORE UPDATE ON public.member_recipes
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE INDEX member_recipes_created_idx ON public.member_recipes (created_at DESC);