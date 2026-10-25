# Vrátenie zálohy 100 €

Pre adminov a podporu.

Pred výberom termínu zaplatí každá žena **vratnú zálohu 100 €**. Záloha sa vždy vracia
celá, ručne v Stripe:

| Situácia | Kedy vrátiť |
| --- | --- |
| po pohovore (či sa stala členkou, alebo nie) | hneď po pohovore |
| zaplatila zálohu dvakrát (dve platby po 100 €) | jednu hneď |

## Ako vrátiť

1. Stripe (live) → **Payments** → do vyhľadávania zadaj jej e-mail.
2. Otvor platbu **100 €** „Vratná záloha za vstupný nezáväzný pohovor“ (stav *Succeeded*).
3. **Refund** → celá suma → dôvod *Requested by customer* → potvrď.

Peniaze jej prídu na kartu do 5–10 pracovných dní. Stripe jej pošle potvrdenie
o vrátení, ak sú v Stripe zapnuté e-maily zákazníkom (Settings → Customer emails →
*Refunds*).

## Zoznam zaplatených záloh

```sql
select c.name, c.email, c.deposit_paid_at at time zone 'Europe/Bratislava' as zaplatene,
       c.deposit_payment_intent_id, a.starts_at at time zone 'Europe/Bratislava' as pohovor, a.status
from consultation_applications c
left join appointments a on a.application_id = c.id and a.status <> 'cancelled'
where c.deposit_paid order by c.deposit_paid_at desc;
```

`deposit_payment_intent_id` (`pi_…`) môžeš vložiť priamo do vyhľadávania v Stripe.
