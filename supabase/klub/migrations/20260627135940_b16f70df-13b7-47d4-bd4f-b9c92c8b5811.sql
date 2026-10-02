ALTER TABLE public.challenge_days ADD COLUMN IF NOT EXISTS day_type text NOT NULL DEFAULT 'cvicenie' CHECK (day_type IN ('cvicenie','strecing'));

UPDATE public.challenge_days
SET day_type = CASE WHEN day_number % 2 = 1 THEN 'cvicenie' ELSE 'strecing' END,
    title = CASE WHEN day_number % 2 = 1
                 THEN 'Deň ' || day_number || ' — Tréning'
                 ELSE 'Deň ' || day_number || ' — Strečing' END;