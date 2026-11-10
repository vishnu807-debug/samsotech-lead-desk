-- Lead Desk · Upsell leads (6 Nov 2026)
-- Run once in Supabase → SQL Editor, after 12_operations.sql. Safe to run again. No data is changed.
--
-- When a product is added to an approved lead at or after a meeting, the app creates a separate
-- "Upsell" lead (doc.type = 'Upsell', doc.parentId = the original lead) assigned to the engineer who
-- held the meeting. This lets a sales engineer create that upsell lead, only from one of their own
-- (approved, not deleted) leads, assigned to the engineer recorded as holding the meeting.
-- Everything else about creating leads is unchanged.

-- Checks the original lead outside the policy (a policy on "leads" can't read "leads" directly)
create or replace function public.upsell_parent_ok(p_parent text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leads p
                 where p.id = p_parent and public.is_mine(p.assigned_to) and (p.doc->>'deleted') is null
                   and p.status not in ('New','Info Needed'))
$$;
revoke execute on function public.upsell_parent_ok(text) from public, anon;
grant execute on function public.upsell_parent_ok(text) to authenticated;

drop policy if exists leads_insert on public.leads;
create policy leads_insert on public.leads for insert to authenticated with check (
  (select public.has_perm('lead.create'))
  or ((select public.has_perm('lead.create_own_outbound'))
      and (select public.my_engineer()) <> ''
      and status = 'New'
      and doc->>'category' = 'Outbound'
      and ( public.is_mine(assigned_to)
            or (coalesce(assigned_to,'') = '' and lower(doc->>'generatedBy') = lower((select public.my_engineer()))) ))
  or ((select public.has_perm('lead.edit_own'))
      and (select public.my_engineer()) <> ''
      and doc->>'type' = 'Upsell'
      and status = 'Meeting Done'
      and coalesce(assigned_to,'') <> ''
      and public.upsell_parent_ok(doc->>'parentId'))
);

-- Check: the policy is in place
select policyname, cmd from pg_policies where tablename = 'leads' order by policyname;
