-- Lead Desk · Two-step sign-in (MFA with an authenticator app)             15 Nov 2026
-- Run in Supabase → SQL Editor after file 35. Safe to run again. Changes no existing data.
-- If you ever run 01_schema.sql or 09_rbac.sql again, run this file again afterwards
-- (they re-create my_role() and my_engineer() without the two-step check).
--
-- The rule lives in Products & settings → Users and access and is stored in settings.mfa:
--   {"mode": "off" | "optional" | "required",          for everyone
--    "roles": {"sales": "required", …},                overrides per role
--    "users": {"name@company.com": "off", …}}          overrides per person (strongest)
--
-- What the database enforces
--   * A person whose rule is "required", or who has switched two-step sign-in on, gets NO data
--     until the 6-digit code has been entered in this session (Supabase marks that session "aal2").
--     Enforced twice: a restrictive rule on every table, and inside my_role() / my_engineer(),
--     which every other rule and database function asks.
--   * The rule can only be changed through set_mfa_policy() (permission users.manage: Supervisor by
--     default), which refuses to make two-step sign-in required for the person changing it before
--     their own authenticator is set up, and writes the change to the audit trail.
--   * Saving the settings in any other way leaves settings.mfa as it was.

-- ---------- 1. Helpers ----------------------------------------------------
create or replace function public.mfa_mode_for(p_email text, p_role text, p_cfg jsonb) returns text
language sql immutable as $$
  select case when v in ('off','optional','required') then v else 'off' end
  from (select coalesce(nullif(p_cfg->'users'->>lower(coalesce(p_email,'')),''),
                        nullif(p_cfg->'roles'->>(case p_role when 'backoffice' then 'supervisor' else p_role end),''),
                        nullif(p_cfg->>'mode',''), 'off') as v) x
$$;

-- Has this sign-in a confirmed authenticator? (reads Supabase's own table; never exposes the secret)
create or replace function public.mfa_has(p_uid uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if p_uid is null then return false; end if;
  return exists (select 1 from auth.mfa_factors f where f.user_id = p_uid and f.status::text = 'verified');
exception when undefined_table or insufficient_privilege then return false;
end $$;

-- True when this session may see data. System jobs and the SQL editor (no signed-in user) are not affected.
create or replace function public.mfa_ok() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare em text := public.my_email(); r text; cfg jsonb;
begin
  if em = '' then return true; end if;
  if coalesce(auth.jwt()->>'aal','aal1') = 'aal2' then return true; end if;
  select role into r from public.members where email = em and active;
  if r is null then return true; end if;                       -- not a member: sees nothing anyway
  select doc->'mfa' into cfg from public.docs where path = 'config/settings';
  if public.mfa_mode_for(em, r, coalesce(cfg,'{}'::jsonb)) = 'required' then return false; end if;
  return not public.mfa_has(auth.uid());                       -- switched on by the user: the code is always asked
end $$;

-- ---------- 2. my_role() and my_engineer(): empty until the code is entered ----------
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select case when public.mfa_ok() then
    (select case role when 'backoffice' then 'supervisor' else role end
       from public.members where email = public.my_email() and active) end
$$;
create or replace function public.my_engineer() returns text
language sql stable security definer set search_path = public as $$
  select case when public.mfa_ok() then
    (select coalesce(engineer,'') from public.members where email = public.my_email() and active) end
$$;

-- ---------- 3. A restrictive rule on every table (stays even if older files are run again) ----------
do $$
declare t text;
begin
  foreach t in array array['leads','accounts','docs','members','audit_log','contracts','contract_pages'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists mfa_gate on public.%I', t);
      execute format('create policy mfa_gate on public.%I as restrictive for all to authenticated using ((select public.mfa_ok())) with check ((select public.mfa_ok()))', t);
    end if;
  end loop;
end $$;

-- ---------- 4. What the sign-in screen needs to know (works before the code is entered) ----------
create or replace function public.mfa_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare em text := public.my_email(); r text; cfg jsonb; m text; has boolean; aal text := coalesce(auth.jwt()->>'aal','aal1');
begin
  select role into r from public.members where email = em and active;
  if r is null then return jsonb_build_object('member', false, 'mode', 'off', 'enrolled', false, 'aal', aal, 'need', 'none'); end if;
  select doc->'mfa' into cfg from public.docs where path = 'config/settings';
  m := public.mfa_mode_for(em, r, coalesce(cfg,'{}'::jsonb));
  has := public.mfa_has(auth.uid());
  return jsonb_build_object('member', true, 'mode', m, 'enrolled', has, 'aal', aal,
    'need', case when aal = 'aal2' then 'none' when has then 'code' when m = 'required' then 'setup' else 'none' end);
end $$;

-- Who has two-step sign-in switched on (for the Users list). Never returns secrets.
create or replace function public.mfa_users() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_perm('users.manage') then raise exception 'Not allowed' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(m.email, jsonb_build_object('enrolled', true, 'since', x.since))
    from public.members m
    join auth.users u on lower(u.email) = m.email
    join lateral (select min(f.created_at) as since from auth.mfa_factors f where f.user_id = u.id and f.status::text = 'verified') x on x.since is not null), '{}'::jsonb);
end $$;

-- ---------- 5. Changing the rule ----------
create or replace function public.set_mfa_policy(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare em text := public.my_email(); r text; old jsonb; nw jsonb; roles jsonb := '{}'::jsonb; users jsonb := '{}'::jsonb; k text; v text; w record; md text;
begin
  if not public.has_perm('users.manage') then
    raise exception 'Only a Supervisor can change two-step sign-in.' using errcode = '42501';
  end if;
  md := coalesce(p->>'mode','off');
  if md not in ('off','optional','required') then raise exception 'Unknown setting' using errcode = '22023'; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p->'roles','{}'::jsonb)) loop
    if k in ('supervisor','leadmanager','management','sales','amc') and v in ('off','optional','required') then roles := roles || jsonb_build_object(k, v); end if;
  end loop;
  for k, v in select key, value from jsonb_each_text(coalesce(p->'users','{}'::jsonb)) loop
    if v in ('off','optional','required') and exists (select 1 from public.members where email = lower(k)) then users := users || jsonb_build_object(lower(k), v); end if;
  end loop;
  nw := jsonb_build_object('mode', md, 'roles', roles, 'users', users);
  -- lock-out protection: never "required" for yourself before your own authenticator works
  select role into r from public.members where email = em and active;
  if public.mfa_mode_for(em, r, nw) = 'required' and not public.mfa_has(auth.uid()) then
    raise exception 'Set up two-step sign-in on your own account first (account menu, top right). Then make it required.' using errcode = 'P0001';
  end if;
  select doc->'mfa' into old from public.docs where path = 'config/settings';
  perform set_config('leaddesk.mfa_rpc', '1', true);
  update public.docs set doc = jsonb_set(doc, '{mfa}', nw) where path = 'config/settings';
  perform set_config('leaddesk.mfa_rpc', '', true);
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, 'app', 'mfa_policy', 'settings', 'Two-step sign-in',
          'Two-step sign-in rule changed: everyone ' || md
          || case when roles <> '{}'::jsonb then '; by role ' || roles::text else '' end
          || case when users <> '{}'::jsonb then '; by person ' || users::text else '' end,
          jsonb_build_object('mfa', jsonb_build_object('old', old, 'new', nw)));
  return nw;
