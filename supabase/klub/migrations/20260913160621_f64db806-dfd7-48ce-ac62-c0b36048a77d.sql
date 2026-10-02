UPDATE public.coaching_modules SET module_number = 9, etapa = 'zivotna_premena', updated_at = now() WHERE module_number = 7;
UPDATE public.coaching_modules SET module_number = 8, etapa = 'zivotna_premena', updated_at = now() WHERE module_number = 6;
UPDATE public.coaching_modules SET module_number = 7, etapa = 'zivotna_premena', updated_at = now() WHERE module_number = 5;

UPDATE public.module_progress SET module_number = 9, updated_at = now() WHERE module_number = 7;
UPDATE public.module_progress SET module_number = 8, updated_at = now() WHERE module_number = 6;
UPDATE public.module_progress SET module_number = 7, updated_at = now() WHERE module_number = 5;

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
VALUES
  (
    5,
    'Diagnostika techniky',
    'Kontrola správneho prevedenia cvikov',
    'Natoč sa pri cvičení, pošli video trénerovi a získaj spätnú väzbu na svoju techniku.',
    NULL,
    '[]'::jsonb,
    false,
    'zivotna_premena',
    'pripravna',
    '[]'::jsonb,
    'kontrola techniky'
  ),
  (
    6,
    '90 dňová výzva',
    'Praktická výzva a manuál PRÍJEMNÁ premena',
    'Pozri si úvodné video, stiahni manuál a prejdi 90 dňovou výzvou.',
    NULL,
    '[]'::jsonb,
    false,
    'zivotna_premena',
    'pripravna',
    '[]'::jsonb,
    '90 dňová výzva'
  );