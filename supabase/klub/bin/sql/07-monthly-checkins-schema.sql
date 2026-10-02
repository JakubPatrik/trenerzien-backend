-- monthly_checkins: same gap as monthly_themes (not in any of the 59
-- migration files) — but unlike monthly_themes, its export has 0 rows, so
-- there is NO data to infer real columns from. This is a best-effort
-- reconstruction only, modeled directly on its sibling daily_checks (exact
-- same shape/RLS pattern, just day -> month) and paired with monthly_themes
-- (same "month date" grain). Verify against the actual frontend/Lovable
-- code before relying on this — it is a guess, not recovered DDL.
CREATE TABLE IF NOT EXISTS public.monthly_checkins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  month date NOT NULL,
  task_key text NOT NULL,
  completed boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, month, task_key)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.monthly_checkins TO authenticated;
GRANT ALL ON public.monthly_checkins TO service_role;

ALTER TABLE public.monthly_checkins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "monthly_checkins_owner_all" ON public.monthly_checkins;
CREATE POLICY "monthly_checkins_owner_all" ON public.monthly_checkins FOR ALL
  TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
