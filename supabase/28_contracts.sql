-- Lead Desk · AMC contracts of existing clients (12 Nov 2026)
-- Run once in Supabase → SQL Editor, after 27_lead_read_rules.sql. Safe to run again. No leads are changed.
--
-- 1. A new table, contracts: one row per AMC contract read from a PDF. The PDF itself is never stored.
--    These are records of existing clients. They are NOT leads: pipeline, won revenue, targets and incentives
--    are untouched.
-- 2. Uploaded contracts wait as "pending" until a Supervisor approves them. Only approved contracts are shown
--    to the other roles.
-- 3. Permissions (switchable in Users → Roles & permissions):
--      contract.upload    upload contract PDFs and edit them while pending   (AMC; Supervisor always)
--      contract.approve   approve or reject uploaded contracts               (Supervisor only by default)
--      contract.view_all  see every approved contract and the installed base (Management, Lead Manager, AMC)
--      contract.view_own  see approved contracts of their own clients        (Sales)
-- 4. Every change is written to the audit trail.

create table if not exists public.contracts (
  id          text primary key,                                   -- "C" + contract number
  doc         jsonb not null,
  status      text generated always as (doc->>'status') stored,   -- pending | approved | rejected | withdrawn
  engineer    text generated always as (doc->>'engineer') stored,
  account_key text generated always as (doc->>'accountKey') stored,
  updated_at  timestamptz not null default now()
);
create index if not exists contracts_engineer_idx on public.contracts (lower(engineer));
create index if not exists contracts_account_idx  on public.contracts (account_key);
alter table public.contracts enable row level security;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select, insert, update on public.contracts to authenticated;
  end if;
end $$;

drop trigger if exists contracts_touch on public.contracts;
create trigger contracts_touch before insert or update on public.contracts
  for each row execute function public.touch_updated_at();

