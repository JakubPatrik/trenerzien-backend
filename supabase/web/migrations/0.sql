-- Tabuľka: consultation_applications
-- Uchováva prihlášky z dotazníka "pohovor s trénerom"

-- 1. Vytvorenie tabuľky
CREATE TABLE IF NOT EXISTS public.consultation_applications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token text NOT NULL DEFAULT encode(extensions.gen_random_bytes(24), 'hex'::text),
    name text NOT NULL,
    email text NOT NULL,
    phone text NOT NULL,
    age integer,
    current_weight numeric,
    target_weight numeric,
    health_issues text,
    occupation text,
    hobbies text,
    genetics text,
    life_changes text,
    obstacles text,
    vision_one_year text,
    expectations text,
    qualified boolean NOT NULL DEFAULT true,
    synced_to_smartemailing boolean NOT NULL DEFAULT false,
    sync_error text,
    deposit_paid boolean NOT NULL DEFAULT false,
    deposit_session_id text,
    deposit_paid_at timestamp with time zone,
    booking_start timestamp with time zone,
    booking_event_id text,
    booking_meet_url text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 2. Prístupové práva (Supabase Data API vyžaduje explicitné GRANTy)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_applications TO authenticated;
GRANT ALL ON public.consultation_applications TO service_role;

-- 3. Zapnutie Row Level Security
ALTER TABLE public.consultation_applications ENABLE ROW LEVEL SECURITY;

-- 4. RLS politiky (DROP IF EXISTS first so this file can be re-run safely)
-- Admins can read all applications
DROP POLICY IF EXISTS "Admins can read all applications" ON public.consultation_applications;
CREATE POLICY "Admins can read all applications"
ON public.consultation_applications
FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role));

-- Admins can insert applications
DROP POLICY IF EXISTS "Admins can insert applications" ON public.consultation_applications;
CREATE POLICY "Admins can insert applications"
ON public.consultation_applications
FOR INSERT
TO authenticated
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

-- Admins can update applications
DROP POLICY IF EXISTS "Admins can update applications" ON public.consultation_applications;
CREATE POLICY "Admins can update applications"
ON public.consultation_applications
FOR UPDATE
TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role))
WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

-- Admins can delete applications
DROP POLICY IF EXISTS "Admins can delete applications" ON public.consultation_applications;
CREATE POLICY "Admins can delete applications"
ON public.consultation_applications
FOR DELETE
TO authenticated
USING (public.has_role(auth.uid(), 'admin'::app_role));

-- Anyone can submit an application (anon + authenticated) cez verejný formulár
DROP POLICY IF EXISTS "Anyone can submit an application" ON public.consultation_applications;
CREATE POLICY "Anyone can submit an application"
ON public.consultation_applications
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- 5. Automatická aktualizácia updated_at
-- (public.update_updated_at_column() does NOT already exist in this project —
-- there's a same-named function, but it's Supabase's internal storage.update_updated_at_column()
-- for storage.objects, in a different schema. Define our own.)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_consultation_applications_updated_at ON public.consultation_applications;
CREATE TRIGGER update_consultation_applications_updated_at
BEFORE UPDATE ON public.consultation_applications
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();
