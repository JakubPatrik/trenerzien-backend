CREATE TABLE IF NOT EXISTS public.club_survey (
  user_id UUID NOT NULL PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  answers JSONB NOT NULL DEFAULT '{}'::jsonb,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_survey TO authenticated;
GRANT ALL ON public.club_survey TO service_role;
ALTER TABLE public.club_survey ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own survey" ON public.club_survey;
CREATE POLICY "own survey" ON public.club_survey FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS public.pair_requests (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  from_user UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  to_user UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (from_user, to_user)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pair_requests TO authenticated;
GRANT ALL ON public.pair_requests TO service_role;
ALTER TABLE public.pair_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "see own pair requests" ON public.pair_requests;
CREATE POLICY "see own pair requests" ON public.pair_requests FOR SELECT TO authenticated
  USING (auth.uid() = from_user OR auth.uid() = to_user);
DROP POLICY IF EXISTS "create own pair requests" ON public.pair_requests;
CREATE POLICY "create own pair requests" ON public.pair_requests FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = from_user AND from_user <> to_user);
DROP POLICY IF EXISTS "update involved pair requests" ON public.pair_requests;
CREATE POLICY "update involved pair requests" ON public.pair_requests FOR UPDATE TO authenticated
  USING (auth.uid() = from_user OR auth.uid() = to_user)
  WITH CHECK (auth.uid() = from_user OR auth.uid() = to_user);
DROP POLICY IF EXISTS "delete own pair requests" ON public.pair_requests;
CREATE POLICY "delete own pair requests" ON public.pair_requests FOR DELETE TO authenticated
  USING (auth.uid() = from_user);

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS club_survey_updated_at ON public.club_survey;
CREATE TRIGGER club_survey_updated_at BEFORE UPDATE ON public.club_survey
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS pair_requests_updated_at ON public.pair_requests;
CREATE TRIGGER pair_requests_updated_at BEFORE UPDATE ON public.pair_requests
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();