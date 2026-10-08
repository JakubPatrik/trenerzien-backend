# Nová rola „Personalistka“ — zmeny v KLUBe

V KLUBe pribúda rola **Personalistka**. Iba personalistky vedú úvodné pohovory,
preto iba ony si nastavujú voľné termíny na stránke **Moja dostupnosť**
(`/dostupnost`). **Sprievodkyne k tejto stránke už prístup nemajú.**

Pri mene v členskej sekcii má personalistka písmenko **P**. Písmenká sú ako
hodnosti a dajú sa kombinovať, jedna žena môže mať aj všetky:

| Písmenko | Význam | Odkiaľ sa berie |
| --- | --- | --- |
| **RL** | Legionárna líderka | rola `leader` |
| **Z** | Zakladateľka | `profiles.founder_at` |
| **S** | Sprievodkyňa | aktívne členstvo `Sprievodkyňa klubu` |
| **P** | Personalistka | rola `personalistka` (**nová**) |

Backend (migrácia `6.sql`) je hotový, mení sa len frontend. Nové tabuľky ani migrácie
nevytváraj.

---

## 0. Čo je nové v databáze (len na čítanie, nič nevytváraj)

- Enum `app_role` má novú hodnotu **`'personalistka'`**. Uloží sa ako riadok v
  `user_roles` (rovnako ako `leader`), **nie** ako členstvo v `memberships`.
- RPC **`is_recruiter(_user_id uuid) → boolean`** vráti, či je používateľka personalistka.
- RPC **`member_badges() → table(user_id uuid, badges text[])`** vráti písmenká
  pre všetky ženy, ktoré majú aspoň jedno. Poradie je vždy `RL`, `Z`, `S`, `P`.
  Ženy bez písmenka v ňom nie sú.
- Admin smie v `user_roles` pridať alebo zmazať **len** rolu `personalistka`.
  Iné roly mu RLS nedovolí meniť.
- Neaktívna helperka (napr. sprievodkyňa) už nemôže zapisovať do
  `helper_availability` ani do `helper_time_off`. RLS to odmietne.

Najprv obnov typy:

```bash
bunx supabase gen types typescript --project-id eyxmuzfbtdaqtfzyaoqb > src/integrations/supabase/types.ts
```

---

## 1. „Moja dostupnosť“: len pre personalistky

Dnes sa položka v profilovom menu aj stránka `/dostupnost` zobrazujú podľa
členstva `Sprievodkyňa klubu`. Nájdi tú podmienku. Pravdepodobne je to dotaz na
`memberships` s `.eq("name", "Sprievodkyňa klubu")` alebo `isGuide` či
`is_guide`. **Nahraď ju** týmto:

```ts
const { data: isRecruiter } = await supabase.rpc("is_recruiter", { _user_id: user.id });
```

- Položka **Moja dostupnosť** v profilovom menu sa zobrazí, len ak `isRecruiter === true`.
- Route guard na `/dostupnost`: ak používateľka nie je personalistka (a nie je
  admin), presmeruj ju preč, rovnako ako dnes pri nečlenke.
- Na stránke ostáva načítanie helpera bez zmeny:
  `supabase.from("helpers").select("id, active").eq("user_id", user.id).maybeSingle()`.
  Ak je výsledok `null` alebo `active === false`, zobraz text
  *„Účet personalistky ešte nie je nastavený, napíš podpore.“*
- V texte stránky a menu prepíš „sprievodkyňa“ na „personalistka“, ak sa
  tam to slovo vyskytuje (nadpisy, popisy, prázdne stavy, chybové hlášky).
- `is_guide` / členstvo `Sprievodkyňa klubu` **nepoužívaj** na nič, čo súvisí s
  dostupnosťou alebo pohovormi. Ostáva len pre písmenko **S**.

---

## 2. Písmenká pri mene v členskej sekcii (RL, Z, S, P)

Načítaj písmenká **raz** pre celú členskú sekciu a namapuj ich podľa `user_id`:

