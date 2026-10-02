# Prechod na vlastný Supabase backend (migration guide)

Cieľ: presunúť schému, dáta, používateľov a súbory z aktuálneho backendu do vlastného
Supabase projektu a potom prepnúť túto appku na nový projekt.

---

## 0. Čo si priprav

- Vlastný Supabase projekt (Pro plán odporúčaný kvôli storage a rozšíreniam).
- Lokálne nainštalované: `psql`, `pg_dump`, `pg_restore` (Postgres 15+) a `supabase` CLI.
- Z NOVÉHO projektu: `Project URL`, `anon/publishable key`, `service_role key`, `DB password`.
- Zo STARÉHO projektu: `DB connection string` a `service_role key`.

> Dôležité: aktuálny backend beží ako Lovable Cloud. `SUPABASE_SERVICE_ROLE_KEY`
> ani heslo k databáze nie sú pre teba prístupné z tohto prostredia. Buď si ich
> vyžiadaj od Lovable podpory pre tento projekt, alebo mi napíš a vygenerujem ti
> priamo v repozitári kompletný SQL dump schémy + dát (tabuľky, funkcie, triggery,
> RLS politiky, granty, enumy). Bez service_role kľúča sa nedajú preniesť hashe
> hesiel z `auth.users` — vtedy sa rieši reset hesiel (krok 4B).

---

## 1. Rozšírenia v novom projekte

Projekt používa `pgvector` (AI tréner / `odm_knowledge`). V SQL editore nového projektu:

```sql
create extension if not exists vector;
create extension if not exists pgcrypto;
```

## 2. Export a import schémy + dát (`public`)

```bash
# 1) len schéma
pg_dump "$OLD_DB_URL" \
  --schema=public --schema-only --no-owner --no-privileges \
  -f schema.sql

# 2) len dáta
pg_dump "$OLD_DB_URL" \
  --schema=public --data-only --no-owner --disable-triggers \
  -f data.sql

# 3) import do nového projektu
psql "$NEW_DB_URL" -f schema.sql
psql "$NEW_DB_URL" -f data.sql
```

Poznámky:
- Enum typy (`app_role`, `registration_status`, …) sú v `schema.sql`, importuj ho ako prvý.
- Ak `data.sql` zlyhá na foreign key na `auth.users`, najprv urob krok 4 (používatelia), potom dáta.
- Po importe skontroluj, že RLS je zapnutá a granty existujú:

```sql
select relname, relrowsecurity from pg_class
where relnamespace = 'public'::regnamespace and relkind = 'r';

select table_name, grantee, privilege_type from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon','authenticated','service_role');
```

## 3. Databázové funkcie a triggery

Sú súčasťou `schema.sql` (`has_role`, `handle_new_user`, `member_directory`,
`is_pair_member`, `match_odm_knowledge`, `touch_updated_at`, …).
Jediná výnimka: trigger na `auth.users`:

```sql
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();
```

Ten musíš v novom projekte vytvoriť ručne — `pg_dump` schémy `public` ho neobsahuje.

## 4. Používatelia (`auth.users`)

### 4A. S prenesenými heslami (potrebný prístup k starej DB)

```bash
pg_dump "$OLD_DB_URL" --schema=auth --data-only --no-owner \
  --table=auth.users --table=auth.identities -f auth.sql
psql "$NEW_DB_URL" -f auth.sql
```

Prenášaj len `auth.users` a `auth.identities`. Tokenové/refresh tabuľky nekopíruj.
Ak import spadne na NOT NULL v tokenových stĺpcoch, doplň prázdne stringy:

```sql
update auth.users set
  confirmation_token = coalesce(confirmation_token,''),
  recovery_token = coalesce(recovery_token,''),
  email_change_token_new = coalesce(email_change_token_new,''),
  email_change_token_current = coalesce(email_change_token_current,''),
  email_change = coalesce(email_change,''),
  phone_change = coalesce(phone_change,''),
  phone_change_token = coalesce(phone_change_token,''),
  reauthentication_token = coalesce(reauthentication_token,'');
```

Pri tomto postupe vypni trigger `on_auth_user_created` počas importu, inak sa
duplikujú profily:

```sql
alter table auth.users disable trigger on_auth_user_created;
-- import
alter table auth.users enable trigger on_auth_user_created;
```

### 4B. Bez hesiel (odporúčané — hotový export)

V exporte `supabase-data-export.zip` je súbor `auth_users.json` so všetkými
123 účtami: `id`, `email`, `created_at`, `email_confirmed_at`,
`last_sign_in_at`, `user_metadata`. **Heslá v ňom nie sú** (hashe sú v `auth`
schéme, ku ktorej z Lovable Cloud nie je prístup) — ženy si po migrácii
nastavia heslo nanovo cez „Zabudnuté heslo" / pozvánkový link.

