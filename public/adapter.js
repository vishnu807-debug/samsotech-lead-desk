/* Lead Desk · Supabase adapter
   Gives the app the same small data/user interface it uses inside Claude,
   backed by Supabase (Postgres + Auth + Realtime). Sign-in is by email link. */
(function () {
  "use strict";
  const cfg = window.LD_CONFIG || {};
  if (!cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY || /YOUR-/.test(cfg.SUPABASE_URL)) {
    document.getElementById("main").innerHTML =
      '<div class="panel empty">Lead Desk isn\'t configured yet. Put your Supabase URL and anon key in <code>config.js</code>.</div>';
    return;
  }
  window.LD_HOSTED = true;
  const sb = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "pkce" },
  });
  window.__sb = sb;
  window.__adminUser = async (action, email) => {
    const { data, error } = await sb.functions.invoke("user-admin", { body: { action, email } });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); if (j && j.error) msg = j.error; } catch (_) {}
      if (/Failed to send|not found|404/i.test(msg)) msg = "The user-admin function isn't set up yet (see README). Create the login in Supabase instead.";
      return { error: msg };
    }
    return data;
  };
  /* audit trail: events the database can't see by itself (see supabase/10_audit_trail.sql) */
  window.__audit = (action, entity, id, summary, details) =>
    sb.rpc("log_event", { p_action: action, p_entity: entity || "session", p_entity_id: id || null, p_summary: summary || null, p_details: details || null }).then(() => {}, () => {});
  window.__signOut = async () => { try { await window.__audit("signed_out", "session", ME.email, "Signed out"); } catch (e) {} try { await window.__clearCache(); } catch (e) {} await sb.auth.signOut(); location.href = location.pathname; };

  let ME = { email: "", role: null, displayName: "" };
  const NAMES = {};          // email -> display name, for the people this user can see
  let DN_COLUMN = false;     // true once supabase/14_names.sql has added members.display_name

  /* ---------- helpers ---------- */
  const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
  function merge(a, b) {               // Firestore-style update: nested objects merge, everything else replaces
    const o = Object.assign({}, a || {});
    for (const [k, v] of Object.entries(b || {})) o[k] = isObj(v) && isObj(o[k]) ? merge(o[k], v) : v;
    return o;
  }
  function dbErr(e) {
    const msg = (e && e.message) || String(e);
    const denied = (e && (e.code === "42501" || e.code === "PGRST301")) || /row-level security|permission/i.test(msg);
    return { code: denied ? "invalid_argument" : "unavailable", message: msg };
  }
  const snap = (id, doc) => ({ id, exists: !!doc, data: () => (doc ? doc : undefined), metadata: { fromCache: false, hasPendingWrites: false } });
  function route(path) {
    const seg = path.split("/");
    if (seg[0] === "leads") return { t: "leads", k: "id", id: seg[1] };
    if (seg[0] === "accounts") return { t: "accounts", k: "key", id: seg[1] };
    if (path === "config/users") return { t: "members" };
    return { t: "docs", k: "path", id: path };
  }
  async function fetchAll(table, key) {
    // Supabase returns at most "Max rows" per request (1000 by default, can be lower), whatever range is asked for,
    // so keep asking from where the last answer ended until an empty page comes back.
    const out = []; const page = 1000;
    for (let from = 0; ; ) {
      const { data, error } = await sb.from(table).select(key + ",doc").order(key).range(from, from + page - 1);
      if (error) throw dbErr(error);
      if (!data.length) break;
      out.push(...data); from += data.length;
    }
    return out;
  }
  /* ---------- low-data mode: device cache + "changed since" sync (supabase/11_low_data.sql) ---------- */
  const SYNCED = { leads: true, accounts: true };           // tables that have updated_at
  let hasStamp = null;                                       // null = unknown yet; false = SQL not run, use full loads
  async function fetchSince(table, key, since) {
    const out = []; const page = 1000;
    for (let from = 0; ; ) {
      let q = sb.from(table).select(key + ",doc,updated_at").order("updated_at").order(key).range(from, from + page - 1);
      if (since) q = q.gt("updated_at", new Date(new Date(since).getTime() - 60000).toISOString());   // 1-minute overlap for slow saves
      const { data, error } = await q;
      if (error) throw error;
      if (!data.length) break;
      out.push(...data); from += data.length;
    }
    return out;
  }
  async function fetchKeys(table, key) {
    // Fix 9 Nov 2026: this used to stop after the first 1000 keys (Supabase's row limit), so once there were more than
    // 1000 leads the newest ones were dropped from the device copy every 30 minutes.
    const out = []; const page = 1000;
    for (let from = 0; ; ) {
      const { data, error } = await sb.from(table).select(key).order(key).range(from, from + page - 1);
      if (error) throw dbErr(error);
      if (!data.length) break;
      out.push(...data.map((x) => x[key])); from += data.length;
    }
    return out;
  }
  const idb = (() => {
    let dbp = null;
    const open = () => dbp || (dbp = new Promise((res, rej) => {
      try { const r = indexedDB.open("lead-desk", 1); r.onupgradeneeded = () => r.result.createObjectStore("cache"); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); }
      catch (e) { rej(e); }
    }));
    const tx = (mode, fn) => open().then((db) => new Promise((res, rej) => { const t = db.transaction("cache", mode); const st = t.objectStore("cache"); const r = fn(st); t.oncomplete = () => res(r && r.result); t.onerror = () => rej(t.error); }));
    return {
      get: (k) => tx("readonly", (st) => st.get(k)).catch(() => null),
      set: (k, v) => tx("readwrite", (st) => st.put(v, k)).catch(() => null),
      clear: () => tx("readwrite", (st) => st.clear()).catch(() => null),
    };
  })();
  window.__clearCache = () => idb.clear();
  // display name of the signed-in user (supabase/14_names.sql)
  window.__setDisplayName = async (name) => {
    const { data, error } = await sb.rpc("set_my_display_name", { p_name: name });
    if (error) throw dbErr(error);
    ME.displayName = data || ""; if (data) NAMES[ME.email] = data; else delete NAMES[ME.email];
    return ME.displayName;
  };
  // Supervisor: move every lead of a name that isn't on the Sales engineer list to an existing engineer (supabase/15_merge.sql)
  // AMC changes (supabase/34_amc_lines_signoff_cloud.sql): project sign-off date on a won order, and the picture of a
  // contract's commercial page, kept only while the contract waits for approval. Pictures are fetched on demand.
  window.__setSignoff = async (id, date) => {
    const { error } = await sb.rpc("set_signoff", { p_id: id, p_date: date });
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    return true;
  };
  // Renaming an account: asked by a sales engineer, done by someone with account.manage. One database call each.
  window.__accountRename = {
    request: async (a) => { const { error } = await sb.rpc("account_rename_request", { p_key: a.key, p_name: a.name, p_reason: a.reason || "", p_cur: a.cur || {} }); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return true; },
    rename: async (a) => { const { error } = await sb.rpc("account_rename", { p_key: a.key, p_name: a.name, p_reason: a.reason || "", p_cur: a.cur || {} }); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return true; },
    reject: async (a) => { const { error } = await sb.rpc("account_rename_reject", { p_key: a.key }); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return true; },
  };
  window.__contractPages = {
    put: async (id, pages) => {
      const rows = (pages || []).slice(0, 3).map((p) => ({ contract_id: id, n: p.n, img: p.img }));
      if (!rows.length) return true;
      const { error } = await sb.from("contract_pages").upsert(rows, { onConflict: "contract_id,n" });
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      return true;
    },
    list: async (id) => {
      const { data, error } = await sb.from("contract_pages").select("n,img").eq("contract_id", id).order("n");
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      return data || [];
    },
  };
  // Joint work and events (supabase/33_joint_events.sql)
  window.__shareDecide = async (id, ok) => {
    const { error } = await sb.rpc("lead_share_decide", { p_id: id, p_ok: !!ok });
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    return true;
  };
  window.__saveEvents = async (list) => {
    const { error } = await sb.rpc("save_events", { p_events: list });
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    return true;
  };
  window.__setRenewal = async (id, key, val) => {
    const { error } = await sb.rpc("set_renewal", { p_id: id, p_key: key, p_val: val });
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    return true;
  };
  // AMC contracts of existing clients (supabase/28_contracts.sql). A small table read in full; the PDFs are never uploaded.
  window.__contracts = {
    async list() {
      const out = [];
      for (let from = 0; ; ) {
        const { data, error } = await sb.from("contracts").select("id,doc").order("id").range(from, from + 999);
        if (error) throw Object.assign(new Error(error.message), { code: error.code });
        if (!data.length) break;
        data.forEach((r) => out.push(Object.assign({}, r.doc, { id: r.id })));
        from += data.length;
      }
      return out;
    },
    async insert(rows) {
      const { error } = await sb.from("contracts").insert(rows.map((d) => ({ id: d.id, doc: d })));
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      return true;
    },
    async update(id, doc) {
      const { data, error } = await sb.from("contracts").update({ doc }).eq("id", id).select("id");
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      if (!data || !data.length) throw Object.assign(new Error("You are not allowed to change this contract."), { code: "42501" });
      return true;
    },
    async setRenewal(id, key, val) {
      const { error } = await sb.rpc("set_contract_renewal", { p_id: id, p_key: key, p_val: val });
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      return true;
    },
  };
  window.__approveQuoteLines = async (id, lines) => {
    const { error } = await sb.rpc("approve_quote_lines", { p_id: id, p_lines: lines });
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    return true;
  };
  window.__mergeProduct = async (from, to) => {
    const { data, error } = await sb.rpc("merge_product", { p_old: from, p_new: to });
    if (error) throw dbErr(error);
    return data;
  };
  window.__mergeEngineer = async (from, to) => {
    const { data, error } = await sb.rpc("merge_engineer", { p_old: from, p_new: to });
    if (error) throw dbErr(error);
    return data;
  };
  // Supervisor: rename a product or a sales engineer everywhere it is used, in one database transaction
  window.__renameEverywhere = async (kind, from, to) => {
    const { data, error } = await sb.rpc("rename_everywhere", { p_kind: kind, p_old: from, p_new: to });
    if (error) throw dbErr(error);
    return data;
  };

  async function readMembers() {
    const { data, error } = await sb.from("members").select("*").eq("active", true);
    if (error) throw dbErr(error);
    DN_COLUMN = !data.length || "display_name" in data[0];
    const members = {};
    data.forEach((m) => { members[m.email] = { role: m.role, engineer: m.engineer || "", addedAt: m.added_at, displayName: m.display_name || "" }; if (m.display_name) NAMES[m.email] = m.display_name; else delete NAMES[m.email]; });
    return { members };
  }
  async function writeMembers(doc) {
    const want = doc.members || {};
    const cur = (await readMembers()).members;
    const hasDN = Object.values(cur).some((m) => "displayName" in m) && DN_COLUMN;
    const rows = Object.entries(want).map(([email, m]) => Object.assign({ email: email.toLowerCase(), role: m.role, engineer: m.role === "sales" ? (m.engineer || null) : null, active: true, added_by: ME.email },
      hasDN ? { display_name: (m.displayName !== undefined ? String(m.displayName || "").trim().replace(/\s+/g, " ") : ((cur[email] || {}).displayName || "")) || null } : {}));
    // clear engineer links first so moving a name between people doesn't trip the uniqueness rule
    const removed = Object.keys(cur).filter((e) => !want[e]);
    if (removed.length) { const { error } = await sb.from("members").delete().in("email", removed); if (error) throw dbErr(error); }
    if (rows.length) { const { error } = await sb.from("members").upsert(rows, { onConflict: "email" }); if (error) throw dbErr(error); }
  }
  const caches = {};   // table -> Map(id -> doc) for merge-on-update

  /* ---------- realtime fan-out ---------- */
  const listeners = {};  // table -> Set(fn)
  const resync = {};     // table -> Set(fn) called when the live connection comes back after a drop
  // The screen must not depend on Supabase's live updates to show the user's OWN change: if that message is late or
  // lost, a form would stay on "Saving…" although the save went through. So after a successful write the change is
  // handed to the same listeners straight away (an update or delete), or the list is re-read through the normal
  // access rules (a new row, which the person may not be allowed to see).
  function localEcho(table, key, id, doc, type) {
    (listeners[table] || []).forEach((f) => { try { f({ eventType: type, new: type === "DELETE" ? {} : { [key]: id, doc }, old: { [key]: id }, local: true }); } catch (e) { console.error(e); } });
  }
  const localReload = (table) => (resync[table] || []).forEach((f) => { try { f(); } catch (e) { console.error(e); } });
  // changes made through database functions (sign-off, agreed share, renewal progress) are re-read the same way
  ["__setSignoff", "__shareDecide", "__setRenewal"].forEach((n) => { const f = window[n]; if (typeof f === "function") window[n] = async (...a) => { const r = await f(...a); localReload("leads"); return r; }; });
  function onTable(table, fn) {
    if (!listeners[table]) {
      listeners[table] = new Set(); resync[table] = resync[table] || new Set();
      let dropped = false;
      sb.channel("ld-" + table)
        .on("postgres_changes", { event: "*", schema: "public", table }, (p) => listeners[table].forEach((f) => f(p)))
        .subscribe((status) => {
          if (status === "SUBSCRIBED") { if (dropped) { dropped = false; resync[table].forEach((f) => f()); } }
          else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") dropped = true;
        });
    }
    listeners[table].add(fn);
    return () => listeners[table].delete(fn);
  }

  /* ---------- db namespace ---------- */
  function doc(path) {
    const r = route(path);
    const ref = {
      id: path.split("/").pop(), path,
      async get() {
        if (r.t === "members") return snap("users", await readMembers());
        const { data, error } = await sb.from(r.t).select("doc").eq(r.k, r.id).maybeSingle();
        if (error) throw dbErr(error);
        if (data) (caches[r.t] = caches[r.t] || new Map()).set(r.id, data.doc);
        return snap(r.id, data && data.doc);
      },
      async set(d) {
        if (r.t === "members") return writeMembers(d);
        // leads and accounts: plain insert, because a sales engineer may create a row they can't read back
        // (an upsert would also need read access to the row)
        const plain = r.t === "leads" || r.t === "accounts";
        let { error } = plain
          ? await sb.from(r.t).insert({ [r.k]: r.id, doc: d })
          : await sb.from(r.t).upsert({ [r.k]: r.id, doc: d }, { onConflict: r.k });
        if (error && plain && error.code === "23505") {
          const up = await sb.from(r.t).update({ doc: d }).eq(r.k, r.id).select(r.k);
          // an account that already exists but isn't visible to this user is fine: the lead links to it by key
          error = r.t === "accounts" && (up.error || !(up.data || []).length) ? null : up.error;
        }
        if (error) throw dbErr(error);
        (caches[r.t] = caches[r.t] || new Map()).set(r.id, d);
        localReload(r.t); if (r.t === "docs") localEcho(r.t, r.k, r.id, d, "UPDATE");
      },
      async update(d) {
        if (r.t === "members") return writeMembers(merge(await readMembers(), d));
        // always start from the latest saved copy (one small read), so a change made by someone else
        // a moment ago, or a device copy that is a little behind, is never overwritten
        const s = await ref.get(); if (!s.exists) throw { code: "invalid_argument", message: "Document does not exist" };
        const base = s.data();
        const next = merge(base, d);
        const { data, error } = await sb.from(r.t).update({ doc: next }).eq(r.k, r.id).select(r.k);
        if (error) throw dbErr(error);
        if (!data || !data.length) throw { code: "invalid_argument", message: "You don't have permission to change this record." };
        caches[r.t].set(r.id, next);
        localEcho(r.t, r.k, r.id, next, "UPDATE");
      },
      async delete() {
        if (r.t === "members") return;
        const { error } = await sb.from(r.t).delete().eq(r.k, r.id);
        if (error) throw dbErr(error);
        localEcho(r.t, r.k, r.id, null, "DELETE");
      },
      async acquire() { return { acquired: true }; },   // reference numbers come from next_lead_ref() instead
      onSnapshot(next, onErr) {
        let alive = true;
        const load = () => ref.get().then((s) => alive && next(s)).catch((e) => alive && onErr && onErr(e));
        load();
        const off = onTable(r.t, (p) => {
          const row = p.new && Object.keys(p.new).length ? p.new : p.old;
          if (r.t === "members" || (row && row[r.k] === r.id)) load();
        });
        return () => { alive = false; off(); };
      },
      collection() { throw new Error("Sub-collections are not used by Lead Desk"); },
    };
    return ref;
  }
  function collection(name) {
    const r = route(name + "/x"); const table = r.t, key = r.k;
    return {
      path: name,
      doc: (id) => doc(name + "/" + id),
      onSnapshot(next, onErr) {
        let alive = true, timer = null;
        const map = (caches[table] = caches[table] || new Map());
        const emit = () => {
          if (!alive) return;
          const docs = [...map.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([id, d]) => snap(id, d));
          next({ docs, size: docs.length, empty: !docs.length, metadata: { fromCache: false, hasPendingWrites: false }, docChanges: () => [] });
        };
        // Data use matters (free plan: 5 GB a month). Live changes arrive one row at a time. For leads and
        // accounts each device keeps a copy and only asks for rows changed since its last sync, plus the
        // list of row keys (to drop rows that were deleted or are no longer visible to this user).
        const ck = "v4:" + table + ":" + ME.email + ":" + (ME.role || "");   // v3: fresh full copy on every device (v2: rows lost to the old 1000-key limit; v3: sales can now read leads they generated)
        let sync = null, lastFull = 0, lastKeys = 0, inflight = null, saveT = null, last = 0;
        const save = () => { clearTimeout(saveT); saveT = setTimeout(() => idb.set(ck, { sync, lastFull, rows: [...map.entries()] }), 1500); };
        const serverNow = async () => { const { data, error } = await sb.rpc("server_now"); if (error || !data) throw Object.assign(new Error("no server_now"), { code: "42703" }); return data; };
        const full = async () => {
          if (SYNCED[table] && hasStamp !== false) {
            try { const t0 = await serverNow(); const rows = await fetchSince(table, key, null); hasStamp = true; map.clear(); rows.forEach((x) => map.set(x[key], x.doc)); sync = t0; lastFull = lastKeys = Date.now(); emit(); save(); return; }
            catch (e) { hasStamp = false; console.warn("Lead Desk: low-data mode unavailable, using full loads", e); }   // e.g. 11_low_data.sql not run yet
          }
          const rows = await fetchAll(table, key); map.clear(); rows.forEach((x) => map.set(x[key], x.doc)); lastFull = Date.now(); emit();
        };
        const delta = async () => {
          const t0 = await serverNow(); const rows = await fetchSince(table, key, sync);
          rows.forEach((x) => map.set(x[key], x.doc)); sync = t0;
          if (Date.now() - lastKeys > 30 * 60000) {           // prune rows deleted or reassigned away, every 30 min
            const keep = new Set(await fetchKeys(table, key)); [...map.keys()].forEach((k) => { if (!keep.has(k)) map.delete(k); }); lastKeys = Date.now();
            // rows this user may now read but this device never received (e.g. a permission was switched on): take a fresh full copy
            for (const k of keep) if (!map.has(k)) { await full(); return; }
          }
          emit(); save();
        };
        const reload = (force) => { if (inflight) return inflight; last = Date.now();
          const useDelta = !force && SYNCED[table] && hasStamp === true && sync && Date.now() - lastFull < 24 * 3600000;
          inflight = (useDelta ? delta().catch(() => full()) : full()).catch((e) => alive && onErr && onErr(e)).finally(() => { inflight = null; });
          return inflight; };
        (async () => {
          if (SYNCED[table]) {
            const c = await idb.get(ck);
            if (c && c.rows && c.sync && alive) { c.rows.forEach(([k, d]) => map.set(k, d)); sync = c.sync; lastFull = c.lastFull || 0; hasStamp = true; emit(); lastKeys = 0; }
          }
          reload();
        })();
        resync[table] = resync[table] || new Set(); const rs = () => alive && reload(); resync[table].add(rs);
        const off = onTable(table, (p) => {
          if (p.eventType === "DELETE") { if (p.old && p.old[key]) map.delete(p.old[key]); }
          else if (p.new && p.new[key]) map.set(p.new[key], p.new.doc);
          clearTimeout(timer); timer = setTimeout(() => { emit(); save(); }, 120);
        });
        // safety net, cheap in low-data mode (only changed rows come back)
        const every = ME.role === "sales" ? 5 * 60000 : 10 * 60000;
        const iv = setInterval(() => { if (document.visibilityState === "visible") reload(); }, every);
        const vis = () => { if (document.visibilityState === "visible" && Date.now() - last > 2 * 60000) reload(); };
        document.addEventListener("visibilitychange", vis);
        return () => { alive = false; off(); resync[table].delete(rs); clearInterval(iv); document.removeEventListener("visibilitychange", vis); };
      },
      async get() { const rows = await fetchAll(table, key); const docs = rows.map((x) => snap(x[key], x.doc)); return { docs, size: docs.length, empty: !docs.length, metadata: { fromCache: false }, docChanges: () => [] }; },
    };
  }

  /* ---------- user namespace ---------- */
  const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
  const prof = (id) => ({ id, name: NAMES[id] || (id && id.includes("@") ? id : ""), email: id && id.includes("@") ? id : null, avatarUrl: "", color: "#6b7a8f", isMe: id === ME.email, guest: false });
  const userNs = {
    me: async () => ({ id: ME.email, name: ME.displayName || ME.email, email: ME.email, isOwner: false, canEdit: (ME.role === "supervisor" || ME.role === "backoffice"), avatarUrl: "", color: "#6b7a8f" }),
    id: async () => ME.email,
    isOwner: async () => false,
    canEdit: async () => (ME.role === "supervisor" || ME.role === "backoffice"),
    can: async () => true,
    name: async () => ME.displayName || ME.email,
    email: async () => ME.email,
    profiles: async (ids) => Object.fromEntries([].concat(ids).map((i) => [i, prof(i)])),
    search: async (q) => { q = String(q || "").trim().toLowerCase(); return EMAIL_RE.test(q) ? [prof(q)] : []; },
  };

  /* ---------- downloads ---------- */
  const downloads = {
    async save({ filename, data }) {
      const blob = data instanceof Blob ? data : new Blob([data]);
      const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = filename;
      document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
    },
  };

  window.claude = { use: async (n) => (n === "db" ? { doc, collection } : n === "user" ? userNs : n === "downloads" ? downloads : null) };

  /* ---------- sign-in screen ---------- */
  const clean = (t) => String(t || "").replace(/[<>&]/g, "");
  function showSignIn(note) {
    document.getElementById("tabs").hidden = true;
    document.getElementById("main").innerHTML = `
      <section class="view" style="max-width:440px;margin:48px auto">
        <form class="panel" id="signin" style="padding:28px;display:grid;gap:14px" novalidate>
          <div><h2>Sign in to Lead Desk</h2><p class="muted" style="margin:6px 0 0">Use the work email and password your Supervisor gave you.</p></div>
          <label class="f">Work email<input id="si-email" type="email" autocomplete="username" required placeholder="${clean((window.LD_CONFIG || {}).EMAIL_HINT || "name@company.com")}"></label>
          <label class="f">Password<input id="si-pass" type="password" autocomplete="current-password"></label>
          <button class="btn pri" id="si-btn" type="submit">Sign in</button>
          <button class="btn" id="si-link" type="button">Email me a sign-in link instead</button>
          <div id="si-msg" class="small">${note || ""}</div>
        </form>
      </section>`;
    const $e = () => document.getElementById("si-email").value.trim().toLowerCase();
    const msg = (h) => (document.getElementById("si-msg").innerHTML = h);
    const bad = (t) => msg(`<span style="color:var(--bad)">${clean(t)}</span>`);
    document.getElementById("signin").onsubmit = async (e) => {
      e.preventDefault();
      const email = $e(), password = document.getElementById("si-pass").value;
      if (!EMAIL_RE.test(email)) return bad("Enter a valid email address.");
      if (!password) return bad("Enter your password, or use the email link button.");
      const btn = document.getElementById("si-btn"); btn.disabled = true; btn.textContent = "Signing in…";
      signedInWith = password;
      const { error } = await sb.auth.signInWithPassword({ email, password });
      btn.disabled = false; btn.textContent = "Sign in";
      if (error) bad(/invalid login/i.test(error.message) ? "Email or password is wrong. Ask a Supervisor to reset your password if you've forgotten it." : error.message);
    };
    document.getElementById("si-link").onclick = async () => {
      const email = $e();
      if (!EMAIL_RE.test(email)) return bad("Enter a valid email address first.");
      const btn = document.getElementById("si-link"); btn.disabled = true; btn.textContent = "Sending…";
      const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname } });
      btn.disabled = false; btn.textContent = "Email me a sign-in link instead";
      if (error) bad(/not on the Lead Desk user list|signups not allowed|403/i.test(error.message) ? "This email isn't on the Lead Desk user list. Ask a Supervisor to add you." : "Couldn't send the link: " + error.message);
      else msg(`<span style="color:var(--ok)">Check your inbox for an email from Lead Desk and open the link on this device.</span>`);
    };
  }

  /* ---------- change password ---------- */
  window.__changePassword = function (forced) {
    const host = document.createElement("div");
    host.className = "scrim"; host.style.alignItems = "center"; host.style.justifyContent = "center";
    host.innerHTML = `<form class="panel" style="width:min(400px,calc(100% - 32px));display:grid;gap:12px;padding:22px" novalidate>
        <h3>${forced ? "Choose your own password" : "Change password"}</h3>
        ${forced ? '<p class="small muted" style="margin:0">You signed in with the temporary password your Supervisor gave you. Choose a password only you know before you continue.</p>' : ""}
        <label class="f">New password<input id="cp1" type="password" autocomplete="new-password" minlength="8"></label>
        <label class="f">Repeat new password<input id="cp2" type="password" autocomplete="new-password"></label>
        <div id="cpm" class="small"></div>
        <div class="row"><button class="btn pri" type="submit">Save password</button>${forced ? '<button class="btn" type="button" id="cpx">Sign out</button>' : '<button class="btn" type="button" id="cpx">Cancel</button>'}</div>
      </form>`;
    document.body.appendChild(host);
    const close = () => host.remove();
    host.querySelector("#cpx").onclick = forced ? () => window.__signOut() : close;
    if (!forced) host.onclick = (e) => { if (e.target === host) close(); };
    host.querySelector("form").onsubmit = async (e) => {
      e.preventDefault();
      const a = host.querySelector("#cp1").value, b = host.querySelector("#cp2").value, m = host.querySelector("#cpm");
      if (a.length < 8) { m.innerHTML = '<span style="color:var(--bad)">Use at least 8 characters.</span>'; return; }
      if (a !== b) { m.innerHTML = '<span style="color:var(--bad)">The two passwords don\'t match.</span>'; return; }
      if (forced && signedInWith && a === signedInWith) { m.innerHTML = '<span style="color:var(--bad)">Choose a password different from the temporary one.</span>'; return; }
      const { error } = await sb.auth.updateUser({ password: a, data: { must_change_password: false } });
      if (error) m.innerHTML = `<span style="color:var(--bad)">${clean(error.message)}</span>`;
      else { window.__audit("password_changed", "session", ME.email, forced ? "Changed the temporary password" : "Changed password"); m.innerHTML = '<span style="color:var(--ok)">Password changed.</span>'; setTimeout(() => { close(); if (forced && window.__afterPassword) window.__afterPassword(); }, 900); }
    };
    host.querySelector("#cp1").focus();
  };


  /* ---------- two-step sign-in with an authenticator app (supabase/36_mfa.sql) ----------
     Uses Supabase's built-in MFA. The database gives no data to a person who must use two-step sign-in
     until the code has been entered in this session, so this screen comes before anything is loaded. */
  const mfaState = async () => { try { const { data, error } = await sb.rpc("mfa_state"); return error ? null : data; } catch (e) { return null; } };   // null: 36_mfa.sql not run yet
  async function mfaFactors() {
    const { data, error } = await sb.auth.mfa.listFactors();
    if (error) throw error;
    const all = (data && data.all) || [];
    return { ok: all.filter((f) => f.status === "verified" && f.factor_type === "totp"), open: all.filter((f) => f.status !== "verified") };
  }
  const mfaLog = (a) => sb.rpc("mfa_log", { p_action: a }).then(() => {}, () => {});
  // One small dialog for: entering the code, first set-up, and switching it on or off from the account menu.
  function mfaDialog(o) {
    return new Promise((done) => {
      const host = document.createElement("div");
      host.className = "scrim mfas"; host.style.alignItems = "center"; host.style.justifyContent = "center"; host.style.overflow = "auto";
      document.body.appendChild(host);
      const close = (v) => { host.remove(); done(v); };
      const err = (t) => { const m = host.querySelector("#mfm"); if (m) m.innerHTML = t ? `<span style="color:var(--bad)">${clean(t)}</span>` : ""; };
      const shell = (title, body, okLabel) => {
        host.innerHTML = `<form class="panel" role="dialog" aria-modal="true" aria-label="${title}" style="width:min(420px,calc(100% - 24px));display:grid;gap:12px;padding:20px;margin:12px auto" novalidate>
          <h3 style="margin:0">${title}</h3>${body}<div id="mfm" class="small" role="alert"></div>
          <div class="row">${okLabel ? `<button class="btn pri" type="submit" id="mfok">${okLabel}</button>` : ""}<button class="btn" type="button" id="mfx">${o.forced ? "Sign out" : "Close"}</button></div></form>`;
        host.querySelector("#mfx").onclick = o.forced ? () => window.__signOut() : () => close(false);
      };
      const codeBox = `<label class="f">6-digit code<input id="mfc" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]*" maxlength="6" placeholder="000000" style="font:600 22px var(--f-mono,monospace);letter-spacing:.3em;text-align:center;height:48px"></label>`;
      const readCode = () => { const c = (host.querySelector("#mfc").value || "").replace(/\D/g, ""); if (c.length !== 6) { err("Enter the 6 digits shown in your authenticator app."); return null; } return c; };
      const busy = (on, label) => { const b = host.querySelector("#mfok"); if (b) { b.disabled = on; b.textContent = label; } };
      const askCode = async () => {
        let f; try { f = (await mfaFactors()).ok[0]; } catch (e) { f = null; }
        shell("Two-step sign-in", `<p class="small muted" style="margin:0">Open your authenticator app and enter the code shown for Lead Desk.</p>${codeBox}
          <p class="small muted" style="margin:0">Lost or changed your phone? Ask a Supervisor to reset your two-step sign-in.</p>`, "Verify");
        host.querySelector("form").onsubmit = async (e) => {
          e.preventDefault(); const code = readCode(); if (!code) return;
          if (!f) return err("No authenticator is registered for this account. Ask a Supervisor to reset your two-step sign-in.");
          busy(true, "Checking…");
          const { error } = await sb.auth.mfa.challengeAndVerify({ factorId: f.id, code });
          busy(false, "Verify");
          if (error) { err(/invalid|expired/i.test(error.message) ? "That code is not right or has expired. Wait for the next code and try again." : error.message); host.querySelector("#mfc").select(); return; }
          close(true);
        };
        host.querySelector("#mfc").focus();
      };
      const setUp = async () => {
        shell("Set up two-step sign-in", `<p class="small muted" style="margin:0">Preparing…</p>`, "");
        let en;
        try {
          const fs = await mfaFactors();
          for (const f of fs.open) await sb.auth.mfa.unenroll({ factorId: f.id });             // an earlier set-up that was never finished
          const r = await sb.auth.mfa.enroll({ factorType: "totp", friendlyName: "Lead Desk " + new Date().toISOString().slice(0, 16) });
          if (r.error) throw r.error; en = r.data;
        } catch (e) {
          shell("Set up two-step sign-in", `<p class="small" style="margin:0;color:var(--bad)">${clean(/not enabled|disabled/i.test(e.message || "") ? "Two-step sign-in is not switched on in Supabase yet (Authentication → Sign In / Providers → Multi-Factor → TOTP)." : (e.message || "Could not start the set-up."))}</p>`, "");
          return;
        }
        shell("Set up two-step sign-in", `${o.forced ? `<p class="small" style="margin:0"><b>Your Supervisor requires two-step sign-in.</b> It takes about a minute and you only do it once.</p>` : ""}
          <ol class="small" style="margin:0;padding-left:18px;display:grid;gap:8px">
            <li>Install an authenticator app on your phone, for example Microsoft Authenticator or Google Authenticator.</li>
            <li>In the app choose “Add account” and scan this picture:<div style="margin:8px 0;display:grid;justify-items:center"><img alt="QR code for your authenticator app" id="mfqr" width="176" height="176" style="background:#fff;padding:8px;border-radius:8px;border:1px solid var(--line);max-width:100%;height:auto"></div>
              <details><summary>Can't scan? Type this key instead</summary><div class="mono" style="word-break:break-all;user-select:all;padding:8px;margin-top:6px;background:var(--sunk);border-radius:6px" id="mfkey"></div></details></li>
            <li>Enter the 6-digit code the app now shows.</li></ol>${codeBox}`, "Switch on");
        // Supabase returns the picture as an SVG data address that contains quotes, so it is set here, not inside the HTML text
        const qr = String(en.totp.qr_code || ""); host.querySelector("#mfqr").src = /^data:image\/svg\+xml;utf-?8,/i.test(qr) ? "data:image/svg+xml;charset=utf-8," + encodeURIComponent(qr.replace(/^data:image\/svg\+xml;utf-?8,/i, "")) : qr;
        host.querySelector("#mfkey").textContent = en.totp.secret || "";
        host.querySelector("form").onsubmit = async (e) => {
          e.preventDefault(); const code = readCode(); if (!code) return;
          busy(true, "Checking…");
          const { error } = await sb.auth.mfa.challengeAndVerify({ factorId: en.id, code });
          busy(false, "Switch on");
          if (error) { err(/invalid|expired/i.test(error.message) ? "That code is not right or has expired. Wait for the next code and try again." : error.message); host.querySelector("#mfc").select(); return; }
          await mfaLog("mfa_enabled");
          close(true);
        };
        host.querySelector("#mfc").focus();
      };
      const manage = async () => {
        shell("Two-step sign-in", `<p class="small muted" style="margin:0">Checking…</p>`, "");
        const st = await mfaState(); let fs = { ok: [] }; try { fs = await mfaFactors(); } catch (e) {}
        if (!st) { shell("Two-step sign-in", `<p class="small muted" style="margin:0">Two-step sign-in is not available yet. A Supervisor needs to run <span class="mono">supabase/36_mfa.sql</span> first.</p>`, ""); return; }
        const on = fs.ok.length > 0;
        const rule = st.mode === "required" ? "Your Supervisor requires it for your account." : st.mode === "optional" ? "It is optional for your account." : "Your Supervisor has not switched it on for your account.";
        if (on) {
          shell("Two-step sign-in", `<p style="margin:0"><span class="chip ok">On</span> You enter a code from your authenticator app each time you sign in.</p><p class="small muted" style="margin:0">${rule}${st.mode === "required" ? " Only a Supervisor can reset it." : ""}</p>`, st.mode === "required" ? "" : "Switch off");
          const fm = host.querySelector("form");
          fm.onsubmit = async (e) => {
            e.preventDefault(); const b = host.querySelector("#mfok");
            if (b.dataset.armed !== "1") { b.dataset.armed = "1"; b.textContent = "Confirm: switch off"; return; }
            busy(true, "Switching off…");
            for (const f of fs.ok) { const { error } = await sb.auth.mfa.unenroll({ factorId: f.id }); if (error) { busy(false, "Switch off"); return err(error.message); } }
            await mfaLog("mfa_disabled"); try { await sb.auth.refreshSession(); } catch (e2) {}
            close(true);
          };
        } else if (st.mode === "off") {
          shell("Two-step sign-in", `<p style="margin:0"><span class="chip">Off</span> ${rule}</p>`, "");
        } else {
          shell("Two-step sign-in", `<p style="margin:0"><span class="chip">Off</span> Add a second step to your sign-in: a 6-digit code from an authenticator app on your phone.</p><p class="small muted" style="margin:0">${rule}</p>`, "Set up now");
          host.querySelector("form").onsubmit = (e) => { e.preventDefault(); setUp(); };
        }
      };
      (o.view === "code" ? askCode : o.view === "setup" ? setUp : manage)();
    });
  }
  // Before any data is read: ask for the code, or take the person through set-up when it is required.
  async function mfaGate() {
    const st = await mfaState();
    if (!st || !st.member || st.need === "none") return;
    document.getElementById("tabs").hidden = true;
    document.getElementById("main").innerHTML = '<div class="panel empty">Two-step sign-in: enter your code to continue.</div>';
    await mfaDialog({ view: st.need === "code" ? "code" : "setup", forced: true });
  }
  window.__mfa = {
    state: mfaState,
    manage: () => mfaDialog({ view: "manage" }),
    setup: () => mfaDialog({ view: "setup" }),                          // Supervisor setting up their own before making it required
    users: async () => { const { data, error } = await sb.rpc("mfa_users"); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return data || {}; },
    setPolicy: async (p) => { const { data, error } = await sb.rpc("set_mfa_policy", { p }); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return data; },
    reset: (email) => window.__adminUser("mfa_reset", email),
  };

  /* ---------- email settings (supabase/38_email_settings.sql) ----------
     The service key is write-only: set_mail_key() stores it where no role can read it, and nothing here can fetch it back. */
  const rpcOr = async (name, args) => { const { data, error } = await sb.rpc(name, args); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return data; };
  window.__mail = {
    save: (p) => rpcOr("set_mail_settings", { p }),
    setKey: (k) => rpcOr("set_mail_key", { p_key: k }),
    log: async (n) => { const { data, error } = await sb.from("mail_log").select("id,at,kind,to_addr,subject,ok,error,provider").order("id", { ascending: false }).limit(n || 50); if (error) throw Object.assign(new Error(error.message), { code: error.code }); return data || []; },
    test: async (to) => {
      const { data, error } = await sb.functions.invoke("lead-mailer", { body: { type: "test", to } });
      if (error) { let msg = error.message; try { const j = await error.context.json(); if (j && j.error) msg = j.error; } catch (e) {} return { error: /not found|404|Failed to send/i.test(msg) ? "The lead-mailer function is not deployed yet (or is an older version)." : msg }; }
      return data || { error: "No answer from the mail function." };
    },
  };

  let signedInWith = "";   // the password typed at this sign-in (memory only), so the temporary one cannot be kept
  let started = false;
  async function start(session) {
    if (started || !session) return;
    started = true;
    ME.email = (session.user.email || "").toLowerCase();
    await mfaGate();                                                    // two-step sign-in comes before any data
    // "*" so this keeps working before supabase/14_names.sql adds the display_name column
    const { data } = await sb.from("members").select("*").eq("email", ME.email).eq("active", true).maybeSingle();
    ME.role = data ? data.role : null;
    ME.displayName = (data && data.display_name) || ""; if (ME.displayName) NAMES[ME.email] = ME.displayName;
    // log each new sign-in once (Supabase sets last_sign_in_at on every real sign-in)
    try {
      const k = "ld.signin." + ME.email, at = session.user.last_sign_in_at || "";
      if (ME.role && at && localStorage.getItem(k) !== at) { localStorage.setItem(k, at); window.__audit("signed_in", "session", ME.email, "Signed in"); }
    } catch (e) {}
    const go = () => { window.__ldReady = true; window.__startApp && window.__startApp(); };
    if (session.user.user_metadata && session.user.user_metadata.must_change_password) {
      document.getElementById("main").innerHTML = '<div class="panel empty">Choose your own password to continue.</div>';
      window.__afterPassword = go; window.__changePassword(true); return;
    }
    go();
  }
  sb.auth.onAuthStateChange((evt, session) => {
    if (evt === "SIGNED_OUT") { location.href = location.pathname; return; }
    if (session) start(session);
  });
  sb.auth.getSession().then(({ data, error }) => {
    if (data && data.session) start(data.session);
    else {
      const p = new URLSearchParams(location.search + "&" + location.hash.slice(1));
      showSignIn(error || p.get("error_description") ? `<span style="color:var(--bad)">${(p.get("error_description") || error.message || "").replace(/[<>&]/g, "")}</span>` : "");
    }
  });
})();
