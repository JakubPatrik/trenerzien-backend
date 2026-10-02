create extension if not exists vector;

create table if not exists public.odm_knowledge (
  id uuid primary key default gen_random_uuid(),
  source text not null,
  source_kind text not null default 'transcript',
  chunk_index integer not null default 0,
  content text not null,
  embedding vector(1536),
  created_at timestamptz not null default now()
);

grant select on public.odm_knowledge to authenticated;
grant all on public.odm_knowledge to service_role;

alter table public.odm_knowledge enable row level security;

create policy "Members can read know-how"
on public.odm_knowledge for select to authenticated using (true);

create index if not exists odm_knowledge_embedding_idx
on public.odm_knowledge using hnsw (embedding vector_cosine_ops);

create or replace function public.match_odm_knowledge(
  query_embedding vector(1536),
  match_count integer default 8
)
returns table (id uuid, source text, content text, similarity double precision)
language sql
stable
security definer
set search_path = public
as $$
  select k.id, k.source, k.content,
         1 - (k.embedding <=> query_embedding) as similarity
  from public.odm_knowledge k
  where k.embedding is not null
  order by k.embedding <=> query_embedding
  limit greatest(1, least(match_count, 20));
$$;

grant execute on function public.match_odm_knowledge(vector, integer) to authenticated, service_role;