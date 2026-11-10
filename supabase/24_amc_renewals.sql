-- Lead Desk · AMC and renewals (10 Nov 2026)
-- Run once in Supabase → SQL Editor, after 23_generated_view.sql. Safe to run again. No leads are changed.
--
-- 1. A fifth role, AMC, for the department that renews AMC contracts and subscriptions.
-- 2. Permissions (switchable in Users → Roles & permissions):
--      page.renewals   open the Renewals page              (AMC, Management, Lead Manager, Sales for their own orders)
--      renewal.manage  update any renewal's status/notes    (AMC)
--      lead.view_won   read won orders, nothing else        (AMC)
-- 3. AMC role can read won orders only. Nobody gains the right to edit leads.
-- 4. set_renewal(): the AMC team, or the engineer the order belongs to, records a renewal's status, note or
--    corrected amount. It can touch nothing else on the lead.
-- 5. Starting AMC settings (only if none exist): 18% a year on Passport / ID Scanner, starting 12 months after
--    the order. The Sales share of subscriptions starts empty: the Supervisor sets it in Products & settings.

-- 1. Role
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check
  check (role in ('supervisor','leadmanager','management','sales','amc'));

-- 2. Permissions, the first time only (later choices made by the Supervisor stand)
update public.docs
set doc = jsonb_set(jsonb_set(jsonb_set(jsonb_set(doc,
      '{roles,amc}', coalesce(doc->'roles'->'amc', '["page.renewals","renewal.manage","lead.view_won"]'::jsonb)),
      '{roles,management}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(coalesce(doc->'roles'->'management','[]'::jsonb) || '["page.renewals"]'::jsonb) x)),
      '{roles,leadmanager}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(coalesce(doc->'roles'->'leadmanager','[]'::jsonb) || '["page.renewals"]'::jsonb) x)),
      '{roles,sales}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(coalesce(doc->'roles'->'sales','[]'::jsonb) || '["page.renewals"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles'
  and not (coalesce(doc->'known','[]'::jsonb) ? 'page.renewals');

-- The AMC role always gets its permissions when it has none (see 26_amc_access_fix.sql)
update public.docs
set doc = jsonb_set(doc, '{roles,amc}', '["page.renewals","renewal.manage","lead.view_won"]'::jsonb)
where path = 'config/permissions' and doc ? 'roles'
  and jsonb_array_length(case when jsonb_typeof(doc->'roles'->'amc') = 'array' then doc->'roles'->'amc' else '[]'::jsonb end) = 0;

update public.docs
set doc = jsonb_set(doc, '{known}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'known','[]'::jsonb) || '["page.renewals","renewal.manage","lead.view_won"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles' and doc ? 'known';

-- 3. Who can read which lead (as before, plus: won orders for lead.view_won)
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads for select to authenticated
  using (
    (select public.has_perm('lead.view_all'))
    or ((doc->>'deleted') is null and (select public.my_engineer()) <> '' and lower(coalesce(assigned_to,'')) = lower((select public.my_engineer())))
    or ((doc->>'deleted') is null and (select public.my_engineer()) <> '' and (select public.has_perm('lead.view_generated'))
        and lower(btrim(coalesce(doc->>'generatedBy',''))) = lower((select public.my_engineer())))
    or ((doc->>'deleted') is null and status = 'Won' and (select public.has_perm('lead.view_won')))
  );

-- 4. Record a renewal's progress
create or replace function public.set_renewal(p_id text, p_key text, p_val jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare l record; v jsonb;
begin
  if p_key !~ '^(amc|sub|ohip)-[23]$' or jsonb_typeof(p_val) <> 'object' then
    raise exception 'Not a renewal.' using errcode = '22023';
  end if;
  select id, status, assigned_to, doc into l from public.leads where id = p_id for update;
  if l.id is null or l.status <> 'Won' or (l.doc->>'deleted') is not null then
    raise exception 'Renewals are kept on won orders only.' using errcode = '22023';
  end if;
  if not (public.has_perm('renewal.manage') or public.has_perm('lead.edit_all') or public.is_mine(l.assigned_to)) then
    raise exception 'Only the AMC team or the order''s sales engineer can update this renewal.' using errcode = '42501';
  end if;
  -- only these fields are kept
  v := jsonb_strip_nulls(jsonb_build_object('st', p_val->'st', 'amt', p_val->'amt', 'notes', p_val->'notes',
                                            'by', p_val->'by', 'at', p_val->'at'));
  update public.leads
     set doc = jsonb_set(doc, '{renewals}', coalesce(doc->'renewals','{}'::jsonb) || jsonb_build_object(p_key, v)),
         updated_at = now()
   where id = p_id;
  return true;
end $$;
revoke all on function public.set_renewal(text, text, jsonb) from public;
grant execute on function public.set_renewal(text, text, jsonb) to authenticated;

-- 5. Starting AMC settings
update public.docs
set doc = jsonb_set(doc, '{amc}', jsonb_build_object(
      'rates', '[{"scope":"std","key":"","product":"Passport / ID Scanner","pct":18}]'::jsonb,
      'startMonths', 12, 'salesShare', null, 'alertDays', '[90,60,30]'::jsonb,
      'subProducts', coalesce((select jsonb_agg(p->>'name') from jsonb_array_elements(coalesce(doc->'products','[]'::jsonb)) p
                               where jsonb_typeof(p) = 'object' and p->>'name' ilike 'SamsoSuite %' and p->>'name' <> 'SamsoSuite Solutions'), '[]'::jsonb)))
where path = 'config/settings' and not (doc ? 'amc');

-- 6. A price-free list of the price book items (type, unit, product), kept beside the line rules, so the AMC
--    team and sales can tell hardware, licences, interfaces, subscriptions and OHIP apart without seeing prices.
update public.docs d
set doc = jsonb_set(d.doc, '{items}', coalesce((
      select jsonb_object_agg(i->>'id', jsonb_build_object(
               'ty', i->>'type', 'un', i->>'unit',
               'yr', (coalesce((i->>'yearly')::boolean, false) or i->>'unit' = 'room'),
               'pr', i->>'product', 'if', coalesce(i->>'iface',''), 'nm', i->>'name'))
      from public.docs pb, jsonb_array_elements(coalesce(pb.doc->'items','[]'::jsonb)) i
      where pb.path = 'config/pricebook' and i ? 'id'), '{}'::jsonb))
where d.path = 'config/linerules' and not (d.doc ? 'items');

-- Check
select doc->'amc' as amc_settings from public.docs where path = 'config/settings';
