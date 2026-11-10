-- Lead Desk · PMS integrations (9 Nov 2026)
-- Run once in Supabase → SQL Editor, after 19_targets.sql. Safe to run again. Nothing is deleted or changed:
-- it only adds what is missing.
--
-- 1. Adds the 9 SamsoSuite products to the product list (existing products stay as the on-premise versions).
-- 2. Adds the PMS list, interface methods and the product × PMS compatibility matrix, unless a Supervisor
--    has already set them in Products & settings → PMS integrations.
-- 3. Lets Management see Management → Products (with the new "By PMS and interface" section).

-- 1. SamsoSuite products (added only if a product of that name doesn't exist yet)
update public.docs d
set doc = jsonb_set(d.doc, '{products}', coalesce(d.doc->'products','[]'::jsonb) || (
  select coalesce(jsonb_agg(jsonb_build_object('name', n, 'active', true, 'repeatable', false) order by o), '[]'::jsonb)
  from unnest(array[
    'SamsoSuite Passport / ID Scanning','SamsoSuite eREG','SamsoSuite eREG Plus','SamsoSuite F&B','SamsoSuite Mailer',
    'SamsoSuite Samso Sign','SamsoSuite Online Check-in','SamsoSuite Kiosk on Payment Device','SamsoSuite House Keeping'
  ]) with ordinality as t(n, o)
  where not exists (select 1 from jsonb_array_elements(coalesce(d.doc->'products','[]'::jsonb)) p
                    where lower(trim(coalesce(p->>'name', p #>> '{}'))) = lower(n))))
where d.path = 'config/settings';

-- 2. PMS settings (only when not set yet)
update public.docs set doc = doc || '{"pmsList":["OPERA Cloud","OPERA 5 / V5","Protel","Mews","Cloudbeds","Other"]}'::jsonb
where path = 'config/settings' and not (doc ? 'pmsList');
update public.docs set doc = doc || '{"pmsIfaces":["OHIP","OPP_KSK","OWS","OXI","FIAS","Standalone","Vendor API","File export"]}'::jsonb
where path = 'config/settings' and not (doc ? 'pmsIfaces');
update public.docs set doc = doc || '{"pmsCols":["OPERA Cloud","OPERA 5 / V5"]}'::jsonb
where path = 'config/settings' and not (doc ? 'pmsCols');
update public.docs set doc = doc || jsonb_build_object('pmsMatrix', '{
  "SamsoSuite Passport / ID Scanning":   {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite eREG":                     {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite eREG Plus":                {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite F&B":                      {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite Mailer":                   {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite Samso Sign":               {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite Online Check-in":          {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite Kiosk on Payment Device":  {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "SamsoSuite House Keeping":            {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":[],"*":[]},
  "eREG": {"OPERA Cloud":["OHIP"],"OPERA 5 / V5":["Standalone","OPP_KSK","OWS"],"*":["Standalone"]}
}'::jsonb)
where path = 'config/settings' and not (doc ? 'pmsMatrix');

-- 3. Management can open Management → Products
update public.docs
set doc = jsonb_set(doc, '{roles,management}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'management','[]'::jsonb) || '["report.products"]'::jsonb) x))
where path = 'config/permissions';

-- Check
select (select count(*) from jsonb_array_elements(doc->'products') p where p->>'name' like 'SamsoSuite %') as samsosuite_products,
       jsonb_object_keys_count.n as matrix_rows
from public.docs, lateral (select count(*) n from jsonb_object_keys(doc->'pmsMatrix')) jsonb_object_keys_count
where path = 'config/settings';
