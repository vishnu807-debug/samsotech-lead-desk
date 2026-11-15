-- Lead Desk · Full data export (backup)                                    15 Nov 2026
-- Run in Supabase → SQL Editor after file 34. Safe to run again. Changes no existing data.
--
-- What it adds
--   export_begin(kind)  The app calls this before it downloads anything. It refuses anyone
--                       without the "Download a full backup" permission (data.backup: Supervisor only
--                       by default), writes who / when to the audit trail, and returns the number of
--                       rows in every table so the app can show progress and prove the export is complete.
--
-- Nothing secret can be exported: passwords and two-step (MFA) secrets live in Supabase's own
-- sign-in system (the auth schema), which the browser can never read.

create or replace function public.export_begin(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; c jsonb; lab text;
begin
  if not public.has_perm('data.backup') then
    raise exception 'Only a Supervisor can export all Lead Desk data.' using errcode = '42501';
  end if;
  if p_kind not in ('excel','backup') then
    raise exception 'Unknown export type' using errcode = '22023';
  end if;
  lab := case p_kind when 'excel' then 'Excel workbook' else 'backup file' end;
  c := jsonb_build_object(
    'leads',     (select count(*) from public.leads),
    'accounts',  (select count(*) from public.accounts),
    'contracts', (select count(*) from public.contracts),
    'members',   (select count(*) from public.members),
    'docs',      (select count(*) from public.docs),
    'audit_log', (select count(*) from public.audit_log));
  select * into w from public.audit_who();
  insert into public.audit_log(actor, actor_role, source, action, entity, entity_id, summary, changes)
  values (w.actor, w.actor_role, 'app', 'exported', 'report', 'Full export · ' || lab,
          'Started a full data export (' || lab || '): ' || (c->>'leads') || ' leads, ' || (c->>'accounts') || ' accounts, '
          || (c->>'contracts') || ' contracts, ' || (c->>'members') || ' users', c);
  return jsonb_build_object('at', now(), 'by', w.actor, 'counts', c);
end $$;
revoke all on function public.export_begin(text) from public, anon;
grant execute on function public.export_begin(text) to authenticated;

-- Permissions: no new permission. data.backup already exists and stays Supervisor only
-- (Lead Manager, Management, Sales and AMC: off). If the saved permission table keeps a list of
-- known permissions, make sure data.backup is on it so no role can receive it by a default.
update public.docs
   set doc = jsonb_set(doc, '{known}', (select jsonb_agg(distinct x) from jsonb_array_elements_text(coalesce(doc->'known','[]'::jsonb) || '["data.backup"]'::jsonb) x))
 where path = 'config/permissions' and doc ? 'known' and not (doc->'known') ? 'data.backup';

select 'export_begin ready' as full_export,
       (select string_agg(r.key, ', ') from public.docs d, jsonb_each(d.doc->'roles') r
         where d.path = 'config/permissions' and r.value ? 'data.backup') as other_roles_with_backup_right;
