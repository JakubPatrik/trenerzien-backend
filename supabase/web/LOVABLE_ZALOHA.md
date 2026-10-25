# Pohovor: záloha 100 € pred výberom termínu

Medzi dotazník a výber termínu pribúda platba **vratnej zálohy 100 €**. Termín si
žena vyberie až po zaplatení. Dôvod: chodí nám veľa nekvalifikovaných prihlášok.

Na platbu použi **existujúcu platobnú stránku** pre produkt „Vratná záloha za vstupný
nezáväzný pohovor“ (Stripe lookup key `vstupny_pohovor_zaloha_100`, 100 €). Backend
platbu zachytí cez Stripe webhook a `book-meeting` bez nej termín nerezervuje.
Nevytváraj edge functions, tabuľky ani SQL migrácie.

---

## 0. Nový priebeh

| Krok | Stránka | Hlavička | Zmena |
| --- | --- | --- | --- |
| 1 | `/pohovor` dotazník | **1/4** | po odoslaní choď na platbu zálohy (doteraz `/pohovor/termin`) |
| 2 | platba zálohy (existujúca stránka) | **2/4** | po zaplatení → `/pohovor/termin`, pri zrušení späť na krok 2 |
| 3 | `/pohovor/termin` výber termínu | **3/4** | nová chyba `deposit_required` (sekcia 2) |
| 4 | `/pohovor/potvrdenie` potvrď e-mail | **4/4** | len číslo kroku |
| – | `/pohovor/dakujem?t=` | – | bez zmeny |

Počítadlo krokov v hlavičke funnelu zmeň na **1/4 … 4/4**.

---

## 1. Platba: token dotazníka do Stripe (povinné)

Backend spáruje platbu s prihláškou **len podľa tokenu dotazníka** (ten istý, ktorý sa
posiela v inserte a ktorý číta `/pohovor/termin`). Pošli ho do Stripe ako
**`client_reference_id`**:

- Checkout Session: `client_reference_id: token`
- Payment Link: `…?client_reference_id=<token>&prefilled_email=<email>`

Bez `client_reference_id` sa platba k prihláške nepriradí a žena si termín nevyberie.

- Úspešná platba → `/pohovor/termin`
- Zrušená platba → späť na stránku zálohy

**Text na stránke zálohy:** zálohu ti po pohovore vrátime celú.

---

## 2. `/pohovor/termin`: zaplatená záloha

`book-meeting` vráti novú chybu, keď záloha nie je zaplatená:

| HTTP | `error` | Čo urobiť |
| --- | --- | --- |
| 402 | `deposit_required` | namiesto potvrdenia zobraz chybový box (nižšie); `message` je pripravený text |

Chybový box:

> **Záloha zatiaľ nie je uhradená**
>
> Platba neprebehla alebo bola zamietnutá. Termín si vyberieš hneď po zaplatení zálohy.
>
> [Zaplatiť zálohu] → stránka zálohy  [Skúsiť znova] → zopakuj `book-meeting`

„Skúsiť znova“ je pre prípad, keď žena zaplatila pred pár sekundami a potvrdenie
platby zo Stripe ešte neprišlo.

Ostatné odpovede `book-meeting` sa nemenia. Ak termín vyprší (`/pohovor/dakujem` →
„Vybrať nový termín“), záloha ostáva zaplatená a žena ju neplatí znova.

---

## 3. Spustenie

1. Backend je nasadený. Záloha je zatiaľ **nepovinná**: `book-meeting` funguje aj bez nej.
2. Nasaď frontend (sekcie 0–2).
3. Potom backend zapne povinnú zálohu. Odvtedy `book-meeting` bez zaplatenej zálohy vráti 402.

## 4. Test

- dotazník → platba zálohy (2/4) → zaplať → `/pohovor/termin` → rezervácia → `/pohovor/potvrdenie` (4/4)
- v Stripe má platba vyplnené `client_reference_id` = token dotazníka
- nový dotazník bez platby → priamo `/pohovor/termin` → vyber termín → chybový box (402)
