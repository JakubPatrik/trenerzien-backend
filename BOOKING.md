# Rezervácia pohovoru — backend

Krok 2 po dotazníku (`consultation_applications`): lead si vyberie termín
(60 min) a s kým sa porozpráva; vznikne Google Meet v kalendári master účtu,
pozvánka ide leadovi aj helperovi a lead dostane potvrdenie zo SmartEmailingu.

Dve aplikácie, jeden Supabase projekt:

| Aplikácia | Čo v nej žije |
| --- | --- |
| **WEB** (trenerzien.sk) | dotazník + výber termínu + potvrdenie — [WEB](#web--rezervácia-pohovoru) |
| **KLUB** | sprievodkyne (`Sprievodkyňa klubu`) si v profile nastavujú dostupnosť — [KLUB](#klub--dostupnosť-sprievodkýň) |

```
krok 1 dotazník ──insert (s tokenom)──▶ consultation_applications
krok 2 výber    ──rpc booking_slots()──▶ voľné termíny (helper × čas)
       potvrdiť ──POST book-meeting────▶ book_appointment()  ── 'pending' (DB zamkne slot)
                                         Google Calendar       ── udalosť + Meet link, pozvánky
                                         appointments          ── 'confirmed'
                                         SmartEmailing         ── potvrdzovací e-mail
helper / admin  ──POST cancel-meeting──▶ zmaže udalosť (Google pošle zrušenie), slot sa uvoľní

KLUB sprievodkyňa ──rpc ensure_my_helper()──▶ helpers (vytvorí sa raz)
                  ──CRUD──▶ helper_availability, helper_time_off ──▶ booking_slots() na WEBe
```

| Čo | Kde |
| --- | --- |
| Schéma, RPC, RLS | `supabase/web/migrations/4.sql` (+ `5.sql` pre KLUB — zatiaľ neimplementované) |
| Edge functions | `supabase/functions/book-meeting/`, `cancel-meeting/`, `_shared/` |
| Skripty | `supabase/web/bin/08–12-*.sh` |
| Testy (lokálny Postgres) | `supabase/web/tests/booking-test.sh` |

## Dátový model

| Tabuľka | Obsah |
| --- | --- |
| `helpers` | kto vedie pohovory; `user_id` → prihlásenie helpera, `email` → pozvánka |
| `helper_availability` | týždenné okná, `day_of_week` ISO **1 = pondelok … 7 = nedeľa**, `timezone` (default `Europe/Bratislava`) |
| `helper_time_off` | dovolenka / voľno (`starts_at`–`ends_at`), blokuje sloty |
| `booking_settings` | 1 riadok: `slot_minutes` 60, `slot_step_minutes` 60, `buffer_minutes` 0, `min_notice_minutes` 1440 (24 h), `horizon_days` 21 |
| `appointments` | `pending → confirmed → completed / no_show`, alebo `cancelled` |

Záruky v databáze:

- **Žiadna dvojitá rezervácia** — `EXCLUDE` constraint (helper × časový rozsah)
  pre `pending`/`confirmed` + `book_appointment()` beží pod zámkom.
- **Jedna prihláška = jeden pohovor** (kým nie je zrušený).
- **Čas sa overuje** v `book_appointment()` cez `booking_slots()`: mriežka,
  okno dostupnosti, voľno, buffer, min. predstih, horizont. Letný/zimný čas
  sedí (sloty sa generujú v lokálnom čase).
- `pending` staršie ako 10 min (spadnutá edge function) sa automaticky uvoľní.
- Neplatná časová zóna sa nedá uložiť.

Prístup (RLS):

| | anon | helper (`helpers.user_id = auth.uid()`) | admin |
| --- | --- | --- | --- |
| `booking_slots()` | ✓ (len čas + meno) | ✓ | ✓ |
| `helpers` | — | svoj riadok | všetko |
| `helper_availability`, `helper_time_off` | — | svoje: čítať/pridať/meniť/mazať | všetko |
| `appointments` | — | svoje: čítať, `status` → `completed`/`no_show`/`confirmed`, `helper_note` | čítať, to isté |
| `consultation_applications` | insert (dotazník) | dotazníky leadov s jeho pohovorom | všetko |
| `booking_settings` | čítať | čítať | meniť |
| rezervácia / zrušenie | `book-meeting` (token) | `cancel-meeting` | `cancel-meeting` |

## WEB — rezervácia pohovoru

### Krok 1 — token

Token je „heslo“ k prihláške pre krok 2. Anon nemôže prihlášku po inserte
prečítať (RLS), preto ho **vygeneruj v prehliadači** a pošli v inserte:

```ts
const token = [...crypto.getRandomValues(new Uint8Array(24))]
  .map((b) => b.toString(16).padStart(2, "0")).join("");
await supabase.from("consultation_applications").insert({ ...answers, token });
// token drž v stave / sessionStorage pre krok 2
```

### Krok 2 — voľné termíny

```ts
const { data: slots } = await supabase.rpc("booking_slots", {
  p_from: new Date().toISOString(),                 // voliteľné
  p_to: new Date(Date.now() + 21 * 864e5).toISOString(),
});
// [{ starts_at, ends_at, helper_id, helper_name }, …] — zoradené podľa času
```

- „Dátum a čas“: zoskup podľa `starts_at` (deň → časy). Formát ako v UI:
  `Intl.DateTimeFormat("sk-SK", { timeZone: "Europe/Bratislava", weekday: "long", day: "numeric", month: "long" })`
  → „utorok 6. októbra“, čas `hour: "numeric", minute: "2-digit"` → „9:00–10:00“.
- „S kým sa porozprávaš“: helperi s riadkom pre zvolený `starts_at` + voľba
  **„Ktokoľvek“** (`helper_id` vynechaj → najmenej vyťažený voľný helper).
- Dĺžku („60 MIN“) ber z `ends_at - starts_at` alebo `booking_settings.slot_minutes`.

### Potvrdiť termín

```ts
const { data, error } = await supabase.functions.invoke("book-meeting", {
  body: { token, starts_at: slot.starts_at, helper_id: chosenHelperId ?? undefined },
});
if (error) {
  const body = await error.context.json(); // { error, message, appointment? }
}
// data.appointment = { id, starts_at, ends_at, status: "confirmed", helper_name, meet_link }
```

| HTTP | `error` | Čo urobiť (`message` je pripravený text) |
| --- | --- | --- |
| 200 | — | zobraz potvrdenie + `meet_link` |
| 400 | `invalid_request` | chyba vo fronte |
| 404 | `application_not_found` | späť na dotazník |
| 403 | `not_qualified` | zobraz `message` |
| 409 | `already_booked` | zobraz existujúci termín z `appointment` (dvojklik / reload) |
| 409 | `slot_unavailable` | znova načítaj `booking_slots`, nech vyberie iný |
| 502 | `calendar_unavailable` | slot je uvoľnený, „skús znova“ |

Admin: správa `helpers` a `booking_settings`, prehľad `appointments` (dotazy ako v sekcii KLUB, bez filtra na helpera).

## KLUB — dostupnosť sprievodkýň

Sprievodkyne klubu vedú úvodné pohovory. Dostupnosť si nastavujú **samy v KLUBe**
(profilové menu → **Moja dostupnosť**); WEB z nej cez `booking_slots()` ponúka termíny.

**Kto:** používateľka s aktívnym členstvom `memberships.name = 'Sprievodkyňa klubu'`
(`status = 'active'`, `ends_at` je `NULL` alebo v budúcnosti). Dnes 7 používateliek,
manuálne, doživotné. Rola `leader` o tom **nerozhoduje** (časť lídriek nie sú
sprievodkyne a naopak).

### Backend doplnok — `supabase/web/migrations/5.sql` (⚠️ zatiaľ neimplementované)

| Čo | Správanie |
| --- | --- |
| `public.is_guide(_user_id uuid) → boolean` | `SECURITY DEFINER`; aktívne členstvo `Sprievodkyňa klubu` (rovnaká podmienka ako vyššie). |
| `public.ensure_my_helper() → public.helpers` | `SECURITY DEFINER`, `EXECUTE` pre `authenticated`. Pre `auth.uid()`: nie je sprievodkyňa → `NULL`. Má riadok v `helpers` → vráti ho. Existuje helper s rovnakým e-mailom bez `user_id` (pridaný cez `10-add-helper.sh`) → prepojí ho. Inak vytvorí `helpers(user_id, name = profiles.full_name, email = auth.users.email, active = true)`. |
| trigger na `memberships` | po INSERT/UPDATE/DELETE riadku `Sprievodkyňa klubu`: `helpers.active = is_guide(user_id)`. Keď členstvo skončí, sprievodkyňa sa prestane ponúkať (`booking_slots()` berie len `active`), jej dostupnosť ostane uložená. Dnešné členstvá sú doživotné; ak pribudnú časovo obmedzené, doplniť denný `pg_cron` sync. |
| RLS | **bez zmeny** — existujúce politiky (`helpers.user_id = auth.uid()`) už sprievodkyni dovolia spravovať svoju dostupnosť a voľno, len čo má riadok v `helpers`. |
| testy | doplniť do `supabase/web/tests/booking-test.sql`: nesprievodkyňa → `NULL`; sprievodkyňa → vytvorí raz (2. volanie vráti ten istý riadok); prepojenie podľa e-mailu; ukončené členstvo → `active = false` a zmizne z `booking_slots()`. |

### KLUB frontend

**1. Položka v profilovom menu** — zobraz len sprievodkyniam (vlastné členstvá
si používateľka číta cez existujúce RLS):

```ts
const { count } = await supabase
  .from("memberships")
  .select("id", { count: "exact", head: true })
  .eq("user_id", user.id)
  .eq("name", "Sprievodkyňa klubu")
  .eq("status", "active")
  .or(`ends_at.is.null,ends_at.gt.${new Date().toISOString()}`);
const isGuide = (count ?? 0) > 0;
```

**2. Stránka „Moja dostupnosť“** — pri otvorení:

```ts
const { data: me } = await supabase.rpc("ensure_my_helper"); // { id, name, … } | null
if (!me) return navigate("/profil");                            // nie je sprievodkyňa

const { data: settings } = await supabase.from("booking_settings")
  .select("slot_minutes, min_notice_minutes, horizon_days").single();
```

Úvodný text: *„Nastav si, kedy máš čas na úvodné pohovory so záujemkyňami.
Pohovor trvá {slot_minutes} min, záujemkyne si termín vyberajú najskôr
{min_notice_minutes/60} h a najneskôr {horizon_days} dní vopred.“*

**a) Týždenný rozvrh** — 7 riadkov **Po … Ne** (`day_of_week` 1 … 7), v každom
zoznam okien „od – do“, tlačidlo **+ Pridať čas**, pri okne **×**. Časy po 30 min
(select). Časová zóna je vždy `Europe/Bratislava` (default stĺpca — v UI ju nezobrazuj).

```ts
await supabase.from("helper_availability").select("id, day_of_week, start_time, end_time")
  .eq("helper_id", me.id).order("day_of_week").order("start_time");
await supabase.from("helper_availability").insert({ helper_id: me.id, day_of_week, start_time: "09:00", end_time: "12:00" });
await supabase.from("helper_availability").update({ start_time, end_time }).eq("id", rowId);
await supabase.from("helper_availability").delete().eq("id", rowId);
```

Validácia vo fronte (DB stráži len `koniec > začiatok` a deň 1–7):
- koniec musí byť po začiatku;
- okno kratšie ako `slot_minutes` nevytvorí žiadny termín → upozorni
  („Pohovor trvá 60 min, okno musí byť aspoň také dlhé.“);
- okná v jeden deň sa nesmú prekrývať — prekrývajúce zlúč alebo odmietni.

**b) Voľno / dovolenka** — zoznam budúcich blokov, pridanie „od dátumu – do
dátumu (vrátane)“, zmazanie. Celé dni v čase Bratislavy: `starts_at` = 00:00 prvého
dňa, `ends_at` = 00:00 dňa **po** poslednom dni.

