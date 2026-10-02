INSERT INTO public.coaching_modules (
  module_number,
  title,
  subtitle,
  description,
  youtube_id,
  tasks,
  requires_technique_check,
  etapa,
  phase,
  principles,
  level_label
)
VALUES (
  10,
  'Ži podľa DESATORO',
  'Desať zásad pre život O DEKÁDU MLADŠIA',
  'Osvoj si desať zásad a prenes ich do svojho každodenného života.',
  NULL,
  '[]'::jsonb,
  false,
  'zivotna_premena',
  'misia',
  '[]'::jsonb,
  'cieľ cesty'
)
ON CONFLICT (module_number) DO UPDATE SET
  title = EXCLUDED.title,
  subtitle = EXCLUDED.subtitle,
  description = EXCLUDED.description,
  etapa = EXCLUDED.etapa,
  phase = EXCLUDED.phase,
  level_label = EXCLUDED.level_label,
  updated_at = now();