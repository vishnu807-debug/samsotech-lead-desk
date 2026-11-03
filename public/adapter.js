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
  window.__signOut = async () => { await sb.auth.signOut(); location.href = location.pathname; };

  let ME = { email: "", role: null };

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
    const out = []; const page = 1000;
    for (let from = 0; ; from += page) {
      const { data, error } = await sb.from(table).select(key + ",doc").order(key).range(from, from + page - 1);
      if (error) throw dbErr(error);
      out.push(...data);
      if (data.length < page) break;
    }
    return out;
  }
  async function readMembers() {
    const { data, error } = await sb.from("members").select("*").eq("active", true);
    if (error) throw dbErr(error);
    const members = {};
    data.forEach((m) => (members[m.email] = { role: m.role, engineer: m.engineer || "", addedAt: m.added_at }));
    return { members };
  }
  async function writeMembers(doc) {
    const want = doc.members || {};
    const cur = (await readMembers()).members;
    const rows = Object.entries(want).map(([email, m]) => ({ email: email.toLowerCase(), role: m.role, engineer: m.role === "sales" ? (m.engineer || null) : null, active: true, added_by: ME.email }));
    // clear engineer links first so moving a name between people doesn't trip the uniqueness rule
    const removed = Object.keys(cur).filter((e) => !want[e]);
    if (removed.length) { const { error } = await sb.from("members").delete().in("email", removed); if (error) throw dbErr(error); }
    if (rows.length) { const { error } = await sb.from("members").upsert(rows, { onConflict: "email" }); if (error) throw dbErr(error); }
  }
  const caches = {};   // table -> Map(id -> doc) for merge-on-update

  /* ---------- realtime fan-out ---------- */
  const listeners = {};  // table -> Set(fn)
  function onTable(table, fn) {
    if (!listeners[table]) {
      listeners[table] = new Set();
      sb.channel("ld-" + table)
        .on("postgres_changes", { event: "*", schema: "public", table }, (p) => listeners[table].forEach((f) => f(p)))
        .subscribe();
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
        const { error } = await sb.from(r.t).upsert({ [r.k]: r.id, doc: d }, { onConflict: r.k });
        if (error) throw dbErr(error);
        (caches[r.t] = caches[r.t] || new Map()).set(r.id, d);
      },
      async update(d) {
        if (r.t === "members") return writeMembers(merge(await readMembers(), d));
        let base = caches[r.t] && caches[r.t].get(r.id);
        if (!base) { const s = await ref.get(); if (!s.exists) throw { code: "invalid_argument", message: "Document does not exist" }; base = s.data(); }
        const next = merge(base, d);
        const { data, error } = await sb.from(r.t).update({ doc: next }).eq(r.k, r.id).select(r.k);
        if (error) throw dbErr(error);
        if (!data || !data.length) throw { code: "invalid_argument", message: "You don't have permission to change this record." };
        caches[r.t].set(r.id, next);
      },
      async delete() {
        if (r.t === "members") return;
        const { error } = await sb.from(r.t).delete().eq(r.k, r.id);
        if (error) throw dbErr(error);
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
        const reload = () => fetchAll(table, key).then((rows) => { map.clear(); rows.forEach((x) => map.set(x[key], x.doc)); emit(); })
          .catch((e) => alive && onErr && onErr(e));
        reload();
        const off = onTable(table, (p) => {
          if (p.eventType === "DELETE") { if (p.old && p.old[key]) map.delete(p.old[key]); }
          else if (p.new && p.new[key]) map.set(p.new[key], p.new.doc);
          clearTimeout(timer); timer = setTimeout(emit, 120);
        });
        // a lead reassigned away from a sales engineer stops sending them events, so refresh now and then
        const iv = setInterval(reload, 120000);
        const vis = () => { if (document.visibilityState === "visible") reload(); };
        document.addEventListener("visibilitychange", vis);
        return () => { alive = false; off(); clearInterval(iv); document.removeEventListener("visibilitychange", vis); };
      },
      async get() { const rows = await fetchAll(table, key); const docs = rows.map((x) => snap(x[key], x.doc)); return { docs, size: docs.length, empty: !docs.length, metadata: { fromCache: false }, docChanges: () => [] }; },
    };
  }

  /* ---------- user namespace ---------- */
  const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
  const prof = (id) => ({ id, name: id && id.includes("@") ? id : "", email: id && id.includes("@") ? id : null, avatarUrl: "", color: "#6b7a8f", isMe: id === ME.email, guest: false });
  const userNs = {
    me: async () => ({ id: ME.email, name: ME.email, email: ME.email, isOwner: false, canEdit: ME.role === "backoffice", avatarUrl: "", color: "#6b7a8f" }),
    id: async () => ME.email,
    isOwner: async () => false,
    canEdit: async () => ME.role === "backoffice",
    can: async () => true,
    name: async () => ME.email,
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
  function showSignIn(note) {
    document.getElementById("tabs").hidden = true;
    document.getElementById("main").innerHTML = `
      <section class="view" style="max-width:440px;margin:48px auto">
        <form class="panel" id="signin" style="padding:28px;display:grid;gap:14px">
          <div><h2>Sign in to Lead Desk</h2><p class="muted" style="margin:6px 0 0">Enter your work email. We'll send you a sign-in link.</p></div>
          <label class="f">Work email<input id="si-email" type="email" autocomplete="email" required placeholder="name@samsotech.com"></label>
          <button class="btn pri" id="si-btn" type="submit">Email me a sign-in link</button>
          <div id="si-msg" class="small">${note || ""}</div>
        </form>
      </section>`;
    document.getElementById("signin").onsubmit = async (e) => {
      e.preventDefault();
      const email = document.getElementById("si-email").value.trim().toLowerCase();
      const btn = document.getElementById("si-btn"), msg = document.getElementById("si-msg");
      if (!EMAIL_RE.test(email)) { msg.innerHTML = '<span style="color:var(--bad)">Enter a valid email address.</span>'; return; }
      btn.disabled = true; btn.textContent = "Sending…";
      const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname } });
      btn.disabled = false; btn.textContent = "Email me a sign-in link";
      msg.innerHTML = error
        ? `<span style="color:var(--bad)">${/not on the Lead Desk user list|signups not allowed|403/i.test(error.message) ? "This email isn't on the Lead Desk user list. Ask back office to add you." : "Couldn't send the link: " + error.message.replace(/[<>&]/g, "")}</span>`
        : `<span style="color:var(--ok)">Check your inbox for an email from Lead Desk and open the link on this device.</span>`;
    };
  }

  let started = false;
  async function start(session) {
    if (started || !session) return;
    started = true;
    ME.email = (session.user.email || "").toLowerCase();
    const { data } = await sb.from("members").select("role,engineer").eq("email", ME.email).eq("active", true).maybeSingle();
    ME.role = data ? data.role : null;
    window.__ldReady = true;
    window.__startApp && window.__startApp();
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
