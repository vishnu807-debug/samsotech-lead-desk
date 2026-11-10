-- Lead Desk · Move a Won lead back to an earlier status (7 Nov 2026)
-- Run once in Supabase → SQL Editor, after 12_operations.sql. Safe to run again. No data is changed.
--
-- Supervisors and Lead Managers can change a Won lead to Quotation Sent, Meeting Done, Assigned, On Hold or Lost,
-- with a required reason. The order is kept in the lead's history (orderHistory) and no longer counts as revenue.
-- The database refuses the change from any other role, even through the API.

-- 1. Lead Manager gets the new permission (Supervisor always has every permission)
update public.docs
set doc = jsonb_set(doc, '{roles,leadmanager}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'leadmanager','[]'::jsonb) || '["lead.status_override"]'::jsonb) x))
where path = 'config/permissions';

-- 2. Guard (same rules as 12_operations.sql, plus the Won rule)
create or replace function public.guard_lead_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare os text := old.doc->>'status'; ns text := new.doc->>'status';
begin
  if coalesce(auth.role(),'') <> 'authenticated' then return new; end if;   -- SQL editor, service jobs
  if (old.doc->'deleted') is distinct from (new.doc->'deleted') and not public.has_perm('lead.remove') then
    raise exception 'Only a Lead Manager or Supervisor can delete or restore leads.' using errcode = '42501';
  end if;
  if os in ('New','Info Needed') and ns is distinct from os and not public.has_perm('lead.verify') then
    raise exception 'Only a Lead Manager or Supervisor can approve, reject or assign a new lead.' using errcode = '42501';
  end if;
  if coalesce(old.doc->>'assignedTo','') <> '' and (new.doc->>'assignedTo') is distinct from (old.doc->>'assignedTo')
     and not (public.has_perm('lead.reassign') or public.has_perm('lead.verify')) then
    raise exception 'You are not allowed to reassign leads.' using errcode = '42501';
  end if;
  if os not in ('New','Info Needed') and (old.doc->>'country') is distinct from (new.doc->>'country')
     and not (public.has_perm('lead.edit_country') or public.has_perm('lead.edit_fields')) then
    raise exception 'Only a Lead Manager or Supervisor can change the country of an approved lead.' using errcode = '42501';
  end if;
  if os = 'Won' and ns is distinct from 'Won' and not public.has_perm('lead.status_override') then
    raise exception 'Only a Lead Manager or Supervisor can move a won lead back to an earlier status.' using errcode = '42501';
  end if;
  if os = 'Won' and not public.has_perm('meeting.edit_won') and exists (
       select 1 from jsonb_array_elements(coalesce(old.doc->'meetings','[]'::jsonb)) o
       join jsonb_array_elements(coalesce(new.doc->'meetings','[]'::jsonb)) n on n->>'id' = o->>'id'
       where (n->>'date') is distinct from (o->>'date')) then
    raise exception 'Only a Supervisor can change meeting dates on a won lead.' using errcode = '42501';
  end if;
  return new;
end $$;

-- Check
select doc->'roles'->'leadmanager' ? 'lead.status_override' as lead_manager_can_change_won from public.docs where path = 'config/permissions';
