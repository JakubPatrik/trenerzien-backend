-- Členstvá klientiek (voľný text názvu produktu) + stav pozvánky do klubu

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan text not null,
  source text,
  started_on date,
  ends_on date,
  is_lifetime boolean not null default false,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, plan)
);

grant select, insert, update, delete on public.memberships to authenticated;
grant all on public.memberships to service_role;

alter table public.memberships enable row level security;

create policy "Members read own memberships"
  on public.memberships for select to authenticated
  using (auth.uid() = user_id or public.has_role(auth.uid(), 'admin'));

create policy "Admins insert memberships"
  on public.memberships for insert to authenticated
  with check (public.has_role(auth.uid(), 'admin'));

create policy "Admins update memberships"
  on public.memberships for update to authenticated
  using (public.has_role(auth.uid(), 'admin'));

create policy "Admins delete memberships"
  on public.memberships for delete to authenticated
  using (public.has_role(auth.uid(), 'admin'));

create trigger memberships_touch_updated_at
  before update on public.memberships
  for each row execute function public.touch_updated_at();

create index if not exists memberships_user_idx on public.memberships (user_id);
create index if not exists memberships_plan_idx on public.memberships (plan);

-- Stav pozvánky: none / invited / accepted
do $$
begin
  if not exists (select 1 from pg_type where typname = 'invitation_state') then
    create type public.invitation_state as enum ('none', 'invited', 'accepted');
  end if;
end $$;

alter table public.profiles
  add column if not exists invitation public.invitation_state not null default 'none';

-- História odoslaných pozvánok
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  sent_at timestamptz,
  accepted_at timestamptz,
  error text,
  batch_id uuid,
  created_at timestamptz not null default now()
);

grant select on public.invites to authenticated;
grant all on public.invites to service_role;

alter table public.invites enable row level security;

create policy "Admins read invites"
  on public.invites for select to authenticated
  using (public.has_role(auth.uid(), 'admin'));

create index if not exists invites_user_idx on public.invites (user_id);
create index if not exists invites_batch_idx on public.invites (batch_id);