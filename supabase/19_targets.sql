-- Lead Desk · Sales targets (8 Nov 2026)
-- Run once in Supabase → SQL Editor, after 18_focus.sql. Safe to run again. No data is changed.
--
-- Sales targets live in the document 'config/targets': for each year a company target, a target per month
-- and a target per sales engineer. Management and Supervisors (permission targets.manage) set them in
-- Management → Targets; everyone signed in can read them (engineers see their own progress in Focus).

-- 1. Management gets the new permission (Supervisor always has every permission)
update public.docs
set doc = jsonb_set(doc, '{roles,management}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'management','[]'::jsonb) || '["targets.manage"]'::jsonb) x))
where path = 'config/permissions';

-- 2. Who can read and write which document
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (
  ((select public.my_role()) is not null and path in ('config/settings','config/permissions','config/references','config/targets'))
  or (select public.has_perm('lead.view_all')) or (select public.has_perm('account.manage'))
);

drop policy if exists docs_write on public.docs;
create policy docs_write on public.docs for all to authenticated
  using      (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   when path = 'config/targets'     then public.has_perm('targets.manage')
                   else public.has_perm('settings.manage') end)
  with check (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   when path = 'config/targets'     then public.has_perm('targets.manage')
                   else public.has_perm('settings.manage') end);

insert into public.docs (path, doc) values ('config/targets', '{"years":{}}'::jsonb) on conflict (path) do nothing;

-- Check: Management can now set targets
select doc->'roles'->'management' ? 'targets.manage' as management_sets_targets from public.docs where path = 'config/permissions';
