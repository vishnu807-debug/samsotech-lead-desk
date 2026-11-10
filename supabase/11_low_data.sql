-- Lead Desk · Low-data mode (stay inside the Supabase free plan)
-- Run once in Supabase → SQL Editor. Safe to run again.
--
-- Adds an "updated_at" time to leads and accounts, kept up to date by the database.
-- The app keeps a copy of the leads on each device and asks only for rows changed since
-- its last visit, instead of downloading every lead each time Lead Desk is opened.
-- Until this file is run, the app simply keeps working the old way.

alter table public.leads    add column if not exists updated_at timestamptz not null default now();
alter table public.accounts add column if not exists updated_at timestamptz not null default now();
create index if not exists leads_updated_at_idx    on public.leads (updated_at);
create index if not exists accounts_updated_at_idx on public.accounts (updated_at);

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists leads_touch on public.leads;
drop trigger if exists accounts_touch on public.accounts;
create trigger leads_touch    before insert or update on public.leads    for each row execute function public.touch_updated_at();
create trigger accounts_touch before insert or update on public.accounts for each row execute function public.touch_updated_at();

-- The database clock, so every device asks "what changed since" in the same time reference.
create or replace function public.server_now() returns timestamptz language sql stable as $$ select now() $$;
grant execute on function public.server_now() to authenticated;

-- Check
select 'leads' as table_name, count(*) as rows, max(updated_at) as latest_change from public.leads
union all
select 'accounts', count(*), max(updated_at) from public.accounts;
