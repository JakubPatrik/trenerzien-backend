# Migrácia na vlastný Supabase backend

Návod, ako preniesť databázu, používateľov a nastavenia z Lovable Cloud na tvoj
vlastný Supabase projekt a prepnúť na neho tento frontend.

---

## 0. Dôležité obmedzenie na začiatok

Zdrojová databáza beží na Lovable Cloud, kde **nemáš k dispozícii databázové
heslo ani service-role kľúč**. Preto nie je možné spraviť klasický
`pg_dump` celej inštancie (vrátane `auth` schémy s hashmi hesiel).

Praktický postup je preto:

1. **Schéma** – znovu vytvoriť z migračných súborov v tomto repozitári
   (`drizzle/migrations/*.sql`). Sú to presne tie SQL príkazy, ktoré vytvorili
   dnešnú databázu.
2. **Dáta** – exportovať cez Supabase Data API / CSV a naimportovať do nového
   projektu.
3. **Používatelia** – vytvoriť v novom projekte cez Auth Admin API. Hashe hesiel
   sa preniesť nedajú, takže členky si nastavia heslo znova cez pozývací email
   (rovnaká funkcia „Pozvať“, ktorú už v admine máš). Admin účty si nastavíš
   heslo sám.

Ak neskôr získaš plný `postgres://` prístup k zdrojovej databáze, sekcia
„Varianta B“ nižšie popisuje rýchlejší postup s `pg_dump`.

---

## 1. Vytvor nový Supabase projekt

1. supabase.com → New project (región najbližšie k EU, napr. `eu-central-1`).
2. Ulož si:
   - Project URL – `https://<ref>.supabase.co`
   - `anon` / publishable key
   - `service_role` / secret key
   - databázové heslo (potrebné pre `psql` / `pg_dump`)
3. Authentication → Providers:
   - **Email** zapni, **Confirm email** podľa potreby, **Enable signups** vypni
     (účty vytvára iba admin).
   - **Google** zapni a vlož Client ID / Secret, ak chceš zachovať prihlásenie
     cez Google.
4. Authentication → URL Configuration:
   - Site URL: `https://vyzva.trenerzien.sk`
   - Redirect URLs: `https://vyzva.trenerzien.sk/nove-heslo`,
     `https://vyzva.trenerzien.sk/*`, plus lokálne `http://localhost:8080/*`.

---

## 2. Vytvor schému

V novom projekte spusti migrácie v tomto poradí (SQL Editor alebo `psql`):

```
drizzle/migrations/0000_auth_profiles_roles.sql
drizzle/migrations/0001_create_memberships.sql
drizzle/migrations/0002_add_membership_name.sql
drizzle/migrations/0003_add_profiles_invited_at.sql
```

Cez `psql`:

```bash
export PGURL="postgresql://postgres:<DB_PASSWORD>@db.<ref>.supabase.co:5432/postgres"
for f in drizzle/migrations/0*.sql; do echo "== $f"; psql "$PGURL" -f "$f" || break; done
```

Po dobehnutí over, že existuje:

- enumy `app_role` (`admin`, `user`), `membership_status` (`active`, `paused`, `ended`)
- tabuľky `public.profiles`, `public.user_roles`, `public.memberships`
- funkcie `public.has_role(uuid, app_role)`, `public.handle_new_user()`
- trigger na `auth.users`, ktorý zakladá profil a rolu `user`
- RLS zapnuté na všetkých troch tabuľkách + `GRANT`-y pre `authenticated`
  a `service_role`

```sql
select tablename, rowsecurity from pg_tables where schemaname='public';
select proname from pg_proc where proname in ('has_role','handle_new_user');
```

---

## 3. Exportuj dáta zo starého projektu

Vytvor si lokálne `.env.export`:

```bash
OLD_URL="https://<stary-ref>.supabase.co"
OLD_SERVICE_KEY="<service_role kluc stareho projektu>"
```

Ak service-role kľúč k starému projektu nemáš, dáta vieš vytiahnuť aj ako
prihlásený admin (RLS politiky „Admins can view all …“ to dovolia) alebo
priamo z admin tabuliek v aplikácii.

