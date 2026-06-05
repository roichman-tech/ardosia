-- ROI-22: minimal table for the hello-world preview-deploy read.
--
-- The app reads this table with the *restricted* (anon) key, which is
-- RLS-enforced. Without an explicit SELECT policy for the `anon` role, the read
-- returns an EMPTY result (not an error) — the page would deploy fine and show
-- nothing. All four steps below are required for the read to return a row.

-- 1. Table
create table if not exists public.greetings (
  id         bigint generated always as identity primary key,
  message    text not null,
  created_at timestamptz not null default now()
);

-- 2. Seed one row
insert into public.greetings (message)
select 'Hello from Supabase 👋'
where not exists (select 1 from public.greetings);

-- 3. Enable Row Level Security (deny-by-default once on)
alter table public.greetings enable row level security;

-- 4. Grant the table-level SELECT privilege to the restricted roles.
--    RLS decides WHICH ROWS are visible; the role still needs the table GRANT
--    itself. This project doesn't apply Supabase's default grants, so it's explicit.
grant select on public.greetings to anon, authenticated;

-- 5. Allow the restricted `anon` role to read (and `authenticated`, for later)
drop policy if exists "Public read access" on public.greetings;
create policy "Public read access"
  on public.greetings
  for select
  to anon, authenticated
  using (true);
