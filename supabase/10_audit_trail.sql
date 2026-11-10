-- Lead Desk · Audit trail
-- Run once in Supabase → SQL Editor, after 09_rbac.sql. Safe to run again.
--
-- Every change to leads, accounts, users and settings is written to audit_log by the database
-- itself (triggers), so it is recorded whether it came from the app, an API call, the SQL editor
-- or a scheduled job. The app adds events the database can't see (sign-in, sign-out, password
-- change, exports, presentations). Rows can't be edited or deleted by anyone using the app.
-- Only roles with the "Audit trail" permission (Supervisor by default) can read it.

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       text not null default 'system',     -- email of the signed-in user, or 'system'
  actor_role  text,
  source      text not null default 'app',        -- app (a signed-in user) | system (jobs, SQL editor, functions)
  action      text not null,                      -- created | updated | deleted | signed_in | exported | …
  entity      text not null,                      -- lead | account | user | settings | permissions | session | report
  entity_id   text,
  summary     text,
  changes     jsonb                               -- {"field": {"old": …, "new": …}}
);
create index if not exists audit_log_at_idx     on public.audit_log (at desc);
create index if not exists audit_log_entity_idx on public.audit_log (entity, entity_id);
create index if not exists audit_log_actor_idx  on public.audit_log (actor);

alter table public.audit_log enable row level security;
revoke insert, update, delete, truncate on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated using (public.has_perm('page.audit'));

-- Who is acting right now
create or replace function public.audit_who(out actor text, out actor_role text, out source text)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(public.my_email(),''), 'system'),
         public.my_role(),
         case when coalesce(public.my_email(),'') = '' then 'system' else 'app' end
$$;

-- Field-by-field difference between two JSON objects
create or replace function public.audit_diff(a jsonb, b jsonb, skip text[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('old', a->k, 'new', b->k)), '{}'::jsonb)
  from (select distinct k from jsonb_object_keys(coalesce(a,'{}'::jsonb) || coalesce(b,'{}'::jsonb)) k) x
  where not (k = any(skip)) and (a->k) is distinct from (b->k)
$$;

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
  summ := initcap(act) || ' ' || ent || ' ' || coalesce(rid,'') || case when label <> '' then ' · ' || label else '' end;
  if tg_op = 'UPDATE' then
    summ := summ || ': ' || (select string_agg(k, ', ' order by k) from jsonb_object_keys(ch) k);
    if ch ? 'status' then summ := summ || ' (status ' || coalesce(ch->'status'->>'old','—') || ' → ' || coalesce(ch->'status'->>'new','—') || ')'; end if;
    if ch ? 'assignedTo' then summ := summ || ' (assigned ' || coalesce(nullif(ch->'assignedTo'->>'old',''),'nobody') || ' → ' || coalesce(nullif(ch->'assignedTo'->>'new',''),'nobody') || ')'; end if;
  end if;
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, w.source, act, ent, rid, summ, case when tg_op = 'UPDATE' then ch else null end);
  return null;
end $$;

drop trigger if exists audit_leads    on public.leads;
drop trigger if exists audit_accounts on public.accounts;
drop trigger if exists audit_members  on public.members;
drop trigger if exists audit_docs     on public.docs;
create trigger audit_leads    after insert or update or delete on public.leads    for each row execute function public.audit_row('lead','id');
create trigger audit_accounts after insert or update or delete on public.accounts for each row execute function public.audit_row('account','key');
create trigger audit_members  after insert or update or delete on public.members  for each row execute function public.audit_row('user','email');
create trigger audit_docs     after insert or update or delete on public.docs     for each row execute function public.audit_row('document','path');

-- Events the database can't see on its own (sign-in, exports …), sent by the app.
create or replace function public.log_event(p_action text, p_entity text, p_entity_id text default null, p_summary text default null, p_details jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare w record;
begin
  if public.my_role() is null then return; end if;   -- only active members
  if p_action not in ('signed_in','signed_out','password_changed','exported','presentation','viewed_audit') then
    raise exception 'Unknown audit event' using errcode = '22023';
  end if;
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, 'app', p_action, left(coalesce(p_entity,'session'),40), left(p_entity_id,200), left(p_summary,500), p_details);
end $$;
revoke execute on function public.log_event(text,text,text,text,jsonb) from anon, public;
grant  execute on function public.log_event(text,text,text,text,jsonb) to authenticated;
revoke execute on function public.audit_row() from anon, authenticated, public;
revoke execute on function public.audit_who() from anon, public;

-- Supervisor sees the "Audit trail" page (permission page.audit). Supervisor always has every permission,
-- so nothing else is needed; other roles get it only if a Supervisor ticks it under Roles and permissions.

-- Check: the most recent entries
select at, actor, action, entity, entity_id, summary from public.audit_log order by at desc limit 10;
