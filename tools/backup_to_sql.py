#!/usr/bin/env python3
"""Lead Desk · turn a backup file into SQL that restores it.

    python3 tools/backup_to_sql.py LeadDesk_Backup_2026-11-15_1235.json  >  restore.sql

Then, in a Supabase project where files 01 to 36 have been run, paste restore.sql into the SQL Editor
(or split it if it is large) and run it. Rows that already exist are left alone: nothing is overwritten
or deleted, so it is safe to run twice. Passwords are not in a backup: people sign in again with a
password reset (Users and access → Reset password). Two-step sign-in is set up again by each person.
"""
import json, sys

def q(v):                      # a text value
    return "null" if v is None else "$ld$" + str(v).replace("$ld$", "$ ld $") + "$ld$"
def j(v):                      # a json value
    return "null" if v is None else q(json.dumps(v, ensure_ascii=False)) + "::jsonb"

def main(path):
    b = json.load(open(path, encoding="utf-8"))
    if b.get("app") != "Lead Desk" or "tables" not in b:
        sys.exit("This is not a Lead Desk backup file.")
    t = b["tables"]; out = []
    out.append(f"-- Lead Desk restore · backup of {b.get('createdAt','?')} by {b.get('createdBy','?')} · format {b.get('format')}")
    if not b.get("complete", True): out.append("-- WARNING: this backup was marked incomplete: " + " ".join(b.get("notes") or []))
    out.append("begin;")
    for r in t.get("docs", []):
        out.append(f"insert into public.docs(path, doc) values ({q(r['path'])}, {j(r['doc'])}) on conflict (path) do nothing;")
    for r in t.get("members", []):
        cols = [c for c in ("email", "role", "engineer", "active", "added_at", "added_by", "display_name") if c in r]
        vals = [("true" if r[c] else "false") if isinstance(r[c], bool) else q(r[c]) for c in cols]
        out.append(f"insert into public.members({', '.join(cols)}) values ({', '.join(vals)}) on conflict (email) do nothing;")
    for r in t.get("accounts", []):
        out.append(f"insert into public.accounts(key, doc) values ({q(r['key'])}, {j(r['doc'])}) on conflict (key) do nothing;")
    for r in t.get("leads", []):
        out.append(f"insert into public.leads(id, doc) values ({q(r['id'])}, {j(r['doc'])}) on conflict (id) do nothing;")
    for r in t.get("contracts", []):
        out.append(f"insert into public.contracts(id, doc) values ({q(r['id'])}, {j(r['doc'])}) on conflict (id) do nothing;")
    for r in t.get("audit_log", []):
        out.append("insert into public.audit_log(id, at, actor, actor_role, source, action, entity, entity_id, summary, changes) overriding system value values "
                   f"({int(r['id'])}, {q(r.get('at'))}, {q(r.get('actor') or 'system')}, {q(r.get('actor_role'))}, {q(r.get('source') or 'app')}, {q(r.get('action'))}, {q(r.get('entity'))}, {q(r.get('entity_id'))}, {q(r.get('summary'))}, {j(r.get('changes'))}) on conflict (id) do nothing;")
    out.append("select setval(pg_get_serial_sequence('public.audit_log','id'), greatest((select coalesce(max(id),1) from public.audit_log), 1));")
    out.append("commit;")
    out.append("select (select count(*) from public.leads) as leads, (select count(*) from public.accounts) as accounts, (select count(*) from public.contracts) as contracts, (select count(*) from public.members) as users, (select count(*) from public.docs) as settings_documents;")
    sys.stdout.write("\n".join(out) + "\n")

if __name__ == "__main__":
    if len(sys.argv) != 2: sys.exit(__doc__)
    main(sys.argv[1])
