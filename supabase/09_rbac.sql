-- Lead Desk · Role-based access control (four roles + one permission table)
-- Run once in Supabase → SQL Editor, after files 01–08. Safe to run again.
--
-- Roles:  supervisor (everything) · leadmanager · management · sales
-- Existing 'backoffice' users become 'supervisor', so nobody loses access.
-- What each role may do is stored in docs['config/permissions'] and edited in the app
-- (Products & settings → Roles and permissions). Every policy below asks has_perm(),
-- so the database enforces exactly what the app shows.

-- ---------- 1. Roles --------------------------------------------------
alter table public.members drop constraint if exists members_role_check;
update public.members set role = 'supervisor' where role = 'backoffice';
alter table public.members add constraint members_role_check
  check (role in ('supervisor','leadmanager','management','sales'));

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select case role when 'backoffice' then 'supervisor' else role end
  from public.members where email = public.my_email() and active
$$;

-- ---------- 2. Permission table (defaults; Supervisors change it in the app) ----------
insert into public.docs (path, doc) values ('config/permissions', jsonb_build_object('roles', $j${
  "leadmanager": ["page.leads","page.backoffice","page.pipelines","page.meetings","page.accounts","lead.view_all","lead.create","lead.verify","lead.edit_all","lead.reassign","account.manage"],
  "management":  ["page.leads","page.pipelines","page.meetings","page.accounts","page.management","lead.view_all"],
  "sales":       ["page.leads","page.pipelines","page.meetings","page.accounts","lead.create_own_outbound","lead.edit_own"]
}$j$::jsonb))
on conflict (path) do nothing;

-- has_perm('lead.view_all') → true/false for the signed-in user. Supervisor always true.
create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  with me as (select public.my_role() as r)
  select case
    when me.r is null then false
    when me.r = 'supervisor' then true
    else coalesce(
      (select (d.doc->'roles'->me.r) ? p from public.docs d where d.path = 'config/permissions'),
      false)
  end from me
$$;

-- "Own" records: assigned to the engineer name linked to this login.
create or replace function public.is_mine(p_assigned text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_engineer() <> '' and lower(coalesce(p_assigned,'')) = lower(public.my_engineer())
$$;

grant execute on function public.has_perm(text), public.is_mine(text), public.my_role(), public.my_engineer() to authenticated;
revoke execute on function public.has_perm(text), public.is_mine(text) from anon;

-- ---------- 3. members: users.manage; only a Supervisor can create, change or remove a Supervisor ----------
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (public.has_perm('users.manage') or email = public.my_email());
drop policy if exists members_write on public.members;
create policy members_write on public.members for all to authenticated
  using      (public.has_perm('users.manage') and (role <> 'supervisor' or public.my_role() = 'supervisor'))
  with check (public.has_perm('users.manage') and (role <> 'supervisor' or public.my_role() = 'supervisor'));

-- Never leave the system without an active Supervisor.
create or replace function public.keep_one_supervisor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where role = 'supervisor' and active) then
    raise exception 'There must be at least one active Supervisor.' using errcode = '42501';
  end if;
  return null;
end $$;
drop trigger if exists members_keep_supervisor on public.members;
create constraint trigger members_keep_supervisor after update or delete on public.members
  deferrable initially immediate for each row execute function public.keep_one_supervisor();

-- ---------- 4. leads ----------
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads for select to authenticated
  using (public.has_perm('lead.view_all') or public.is_mine(assigned_to));

drop policy if exists leads_insert on public.leads;
create policy leads_insert on public.leads for insert to authenticated with check (
  public.has_perm('lead.create')
  or (public.has_perm('lead.create_own_outbound')
      and public.my_engineer() <> ''
      and status = 'New'
      and doc->>'category' = 'Outbound'
      and ( public.is_mine(assigned_to)
            or (coalesce(assigned_to,'') = '' and lower(doc->>'generatedBy') = lower(public.my_engineer())) ))
);

drop policy if exists leads_update on public.leads;
create policy leads_update on public.leads for update to authenticated
  using      (public.has_perm('lead.edit_all') or (public.has_perm('lead.edit_own') and public.is_mine(assigned_to)))
  with check (public.has_perm('lead.edit_all') or (public.has_perm('lead.edit_own') and public.is_mine(assigned_to)));

drop policy if exists leads_delete on public.leads;
create policy leads_delete on public.leads for delete to authenticated
  using (public.has_perm('lead.delete'));

-- Approving / assigning / reassigning need their own permission, even through the API.
create or replace function public.guard_lead_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare os text := old.doc->>'status'; ns text := new.doc->>'status';
begin
  if coalesce(auth.role(),'') <> 'authenticated' then return new; end if;   -- SQL editor, service jobs
  if os in ('New','Info Needed') and ns is distinct from os and not public.has_perm('lead.verify') then
    raise exception 'Only a Lead Manager or Supervisor can approve, reject or assign a new lead.' using errcode = '42501';
  end if;
  if coalesce(old.doc->>'assignedTo','') <> '' and (new.doc->>'assignedTo') is distinct from (old.doc->>'assignedTo')
     and not (public.has_perm('lead.reassign') or public.has_perm('lead.verify')) then
    raise exception 'You are not allowed to reassign leads.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists leads_guard on public.leads;
