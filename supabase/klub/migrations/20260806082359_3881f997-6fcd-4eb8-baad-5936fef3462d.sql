ALTER TABLE public.coaching_modules
  ADD COLUMN IF NOT EXISTS etapa TEXT NOT NULL DEFAULT 'prijemna_premena',
  ADD COLUMN IF NOT EXISTS phase TEXT NOT NULL DEFAULT 'necvicaca',
  ADD COLUMN IF NOT EXISTS principles JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS level_label TEXT;

ALTER TABLE public.coaching_modules DROP CONSTRAINT IF EXISTS coaching_modules_module_number_check;
ALTER TABLE public.coaching_modules ADD CONSTRAINT coaching_modules_module_number_check CHECK (module_number BETWEEN 1 AND 9);
ALTER TABLE public.module_progress DROP CONSTRAINT IF EXISTS module_progress_module_number_check;
ALTER TABLE public.module_progress ADD CONSTRAINT module_progress_module_number_check CHECK (module_number BETWEEN 1 AND 9);

DELETE FROM public.coaching_modules;

INSERT INTO public.coaching_modules
  (module_number, title, subtitle, description, etapa, phase, level_label, tasks, principles, requires_technique_check)
VALUES
(1, 'Nastavenie hlavy',
 'Vstup do metódy — čo rozhodne o úspechu',
 'Mindset. Moje klientky dosahujú úspech jedine ak zvládnu tento vstup. Úprimne 80 % žien skončí po prvom uspokojení s výsledkami, len 20 % žien si zmení život na nepoznanie. Daj seba na 1. miesto v živote a nájdi svoje SILNÉ prečo.',
 'prijemna_premena', 'necvicaca', 'necvičiaca',
 '["Pozri si celé koučingové video","Napíš si svoje SILNÉ prečo","Rozhodni sa dať seba na 1. miesto"]'::jsonb,
 '[]'::jsonb, false),
(2, 'Nastaviť systém',
 'Spánok, frekvencia jedenia, lačnenie',
 'Prvé tri zásady desatora — bez systému nefunguje nič ďalšie.',
 'prijemna_premena', 'necvicaca', 'necvičiaca',
 '["Nastav si spánkový režim","Nastav si frekvenciu jedenia","Nastav si fyziologické načasovanie a lačnenie"]'::jsonb,
 '["1. zásada — spánok","2. zásada — frekvencia jedenia","3. zásada — fyziologické načasovanie a lačnenie"]'::jsonb, false),
(3, 'Vyživiť telo',
 'VMBTV koncept + generátor receptov',
 'Ako jesť tak, aby telo dostalo všetko čo potrebuje — a ty si nekupovala nič navyše.',
 'prijemna_premena', 'necvicaca', 'necvičiaca',
 '["Nauč sa VMBTV koncept","Prestaň kupovať potraviny navyše","Vyskúšaj 3 dni bez mäsa a mlieka","Stiahni si PDF s receptami"]'::jsonb,
 '["4. zásada — VMBTV koncept","5. zásada — nekupovať potraviny navyše","6. zásada — nejesť 3 dni mäso a mlieko"]'::jsonb, false),
(4, 'Rozhýbať telo',
 'Rýchla chôdza a 10 000 krokov denne',
 'Prvý pohyb — bez cvičenia, len chôdza. Toto je motor prvých výsledkov.',
 'prijemna_premena', 'necvicaca', 'necvičiaca',
 '["RCH 30 min denne tempom pod 9 min/km","10 000 krokov denne","Zapisuj kroky a tempo v sekcii Chôdza"]'::jsonb,
 '["7. zásada — RCH 30 min/deň tempom < 9 min/km + 10 000 krokov denne"]'::jsonb, false),
(5, 'Pripraviť sa na cvičenie a začať cvičiť',
 'Budovanie návyku pravidelne cvičiť',
 'Rozcvičenie pred každým cvičením, naučenie správnej techniky DVP, diagnostika a cvičenie každý druhý deň — BZS výzva I.',
 'zivotna_premena', 'pripravna', 'začiatočníčka až mierne pokročilá',
 '["Nauč sa rozcvičenie","Zvládni techniku DVP","Absolvuj diagnostiku","Cvič každý druhý deň BZS výzvu I","Pošli video techniky na posúdenie"]'::jsonb,
 '[]'::jsonb, true),
(6, 'Odstrániť bolesti, získať mobilitu a flexibilitu',
 'Joga, strečing, roller',
 'Telo bez bolesti je telo, ktoré vydrží. Denných 30 minút mení všetko.',
 'zivotna_premena', 'pripravna', 'začiatočníčka až mierne pokročilá',
 '["30 min denne joga / strečing / roller","Zaznač si, kde bolesti ustupujú"]'::jsonb,
 '["8. zásada — vykonávaj každý deň 30 min (joga, strečing, roller)"]'::jsonb, false),
