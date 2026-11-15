# Database rules for Part A (export + two-step sign-in), per role, on a local Postgres with Supabase stand-ins.
import subprocess, json, sys
def sql(db, q, claims=None):
    pre = ""
    if claims is not None:
        pre = "set role authenticated; select set_config('request.jwt.claims', $j$%s$j$, false);" % json.dumps(claims)
    r = subprocess.run(["su","postgres","-c",f"psql -X -q -At -v ON_ERROR_STOP=1 -d {db}"], input=pre+q, capture_output=True, text=True)
    out=[l for l in r.stdout.strip().split("\n") if l!=""]
    if claims is not None and out: out=out[1:]   # drop the set_config echo
    return ("ERR:"+r.stderr.strip().split("\n")[0]) if r.returncode else "\n".join(out)
eng = sql("ld1","select doc->>'assignedTo' from leads where coalesce(doc->>'assignedTo','')<>'' group by 1 order by count(*) desc limit 1")
U = {"sup":("sup@t.co","supervisor",None),"lm":("lm@t.co","leadmanager",None),"mg":("mg@t.co","management",None),"sales":("sales@t.co","sales",eng),"amc":("amc@t.co","amc",None)}
UID = {k:"00000000-0000-0000-0000-00000000000%d"%i for i,k in enumerate(U,1)}
for db in ("ldb","ld1"):
    for k,(e,r,g) in U.items():
        sql(db, f"insert into members(email,role,engineer) values ('{e}','{r}',{('$$'+g+'$$') if g else 'null'}) on conflict do nothing; insert into auth.users(id,email) values ('{UID[k]}','{e}') on conflict do nothing;")
def C(k, aal="aal1"): return {"sub":UID[k],"email":U[k][0],"role":"authenticated","aal":aal}
ok=0; bad=0
def chk(name, got, want):
    global ok,bad
    good = want(got) if callable(want) else got==want
    ok+=good; bad+=(not good); print(("PASS " if good else "FAIL ")+name+("" if good else f"   got: {got!r}"))
CNT = "select (select count(*) from leads)||'/'||(select count(*) from docs)||'/'||(select count(*) from members)||'/'||(select count(*) from contracts)||'/'||(select count(*) from audit_log)"
# 0. nothing changes while the rule is off
for k in U:
    chk(f"rule off: {k} reads exactly what it read before files 35/36", sql("ld1",CNT,C(k)).rsplit('/',1)[0], sql("ldb",CNT,C(k)).rsplit('/',1)[0])
chk("sales reads some leads but not all", sql("ld1","select count(*) from leads",C("sales")), lambda v: 0<int(v)<1043)
# 1. export
for k in U:
    r = sql("ld1","select public.export_begin('backup')->'counts'->>'leads'",C(k))
    chk(f"export_begin as {k}: {'allowed' if k=='sup' else 'refused'}", r, (lambda v: v=='1043') if k=='sup' else (lambda v: v.startswith('ERR') and 'Supervisor' in v))
chk("export is written to the audit trail with who", sql("ld1","select actor||'|'||action||'|'||entity_id from audit_log where action='exported' order by id desc limit 1"), "sup@t.co|exported|Full export · backup file")
chk("refused exports leave no audit row", sql("ld1","select count(*) from audit_log where action='exported'"), "1")
chk("unknown export type refused", sql("ld1","select public.export_begin('x')",C("sup")), lambda v: v.startswith("ERR"))
chk("not signed in: export refused", sql("ld1","select public.export_begin('excel')",{"role":"anon"}), lambda v: v.startswith("ERR"))
# 2. two-step: changing the rule
REQ = """select public.set_mfa_policy('{"mode":"required"}'::jsonb)->>'mode'"""
for k in ("lm","mg","sales","amc"):
    chk(f"set rule as {k}: refused", sql("ld1",REQ,C(k)), lambda v: v.startswith("ERR") and "Supervisor" in v)
chk("lock-out: Supervisor cannot require it before own set-up", sql("ld1",REQ,C("sup")), lambda v: v.startswith("ERR") and "own account first" in v)
chk("Supervisor can set Optional without own set-up", sql("ld1","""select public.set_mfa_policy('{"mode":"optional"}'::jsonb)->>'mode'""",C("sup")), "optional")
sql("ld1", f"insert into auth.mfa_factors(user_id,status) values ('{UID['sup']}','unverified')")
chk("an unfinished set-up does not count", sql("ld1",REQ,C("sup")), lambda v: v.startswith("ERR"))
sql("ld1", f"update auth.mfa_factors set status='verified' where user_id='{UID['sup']}'")
chk("Supervisor with authenticator but no code this session: no data", sql("ld1",CNT,C("sup")), "0/0/0/0/0")
chk("…and cannot change the rule", sql("ld1",REQ,C("sup")), lambda v: v.startswith("ERR"))
chk("mfa_state says: enter code", sql("ld1","select public.mfa_state()->>'need'",C("sup")), "code")
chk("Supervisor after the code: can require it", sql("ld1",REQ,C("sup","aal2")), "required")
chk("rule change is in the audit trail", sql("ld1","select actor||'|'||action from audit_log where action='mfa_policy' order by id desc limit 1"), "sup@t.co|mfa_policy")
# 3. required: no data before set-up, for every role, tables and functions
for k in ("lm","mg","sales","amc"):
    chk(f"required, {k} not set up: sees no rows", sql("ld1",CNT,C(k)), "0/0/0/0/0")
    chk(f"required, {k}: mfa_state says set up", sql("ld1","select public.mfa_state()->>'need'",C(k)), "setup")
