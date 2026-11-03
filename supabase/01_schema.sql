-- =====================================================================
-- Lead Desk · Supabase schema
-- Run this whole file once in Supabase → SQL Editor → New query → Run.
-- Safe to re-run: it drops and recreates the Lead Desk policies/functions.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

-- Who may use Lead Desk. Only emails in this table can sign in and see data.
create table if not exists public.members (
  email       text primary key check (email = lower(email)),
  role        text not null check (role in ('backoffice','sales','management')),
  engineer    text,                       -- the sales engineer name this login is (sales role)
  active      boolean not null default true,
  added_at    timestamptz not null default now(),
  added_by    text
);
-- One login per sales engineer name
create unique index if not exists members_engineer_unique
  on public.members (lower(engineer)) where engineer is not null and engineer <> '';

-- Leads. The full lead lives in `doc`; key fields are generated columns for security and filtering.
create table if not exists public.leads (
  id           text primary key,                                   -- e.g. LD2026-0986
  doc          jsonb not null,
  assigned_to  text generated always as (doc->>'assignedTo') stored,
  status       text generated always as (doc->>'status') stored,
  account_key  text generated always as (doc->>'accountKey') stored,
  updated_at   timestamptz not null default now()
);
create index if not exists leads_assigned_idx on public.leads (lower(assigned_to));
create index if not exists leads_account_idx  on public.leads (account_key);

-- Accounts (properties) created through Lead Desk
create table if not exists public.accounts (
  key         text primary key,
  doc         jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Settings and reference documents: config/settings, history/2026, registry/accounts-1, registry/accounts-2
create table if not exists public.docs (
  path        text primary key,
  doc         jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Lead reference counter (LDyyyy-nnnn)
create table if not exists public.lead_counter (
  year  int primary key,
  next  int not null
);

-- Keep updated_at current
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists leads_touch on public.leads;
create trigger leads_touch before update on public.leads for each row execute function public.touch_updated_at();
drop trigger if exists accounts_touch on public.accounts;
create trigger accounts_touch before update on public.accounts for each row execute function public.touch_updated_at();
drop trigger if exists docs_touch on public.docs;
create trigger docs_touch before update on public.docs for each row execute function public.touch_updated_at();

-- ---------- Who is calling? ------------------------------------------

create or replace function public.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where email = public.my_email() and active
$$;

create or replace function public.my_engineer() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(engineer,'') from public.members where email = public.my_email() and active
$$;

-- ---------- Row-level security ---------------------------------------

alter table public.members      enable row level security;
alter table public.leads        enable row level security;
alter table public.accounts     enable row level security;
alter table public.docs         enable row level security;
alter table public.lead_counter enable row level security;   -- no policies: only reachable through next_lead_ref()

-- members: back office sees and manages everyone; others see only their own row
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (public.my_role() = 'backoffice' or email = public.my_email());
drop policy if exists members_write on public.members;
create policy members_write on public.members for all to authenticated
  using (public.my_role() = 'backoffice') with check (public.my_role() = 'backoffice');

-- leads: back office & management read all; sales read only leads assigned to them
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads for select to authenticated using (
  public.my_role() in ('backoffice','management')
  or (public.my_role() = 'sales' and public.my_engineer() <> '' and lower(assigned_to) = lower(public.my_engineer()))
);
-- only back office creates or deletes leads
drop policy if exists leads_insert on public.leads;
create policy leads_insert on public.leads for insert to authenticated
  with check (public.my_role() = 'backoffice');
drop policy if exists leads_delete on public.leads;
create policy leads_delete on public.leads for delete to authenticated
  using (public.my_role() = 'backoffice');
-- back office updates any lead; sales update only their own and cannot hand it to someone else
drop policy if exists leads_update on public.leads;
create policy leads_update on public.leads for update to authenticated using (
  public.my_role() = 'backoffice'
  or (public.my_role() = 'sales' and public.my_engineer() <> '' and lower(assigned_to) = lower(public.my_engineer()))
) with check (
  public.my_role() = 'backoffice'
  or (public.my_role() = 'sales' and lower(assigned_to) = lower(public.my_engineer()))
);

-- accounts: every member reads; back office writes
drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts for select to authenticated using (public.my_role() is not null);
drop policy if exists accounts_write on public.accounts;
create policy accounts_write on public.accounts for all to authenticated
  using (public.my_role() = 'backoffice') with check (public.my_role() = 'backoffice');

-- docs (settings, history, registry): every member reads; back office writes
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (public.my_role() is not null);
drop policy if exists docs_write on public.docs;
create policy docs_write on public.docs for all to authenticated
  using (public.my_role() = 'backoffice') with check (public.my_role() = 'backoffice');

-- ---------- Functions the app calls ----------------------------------

-- Next lead reference, atomic. Back office only.
create or replace function public.next_lead_ref() returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now() at time zone 'Asia/Dubai')::int; n int; ref text;
begin
  if public.my_role() is distinct from 'backoffice' then
    raise exception 'Only back office can create leads' using errcode = '42501';
  end if;
  loop
    insert into public.lead_counter(year, next) values (y, 2)
      on conflict (year) do update set next = public.lead_counter.next + 1
      returning next - 1 into n;
    ref := 'LD' || y || '-' || lpad(n::text, 4, '0');
    exit when not exists (select 1 from public.leads where id = ref);
  end loop;
  return ref;
end $$;

-- Products already open or won on any lead for an account.
-- Lets sales engineers see which products are locked without seeing other people's leads.
create or replace function public.product_locks(p_account text)
returns table(product text, ref text, status text, assigned_to text)
language sql stable security definer set search_path = public as $$
  select p.value, l.id, l.status, l.assigned_to
  from public.leads l, jsonb_array_elements_text(coalesce(l.doc->'products', jsonb_build_array(l.doc->>'product'))) p
  where public.my_role() is not null
    and l.account_key = p_account
    and l.status in ('New','Info Needed','Assigned','Meeting Done','Quotation Sent','On Hold','Won')
$$;

grant execute on function public.my_role(), public.my_engineer(), public.next_lead_ref(), public.product_locks(text) to authenticated;
revoke execute on function public.next_lead_ref() from anon;
revoke execute on function public.product_locks(text) from anon;

-- ---------- Block sign-ups from people who aren't on the list --------
-- Turn this on in Authentication → Hooks → "Before User Created" → Postgres function → public.hook_before_user_created
create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.members where email = lower(event->'user'->>'email') and active) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403,
    'message', 'This email is not on the Lead Desk user list. Ask back office to add you.'));
end $$;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, anon, public;
grant select on public.members to supabase_auth_admin;

-- ---------- Live updates ---------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.leads;    exception when others then null; end;
  begin alter publication supabase_realtime add table public.accounts; exception when others then null; end;
  begin alter publication supabase_realtime add table public.docs;     exception when others then null; end;
  begin alter publication supabase_realtime add table public.members;  exception when others then null; end;
end $$;