(7, 'Prechod na regulérny silový tréning',
 'BZS výzva II a III + kondičné aktivity',
 'Cvičenie s jednoručkami, potom s veľkou činkou, plus kondičné aktivity. Dosiahnutie cieľa, ktorý nikdy nekončí.',
 'zivotna_premena', 'vykonnostna', 'pokročilá až atlétka',
 '["BZS výzva II — jednoručky","BZS výzva III — veľká činka","Pridaj kondičné aktivity"]'::jsonb,
 '["9. zásada — vykonávaj 2-3x ST za týždeň a zvyšuj % svalovej hmoty","10. zásada — vykonávaj 2-3x KA za týždeň a rozvíjaj VO2max"]'::jsonb, false),
(8, 'Sprievodkyňa',
 'Pomáhaš ostatným ženám uspieť',
 'Úspech tvojich zverenkýň je aj tvojím úspechom. Desatoro máš zvládnuté — koleso je vymyslené, stačí ním točiť.',
 'zivotna_premena', 'misia', 'sprievodkyňa',
 '["Prejdi si DESATORO od začiatku","Prihlás sa do zoznamu sprievodkýň"]'::jsonb,
 '[]'::jsonb, false),
(9, 'Ambasádorka / Partnerka',
 'Šíriš projekt ďalej za spravodlivú odmenu',
 'Úspech partneriek je úspech celého projektu. Čakáme na prvú partnerku.',
 'zivotna_premena', 'misia', 'ambasádorka',
 '["Ozvi sa Danielovi ohľadom partnerstva"]'::jsonb,
 '[]'::jsonb, false);

CREATE TABLE IF NOT EXISTS public.content_videos (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  description TEXT,
  youtube_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.content_videos TO authenticated;
GRANT ALL ON public.content_videos TO service_role;
ALTER TABLE public.content_videos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "content_videos readable by members" ON public.content_videos
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "content_videos admin manage" ON public.content_videos
  FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_content_videos BEFORE UPDATE ON public.content_videos
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO public.content_videos (slug, title, description) VALUES
('vitaj', 'Vitaj v klube O DEKÁDU MLADŠIA', 'Úvodné video k celej členskej sekcii — čo tu nájdeš a ako to funguje.'),
('etapa-1', 'PRVÁ ETAPA — Príjemná premena', 'Cesta z bodu A do B. Žiadne, alebo len minimálne prekážky. Prvé výsledky: redukcia 8–12 kg za prvé 2–3 mesiace bez cvičenia, veľmi príjemným spôsobom.'),
('etapa-2', 'DRUHÁ ETAPA — Životná premena', 'Cesta z bodu B do C. Veľké prekážky, veľký bod zlomu, zásadná premena identity — musíš sa touto ženou stať už teraz.')
ON CONFLICT (slug) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.club_sections (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  description TEXT,
  icon TEXT,
  sort_order INT NOT NULL DEFAULT 0,
  is_ready BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.club_sections TO authenticated;
GRANT ALL ON public.club_sections TO service_role;
ALTER TABLE public.club_sections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "club_sections readable by members" ON public.club_sections
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "club_sections admin manage" ON public.club_sections
  FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_club_sections BEFORE UPDATE ON public.club_sections
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO public.club_sections (slug, title, description, icon, sort_order, is_ready) VALUES
('recepty', 'Recepty', 'Originálne recepty + recepty od klientiek, tipy a triky s prípravou jedla.', '🍲', 1, false),
('sprievodkyne', 'Sprievodkyne', 'Zoznam sprievodkýň, ich špecializácia, kontakt a výsledky ich premeny.', '🤝', 2, false),
('konzultacie', 'Konzultácie', 'Konzultácie s trénerom cez ZOOM, záznamy a prihlásenie sa na termín.', '💬', 3, false),
('komunita', 'Komunita', 'Mapa Slovenska a Česka s bodmi, kde sa klientky nachádzajú — spoj sa s nimi.', '🗺️', 4, false),
('pohybovnik', 'Pohybovník', 'Pohybový diár — zapisuj výkony, sleduj tabuľky, grafy a získavaj ocenenia.', '📔', 5, false),
('akcie', 'Akcie', 'FITpobyty, aktívne dovolenky a výlety — všetko prehľadne a jednoducho.', '🏔️', 6, false),
('kalendar', 'Kalendár', 'Všetky udalosti prehľadne, s možnosťou prihlásiť sa na konzultáciu či pobyt.', '📅', 7, false),
('materialy', 'Doplnkové materiály', 'Vzdelávacie materiály na prehĺbenie toho, čo sa učíš na Ceste ODM.', '📚', 8, false)
ON CONFLICT (slug) DO NOTHING;