-- Enums
CREATE TYPE public.group_topic AS ENUM ('vseobecne','chodza','strava','cvicenie','spanok','akcie');
CREATE TYPE public.group_post_kind AS ENUM ('post','otazka','anketa');

-- Posts
CREATE TABLE public.group_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL,
  topic public.group_topic NOT NULL DEFAULT 'vseobecne',
  kind public.group_post_kind NOT NULL DEFAULT 'post',
  is_pinned boolean NOT NULL DEFAULT false,
  poll_multi boolean NOT NULL DEFAULT false,
  video_key text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX group_posts_feed_idx ON public.group_posts (video_key, created_at DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_posts TO authenticated;
GRANT ALL ON public.group_posts TO service_role;
ALTER TABLE public.group_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "posts_select_members" ON public.group_posts
  FOR SELECT TO authenticated USING (deleted_at IS NULL OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "posts_insert_own" ON public.group_posts
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = author_id);
CREATE POLICY "posts_update_own" ON public.group_posts
  FOR UPDATE TO authenticated USING (auth.uid() = author_id) WITH CHECK (auth.uid() = author_id);
CREATE POLICY "posts_update_admin" ON public.group_posts
  FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "posts_delete_own_or_admin" ON public.group_posts
  FOR DELETE TO authenticated USING (auth.uid() = author_id OR public.has_role(auth.uid(),'admin'));

CREATE TRIGGER touch_group_posts BEFORE UPDATE ON public.group_posts
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Comments
CREATE TABLE public.group_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.group_posts(id) ON DELETE CASCADE,
  parent_id uuid REFERENCES public.group_comments(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX group_comments_post_idx ON public.group_comments (post_id, created_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_comments TO authenticated;
GRANT ALL ON public.group_comments TO service_role;
ALTER TABLE public.group_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "comments_select_members" ON public.group_comments
  FOR SELECT TO authenticated USING (deleted_at IS NULL OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "comments_insert_own" ON public.group_comments
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = author_id);
CREATE POLICY "comments_update_own" ON public.group_comments
  FOR UPDATE TO authenticated USING (auth.uid() = author_id) WITH CHECK (auth.uid() = author_id);
CREATE POLICY "comments_delete_own_or_admin" ON public.group_comments
  FOR DELETE TO authenticated USING (auth.uid() = author_id OR public.has_role(auth.uid(),'admin'));

CREATE TRIGGER touch_group_comments BEFORE UPDATE ON public.group_comments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Reactions
CREATE TABLE public.group_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid REFERENCES public.group_posts(id) ON DELETE CASCADE,
  comment_id uuid REFERENCES public.group_comments(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reaction_target_one CHECK ((post_id IS NOT NULL) <> (comment_id IS NOT NULL))
);
CREATE UNIQUE INDEX group_reactions_post_uniq ON public.group_reactions (post_id, user_id) WHERE post_id IS NOT NULL;
CREATE UNIQUE INDEX group_reactions_comment_uniq ON public.group_reactions (comment_id, user_id) WHERE comment_id IS NOT NULL;

GRANT SELECT, INSERT, DELETE ON public.group_reactions TO authenticated;
GRANT ALL ON public.group_reactions TO service_role;
ALTER TABLE public.group_reactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "reactions_select_members" ON public.group_reactions
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "reactions_insert_own" ON public.group_reactions
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "reactions_delete_own" ON public.group_reactions
  FOR DELETE TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin'));

-- Poll options
CREATE TABLE public.poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.group_posts(id) ON DELETE CASCADE,
  label text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX poll_options_post_idx ON public.poll_options (post_id, sort_order);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.poll_options TO authenticated;
GRANT ALL ON public.poll_options TO service_role;
ALTER TABLE public.poll_options ENABLE ROW LEVEL SECURITY;

CREATE POLICY "poll_options_select_members" ON public.poll_options
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "poll_options_write_author" ON public.poll_options
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.group_posts p WHERE p.id = post_id AND (p.author_id = auth.uid() OR public.has_role(auth.uid(),'admin'))))
  WITH CHECK (EXISTS (SELECT 1 FROM public.group_posts p WHERE p.id = post_id AND (p.author_id = auth.uid() OR public.has_role(auth.uid(),'admin'))));

-- Poll votes
CREATE TABLE public.poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_id uuid NOT NULL REFERENCES public.poll_options(id) ON DELETE CASCADE,
  post_id uuid NOT NULL REFERENCES public.group_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (option_id, user_id)
);
CREATE INDEX poll_votes_post_idx ON public.poll_votes (post_id);

GRANT SELECT, INSERT, DELETE ON public.poll_votes TO authenticated;
GRANT ALL ON public.poll_votes TO service_role;
ALTER TABLE public.poll_votes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "poll_votes_select_members" ON public.poll_votes
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "poll_votes_insert_own" ON public.poll_votes
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "poll_votes_delete_own" ON public.poll_votes
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- Safe author lookup (name + avatar of club members)
CREATE OR REPLACE FUNCTION public.group_authors()
RETURNS TABLE(id uuid, full_name text, avatar_url text, is_admin boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.full_name, p.avatar_url,
         EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id AND r.role = 'admin')
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
$$;