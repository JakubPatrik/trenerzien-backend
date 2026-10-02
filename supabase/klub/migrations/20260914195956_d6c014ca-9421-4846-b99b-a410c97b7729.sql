CREATE OR REPLACE FUNCTION public.is_pair_member(_pair_id uuid, _user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pair_requests p
    WHERE p.id = _pair_id
      AND p.status = 'accepted'
      AND (p.from_user = _user_id OR p.to_user = _user_id)
  )
$$;

CREATE TABLE public.direct_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pair_id uuid NOT NULL REFERENCES public.pair_requests(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX direct_messages_pair_created_idx ON public.direct_messages (pair_id, created_at);

GRANT SELECT, INSERT, UPDATE ON public.direct_messages TO authenticated;
GRANT ALL ON public.direct_messages TO service_role;

ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Partners can read their conversation"
ON public.direct_messages FOR SELECT TO authenticated
USING (public.is_pair_member(pair_id, auth.uid()));

CREATE POLICY "Partners can write in their conversation"
ON public.direct_messages FOR INSERT TO authenticated
WITH CHECK (sender_id = auth.uid() AND public.is_pair_member(pair_id, auth.uid()));

CREATE POLICY "Recipient can mark as read"
ON public.direct_messages FOR UPDATE TO authenticated
USING (public.is_pair_member(pair_id, auth.uid()) AND sender_id <> auth.uid())
WITH CHECK (public.is_pair_member(pair_id, auth.uid()) AND sender_id <> auth.uid());