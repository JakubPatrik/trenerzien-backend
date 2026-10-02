
ALTER TABLE public.day_progress
  ADD COLUMN IF NOT EXISTS walking_pace_min_per_km numeric(5,2),
  ADD COLUMN IF NOT EXISTS squats_reps integer[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS lunges_reps integer[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS plank_seconds integer[] NOT NULL DEFAULT '{}';
