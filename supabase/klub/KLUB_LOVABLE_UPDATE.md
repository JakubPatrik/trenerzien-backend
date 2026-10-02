# Klub beží na zdieľanom Supabase projekte — čo treba zmeniť v kóde

Backend appky **klub.trenerzien.sk** bol premigrovaný do **rovnakého** Supabase
projektu, aký používa `vyzva.trenerzien.sk` (a `web`/`trenerzien.sk`). Tabuľky
`profiles`, `user_roles` a `memberships` sú teraz **zdieľané naprieč tromi
appkami** — nie je to už samostatná databáza len pre klub. Schéma sa kvôli
tomu na niekoľkých miestach zmenila. Nižšie je presný zoznam zmien a čo treba
v kóde nájsť a upraviť.

---

## 1. Connection (env premenné)

Appka má odteraz smerovať na ten istý projekt ako vyzva/web:

```
VITE_SUPABASE_URL="https://eyxmuzfbtdaqtfzyaoqb.supabase.co"
VITE_SUPABASE_PUBLISHABLE_KEY="<anon/publishable key nového projektu>"
VITE_SUPABASE_PROJECT_ID="eyxmuzfbtdaqtfzyaoqb"

SUPABASE_URL="https://eyxmuzfbtdaqtfzyaoqb.supabase.co"
SUPABASE_PUBLISHABLE_KEY="<anon/publishable key nového projektu>"
SUPABASE_PROJECT_ID="eyxmuzfbtdaqtfzyaoqb"
SUPABASE_SERVICE_ROLE_KEY="<service_role key nového projektu>"
```

Regeneruj typy:

```bash
bunx supabase gen types typescript --project-id eyxmuzfbtdaqtfzyaoqb > src/integrations/supabase/types.ts
```

---

## 2. `public.profiles` — zmeny stĺpcov

| Klub stĺpec (starý) | Nový stav v zdieľanej tabuľke | Čo urobiť v kóde |
| --- | --- | --- |
| `full_name` | beží ďalej ako `full_name` | nič — vyzva mala `display_name`, ten sa premenoval na `full_name`, takže klubov kód sa nemení |
| *(nemal `email`)* | **`email` teraz existuje a je vyplnený pre všetky profily** | ak niekde appka doťahovala e-mail cez `auth.users`/session namiesto `profiles.email`, môžeš to odteraz čítať priamo z `profiles.email` |
| všetky ostatné (`avatar_url`, `city`, `region`, `lat`, `lng`, `show_on_map`, `birth_year`, `phone`, `bio`, `goal`, `motivation`, `profile_completed_at`, `height_cm`, `weight_kg`, `health_notes`, `target_weight_kg`, `target_waist_cm`, `founder_at`, `invitation`, `admin_note`, `membership_ends_on`, `nickname`, `postal_code`, `region_slug`, `updated_at`, `challenge_start_date`) | **nezmenené** — presne tie isté názvy a typy | nič |

**Dôležité — `id` sa pre časť členiek zmenilo.** 37 zo 123 klub-členiek malo
ten istý e-mail ako už existujúci účet vo vyzva projekte (spoločné členky
oboch produktov). Pre tieto ženy sa ich klub dáta napojili na **existujúce**
`auth.users.id` (z vyzva), nie na pôvodné klub UUID. V praxi to appku
nezaujíma — všetko je vždy naviazané cez `auth.uid()` prihláseného
používateľa, takže RLS politiky a `WHERE user_id = auth.uid()` fungujú ďalej
bez zmeny. Zmeň si to len ak niekde v kóde/testoch máš **natvrdo zapísané
konkrétne UUID** týchto ľudí.

---

## 3. `public.memberships` — zmeny stĺpcov

| Klub stĺpec (starý) | Nový stav | Čo urobiť v kóde |
| --- | --- | --- |
| `plan` | **premenovaný na `name`** | všade nahraď `.plan` → `.name`, `memberships.plan` → `memberships.name` (v SQL aj v TS) |
| `started_on` | **premenovaný na `starts_at`**, typ `date` → `timestamptz` | `.started_on` → `.starts_at` |
| `ends_on` | **premenovaný na `ends_at`**, typ `date` → `timestamptz` | `.ends_on` → `.ends_at` |
| `is_lifetime` | **stĺpec zrušený** | nahraď `row.is_lifetime` za `row.ends_at === null`. Pozor: nie je to 100% to isté — pôvodne malo 64 riadkov `ends_on = null` a `is_lifetime = false` zároveň (aktívne členstvo bez dátumu konca, ale nie formálne "doživotné"). Po migrácii to už nevieš rozlíšiť; ak na tom appka niekde staví logiku (napr. iný text/badge pre "doživotné" vs. "aktívne bez konca"), over si to. |
| `source`, `note` | **zachované, rovnaké názvy** | nič |
| — | **`status` je nový stĺpec** (enum `active`/`paused`/`ended`), pri migrácii nastavený na `'active'` pre všetky klub riadky | ak appka niekde filtruje/zobrazuje členstvá, môžeš odteraz použiť `status` namiesto vlastnej logiky nad dátumami |
| `unique(user_id, plan)` | **táto constraint sa do zdieľanej tabuľky NEPRENIESLA** | appka si už nemôže spoľahnúť na DB, že jeden user má max. jedno členstvo na daný `name` — ak na to niekde spoliehaš (napr. `upsert` s `onConflict: 'user_id,plan'`), over/uprav |

### Zdieľaná tabuľka = vidno aj vyzva riadky

