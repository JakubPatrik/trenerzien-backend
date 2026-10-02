CREATE TABLE public.consultation_recordings (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  held_on date NOT NULL,
  youtube_id text NOT NULL,
  title text,
  note text,
  is_published boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_recordings TO authenticated;
GRANT ALL ON public.consultation_recordings TO service_role;
ALTER TABLE public.consultation_recordings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view published recordings"
ON public.consultation_recordings FOR SELECT TO authenticated
USING (is_published OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Admins manage recordings"
ON public.consultation_recordings FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE INDEX consultation_recordings_held_on_idx ON public.consultation_recordings (held_on DESC);

CREATE TRIGGER touch_consultation_recordings BEFORE UPDATE ON public.consultation_recordings
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.recording_views (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recording_id uuid NOT NULL REFERENCES public.consultation_recordings(id) ON DELETE CASCADE,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  UNIQUE (user_id, recording_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.recording_views TO authenticated;
GRANT ALL ON public.recording_views TO service_role;
ALTER TABLE public.recording_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own recording views"
ON public.recording_views FOR ALL TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);