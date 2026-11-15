-- Lead Desk · Sales can change their own won leads for a limited time (13 Nov 2026)
-- Run once in Supabase → SQL Editor, after 30_pms_strict.sql. Safe to run again. No leads are changed.
--
-- New permission lead.won_own (Sales by default; switch it per role in Roles and permissions):
--   for wonEditDays days after a lead was marked Won (default 30, set in Products & settings → Sales rules →
--   Activity rules and forecast) the lead's own sales engineer can
--     • move it back to Quotation Sent, Meeting Done or Assigned, without a reason
--     • correct the order value while it stays Won
-- After that time, and for On Hold / Lost, it stays with Lead Manager and Supervisor as before (16_won_status.sql).
-- New in this file as well: nobody without one of these two permissions can change the order of a won lead.

-- 1. the number of days, only if it was never set
update public.docs set doc = jsonb_set(doc, '{wonEditDays}', '30'::jsonb)
where path = 'config/settings' and not (doc ? 'wonEditDays');

-- 2. is the lead still inside its change window?
create or replace function public.won_window_open(d jsonb) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare t timestamptz; n int;
begin
  begin
    t := coalesce(nullif(d->'stageAt'->>'Won',''), nullif(d->'order'->>'date',''))::timestamptz;
  exception when others then return false; end;
  if t is null then return false; end if;
  begin
    select coalesce(nullif(doc->>'wonEditDays','')::int, 30) into n from public.docs where path = 'config/settings';
  exception when others then n := 30; end;
  return now() - t <= make_interval(days => coalesce(n, 30));
end $$;
revoke all on function public.won_window_open(jsonb) from public, anon;
grant execute on function public.won_window_open(jsonb) to authenticated;

-- 3. Guard (same rules as 16_won_status.sql, with the new Won rule)
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
  return new;
end $$;

-- Check
select coalesce((select (doc->>'wonEditDays')::int from public.docs where path = 'config/settings'), 30) as days_sales_can_change_own_won_lead,
       coalesce((select doc->'roles'->'sales' ? 'lead.won_own' or not coalesce(doc->'known','[]'::jsonb) ? 'lead.won_own' from public.docs where path = 'config/permissions'), true) as sales_has_the_permission;
