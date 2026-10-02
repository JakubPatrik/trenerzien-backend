UPDATE public.coaching_modules
SET title = 'Rozhýbať telo — rýchla chôdza a 10 000 krokov denne + pripraviť sa na cvičenie',
    subtitle = 'Rýchla chôdza, 10 000 krokov denne a príprava na cvičenie',
    description = 'Prvý pohyb — bez cvičenia, len chôdza. Toto je motor prvých výsledkov. Následne sa pripravíš na cvičenie: rozcvičenie, správna technika DVP, diagnostika a budovanie návyku pravidelne cvičiť.',
    requires_technique_check = true
WHERE module_number = 4;

DELETE FROM public.module_progress WHERE module_number >= 5;
DELETE FROM public.coaching_modules WHERE module_number IN (5, 9, 10);

UPDATE public.coaching_modules SET module_number = module_number - 1 WHERE module_number IN (6, 7, 8);

UPDATE public.coaching_modules SET etapa = 'prijemna_premena';