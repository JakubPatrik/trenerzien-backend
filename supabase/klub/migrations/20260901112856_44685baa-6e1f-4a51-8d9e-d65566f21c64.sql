ALTER TABLE public.consultation_sessions
  ADD COLUMN IF NOT EXISTS starts_at timestamptz;

UPDATE public.consultation_sessions
SET starts_at = (held_on::timestamp + interval '19 hours') AT TIME ZONE 'Europe/Bratislava'
WHERE starts_at IS NULL;

INSERT INTO public.consultation_sessions (held_on, title, starts_at, is_open)
SELECT d::date, 'Pondelok 19:00', (d::timestamp + interval '19 hours') AT TIME ZONE 'Europe/Bratislava', false
FROM (VALUES
  ('2026-09-14'),('2026-09-28'),('2026-10-12'),('2026-10-26'),
  ('2026-11-09'),('2026-11-23'),('2026-12-07'),('2026-12-21')
) AS t(d)
WHERE NOT EXISTS (
  SELECT 1 FROM public.consultation_sessions s WHERE s.held_on = d::date
);

INSERT INTO public.club_events (kind, title, description, location, starts_at, ends_at, meeting_url, is_published)
SELECT 'konzultacia'::event_kind,
       'Konzultácia s trénerom',
       'Spoločná online konzultácia klubu. Otázky vkladaj v sekcii Konzultácie — odpovedám na ne postupne naživo.',
       'ZOOM (online)',
       (d::timestamp + interval '19 hours') AT TIME ZONE 'Europe/Bratislava',
       (d::timestamp + interval '20 hours 30 minutes') AT TIME ZONE 'Europe/Bratislava',
       NULL,
       true
FROM (VALUES
  ('2026-09-14'),('2026-09-28'),('2026-10-12'),('2026-10-26'),
  ('2026-11-09'),('2026-11-23'),('2026-12-07'),('2026-12-21')
) AS t(d)
WHERE NOT EXISTS (
  SELECT 1 FROM public.club_events e
  WHERE e.kind = 'konzultacia'
    AND e.starts_at = (d::timestamp + interval '19 hours') AT TIME ZONE 'Europe/Bratislava'
);