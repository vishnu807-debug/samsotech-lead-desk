-- Lead Desk · renewal reminder emails (10 Nov 2026) · OPTIONAL
-- Only for sites that already use the automatic emails (07_email_notifications.sql + the lead-mailer function).
-- Run after 24_amc_renewals.sql, then redeploy the lead-mailer function from this zip. Safe to run again.
-- No leads are changed by running this file.
--
-- Once a day (09:00 Dubai) the order's sales engineer and every active AMC user get ONE email listing the won
-- orders whose 2nd- or 3rd-year renewal has just come within 90, 60 or 30 days (the "alert days" set in
-- Products & settings → AMC and renewals). Each order is mentioned once per step. Orders already marked
-- Renewed or Lost for that year are left out. Amounts are not in the email; they are on the Renewals page.

-- Won orders reaching an alert step today
create or replace function public.due_renewals()
returns table (id text, ref text, account text, engineer text, yr int, due date, days int, step int, products text)
language sql stable security definer set search_path = public as $$
  with cfg as (
    select coalesce(nullif(doc->'amc'->>'startMonths','')::int, 12) as start_m,
           coalesce(doc->'amc'->'alertDays', '[90,60,30]'::jsonb) as alert,
           coalesce(doc->'amc'->'rates', '[]'::jsonb) as rates,
           coalesce(doc->'amc'->'subProducts', '[]'::jsonb) as subs
    from public.docs where path = 'config/settings'),
  won as (
    select l.id, l.doc, l.assigned_to,
           case when left(coalesce(l.doc->'stageAt'->>'Won', l.doc->'order'->>'date', ''), 10) ~ '^\d{4}-\d{2}-\d{2}$'
                then left(coalesce(l.doc->'stageAt'->>'Won', l.doc->'order'->>'date'), 10)::date end as won_on
    from public.leads l where l.status = 'Won' and (l.doc->>'deleted') is null),
  items as (
    select w.id, w.doc, w.assigned_to, y.yr,
           (w.won_on + make_interval(months => c.start_m + (y.yr - 2) * 12))::date as due, c.alert
    from won w cross join cfg c cross join (values (2), (3)) y(yr)
    where w.won_on is not null
      -- the order has something that renews: a product with an AMC rate, or a subscription product
      and (exists (select 1 from jsonb_array_elements(c.rates) r where r->>'product' = '*')
           or exists (select 1 from jsonb_array_elements_text(coalesce(w.doc->'products', '[]'::jsonb) || jsonb_build_array(coalesce(w.doc->>'product',''))) p
                      where p in (select r->>'product' from jsonb_array_elements(c.rates) r)
                         or p in (select jsonb_array_elements_text(c.subs))))),
  stepped as (
    select i.*, (i.due - (now() at time zone 'Asia/Dubai')::date) as days,
           (select min(a::int) from jsonb_array_elements_text(i.alert) a
             where a ~ '^\d+$' and a::int >= (i.due - (now() at time zone 'Asia/Dubai')::date)) as step
    from items i)
  select s.id, s.doc->>'ref', s.doc->>'accountName', s.assigned_to, s.yr, s.due, s.days, s.step,
         (select string_agg(p, ', ') from jsonb_array_elements_text(coalesce(s.doc->'products', '[]'::jsonb)) p)
  from stepped s
  where s.days >= 0 and s.step is not null
    -- not yet emailed for this step
    and coalesce(nullif(s.doc->'renewalMail'->>(s.yr::text), '')::int, 100000) > s.step
    -- not already closed for that year
    and not (exists (select 1 from jsonb_each(coalesce(s.doc->'renewals', '{}'::jsonb)) e
                      where e.key like '%-' || s.yr and e.value->>'st' in ('Renewed', 'Lost'))
             and not exists (select 1 from jsonb_each(coalesce(s.doc->'renewals', '{}'::jsonb)) e
                              where e.key like '%-' || s.yr and coalesce(e.value->>'st', '') not in ('Renewed', 'Lost')))
$$;

-- Records that the reminder went out; touches nothing else on the lead
create or replace function public.mark_renewal_mail(p_id text, p_year int, p_step int) returns void
language sql security definer set search_path = public as $$
  update public.leads
     set doc = jsonb_set(doc, '{renewalMail}', coalesce(doc->'renewalMail', '{}'::jsonb) || jsonb_build_object(p_year::text, p_step))
   where id = p_id and p_year in (2, 3);
$$;

revoke execute on function public.due_renewals() from public, anon, authenticated;
revoke execute on function public.mark_renewal_mail(text, int, int) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.due_renewals() to service_role;
    grant execute on function public.mark_renewal_mail(text, int, int) to service_role;
  end if;
end $$;

-- Daily check at 09:00 Dubai (05:00 UTC), only where the automatic emails are set up
do $$ begin
  if to_regclass('public.mailer_config') is null or not exists (select 1 from pg_namespace where nspname = 'cron') then
    raise notice 'Automatic emails are not set up (07_email_notifications.sql), so no daily renewal email was scheduled.';
    return;
  end if;
  begin perform cron.unschedule('lead-desk-renewals'); exception when others then null; end;
  perform cron.schedule('lead-desk-renewals', '0 5 * * *', $cron$
    select net.http_post(
      url     := (select function_url from public.mailer_config where id = 1),
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-mailer-secret', (select secret from public.mailer_config where id = 1)),
      body    := '{"type":"renewals"}'::jsonb)
    where exists (select 1 from public.mailer_config where id = 1 and function_url not like '%YOUR-PROJECT-REF%');
  $cron$);
end $$;

-- Check: what would be emailed today
select * from public.due_renewals();
