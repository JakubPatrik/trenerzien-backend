ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS invited_at timestamptz;

COMMENT ON COLUMN public.profiles.invited_at IS 'Kedy bola členke odoslaná pozvánka na nastavenie hesla (SmartEmailing).';