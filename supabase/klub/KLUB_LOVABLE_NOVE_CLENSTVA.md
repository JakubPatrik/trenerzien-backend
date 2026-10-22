# Členstvá: zobraz aj nové platené členstvá

Na admin stránke **Členstvá** („Profily a členstvá žien v klube.“) chýbajú ženy s novými
platenými členstvami zo Stripe. Nenájde ich ani vyhľadávanie podľa e-mailu vo filtri
„Všetky ženy“ (napr. `michalcova.jana@gmail.com`). Dôvod: stránka berie do klubu len
natvrdo zapísaný zoznam názvov členstiev a nové názvy v ňom nie sú.

Mení sa len frontend. Nové tabuľky, politiky, edge functions ani SQL migrácie nevytváraj.

---

## 0. Čo je v backende (len na čítanie)

Tabuľka `memberships` — jedna žena môže mať viac riadkov (aj iné produkty, napr. „Koučing“,
„Výzva“, „Generátor“ — tie **nie sú** členstvo v klube).

Členstvá v klube (`memberships.name`), presne takto vrátane dlhej pomlčky „—“:

| `name` | typ |
|---|---|
| `Zakladateľské členstvo — mesačné` | zakladateľské |
| `Zakladateľské členstvo — ročné` | zakladateľské |
| `Zakladateľské členstvo — prevodom` | zakladateľské |
| `Členstvo — mesačné` | **nové** (Stripe, od 10/2026) |
| `Členstvo — štvrťročné` | **nové** (Stripe, od 10/2026) |
| `Členstvo — ročné` | **nové** (Stripe, od 10/2026) |

- `status`: `active` / `paused` / `ended`; `ends_at` = do kedy je zaplatené
  (`null` = doživotne); `source = 'stripe'` pri nákupoch cez Stripe.
- **Sprievodkyňa klubu nie je členstvo, ale rola:** `user_roles.role = 'sprievodkyna'`
  (funkcia `public.is_guide()`, odznak „S“). Staré riadky `memberships` s
  `name = 'Sprievodkyňa klubu'` sú zmazané (prevedené na rolu) — ak sa niekde v kóde
  na tento názov odkazuje, odstráň to.
- Databázová funkcia `public.is_club_member()` (prístup do KLUBu) berie členstvá z tabuľky
  vyššie + roly `admin`, `lider`, `personalistka`, `sprievodkyna`. Nové členky teda do KLUBu
  prístup **majú**, chýbajú len v admin prehľade.
- Zakladateľka = `profiles.founder_at is not null` (odznak „Z“). Nové členstvá **nie sú**
  zakladateľské — `founder_at` im nenastavuj.
- Vyplnený osobný profil = `profiles.profile_completed_at is not null`.

---

## 1. Jeden zoznam členstiev klubu

- Nájdi v kóde **všetky** miesta, kde je natvrdo zoznam názvov členstiev klubu
  (hľadaj `Zakladateľské členstvo`, `Sprievodkyňa klubu`) — stránka Členstvá, jej počty,
  filtre, vyhľadávanie, export, prípadne iné admin prehľady.
- Nahraď ich **jednou** zdieľanou konštantou (napr. `src/lib/clubMemberships.ts`)
  so všetkými 6 názvami z tabuľky vyššie a všade importuj ju. `Sprievodkyňa klubu`
  do nej **nedávaj**.
- Sprievodkyne (a ostatné roly) ber z `user_roles`, nie z `memberships`. Sprievodkyňa
  patrí medzi ženy v klube aj bez platného členstva.
- Ostatné pravidlá stránky (ktoré stavy sa rátajú, bývalé členky cez
  `profiles.membership_ends_on`) nemeň — len rozšír zoznam názvov.

## 2. Čo stránka zobrazí

- **Karta „Členky v klube“** — započíta aj ženy s novými členstvami (jedna žena = 1,
  aj keď má viac riadkov v `memberships`).
- **„Vyplnený osobný profil“** — z toho istého rozšíreného okruhu žien.
- **„Zakladateľky“** — bez zmeny (`founder_at`), nové členky sa sem nepridajú.
- **Riadok členky** — pri každej žene zobraz jej aktuálne členstvo v klube:
  - štítok s typom: „Zakladateľské — mesačné“, „Zakladateľské — ročné“,
    „Zakladateľské — prevodom“, „Mesačné“, „Štvrťročné“, „Ročné“ (ak má viac, ukáž to
    s najneskorším `ends_at`),
  - stav (`Aktívne` / `Pozastavené` / `Ukončené`) a „platí do {ends_at}“ (d. M. yyyy),
    pri `ends_at = null` „bez obmedzenia“,
  - sprievodkyňa bez členstva: štítok „Bez členstva“ a odznak „S“ z roly (nie z `memberships`).
- **Filtre** — existujúce (Všetky ženy / Profil vyplnený / Profil chýba / Zakladateľky)
  nechaj a pridaj **„Nové členstvá“** = ženy s členstvom `Členstvo — mesačné | štvrťročné | ročné`.
- **Vyhľadávanie** — hľadá v mene aj v e-maile (`profiles.email`). Nové členky majú
  často ako meno časť e-mailu (napr. „michalcova.jana“), kým si nevyplnia profil.

---

## Kontrola

- [ ] Vo „Všetky ženy“ vyhľadaj `michalcova.jana@gmail.com` → nájde ju, štítok „Mesačné“,
      Aktívne, platí do 21. 11. 2026, profil chýba.
- [ ] `hasarova@gmail.com` → „Štvrťročné“, platí do 20. 1. 2027.
- [ ] `ivka.brunova@gmail.com` → „Ročné“, profil vyplnený.
- [ ] „Členky v klube“ stúpne o 5 (dnešné nové členky), „Zakladateľky“ ostane 76.
- [ ] Filter „Nové členstvá“ ukáže 5 žien: michalcova.jana, hasarova, anna.svarna,
      trnovcova.julia, ivka.brunova.
- [ ] Ženy len s „Koučing“ / „Výzva“ / „Generátor“ sa na stránke **neobjavia**.
- [ ] Nikde sa nezobrazí „Sprievodkyňa klubu“ ako typ členstva; sprievodkyne majú odznak
      „S“ podľa roly (8 žien s rolou `sprievodkyna`).
