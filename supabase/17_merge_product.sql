-- Lead Desk · Merge one product into another (7 Nov 2026)
-- Run once in Supabase → SQL Editor, after 15_merge.sql. Safe to run again. No data is lost.
--
-- Used by Products & settings → Rename when the new name already exists (e.g. "Dropbox" into "Check-out Box"):
-- every lead and meeting with the old product gets the other one instead (a lead that had both keeps it once),
-- the old product leaves the catalog, the 2026 account history moves across, and one "Merged" entry
-- listing the leads goes to the audit trail.

create or replace function public.ld_ren_product_doc(d jsonb, o text, n text) returns jsonb language plpgsql immutable as $$
declare ps jsonb; ms jsonb;
begin
  if jsonb_typeof(d->'products') = 'array' then
    select coalesce(jsonb_agg(to_jsonb(x.v) order by x.i), '[]'::jsonb) into ps from (
      select v, min(i) as i from (select case when public.ld_same(e, o) then n else e end as v, i
                                    from jsonb_array_elements_text(d->'products') with ordinality t(e, i)) y group by v) x;
    d := jsonb_set(d, '{products}', ps);
    if jsonb_array_length(ps) > 0 then
      d := jsonb_set(d, '{product}', to_jsonb((select string_agg(e, ', ' order by i) from jsonb_array_elements_text(ps) with ordinality t(e, i))));
    end if;
  elsif public.ld_same(d->>'product', o) then
    d := jsonb_set(d, '{product}', to_jsonb(n));
  end if;
  if jsonb_typeof(d->'meetings') = 'array' then
    select jsonb_agg(case when jsonb_typeof(m->'products') = 'array' then jsonb_set(m, '{products}',
             (select coalesce(jsonb_agg(to_jsonb(x.v) order by x.j), '[]'::jsonb) from (
                select v, min(j) as j from (select case when public.ld_same(e, o) then n else e end as v, j
                                              from jsonb_array_elements_text(m->'products') with ordinality u(e, j)) y group by v) x)) else m end order by i)
      into ms from jsonb_array_elements(d->'meetings') with ordinality t(m, i);
    d := jsonb_set(d, '{meetings}', coalesce(ms, '[]'::jsonb));
  end if;
  return d;
end $$;

create or replace function public.rename_everywhere(p_kind text, p_old text, p_new text) returns integer
language plpgsql security definer set search_path = public as $$
declare o text := trim(coalesce(p_old,'')); n text := regexp_replace(trim(coalesce(p_new,'')), '\s+', ' ', 'g');
        st jsonb; lst jsonb; ids text[]; cnt int; w record;
        mrg boolean := coalesce(current_setting('leaddesk.merge', true),'') = 'on';
