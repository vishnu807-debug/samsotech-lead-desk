-- Lead Desk · AMC role can read won orders (10 Nov 2026)
-- Run once in Supabase → SQL Editor, after 24_amc_renewals.sql. Safe to run again. No leads are changed.
--
-- Why: 24_amc_renewals.sql gave the AMC role its permissions only when the permission table had never seen
-- "Renewals" before. If the table was saved from the app around the time of the update, the AMC role could end up
-- with no permissions in the database, so AMC users saw the Renewals page with no orders on it.
-- This file gives the AMC role its three permissions whenever it has none. A choice the Supervisor has already
-- made for the AMC role (any ticked box) is left as it is.

update public.docs
set doc = jsonb_set(doc, '{roles,amc}', '["page.renewals","renewal.manage","lead.view_won"]'::jsonb)
where path = 'config/permissions' and doc ? 'roles'
  and jsonb_array_length(case when jsonb_typeof(doc->'roles'->'amc') = 'array' then doc->'roles'->'amc' else '[]'::jsonb end) = 0;

update public.docs
set doc = jsonb_set(doc, '{known}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'known','[]'::jsonb) || '["page.renewals","renewal.manage","lead.view_won"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles' and doc ? 'known';

-- Check: the AMC role should list lead.view_won, and the last two numbers should match
select doc->'roles'->'amc' as amc_permissions,
       (select count(*) from public.members where role = 'amc' and active) as amc_users,
       (select count(*) from public.leads where status = 'Won' and (doc->>'deleted') is null) as won_orders
from public.docs where path = 'config/permissions';
