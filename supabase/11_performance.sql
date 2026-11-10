-- Lead Desk · Faster access rules (for a team of 15+ people)
-- Run once in Supabase → SQL Editor, after 09_rbac.sql (and 10_audit_trail.sql if you use it). Safe to run again.
--
-- The rules from 09 asked "what is this user's role / permission?" once for EVERY row. These versions
-- ask once per query (Postgres "initplan": the wrapped (select …) is evaluated a single time), so loading
-- all leads is several times faster. Who can see and change what is exactly the same as before.

-- leads
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads for select to authenticated using (
  (select public.has_perm('lead.view_all'))
  or ((select public.my_engineer()) <> '' and lower(coalesce(assigned_to,'')) = lower((select public.my_engineer())))
);
drop policy if exists leads_update on public.leads;
create policy leads_update on public.leads for update to authenticated
  using (
    (select public.has_perm('lead.edit_all'))
    or ((select public.has_perm('lead.edit_own')) and (select public.my_engineer()) <> '' and lower(coalesce(assigned_to,'')) = lower((select public.my_engineer())))
  )
  with check (
    (select public.has_perm('lead.edit_all'))
    or ((select public.has_perm('lead.edit_own')) and (select public.my_engineer()) <> '' and lower(coalesce(assigned_to,'')) = lower((select public.my_engineer())))
  );
drop policy if exists leads_delete on public.leads;
create policy leads_delete on public.leads for delete to authenticated using ((select public.has_perm('lead.delete')));

-- accounts
drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts for select to authenticated using (
  (select public.has_perm('lead.view_all')) or (select public.has_perm('account.manage'))
  or exists (select 1 from public.leads l where l.account_key = accounts.key
             and (select public.my_engineer()) <> '' and lower(coalesce(l.assigned_to,'')) = lower((select public.my_engineer())))
);
drop policy if exists accounts_update on public.accounts;
create policy accounts_update on public.accounts for update to authenticated
  using ((select public.has_perm('account.manage'))) with check ((select public.has_perm('account.manage')));
drop policy if exists accounts_delete on public.accounts;
create policy accounts_delete on public.accounts for delete to authenticated using ((select public.has_perm('account.manage')));

-- docs
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (
  ((select public.my_role()) is not null and path in ('config/settings','config/permissions'))
  or (select public.has_perm('lead.view_all')) or (select public.has_perm('account.manage'))
);

-- members
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using ((select public.has_perm('users.manage')) or email = (select public.my_email()));

-- audit trail (only if 10_audit_trail.sql has been run)
do $$ begin
  if to_regclass('public.audit_log') is not null then
    execute 'drop policy if exists audit_select on public.audit_log';
    execute 'create policy audit_select on public.audit_log for select to authenticated using ((select public.has_perm(''page.audit'')))';
  end if;
end $$;

-- indexes used by the rules and by the app
create index if not exists leads_assigned_lower_idx on public.leads (lower(coalesce(assigned_to,'')));
create index if not exists leads_account_key_idx    on public.leads (account_key);
create index if not exists members_email_active_idx on public.members (email) where active;
analyze public.leads; analyze public.accounts; analyze public.members; analyze public.docs;