Vyexportuj do JSON súborov (stránkovanie po 1000, inak Supabase reže výsledok):

```bash
for t in profiles user_roles memberships; do
  off=0
  : > "$t.json"
  while :; do
    n=$(curl -s "$OLD_URL/rest/v1/$t?select=*&order=id&offset=$off&limit=1000" \
      -H "apikey: $OLD_SERVICE_KEY" -H "Authorization: Bearer $OLD_SERVICE_KEY" \
      | tee "$t.part.json" | jq 'length')
    [ "$n" = "0" ] && break
    jq -s 'add' "$t.json" "$t.part.json" 2>/dev/null > "$t.merged" || cp "$t.part.json" "$t.merged"
    mv "$t.merged" "$t.json"
    off=$((off+1000))
  done
  echo "$t: $(jq length "$t.json")"
done
```

Používateľov (email, `id`, `created_at`, `last_sign_in_at`) vyexportuj cez Auth
Admin API:

```bash
page=1; : > users.json
while :; do
  r=$(curl -s "$OLD_URL/auth/v1/admin/users?page=$page&per_page=1000" \
    -H "apikey: $OLD_SERVICE_KEY" -H "Authorization: Bearer $OLD_SERVICE_KEY")
  n=$(echo "$r" | jq '.users | length'); [ "$n" = "0" ] && break
  echo "$r" | jq '.users' >> users.json; page=$((page+1))
done
```

---

## 4. Naimportuj používateľov do nového projektu

Kľúčové: **zachovaj rovnaké `id`** (UUID), aby na ne pasovali profily,
roly a členstvá. Auth Admin API to umožňuje.

```bash
NEW_URL="https://<novy-ref>.supabase.co"
NEW_SERVICE_KEY="<service_role kluc noveho projektu>"

jq -c '.[] | {id, email, email_confirm: true}' users.json | while read -r u; do
  curl -s -o /dev/null -X POST "$NEW_URL/auth/v1/admin/users" \
    -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
    -H "Content-Type: application/json" -d "$u"
done
```

Poznámky:

- Používatelia vzniknú **bez hesla**. Heslo si nastavia cez pozývací email
  (SmartEmailing template 1180 → odkaz na `/nove-heslo`), presne ako doteraz.
- Trigger `handle_new_user()` im automaticky vytvorí `profiles` riadok a rolu
  `user`. Preto v nasledujúcom kroku profily **aktualizuj**, neinsertuj.
- Adminom (`cmeldaniel@gmail.com`, `jakub.pa27@gmail.com`) daj rovno heslo:
  pridaj do JSON objektu `"password": "<docasne>"`.

---

## 5. Naimportuj tabuľky

Poradie: `profiles` → `user_roles` → `memberships`.

```bash
# profiles - upsert, lebo trigger uz zalozil zaklady
curl -s -X POST "$NEW_URL/rest/v1/profiles?on_conflict=id" \
  -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
  --data-binary @profiles.json

# roly - trigger uz pridal 'user', duplicity zahodi unique(user_id, role)
curl -s -X POST "$NEW_URL/rest/v1/user_roles?on_conflict=user_id,role" \
  -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: resolution=ignore-duplicates" \
  --data-binary @user_roles.json

curl -s -X POST "$NEW_URL/rest/v1/memberships" \
  -H "apikey: $NEW_SERVICE_KEY" -H "Authorization: Bearer $NEW_SERVICE_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @memberships.json
```

Pri veľkých súboroch (~3000 riadkov) to rozdeľ na dávky po 500:
`jq -c '.' | split` alebo `jq '.[0:500]'` v cykle.

### Kontrola po importe

```sql
select count(*) from auth.users;
select count(*) from public.profiles;
select count(*) from public.user_roles where role='admin';
select status, count(*) from public.memberships group by status;
-- osirele riadky (malo by byt 0)
select count(*) from public.memberships m left join auth.users u on u.id=m.user_id where u.id is null;
```

---

## 6. Prepni frontend na nový backend

Zmeň len premenné prostredia – kód sa nemení. Aplikácia číta:

