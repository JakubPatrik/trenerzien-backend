ALTER TABLE public.invites
  ADD COLUMN IF NOT EXISTS token uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS token_expires_at timestamptz;
CREATE INDEX IF NOT EXISTS invites_token_idx ON public.invites (token);