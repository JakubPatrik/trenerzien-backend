ALTER TABLE public.challenge_days DROP CONSTRAINT challenge_days_day_type_check;
ALTER TABLE public.challenge_days ADD CONSTRAINT challenge_days_day_type_check
  CHECK (day_type = ANY (ARRAY['cvicenie'::text, 'strecing'::text, 'volno'::text]));

DELETE FROM public.coaching_modules;
INSERT INTO public.coaching_modules (module_number, title, subtitle, description, tasks, requires_technique_check) VALUES
(1, 'Nastaviť systém', 'Spánok, jedlá a ranné lačnenie', 'Bez systému nefunguje nič. V tomto videu si spolu nastavíme tvoj denný režim — koľko spať, koľko jedál denne a ako dlho ráno lačniť.', '["Spím aspoň 8 hodín","Jem 2–3 jedlá denne, bez zobania medzi nimi","Ráno lačním 4–6 hodín","Vybrala som si svoj systém a viem, ako bude vyzerať môj deň"]'::jsonb, false),
(2, 'Vyživiť telo', 'VMBTV — poradie, ktoré rozhoduje', 'Nejde o to jesť menej, ale vyživiť telo. Naučím ťa poradie VMBTV, prečo jesť celé potraviny a ako zaradiť 3 dni v týždni bez mäsa a mliečnych.', '["Rozumiem poradiu VMBTV","Jem celé, neupravované potraviny","Mám naplánované 3 dni v týždni bez mäsa a mliečnych výrobkov","Doplnila som pitný režim"]'::jsonb, false),
(3, 'Rozhýbať telo', 'Rýchla chôdza a 10 000 krokov', 'Základ celej premeny je chôdza. 30 minút rýchlej chôdze, tempo pod 9 min/km a 10 000 krokov denne. Poviem ti aj ako sa obliekať a kedy chodiť.', '["Viem, čo je rýchla chôdza a ako ju merať","Chodím 30 minút rýchlou chôdzou","Idem si na 10 000 krokov denne","Chodím von na slnko a vzduch"]'::jsonb, false),
(4, 'Naučiť sa techniku', 'Drep, výpad, plank', 'Predtým než začneš cvičiť, musíš mať správnu techniku. Ukážem ti drep, výpad a plank, aj najčastejšie chyby, ktoré robí väčšina žien.', '["Pozrela som si techniku drepu","Pozrela som si techniku výpadu","Pozrela som si techniku planku","Poznám najčastejšie chyby a viem sa im vyhnúť"]'::jsonb, true),
(5, 'Štart', 'Prvý deň tvojej premeny', 'Máš všetko pripravené. Odmeriame si vstupné hodnoty a spúšťame 12 týždňov Príjemnej premeny.', '["Zapísala som si vstupné merania","Mám pripravené miesto na cvičenie","Viem, kedy budem chodiť a cvičiť","Som pripravená začať"]'::jsonb, false);

DELETE FROM public.challenge_days;
INSERT INTO public.challenge_days (day_number, day_type, title, description)
SELECT
  d,
  CASE (d - 1) % 3 WHEN 0 THEN 'cvicenie' WHEN 1 THEN 'strecing' ELSE 'volno' END,
  CASE (d - 1) % 3
    WHEN 0 THEN 'Tréning č. ' || ((d - 1) / 3 + 1)
    WHEN 1 THEN 'Strečing č. ' || ((d - 1) / 3 + 1)
    ELSE 'Voľno / dobiehací deň'
  END,
  CASE (d - 1) % 3
    WHEN 0 THEN 'Pozri si video a odcvič dnešný tréning. Nezabudni na rýchlu chôdzu a kroky.'
    WHEN 1 THEN 'Dnes telo len uvoľníme. Pozri si strečingové video a prejdi si ho spolu so mnou.'
    ELSE 'Dnes máš voľno. Ak ti nejaký deň unikol, dnes ho môžeš dobehnúť. Chôdza a kroky platia stále.'
  END
FROM generate_series(1, 90) AS d;