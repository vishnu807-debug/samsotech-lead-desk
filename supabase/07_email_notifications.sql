-- Lead Desk · automatic emails to sales engineers
--   • when a lead is assigned to them
--   • when a follow-up they scheduled is due
-- Run this AFTER deploying the lead-mailer Edge Function (see README, "Automatic emails").
-- Before running, replace the two values in the "Your settings" block below.

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------- Your settings ------------------------------------------
create table if not exists public.mailer_config (
  id            int primary key default 1 check (id = 1),
  function_url  text not null,
  secret        text not null
);
alter table public.mailer_config enable row level security;   -- no policies: only the database itself can read it

insert into public.mailer_config (id, function_url, secret) values (
  1,
  'https://YOUR-PROJECT-REF.supabase.co/functions/v1/lead-mailer',   -- ← your function URL
  'PASTE-THE-SAME-MAILER_SECRET-YOU-SET-ON-THE-FUNCTION'              -- ← same value as the MAILER_SECRET secret
) on conflict (id) do update set function_url = excluded.function_url, secret = excluded.secret;

-- ---------- Helpers the function calls -----------------------------
-- Records that an email went out, without touching anything else on the lead.
create or replace function public.mark_lead_mail(p_id text, p_field text, p_value text) returns void
language sql security definer set search_path = public as $$
  update public.leads set doc = doc || jsonb_build_object(p_field, p_value) where id = p_id
    and p_field in ('assignedMailFor', 'followUpRemindedFor');
$$;

-- Follow-ups that are due now and haven't been emailed yet (ignores ones more than 2 days overdue).
create or replace function public.due_followups()
returns table (id text, account text, email text, due timestamptz, followup text, note text, doc jsonb)
language sql stable security definer set search_path = public as $$
  select * from (
    select l.id, l.doc->>'accountName', m.email,
           case
             when coalesce(l.doc->>'nextFollowUpAt','') <> '' then (l.doc->>'nextFollowUpAt')::timestamptz
             when l.doc->>'nextFollowUp' like '%T%' then (l.doc->>'nextFollowUp')::timestamp at time zone 'Asia/Dubai'
             else ((l.doc->>'nextFollowUp')::date + time '09:00') at time zone 'Asia/Dubai'
           end as due,
           l.doc->>'nextFollowUp', l.doc->>'followUpNote', l.doc
    from public.leads l
    join public.members m on m.active and m.role = 'sales' and lower(m.engineer) = lower(l.assigned_to)
    where coalesce(l.doc->>'nextFollowUp','') <> ''
      and l.status in ('Assigned','Meeting Done','Quotation Sent','On Hold')
      and coalesce(l.doc->>'followUpRemindedFor','') <> l.doc->>'nextFollowUp'
  ) x
  where x.due <= now() and x.due > now() - interval '2 days'
$$;

revoke execute on function public.mark_lead_mail(text, text, text) from public, anon, authenticated;
revoke execute on function public.due_followups() from public, anon, authenticated;
grant  execute on function public.mark_lead_mail(text, text, text) to service_role;
grant  execute on function public.due_followups() to service_role;

-- ---------- New lead assigned → email ------------------------------
create or replace function public.notify_lead_assigned() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if coalesce(new.assigned_to, '') = '' then return new; end if;
  if new.status not in ('Assigned','Meeting Done','Quotation Sent','On Hold') then return new; end if;   -- not while waiting for back office
  if tg_op = 'UPDATE' and lower(coalesce(old.assigned_to, '')) = lower(new.assigned_to)
     and old.status = new.status then return new; end if;                                               -- nothing relevant changed
  if tg_op = 'UPDATE' and lower(coalesce(old.assigned_to, '')) = lower(new.assigned_to)
     and old.status not in ('New','Info Needed') then return new; end if;                               -- same engineer, just a stage change
  if coalesce(new.doc->>'assignedMailFor', '') = new.assigned_to then return new; end if;               -- already emailed
  if lower(coalesce(new.doc->>'generatedBy', '')) = lower(new.assigned_to) then return new; end if;  -- engineer's own outbound lead
  if coalesce(new.doc->>'imported', 'false') = 'true' and tg_op = 'INSERT' then return new; end if;     -- bulk imports stay quiet
  select * into c from public.mailer_config where id = 1;
  if c.function_url is null or c.function_url like '%YOUR-PROJECT-REF%' then return new; end if;
  perform net.http_post(
    url     := c.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-mailer-secret', c.secret),
    body    := jsonb_build_object('type', 'assigned', 'lead_id', new.id));
  return new;
end $$;

drop trigger if exists leads_assigned_mail on public.leads;
create trigger leads_assigned_mail after insert or update on public.leads
  for each row execute function public.notify_lead_assigned();

-- ---------- Follow-up reminders: check every 10 minutes ------------
do $$ begin perform cron.unschedule('lead-desk-followups'); exception when others then null; end $$;
select cron.schedule('lead-desk-followups', '*/10 * * * *', $cron$
  select net.http_post(
    url     := (select function_url from public.mailer_config where id = 1),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-mailer-secret', (select secret from public.mailer_config where id = 1)),
    body    := '{"type":"followups"}'::jsonb)
  where exists (select 1 from public.mailer_config where id = 1 and function_url not like '%YOUR-PROJECT-REF%');
$cron$);