end $$;

-- settings.mfa cannot be changed by an ordinary settings save
create or replace function public.guard_mfa_setting() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.path <> 'config/settings' or coalesce(auth.role(),'') <> 'authenticated' then return new; end if;   -- SQL editor, service jobs
  if coalesce(current_setting('leaddesk.mfa_rpc', true),'') = '1' then return new; end if;
  if tg_op = 'INSERT' then new.doc := new.doc - 'mfa'; return new; end if;
  if (new.doc->'mfa') is distinct from (old.doc->'mfa') then
    new.doc := case when old.doc ? 'mfa' then jsonb_set(new.doc, '{mfa}', old.doc->'mfa') else new.doc - 'mfa' end;
  end if;
  return new;
end $$;
drop trigger if exists docs_mfa_guard on public.docs;
create trigger docs_mfa_guard before insert or update on public.docs
  for each row execute function public.guard_mfa_setting();

-- ---------- 6. Audit: a person switched their own two-step sign-in on or off ----------
-- The database checks the claim against Supabase's own record before writing it.
create or replace function public.mfa_log(p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare em text := public.my_email(); r text; has boolean := public.mfa_has(auth.uid());
begin
  select role into r from public.members where email = em and active;
  if r is null then return; end if;
  if p_action = 'mfa_enabled' and has then
    insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary)
    values (em, r, 'app', 'mfa_enabled', 'user', em, 'Switched two-step sign-in on (authenticator app)');
  elsif p_action = 'mfa_disabled' and not has then
    insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary)
    values (em, r, 'app', 'mfa_disabled', 'user', em, 'Switched two-step sign-in off');
  else
    raise exception 'Nothing to record' using errcode = '22023';
  end if;
end $$;

revoke all on function public.mfa_ok(), public.mfa_state(), public.mfa_users(), public.set_mfa_policy(jsonb), public.mfa_log(text), public.mfa_has(uuid), public.guard_mfa_setting() from public, anon;
grant execute on function public.mfa_ok(), public.mfa_state(), public.mfa_users(), public.set_mfa_policy(jsonb), public.mfa_log(text) to authenticated;
grant execute on function public.my_role(), public.my_engineer() to authenticated;

-- Permissions: no new permission. The rule and "Reset two-step" use users.manage
-- (Supervisor: on · Lead Manager, Management, Sales, AMC: off). Starting value: off for everyone.
update public.docs set doc = jsonb_set(doc, '{mfa}', '{"mode":"off","roles":{},"users":{}}'::jsonb)
 where path = 'config/settings' and not doc ? 'mfa';

select doc->'mfa' as two_step_rule,
       (select count(*) from pg_policy where polname = 'mfa_gate') as tables_protected
  from public.docs where path = 'config/settings';
