-- Lead Desk · AMC changes: commercial page picture until approval, project sign-off date, cloud hosting; account rename (14 Nov 2026)
-- Run once in Supabase → SQL Editor, after 33_joint_events.sql. Safe to run again. No leads or contracts are changed.
--
-- 1. contract_pages: a small picture of a contract's commercial page(s), kept ONLY while the contract waits for
--    approval. The database removes it as soon as the contract is approved, rejected or taken back, so nothing builds
--    up (at most 3 pictures per waiting contract, each under about 300 KB).
-- 2. set_signoff(): the AMC team or a Supervisor enters the project sign-off date on a won order. Renewal dates count
--    from it.
-- 3. Cloud hosting becomes its own kind of yearly charge (like OHIP): the "Cloud / hosting" line category is switched
--    to it, the contract renewal function accepts it, and "Cloud Hosting" is added to the product catalog if missing.

-- 1. pictures of the commercial page
create table if not exists public.contract_pages (
  contract_id text not null,
  n           int  not null check (n between 1 and 60),
  img         text not null check (img like 'data:image/jpeg;base64,%' and length(img) < 700000),
  created_at  timestamptz not null default now(),
  created_by  text default (auth.jwt()->>'email'),
  primary key (contract_id, n)
);
alter table public.contract_pages enable row level security;

drop policy if exists contract_pages_select on public.contract_pages;
create policy contract_pages_select on public.contract_pages for select to authenticated
  using ((select public.has_perm_or('contract.approve', array[]::text[]))
         or (select public.has_perm_or('contract.upload', array['amc'])));

drop policy if exists contract_pages_insert on public.contract_pages;
create policy contract_pages_insert on public.contract_pages for insert to authenticated
  with check (((select public.has_perm_or('contract.upload', array['amc'])) or (select public.has_perm_or('contract.approve', array[]::text[])))
              and exists (select 1 from public.contracts c where c.id = contract_id and c.status = 'pending'));

-- at most 3 pictures per contract
create or replace function public.contract_pages_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.contract_pages where contract_id = new.contract_id) >= 3 then
    raise exception 'At most 3 page pictures are kept per contract.' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists contract_pages_limit on public.contract_pages;
create trigger contract_pages_limit before insert on public.contract_pages
  for each row execute function public.contract_pages_limit();

drop policy if exists contract_pages_update on public.contract_pages;
create policy contract_pages_update on public.contract_pages for update to authenticated
  using (((select public.has_perm_or('contract.upload', array['amc'])) or (select public.has_perm_or('contract.approve', array[]::text[])))
         and exists (select 1 from public.contracts c where c.id = contract_id and c.status = 'pending'))
  with check (exists (select 1 from public.contracts c where c.id = contract_id and c.status = 'pending'));
-- nobody deletes by hand: the trigger below does it

create or replace function public.contract_pages_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from 'pending' then
    delete from public.contract_pages where contract_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists contracts_pages_cleanup on public.contracts;
create trigger contracts_pages_cleanup after update on public.contracts
  for each row when (old.status is distinct from new.status) execute function public.contract_pages_cleanup();

grant select, insert, update on public.contract_pages to authenticated;