```ts
await supabase.from("helper_time_off").select("id, starts_at, ends_at, note")
  .eq("helper_id", me.id).gte("ends_at", new Date().toISOString()).order("starts_at");
await supabase.from("helper_time_off").insert({ helper_id: me.id, starts_at, ends_at, note });
await supabase.from("helper_time_off").delete().eq("id", rowId);
```

**c) Náhľad „Takto ťa uvidia záujemkyne“** — najbližších 7 dní z rovnakého RPC
ako WEB (už zohľadňuje predstih, voľno aj obsadené termíny):

```ts
const { data } = await supabase.rpc("booking_slots", {
  p_to: new Date(Date.now() + 7 * 864e5).toISOString(),
});
const mine = (data ?? []).filter((s) => s.helper_id === me.id);
```

Prázdny náhľad → *„Zatiaľ ti nikto nemôže rezervovať termín — pridaj si
dostupnosť.“*

**3. Neskôr (2. fáza, po nasadení Google):** „Moje pohovory“ na tej istej stránke —
nadchádzajúce pohovory + dotazník leadky na prípravu, po pohovore
*Uskutočnený* / *Neprišla*, zrušenie cez `cancel-meeting`:

```ts
await supabase.from("appointments")
  .select("id, starts_at, ends_at, status, meet_link, helper_note, application:consultation_applications(*)")
  .eq("helper_id", me.id).in("status", ["confirmed", "completed", "no_show"]).order("starts_at");
await supabase.from("appointments").update({ status: "completed", helper_note }).eq("id", id); // alebo "no_show"
await supabase.functions.invoke("cancel-meeting", { body: { appointment_id: id, reason } });
```