`memberships` teraz obsahuje aj ~3250 riadkov z vyzva appky (`name` ∈
`Výzva`, `Koučing`, `Generátor`, `source IS NULL`). Ak klub appka číta
`select * from memberships where user_id = auth.uid()` bez ďalšieho filtra,
**u spoločných členiek (tých 37) dostaneš naspäť aj ich vyzva členstvá.**

Praktické rozlíšenie klub vs. vyzva riadkov (kým nepribudne čistejší
discriminator stĺpec):

```sql
-- klub-origin riadky majú vždy vyplnený source, vyzva riadky nikdy
where source is not null
```

Zváž, či to appke stačí, alebo či chceš pridať explicitný stĺpec (napr.
`app text` / `product text`) na jednoznačné odlíšenie — momentálne to nie je
súčasť schémy.

---

## 4. `public.user_roles` — hodnota role

| Klub hodnota (stará) | Nová hodnota | Čo urobiť v kóde |
| --- | --- | --- |
| `'client'` | **`'user'`** (zdieľaný `app_role` enum má len `admin`/`user`, nie `client`) | nájди všetky výskyty `'client'` v role-checkoch, RLS-adjacent podmienkach, TS typoch (`role === 'client'`, `Database['public']['Enums']['app_role']`, atď.) a nahraď za `'user'` |
| `'admin'` | nezmenené | nič |

`has_role(uid, role)` funguje rovnako ako predtým (`public.has_role`), len s
inou hodnotou pre bežných členov.

---

## 5. Storage, ostatné tabuľky (`club_survey`, `pair_requests`, `invites`, `odm_knowledge`, …)

**Toto ešte nie je premigrované.** Táto úprava sa týka **len**
`profiles`/`user_roles`/`memberships` (zdieľané naprieč appkami). Zvyšných
~50 klub-špecifických tabuliek (community, chat, AI tréner, meal plans,
storage buckety `avatars`/`diagnostika`/…) čaká na samostatnú migráciu — ich
FK na `profiles.id`/`auth.users.id` budú fungovať bez zmeny (id sa buď
zachovalo, alebo bolo správne premapované), ale samotné dáta v nich ešte
treba preniesť/mount-núť do nového projektu, kým appka bude tieto tabuľky
vedieť použiť naživo.

---

## 6. Chýbajúce funkcie: `inactive_members(integer)`, `my_last_activity()`

Zvyšných ~44 klub-špecifických tabuliek (community, chat, AI tréner, meal
plans, `odm_knowledge`, …) je teraz premigrovaných — schéma aj dáta. Pri
aplikovaní všetkých 59 migračných súborov ale zlyhali `REVOKE`/`GRANT`
príkazy na dvoch funkciách, ktoré **nikdy neboli súčasťou migračnej
histórie**: `public.inactive_members(integer)` a `public.my_last_activity()`.
Museli byť pridané priamo cez SQL editor v starom Lovable Cloud projekte,
mimo migrácií — takže ich definíciu nemám k dispozícii.

Ak appka niekde volá tieto funkcie (RPC), **po migrácii zlyhajú** ("function
does not exist"), kým ich niekto ručne nedotiahne zo starého projektu
(Supabase dashboard → Database → Functions → zobraz definíciu → `CREATE
FUNCTION` do nového projektu) alebo neposkytne ich zdroj inak.

Rovnaký problém, ale s celými **tabuľkami**: `monthly_themes` a
`monthly_checkins` tiež nie sú v žiadnom z 59 migračných súborov — vznikli
mimo migračnej histórie. Pre `monthly_themes` (5 riadkov dát) som schému
rekonštruoval podľa tvaru exportovaných dát a podľa vzoru `coaching_modules`
(`month date unique`, `title`, `subtitle`, `description`, `youtube_id`,
`tasks jsonb`, `is_published`) — over, či to sedí s tým, čo appka očakáva.
`monthly_checkins` má v exporte 0 riadkov, takže jeho schému nemám z čoho
overiť — vytvoril som ju ako **odhad** podľa vzoru sesterskej `daily_checks`
(rovnaká RLS politika, rovnaký tvar, len `check_date` → `month`):

```sql
id uuid, user_id uuid references auth.users, month date, task_key text,
completed boolean default true, created_at timestamptz,
unique(user_id, month, task_key)
```

**Toto nie je obnovená DDL, je to hádanka** — over stĺpce oproti
skutočnému frontend kódu (Lovable/appka) skôr, než sa na ňu appka bude
spoliehať. Ak sa nezhoduje, uprav/zahoď a vytvor znova.

---

## Zhrnutie — checklist na prehľadanie kódu

- [ ] `.plan` → `.name` (memberships)
- [ ] `.started_on` → `.starts_at`, `.ends_on` → `.ends_at`
- [ ] `.is_lifetime` → `.ends_at === null` (over rozdielové prípady vyššie)
- [ ] `'client'` role hodnota → `'user'`
- [ ] `onConflict: 'user_id,plan'` (alebo podobný upsert) → over, unique constraint už neplatí
- [ ] ak appka číta membership zoznam bez filtra na `user_id` → zváž `source is not null` filter
- [ ] env premenné (`SUPABASE_URL`/`PUBLISHABLE_KEY`/`SERVICE_ROLE_KEY`/`PROJECT_ID`) → nový zdieľaný projekt
- [ ] `bunx supabase gen types typescript` → obnoviť `types.ts`
- [ ] nájди volania `inactive_members(...)` / `my_last_activity()` → tieto funkcie v novom projekte zatiaľ neexistujú (pozri bod 6)
