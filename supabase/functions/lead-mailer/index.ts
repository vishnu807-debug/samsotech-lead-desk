// Lead Desk · lead-mailer (Supabase Edge Function)
//
// Sends three kinds of email:
//   • "assigned"  — a lead was assigned to them (called by a database trigger)
//   • "followups" — a follow-up they scheduled is now due (called every 10 minutes by a scheduled job)
//   • "renewals"  — won orders whose 2nd/3rd-year renewal is coming up, to the order's sales engineer and the
//                   AMC team (called once a day; needs 25_renewal_emails.sql)
//
// Secrets to set in Supabase → Edge Functions → Secrets:
//   RESEND_API_KEY  API key from resend.com (free tier is enough to start)
//   MAIL_FROM       e.g.  Lead Desk <leaddesk@samsotech.com>   (domain must be verified in Resend)
//   APP_URL         your Lead Desk address, e.g. https://lead-desk-samsotech.vercel.app
//   MAILER_SECRET   any long random text; the same value goes into 07_email_notifications.sql
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//
// Deploy with "Verify JWT" turned OFF; the function checks MAILER_SECRET instead.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const env = (k: string) => Deno.env.get(k) ?? "";
const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const APP_URL = env("APP_URL").replace(/\/$/, "");

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const dubai = (d: Date, withTime = true) =>
  d.toLocaleString("en-GB", { timeZone: "Asia/Dubai", weekday: "short", day: "2-digit", month: "short", year: "numeric", ...(withTime ? { hour: "2-digit", minute: "2-digit" } : {}) });

async function send(to: string, subject: string, html: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${env("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: env("MAIL_FROM"), to: [to], subject, html }),
  });
  if (!r.ok) throw new Error(`Email to ${to} failed: ${r.status} ${await r.text()}`);
}

function layout(title: string, rows: [string, string][], intro: string, button: string) {
  const tr = rows.filter(([, v]) => v).map(([k, v]) =>
    `<tr><td style="padding:6px 12px 6px 0;color:#5a6779;white-space:nowrap;vertical-align:top">${esc(k)}</td><td style="padding:6px 0;color:#142131">${v}</td></tr>`).join("");
  return `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#142131;max-width:560px">
    <h2 style="font-size:18px;margin:0 0 6px">${esc(title)}</h2>
    <p style="margin:0 0 14px;color:#5a6779">${intro}</p>
    <table style="border-collapse:collapse;font-size:14px">${tr}</table>
    ${APP_URL ? `<p style="margin:18px 0"><a href="${esc(APP_URL)}" style="background:#1e5aa8;color:#fff;padding:9px 16px;border-radius:6px;text-decoration:none">${esc(button)}</a></p>` : ""}
    <p style="color:#97a4b5;font-size:12px">Sent automatically by Lead Desk.</p></div>`;
}

const leadRows = (d: Record<string, any>): [string, string][] => {
  const c = d.contact ?? {};
  return [
    ["Lead", `<b>${esc(d.ref)}</b>`],
    ["Property", esc(d.accountName) + (d.country ? ` · ${esc(d.country)}` : "")],
    ["Region", esc(d.region)],
    ["Products", esc((d.products ?? [d.product]).filter(Boolean).join(", "))],
    ["Contact", [esc(c.name), esc(c.title)].filter(Boolean).join(", ") + (c.email ? `<br>${esc(c.email)}` : "") + (c.phone ? `<br>${esc(c.phone)}` : "")],
    ["Category", `${esc(d.category)}${d.source ? " · " + esc(d.source) : ""}`],
    ["Requirement received", esc(d.requirementDate)],
    ["Priority", esc(d.priority)],
    ["Requirement", esc(d.notes)],
  ];
};

async function engineerEmail(name: string): Promise<string | null> {
  if (!name) return null;
  const { data } = await sb.from("members").select("email,engineer").eq("role", "sales").eq("active", true);
  const m = (data ?? []).find((x) => (x.engineer ?? "").trim().toLowerCase() === name.trim().toLowerCase());
  return m?.email ?? null;
}

async function assigned(leadId: string) {
  const { data: lead } = await sb.from("leads").select("id,doc").eq("id", leadId).maybeSingle();
  if (!lead) return { skipped: "lead not found" };
  const d = lead.doc as Record<string, any>;
  const to = await engineerEmail(d.assignedTo);
  if (!to) return { skipped: `no active login linked to engineer "${d.assignedTo}"` };
  if (d.assignedMailFor === d.assignedTo) return { skipped: "already emailed" };
  await send(to, `New lead assigned: ${d.ref} · ${d.accountName}`,
    layout(`New lead: ${d.accountName}`, leadRows(d), `Back office has assigned <b>${esc(d.ref)}</b> to you. Please contact the client and log the meeting in Lead Desk.`, "Open Lead Desk"));
  await sb.rpc("mark_lead_mail", { p_id: leadId, p_field: "assignedMailFor", p_value: d.assignedTo });
  return { sent: to };
}