## Nasadenie

1. **Migrácia:** `supabase/web/bin/08-apply-booking.sh`
2. **Helperi:** sprievodkyne sa po `5.sql` pridajú samy pri prvom otvorení
   „Moja dostupnosť“ v KLUBe. `10-add-helper.sh "Meno" email 1-5 09:00 12:00`
   len pre helperov mimo klubu (prepojí účet s rovnakým e-mailom).
3. **Google** (master účet, v ktorého kalendári budú pohovory):
   - Google Cloud Console → zapni *Google Calendar API*.
   - OAuth consent screen: Workspace → *Internal*; Gmail → *External* a
     **Publish → In production** (v režime *Testing* refresh token po 7 dňoch expiruje).
   - Credentials → OAuth client ID → *Desktop app*.
   - `GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… ./11-google-refresh-token.sh`
     → prihlás sa ako master účet → vypíše `GOOGLE_REFRESH_TOKEN`.
4. **Secrets:** `GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… GOOGLE_REFRESH_TOKEN=… BOOKING_ALLOWED_ORIGINS=https://trenerzien.sk,https://www.trenerzien.sk ./12-set-booking-secrets.sh`
5. **SmartEmailing** (keď budú prístupy): `SMARTEMAILING_USERNAME=… SMARTEMAILING_API_KEY=… SMARTEMAILING_SENDER_EMAIL=… SMARTEMAILING_REPLY_TO=podpora@trenerzien.sk ./12-set-booking-secrets.sh`
   — odosielateľ aj reply-to musia byť v SmartEmailingu overené. Bez nich
   rezervácia funguje, len sa nepošle e-mail (`appointments.email_error`).