| Premenná | Kde sa používa | Hodnota |
| --- | --- | --- |
| `VITE_SUPABASE_URL` | prehliadač | `https://<novy-ref>.supabase.co` |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | prehliadač | nový `anon` / publishable kľúč |
| `VITE_SUPABASE_PROJECT_ID` | prehliadač | `<novy-ref>` |
| `SUPABASE_URL` | server | `https://<novy-ref>.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | server | nový `anon` / publishable kľúč |
| `SUPABASE_SERVICE_ROLE_KEY` | server (admin operácie) | nový `service_role` kľúč |
| `SUPABASE_PROJECT_ID` | server | `<novy-ref>` |

Ďalšie premenné, ktoré musia existovať aj v novom prostredí (nesúvisia so
Supabase, ale bez nich nefungujú pozvánky a cron):

- `SMARTEMAILING_USERNAME`, `SMARTEMAILING_API_KEY`
- `SMARTEMAILING_SENDER_EMAIL`, `SMARTEMAILING_REPLY_TO`
- `SMARTEMAILING_SENDER_NAME` (voliteľné), `SMARTEMAILING_TEMPLATE_ID` (default `1180`)
- `LOVABLE_CRON_SECRET` (+ `LOVABLE_CRON_SECRET_PREVIOUS` pri rotácii)

Pri hostovaní mimo Lovable:

- `bun install && bun run build`, nasadenie ako TanStack Start aplikácia
  (Cloudflare Workers / Node adaptér).
- Serverové premenné nastav v hostingu, nie v repozitári.
- Typy databázy prípadne regeneruj:
  `bunx supabase gen types typescript --project-id <novy-ref> > src/integrations/supabase/types.ts`

---

## 7. Smoke test po prepnutí

1. `/prihlasenie` – prihlásenie admina emailom + heslom.
2. `/admin` – zobrazí správneho prihláseného admina.
3. `/admin/users` – počet členiek sedí s `select count(*) from profiles`.
4. `/admin/memberships` – počty a stavy sedia.
5. Vytvor testovaciu členku → skontroluj riadok v `profiles`, `user_roles`,
   `memberships`.
6. Pošli pozvánku na vlastný email → dorazí zo SmartEmailingu, odkaz otvorí
   `/nove-heslo` a heslo sa dá nastaviť.
7. „Zabudla si heslo?“ → recovery email a redirect na `/nove-heslo`.
8. Prihlásenie cez Google (ak ho používaš).
9. Odhlásenie → redirect na `/prihlasenie`, chránené stránky nie sú dostupné.

---

## Varianta B: keď máš plný databázový prístup k starému projektu

Ak získaš `postgres://` connection string aj k starej databáze, celý krok 3–5
sa zredukuje na:

```bash
# schema + data verejnej schemy
pg_dump "$OLD_PGURL" --schema=public --no-owner --no-privileges -f public.sql

# pouzivatelia vratane hashov hesiel
pg_dump "$OLD_PGURL" --data-only \
  --table=auth.users --table=auth.identities --table=auth.mfa_factors \
  --no-owner -f auth_data.sql

psql "$NEW_PGURL" -f public.sql
psql "$NEW_PGURL" -f auth_data.sql
```

Výhoda: **hashe hesiel prejdú**, takže členky sa prihlásia pôvodným heslom a
nemusíš posielať pozvánky. Postupuj v poradí `auth_data.sql` → `public.sql`
(kvôli foreign key na `auth.users`) a pred importom vypni triggre na
`auth.users`, aby ti `handle_new_user()` nevytváral duplicitné profily:

```sql
alter table auth.users disable trigger on_auth_user_created;
-- import
alter table auth.users enable trigger on_auth_user_created;
```

---

## Rollback

Kým v novom projekte niečo nefunguje, starý backend zostáva nedotknutý – nič
z tohto postupu doň nezapisuje. Vrátenie = vrátiť pôvodné hodnoty premenných
z tabuľky v kroku 6.

---

Toto je všetko, čo z tohto projektu vieš dostať:

URL: https://krqjvrzqxhczpmgrynwz.supabase.co
Project ID: krqjvrzqxhczpmgrynwz
Publishable (anon) kľúč: sb_publishable_Y2L7DAW4vUvrs3ufCe_zVQ_ojZIIyIY