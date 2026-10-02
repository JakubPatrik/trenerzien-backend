ALTER TABLE public.memberships ADD COLUMN IF NOT EXISTS name text;
COMMENT ON COLUMN public.memberships.name IS 'Display name of the membership plan.';