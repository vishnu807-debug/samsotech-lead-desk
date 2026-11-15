-- Lead Desk · OHIP rules for AMC contracts (12 Nov 2026)
-- Run once in Supabase → SQL Editor, after 28_contracts.sql. Safe to run again. No leads or contracts are changed.
--
-- 1. Adds "DayLight PMS" and "HotelKey PMS" to the PMS list, if they are not there.
-- 2. Starting OHIP rules (only if none exist): when the hotel's PMS is OPERA Cloud, each solution on a contract
--    needs its own yearly OHIP line. Prices per room and minimums start empty: the Supervisor enters them in
--    Products & settings → OHIP rules. Rules can be changed there afterwards; this file never overwrites them.
--      eREG Plus (subscription)              → Annual OHIP charges (eREG Plus)     sold with OPERA Cloud, DayLight PMS or HotelKey PMS
--      eREG Plus (On-premise)                → no OHIP                            for OPERA V5 clients
--      eREG                                  → Annual OHIP charges (eREG)
--      Passport / ID scanning PMS interface  → Annual OHIP charges (ID scanning)  shown as "VICAS PMS interface (Opera Cloud-OHIP)" once OHIP is on the contract
--      VICAS (UAE, Dubai, Italy, …)          → Annual OHIP charges (VICAS)
--      Samsotech Diamond interface (Dubai)   → Annual OHIP charges (VICAS-Diamond)
--      easyKiosk                             → Annual OHIP charges (easyKiosk)
--      Mirror                                → Annual OHIP charges (Mirror)

update public.docs
set doc = jsonb_set(doc, '{pmsList}', coalesce(doc->'pmsList','[]'::jsonb)
      || (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text('["DayLight PMS","HotelKey PMS"]'::jsonb) x
          where not exists (select 1 from jsonb_array_elements(coalesce(doc->'pmsList','[]'::jsonb)) p
                            where lower(case when jsonb_typeof(p) = 'string' then p #>> '{}' else p->>'name' end) = lower(x))))
where path = 'config/settings';

update public.docs
set doc = jsonb_set(doc, '{ohip}', $ohip$
{
 "pms": [
  "OPERA Cloud"
 ],
 "legacy": [
  "OPERA 5 / V5"
 ],
 "rules": [
  {
   "id": "eregplus",
   "name": "eREG Plus (subscription)",
   "text": "ereg\\s*plus",
   "notText": "on[- ]?premise",
   "label": "eREG Plus",
   "keys": [
    "eREGPlus"
   ],
   "pmsOnly": [
    "OPERA Cloud",
    "DayLight PMS",
    "HotelKey PMS"
   ],
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "eregplusop",
   "name": "eREG Plus (On-premise)",
   "text": "ereg\\s*plus.*on[- ]?premise",
   "pmsOnly": [
    "OPERA 5 / V5"
   ],
   "noOhip": true,
   "active": true
  },
  {
   "id": "ereg",
   "name": "eREG",
   "text": "\\bereg\\b",
   "notText": "plus",
   "label": "eREG",
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "idscan",
   "name": "Passport / ID scanning PMS interface",
   "text": "pms\\s+interface",
   "notText": "diamond",
   "label": "ID scanning",
   "keys": [
    "ID scanner",
    "Passport scanning",
    "Passport scanner",
    "IDscanning"
   ],
   "rename": "VICAS PMS interface (Opera Cloud-OHIP)",
   "renameText": "vicas.*pms\\s+interface",
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "vicas",
   "name": "VICAS",
   "text": "\\bvicas\\b",
   "notText": "pms\\s+interface|diamond",
   "label": "VICAS",
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "diamond",
   "name": "VICAS-Diamond",
   "text": "diamond\\s+interface",
   "place": "Dubai",
   "label": "VICAS-Diamond",
   "keys": [
    "VICAS Diamond"
   ],
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "easykiosk",
   "name": "easyKiosk",
   "text": "easy\\s*kiosk",
   "label": "easyKiosk",
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  },
  {
   "id": "mirror",
   "name": "Mirror",
   "text": "\\bmirror\\b",
   "label": "Mirror",
   "perRoom": null,
   "min": null,
   "cur": "USD",
   "active": true
  }
 ]
}
$ohip$::jsonb)
where path = 'config/settings' and not (doc ? 'ohip');

-- Check
select doc->'pmsList' as pms_list, jsonb_array_length(doc->'ohip'->'rules') as ohip_rules, doc->'ohip'->'pms' as applies_to
from public.docs where path = 'config/settings';
