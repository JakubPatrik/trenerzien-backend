CREATE OR REPLACE FUNCTION public.event_attendees(_event_id uuid)
RETURNS TABLE(user_id uuid, full_name text, avatar_url text, city text, region text, status registration_status, created_at timestamptz)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT r.user_id, p.full_name, p.avatar_url, p.city, p.region, r.status, r.created_at
  FROM public.event_registrations r
  JOIN public.profiles p ON p.id = r.user_id
  WHERE r.event_id = _event_id
    AND r.status <> 'zrusena'
    AND auth.uid() IS NOT NULL
  ORDER BY r.created_at
$$;

GRANT EXECUTE ON FUNCTION public.event_attendees(uuid) TO authenticated;