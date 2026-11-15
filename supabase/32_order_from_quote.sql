-- Lead Desk · The order value comes from the quotation (13 Nov 2026)
-- Run once in Supabase → SQL Editor, after 31_won_own.sql. Safe to run again. No leads are changed.
--
-- In the app, Sales must upload the Salesforce quotation when a lead goes to Quotation Sent; the amount is the
-- quotation's total before tax, and "Order won" takes that value. A won order's value changes only through a
-- revised quotation, with a reason. This file makes the database refuse an order whose value is not the value of
-- the lead's quotation, unless the person is a Lead Manager or Supervisor (lead.status_override).
-- Orders and quotations entered before today are left as they are; the check runs only when an order value is set
-- or changed.

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
  -- Won leads: a Lead Manager or Supervisor (lead.status_override) can always change them. The lead's own engineer
  -- (lead.won_own, default Sales) can move it back a stage or correct the order value for wonEditDays days after Won.
  if os = 'Won' and not public.has_perm('lead.status_override')
     and (ns is distinct from 'Won' or (old.doc->'order') is distinct from (new.doc->'order')) then
    if not (public.has_perm_or('lead.won_own', array['sales']) and public.is_mine(old.doc->>'assignedTo') and public.won_window_open(old.doc)) then
      raise exception 'A won lead can be changed by its own sales engineer for a limited number of days after it was won. After that, ask a Lead Manager or Supervisor.' using errcode = '42501';
    end if;
    if ns is distinct from 'Won' and ns not in ('Quotation Sent','Meeting Done','Assigned') then
      raise exception 'Only a Lead Manager or Supervisor can move a won lead to this status.' using errcode = '42501';
    end if;
    if ns = 'Won' and coalesce((new.doc->'order'->>'aed')::numeric, 0) <= 0 then
      raise exception 'A won lead needs an order value above zero.' using errcode = '23514';
    end if;
  end if;
  if os = 'Won' and not public.has_perm('meeting.edit_won') and exists (
       select 1 from jsonb_array_elements(coalesce(old.doc->'meetings','[]'::jsonb)) o
       join jsonb_array_elements(coalesce(new.doc->'meetings','[]'::jsonb)) n on n->>'id' = o->>'id'
       where (n->>'date') is distinct from (o->>'date')) then
    raise exception 'Only a Supervisor can change meeting dates on a won lead.' using errcode = '42501';
  end if;
  -- The order value comes from the quotation: without lead.status_override, an order can only be saved with the
  -- same value as the lead's quotation (new order, or a new value through a revised quotation).
  if ns = 'Won' and not public.has_perm('lead.status_override')
     and (os is distinct from 'Won' or (old.doc->'order') is distinct from (new.doc->'order'))
     and (new.doc->'order'->>'aed') is not null
     and (os is distinct from 'Won' or (old.doc->'order'->>'aed') is distinct from (new.doc->'order'->>'aed')) then
    if coalesce((new.doc->'quote'->>'aed')::numeric, 0) <= 0
       or abs((new.doc->'order'->>'aed')::numeric - (new.doc->'quote'->>'aed')::numeric) > 0.01 then
      raise exception 'The order value must be the value of the lead''s quotation. Upload the revised quotation to change it.' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

-- Check
select 'order value must match the quotation (except Lead Manager / Supervisor)' as rule_now_in_force;
