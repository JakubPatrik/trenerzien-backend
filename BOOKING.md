# Rezervácia pohovoru — backend

Krok 2 po dotazníku (`consultation_applications`): lead si vyberie termín
(60 min) a s kým sa porozpráva; vznikne Google Meet v kalendári master účtu,
pozvánka ide leadovi aj helperovi a lead dostane potvrdenie zo SmartEmailingu.

Dve aplikácie, jeden Supabase projekt:

| Aplikácia | Čo v nej žije |
| --- | --- |
| **WEB** (trenerzien.sk) | dotazník + výber termínu + potvrdenie — [WEB](#web--rezervácia-pohovoru) |
| **KLUB** | sprievodkyne (`Sprievodkyňa klubu`) si nastavujú dostupnosť na mesiac dopredu — [KLUB](#klub--dostupnosť-sprievodkýň) |

```
krok 1 dotazník ──insert (s tokenom)──▶ consultation_applications
krok 2 výber    ──rpc booking_slots()──▶ voľné termíny (helper × čas)
       potvrdiť ──POST book-meeting────▶ book_appointment()  ── 'pending' (DB zamkne slot)
                                         Google Calendar       ── udalosť + Meet link, pozvánky
                                         appointments          ── 'confirmed'
                                         SmartEmailing         ── potvrdzovací e-mail
helper / admin  ──POST cancel-meeting──▶ zmaže udalosť (Google pošle zrušenie), slot sa uvoľní

memberships 'Sprievodkyňa klubu' ──trigger──▶ helpers (vytvorí / active)
KLUB sprievodkyňa ──insert/delete slot (date)──▶ helper_availability ──▶ booking_slots() na WEBe
```

| Čo | Kde |
| --- | --- |
| Schéma, RPC, RLS | `supabase/web/migrations/4.sql` + `5.sql` (KLUB sprievodkyne, dátumová dostupnosť) |
| Edge functions | `supabase/functions/book-meeting/`, `cancel-meeting/`, `_shared/` |
| Skripty | `supabase/web/bin/08–12-*.sh`, `14-sync-guide-helpers.sh` |
| Testy (lokálny Postgres) | `supabase/web/tests/booking-test.sh` |

## Dátový model

| Tabuľka | Obsah |
| --- | --- |
| `helpers` | kto vedie pohovory; `user_id` → prihlásenie helpera, `email` → pozvánka |
| `helper_availability` | `date` (konkrétny deň, KLUB) **alebo** týždenné `day_of_week` ISO **1 = pondelok … 7 = nedeľa**; `timezone` (default `Europe/Bratislava`) |
| `helper_time_off` | dovolenka / voľno (`starts_at`–`ends_at`), blokuje sloty |
| `booking_settings` | 1 riadok: `slot_minutes` 60, `slot_step_minutes` 60, `buffer_minutes` 0, `min_notice_minutes` 1440 (24 h), `horizon_days` 31 |
| `appointments` | `pending → confirmed → completed / no_show`, alebo `cancelled` |

Záruky v databáze:

- **Žiadna dvojitá rezervácia** — `EXCLUDE` constraint (helper × časový rozsah)
  pre `pending`/`confirmed` + `book_appointment()` beží pod zámkom.
- **Jedna prihláška = jeden pohovor** (kým nie je zrušený).
- **Čas sa overuje** v `book_appointment()` cez `booking_slots()`: mriežka,
  okno dostupnosti, voľno, buffer, min. predstih, horizont. Letný/zimný čas
  sedí (sloty sa generujú v lokálnom čase).
- Dátumová dostupnosť len od dnes do dnes + `horizon_days`.
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
(profilové menu → **Moja dostupnosť**, `/dostupnost`) **na najbližší mesiac, po
jednotlivých hodinových slotoch**; WEB z nej cez `booking_slots()` ponúka termíny.

**Kto:** používateľka s aktívnym členstvom `memberships.name = 'Sprievodkyňa klubu'`
(`status = 'active'`, `ends_at` je `NULL` alebo v budúcnosti). Dnes 7 používateliek,
manuálne, doživotné. Rola `leader` o tom **nerozhoduje** (časť lídriek nie sú
sprievodkyne a naopak).

### Backend — `supabase/web/migrations/5.sql`

| Čo | Správanie |
| --- | --- |
| `helper_availability.date` | Riadok má **buď** `date` (KLUB: jeden slot v konkrétny deň, Bratislava), **alebo** `day_of_week` (týždenné okno, `10-add-helper.sh`). Unikátne `(helper_id, date, start_time)`. Trigger: `date` len od dnes do dnes + `horizon_days`, inak `check_violation` „availability date … is outside …“. |
| `booking_slots()` | ponúka sloty z oboch druhov riadkov; riadok 09:00–10:00 = presne jeden 60-min termín |
| `is_guide(uuid)` | aktívne členstvo `Sprievodkyňa klubu` |
| trigger `sync_guide_helper` na `memberships` | zmena členstva `Sprievodkyňa klubu` → `sync_guide_helper(user_id)`: sprievodkyňa bez riadku v `helpers` → vytvorí (`name` = `profiles.full_name`, `email` z `auth.users`; helpera s rovnakým e-mailom bez konta prepojí). Členstvo skončilo / zmazané → `active = false` (dostupnosť ostane, `booking_slots()` ju neponúka). Pri nasadení sa spustí pre dnešné sprievodkyne. Dnešné členstvá sú doživotné; ak pribudnú časovo obmedzené, doplniť denný `pg_cron`. |
| `booking_settings.horizon_days` | 21 → **31** |
| RLS | bez zmeny — sprievodkyňa číta svoj riadok v `helpers` a spravuje svoju `helper_availability` (`helpers.user_id = auth.uid()`). |

### KLUB frontend

**1. Položka v profilovom menu** — len sprievodkyniam:

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
const { data: helper } = await supabase.from("helpers").select("id").eq("user_id", user.id).maybeSingle();
// null → „Účet sprievodkyne ešte nie je nastavený, napíš podpore.“
```

Pás dátumov **zajtra … dnes + 30 dní**, pri výbere dňa hodinové sloty
**07:00–21:00** ako prepínacie čipy (zapnutý = dostupná):

```ts
await supabase.from("helper_availability").select("id, date, start_time")
  .eq("helper_id", helper.id).gte("date", tomorrow).lte("date", todayPlus30);
await supabase.from("helper_availability")
  .insert({ helper_id: helper.id, date: "2026-10-12", start_time: "09:00", end_time: "10:00" }); // zapnúť
await supabase.from("helper_availability").delete().eq("id", rowId);                            // vypnúť
```

`date` je lokálny dátum `YYYY-MM-DD`; `timezone` ani `day_of_week` neposielaj.
Chyba `23505` (dvojklik) = slot už je zapnutý — ignoruj. Vypnutie slotu
**neruší** už rezervovaný pohovor.

**3. Neskôr (2. fáza, po nasadení Google):** „Moje pohovory“ na tej istej stránke —
nadchádzajúce pohovory + dotazník leadky na prípravu, po pohovore
*Uskutočnený* / *Neprišla*, zrušenie cez `cancel-meeting`:

```ts
await supabase.from("appointments")
  .select("id, starts_at, ends_at, status, meet_link, helper_note, application:consultation_applications(*)")
  .eq("helper_id", helper.id).in("status", ["confirmed", "completed", "no_show"]).order("starts_at");
await supabase.from("appointments").update({ status: "completed", helper_note }).eq("id", id); // alebo "no_show"
await supabase.functions.invoke("cancel-meeting", { body: { appointment_id: id, reason } });
```

## Nasadenie

1. **Migrácia:** `supabase/web/bin/08-apply-booking.sh` (4.sql + 5.sql)
2. **Helperi:** sprievodkyne (`Sprievodkyňa klubu`) vzniknú automaticky z členstva
   (5.sql ich pri nasadení doplní, potom trigger). Kontrola / oprava:
   `14-sync-guide-helpers.sh`.
   `10-add-helper.sh "Meno" email 1-5 09:00 12:00` len pre helperov mimo klubu
   (týždenné okná; prepojí účet s rovnakým e-mailom).
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
migrácie 4→5→4→5 (re-runnable), sloty, letný čas, všetky odmietnutia, constraint,
voľno, buffer, expirácia `pending`, RLS pre anon / helpera / cudzieho / admina
a 30 súbežných rezervácií (presne 2 na slot, bez deadlockov). `booking-guides-test.sql`:
členstvo → helper (raz, prepojenie e-mailom, deaktivácia), dátumové sloty
(RLS, duplicita, rozsah dátumu), rezervácia dátumového slotu.

## Ďalej (nie je súčasťou)

- Pripomienka 24 h vopred (pg_cron + pg_net → SmartEmailing).
- Zrušenie / presun leadom cez odkaz s tokenom (zatiaľ e-mailom na podporu).
- Kontrola obsadenosti v osobných kalendároch helperov (Google freeBusy).
- Ochrana formulára pred botmi (Cloudflare Turnstile) pri raste návštevnosti.
