-- Lead Desk · products that are blocked on an unsupported PMS (13 Nov 2026)
-- Run once in Supabase → SQL Editor, after 29_ohip_rules.sql. Safe to run again. No leads are changed.
--
-- 1. Tap & Smile rule (only if the product has no PMS rule yet):
--      OPERA 5 / V5  → OWS or OPP_KSK
--      OPERA Cloud   → OHIP
--      any other PMS → not supported
--    and the product is marked "Block if not supported" (only if that mark was never set for it).
--    Both can be changed afterwards in Products & settings → Products & PMS → PMS integrations.
-- 2. A database check: a lead can't be saved with a product marked "Block if not supported" when the hotel's PMS
--    is "not supported" for it. An unknown PMS ("Not known yet") never blocks. Existing leads are left alone; the
--    check only runs when a lead's products or PMS are being set or changed.

-- 1a. interface methods the rule needs
update public.docs
set doc = jsonb_set(doc, '{pmsIfaces}', coalesce(doc->'pmsIfaces','[]'::jsonb)
      || (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text('["OHIP","OWS","OPP_KSK"]'::jsonb) x
          where not exists (select 1 from jsonb_array_elements_text(coalesce(doc->'pmsIfaces','[]'::jsonb)) p where lower(p) = lower(x))))
where path = 'config/settings' and jsonb_typeof(coalesce(doc->'pmsIfaces','[]'::jsonb)) = 'array';

-- 1b. the rule itself, written against the product and PMS names this client uses
do $$
declare st jsonb; pname text; cloud text; v5 text; prods jsonb; i int;
begin
  select doc into st from public.docs where path = 'config/settings';
  if st is null or jsonb_typeof(st->'products') <> 'array' then return; end if;
  select case when jsonb_typeof(x) = 'string' then x #>> '{}' else x->>'name' end into pname
    from jsonb_array_elements(st->'products') x
    where (case when jsonb_typeof(x) = 'string' then x #>> '{}' else x->>'name' end) ~* 'tap\s*(&|and)?\s*smile' limit 1;
  if pname is null then return; end if;
  select x into cloud from jsonb_array_elements_text(coalesce(st->'pmsList','[]'::jsonb)) x where x ~* 'opera\s*cloud' limit 1;
  select x into v5    from jsonb_array_elements_text(coalesce(st->'pmsList','[]'::jsonb)) x where x ~* 'opera.*(v\s*5|\m5\M)' limit 1;
  cloud := coalesce(cloud, 'OPERA Cloud'); v5 := coalesce(v5, 'OPERA 5 / V5');

  if not exists (select 1 from jsonb_each(coalesce(st->'pmsMatrix','{}'::jsonb)) m
                 where lower(btrim(m.key)) = lower(btrim(pname)) and jsonb_typeof(m.value) = 'object') then
    st := jsonb_set(st, '{pmsMatrix}', coalesce(st->'pmsMatrix','{}'::jsonb)
            || jsonb_build_object(pname, jsonb_build_object(cloud, '["OHIP"]'::jsonb, v5, '["OWS","OPP_KSK"]'::jsonb, '*', '[]'::jsonb)));
    -- give both PMS their own column in the settings table, if they don't have one
    st := jsonb_set(st, '{pmsCols}', coalesce(st->'pmsCols','[]'::jsonb)
            || (select coalesce(jsonb_agg(x), '[]'::jsonb) from unnest(array[cloud, v5]) x
                where not exists (select 1 from jsonb_array_elements_text(coalesce(st->'pmsCols','[]'::jsonb)) c where lower(c) = lower(x))));
  end if;

  prods := st->'products';
  for i in 0 .. jsonb_array_length(prods) - 1 loop
    if jsonb_typeof(prods->i) = 'string' and (prods->>i) = pname then
      prods := jsonb_set(prods, array[i::text], jsonb_build_object('name', pname, 'repeatable', false, 'active', true, 'pmsStrict', true));
    elsif jsonb_typeof(prods->i) = 'object' and (prods->i->>'name') = pname and not ((prods->i) ? 'pmsStrict') then
      prods := jsonb_set(prods, array[i::text, 'pmsStrict'], 'true'::jsonb);
    end if;
  end loop;
  st := jsonb_set(st, '{products}', prods);
  update public.docs set doc = st where path = 'config/settings' and doc is distinct from st;
end $$;

-- 2. the database check
create or replace function public.ld_nk(t text) returns text language sql immutable as $$
  select lower(btrim(regexp_replace(coalesce(t,''), '\s+', ' ', 'g')))
$$;

create or replace function public.guard_lead_pms() returns trigger
language plpgsql security definer set search_path = public as $$
declare st jsonb; pms text; p text; prod jsonb; mrow jsonb; meths jsonb;
begin
  if tg_op = 'UPDATE'
     and (new.doc->'products') is not distinct from (old.doc->'products')
     and (new.doc->>'product') is not distinct from (old.doc->>'product')
     and (new.doc->>'pms')     is not distinct from (old.doc->>'pms') then
    return new;                                            -- products and PMS untouched: nothing to check
  end if;
  pms := public.ld_nk(new.doc->>'pms');
  if pms = '' or pms ~ '^(unknown|not known)' then return new; end if;
  select doc into st from public.docs where path = 'config/settings';
  if st is null or jsonb_typeof(st->'products') <> 'array' or jsonb_typeof(st->'pmsMatrix') <> 'object' then return new; end if;

  for p in
    select x from jsonb_array_elements_text(
      case when jsonb_typeof(new.doc->'products') = 'array' and jsonb_array_length(new.doc->'products') > 0 then new.doc->'products'
           when coalesce(new.doc->>'product','') <> '' then jsonb_build_array(new.doc->>'product') else '[]'::jsonb end) x
  loop
    select x into prod from jsonb_array_elements(st->'products') x
      where jsonb_typeof(x) = 'object' and public.ld_nk(x->>'name') = public.ld_nk(p) limit 1;
    if prod is null or coalesce((prod->>'pmsStrict')::boolean, false) is not true
       or coalesce((prod->>'noPms')::boolean, false) or coalesce((prod->>'standalone')::boolean, false) then continue; end if;
    select m.value into mrow from jsonb_each(st->'pmsMatrix') m
      where public.ld_nk(m.key) = public.ld_nk(p) and jsonb_typeof(m.value) = 'object' limit 1;
    if mrow is null then continue; end if;
    meths := null;
    select m.value into meths from jsonb_each(mrow) m where m.key <> '*' and public.ld_nk(m.key) = pms limit 1;
    if not found then meths := mrow->'*'; end if;
    if meths is null or jsonb_typeof(meths) <> 'array' or jsonb_array_length(meths) = 0 then
      raise exception '% does not work with %. Remove the product or correct the hotel''s PMS.', p, new.doc->>'pms' using errcode = '23514';
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists leads_pms_guard on public.leads;
create trigger leads_pms_guard before insert or update on public.leads for each row execute function public.guard_lead_pms();

-- check: shows the rule that is now in force
select p->>'name' as product, (p->>'pmsStrict')::boolean as block_if_not_supported,
       (select m.value from jsonb_each(d.doc->'pmsMatrix') m where public.ld_nk(m.key) = public.ld_nk(p->>'name') limit 1) as pms_rule
from public.docs d, jsonb_array_elements(d.doc->'products') p
where d.path = 'config/settings' and jsonb_typeof(p) = 'object' and coalesce((p->>'pmsStrict')::boolean, false);
