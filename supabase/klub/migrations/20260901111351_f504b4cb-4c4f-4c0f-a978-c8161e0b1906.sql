CREATE TABLE public.consultation_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  held_on date NOT NULL,
  title text,
  is_open boolean NOT NULL DEFAULT true,
  cleared_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX consultation_sessions_held_on_key ON public.consultation_sessions (held_on);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_sessions TO authenticated;
GRANT ALL ON public.consultation_sessions TO service_role;
ALTER TABLE public.consultation_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY cs_select ON public.consultation_sessions FOR SELECT TO authenticated USING (true);
CREATE POLICY cs_admin_all ON public.consultation_sessions FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_consultation_sessions BEFORE UPDATE ON public.consultation_sessions FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.consultation_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.consultation_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'nova',
  answered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX consultation_questions_session_idx ON public.consultation_questions (session_id, created_at);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_questions TO authenticated;
GRANT ALL ON public.consultation_questions TO service_role;
ALTER TABLE public.consultation_questions ENABLE ROW LEVEL SECURITY;
CREATE POLICY cq_select ON public.consultation_questions FOR SELECT TO authenticated USING (true);
CREATE POLICY cq_insert_own ON public.consultation_questions FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY cq_update_own ON public.consultation_questions FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY cq_delete_own ON public.consultation_questions FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY cq_admin_all ON public.consultation_questions FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER touch_consultation_questions BEFORE UPDATE ON public.consultation_questions FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.question_media (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id uuid NOT NULL REFERENCES public.consultation_questions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  media_type text NOT NULL,
  mime text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX question_media_question_idx ON public.question_media (question_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.question_media TO authenticated;
GRANT ALL ON public.question_media TO service_role;
ALTER TABLE public.question_media ENABLE ROW LEVEL SECURITY;
CREATE POLICY qm_select ON public.question_media FOR SELECT TO authenticated USING (true);
CREATE POLICY qm_insert_own ON public.question_media FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY qm_delete_own ON public.question_media FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY qm_admin_all ON public.question_media FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TABLE public.question_replies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id uuid NOT NULL REFERENCES public.consultation_questions(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX question_replies_question_idx ON public.question_replies (question_id, created_at);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.question_replies TO authenticated;
GRANT ALL ON public.question_replies TO service_role;
ALTER TABLE public.question_replies ENABLE ROW LEVEL SECURITY;
CREATE POLICY qrep_select ON public.question_replies FOR SELECT TO authenticated USING (true);
CREATE POLICY qrep_insert_own ON public.question_replies FOR INSERT TO authenticated WITH CHECK (auth.uid() = author_id);
CREATE POLICY qrep_delete_own ON public.question_replies FOR DELETE TO authenticated USING (auth.uid() = author_id OR public.has_role(auth.uid(), 'admin'));

CREATE TABLE public.question_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id uuid REFERENCES public.consultation_questions(id) ON DELETE CASCADE,
  reply_id uuid REFERENCES public.question_replies(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX question_reactions_q_key ON public.question_reactions (question_id, user_id) WHERE question_id IS NOT NULL;
CREATE UNIQUE INDEX question_reactions_r_key ON public.question_reactions (reply_id, user_id) WHERE reply_id IS NOT NULL;
GRANT SELECT, INSERT, DELETE ON public.question_reactions TO authenticated;
GRANT ALL ON public.question_reactions TO service_role;
ALTER TABLE public.question_reactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY qr_select ON public.question_reactions FOR SELECT TO authenticated USING (true);
CREATE POLICY qr_insert_own ON public.question_reactions FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY qr_delete_own ON public.question_reactions FOR DELETE TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY konzultacie_select ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'konzultacie');
CREATE POLICY konzultacie_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'konzultacie' AND (storage.foldername(name))[1] = (auth.uid())::text);
CREATE POLICY konzultacie_delete ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'konzultacie' AND ((storage.foldername(name))[1] = (auth.uid())::text OR public.has_role(auth.uid(), 'admin')));