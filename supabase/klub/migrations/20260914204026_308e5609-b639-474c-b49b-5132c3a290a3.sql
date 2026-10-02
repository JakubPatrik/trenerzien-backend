CREATE OR REPLACE FUNCTION public.is_pair_member(_pair_id uuid, _user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pair_requests p
    WHERE p.id = _pair_id
      AND p.status <> 'declined'
      AND (p.from_user = _user_id OR p.to_user = _user_id)
  )
$$;