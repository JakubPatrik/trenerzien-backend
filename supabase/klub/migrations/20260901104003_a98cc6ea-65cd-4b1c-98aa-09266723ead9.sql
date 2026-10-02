ALTER TABLE public.measurements
  ADD COLUMN IF NOT EXISTS thigh_left_cm numeric,
  ADD COLUMN IF NOT EXISTS muscle_percent numeric,
  ADD COLUMN IF NOT EXISTS fat_percent numeric,
  ADD COLUMN IF NOT EXISTS visceral_fat numeric;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS target_weight_kg numeric,
  ADD COLUMN IF NOT EXISTS target_waist_cm numeric;