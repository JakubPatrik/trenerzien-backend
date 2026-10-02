CREATE TABLE IF NOT EXISTS public.announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  body text NOT NULL,
  is_pinned boolean NOT NULL DEFAULT false,
  is_published boolean NOT NULL DEFAULT true,
  published_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.announcements TO authenticated;
GRANT ALL ON public.announcements TO service_role;

ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "announcements readable by members" ON public.announcements
  FOR SELECT TO authenticated USING (is_published);

CREATE POLICY "announcements admin manage" ON public.announcements
  FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

INSERT INTO public.announcements (title, body, is_pinned, published_at) VALUES
  ('Vitaj v klube O DEKÁDU MLADŠIA', 'Začni v sekcii „Tu začni“ — pozri si úvodné video a vyplň svoj osobný profil. Potom pokračuj na Príjemnú premenu.', true, now()),
  ('Konzultácie každý týždeň', 'Spoločné ZOOM konzultácie s trénerom Danielom. Termíny nájdeš v Kalendári, pripojiť sa môžeš v sekcii Podpora → Konzultácie.', false, now() - interval '2 days'),
  ('Chystáme FITpobyt', 'Pripravujeme ďalší FITpobyt pre členky klubu. Detaily a prihlasovanie sa objavia v sekcii Akcie.', false, now() - interval '6 days');