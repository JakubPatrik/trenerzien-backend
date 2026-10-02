ALTER TABLE public.member_recipes ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.member_recipes ADD COLUMN IF NOT EXISTS guest_author_name text;
ALTER TABLE public.member_recipes ADD COLUMN IF NOT EXISTS image_url text;

CREATE TABLE IF NOT EXISTS public.recipe_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id uuid NOT NULL REFERENCES public.member_recipes(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recipe_id, user_id)
);

GRANT SELECT, INSERT, DELETE ON public.recipe_votes TO authenticated;
GRANT ALL ON public.recipe_votes TO service_role;
ALTER TABLE public.recipe_votes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members read recipe votes" ON public.recipe_votes
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Members vote once" ON public.recipe_votes
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Members remove own vote" ON public.recipe_votes
  FOR DELETE TO authenticated USING (auth.uid() = user_id);