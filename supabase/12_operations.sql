-- Lead Desk · Operational changes (6 Nov 2026)
-- Run once in Supabase → SQL Editor, after 09, 10 and both 11 files. Safe to run again. No data is changed or removed.
--
--  · Soft delete: a deleted lead keeps all its data, gets doc.deleted = {at, by, reason, note, prevStatus},
--    disappears from lists, counts and reports, and can be restored. Only roles with "lead.remove"
--    (Supervisor, Lead Manager) can delete or restore, enforced here as well as in the app.
--  · The country of an approved lead can only be changed by roles with "lead.edit_country" (Supervisor, Lead Manager).
--  · Meeting dates on Won leads can only be changed by roles with "meeting.edit_won" (Supervisor).
--  · New permissions for Lead Manager: lead.remove, lead.edit_country.

-- 1. Permission table: give Lead Manager the two new permissions
update public.docs
set doc = jsonb_set(doc, '{roles,leadmanager}',
      (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(doc->'roles'->'leadmanager','[]'::jsonb) || '["lead.remove","lead.edit_country"]'::jsonb) x))
where path = 'config/permissions';

-- 2. Guard: delete / restore and Won-meeting dates need their own permission, even through the API
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
  if os = 'Won' and not public.has_perm('meeting.edit_won') and exists (
       select 1 from jsonb_array_elements(coalesce(old.doc->'meetings','[]'::jsonb)) o
       join jsonb_array_elements(coalesce(new.doc->'meetings','[]'::jsonb)) n on n->>'id' = o->>'id'
       where (n->>'date') is distinct from (o->>'date')) then
    raise exception 'Only a Supervisor can change meeting dates on a won lead.' using errcode = '42501';
  end if;
  return new;
end $$;

-- 3. Sales engineers no longer see their deleted leads
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads for select to authenticated
  using (
    (select public.has_perm('lead.view_all'))
    or ((doc->>'deleted') is null and (select public.my_engineer()) <> '' and lower(coalesce(assigned_to,'')) = lower((select public.my_engineer())))
  );

-- 4. Leads are soft-deleted from the app; removing a row for good stays Supervisor-only
drop policy if exists leads_delete on public.leads;
create policy leads_delete on public.leads for delete to authenticated
  using ((select public.my_role()) = 'supervisor');

-- 5. Deleted leads don't lock products or send follow-up reminders
create or replace function public.product_locks(p_account text)
returns table(product text, ref text, status text, assigned_to text)
language sql stable security definer set search_path = public as $$
  select p.value, l.id, l.status, l.assigned_to
  from public.leads l, jsonb_array_elements_text(coalesce(l.doc->'products', jsonb_build_array(l.doc->>'product'))) p
  where public.my_role() is not null
    and l.account_key = p_account
    and (l.doc->>'deleted') is null
    and l.status in ('New','Info Needed','Assigned','Meeting Done','Quotation Sent','On Hold','Won')
$$;

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
      and (l.doc->>'deleted') is null
      and l.status in ('Assigned','Meeting Done','Quotation Sent','On Hold')
      and coalesce(l.doc->>'followUpRemindedFor','') <> l.doc->>'nextFollowUp'
  ) x
  where x.due <= now() and x.due > now() - interval '2 days'
$$;
revoke execute on function public.due_followups() from public, anon, authenticated;
grant  execute on function public.due_followups() to service_role;

-- 6. Audit trail: a soft delete is recorded as "Deleted" with its reason, a restore as "Restored"
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  w record; rec jsonb; old_j jsonb; new_j jsonb; ch jsonb; ent text := tg_argv[0]; rid text; act text; summ text; label text;
  noise text[] := array['log','updatedAt','assignedMailFor','followUpRemindedFor','updated_at','added_at'];
begin
  rec := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  rid := rec->>tg_argv[1];
  if tg_table_name in ('leads','accounts','docs') then
    old_j := case when tg_op <> 'INSERT' then to_jsonb(old)->'doc' end;
    new_j := case when tg_op <> 'DELETE' then to_jsonb(new)->'doc' end;
  else
    old_j := case when tg_op <> 'INSERT' then to_jsonb(old) end;
    new_j := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  end if;
  if tg_table_name = 'docs' then
    ent := case rid when 'config/permissions' then 'permissions' when 'config/settings' then 'settings' else 'document' end;
  end if;
  ch := public.audit_diff(old_j, new_j, noise);
  if tg_op = 'UPDATE' and ch = '{}'::jsonb then return null; end if;   -- nothing meaningful changed
  act := case tg_op when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end;
  label := coalesce(new_j->>'accountName', old_j->>'accountName', new_j->>'name', old_j->>'name', '');
  if tg_table_name = 'accounts' and coalesce((new_j->>'deleted')::boolean,false) and not coalesce((old_j->>'deleted')::boolean,false) then
    act := case when new_j ? 'mergedInto' then 'merged' else 'deleted' end;
  end if;
  -- leads are soft-deleted: show it as Deleted / Restored, with the reason, instead of a plain update
  if tg_table_name = 'leads' and tg_op = 'UPDATE' then
    if (new_j->>'deleted') is not null and (old_j->>'deleted') is null then act := 'deleted';
    elsif (new_j->>'deleted') is null and (old_j->>'deleted') is not null then act := 'restored';
    end if;
  end if;
  summ := initcap(act) || ' ' || ent || ' ' || coalesce(rid,'') || case when label <> '' then ' · ' || label else '' end;
  if tg_op = 'UPDATE' then
    summ := summ || ': ' || (select string_agg(k, ', ' order by k) from jsonb_object_keys(ch) k);
    if ch ? 'status' then summ := summ || ' (status ' || coalesce(ch->'status'->>'old','—') || ' → ' || coalesce(ch->'status'->>'new','—') || ')'; end if;
    if act = 'deleted' then summ := summ || ' · reason: ' || coalesce(new_j->'deleted'->>'reason','—')
       || case when coalesce(new_j->'deleted'->>'note','') <> '' then ' (' || (new_j->'deleted'->>'note') || ')' else '' end; end if;
    if ch ? 'assignedTo' then summ := summ || ' (assigned ' || coalesce(nullif(ch->'assignedTo'->>'old',''),'nobody') || ' → ' || coalesce(nullif(ch->'assignedTo'->>'new',''),'nobody') || ')'; end if;
  end if;
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, w.source, act, ent, rid, summ, case when tg_op = 'UPDATE' then ch else null end);
  return null;
end $$;

-- Check: Lead Manager permissions now include lead.remove and lead.edit_country
select doc->'roles'->'leadmanager' as lead_manager_permissions from public.docs where path = 'config/permissions';
