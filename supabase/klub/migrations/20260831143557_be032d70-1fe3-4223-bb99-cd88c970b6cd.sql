CREATE TABLE public.funnel_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  name text,
  phone text,
  age integer,
  current_weight numeric,
  target_weight numeric,
  health_issues text,
  occupation text,
  hobbies text,
  genetics text,
  life_changes text,
  obstacles text,
  vision_one_year text,
  expectations text,
  source text NOT NULL DEFAULT 'pohovor',
  submitted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX funnel_applications_email_key ON public.funnel_applications (lower(email));

GRANT SELECT ON public.funnel_applications TO authenticated;
GRANT ALL ON public.funnel_applications TO service_role;

ALTER TABLE public.funnel_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Women can read their own funnel application"
ON public.funnel_applications FOR SELECT TO authenticated
USING (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

CREATE POLICY "Admins can read all funnel applications"
ON public.funnel_applications FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER touch_funnel_applications
BEFORE UPDATE ON public.funnel_applications
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();