-- 2. project sign-off date
create or replace function public.set_signoff(p_id text, p_date date) returns boolean
language plpgsql security definer set search_path = public as $$
declare l record; t text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'); who text;
begin
  if not (public.has_perm_or('renewal.manage', array['amc']) or public.has_perm('lead.edit_all')) then
    raise exception 'Only the AMC team or a Supervisor can enter the sign-off date.' using errcode = '42501';
  end if;
  if p_date is null or p_date > (now() at time zone 'utc')::date + 1 then
    raise exception 'Enter a sign-off date that is not in the future.' using errcode = '22023';
  end if;
  select id, status, doc into l from public.leads where id = p_id for update;
  if l.id is null or l.status <> 'Won' or (l.doc->>'deleted') is not null then
    raise exception 'The sign-off date is kept on won orders only.' using errcode = '22023';
  end if;
  select coalesce(nullif(display_name,''), email) into who from public.members where lower(email) = lower(auth.jwt()->>'email');
  update public.leads
     set doc = jsonb_set(jsonb_set(doc, '{signOff}', jsonb_build_object('date', to_char(p_date,'YYYY-MM-DD'), 'by', coalesce(who, auth.jwt()->>'email'), 'at', t)),
                         '{log}', coalesce(doc->'log','[]'::jsonb) || jsonb_build_array(jsonb_build_object('t', t, 'by', coalesce(who, auth.jwt()->>'email'),
                                  'byId', auth.jwt()->>'email', 'a', 'Project sign-off date set to ' || to_char(p_date,'DD Mon YYYY')))),
         updated_at = now()
   where id = p_id;
  return true;
end $$;
revoke all on function public.set_signoff(text, date) from public, anon;
grant execute on function public.set_signoff(text, date) to authenticated;

-- 3a. cloud hosting renewals on contracts
create or replace function public.set_contract_renewal(p_id text, p_key text, p_val jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare c record; v jsonb;
begin
  if p_key !~ '^(amc|sub|ohip|cloud)-c$' or jsonb_typeof(p_val) <> 'object' then
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

-- 3b. the "Cloud / hosting" category now means cloud hosting, not an ordinary subscription (only if it was never changed)
update public.docs d
set doc = jsonb_set(doc, '{lineCats}', (select jsonb_agg(case when c->>'key' = 'cloud' and c->>'type' = 'sub' then c || '{"type":"cloud"}'::jsonb else c end)
                                        from jsonb_array_elements(doc->'lineCats') c))
where path = 'config/settings' and jsonb_typeof(doc->'lineCats') = 'array'
  and exists (select 1 from jsonb_array_elements(doc->'lineCats') c where c->>'key' = 'cloud' and c->>'type' = 'sub');

-- 3c. Cloud Hosting as a product, if the catalog has nothing like it
update public.docs
set doc = jsonb_set(doc, '{products}', doc->'products' || '[{"name":"Cloud Hosting","repeatable":false,"active":true,"noPms":true}]'::jsonb)
where path = 'config/settings' and jsonb_typeof(doc->'products') = 'array'
  and not exists (select 1 from jsonb_array_elements(doc->'products') p
                  where (case when jsonb_typeof(p) = 'string' then p #>> '{}' else p->>'name' end) ~* 'cloud.*host|host.*cloud');

-- 4. Renaming an account (hotel). The account keeps its key; the name changes on the account, on every lead and on
--    its AMC contracts in one go. Supervisor and Lead Manager (account.manage) rename; a sales engineer with a lead on
--    the account can only ask, and the name changes when one of them approves. Old names are kept in doc.aka.
create or replace function public.ld_who() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(display_name,''), email) from public.members where lower(email) = lower(auth.jwt()->>'email')), auth.jwt()->>'email')
$$;