create trigger leads_guard before update on public.leads for each row execute function public.guard_lead_update();

-- ---------- 5. accounts (merge / delete tombstones and account records) ----------
drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts for select to authenticated using (
  public.has_perm('lead.view_all') or public.has_perm('account.manage')
  or exists (select 1 from public.leads l where l.account_key = accounts.key and public.is_mine(l.assigned_to))
);
drop policy if exists accounts_write on public.accounts;
drop policy if exists accounts_insert_sales on public.accounts;
drop policy if exists accounts_insert on public.accounts;
create policy accounts_insert on public.accounts for insert to authenticated with check (
  public.has_perm('account.manage')
  or ((public.has_perm('lead.create') or public.has_perm('lead.create_own_outbound')) and coalesce((doc->>'deleted')::boolean,false) = false));
drop policy if exists accounts_update on public.accounts;
create policy accounts_update on public.accounts for update to authenticated
  using (public.has_perm('account.manage')) with check (public.has_perm('account.manage'));
drop policy if exists accounts_delete on public.accounts;
create policy accounts_delete on public.accounts for delete to authenticated
  using (public.has_perm('account.manage'));

-- ---------- 6. docs ----------
-- settings & permissions: every member reads (the app needs product lists and its own permissions)
-- history & account registry (everyone's past leads): only roles that see all leads
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (
  (public.my_role() is not null and path in ('config/settings','config/permissions'))
  or public.has_perm('lead.view_all') or public.has_perm('account.manage')
);
drop policy if exists docs_write on public.docs;
create policy docs_write on public.docs for all to authenticated
  using      (case when path = 'config/permissions' then public.has_perm('users.manage') else public.has_perm('settings.manage') end)
  with check (case when path = 'config/permissions' then public.has_perm('users.manage') else public.has_perm('settings.manage') end);

-- ---------- 7. Functions the app calls ----------
create or replace function public.next_lead_ref() returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now() at time zone 'Asia/Dubai')::int; n int; ref text;
begin
  if not (public.has_perm('lead.create') or public.has_perm('lead.create_own_outbound')) then
    raise exception 'You are not allowed to create leads' using errcode = '42501';
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

-- Account search for people who only see their own leads: returns at most 10 matching
-- property names (no contacts, no values, no owners) so they can pick an existing account
-- instead of creating a duplicate. Needs 3+ characters.
create or replace function public.find_accounts(q text)
returns table(key text, name text, country text, hist jsonb)
language sql stable security definer set search_path = public as $$
  with needle as (select lower(trim(q)) as n),
  src as (
    select r.key, r.value->>'n' as name, r.value->>'c' as country, coalesce(r.value->'p','{}'::jsonb) as hist
      from public.docs d, jsonb_each(d.doc->'a') r where d.path like 'registry/%'
    union all
    select distinct on (l.account_key) l.account_key, l.doc->>'accountName', l.doc->>'country', '{}'::jsonb
      from public.leads l where l.account_key is not null
  )
  select distinct on (s.key) s.key, s.name, coalesce(s.country,''), s.hist
  from src s, needle
  where (public.has_perm('lead.create') or public.has_perm('lead.create_own_outbound') or public.has_perm('lead.view_all'))
    and length(needle.n) >= 3
    and (lower(s.name) like '%' || needle.n || '%' or s.key like '%' || replace(needle.n,' ','-') || '%')
    and not exists (select 1 from public.accounts a where a.key = s.key and coalesce((a.doc->>'deleted')::boolean,false))
  order by s.key, (s.hist = '{}'::jsonb)
  limit 10
$$;
grant execute on function public.find_accounts(text), public.next_lead_ref() to authenticated;
revoke execute on function public.find_accounts(text) from anon;

-- product_locks: members only (unchanged behaviour)
create or replace function public.product_locks(p_account text)
returns table(product text, ref text, status text, assigned_to text)
language sql stable security definer set search_path = public as $$
  select p.value, l.id, l.status, l.assigned_to
  from public.leads l, jsonb_array_elements_text(coalesce(l.doc->'products', jsonb_build_array(l.doc->>'product'))) p
  where public.my_role() is not null
    and l.account_key = p_account
    and l.status in ('New','Info Needed','Assigned','Meeting Done','Quotation Sent','On Hold','Won')
$$;

-- Sign-up hook message
create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.members where email = lower(event->'user'->>'email') and active) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403,
    'message', 'This email is not on the Lead Desk user list. Ask a Supervisor to add you.'));
end $$;

-- Check: who has which role now
select role, count(*) from public.members group by role order by role;
