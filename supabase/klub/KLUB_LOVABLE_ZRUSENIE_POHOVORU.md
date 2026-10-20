# Moja dostupnosť: personalistka môže zrušiť pohovor

Na stránke **Moja dostupnosť** (`/dostupnost`) personalistka vidí svoje rezervované
pohovory. Pri každom budúcom pohovore pribudne tlačidlo **„Zrušiť pohovor“** s
potvrdzovacím dialógom.

Backend je hotový: edge function `cancel-meeting` (už nasadená). Mení sa len frontend.
Nové tabuľky, politiky, edge functions ani SQL migrácie nevytváraj.

---

## 0. Čo je v backende (len na čítanie)

```ts
const { data, error } = await supabase.functions.invoke("cancel-meeting", {
  body: { appointment_id: appointment.id, reason: "…" }, // reason je nepovinný
});
// úspech: data = { cancelled: true }
```

- Volá sa s reláciou prihlásenej personalistky (`supabase.functions.invoke` pridá jej
  token sám). Service-role kľúč nepoužívaj.
- Personalistka smie zrušiť **len svoj** pohovor, ktorý je **potvrdený** (`status = 'confirmed'`)
  a **ešte nezačal**. Ostatné backend odmietne.
- Po zrušení: Google udalosť sa zmaže (klientka aj personalistka dostanú od Googlu e-mail
  o zrušení), pohovor má `status = 'cancelled'` a termín sa na webe znova ponúka.
- Admin smie zrušiť ktorýkoľvek pohovor rovnakým volaním (ak to už v admin časti je, nič nemeň).

---

## 1. Tlačidlo v zozname pohovorov

V zozname rezervovaných pohovorov na `/dostupnost` (tam, kde je dátum, čas a meno klientky):

- Pri pohovore, kde `status === "confirmed"` a `starts_at` je v budúcnosti, zobraz
  tlačidlo **„Zrušiť pohovor“** (sekundárne / textové, červené ako destruktívna akcia).
  Zlaď ho s existujúcimi tlačidlami, nový dizajn nevymýšľaj.
- Pri minulých a už zrušených pohovoroch tlačidlo nezobrazuj.

## 2. Potvrdzovací dialóg

Po kliknutí otvor dialóg:

- Nadpis: **„Zrušiť pohovor?“**
- Text: *„Pohovor s {meno klientky} {deň} o {čas} sa zruší. Klientka dostane e-mail o
  zrušení a termín sa znova uvoľní. Túto akciu nejde vrátiť späť.“*
- Nepovinné pole **„Dôvod (uvidí ho len admin)“**, max. 500 znakov → `reason`.
- Tlačidlá: **„Späť“** a **„Zrušiť pohovor“** (destruktívne).
- Kým volanie beží, tlačidlá vypni (žiadny dvojklik).

## 3. Výsledok

- Úspech (`data.cancelled === true`): zavri dialóg, pohovor zo zoznamu odstráň (alebo
  znova načítaj zoznam) a zobraz toast *„Pohovor je zrušený.“*
- Chyba: `supabase.functions.invoke` vráti `error`. Kód chyby prečítaj z tela odpovede
  (`await error.context.json()` → `{ error }`) a zobraz toast:

| `error` | Toast |
| --- | --- |
| `already_started` | „Pohovor už začal, nedá sa zrušiť.“ |
| `not_active` | „Pohovor už je zrušený.“ (a znova načítaj zoznam) |
| `forbidden` | „Tento pohovor nemôžeš zrušiť.“ |
| `calendar_unavailable` | „Nepodarilo sa zrušiť, skús to o chvíľu znova.“ |
| iné | „Nepodarilo sa zrušiť, skús to znova.“ |

---

## 4. Čo nerobiť

- Nemeň `appointments` priamo (`update status = 'cancelled'`). Google udalosť by ostala
  a klientka by sa o zrušení nedozvedela. Vždy len cez `cancel-meeting`.
- Neponúkaj zrušenie pri nepotvrdených termínoch. Personalistka ich ani nevidí.

---

## 5. Kontrola po implementácii

- [ ] Personalistka vidí pri budúcom potvrdenom pohovore „Zrušiť pohovor“, pri minulom nie.
- [ ] Po potvrdení dialógu pohovor zmizne a ukáže sa toast.
- [ ] Google udalosť zmizla z kalendára a klientka dostala e-mail o zrušení.
- [ ] Termín sa na webe (`/pohovor/termin`) znova ponúka.
- [ ] „Späť“ v dialógu nič nezruší.
