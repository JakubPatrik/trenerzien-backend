
-- Enum pre typ jedla
DO $$ BEGIN
  CREATE TYPE public.meal_type AS ENUM ('ranajky','predjedlo','polievka','obed','vecera','dezert');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 1) meal_plan_days
CREATE TABLE public.meal_plan_days (
  day_number INT PRIMARY KEY CHECK (day_number BETWEEN 1 AND 90),
  fruit_suggestion TEXT,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.meal_plan_days TO authenticated;
GRANT ALL ON public.meal_plan_days TO service_role;
ALTER TABLE public.meal_plan_days ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can read meal_plan_days" ON public.meal_plan_days
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admins manage meal_plan_days" ON public.meal_plan_days
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_meal_plan_days_touch BEFORE UPDATE ON public.meal_plan_days
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 2) meals
CREATE TABLE public.meals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  day_number INT NOT NULL REFERENCES public.meal_plan_days(day_number) ON DELETE CASCADE,
  meal_type public.meal_type NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  description TEXT,
  recipe TEXT,
  youtube_id TEXT,
  image_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(day_number, meal_type)
);
GRANT SELECT ON public.meals TO authenticated;
GRANT ALL ON public.meals TO service_role;
ALTER TABLE public.meals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can read meals" ON public.meals
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admins manage meals" ON public.meals
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_meals_touch BEFORE UPDATE ON public.meals
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 3) meal_progress
CREATE TABLE public.meal_progress (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  day_number INT NOT NULL CHECK (day_number BETWEEN 1 AND 90),
  meals_eaten public.meal_type[] NOT NULL DEFAULT '{}',
  fruit_eaten BOOLEAN NOT NULL DEFAULT false,
  notes TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, day_number)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.meal_progress TO authenticated;
GRANT ALL ON public.meal_progress TO service_role;
ALTER TABLE public.meal_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own meal_progress" ON public.meal_progress
  FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
CREATE TRIGGER trg_meal_progress_touch BEFORE UPDATE ON public.meal_progress
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Seed 90 dní + 6 placeholder jedál na deň
INSERT INTO public.meal_plan_days (day_number, fruit_suggestion)
SELECT g, 'Sezónne ovocie podľa chuti (1–2 porcie)'
FROM generate_series(1,90) AS g;

INSERT INTO public.meals (day_number, meal_type, title)
SELECT d.day_number, t.meal_type, ''
FROM generate_series(1,90) AS d(day_number)
CROSS JOIN (VALUES
  ('ranajky'::public.meal_type),
  ('predjedlo'::public.meal_type),
  ('polievka'::public.meal_type),
  ('obed'::public.meal_type),
  ('vecera'::public.meal_type),
  ('dezert'::public.meal_type)
) AS t(meal_type);