async function followups() {
  const { data, error } = await sb.rpc("due_followups");
  if (error) throw error;
  const out: unknown[] = [];
  for (const r of data ?? []) {
    try {
      const due = new Date(r.due);
      const timed = String(r.followup).includes("T");
      await send(r.email, `Follow-up due ${timed ? "at " + due.toLocaleTimeString("en-GB", { timeZone: "Asia/Dubai", hour: "2-digit", minute: "2-digit" }) + " (Dubai)" : "today"}: ${r.account} · ${r.id}`,
        layout(`Follow-up: ${r.account}`, [["When", esc(dubai(due, timed)) + (timed ? " (Dubai time)" : "")], ["Follow up on", esc(r.note)], ...leadRows(r.doc)],
          "This is the follow-up you scheduled in Lead Desk. When it's done, open the lead and click <b>Mark follow-up done</b>, or set the next one.", "Open Lead Desk"));
      await sb.rpc("mark_lead_mail", { p_id: r.id, p_field: "followUpRemindedFor", p_value: r.followup });
      out.push({ id: r.id, sent: r.email });
    } catch (e) { out.push({ id: r.id, error: String(e) }); }
  }
  return { checked: (data ?? []).length, results: out };
}

async function renewals() {
  const { data, error } = await sb.rpc("due_renewals");
  if (error) throw error;
  const rows = (data ?? []) as Record<string, any>[];
  if (!rows.length) return { checked: 0 };
  const { data: mem } = await sb.from("members").select("email,engineer,role").eq("active", true).in("role", ["sales", "amc"]);
  const amc = (mem ?? []).filter((m) => m.role === "amc").map((m) => m.email);
  const byMail = new Map<string, Record<string, any>[]>();
  const add = (to: string, r: Record<string, any>) => { if (!byMail.has(to)) byMail.set(to, []); byMail.get(to)!.push(r); };
  for (const r of rows) {
    const eng = (mem ?? []).find((m) => m.role === "sales" && (m.engineer ?? "").trim().toLowerCase() === String(r.engineer ?? "").trim().toLowerCase());
    if (eng) add(eng.email, r);
    for (const a of amc) add(a, r);
  }
  const out: unknown[] = []; let failed = false;
  for (const [to, list] of byMail) {
    list.sort((a, b) => a.days - b.days);
    const tr = list.map((r) =>
      `<tr><td style="padding:6px 12px 6px 0"><b>${esc(r.account)}</b><br><span style="color:#5a6779">${esc(r.ref)} · ${esc(r.products)}</span></td>
       <td style="padding:6px 12px 6px 0;white-space:nowrap">Year ${esc(r.yr)}</td>
       <td style="padding:6px 12px 6px 0;white-space:nowrap">${esc(dubai(new Date(r.due + "T09:00:00+04:00"), false))}<br><span style="color:#5a6779">in ${esc(r.days)} days</span></td>
       <td style="padding:6px 0">${esc(r.engineer || "—")}</td></tr>`).join("");
    const html = `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#142131;max-width:640px">
      <h2 style="font-size:18px;margin:0 0 6px">Renewals coming up</h2>
      <p style="margin:0 0 14px;color:#5a6779">These won orders are due for their AMC or subscription renewal. Sales and the AMC team work on them together: open the Renewals page for the amounts and to record progress.</p>
      <table style="border-collapse:collapse;font-size:14px"><tr style="color:#5a6779;text-align:left"><th style="padding:0 12px 6px 0">Hotel</th><th style="padding:0 12px 6px 0">Renewal</th><th style="padding:0 12px 6px 0">Due</th><th style="padding:0 0 6px">Sales engineer</th></tr>${tr}</table>
      ${APP_URL ? `<p style="margin:18px 0"><a href="${esc(APP_URL)}" style="background:#1e5aa8;color:#fff;padding:9px 16px;border-radius:6px;text-decoration:none">Open Renewals</a></p>` : ""}
      <p style="color:#97a4b5;font-size:12px">Sent automatically by Lead Desk.</p></div>`;
    try {
      await send(to, list.length === 1 ? `Renewal due in ${list[0].days} days: ${list[0].account}` : `${list.length} renewals coming up`, html);
      out.push({ sent: to, orders: list.length });
    } catch (e) { failed = true; out.push({ to, error: String(e) }); }
  }
  // mark only when every email went out, so a failed run is tried again tomorrow
  if (!failed) for (const r of rows) await sb.rpc("mark_renewal_mail", { p_id: r.id, p_year: r.yr, p_step: r.step });
  return { checked: rows.length, results: out };
}

Deno.serve(async (req) => {
  if (req.headers.get("x-mailer-secret") !== env("MAILER_SECRET") || !env("MAILER_SECRET"))
    return new Response("Forbidden", { status: 403 });
  try {
    const body = await req.json().catch(() => ({}));
    const result = body.type === "assigned" ? await assigned(String(body.lead_id ?? ""))
      : body.type === "followups" ? await followups()
      : body.type === "renewals" ? await renewals()
      : { error: "unknown type" };
    return Response.json(result);
  } catch (e) {
    console.error(e);
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
