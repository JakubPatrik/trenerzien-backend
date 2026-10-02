#!/usr/bin/env python3
"""
Match existing Stripe-sourced memberships (source = 'stripe', imported from
klub before the stripe-webhook existed) to their Stripe subscriptions, and
generate the SQL that fills memberships.stripe_subscription_id /
stripe_customer_id. Nothing is written to the DB here — 07-backfill-stripe-ids.sh
shows the report and applies the SQL after confirmation.

Matching: Stripe customer email == profiles.email of the membership's user.
When one email has several subscriptions, the billing interval implied by the
membership name (mesačné / štvrťročné / ročné) and then the subscription
status (live ones first) decide. Anything still ambiguous is reported and
left alone.

Usage: 07-backfill-stripe-ids.py <memberships.json> <out_dir>
Env:   STRIPE_SECRET_KEY  (sk_/rk_ key, Subscriptions + Customers: read)
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

STRIPE_API = "https://api.stripe.com/v1"
# Same pinned version as supabase/functions/_shared/stripe.ts.
STRIPE_VERSION = "2025-03-31.basil"

# Lower = preferred when an email has several candidate subscriptions.
STATUS_PRIORITY = {
    "active": 0,
    "trialing": 0,
    "past_due": 1,
    "unpaid": 2,
    "paused": 2,
    "incomplete": 3,
    "canceled": 4,
    "incomplete_expired": 5,
}
LIVE_STATUSES = {"active", "trialing", "past_due", "unpaid", "paused"}


def stripe_get(path, params, key):
    url = f"{STRIPE_API}/{path}?{urllib.parse.urlencode(params, doseq=True)}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {key}",
        "Stripe-Version": STRIPE_VERSION,
    })
    try:
        with urllib.request.urlopen(req) as res:
            return json.load(res)
    except urllib.error.HTTPError as e:
        body = json.load(e)
        sys.exit(f"Stripe GET {path} failed ({e.code}): {body.get('error', {}).get('message')}")


def fetch_subscriptions(key):
    subs, after = [], None
    while True:
        params = {"status": "all", "limit": 100, "expand[]": ["data.customer"]}
        if after:
            params["starting_after"] = after
        page = stripe_get("subscriptions", params, key)
        subs.extend(page["data"])
        print(f"  fetched {len(subs)} subscriptions…", file=sys.stderr)
        if not page.get("has_more"):
            return subs
        after = page["data"][-1]["id"]


def interval_of(sub):
    rec = ((sub.get("items", {}).get("data") or [{}])[0].get("price") or {}).get("recurring") or {}
    if not rec:
        return None
    return (rec.get("interval"), rec.get("interval_count", 1))


def interval_hint(name):
    n = (name or "").lower()
    if "štvrťročn" in n:
        return ("month", 3)
    if "mesačn" in n:
        return ("month", 1)
    if "ročn" in n:
        return ("year", 1)
    return None


def fmt_interval(iv):
    if not iv:
        return "?"
    unit, count = iv
    return unit if count == 1 else f"{count} {unit}s"


def customer_of(sub):
    c = sub.get("customer")
    return c if isinstance(c, dict) else {"id": c}


def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    key = os.environ.get("STRIPE_SECRET_KEY")
    if not key:
        sys.exit("STRIPE_SECRET_KEY is not set")

    data = json.loads(Path(sys.argv[1]).read_text())
    rows, taken_sub_ids = data["rows"], set(data["linked_subscription_ids"])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    subs = [s for s in fetch_subscriptions(key) if s["id"] not in taken_sub_ids]
    (out_dir / "stripe-subscriptions.json").write_text(json.dumps(subs, indent=2, ensure_ascii=False))

    matches, ambiguous, unmatched_rows = [], [], []
    rows_by_email = defaultdict(list)
    for r in rows:
        if r["email"]:
            rows_by_email[r["email"].strip().lower()].append(r)
        else:
            unmatched_rows.append((r, f"no profile email, membership {r['id']}"))
    subs_by_email = defaultdict(list)
    no_email_subs = []
    for s in subs:
        email = customer_of(s).get("email")
        if email:
            subs_by_email[email.strip().lower()].append(s)
        else:
            no_email_subs.append(s)

    used = set()
    for email, email_rows in sorted(rows_by_email.items()):
        candidates_all = subs_by_email.get(email, [])
        for row in email_rows:
            free = [s for s in candidates_all if s["id"] not in used]
            if not free:
                unmatched_rows.append((row, "no Stripe subscription for this email"))
                continue
            hint = interval_hint(row["name"])
            fitting = [s for s in free if hint is None or interval_of(s) == hint]
            flags = []
            if not fitting:
                if len(free) == 1:
                    fitting = free
                    flags.append(f"interval mismatch: name says {fmt_interval(hint)}, "
                                 f"Stripe bills every {fmt_interval(interval_of(free[0]))}")
                else:
                    ambiguous.append((row, free, "no subscription with the interval from the name"))
                    continue
            fitting.sort(key=lambda s: (STATUS_PRIORITY.get(s["status"], 9), -s["created"]))
            best = fitting[0]
            best_prio = STATUS_PRIORITY.get(best["status"], 9)
            if sum(1 for s in fitting if STATUS_PRIORITY.get(s["status"], 9) == best_prio) > 1:
                ambiguous.append((row, fitting, f"several '{best['status']}' subscriptions"))
                continue
            if best["status"] not in LIVE_STATUSES:
                flags.append(f"subscription is {best['status']} — membership stays as is, "
                             "no webhook events will update it")
            used.add(best["id"])
            matches.append((row, best, flags))

    ambiguous_ids = {s["id"] for _, cands, _ in ambiguous for s in cands}
    unmatched_subs = [s for subs_ in subs_by_email.values() for s in subs_
                      if s["id"] not in used and s["id"] not in ambiguous_ids]
    unmatched_subs += no_email_subs

    # --- SQL ------------------------------------------------------------------
    sql = [
        "-- Generated by 07-backfill-stripe-ids.py — fills Stripe ids on existing memberships.",
        "-- Only rows still without a subscription id are touched.",
        "BEGIN;",
    ]
    for row, sub, _ in matches:
        sql.append(
            "UPDATE public.memberships SET "
            f"stripe_subscription_id = {sql_str(sub['id'])}, "
            f"stripe_customer_id = {sql_str(customer_of(sub)['id'])} "
            f"WHERE id = {sql_str(row['id'])} AND stripe_subscription_id IS NULL;"
        )
    sql.append("COMMIT;")
    (out_dir / "backfill.sql").write_text("\n".join(sql) + "\n")

    # --- Report ---------------------------------------------------------------
    out = []
    p = out.append
    mode = "LIVE" if "_live_" in key else "TEST"
    p(f"Stripe mode: {mode}")
    p(f"Memberships without stripe_subscription_id (source='stripe'): {len(rows)}")
    p(f"Stripe subscriptions (not yet linked): {len(subs)}  "
      f"[{', '.join(f'{k}: {v}' for k, v in Counter(s['status'] for s in subs).most_common())}]")
    p("")
    p(f"== MATCHED: {len(matches)} (written by backfill.sql)")
    for row, sub, flags in matches:
        p(f"  {row['email']:<40} {row['name']:<36} → {sub['id']} "
          f"[{sub['status']}, {fmt_interval(interval_of(sub))}]")
        for f in flags:
            p(f"      ! {f}")
    p("")
    p(f"== AMBIGUOUS: {len(ambiguous)} (skipped — link manually)")
    for row, cands, why in ambiguous:
        p(f"  {row['email']:<40} {row['name']:<36} ({why})")
        for s in cands:
            p(f"      {s['id']} [{s['status']}, {fmt_interval(interval_of(s))}]")
    p("")
    p(f"== MEMBERSHIPS WITHOUT A SUBSCRIPTION: {len(unmatched_rows)} (skipped)")
    for row, why in unmatched_rows:
        p(f"  {row['email'] or '(no email)':<40} {row['name']:<36} ({why})")
    p("")
    live_unmatched = [s for s in unmatched_subs if s["status"] in LIVE_STATUSES]
    p(f"== LIVE SUBSCRIPTIONS WITHOUT A MEMBERSHIP: {len(live_unmatched)} "
      f"(+{len(unmatched_subs) - len(live_unmatched)} ended ones not listed)")
    for s in live_unmatched:
        p(f"  {customer_of(s).get('email') or '(no email)':<40} {s['id']} "
          f"[{s['status']}, {fmt_interval(interval_of(s))}]")
    p("")
    p("== PRICES ON LIVE SUBSCRIPTIONS (lookup_key must be in PLANS in stripe-webhook/membership.ts)")
    prices = Counter()
    for s in subs:
        if s["status"] not in LIVE_STATUSES:
            continue
        for item in s.get("items", {}).get("data", []):
            pr = item.get("price") or {}
            prices[(pr.get("id"), pr.get("lookup_key") or "(no lookup_key)",
                    fmt_interval(interval_of(s)), pr.get("unit_amount"), pr.get("currency"))] += 1
    for (pid, lk, iv, amount, cur), n in prices.most_common():
        amt = f"{amount / 100:.2f} {cur}" if amount is not None else "?"
        p(f"  {n:>4}× {pid}  {lk:<24} {iv:<10} {amt}")

    report = "\n".join(out) + "\n"
    (out_dir / "report.txt").write_text(report)
    print(report)


if __name__ == "__main__":
    main()
