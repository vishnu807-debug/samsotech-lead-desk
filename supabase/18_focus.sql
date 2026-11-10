-- Lead Desk · Focus tab: reference sites (8 Nov 2026)
-- Run once in Supabase → SQL Editor, after the earlier files. Safe to run again. No data is changed.
--
-- Reference sites (client hotels that will take a call from a prospect) are kept in the document
-- 'config/references'. Everyone signed in can read it, so engineers can find a reference for their prospect;
-- Lead Managers and Supervisors (permission account.manage) can add or remove references.
-- Activity rules, forecast categories, sales rules and chain owners need no database change.

drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (
  ((select public.my_role()) is not null and path in ('config/settings','config/permissions','config/references'))
  or (select public.has_perm('lead.view_all')) or (select public.has_perm('account.manage'))
);

drop policy if exists docs_write on public.docs;
create policy docs_write on public.docs for all to authenticated
  using      (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   else public.has_perm('settings.manage') end)
  with check (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   else public.has_perm('settings.manage') end);

insert into public.docs (path, doc) values ('config/references', '{"refs":{}}'::jsonb) on conflict (path) do nothing;

-- Check
select path from public.docs where path = 'config/references';
