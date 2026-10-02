-- stripe_events: idempotencia Stripe webhooku (edge function stripe-webhook) —
-- každý Stripe event spracujeme len raz.

CREATE TABLE IF NOT EXISTS public.stripe_events (
    id text PRIMARY KEY,
    type text NOT NULL,
    livemode boolean,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Prístupové práva — zapisuje iba edge function (service_role), admin číta
GRANT SELECT ON public.stripe_events TO authenticated;
GRANT ALL ON public.stripe_events TO service_role;

ALTER TABLE public.stripe_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can read stripe events" ON public.stripe_events;
CREATE POLICY "Admins can read stripe events"
ON public.stripe_events
FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role));