Dôležité: zachovaj pôvodné `id`, inak sa rozpadnú väzby na `profiles`,
`club_survey`, `pair_requests`, `memberships`, `direct_messages` atď.

```ts
// scripts/migrate-users.ts — spusti s bun
import { createClient } from "@supabase/supabase-js";
const dst = createClient(process.env.NEW_URL!, process.env.NEW_SERVICE_KEY!, {
  auth: { persistSession: false },
});
const users = JSON.parse(await Bun.file("auth_users.json").text()) as Array<{
  id: string; email: string | null; user_metadata?: Record<string, unknown>;
}>;
for (const u of users) {
  if (!u.email) continue;
  const { error } = await dst.auth.admin.createUser({
    id: u.id,
    email: u.email,
    email_confirm: true,               // netreba potvrdzovať e-mail znova
    user_metadata: u.user_metadata ?? {},
  });
  if (error) console.error(u.email, error.message);
}
```

Vypni pritom trigger `on_auth_user_created` (inak vzniknú duplicitné profily),
lebo profily importuješ z dát:

```sql
alter table auth.users disable trigger on_auth_user_created;
-- spusti migrate-users.ts
alter table auth.users enable trigger on_auth_user_created;
```

Potom rozpošli nastavenie hesla (Admin API generuje jednorazový link, ktorý
môžeš poslať cez SmartEmailing rovnako ako dnešné pozvánky):

```ts
const { data } = await dst.auth.admin.generateLink({
  type: "recovery",
  email: u.email!,
  options: { redirectTo: "https://klub.trenerzien.sk/nove-heslo" },
});
// data.properties.action_link → vlož do e-mailu
```

## 4C. Import dát z JSON exportu

`supabase-data-export.zip` obsahuje po jednom `.json` súbore na každú tabuľku
`public` schémy (pole objektov = riadky) + `storage/` s reálnymi súbormi.
Poradie importu: **schéma → používatelia (4B) → dáta**. V rámci dát drž
poradie podľa závislostí: `profiles`, `memberships`, `club_survey`,
`regional_communities`, `community_members`, `club_events`,
`event_registrations`, `pair_requests`, `direct_messages`, ostatné.

```ts
// scripts/import-json.ts — spusti s bun v rozbalenej priečinku exportu
import { createClient } from "@supabase/supabase-js";
const dst = createClient(process.env.NEW_URL!, process.env.NEW_SERVICE_KEY!, {
  auth: { persistSession: false },
});
const order = ["profiles","memberships","club_survey","regional_communities",
  "community_members","badges","user_badges","user_roles","club_sections",
  "coaching_modules","challenge_days","meal_plan_days","meals","content_videos",
  "club_events","event_registrations","pair_requests","direct_messages",
  "consultation_sessions","consultation_questions","consultation_recordings",
  "member_recipes","recipe_votes","measurements","module_progress",
  "step_progress","day_progress","meal_progress","daily_checks","invites",
  "survey_config","announcements","monthly_themes","funnel_applications",
  "odm_knowledge"];
for (const table of order) {
  const rows = JSON.parse(await Bun.file(`${table}.json`).text());
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await dst.from(table).upsert(rows.slice(i, i + 500));
    if (error) console.error(table, error.message);
  }
}
```

Pozn.: `odm_knowledge.embedding` je v JSON textový vektor (`"[0.1,...]"`) —
pgvector ho pri inserte prijme, len najprv musí existovať `create extension vector`.

## 5. Storage

Buckety v projekte: `avatars`, `diagnostika`, `konzultacie`, `recepty`,
`submissions` — všetky privátne. Reálne súbory má dnes iba `avatars`
(32 profilových fotiek, ~7,7 MB) a sú súčasťou exportu v `storage/avatars/…`
s presnými cestami, na aké odkazuje `profiles.avatar_url`.

1. V novom projekte vytvor rovnaké buckety s rovnakými názvami a `public = false`
   (`diagnostika` má limit 200 MB na súbor, avatars stačí 10 MB).
2. Skopíruj RLS politiky na `storage.objects` — sú súčasťou migračných SQL
   súborov (`supabase-migrations.zip`), takže ich dostaneš spustením migrácií.
   Overenie v novom projekte:

```sql
select policyname, cmd, qual, with_check from pg_policies
where schemaname = 'storage' and tablename = 'objects';
```

3. Nahraj súbory z exportu — cesty musia zostať 1:1, DB na ne odkazuje:

