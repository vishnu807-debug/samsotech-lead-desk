-- Lead Desk · Price book and quote-line learning (9 Nov 2026)
-- Run once in Supabase → SQL Editor, after 20_pms.sql. Safe to run again. No existing data is changed or deleted.
--
-- 1. New permissions (the Supervisor can switch them on or off per role in Users → Roles & permissions):
--      pricing.view    see the price book, standard prices and discounts      (Management, Lead Manager)
--      pricing.approve approve prices and quote lines; teach line rules       (Management)
--      pricing.manage  edit prices, upload price sheets, add price items      (Supervisor only)
-- 2. Two settings documents: 'config/pricebook' (items with dated, approved prices) and 'config/linerules'
--    (quote wording → price item, used to recognise lines automatically). Created only if missing.
-- 3. Who can read and write them, enforced here: the price book is hidden from anyone without a pricing
--    permission; someone who can approve but not edit can only change a price's approval status.
-- 4. approve_quote_lines(): lets an approver confirm the lines of a quotation without needing to edit leads.

-- 1. Permissions (Supervisor always has every permission)
update public.docs
set doc = jsonb_set(jsonb_set(doc, '{roles,management}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'management','[]'::jsonb) || '["pricing.view","pricing.approve"]'::jsonb) x)),
      '{roles,leadmanager}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'leadmanager','[]'::jsonb) || '["pricing.view"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles'
  and not (coalesce(doc->'known','[]'::jsonb) ? 'pricing.view');   -- only the first time: later choices made by the Supervisor stand

-- remember that these permissions are now known, so switching them off later sticks
update public.docs
set doc = jsonb_set(doc, '{known}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'known','[]'::jsonb) || '["pricing.view","pricing.approve","pricing.manage"]'::jsonb) x))
where path = 'config/permissions' and doc ? 'roles' and doc ? 'known';

-- 2. Who can read and write which document
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated using (
  case when path = 'config/pricebook'
       then (select public.has_perm('pricing.view')) or (select public.has_perm('pricing.approve')) or (select public.has_perm('pricing.manage'))
       else ((select public.my_role()) is not null and path in ('config/settings','config/permissions','config/references','config/targets','config/linerules'))
            or (select public.has_perm('lead.view_all')) or (select public.has_perm('account.manage'))
  end
);

drop policy if exists docs_write on public.docs;
create policy docs_write on public.docs for all to authenticated
  using      (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   when path = 'config/targets'     then public.has_perm('targets.manage')
                   when path = 'config/pricebook'   then public.has_perm('pricing.manage') or public.has_perm('pricing.approve')
                   when path = 'config/linerules'   then public.has_perm('pricing.manage') or public.has_perm('pricing.approve')
                   else public.has_perm('settings.manage') end)
  with check (case when path = 'config/permissions' then public.has_perm('users.manage')
                   when path = 'config/references'  then public.has_perm('account.manage')
                   when path = 'config/targets'     then public.has_perm('targets.manage')
                   when path = 'config/pricebook'   then public.has_perm('pricing.manage') or public.has_perm('pricing.approve')
                   when path = 'config/linerules'   then public.has_perm('pricing.manage') or public.has_perm('pricing.approve')
                   else public.has_perm('settings.manage') end);

-- 3. An approver who can't edit prices may only change approval fields (st, okBy, okAt) on price versions
create or replace function public.ld_pb_strip(d jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(coalesce(d,'{}'::jsonb), '{items}', coalesce((
    select jsonb_agg(jsonb_set(it, '{v}', coalesce((
             select jsonb_agg(v - 'st' - 'okBy' - 'okAt' order by o)
             from jsonb_array_elements(coalesce(it->'v','[]'::jsonb)) with ordinality x(v,o)), '[]'::jsonb)) order by io)
    from jsonb_array_elements(coalesce(d->'items','[]'::jsonb)) with ordinality y(it,io)), '[]'::jsonb))
$$;

create or replace function public.guard_pricebook() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(),'') <> 'authenticated' then return new; end if;   -- SQL editor, service jobs
  if new.path = 'config/pricebook' and not public.has_perm('pricing.manage') then
    if tg_op = 'INSERT' or public.ld_pb_strip(new.doc) is distinct from public.ld_pb_strip(old.doc) then
      raise exception 'Only a Supervisor can change prices. You can approve them.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists guard_pricebook on public.docs;
create trigger guard_pricebook before insert or update on public.docs
  for each row when (new.path = 'config/pricebook') execute function public.guard_pricebook();

-- 4. Approvers confirm quote lines (product / price item for each line) without needing to edit leads
create or replace function public.approve_quote_lines(p_id text, p_lines jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare cur jsonb;
begin
  if not (public.has_perm('pricing.approve') or public.has_perm('pricing.manage')) then
    raise exception 'Only Management or a Supervisor can approve quote lines.' using errcode = '42501';
  end if;
  select doc->'quote'->'lines' into cur from public.leads where id = p_id for update;
  if cur is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(cur) <> jsonb_array_length(p_lines) then
    raise exception 'This quotation has changed. Reload and try again.' using errcode = '22023';
  end if;
  -- only the mapping ("m") of each line may change; the quoted figures stay as they were
  update public.leads
     set doc = jsonb_set(doc, '{quote,lines}', (
           select jsonb_agg(case when n ? 'm' then o || jsonb_build_object('m', n->'m') else o end order by i)
           from jsonb_array_elements(cur) with ordinality a(o,i)
           join jsonb_array_elements(p_lines) with ordinality b(n,j) on i = j)),
         updated_at = now()
   where id = p_id;
  return true;
end $$;
revoke all on function public.approve_quote_lines(text, jsonb) from public;
grant execute on function public.approve_quote_lines(text, jsonb) to authenticated;

-- 5. The two documents, empty price book items are added by the app's seed below
insert into public.docs (path, doc) values ('config/linerules', '{"rules":[]}'::jsonb) on conflict (path) do nothing;

-- Starting price book: every item without a price (Draft). Prices come from the price sheet upload.
insert into public.docs (path, doc) values ('config/pricebook', jsonb_build_object('items', (
  select jsonb_agg(jsonb_build_object('id', id, 'product', product, 'name', name, 'type', type, 'unit', unit, 'yearly', yearly,
                                      'pms', pms, 'iface', iface, 'cur', 'AED', 'v', '[]'::jsonb, 'active', true) order by ord)
  from (values
    (1,'pp-pms','Passport / ID Scanner','Licence · interfaced with PMS only','software','pc',false,'',''),
    (2,'pp-vic','Passport / ID Scanner','Licence · interfaced with VICAS only','software','pc',false,'',''),
    (3,'pp-vp','Passport / ID Scanner','Licence · interfaced with VICAS and PMS','software','pc',false,'',''),
    (4,'hw-2000','Passport / ID Scanner','Samsotech Passport/ID Scanner 2000','hardware','unit',false,'',''),
    (5,'hw-7013','Passport / ID Scanner','Samsotech Passport/ID Scanner 7013','hardware','unit',false,'',''),
    (6,'hw-7023','Passport / ID Scanner','Samsotech Passport/ID Scanner 7023','hardware','unit',false,'',''),
    (7,'hw-icon','Passport / ID Scanner','Samsotech Passport Scanner ICON','hardware','unit',false,'',''),
    (8,'hw-pbis','Passport / ID Scanner','Samsotech Passport/ID Scanner Penta (BIS)','hardware','unit',false,'',''),
    (9,'hw-psc','Passport / ID Scanner','Samsotech Passport/ID Scanner Penta (SC)','hardware','unit',false,'',''),
    (10,'hw-prf','Passport / ID Scanner','Samsotech Passport/ID Scanner Penta (SC & RFID)','hardware','unit',false,'',''),
    (11,'hw-7028','Passport / ID Scanner','Samsotech Kiosk Passport/ID Scanner 7028M','hardware','unit',false,'',''),
    (12,'er-sa','eREG','Licence · standalone','software','pc',false,'',''),
    (13,'er-pms','eREG','Licence · interfaced with PMS','software','pc',false,'',''),
    (14,'if-v5k','PMS interface','OPERA 5 / V5 · OPP_KSK','interface','once',false,'OPERA 5 / V5','OPP_KSK'),
    (15,'if-v5o','PMS interface','OPERA 5 / V5 · OWS','interface','once',false,'OPERA 5 / V5','OWS'),
    (16,'oh-pp','Passport / ID Scanner','OPERA Cloud OHIP · Passport / ID Scanner','interface','room',true,'OPERA Cloud','OHIP'),
    (17,'oh-er','eREG','OPERA Cloud OHIP · eREG','interface','room',true,'OPERA Cloud','OHIP'),
    (18,'sv-inst','Services','Installation & training','service','property',false,'',''),
    (19,'ss-1','SamsoSuite Passport / ID Scanning','SamsoSuite Passport / ID Scanning · subscription','software','property',true,'',''),
    (20,'ss-2','SamsoSuite eREG','SamsoSuite eREG · subscription','software','property',true,'',''),
    (21,'ss-3','SamsoSuite eREG Plus','SamsoSuite eREG Plus · subscription','software','property',true,'',''),
    (22,'ss-4','SamsoSuite F&B','SamsoSuite F&B · subscription','software','property',true,'',''),
    (23,'ss-5','SamsoSuite Mailer','SamsoSuite Mailer · subscription','software','property',true,'',''),
    (24,'ss-6','SamsoSuite Samso Sign','SamsoSuite Samso Sign · subscription','software','property',true,'',''),
    (25,'ss-7','SamsoSuite Online Check-in','SamsoSuite Online Check-in · subscription','software','property',true,'',''),
    (26,'ss-8','SamsoSuite Kiosk on Payment Device','SamsoSuite Kiosk on Payment Device · subscription','software','property',true,'',''),
    (27,'ss-9','SamsoSuite House Keeping','SamsoSuite House Keeping · subscription','software','property',true,'','')
  ) as t(ord,id,product,name,type,unit,yearly,pms,iface))))
on conflict (path) do nothing;

-- Check
select (select count(*) from jsonb_array_elements(doc->'items')) as price_items from public.docs where path = 'config/pricebook';