create or replace function public.account_rename_request(p_key text, p_name text, p_reason text, p_cur jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare nm text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g')); t text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  if length(nm) < 3 or length(nm) > 120 or length(btrim(coalesce(p_reason,''))) < 3 then
    raise exception 'Enter the new name and the reason.' using errcode = '22023';
  end if;
  if not (public.has_perm('account.manage') or exists (select 1 from public.leads l
            where l.doc->>'accountKey' = p_key and (l.doc->>'deleted') is null and public.is_mine(l.doc->>'assignedTo'))) then
    raise exception 'You can only ask to rename an account you have a lead on.' using errcode = '42501';
  end if;
  insert into public.accounts(key, doc) values (p_key, jsonb_build_object('name', coalesce(nullif(p_cur->>'name',''), p_key), 'country', coalesce(p_cur->>'country','')))
    on conflict (key) do nothing;
  update public.accounts set doc = jsonb_set(doc, '{renameReq}', jsonb_build_object('to', nm, 'reason', btrim(p_reason), 'by', public.ld_who(), 'at', t)), updated_at = now()
   where key = p_key and (doc->>'deleted') is null;
  if not found then raise exception 'This account has been removed.' using errcode = '22023'; end if;
  return true;
end $$;

create or replace function public.account_rename(p_key text, p_name text, p_reason text, p_cur jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare nm text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g')); t text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
        a record; oldn text; asked text;
begin
  if not public.has_perm('account.manage') then
    raise exception 'Only a Lead Manager or Supervisor can rename an account.' using errcode = '42501';
  end if;
  if length(nm) < 3 or length(nm) > 120 then raise exception 'Enter the new name.' using errcode = '22023'; end if;
  insert into public.accounts(key, doc) values (p_key, jsonb_build_object('name', coalesce(nullif(p_cur->>'name',''), p_key), 'country', coalesce(p_cur->>'country','')))
    on conflict (key) do nothing;
  select key, doc into a from public.accounts where key = p_key for update;
  if (a.doc->>'deleted') is not null then raise exception 'This account has been removed.' using errcode = '22023'; end if;
  if exists (select 1 from public.accounts x where x.key <> p_key and (x.doc->>'deleted') is null and lower(btrim(x.doc->>'name')) = lower(nm)) then
    raise exception 'Another account already has this name. Merge the two accounts instead.' using errcode = '23505';
  end if;
  oldn := coalesce(nullif(a.doc->>'name',''), p_cur->>'name', p_key); asked := a.doc->'renameReq'->>'by';
  update public.accounts
     set doc = (doc - 'renameReq') || jsonb_build_object('name', nm,
                 'aka', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(coalesce(doc->'aka','[]'::jsonb) || jsonb_build_array(oldn)) x where lower(x) <> lower(nm)),
                 'renamed', jsonb_strip_nulls(jsonb_build_object('from', oldn, 'to', nm, 'by', public.ld_who(), 'at', t, 'reason', btrim(coalesce(p_reason,'')), 'askedBy', asked))),
         updated_at = now()
   where key = p_key;
  update public.leads set doc = jsonb_set(doc, '{accountName}', to_jsonb(nm)), updated_at = now()
   where doc->>'accountKey' = p_key and (doc->>'accountName') is distinct from nm;
  update public.contracts set doc = jsonb_set(doc, '{accountName}', to_jsonb(nm))
   where account_key = p_key and (doc->>'accountName') is distinct from nm;
  return true;
end $$;

create or replace function public.account_rename_reject(p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
declare t text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  if not public.has_perm('account.manage') then
    raise exception 'Only a Lead Manager or Supervisor can decide a rename request.' using errcode = '42501';
  end if;
  update public.accounts
     set doc = (doc - 'renameReq') || jsonb_build_object('renameLast', jsonb_build_object('to', doc->'renameReq'->>'to', 'by', doc->'renameReq'->>'by',
                                                         'status', 'rejected', 'decidedBy', public.ld_who(), 'at', t)), updated_at = now()
   where key = p_key and doc ? 'renameReq';
  return true;
end $$;

revoke all on function public.account_rename_request(text, text, text, jsonb) from public, anon;
revoke all on function public.account_rename(text, text, text, jsonb) from public, anon;
revoke all on function public.account_rename_reject(text) from public, anon;
grant execute on function public.account_rename_request(text, text, text, jsonb) to authenticated;
grant execute on function public.account_rename(text, text, text, jsonb) to authenticated;
grant execute on function public.account_rename_reject(text) to authenticated;

-- Check
select (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'contract_pages') as page_picture_table,
       (select count(*) from public.contract_pages) as pictures_kept_now,
       exists (select 1 from public.docs, jsonb_array_elements(doc->'products') p where path = 'config/settings'
               and (case when jsonb_typeof(p) = 'string' then p #>> '{}' else p->>'name' end) ~* 'cloud.*host|host.*cloud') as cloud_hosting_product;
