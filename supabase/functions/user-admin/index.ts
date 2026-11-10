// Lead Desk · user-admin (Supabase Edge Function)
//
// Lets a Supervisor create a sign-in for a new team member, or reset someone's password,
// without opening the Supabase dashboard. New and reset passwords are set to DEFAULT_PASSWORD
// (Samsotech123 unless you set the secret), and the person must choose their own password the
// first time they sign in.
//
// Deploy with "Verify JWT" ON (the default). Optional secret: DEFAULT_PASSWORD.
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const env = (k: string) => Deno.env.get(k) ?? "";
const DEFAULT_PASSWORD = env("DEFAULT_PASSWORD") || "Samsotech123";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// deno-lint-ignore no-explicit-any
async function findUserId(admin: any, email: string): Promise<string | null> {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const u = data.users.find((x: { email?: string; id: string }) => (x.email ?? "").toLowerCase() === email);
    if (u) return u.id;
    if (data.users.length < 200) return null;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    // Who is calling? Must be an active back-office member.
    const caller = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      auth: { persistSession: false },
    });
    // Permission check uses the same role/permission table as the app and the database.
    const { data: allowed, error: permErr } = await caller.rpc("has_perm", { p: "users.manage" });
    if (permErr || allowed !== true) return reply({ error: "Only a Supervisor (or a role with 'Users, roles and permissions') can manage sign-ins." }, 403);

    const { action, email: rawEmail } = await req.json();
    const email = String(rawEmail ?? "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply({ error: "That email address isn't valid." }, 400);

    const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
    // audit trail (supabase/10_audit_trail.sql); never blocks the action if the table isn't there yet
    const { data: who } = await caller.auth.getUser();
    const actor = (who?.user?.email ?? "unknown").toLowerCase();
    const audit = async (action: string, summary: string) => {
      try { await admin.from("audit_log").insert({ actor, actor_role: "supervisor", source: "app", action, entity: "user", entity_id: email, summary }); } catch (_) { /* ignore */ }
    };
    const { data: member } = await admin.from("members").select("email,active,role").eq("email", email).maybeSingle();
    if (!member || !member.active) return reply({ error: "Add this person under Users and access first." }, 400);
    // Only a Supervisor may reset another Supervisor's password.
    const { data: myRole } = await caller.rpc("my_role");
    if (member.role === "supervisor" && myRole !== "supervisor") return reply({ error: "Only a Supervisor can reset a Supervisor's sign-in." }, 403);

    const id = await findUserId(admin, email);
    if (action === "create") {
      if (id) return reply({ status: "exists" });
      const { error } = await admin.auth.admin.createUser({
        email, password: DEFAULT_PASSWORD, email_confirm: true, user_metadata: { must_change_password: true },
      });
      if (error) return reply({ error: error.message }, 400);
      await audit("sign_in_created", `Created a sign-in for ${email} with the temporary password`);
      return reply({ status: "created", password: DEFAULT_PASSWORD });
    }
    if (action === "reset") {
      if (!id) {
        const { error } = await admin.auth.admin.createUser({
          email, password: DEFAULT_PASSWORD, email_confirm: true, user_metadata: { must_change_password: true },
        });
        if (error) return reply({ error: error.message }, 400);
        await audit("sign_in_created", `Created a sign-in for ${email} with the temporary password`);
        return reply({ status: "created", password: DEFAULT_PASSWORD });
      }
      const { error } = await admin.auth.admin.updateUserById(id, {
        password: DEFAULT_PASSWORD, user_metadata: { must_change_password: true },
      });
      if (error) return reply({ error: error.message }, 400);
      await audit("password_reset", `Reset the password of ${email} to the temporary password`);
      return reply({ status: "reset", password: DEFAULT_PASSWORD });
    }
    return reply({ error: "Unknown action." }, 400);
  } catch (e) {
    console.error(e);
    return reply({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
