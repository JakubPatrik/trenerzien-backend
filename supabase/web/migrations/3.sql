-- Stripe predplatné KLUB (edge function stripe-webhook)
-- Jedno predplatné = jeden riadok v memberships, párovaný cez stripe_subscription_id.
-- Idempotencia eventov používa existujúcu tabuľku stripe_events (2.sql).

ALTER TABLE public.memberships
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text UNIQUE,
  ADD COLUMN IF NOT EXISTS stripe_customer_id text;

CREATE INDEX IF NOT EXISTS memberships_stripe_customer_idx
  ON public.memberships (stripe_customer_id);

-- Prístup do KLUBu podľa názvu členstva. Názvy musia sedieť s PLANS v
-- supabase/functions/stripe-webhook/membership.ts. Pribudli bežné členstvá
-- (lookup_key klub_{obdobie}_clenstvo → „Členstvo — {obdobie}“).
CREATE OR REPLACE FUNCTION public.is_club_member(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT _user_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = _user_id AND r.role::text IN ('admin','leader'))
    OR EXISTS (
      SELECT 1 FROM public.memberships m
      WHERE m.user_id = _user_id AND m.source IS NOT NULL
        AND m.name IN (
          'Zakladateľské členstvo — ročné',
          'Zakladateľské členstvo — mesačné',
          'Zakladateľské členstvo — prevodom',
          'Sprievodkyňa klubu',
          'Členstvo — mesačné',
          'Členstvo — štvrťročné',
          'Členstvo — ročné'
        )
        AND (m.ends_at IS NULL OR m.ends_at > now())
    )
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.membership_ends_on >= current_date)
  )
$function$;
