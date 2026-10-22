-- Sprievodkyňa klubu je len rola, nie členstvo
--
-- Od 8.sql určuje sprievodkyňu rola 'sprievodkyna' (is_guide(), písmenko S). Staré ručné
-- riadky memberships 'Sprievodkyňa klubu' ostali len kvôli prístupu do KLUBu — ten však
-- is_club_member() dáva aj podľa roly.
--
--   backfill            kto mal riadok 'Sprievodkyňa klubu' a nemal rolu → dostane rolu
--   memberships         riadky 'Sprievodkyňa klubu' sa zmažú
--   is_club_member()    bez 'Sprievodkyňa klubu' v zozname členstiev
--
-- Členstvá klubu: Zakladateľské (ročné / mesačné / prevodom) + Členstvo (mesačné /
-- štvrťročné / ročné) zo Stripe. Rovnaký zoznam: stripe-webhook/membership.ts,
-- send-invitations. Re-runnable.

BEGIN;

INSERT INTO public.user_roles (user_id, role)
SELECT DISTINCT m.user_id, 'sprievodkyna'::public.app_role
FROM public.memberships m
WHERE m.name = 'Sprievodkyňa klubu'
  AND NOT EXISTS (
    SELECT 1 FROM public.user_roles r
    WHERE r.user_id = m.user_id AND r.role::text = 'sprievodkyna'
  );

DELETE FROM public.memberships WHERE name = 'Sprievodkyňa klubu';

CREATE OR REPLACE FUNCTION public.is_club_member(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT _user_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = _user_id AND r.role::text IN ('admin','lider','personalistka','sprievodkyna'))
    OR EXISTS (
      SELECT 1 FROM public.memberships m
      WHERE m.user_id = _user_id AND m.source IS NOT NULL
        AND m.name IN (
          'Zakladateľské členstvo — ročné',
          'Zakladateľské členstvo — mesačné',
          'Zakladateľské členstvo — prevodom',
          'Členstvo — mesačné',
          'Členstvo — štvrťročné',
          'Členstvo — ročné'
        )
        AND (m.ends_at IS NULL OR m.ends_at > now())
    )
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.membership_ends_on >= current_date)
  )
$function$;

COMMIT;
