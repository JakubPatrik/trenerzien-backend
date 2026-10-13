-- FAPI platby KLUB (edge function fapi-webhook)
-- Jedna zaplatená faktúra = jeden riadok v memberships, párovaný cez
-- fapi_invoice_id. Riadok sa zapíše raz, opakovaná notifikácia ho nemení.
-- Názvy členstiev musia sedieť s is_club_member() (PLANS v
-- supabase/functions/fapi-webhook/membership.ts používa existujúce názvy).
-- Re-runnable.

ALTER TABLE public.memberships
  ADD COLUMN IF NOT EXISTS fapi_invoice_id text UNIQUE;
