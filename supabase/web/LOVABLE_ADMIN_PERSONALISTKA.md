# Admin → Používatelia: akcia „Personalistka“

Na stránke **`/admin/users`** pridaj adminovi akciu, ktorou členke **pridá** alebo
**odoberie** rolu **Personalistka**. Personalistka vedie úvodné pohovory a nastavuje si
termíny na stránke „Moja dostupnosť“.

Backend je hotový: dve RPC (migrácia `7.sql`). Mení sa len frontend. Nové tabuľky,
politiky, edge functions ani SQL migrácie nevytváraj.

---

## 0. Čo je v databáze (len na čítanie)

```ts
supabase.rpc("add_recruiter",    { p_email: string }) // pridá rolu
supabase.rpc("remove_recruiter", { p_email: string }) // odoberie rolu
// data: { user_id, email, full_name, is_recruiter: boolean, helper_active: boolean | null }
```

- Volať ich smie **len prihlásený admin**. Ostatným vráti chybu `forbidden`.
- Hľadá účet podľa e-mailu. Nájde ho aj podľa starého e-mailu, na ktorý sa
  žena kedysi prihlasovala. Na veľkých/malých písmenách a medzerách nezáleží.
- Volanie viackrát po sebe nevadí: `add_recruiter` pri existujúcej personalistke nič
  nezmení a vráti rovnaký výsledok.
- Databáza sa postará o zvyšok. Pri pridaní vytvorí alebo aktivuje účet na pohovory.
  Pri odobratí ho deaktivuje: uložená dostupnosť ostane a už rezervované pohovory sa nerušia.
- Rola sa ukladá v `user_roles` (`role = 'personalistka'`). Nie je to členstvo v `memberships`.

Najprv obnov typy, aby `rpc("add_recruiter")` bolo typované:

```bash
bunx supabase gen types typescript --project-id eyxmuzfbtdaqtfzyaoqb > src/integrations/supabase/types.ts
```

---

## 1. Stav v zozname

Načítaj personalistky **raz** pre celý zoznam (admin smie čítať všetky riadky `user_roles`):

```ts
const { data } = await supabase.from("user_roles").select("user_id").eq("role", "personalistka");
const recruiterIds = new Set((data ?? []).map((r) => r.user_id));
```

- Pri používateľke, ktorá je v `recruiterIds`, zobraz v riadku malý odznak **P**
  (tooltip „Personalistka“). Zlaď ho s ostatnými odznakmi či štítkami v tabuľke, nový
  dizajn nevymýšľaj.

---

## 2. Akcia v riadku

Do existujúceho menu akcií v riadku (tam, kde je napr. „Pozvať“) pridaj položku:

- **„Nastaviť ako personalistku“**, ak používateľka nie je personalistka,
- **„Odobrať rolu personalistky“**, ak už je.

```ts
const fn = isRecruiter ? "remove_recruiter" : "add_recruiter";
const { data, error } = await supabase.rpc(fn, { p_email: user.email });
```

- Pred odobratím zobraz potvrdzovací dialóg: *„Odobrať rolu personalistky? Jej termíny
  sa prestanú ponúkať na webe, už rezervované pohovory ostanú.“* Pri pridaní dialóg netreba.
- Kým volanie beží, položku vypni (žiadny dvojklik).
- Po úspechu aktualizuj `recruiterIds` podľa `data.is_recruiter` (alebo znova načítaj)
  a zobraz toast:
  - pridanie: *„{meno alebo e-mail} je personalistka.“*
  - odobratie: *„{meno alebo e-mail} už nie je personalistka.“*
- Chyby (`error.message`) zobraz v toaste:
  - `forbidden` → *„Na túto akciu nemáš oprávnenie.“*
  - `user_not_found` → *„Účet s týmto e-mailom neexistuje.“*
  - iné → *„Nepodarilo sa uložiť, skús to znova.“*
- Položku zobraz **len adminom** (existujúci admin check pre `/admin/users`).

Ak už v appke existuje prepínač „Personalistka“ zo staršieho zadania, ktorý priamo
zapisuje do `user_roles` (`insert` / `delete`), **prepni ho na tieto RPC**. Nevytváraj
druhý prepínač.

---

## 3. Čo nerobiť

- Nevkladaj ani nemaž riadky v `user_roles` priamo. Používaj len `add_recruiter` /
  `remove_recruiter`.
- Neponúkaj touto akciou iné roly (admin, lider).
- Nezakladaj nový účet, ak e-mail neexistuje. Účty vznikajú cez Stripe alebo pozvánku.
- Nevolaj RPC so service-role kľúčom ani z edge function. Volá sa s reláciou prihláseného admina.

---

## 4. Kontrola po implementácii

- [ ] Admin v `/admin/users` nastaví členku ako personalistku. Zobrazí sa toast a
      v riadku odznak **P**.
- [ ] Po obnovení stránky odznak **P** ostáva.
- [ ] Členka po prihlásení vidí v KLUBe „Moja dostupnosť“.
- [ ] Admin rolu odoberie (s potvrdením). **P** zmizne.
- [ ] Ne-admin akciu nevidí. Aj pri priamom volaní dostane `forbidden`.
- [ ] `types.ts` je obnovený a obsahuje `add_recruiter` a `remove_recruiter`.
