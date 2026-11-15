-- Lead Desk · Joint meetings with an agreed share, and events (14 Nov 2026)
-- Run once in Supabase → SQL Editor, after 32_order_from_quote.sql. Safe to run again. No leads are changed.
--
-- 1. A colleague who joined a meeting on someone else's lead (doc.joint), or who is offered a share of its order
--    (doc.share.to), can READ that lead. Nothing else about who sees what changes.
-- 2. lead_share_decide(): the colleague agrees to or declines the share offered by the lead's engineer.
-- 3. The lead update guard: only the colleague can agree; the share is locked once the order is won.
-- 4. save_events(): people with event.manage (Supervisor and Lead Manager by default) register events.
-- 5. settings.eventIncentive: pay the lead generator incentive on event leads (on unless switched off).

-- 1. reading rights (a separate policy, so the shared lead-read rule is never re-created)
drop policy if exists leads_select_joint on public.leads;
create policy leads_select_joint on public.leads for select to authenticated
  using ((doc->>'deleted') is null and public.my_engineer() <> '' and (
           lower(coalesce(doc->'share'->>'to','')) = lower(public.my_engineer())
           or exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(doc->'joint') = 'array' then doc->'joint' else '[]'::jsonb end) j
                      where lower(j) = lower(public.my_engineer()))));

-- 2. the colleague's answer
create or replace function public.lead_share_decide(p_id text, p_ok boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare l record; sh jsonb; t text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  select id, doc into l from public.leads where id = p_id for update;
  if l.id is null or (l.doc->>'deleted') is not null then raise exception 'Lead not found.' using errcode = '22023'; end if;
  sh := l.doc->'share';
  if jsonb_typeof(sh) <> 'object' or coalesce(sh->>'status','') <> 'proposed' then
    raise exception 'There is no share waiting for an answer on this lead.' using errcode = '22023';
  end if;
  if not public.is_mine(sh->>'to') then
    raise exception 'Only the colleague who is offered the share can answer.' using errcode = '42501';
  end if;
  if (l.doc->>'status') in ('Won','Lost','Duplicate','Rejected') then
    raise exception 'This lead is closed; the share can no longer be answered.' using errcode = '22023';
  end if;
  perform set_config('leaddesk.share_rpc', '1', true);
  update public.leads
     set doc = jsonb_set(jsonb_set(doc, '{share}', sh || jsonb_build_object('status', case when p_ok then 'agreed' else 'declined' end, 'decidedAt', t)),
                         '{log}', coalesce(doc->'log','[]'::jsonb) || jsonb_build_array(jsonb_build_object('t', t, 'by', sh->>'to', 'byId', auth.jwt()->>'email',
                                  'a', (sh->>'to') || case when p_ok then ' agreed to' else ' declined' end || ' the ' || (sh->>'pct') || '% share'))),
         updated_at = now()
   where id = p_id;
  perform set_config('leaddesk.share_rpc', '', true);
  return true;
end $$;
revoke all on function public.lead_share_decide(text, boolean) from public, anon;
grant execute on function public.lead_share_decide(text, boolean) to authenticated;

-- 3. Guard (same rules as 32_order_from_quote.sql, with the share rule added)
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
  -- Agreed share of an order (joint work). The lead's engineer offers it, only the colleague can agree (through
  -- lead_share_decide), and it is locked once the order is won. lead.status_override may always change it.
  if (old.doc->'share') is distinct from (new.doc->'share') and not public.has_perm('lead.status_override')
     and coalesce(current_setting('leaddesk.share_rpc', true), '') <> '1' then
    if os = 'Won' then
      raise exception 'The share of a won order is locked. Ask a Lead Manager or Supervisor.' using errcode = '42501';
    end if;
    if (new.doc->'share'->>'status') = 'agreed' then
      raise exception 'Only the colleague who is offered the share can agree to it.' using errcode = '42501';
    end if;
    if jsonb_typeof(new.doc->'share') = 'object' and (
         coalesce((new.doc->'share'->>'pct')::numeric, 0) < 1 or (new.doc->'share'->>'pct')::numeric > 90
         or lower(coalesce(new.doc->'share'->>'to','')) = lower(coalesce(new.doc->>'assignedTo',''))) then
      raise exception 'A share must be between 1 and 90 percent and go to a colleague.' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

-- 4. events
create or replace function public.save_events(p_events jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm_or('event.manage', array['supervisor','leadmanager']) then
    raise exception 'You are not allowed to register events.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'Not a list of events.' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_events) e
             where jsonb_typeof(e) <> 'object' or coalesce(e->>'id','') = '' or length(coalesce(e->>'name','')) < 3) then
    raise exception 'Every event needs a name.' using errcode = '22023';
  end if;
  update public.docs set doc = jsonb_set(doc, '{events}', p_events) where path = 'config/settings';
  return true;
end $$;
revoke all on function public.save_events(jsonb) from public, anon;
grant execute on function public.save_events(jsonb) to authenticated;

-- 5. the switch, only if it was never set
update public.docs set doc = jsonb_set(doc, '{eventIncentive}', 'true'::jsonb)
where path = 'config/settings' and not (doc ? 'eventIncentive');

-- Check
select (select count(*) from pg_policies where tablename = 'leads' and policyname = 'leads_select_joint') as joint_read_rule,
       coalesce((select (doc->>'eventIncentive')::boolean from public.docs where path = 'config/settings'), true) as generator_incentive_on_event_leads;
