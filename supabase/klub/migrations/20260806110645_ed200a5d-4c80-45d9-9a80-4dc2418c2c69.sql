CREATE TYPE public.event_kind AS ENUM ('konzultacia', 'fitpobyt', 'dovolenka', 'vylet', 'online', 'ine');
CREATE TYPE public.registration_status AS ENUM ('prihlasena', 'zrusena', 'potvrdena');

CREATE TABLE public.club_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind public.event_kind NOT NULL DEFAULT 'ine',
  title text NOT NULL,
  description text,
  location text,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz,
  capacity integer,
  price_eur numeric,
  meeting_url text,
  image_url text,
  is_published boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_events TO authenticated;
GRANT ALL ON public.club_events TO service_role;
ALTER TABLE public.club_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "club_events readable by members" ON public.club_events FOR SELECT TO authenticated USING (is_published OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "club_events admin manage" ON public.club_events FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_club_events BEFORE UPDATE ON public.club_events FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE INDEX club_events_starts_at_idx ON public.club_events (starts_at);

CREATE TABLE public.event_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.club_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  note text,
  status public.registration_status NOT NULL DEFAULT 'prihlasena',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, user_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_registrations TO authenticated;
GRANT ALL ON public.event_registrations TO service_role;
ALTER TABLE public.event_registrations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "event_registrations owner select" ON public.event_registrations FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "event_registrations owner insert" ON public.event_registrations FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "event_registrations owner update" ON public.event_registrations FOR UPDATE TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin')) WITH CHECK (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "event_registrations owner delete" ON public.event_registrations FOR DELETE TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_event_registrations BEFORE UPDATE ON public.event_registrations FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO public.club_events (kind, title, description, location, starts_at, ends_at, capacity, price_eur, meeting_url) VALUES
('online', 'Mesačné ZOOM stretnutie klubu', 'Spoločné stretnutie členiek s Danielom — otázky, odpovede a plán na ďalší mesiac.', 'ZOOM (online)', '2026-08-19 18:00+02', '2026-08-19 19:30+02', NULL, 0, 'https://zoom.us/'),
('konzultacia', 'Konzultácia s trénerom — voľné termíny', 'Individuálna konzultácia 1:1 cez ZOOM. Prihlás sa a dohodneme presný čas.', 'ZOOM (online)', '2026-08-26 17:00+02', '2026-08-26 18:00+02', 8, 0, 'https://zoom.us/'),
('fitpobyt', 'FITpobyt Liptov', 'Predĺžený víkend s rýchlou chôdzou, tréningami, zdravou stravou a regeneráciou.', 'Liptov, Slovensko', '2026-09-17 15:00+02', '2026-09-20 12:00+02', 20, 447, NULL),
('vylet', 'Jednodňový výlet — Malá Fatra', 'Spoločná turistika v pohodovom tempe, vhodná aj pre začiatočníčky.', 'Malá Fatra', '2026-10-10 08:00+02', '2026-10-10 17:00+02', 25, 25, NULL);

UPDATE public.club_sections SET is_ready = true WHERE slug = 'kalendar';