```ts
const { data } = await supabase.rpc("member_badges");
const badgesByUser = new Map((data ?? []).map((r) => [r.user_id, r.badges as string[]]));
// badgesByUser.get(member.id) → napr. ["RL", "Z", "P"] alebo undefined
```

- Písmenká zobraz **hneď za menom** všade, kde sa v členskej sekcii zobrazuje meno
  ženy: zoznam členiek / adresár (`member_directory`), detail profilu, popup na
  mape a ďalšie miesta, kde už dnes svieti RL alebo Z.
- Každé písmenko je samostatný malý odznak (badge/pill) a odznaky idú v poradí z RPC.
  Pri hoveri (alebo tapnutí na mobile) ukáž tooltip s plným názvom:
  `RL` → Legionárna líderka, `Z` → Zakladateľka, `S` → Sprievodkyňa, `P` → Personalistka.
- Ak už dnes niekde počítaš písmenká inak (napr. RL cez `regional_leaders()` a
  Z cez `founder_at`), **nahraď to** zdrojom `member_badges()`. Bude jediný
  zdroj pre všetky štyri písmenká a písmenká sa nebudú líšiť medzi stránkami.
  `regional_leaders()` nemaž. Môže ostať tam, kde sa používa na iné účely
  (napr. zoznam líderiek podľa regiónu).
- Vzhľad nových odznakov **S** a **P** zladi s existujúcimi **RL** a **Z**.
  Rovnaká veľkosť a štýl, nový dizajn nevymýšľaj.
- Ak žena nemá žiadne písmenko, nezobrazuj nič (žiadny prázdny odznak).

---

## 3. Admin: nastavenie personalistky

V admin detaile členky (alebo v admin zozname členiek) pridaj prepínač
**„Personalistka“**. Zobrazí sa len adminom (`has_role(…, 'admin')` / existujúci
admin check).

```ts
// stav
const { data: roles } = await supabase.from("user_roles").select("role").eq("user_id", memberId);
const isRecruiter = roles?.some((r) => r.role === "personalistka") ?? false;

// zapnúť
await supabase.from("user_roles").insert({ user_id: memberId, role: "personalistka" });
// vypnúť
await supabase.from("user_roles").delete().eq("user_id", memberId).eq("role", "personalistka");
```

- Chybu `23505` (rolu už má) pri zapínaní ignoruj.
- Po zmene obnov písmenká (`member_badges`) a stav prepínača.
- O ostatné veci sa postará databáza. Personalistke sa automaticky vytvorí alebo
  aktivuje účet na pohovory. Po odobratí roly sa deaktivuje. Jej uložená
  dostupnosť ostane, len sa na webe prestane ponúkať. Už rezervované pohovory
  sa nerušia.
- Iné roly (admin, leader) cez tento prepínač **neponúkaj**. Databáza by ich
  zmenu aj tak odmietla.

---

## 4. Čo nerobiť

- Nevytváraj členstvo „Personalistka“ v `memberships`. Personalistka je rola v
  `user_roles`, nie členstvo.
- Nevytváraj nové tabuľky, stĺpce, RLS politiky ani SQL migrácie. Backend je hotový.
- Nemeň WEB rezerváciu (`booking_slots`, `book-meeting`). Ponuka termínov sa
  prepne sama podľa toho, kto je personalistka.

---

## 5. Kontrola po implementácii

- [ ] Sprievodkyňa **bez** roly personalistka nevidí v menu „Moja dostupnosť“.
      Pri priamom otvorení `/dostupnost` ju appka presmeruje.
- [ ] Personalistka vidí „Moja dostupnosť“, zapne slot a slot sa uloží.
- [ ] Admin zapne členke prepínač „Personalistka“. Členka potom po
      obnovení stránky vidí „Moja dostupnosť“ a pri mene má **P**.
- [ ] Admin prepínač vypne. **P** zmizne a „Moja dostupnosť“ sa jej skryje.
- [ ] Žena s viacerými hodnosťami má odznaky v poradí `RL Z S P` (napr. `Z S P`).
- [ ] Písmenká sú rovnaké v zozname členiek, na detaile profilu aj na mape.
- [ ] `types.ts` je obnovený a `app_role` obsahuje `"personalistka"`.
