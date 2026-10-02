ALTER TABLE public.consultation_sessions
  ADD COLUMN IF NOT EXISTS auto_open boolean NOT NULL DEFAULT true;