CREATE TABLE public.survey_config (
  id text PRIMARY KEY,
  sections jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT SELECT ON public.survey_config TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.survey_config TO authenticated;
GRANT ALL ON public.survey_config TO service_role;

ALTER TABLE public.survey_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Prihlasene clenky citaju dotaznik"
  ON public.survey_config FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admin spravuje dotaznik"
  ON public.survey_config FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER survey_config_touch_updated_at
  BEFORE UPDATE ON public.survey_config
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();