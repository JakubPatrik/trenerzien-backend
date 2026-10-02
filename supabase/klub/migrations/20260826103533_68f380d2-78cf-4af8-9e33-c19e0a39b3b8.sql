create table public.onboarding_answers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  answers jsonb not null default '{}'::jsonb,
  pre_completed_at timestamp with time zone,
  post_completed_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

grant select, insert, update, delete on public.onboarding_answers to authenticated;
grant all on public.onboarding_answers to service_role;

alter table public.onboarding_answers enable row level security;

create policy "Users can manage their own onboarding answers"
on public.onboarding_answers
for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());


create table public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  title text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

grant select, insert, update, delete on public.ai_conversations to authenticated;
grant all on public.ai_conversations to service_role;

alter table public.ai_conversations enable row level security;

create policy "Users can manage their own AI conversations"
on public.ai_conversations
for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());


create table public.ai_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.ai_conversations(id) on delete cascade not null,
  role text not null check (role in ('user', 'assistant', 'system')),
  content text not null,
  parts jsonb,
  created_at timestamp with time zone not null default now()
);

grant select, insert, update, delete on public.ai_messages to authenticated;
grant all on public.ai_messages to service_role;

alter table public.ai_messages enable row level security;

create policy "Users can manage messages in their own conversations"
on public.ai_messages
for all
to authenticated
using (conversation_id in (select id from public.ai_conversations where user_id = auth.uid()))
with check (conversation_id in (select id from public.ai_conversations where user_id = auth.uid()));


alter table public.profiles
add column height_cm numeric,
add column weight_kg numeric,
add column health_notes text;

grant select, update on public.profiles to authenticated;
grant all on public.profiles to service_role;