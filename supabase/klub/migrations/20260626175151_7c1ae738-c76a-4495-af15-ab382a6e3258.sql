
-- Phase: measurements (add phase enum)
CREATE TYPE measurement_phase AS ENUM ('vstupne', 'priebezne', 'vystupne');
ALTER TABLE public.measurements ADD COLUMN phase measurement_phase;

-- Coaching modules (5 intro modules)
CREATE TABLE public.coaching_modules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module_number int NOT NULL UNIQUE CHECK (module_number BETWEEN 1 AND 5),
  title text NOT NULL,
  subtitle text,
  description text,
  youtube_id text,
  tasks jsonb NOT NULL DEFAULT '[]'::jsonb,
  requires_technique_check boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.coaching_modules TO authenticated;
GRANT ALL ON public.coaching_modules TO service_role;
ALTER TABLE public.coaching_modules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone authenticated can view modules" ON public.coaching_modules
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admins manage modules" ON public.coaching_modules
  FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_coaching_modules BEFORE UPDATE ON public.coaching_modules
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- User progress through coaching modules
CREATE TABLE public.module_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  module_number int NOT NULL CHECK (module_number BETWEEN 1 AND 5),
  video_watched boolean NOT NULL DEFAULT false,
  tasks_done jsonb NOT NULL DEFAULT '[]'::jsonb,
  technique_self_approved boolean NOT NULL DEFAULT false,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, module_number)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.module_progress TO authenticated;
GRANT ALL ON public.module_progress TO service_role;
ALTER TABLE public.module_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own module progress" ON public.module_progress
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Admins view all module progress" ON public.module_progress
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_module_progress BEFORE UPDATE ON public.module_progress
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Challenge days catalogue (90 days)
CREATE TABLE public.challenge_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  day_number int NOT NULL UNIQUE CHECK (day_number BETWEEN 1 AND 90),
  title text NOT NULL,
  description text,
  exercise_youtube_id text,
  exercise_title text,
  stretch_youtube_id text,
  stretch_title text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.challenge_days TO authenticated;
GRANT ALL ON public.challenge_days TO service_role;
ALTER TABLE public.challenge_days ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone authenticated can view days" ON public.challenge_days
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admins manage days" ON public.challenge_days
  FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_challenge_days BEFORE UPDATE ON public.challenge_days
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- User progress per challenge day
CREATE TABLE public.day_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  day_number int NOT NULL CHECK (day_number BETWEEN 1 AND 90),
  exercise_done boolean NOT NULL DEFAULT false,
  stretch_done boolean NOT NULL DEFAULT false,
  steps int,
  walking_pace_kmh numeric(4,2),
  fasting_hours numeric(4,1),
  water_liters numeric(4,2),
  sleep_hours numeric(4,1),
  notes text,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, day_number)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.day_progress TO authenticated;
GRANT ALL ON public.day_progress TO service_role;
ALTER TABLE public.day_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own day progress" ON public.day_progress
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Admins view all day progress" ON public.day_progress
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_day_progress BEFORE UPDATE ON public.day_progress
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Badges
CREATE TABLE public.badges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  title text NOT NULL,
  description text,
  icon text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.badges TO authenticated;
GRANT ALL ON public.badges TO service_role;
ALTER TABLE public.badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone authenticated can view badges" ON public.badges
  FOR SELECT TO authenticated USING (true);

CREATE TABLE public.user_badges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  badge_code text NOT NULL REFERENCES public.badges(code) ON DELETE CASCADE,
  earned_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, badge_code)
);
GRANT SELECT, INSERT ON public.user_badges TO authenticated;
GRANT ALL ON public.user_badges TO service_role;
ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own badges" ON public.user_badges
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users insert own badges" ON public.user_badges
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- Seed 5 coaching modules
INSERT INTO public.coaching_modules (module_number, title, subtitle, description, tasks, requires_technique_check) VALUES
(1, 'Nastav si systém', 'Návyky, spánok, denný režim', 'V tomto koučingu si spolu nastavíme základ — pravidelný režim dňa, kvalitný spánok a malé návyky, ktoré ti budú slúžiť celý život.',
  '["Pozri si video až do konca", "Zapíš si svoj aktuálny čas spánku", "Stanov si pravidelný čas vstávania", "Priprav si fľašu na vodu"]'::jsonb, false),