6. **Deploy:** `09-deploy-booking.sh`

### Test po nasadení

```bash
curl -i -X POST https://<ref>.supabase.co/functions/v1/book-meeting -d '{}'   # → 400 invalid_request
```

Potom testovací dotazník → rezervácia → skontroluj udalosť v kalendári,
pozvánky, e-mail a `appointments`. Zruš cez `cancel-meeting` → udalosť zmizne,
slot je znova v `booking_slots()`.

## Prevádzka

```sql
-- nadchádzajúce pohovory
select a.starts_at at time zone 'Europe/Bratislava' as kedy, h.name as helper, c.name, c.email, a.status, a.meet_link, a.email_error
from appointments a join helpers h on h.id = a.helper_id join consultation_applications c on c.id = a.application_id
where a.starts_at > now() and a.status = 'confirmed' order by a.starts_at;
```

- Logy: Dashboard → Edge Functions → `book-meeting` (`[book]`, `[google]`, `[email]`).
- `calendar_error: … invalid_grant` v `cancel_reason` → refresh token zneplatnený
  → znova `11-google-refresh-token.sh` + `12-set-booking-secrets.sh`.
- Zmena dĺžky / predstihu: `update booking_settings set …` (bez deployu).

## Testy

`supabase/web/tests/booking-test.sh` — lokálny dočasný Postgres (nie Supabase):
migrácia 2× (re-runnable), sloty, letný čas, všetky odmietnutia, constraint,
voľno, buffer, expirácia `pending`, RLS pre anon / helpera / cudzieho / admina
a 30 súbežných rezervácií (presne 2 na slot, bez deadlockov).

## Ďalej (nie je súčasťou)

- Pripomienka 24 h vopred (pg_cron + pg_net → SmartEmailing).
- Zrušenie / presun leadom cez odkaz s tokenom (zatiaľ e-mailom na podporu).
- Kontrola obsadenosti v osobných kalendároch helperov (Google freeBusy).
- Ochrana formulára pred botmi (Cloudflare Turnstile) pri raste návštevnosti.