chk("required: role is empty for functions", sql("ld1","select coalesce(public.my_role(),'-')||coalesce(public.my_engineer(),'-')||public.has_perm('lead.edit_own')",C("sales")), "--false")
chk("required: account search function returns nothing", sql("ld1","select count(*) from public.find_accounts('hotel')",C("sales")), lambda v: v=="0" or v.startswith("ERR"))
chk("required: cannot write a lead", sql("ld1","update leads set doc=doc where true returning 1",C("sales")), "")
chk("required: cannot insert a lead", sql("ld1","insert into leads(id,doc) values ('X1','{}')",C("sales")), lambda v: v.startswith("ERR"))
chk("required: cannot write audit event", sql("ld1","select public.log_event('signed_in','session'); select count(*) from audit_log where action='signed_in'",C("sales")), "0")
sql("ld1", f"insert into auth.mfa_factors(user_id,status) values ('{UID['sales']}','verified')")
chk("sales set up, code not entered: still no rows", sql("ld1",CNT,C("sales")), "0/0/0/0/0")
chk("sales after the code: same leads as before", sql("ld1","select count(*) from leads",C("sales","aal2")), sql("ldb","select count(*) from leads",C("sales")))
chk("supervisor after the code: all leads", sql("ld1","select count(*) from leads",C("sup","aal2")), "1043")
# 4. overrides
P = lambda j: "select public.set_mfa_policy('%s'::jsonb)" % json.dumps(j)
sql("ld1",P({"mode":"required","users":{"mg@t.co":"off"}}),C("sup","aal2"))
chk("per person 'off' beats 'required for everyone'", sql("ld1","select count(*) from leads",C("mg")), "1043")
chk("…others stay blocked", sql("ld1","select count(*) from leads",C("lm")), "0")
sql("ld1",P({"mode":"off","roles":{"leadmanager":"required"}}),C("sup","aal2"))
chk("per role 'required' with everyone 'off': Lead Manager blocked", sql("ld1","select count(*) from leads",C("lm")), "0")
chk("…Management not blocked", sql("ld1","select count(*) from leads",C("mg")), "1043")
chk("rule 'off' but user has it on: code still asked", sql("ld1","select count(*) from leads",C("sales")), "0")
chk("AMC unaffected when not required", sql("ld1","select count(*) from leads",C("amc")), sql("ldb","select count(*) from leads",C("amc")))
chk("unknown role / value ignored", sql("ld1","""select public.set_mfa_policy('{"mode":"off","roles":{"boss":"required","sales":"maybe"},"users":{"nobody@x.y":"required"}}'::jsonb)::text""",C("sup","aal2")), '{"mode": "off", "roles": {}, "users": {}}')
# 5. the rule cannot be changed by an ordinary settings save
sql("ld1",P({"mode":"optional"}),C("sup","aal2"))
sql("ld1","""update docs set doc = doc || '{"mfa":{"mode":"off"},"zzTest":1}'::jsonb where path='config/settings'""",C("sup","aal2"))
chk("settings save cannot change the rule, other settings still save", sql("ld1","select (doc->'mfa'->>'mode')||'/'||(doc->>'zzTest') from docs where path='config/settings'"), "optional/1")
sql("ld1","update docs set doc = doc - 'zzTest' where path='config/settings'")
# 6. users list + self on/off audit
chk("mfa_users as Supervisor lists who has it on", sql("ld1","select (select string_agg(k,',' order by k) from jsonb_object_keys(public.mfa_users()) k)",C("sup","aal2")), "sales@t.co,sup@t.co")
chk("mfa_users as sales: refused", sql("ld1","select public.mfa_users()",C("sales","aal2")), lambda v: v.startswith("ERR"))
chk("'switched on' is recorded only when true", sql("ld1","select public.mfa_log('mfa_enabled')",C("lm")), lambda v: v.startswith("ERR"))
sql("ld1","select public.mfa_log('mfa_enabled')",C("sales","aal2"))
chk("'switched on' recorded for sales", sql("ld1","select actor||'|'||actor_role from audit_log where action='mfa_enabled'"), "sales@t.co|sales")
sql("ld1", f"delete from auth.mfa_factors where user_id='{UID['sales']}'"); sql("ld1","select public.mfa_log('mfa_disabled')",C("sales","aal2"))
chk("'switched off' / reset recorded", sql("ld1","select count(*) from audit_log where action='mfa_disabled'"), "1")
chk("after reset with rule optional: sales reads leads again", sql("ld1","select count(*) from leads",C("sales")), sql("ldb","select count(*) from leads",C("sales")))
chk("system jobs (no signed-in user) are not blocked", sql("ld1","select public.mfa_ok()"), "t")
chk("no lead, account or contract was changed by files 35/36", sql("ld1","select md5(string_agg(id||doc::text,'' order by id)) from leads"), sql("ldb","select md5(string_agg(id||doc::text,'' order by id)) from leads"))
print(f"\n{ok} passed, {bad} failed"); sys.exit(1 if bad else 0)
