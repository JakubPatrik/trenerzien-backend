CREATE TABLE public.technique_videos (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  storage_path text NOT NULL,
  mime text,
  note text,
  reviewed boolean NOT NULL DEFAULT false,
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.technique_videos TO authenticated;
GRANT ALL ON public.technique_videos TO service_role;

ALTER TABLE public.technique_videos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members read own technique videos"
ON public.technique_videos FOR SELECT TO authenticated
USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Members insert own technique videos"
ON public.technique_videos FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins update technique videos"
ON public.technique_videos FOR UPDATE TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Members delete own technique videos"
ON public.technique_videos FOR DELETE TO authenticated
USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER technique_videos_touch_updated_at
BEFORE UPDATE ON public.technique_videos
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE INDEX technique_videos_created_idx ON public.technique_videos (created_at DESC);