```ts
// scripts/upload-storage.ts — spusti s bun v rozbalenom exporte
import { createClient } from "@supabase/supabase-js";
import { readdir } from "node:fs/promises";
const dst = createClient(process.env.NEW_URL!, process.env.NEW_SERVICE_KEY!, {
  auth: { persistSession: false },
});
for (const bucket of ["avatars","diagnostika","konzultacie","recepty","submissions"]) {
  const root = `storage/${bucket}`;
  let entries: string[] = [];
  try {
    entries = (await readdir(root, { recursive: true })) as string[];
  } catch { continue; }                       // bucket je prázdny
  for (const rel of entries) {
    const file = Bun.file(`${root}/${rel}`);
    if (!(await file.exists()) || file.size === 0) continue;   // priečinok
    const { error } = await dst.storage.from(bucket).upload(rel, file, {
      upsert: true,
      contentType: file.type || "application/octet-stream",
    });
    if (error) console.error(bucket, rel, error.message);
  }
}
```

4. Kontrola po nahraní:

```sql
select bucket_id, count(*) from storage.objects group by 1;
```

Alternatíva (ak by si mal service_role kľúč k starému projektu) — kopírovanie
priamo z projektu do projektu bez ZIPu:

```ts
const src = createClient(process.env.OLD_URL!, process.env.OLD_SERVICE_KEY!);
const { data: blob } = await src.storage.from(bucket).download(path);
if (blob) await dst.storage.from(bucket).upload(path, blob, { upsert: true });
```


## 6. Auth nastavenia v novom projekte

- Site URL a Redirect URLs: `https://klub.trenerzien.sk`, `http://localhost:8080`.
- Email/password prihlásenie zapnuté, self-signup podľa potreby vypnutý.
- „Leaked password protection" nechaj vypnuté (tak to má projekt dnes).
- E-mailové šablóny (pozvánka / reset hesla) v slovenčine.
- Ak používaš Google prihlásenie, nastav ho v novom projekte s vlastným OAuth klientom.

## 7. Secrets (server-side)

Prenes do nastavení nového prostredia:
`SMARTEMAILING_API_KEY`, `SMARTEMAILING_USERNAME`, `SMARTEMAILING_SENDER_EMAIL`,
`SMARTEMAILING_SENDER_NAME`, `SMARTEMAILING_REPLY_TO`,
`SMARTEMAILING_INVITE_TEMPLATE_ID`, `FUNNEL_INTAKE_KEY`, `FUNNEL_INTAKE_SECRET`,
`LOVABLE_API_KEY` (AI tréner — ak odchádzaš aj od Lovable AI, treba nahradiť
vlastným poskytovateľom v `src/lib/ai.functions.ts`).

## 8. Prepnutie frontendu

Áno, v podstate len env premenné. V `.env` (a v hostingu):

```
VITE_SUPABASE_URL="https://<new-ref>.supabase.co"
VITE_SUPABASE_PUBLISHABLE_KEY="<new anon/publishable key>"
VITE_SUPABASE_PROJECT_ID="<new-ref>"

SUPABASE_URL="https://<new-ref>.supabase.co"
SUPABASE_PUBLISHABLE_KEY="<new anon/publishable key>"
SUPABASE_PROJECT_ID="<new-ref>"
SUPABASE_SERVICE_ROLE_KEY="<new service role key>"
```

Kód nemení nič iné: `src/integrations/supabase/client.ts` číta `VITE_*`,
`client.server.ts` a `auth-middleware.ts` čítajú `SUPABASE_*` z prostredia.
Pozor: `SUPABASE_SERVICE_ROLE_KEY` nikdy nedávaj do `VITE_*`.

Typy tabuliek v `src/integrations/supabase/types.ts` sú generované — po migrácii
si ich obnov proti novému projektu:

```bash
bunx supabase gen types typescript --project-id <new-ref> > src/integrations/supabase/types.ts
```

## 9. Kontrolný zoznam po migrácii

- [ ] Prihlásenie existujúcej členky funguje (alebo prišiel reset hesla).
- [ ] `/profil` zobrazuje dotazník a avatar (storage signed URL).
- [ ] `/komunita` mapa vracia riadky z `member_directory()`.
- [ ] `/partacky` vyhľadávanie a `/spravy` chat fungujú (RLS `is_pair_member`).
- [ ] `/akcie` rezervácia a zoznam účastníčok.
- [ ] `/trener` odpovedá (pgvector + `match_odm_knowledge`).
- [ ] `/diagnostiky` upload videa a admin zobrazenie.
- [ ] Admin routy prístupné len rolám `admin` (`has_role`).
- [ ] Pozvánka cez SmartEmailing pošle funkčný link.
- [ ] `POST /api/public/funnel-intake` prijme testovací záznam.

SUPABASE_PROJECT_ID="pswwvqdeldgewchuyvhy"
SUPABASE_PUBLISHABLE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBzd3d2cWRlbGRnZXdjaHV5dmh5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0NzczNzYsImV4cCI6MjA5ODA1MzM3Nn0.fmVTpCxMx4UbgoMSfLzb0otfpEdkpCfj9FobxfxkJak"
SUPABASE_URL="https://pswwvqdeldgewchuyvhy.supabase.co"