(2, 'Vyživ svoje telo', 'Strava bez diét, recepty a lačnenie', 'Ukážem ti, ako jesť tak, aby si mala energiu, nehladovala a tvoje telo dostávalo to, čo potrebuje. Žiadne diéty — len jednoduchý systém.',
  '["Pozri si video až do konca", "Spočítaj si bielkoviny v jednom jedle", "Vyskúšaj 12-hodinové lačnenie", "Vyber si 3 recepty, ktoré urobíš tento týždeň"]'::jsonb, false),
(3, 'Rozhýb sa chôdzou', 'Rýchla chôdza ako základ', 'Chôdza je najprirodzenejší pohyb. Naučím ťa, ako chodiť tak, aby si chudla, mala viac energie a nezničila si kĺby.',
  '["Pozri si video až do konca", "Choď na 20 minútovú rýchlu chôdzu", "Zmeraj si tempo (km/h)", "Zapíš si počet krokov za deň"]'::jsonb, false),
(4, 'Nauč sa techniku', 'Drep, výpad, mostík — správne', 'Tri základné cviky, ktoré budeš robiť v 90-dňovej výzve. Tu sa naučíš správnu techniku, aby si si neublížila.',
  '["Pozri si video až do konca", "Vyskúšaj 5 drepov pred zrkadlom", "Vyskúšaj 5 výpadov na každú nohu", "Vyskúšaj 10 mostíkov"]'::jsonb, true),
(5, 'Štart 90-dňovej výzvy', 'Pripravená? Tu sa to začína!', 'Posledný koučing pred štartom. Prejdem s tebou, čo ťa čaká v 90 dňoch, ako si zapisovať pokrok a ako sa nevzdať.',
  '["Pozri si video až do konca", "Vyplň si vstupné meranie", "Sprav si vstupnú fotku", "Stanov si svoj cieľ na 90 dní"]'::jsonb, false);

-- Seed 90 challenge days with placeholders
INSERT INTO public.challenge_days (day_number, title, description, exercise_title, stretch_title)
SELECT
  d,
  CASE
    WHEN d % 30 = 1 THEN 'Deň ' || d || ' — nový mesiac, nový impulz'
    WHEN d % 7 = 0 THEN 'Deň ' || d || ' — týždenný míľnik'
    ELSE 'Deň ' || d
  END,
  'Dnešný plán: chôdza, cvičenie, strečing a zápis pocitov.',
  'Cvičenie ' || d,
  'Strečing ' || d
FROM generate_series(1, 90) d;

-- Seed badges
INSERT INTO public.badges (code, title, description, icon) VALUES
('first_step', 'Prvý krok', 'Dokončila si prvý koučing', 'sparkles'),
('coaching_complete', 'Pripravená na výzvu', 'Dokončila si všetkých 5 koučingov', 'rocket'),
('streak_7', '7 dní v rade', 'Splnila si 7 dní výzvy za sebou', 'flame'),
('streak_30', '30 dní v rade', 'Celý mesiac bez prerušenia!', 'trophy'),
('halfway', 'Polovica za tebou', 'Dokončila si 45. deň výzvy', 'medal'),
('finisher', 'Dokončila výzvu', 'Zvládla si všetkých 90 dní', 'crown'),
('first_measurement', 'Vstupné meranie', 'Zapísala si svoje vstupné hodnoty', 'ruler'),
('final_measurement', 'Výstupné meranie', 'Zapísala si výsledok po 90 dňoch', 'target');