-- A permission check that behaves like the app: a permission the saved table has never seen falls back to the
-- roles it is meant for. (The app does the same, so the page and the database can never disagree.)
create or replace function public.has_perm_or(p text, fallback text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when public.my_role() is null then false
    when public.my_role() = 'supervisor' then true
    when public.has_perm(p) then true
    else public.my_role() = any(fallback)
         and not coalesce((select coalesce(d.doc->'known','[]'::jsonb) ? p from public.docs d where d.path = 'config/permissions'), false)
  end
$$;
revoke all on function public.has_perm_or(text, text[]) from public, anon;
grant execute on function public.has_perm_or(text, text[]) to authenticated;

-- Who can read a contract
drop policy if exists contracts_select on public.contracts;
create policy contracts_select on public.contracts for select to authenticated
  using (
    (select public.has_perm_or('contract.approve', array[]::text[]))
    or (select public.has_perm_or('contract.upload', array['amc']))
    or (status = 'approved' and (
          (select public.has_perm_or('contract.view_all', array['management','leadmanager','amc']))
          or ((select public.has_perm_or('contract.view_own', array['sales'])) and (select public.my_engineer()) <> ''
              and lower(coalesce(engineer,'')) = lower((select public.my_engineer())))))
  );

-- Uploading: always as pending
drop policy if exists contracts_insert on public.contracts;
create policy contracts_insert on public.contracts for insert to authenticated
  with check (status = 'pending' and (select public.has_perm_or('contract.upload', array['amc'])));

-- Changing: an approver may change anything; an uploader only while it is pending, and cannot approve it
drop policy if exists contracts_update on public.contracts;
create policy contracts_update on public.contracts for update to authenticated
  using ((select public.has_perm_or('contract.approve', array[]::text[]))
         or (status = 'pending' and (select public.has_perm_or('contract.upload', array['amc']))))
  with check ((select public.has_perm_or('contract.approve', array[]::text[]))
              or (status in ('pending','withdrawn') and (select public.has_perm_or('contract.upload', array['amc']))));
-- no delete policy: contracts are rejected or withdrawn, never removed

-- Renewal progress on an approved contract (status, notes, corrected amount): the AMC team, lead editors, or the
-- client's sales engineer. Touches nothing else on the contract.
create or replace function public.set_contract_renewal(p_id text, p_key text, p_val jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare c record; v jsonb;
begin
  if p_key !~ '^(amc|sub|ohip)-c$' or jsonb_typeof(p_val) <> 'object' then
    raise exception 'Not a renewal.' using errcode = '22023';
  end if;
  select id, status, engineer, doc into c from public.contracts where id = p_id for update;
  if c.id is null or c.status <> 'approved' then
    raise exception 'Renewals are kept on approved contracts only.' using errcode = '22023';
  end if;
  if not (public.has_perm_or('renewal.manage', array['amc']) or public.has_perm('lead.edit_all') or public.is_mine(c.engineer)) then
    raise exception 'Only the AMC team or the client''s sales engineer can update this renewal.' using errcode = '42501';
  end if;
  v := jsonb_strip_nulls(jsonb_build_object('st', p_val->'st', 'amt', p_val->'amt', 'notes', p_val->'notes',
                                            'by', p_val->'by', 'at', p_val->'at'));
  update public.contracts
     set doc = jsonb_set(doc, '{renewals}', coalesce(doc->'renewals','{}'::jsonb) || jsonb_build_object(p_key, v))
   where id = p_id;
  return true;
end $$;
revoke all on function public.set_contract_renewal(text, text, jsonb) from public, anon;
grant execute on function public.set_contract_renewal(text, text, jsonb) to authenticated;

-- Audit trail
create or replace function public.audit_contract() returns trigger
language plpgsql security definer set search_path = public as $$
declare w record; o jsonb; n jsonb; ch jsonb; act text; summ text;
begin
  o := case when tg_op <> 'INSERT' then old.doc end;
  n := case when tg_op <> 'DELETE' then new.doc end;
  ch := public.audit_diff(o, n, array['updatedAt','updated_at']);
  if tg_op = 'UPDATE' and ch = '{}'::jsonb then return null; end if;
  act := case when tg_op = 'INSERT' then 'uploaded'
              when tg_op = 'DELETE' then 'deleted'
              when ch ? 'status' and n->>'status' = 'approved' then 'approved'
              when ch ? 'status' and n->>'status' = 'rejected' then 'rejected'
              when ch ? 'status' and n->>'status' = 'withdrawn' then 'withdrawn'
              else 'updated' end;
  summ := initcap(act) || ' contract ' || coalesce(n->>'no', o->>'no', '') || ' · ' || coalesce(n->>'client', o->>'client', '')
          || case when act = 'updated' then ': ' || (select string_agg(k, ', ' order by k) from jsonb_object_keys(ch) k) else '' end;
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, w.source, act, 'contract', coalesce(new.id, old.id), summ, case when tg_op = 'UPDATE' then ch else null end);
  return null;
end $$;
revoke execute on function public.audit_contract() from anon, authenticated, public;
drop trigger if exists audit_contracts on public.contracts;
create trigger audit_contracts after insert or update or delete on public.contracts
  for each row execute function public.audit_contract();

-- Permissions in the saved table, the first time only (later choices made by the Supervisor stand)
do $$
declare r record;
begin
  for r in select * from (values
      ('amc','contract.upload'), ('amc','contract.view_all'),
      ('management','contract.view_all'), ('leadmanager','contract.view_all'),
      ('sales','contract.view_own')) as t(role, perm)
  loop
    update public.docs
       set doc = jsonb_set(doc, array['roles', r.role],
             (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                from jsonb_array_elements_text(coalesce(doc->'roles'->r.role, '[]'::jsonb) || jsonb_build_array(r.perm)) x))
     where path = 'config/permissions' and doc ? 'roles'
       and not (coalesce(doc->'known','[]'::jsonb) ? r.perm);
  end loop;
end $$;
update public.docs
set doc = jsonb_set(doc, '{known}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'known','[]'::jsonb)
              || '["contract.upload","contract.approve","contract.view_all","contract.view_own"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles' and doc ? 'known';

-- Check
select (select count(*) from public.contracts) as contracts,
       doc->'roles'->'amc' as amc_permissions from public.docs where path = 'config/permissions';