begin
  if not public.has_perm('settings.manage') then raise exception 'Only a Supervisor can rename products and engineers.' using errcode = '42501'; end if;
  if p_kind not in ('product','engineer') then raise exception 'Unknown kind %', p_kind; end if;
  if o = '' or n = '' then raise exception 'Enter the new name.' using errcode = '22023'; end if;
  if char_length(n) > 80 then raise exception 'Keep the name under 80 characters.' using errcode = '22001'; end if;
  select doc into st from public.docs where path = 'config/settings' for update;
  lst := st->(case p_kind when 'product' then 'products' else 'salespeople' end);
  if not mrg and not public.ld_same(o, n) and exists (select 1 from jsonb_array_elements(coalesce(lst,'[]'::jsonb)) e
       where public.ld_same(case when jsonb_typeof(e) = 'string' then e#>>'{}' else e->>'name' end, n)) then
    raise exception '"%" already exists. Choose a different name.', n using errcode = '23505';
  end if;

  perform set_config('leaddesk.skip_audit', 'on', true);

  if p_kind = 'product' then
    with u as (update public.leads l set doc = public.ld_ren_product_doc(l.doc, o, n)
               where public.ld_ren_product_doc(l.doc, o, n) is distinct from l.doc returning l.id)
    select array_agg(id order by id) into ids from u;
    if mrg then   -- merging into an existing product: drop the old name from the catalog instead of renaming it
      update public.docs set doc = jsonb_set(doc, '{products}', coalesce((select jsonb_agg(e order by i) from jsonb_array_elements(doc->'products') with ordinality t(e, i)
               where not public.ld_same(case when jsonb_typeof(e) = 'string' then e#>>'{}' else e->>'name' end, o)), '[]'::jsonb))
       where path = 'config/settings' and jsonb_typeof(doc->'products') = 'array';
    else
      update public.docs set doc = jsonb_set(doc, '{products}', public.ld_ren_list(doc->'products', o, n)) where path = 'config/settings' and doc ? 'products';
    end if;
  else
    with u as (update public.leads l set doc = public.ld_ren_engineer_doc(l.doc, o, n)
               where public.ld_ren_engineer_doc(l.doc, o, n) is distinct from l.doc returning l.id)
    select array_agg(id order by id) into ids from u;
    if mrg then   -- merging into an existing engineer: drop the old name from the list instead of renaming it
      update public.docs set doc = jsonb_set(doc, '{salespeople}', coalesce((select jsonb_agg(e order by i) from jsonb_array_elements(doc->'salespeople') with ordinality t(e, i)
               where not public.ld_same(case when jsonb_typeof(e) = 'string' then e#>>'{}' else e->>'name' end, o)), '[]'::jsonb))
       where path = 'config/settings' and jsonb_typeof(doc->'salespeople') = 'array';
    else
      update public.docs set doc = jsonb_set(doc, '{salespeople}', public.ld_ren_list(doc->'salespeople', o, n)) where path = 'config/settings' and doc ? 'salespeople';
    end if;
    update public.docs set doc = jsonb_set(doc, '{territories}', coalesce((select jsonb_agg(case when public.ld_same(t->>'engineer', o) then jsonb_set(t, '{engineer}', to_jsonb(n)) else t end order by i)
             from jsonb_array_elements(doc->'territories') with ordinality x(t, i)), '[]'::jsonb))
     where path = 'config/settings' and jsonb_typeof(doc->'territories') = 'array';
    if exists (select 1 from public.members where public.ld_same(engineer, n)) and not public.ld_same(o, n) then
      update public.members set engineer = null where public.ld_same(engineer, o) and coalesce(engineer,'') <> '';   -- the target already has a login
    else
      update public.members set engineer = n where public.ld_same(engineer, o) and coalesce(engineer,'') <> '';
    end if;
  end if;
  update public.docs set doc = public.ld_ren_registry(doc, p_kind, o, n)
   where path like 'registry/%' and public.ld_ren_registry(doc, p_kind, o, n) is distinct from doc;

  perform set_config('leaddesk.skip_audit', 'off', true);
  cnt := coalesce(array_length(ids, 1), 0);
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, w.source, case when mrg then 'merged' else 'renamed' end, 'settings', p_kind,
          case when mrg then 'Merged ' || p_kind || ' "' || o || '" into "' || n || '" on ' || cnt || ' lead(s)'
               else 'Renamed ' || p_kind || ' "' || o || '" to "' || n || '" on ' || cnt || ' lead(s)' end,
          jsonb_build_object('name', jsonb_build_object('old', o, 'new', n), 'leads', jsonb_build_object('old', null, 'new', to_jsonb(coalesce(ids, '{}'::text[])))));
  return cnt;
end $$;
revoke execute on function public.rename_everywhere(text, text, text) from public, anon;
grant execute on function public.rename_everywhere(text, text, text) to authenticated;

create or replace function public.merge_product(p_old text, p_new text) returns integer
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  if not public.has_perm('settings.manage') then raise exception 'Only a Supervisor can merge products.' using errcode = '42501'; end if;
  if public.ld_same(p_old, p_new) then raise exception 'Choose a different product to merge into.' using errcode = '22023'; end if;
  if not exists (select 1 from public.docs d, jsonb_array_elements(coalesce(d.doc->'products','[]'::jsonb)) e
                 where d.path = 'config/settings' and public.ld_same(case when jsonb_typeof(e) = 'string' then e#>>'{}' else e->>'name' end, p_new)) then
    raise exception '"%" is not in the product catalog.', p_new using errcode = '22023';
  end if;
  perform set_config('leaddesk.merge', 'on', true);
  c := public.rename_everywhere('product', p_old, p_new);
  perform set_config('leaddesk.merge', 'off', true);
  return c;
end $$;
revoke execute on function public.merge_product(text, text) from public, anon;
grant execute on function public.merge_product(text, text) to authenticated;
