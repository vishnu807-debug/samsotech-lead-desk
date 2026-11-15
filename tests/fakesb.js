/* Test stand-in for supabase-js: in-memory tables with simplified role rules, Supabase-style MFA, RPCs used by Lead Desk.
   Loaded instead of the CDN script. Seed data comes from window.__SEED (real lead sheet dumped from the local Postgres). */
(function () {
  const SEED = window.__SEED;
  const LS = { get: (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set: (k, v) => localStorage.setItem(k, JSON.stringify(v)) };
  const ENG = "Burhan";
  const MEMBERS = [
    { email: "sup@demo.test", role: "supervisor", engineer: null, active: true, added_at: "2026-01-02T08:00:00Z", added_by: "setup", display_name: "Sara Supervisor" },
    { email: "sup2@demo.test", role: "supervisor", engineer: null, active: true, added_at: "2026-01-02T08:00:00Z", added_by: "setup", display_name: "Omar Supervisor" },
    { email: "lm@demo.test", role: "leadmanager", engineer: null, active: true, added_at: "2026-01-03T08:00:00Z", added_by: "sup@demo.test", display_name: "Lina Lead Manager" },
    { email: "mg@demo.test", role: "management", engineer: null, active: true, added_at: "2026-01-03T08:00:00Z", added_by: "sup@demo.test", display_name: "Mark Management" },
    { email: "sales@demo.test", role: "sales", engineer: ENG, active: true, added_at: "2026-01-04T08:00:00Z", added_by: "sup@demo.test", display_name: ENG },
    { email: "amc@demo.test", role: "amc", engineer: null, active: true, added_at: "2026-01-05T08:00:00Z", added_by: "sup@demo.test", display_name: "Asha AMC" },
  ];
  const now = () => new Date().toISOString();
  const ago = (d) => new Date(Date.now() - d * 864e5).toISOString();
  const DB = { leads: JSON.parse(JSON.stringify(SEED.leads)), accounts: JSON.parse(JSON.stringify(SEED.accounts || [])), docs: JSON.parse(JSON.stringify(SEED.docs)), members: MEMBERS, audit_log: [], contracts: [], contract_pages: [] };
  // a spread of stages on the test engineer's leads
  (function shape() {
    const mine = DB.leads.filter((r) => r.doc.assignedTo === ENG && r.doc.status === "Assigned" && !r.doc.deleted);
    const meet = (d) => [{ id: "m1", date: ago(d).slice(0, 10), mode: "Onsite", notes: "Demo of the passport scanner at the front desk" }];
    const quote = (aed, d) => ({ aed, value: aed, currency: "AED", date: ago(d).slice(0, 10), no: "QT-2026/1" + (8000 + d), targetDate: ago(-30).slice(0, 10), nextStep: "Follow up with the IT manager", src: "pdf",
      lines: [{ item: "Passport/ID Scanner 7023", product: "Passport Scanner", unit: 4200, list: 4500, qty: 4, total: 16800 }, { item: "Passport/ID scanning software · PMS interface", product: "Passport Scanner", unit: aed - 16800, list: aed - 16800, qty: 1, total: aed - 16800 }] });
    const set = (i, f) => { if (mine[i]) { f(mine[i].doc); mine[i].updated_at = now(); } };
    set(1, (d) => { d.status = "Meeting Done"; d.meetings = meet(6); d.stageAt = Object.assign({}, d.stageAt, { "Meeting Done": ago(6) }); d.pms = "OPERA Cloud"; });
    set(2, (d) => { d.status = "Quotation Sent"; d.meetings = meet(12); d.quote = quote(48500, 5); d.stageAt = Object.assign({}, d.stageAt, { "Meeting Done": ago(12), "Quotation Sent": ago(5) }); d.pms = "OPERA Cloud"; });
    set(3, (d) => { d.status = "On Hold"; d.meetings = meet(20); d.stageAt = Object.assign({}, d.stageAt, { "Meeting Done": ago(20) }); });
    set(4, (d) => { d.status = "Lost"; d.lost = { reason: "Price", note: "", at: ago(3) }; });
    set(5, (d) => { d.status = "Won"; d.meetings = meet(30); d.quote = quote(62300, 14); d.order = { aed: 62300, value: 62300, currency: "AED", date: ago(4).slice(0, 10), no: "PO-7781", fromQuote: true }; d.stageAt = Object.assign({}, d.stageAt, { "Meeting Done": ago(30), "Quotation Sent": ago(14), Won: ago(4) }); d.pms = "OPERA Cloud"; });
    set(6, (d) => { d.status = "Won"; d.meetings = meet(120); d.quote = quote(91000, 100); d.order = { aed: 91000, value: 91000, currency: "AED", date: ago(80).slice(0, 10), no: "PO-6120", fromQuote: true }; d.stageAt = Object.assign({}, d.stageAt, { "Meeting Done": ago(120), "Quotation Sent": ago(100), Won: ago(80) }); d.pms = "OPERA Cloud"; });
    window.__DEMO = { assigned: mine[0] && mine[0].id, meeting: mine[1] && mine[1].id, quote: mine[2] && mine[2].id, hold: mine[3] && mine[3].id, lost: mine[4] && mine[4].id, wonNew: mine[5] && mine[5].id, wonOld: mine[6] && mine[6].id,
      other: (DB.leads.find((r) => r.doc.assignedTo !== ENG && r.doc.status === "Assigned") || {}).id, gen: null };
    const g = DB.leads.find((r) => r.doc.assignedTo !== ENG && r.doc.status === "Assigned" && r.id !== window.__DEMO.other); if (g) { g.doc.generatedBy = ENG; window.__DEMO.gen = g.id; }
    DB.contracts.push({ id: "C1001", updated_at: ago(9), doc: { id: "C1001", no: "AMC-2026/0412", client: "Demo Grand Hotel", accountName: "Demo Grand Hotel", status: "approved", start: "2026-01-01", end: "2026-12-31", cur: "AED", total: 18400, engineer: ENG, sender: "Asha AMC", pms: "OPERA Cloud", rooms: 220,
      lines: [{ item: "Passport/ID Scanner 7023 · annual maintenance", product: "Passport Scanner", kind: "amc", qty: 4, total: 6400 }, { item: "eREG Plus annual subscription", product: "eREG Plus", kind: "sub", qty: 1, total: 12000 }] } });
    const extra = +(LS.get("fake.auditRows", 0)) || 0;
    for (let i = 1; i <= extra; i++) DB.audit_log.push({ id: i, at: ago(200 - i / 50), actor: MEMBERS[i % 6].email, actor_role: MEMBERS[i % 6].role, source: "app", action: i % 7 ? "updated" : "signed_in", entity: i % 7 ? "lead" : "session", entity_id: "LD2026-" + String(i % 900).padStart(4, "0"), summary: "Sample audit entry " + i, changes: i % 7 ? { status: { old: "Assigned", new: "Meeting Done" } } : null });
  })();
  const settings = () => DB.docs.find((d) => d.path === "config/settings").doc;
  if (LS.get("fake.mfa", null)) settings().mfa = LS.get("fake.mfa"); else if (!settings().mfa) settings().mfa = { mode: "off", roles: {}, users: {} };
  const NOSQL = LS.get("fake.nosql", []);            // names of RPCs to answer "function not found" for
  let FACTORS = LS.get("fake.factors", {});          // email -> [{id,status,factor_type,friendly_name,created_at}]
  const saveF = () => LS.set("fake.factors", FACTORS);
  let session = LS.get("fake.session", null);        // {email, aal, must}
  const saveS = () => LS.set("fake.session", session);
  const listeners = [];
  const emit = (evt) => setTimeout(() => listeners.forEach((f) => f(evt, sess())), 0);
  const sess = () => session && { user: { id: "u-" + session.email, email: session.email, last_sign_in_at: session.at, user_metadata: { must_change_password: !!session.must } }, aal: session.aal };
  const me = () => session && DB.members.find((m) => m.email === session.email && m.active);
  const verified = (email) => (FACTORS[email] || []).filter((f) => f.status === "verified");
  const modeFor = (email, role, cfg) => { cfg = cfg || {}; const v = (cfg.users || {})[email] || (cfg.roles || {})[role] || cfg.mode || "off"; return ["off", "optional", "required"].includes(v) ? v : "off"; };
  const mfaOk = () => { const m = me(); if (!session || !m) return true; if (session.aal === "aal2") return true; if (modeFor(m.email, m.role, settings().mfa) === "required") return false; return !verified(m.email).length; };
  const role = () => (mfaOk() && me() ? me().role : null);
  const eng = () => (mfaOk() && me() ? me().engineer || "" : "");
  const audit = (action, entity, id, summary, changes, actor) => DB.audit_log.push({ id: (DB.audit_log[DB.audit_log.length - 1] || { id: 0 }).id + 1, at: now(), actor: actor || (session && session.email) || "system", actor_role: role(), source: "app", action, entity, entity_id: id || null, summary: summary || null, changes: changes || null });
  const nk = (s) => String(s || "").toLowerCase().trim();
  const CH = {};   // realtime: table -> callbacks
  const live = (t, type, row) => setTimeout(() => (CH[t] || []).forEach((cb) => cb({ eventType: type, new: type === "DELETE" ? {} : JSON.parse(JSON.stringify(row)), old: type === "DELETE" ? row : {} })), 10);
  const KEY = { leads: "id", accounts: "key", docs: "path", members: "email", audit_log: "id", contracts: "id", contract_pages: "contract_id" };
  function canRead(t, r) {
    const R = role(); if (!R) return false;
    if (t === "leads") { if (["supervisor", "leadmanager", "management"].includes(R)) return true; if (R === "amc") return r.doc.status === "Won"; return nk(r.doc.assignedTo) === nk(eng()) || nk(r.doc.generatedBy) === nk(eng()) || (r.doc.joint || []).some((x) => nk(x) === nk(eng())); }
    if (t === "members") return R === "supervisor" || r.email === session.email;
    if (t === "audit_log") return R === "supervisor";
    if (t === "contracts" || t === "contract_pages") return ["supervisor", "amc", "management"].includes(R);
    if (t === "docs") return r.path !== "config/pricebook" || ["supervisor", "management"].includes(R) ? (["config/settings", "config/permissions", "config/references", "config/targets", "config/linerules", "config/pricebook"].includes(r.path) || ["supervisor", "leadmanager", "management"].includes(R)) : false;
    return true;
  }
  function canWrite(t, r) { const R = role(); if (!R) return false; if (R === "supervisor") return true; if (t === "leads") return R === "leadmanager" || (R === "sales" && (!r || nk(r.doc.assignedTo) === nk(eng()))); if (t === "accounts") return ["leadmanager", "sales"].includes(R); if (t === "docs") return R === "leadmanager"; if (t === "contracts") return R === "amc"; return false; }
  const view = (t, r) => (t === "leads" ? Object.assign({ assigned_to: r.doc.assignedTo, status: r.doc.status, account_key: r.doc.accountKey }, r) : r);
  const pick = (row, cols) => { if (!cols || cols === "*") return Object.assign({}, row); const o = {}; cols.split(",").map((c) => c.trim()).forEach((c) => (o[c] = row[c])); return o; };
  window.__FAKE = { DB, calls: [], get session() { return session; }, FACTORS: () => FACTORS, role };
  function Q(t) {
    const q = { t, op: "select", cols: "*", f: [], ord: [], from: 0, to: null, lim: null, single: false, ret: false };
    const api = {
      select(c) { if (q.op === "select") q.cols = c || "*"; else { q.ret = true; q.rcols = c || "*"; } return api; },
      insert(rows) { q.op = "insert"; q.rows = [].concat(rows); return api; },
      upsert(rows, o) { q.op = "upsert"; q.rows = [].concat(rows); q.conf = (o && o.onConflict) || KEY[t]; return api; },
      update(v) { q.op = "update"; q.vals = v; return api; },
      delete() { q.op = "delete"; return api; },
      eq(c, v) { q.f.push((r) => r[c] === v); return api; }, gt(c, v) { q.f.push((r) => r[c] > v); return api; }, in(c, vs) { q.f.push((r) => vs.includes(r[c])); return api; },
      order(c, o) { q.ord.push([c, !(o && o.ascending === false)]); return api; }, gte(c, v) { q.f.push((r) => r[c] >= v); return api; }, lte(c, v) { q.f.push((r) => r[c] <= v); return api; }, lt(c, v) { q.f.push((r) => r[c] < v); return api; },
      ilike(c, v) { const n = String(v).replace(/%/g, "").toLowerCase(); q.f.push((r) => String(r[c] || "").toLowerCase().includes(n)); return api; }, or() { return api; }, neq(c, v) { q.f.push((r) => r[c] !== v); return api; }, range(a, b) { q.from = a; q.to = b; return api; }, limit(n) { q.lim = n; return api; },
      maybeSingle() { q.single = true; return api; }, single() { q.single = true; return api; },
      then(res, rej) { return Promise.resolve().then(run).then(res, rej); },
    };
    function run() {
      window.__FAKE.calls.push(q.op + ":" + t + (q.op === "select" ? ":" + (q.lim || (q.to != null ? q.to - q.from + 1 : "")) : ""));
      const T = DB[t]; if (!T) return { data: null, error: { code: "42P01", message: `relation "public.${t}" does not exist` } };
      const k = KEY[t];
      if (q.op === "select") {
        let rows = T.filter((r) => canRead(t, r)).map((r) => view(t, r)).filter((r) => q.f.every((f) => f(r)));
        q.ord.slice().reverse().forEach(([c, asc]) => rows.sort((a, b) => (a[c] < b[c] ? -1 : a[c] > b[c] ? 1 : 0) * (asc ? 1 : -1)));
        if (q.to != null) rows = rows.slice(q.from, q.to + 1); if (q.lim != null) rows = rows.slice(0, q.lim);
        rows = rows.slice(0, 1000).map((r) => pick(r, q.cols));        // Supabase "max rows"
        return q.single ? { data: rows[0] || null, error: null } : { data: rows, error: null };
      }
      if (q.op === "insert" || q.op === "upsert") {
        for (const row of q.rows) {
          if (!canWrite(t, null)) return { data: null, error: { code: "42501", message: "new row violates row-level security policy" } };
          const i = T.findIndex((r) => r[k] === row[k]);
          if (i >= 0) { if (q.op === "insert") return { data: null, error: { code: "23505", message: "duplicate key" } }; Object.assign(T[i], row, { updated_at: now() }); live(t, "UPDATE", T[i]); }
          else { T.push(Object.assign({ updated_at: now() }, row)); live(t, "INSERT", T[T.length - 1]); }
        }
        return { data: q.ret ? q.rows : null, error: null };
      }
      const hit = T.filter((r) => canRead(t, r) && canWrite(t, r)).filter((r) => q.f.every((f) => f(view(t, r))));
      if (q.op === "update") {
        hit.forEach((r) => { if (t === "docs" && r.path === "config/settings" && q.vals.doc) { const keep = r.doc.mfa; Object.assign(r, q.vals); if (keep === undefined) delete r.doc.mfa; else r.doc.mfa = keep; } else Object.assign(r, q.vals); r.updated_at = now(); live(t, "UPDATE", r);
          if (t === "leads") audit("updated", "lead", r.id, "Lead updated", { status: { new: r.doc.status } }); });
        return { data: q.ret ? hit.map((r) => pick(view(t, r), q.rcols)) : null, error: null };
      }
      if (q.op === "delete") { hit.forEach((r) => { T.splice(T.indexOf(r), 1); live(t, "DELETE", r); }); return { data: null, error: null }; }
    }
    return api;
  }
  const RPC = {
    server_now: () => now(),
    next_lead_ref: () => "LD2026-" + (2000 + DB.leads.length),
    log_event: (a) => { if (role()) audit(a.p_action, a.p_entity, a.p_entity_id, a.p_summary, a.p_details); return null; },
    has_perm: (a) => role() === "supervisor", my_role: () => role(), product_locks: () => ({}), find_accounts: () => [],
    set_my_display_name: (a) => { me().display_name = a.p_name; return a.p_name; },
    mfa_state: () => { const m = me(); if (!m) return { member: false, mode: "off", enrolled: false, aal: "aal1", need: "none" }; const mode = modeFor(m.email, m.role, settings().mfa), has = verified(m.email).length > 0, aal = session.aal || "aal1"; return { member: true, mode, enrolled: has, aal, need: aal === "aal2" ? "none" : has ? "code" : mode === "required" ? "setup" : "none" }; },
    mfa_users: () => { if (role() !== "supervisor") throw { code: "42501", message: "Not allowed" }; const o = {}; DB.members.forEach((m) => { const v = verified(m.email); if (v.length) o[m.email] = { enrolled: true, since: v[0].created_at }; }); return o; },
    set_mfa_policy: (a) => { if (role() !== "supervisor") throw { code: "42501", message: "Only a Supervisor can change two-step sign-in." }; const p = a.p || {}; const nw = { mode: ["off", "optional", "required"].includes(p.mode) ? p.mode : "off", roles: Object.assign({}, p.roles), users: Object.assign({}, p.users) };
      if (modeFor(session.email, me().role, nw) === "required" && !verified(session.email).length) throw { code: "P0001", message: "Set up two-step sign-in on your own account first (account menu, top right). Then make it required." };
      const old = settings().mfa; settings().mfa = nw; LS.set("fake.mfa", nw); audit("mfa_policy", "settings", "Two-step sign-in", "Two-step sign-in rule changed: everyone " + nw.mode, { mfa: { old, new: nw } }); return nw; },
    mfa_log: (a) => { const has = verified(session.email).length > 0; if ((a.p_action === "mfa_enabled") !== has) throw { code: "22023", message: "Nothing to record" }; DB.audit_log.push({ id: DB.audit_log.length + 1, at: now(), actor: session.email, actor_role: me().role, source: "app", action: a.p_action, entity: "user", entity_id: session.email, summary: has ? "Switched two-step sign-in on (authenticator app)" : "Switched two-step sign-in off" }); return null; },
    export_begin: (a) => { if (role() !== "supervisor") throw { code: "42501", message: "Only a Supervisor can export all Lead Desk data." }; const c = {}; ["leads", "accounts", "contracts", "members", "docs", "audit_log"].forEach((t) => (c[t] = DB[t].length)); audit("exported", "report", "Full export · " + (a.p_kind === "excel" ? "Excel workbook" : "backup file"), "Started a full data export", c); return { at: now(), by: session.email, counts: c }; },
  };
  const rpc = (name, args) => Promise.resolve().then(() => {
    window.__FAKE.calls.push("rpc:" + name);
    if (NOSQL.includes(name) || !RPC[name]) return { data: null, error: { code: "PGRST202", message: "Could not find the function public." + name + " in the schema cache" } };
    try { return { data: RPC[name](args || {}), error: null }; } catch (e) { return { data: null, error: e }; }
  });
  const QR = window.__QR || "";
  const auth = {
    getSession: async () => ({ data: { session: sess() }, error: null }),
    getUser: async () => ({ data: { user: sess() && sess().user }, error: null }),
    onAuthStateChange(cb) { listeners.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
    async signInWithPassword({ email, password }) { const m = DB.members.find((x) => x.email === email); if (!m || password !== "demo1234") return { error: { message: "Invalid login credentials" } }; session = { email, aal: "aal1", at: now() }; saveS(); emit("SIGNED_IN"); return { data: { session: sess() }, error: null }; },
    async signInWithOtp() { return { error: null }; },
    async signOut() { session = null; saveS(); emit("SIGNED_OUT"); return { error: null }; },
    async updateUser() { if (session) { session.must = false; saveS(); } return { error: null }; },
    async refreshSession() { if (session && !verified(session.email).length) { session.aal = "aal1"; saveS(); } return { data: { session: sess() }, error: null }; },
    mfa: {
      async listFactors() { const all = (session && FACTORS[session.email]) || []; return { data: { all, totp: all.filter((f) => f.status === "verified") }, error: null }; },
      async enroll({ factorType, friendlyName }) { if (LS.get("fake.mfaDisabled", false)) return { data: null, error: { message: "MFA enroll is disabled for TOTP" } }; const f = { id: "f" + Math.random().toString(36).slice(2, 10), status: "unverified", factor_type: factorType, friendly_name: friendlyName, created_at: now() }; (FACTORS[session.email] = FACTORS[session.email] || []).push(f); saveF(); return { data: { id: f.id, type: "totp", totp: { qr_code: QR, secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", uri: "otpauth://totp/Lead%20Desk" } }, error: null }; },
      async challengeAndVerify({ factorId, code }) { const f = ((session && FACTORS[session.email]) || []).find((x) => x.id === factorId); if (!f) return { data: null, error: { message: "Factor not found" } }; if (code !== "123456") return { data: null, error: { message: "Invalid TOTP code entered" } }; f.status = "verified"; saveF(); session.aal = "aal2"; saveS(); emit("MFA_CHALLENGE_VERIFIED"); return { data: {}, error: null }; },
      async unenroll({ factorId }) { const a = (session && FACTORS[session.email]) || []; const f = a.find((x) => x.id === factorId); if (f && f.status === "verified" && session.aal !== "aal2") return { error: { message: "AAL2 required to unenroll a verified factor" } }; FACTORS[session.email] = a.filter((x) => x.id !== factorId); saveF(); return { data: { id: factorId }, error: null }; },
      async getAuthenticatorAssuranceLevel() { return { data: { currentLevel: session.aal, nextLevel: verified(session.email).length ? "aal2" : "aal1" }, error: null }; },
    },
  };
  const functions = { async invoke(name, { body }) {
    window.__FAKE.calls.push("fn:" + name + ":" + body.action);
    if (role() !== "supervisor") return { data: null, error: { message: "Only a Supervisor can manage sign-ins.", context: { json: async () => ({ error: "Only a Supervisor (or a role with 'Users, roles and permissions') can manage sign-ins." }) } } };
    if (body.action === "mfa_reset") { const had = (FACTORS[body.email] || []).length; delete FACTORS[body.email]; saveF(); if (had) audit("mfa_reset", "user", body.email, `Reset two-step sign-in for ${body.email} (authenticator removed)`); return { data: { status: had ? "reset" : "none" }, error: null }; }
    return { data: { status: body.action === "create" ? "created" : "reset", password: "Temp12345" }, error: null };
  } };
  const channel = () => { const c = { on(_e, f, cb) { (CH[f.table] = CH[f.table] || []).push(cb); return c; }, subscribe(cb) { setTimeout(() => cb && cb("SUBSCRIBED"), 0); return c; } }; return c; };
  window.supabase = { createClient: () => ({ from: Q, rpc, auth, functions, channel, removeChannel() {} }) };
})();
