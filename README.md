# Lead Desk: hosting on Supabase + Vercel

Lead Desk runs as a static website on **Vercel**, with its database and sign-in on **Supabase**. Staff sign in with a link emailed to their work address. The database decides what each person can see and change:

| Role | Sees | Can change |
|---|---|---|
| Back office | Everything | New leads, verification and assignment, products, engineers, users, settings |
| Sales engineer | Only leads assigned to their linked engineer name | Submit their own outbound leads (back office still verifies them); stages, amounts, products, follow-ups and notes on their own leads |
| Management | Dashboard, team pipeline, accounts (read-only) | Nothing |
| Anyone else | Nothing | Nothing |

These rules are enforced by Postgres row-level security, not just by the screens.

## What's in this folder

```
public/            the website Vercel serves
  index.html       the app
  adapter.js       connects the app to Supabase and shows the sign-in screen
  config.js        your Supabase URL and key (you fill this in)
supabase/          SQL to run once, in order
  01_schema.sql            tables, security rules, functions
  02_add_yourself.sql      makes you the first Supervisor (edit the email first)
  03_seed_settings.sql     products, engineers, sources, rates, 2026 history, account registry
  04_seed_leads_part1-3    the 976 leads from the 2026 Excel sheet
  05_sales_outbound_leads.sql  update for existing installs: lets sales submit outbound leads (already in 01 for new installs)
  06_import_leads_0986_to_1052.sql  adds the Excel leads from 20 Oct – 4 Nov 2026
  08_territories.sql           territory list and routing rules
  09_rbac.sql                  four roles (Supervisor, Lead Manager, Management, Sales) and the permission table the database enforces
  07_email_notifications.sql   automatic emails (run after deploying the lead-mailer function)
  functions/lead-mailer/index.ts  the Edge Function that sends the emails
  functions/user-admin/index.ts   creates sign-ins and resets passwords (Supervisors)
app-source/lead-desk.html  the app source. After editing it, run `python3 build.py app-source/lead-desk.html`
vercel.json                Vercel settings
```

---

## Step 1: Create the Supabase project (10 min)

1. Go to **supabase.com**, sign up and click **New project**.
2. Name it `lead-desk` and set a strong database password (store it safely). For **Region**, pick the one closest to Dubai.
3. Wait about two minutes for the project to start.

## Step 2: Create the database and load the data (5 min)

In Supabase, open **SQL Editor → New query**. For each file below, paste its contents and click **Run**, in this order:

1. `supabase/01_schema.sql`
2. `supabase/02_add_yourself.sql`. **First change `you@samsotech.com` to the email you'll sign in with.**
3. `supabase/03_seed_settings.sql`
4. `supabase/04_seed_leads_part1.sql`, then `part2`, then `part3`
5. `supabase/08_territories.sql`, then `supabase/09_rbac.sql`

To check it worked, open **Table Editor → leads**. It should show 976 rows.

## Step 3: Set up sign-in (10 min)

In Supabase, go to **Authentication**:

1. **Sign In / Providers → Email**: make sure Email is enabled. You can leave "Confirm email" on.
2. **Hooks → Add hook → Before User Created** → type *Postgres function* → choose `public.hook_before_user_created` → Save.
   This stops anyone whose email isn't on the Lead Desk user list from creating an account. Even without the hook, such people see no data, but the hook keeps the user table clean.
3. **Emails → SMTP Settings**: Supabase's built-in email is only for testing and sends very few emails per hour. For real use, turn on **custom SMTP** and enter your company mail server (Microsoft 365, Google Workspace) or a service like Resend or SendGrid. Use a sender such as `leaddesk@samsotech.com`.
4. Optional: in **Emails → Templates → Magic Link**, change the subject to "Your Lead Desk sign-in link".

You'll come back to **URL Configuration** after Step 5.

## Step 4: Connect the website to Supabase (2 min)

In Supabase, go to **Project Settings → API** (in newer projects, **API Keys**) and copy:
- the **Project URL**, e.g. `https://abcd1234.supabase.co`
- the **anon / publishable** key. Never use the `service_role` or secret key here.

Open `public/config.js` and paste both values in.

## Step 5: Publish on Vercel (10 min)

**Option A, through GitHub (recommended, easy to update later)**
1. Create a private GitHub repository, e.g. `samsotech/lead-desk`, and upload everything in this folder.
2. Go to **vercel.com → Add New → Project**, import the repository, leave Framework Preset as **Other** and click **Deploy**. `vercel.json` already tells Vercel to serve the `public` folder.
3. Vercel gives you an address like `https://lead-desk-samsotech.vercel.app`. In Vercel → Settings → Domains you can also add your own, e.g. `leads.samsotech.com`.

**Option B, from your computer**
```bash
npm install -g vercel
cd lead-desk
vercel --prod
```

## Step 6: Tell Supabase the website address (2 min)

In Supabase, go to **Authentication → URL Configuration**:
- **Site URL**: your Vercel address, e.g. `https://lead-desk-samsotech.vercel.app`
- **Redirect URLs**: add `https://lead-desk-samsotech.vercel.app/**`, plus your own domain if you added one.

Without this, sign-in links will open the wrong page.

## Step 7: Sign in and add your team

### Option 1: create users with a password (no email needed)
For each person:
1. **Add them to Lead Desk's user list**, either in the app (Products & settings → Users and access) or in Supabase SQL Editor:
   ```sql
   insert into public.members (email, role, engineer) values
     ('shahbaz@samsotech.com', 'sales', 'Shahbaz'),
     ('jayant@samsotech.com',  'management', null),
     ('lidiya@samsotech.com',  'backoffice', null)
   on conflict (email) do update set role = excluded.role, engineer = excluded.engineer, active = true;
   ```
   Roles are `backoffice`, `sales` or `management`. For `sales`, the engineer name must match one in the Sales engineers list exactly.
2. In Supabase → **Authentication → Users → Add user → Create new user**, enter the same email and a temporary password, and tick **Auto Confirm User**. Do step 1 first; otherwise the sign-up check (the "Before User Created" hook) refuses the account.
3. Send them the address and temporary password. They sign in with email and password, then click **Password** at the top right to choose their own.

To reset a password later: Authentication → Users → click the user → set a new password.

### Option 2: email sign-in links
This needs custom SMTP set up (Step 3). Add the person to the user list, and they click "Email me a sign-in link instead" on the sign-in screen.

### Your own first sign-in

1. Create your own user as in Option 1 (your email is already on the list from `02_add_yourself.sql`), then sign in with your password.
2. Go to **Products & settings → Users and access**. For each person, type their work email and choose a role. For sales engineers, also choose their engineer name, which is what links them to their leads.
3. Tell them the address. They sign in the same way.

---

## Updating an existing install

**22 Nov 2026: split a lead into separate leads (separate quotations).** Run `supabase/52_split_leads.sql` (after 51; safe to run again; it adds one small function and one new insert rule; no lead, account, order or user that already exists is changed or deleted). Replace `public/index.html` (`public/adapter.js` is unchanged).

- **What it is for.** A customer asks about several products and wants a separate quotation for each. **Combined quotation:** do nothing, keep the products on one lead and upload one quotation, as before. **Separate quotations:** split the lead first, then upload one quotation on each lead.
- **How.** Open the lead, **Products discussed → Split into separate leads** (the same button is offered inside the quotation form when the lead has two or more products). Tick the products to move. Either one new lead for each ticked product, or one new lead for all the ticked products together. A preview shows which lead keeps what. At least one product always stays on the original.
- **When.** Before a quotation is sent: status Assigned, Attended or Meeting Done, no quotation yet, two or more products. Not on an upsell lead, not on a split lead, not on a registered order.
- **Who.** Sales on their own leads, Lead Manager and Supervisor on any lead. Management, AMC and Key Account Manager cannot.
- **What the new lead gets.** Same hotel, contact, engineer, lead generator, category, status and stage dates as the original, plus the moved products (and their PMS interfaces). Its own quotation, forecast line, target date, follow-up and Won or Lost result. The reference is the original's with -S1, -S2 added (for example LD2026-0060-S1). It carries a **Split** label, a link back to the original, and the original lists its split leads.
- **Money rules (your decisions).** Same lead generator, full incentive on revenue. Revenue counts in full for the engineer's targets and incentive (it is **not** an upsell). The lead generator's **lead count and conversion do not go up** (it is still one customer request); the generator's revenue, incentive and open pipeline include the split leads. Each split lead is its own line in the forecast, the pipeline and the order list, so nothing is counted twice: the original keeps only its own products.
- **Import quotations** already matches a quotation to the open lead that has the same product, so a quotation PDF for one product lands on the right lead.
- **Database.** A separate rule lets a Sales login create a Split lead only from their own approved lead that has no quotation, at Assigned, Attended or Meeting Done, in the same status, for the same engineer, hotel and lead generator. Everything else is refused (a lead with a quotation, someone else's lead, a new lead, an upsell, a split of a split, another generator or hotel). Lead Manager and Supervisor use the normal create rule. Each new lead and the change on the original are in the audit trail. The "new lead assigned" email is not sent for a split lead.
- **Know before using.** (1) Once a quotation is sent on a lead it can no longer be split; split first. (2) Splitting moves the product off the original, so undo it by editing the products on the leads (Lead Manager or Supervisor can delete a split lead that was created by mistake). (3) A split lead has no follow-up date yet; set one (the activity rules will remind you). (4) Meetings stay on the original lead only, so meeting counts are not doubled. (5) Overall lead counts in Management include split leads, like upsell leads.
- **Tested** as Sales (own and a colleague's lead), Lead Manager, Supervisor, Management and AMC, at 320, 390, 768, 1024 and 1440 px (no sideways scroll); 50 app checks and a local Postgres test of the database rule (18 checks: who may create a split lead and everything that is refused); totals (leads, revenue) unchanged by a split; the earlier tests re-run.

**21 Nov 2026 (evening): hotel chain saved on each account, and the Key Account Manager role.** Run `supabase/51_key_account_manager.sql` (after 50; safe to run again; it adds one table, two small functions and new rules; no lead, account, order, contract or user that already exists is changed or deleted). Replace `public/index.html` (`public/adapter.js` is unchanged). Then, once, as Supervisor: **Products & settings → Territories & accounts → Hotel chains → Save chains on accounts**.

- **Chain saved on each account.** The chain (and region) of a hotel is now stored on its account, filled once from the brand list and kept up to date when a new account is created. The Hotel chains panel shows how many accounts are saved, waiting, confirmed independent, or still without a chain, and one button saves them. Accounts that exist only through leads get an account record. Most leads carry no region of their own (it is worked out from the country), so the same button also saves the region on the account. Nothing is changed on any lead.
- **Bigger brand list.** About 100 more brand words and 22 more chains (for example Langham, Rosewood, Dorchester Collection, RIU, Swiss-Belhotel, ITC Hotels, Frasers, Toyoko Inn). A hotel named after its chain ("Accor", "IHG") is now recognised. If you have edited your own list, a button in the panel adds the new words to it; nothing you wrote is removed.
- **Hotels with no chain.** Back office → Data issues → **Hotels with no chain** (appears after the first save). Pick a chain for each, mark it "Independent (no chain)", or confirm the whole list at once. A confirmed hotel is not listed again. People who can manage accounts can change it; others can only look.
- **New role: Key Account Manager** (`keyaccount`). Read-only. Sees only the leads, hotels and key-account work of the **chains and regions allocated to them**. A person sees a lead only when **both** the chain and the region match one of their allocation rows; one person can hold several rows (a chain with "all regions" or with chosen regions). Hotels with no chain are never visible to this role.
- **Allocate.** Products & settings → People & access → **Key account allocations** (Supervisor, permission `users.manage`). Add the user with the role "Key Account Manager" under Users and access first, then pick the person, chain and regions. Allocating the same chain again replaces its regions. Each row shows how many hotels and leads it matches today. Every allocation change is in the audit trail.
- **What the role sees.** Pipelines, Meetings, Accounts (with the Account profile) and Key accounts, all limited to the allocation, with a banner listing their chains and regions. Order and quotation amounts of their hotels are shown. Not shown: Leads entry, Back office, Focus, Management, Targets, Price book, Settings, Audit, Renewals (AMC prices), contract details, other chains. Lead popups are read-only. The role is not counted in targets, incentives, win rate or engineer revenue, and lead ownership and allocation to Sales are unchanged.
- **Enforced in the database.** A separate rule shows this role only allocated leads and accounts; further limits stop it from ever creating, changing or deleting a lead or account, and from reading anything except the settings and permissions documents, **even if a Supervisor later ticks more permissions for the role**. Key-account items can only be added or changed for hotels inside the allocation. A person can read only their own allocation rows; only the Supervisor changes them. The existing lead rules are not changed.
- **Default permissions for the role** (first time only): Pipelines, Meetings, Accounts and Key accounts. The role does not hold "see all leads".
- **Know before using.** (1) Run the save button **before** allocating, otherwise nobody sees any hotel (the panel warns you). (2) After the brand list or a hotel's chain changes, press the save button again. (3) A lead with no region at all (and a hotel with no saved region) will not show to someone limited to chosen regions; "all regions" rows still show it. (4) The first save writes one audit line per changed account.
- **Not in this phase.** The "Find chain" lookup from a hotel name and location (an optional second phase, suggestion only, a person confirms).
- **Tested** as Supervisor, Lead Manager, Management, Sales, AMC and three Key Account Managers (one chain and region, two chains, none) at 320, 390, 768, 1024 and 1440 px (no sideways scroll); 162 app checks and a local Postgres test (a Key Account Manager sees exactly the allocated chain and region, never another chain, region, a hotel without a chain, or someone else's allocation; cannot write; limits hold with extra permissions; run twice); Management totals are identical with the role set up; the earlier database and app tests were re-run.

**21 Nov 2026: Key accounts (phase 1).** Run `supabase/50_key_accounts.sql` (after 49; safe to run again; it adds one new table and two small functions, no lead, account, order, contract or meeting that already exists is changed or deleted). Replace `public/index.html` in GitHub. `adapter.js` is unchanged.

- **What it is for.** Corporate and key-account work that is **not part of a lead**: platform showcases, discussions about a group's hotel requirements, key account reviews. It sits in its own table and is **never counted** in leads, pipeline, win rate, targets, incentives or any Management total.
- **Who can use it.** A new permission, **Key accounts** (`keyacct.manage`, under Pages in Users → Roles & permissions). Management and Supervisor have it. A Supervisor can switch it on or off for any role. People without it do not see the tab and the database refuses them.
- **New tab "Key accounts".** Four small numbers (key accounts, meetings this quarter, next steps due in 14 days, overdue, no meeting for 60+ days), the next steps with a **Done** button, recent meetings, and one card per key account (stage, owner, last meeting, open requirements, people, open leads). Accounts with overdue steps come first. **My accounts / All accounts** switch appears when you own some of them.
- **Log account meeting.** Account or group (type to find an existing account, or a new name), meeting type (Platform showcase, Requirements discussion, Key account review, Relationship meeting, Proposal walkthrough, Other), date, client attendees, Samsotech attendees, hotels discussed, **notes (30 words minimum, same rule and live counter as lead meetings)**, requirements captured, next steps (who, ours or theirs, due date). Logging a meeting for a new name creates the key account for you. **Save and create a lead…** (only for people who can create leads) saves the meeting, then opens the normal New lead form for that account with the product ticked; when that lead is submitted its reference is written back on the requirement.
- **Account workspace.** Click a card: stage (Introduce, Showcase, Requirements, Proposal, Pilot, Rollout, Expand; click to change), owner, executive sponsor, **who we know** (role in the decision and how they feel about us), **requirements** (Open, In discussion, Promised, Delivered, Declined; **Create lead** button), **promises and next steps** (ours and theirs, due dates, Done), hotels in the account (with the products they already own), and the meetings timeline. Removing anything marks it removed; the row is kept.
- **Account profile.** The profile has a **Key account** button (or **Make key account**) for people with the permission, and the key-account meetings appear in its Activity list. People without the permission (for example Sales on an account they have a lead on) see only the **date and type** of each account meeting, nothing else, through the database function `key_meeting_dates`.
- **Database.** Table `key_items` (account record, meetings, requirements, promises). Read and write need `keyacct.manage`. Nobody can delete a row. The database fills in who and when. Every create, change and removal is in the audit trail (the text of the notes is not copied there, only "notes changed"). The same 30-word rule for meeting notes is enforced in the database (not for SQL editor imports).
- **One simplification to know.** Everyone who holds the permission can change every key account item; "owner" is shown and used for **My accounts**, but it does not lock editing. Every change is in the audit trail with the person's name.
- **Not in this phase.** Portfolio board with health, requirements demand across accounts, Prepare for next meeting brief, QBR deck, reminder emails, "what this work led to".
- **Tested** as Supervisor, Management, Lead Manager, Sales, Sales (no link to the account) and AMC at 320, 390, 768, 1024 and 1440 px (no sideways scroll on the page, the workspace, the log form or the add form); totals (leads, revenue, pipeline, wins) identical before and after; database tests on a local Postgres (who can read and write, no delete, notes rule, tampering, dates-and-types-only function, audit trail, permission switched off and on, run twice); the earlier tests were re-run.

**20 Nov 2026 (night, 3): Account profile (read-only).** Run `supabase/49_account_profile.sql` (after 48; safe to run again; it only adds one read-only function, no lead, account, order or contract data is changed). Replace `public/index.html` in GitHub. `adapter.js` is unchanged.

- **Open it.** Accounts page: click an account (the row used to open its latest lead). A panel opens in the same style as the lead popup, one column on a phone. Close with the **Close** button, **Esc**, or by clicking outside. Clients added from AMC contracts open the same panel.
- **What it shows.** Header (hotel, country, group, PMS, rooms, PCs, users, sales engineer, customer-success contact from the contract, status Customer / Prospect / Lapsed). Key numbers. Revenue by year (new sales, subscription, AMC; OHIP on its own). Products and licences (since which year, units, interface, AMC to which date). Products not yet sold (only those the hotel's PMS supports). Contracts and renewals. Contacts from every lead and contract, one line per email, the contract signer marked. Open leads and quotations (click one to open it). Activity: leads, meetings with their notes, contacts, quotations, orders and contracts.
- **Who sees what.** Supervisor, Management and Lead Manager see the whole account: revenue by year and by engineer, AMC and renewal amounts, contract prices, and a "Needs attention" list (contract expired or expiring, renewal due or overdue, no contact for 90 days, quotation with no answer for 30 days). Sales see the hotel, the products it owns, PMS, contacts from their own leads, renewal dates, their own leads and quotations, and **only their own revenue**. Sales never see AMC prices, other engineers' revenue or the engineer table.
- **Products a colleague sold.** Sales only read their own leads, so the database function `account_profile` (SQL 49) tells them which products the hotel already owns, since which year, units on the contract, the contract dates, the PMS, a colleague's open leads (reference, stage, engineer, product) and the date of the last meeting. It never returns money, contacts, notes, pending contracts or deleted leads. A Sales user can ask only about an account where they have a lead (assigned, generated or joint) or a contract of their own; anyone else gets nothing.
- **Numbers match.** Order revenue in the profile equals the Accounts page revenue for the same account (OHIP inside it, shown as "of which OHIP"); revenue by engineer uses the same joint-work split as Management. AMC and subscription by year come from approved contracts; with no contract they are worked out from the order (year 2 and 3) and marked "expected" when not billed yet.
- **Nothing is saved.** No new data entry and no notes box. Opening a profile writes nothing, so there is nothing new in the audit trail.
- **Tested** as Supervisor, Lead Manager, Management and Sales at 320, 390, 768, 1024 and 1440 px (no sideways scroll); totals tie to the Accounts page and to Management for 60 accounts per role; database tests on a local Postgres (who may ask, no money or contacts returned, pending and deleted left out, not callable when signed out, safe to run twice).

**20 Nov 2026 (night, 2): every new meeting needs real notes (30 words).** Run `supabase/48_meeting_notes.sql` (after 47; safe to run again; no existing lead, meeting or note is changed). Replace `public/index.html` (and `public/adapter.js` if you have not yet replaced it for the Request info update).

- **The rule.** When anyone adds a meeting, the notes must have at least **30 words**, and at least **15 different words** (so "ok ok ok…" does not pass). It applies to everyone: Sales, Lead Manager and Supervisor.
- **Where.** Log a meeting (lead popup), the Meeting done form, and the New lead form when the client has already been met. The notes box is now a larger text box with a live counter ("12 / 30 words", with a tick when enough) and the mic (voice typing) works on it. A message tells the person how many words they have.
- **Management.** The Meetings page already shows a Notes column, so every new meeting now arrives with proper notes. No layout change.
- **Old meetings are not touched.** Only new meetings are checked; saved meetings can still be edited (for example, changing a date) without re-checking their notes. Imports, the SQL editor and quotation / order registration are not affected.
- **Database.** `supabase/48_meeting_notes.sql` enforces the same rule, so it cannot be bypassed. To change the number without code, set `meetMinWords` in the settings document (default 30; the "different words" minimum is half of it).
- **Tested** as Sales, Lead Manager and Supervisor at 320, 390, 768 and 1440 px (no sideways scroll); database tests for new meetings, old meetings, imported leads, new leads with a meeting, and run twice; the earlier database tests give identical results with and without SQL 48.

**20 Nov 2026 (night): "Request info" now works both ways.** Run `supabase/47_info_request.sql` (after 46; safe to run again, no lead, account, order or contract data is changed). Replace **both** `public/index.html` and `public/adapter.js` in GitHub. To send the email, also redeploy the `lead-mailer` function (Supabase → Edge Functions → lead-mailer → paste `supabase/functions/lead-mailer/index.ts` → Deploy). Until it is redeployed nothing is emailed and nothing breaks.

- **Before.** Pressing **Request info** only changed the status to Info Needed and wrote a line in Activity. The person who created the lead was not told, saw "Waiting for a Lead Manager to approve this lead", could not add the missing contact details, and back office had no way to know they had answered.
- **Clear message.** The lead now says "Back office needs more information" with the reason, who asked and when. The reason also shows on the lead card (My pipeline → Awaiting approval), in Leads I created for others, and in the Verification queue ("Waiting for <creator> since <date>").
- **Email to the creator.** When Request info is pressed, the person who created the lead (or, if that cannot be found, the engineer who generated it or holds it) gets one email with the reason and an Open Lead Desk button. One email per request; asking again sends a new one.
- **The creator can answer.** On a lead at Info Needed, the creator, the sales engineer who generated it, or the engineer it is assigned to sees an **Answer back office** form: contact name, designation, email, phone, requirement, timeline and a short note. **Send back to review** saves it and puts the lead back in the queue. Only these fields can be changed this way (database function `lead_info_reply`); nobody else can answer, and direct edits still need the usual permission. It is recorded in Activity ("Info provided (email, requirement): <note> · sent back to review") and in the audit trail.
- **Back office sees the reply.** The queue card and the lead show a **Reply received** tag with who answered, when, the note and what was updated. Nothing else about verifying and assigning changes. Management and other users see the request but no answer form.
- **Tested** as Supervisor, Lead Manager, Sales (creator, generator, assigned engineer, unrelated), Management at 320, 390 and 1440 px; database tests on a local Postgres (who may answer, direct updates still refused, one email per request, run twice); earlier tests re-run.

**20 Nov 2026 (evening): one Edit mode for the lead popup.** Run `supabase/46_lead_account_guard.sql` (after 45; safe to run again, no lead, account, order or contract data is changed). Replace `public/index.html` in GitHub (`adapter.js` is unchanged).

- **One Edit button.** The lead popup now has a single **Edit** button (pencil, left of **Close**). It turns the whole popup into one edit form with an "Editing lead" badge, one sticky bar at the bottom ("N unsaved changes", **Cancel**, **Save changes**) and **Delete lead** on the bottom left. One Save makes one request and writes one Activity entry per group of changes. Cancel, Close and Esc ask "Discard unsaved changes?" when something has changed. The right column (stage buttons, follow-up, activity) is unchanged and works instantly.
- **Buttons removed from view mode:** Edit details, Set / Change target date, Change forecast, Remove quote, Add PMS / Edit PMS, Edit quantities, Add or remove products, Rename account (lead header) and the old Delete card. Everything they did is now inside Edit mode. **Rename** in the Accounts list is unchanged.
- **Account field.** In Edit mode the header account name becomes a search field (not case sensitive; shows city, country and lead count; the current account is marked). Fixing the spelling renames the account for all leads of that hotel (a warning says how many). Picking another existing account moves the lead. A name with no match offers "+ Create new account", with a confirmation. Changes are logged as "Account renamed: A → B" or "Account changed: A → B".
- **Who can edit what.** Supervisor: everything. Lead Manager: account (spelling fix, move, create), quotation amount and number (with a reason), target date, forecast, PMS, quantities, products. Sales: spelling fix on the account (direct when every live lead on the account is theirs and there are no contracts, otherwise it goes as a request for approval), plus their own dates, forecast, PMS, quantities and products; Sales keep Upload / Revise quotation. Category, contact, requirement and generated-by stay Supervisor-only. Assigned to is read-only (use **Reassign**). Management and AMC have no Edit button.
- **Products.** Product chips with add / remove in the header (a single dropdown for one-product leads).
- **Safety.** Another person's change to the same lead is caught when you press Save (you are told to reopen and retry). Live updates pause while you type so your draft is never overwritten.
- **Database (SQL 46).** Closes a gap: until now a Sales login could write a lead's account name or key directly. The database now allows that only for people with **account management** or through the rename function (which keeps the Sales own-account rule). The SQL editor and the service role are unaffected.
- **Tested** as Supervisor, Lead Manager, Sales, Management and AMC at 320, 390, 768, 1024 and 1440 px (no sideways scroll, header and footer stay fixed); Management totals tie; earlier tests re-run.

**20 Nov 2026 (afternoon): security fixes and account renaming.** Run `supabase/44_account_rename_sales.sql` and then `supabase/45_close_anon_functions.sql` (safe to run again; no lead, account, order or contract data is changed). In GitHub replace `public/index.html`, `public/adapter.js`, `vercel.json` and **add the whole new `public/vendor` folder** (5 library files, ~2.9 MB). Redeploy the Edge functions `user-admin` and `lead-mailer` (Supabase → Edge Functions → paste the new code → Deploy).

- **Security fixes (from the 20 Nov review).** (1) The PDF reader now opens PDFs with `isEvalSupported:false`, closing the public pdf.js weakness CVE-2024-4367 (a crafted PDF could run code). (2) The libraries (pdf.js, Excel, presentation export, Supabase) are served from your own site in `public/vendor`, pinned to exact versions, instead of public CDNs; the CDN address is only a fallback if a vendor file is missing. (3) New headers in `vercel.json`: Strict-Transport-Security, Permissions-Policy, and a Content-Security-Policy. The strict allow-list policy is in **report-only** mode first (it only logs); the small safe part is already enforced. After a few days, open the browser console (F12) on the live site: if nothing says "Content Security Policy", rename the `Content-Security-Policy-Report-Only` header to `Content-Security-Policy` to enforce it. (4) The `user-admin` function now makes a **random 14-character temporary password for every new or reset sign-in** and shows it once; the fixed password `Samsotech123` no longer exists. (5) SQL 45 stops the not-signed-in "anon" role from running Lead Desk functions at all (they already refused it; now they are unreachable); signed-in users are unaffected. (6) `lead-mailer` compares its secret in constant time; `user-admin` can be limited to your app address with the optional secret `APP_ORIGIN`.
- **Still for you to check in Supabase / Vercel (cannot be done from the code):** Authentication → password minimum length and leaked-password protection; two-step login for Supervisor and Management; sign-ups disabled (invite only); rate limits; backups; GitHub repository private with two-step login; Vercel deployment protection. Details: project doc `lead-desk-security-review.md`. One known limit: Excel files are read with SheetJS 0.18.5, the last version on npm; newer builds are only on the SheetJS site.
- **Account renaming (SQL 44).** The **Rename account** button now sits in the lead screen header, left of **Close** (Supervisor, Lead Manager, and Sales on their own leads). In **Accounts** the Rename column now stays on screen (it was hidden off to the right). **Supervisor / Lead Manager:** rename directly at any stage (Assigned, Won, …). **Sales:** rename directly only when every live lead on the account is theirs and the account has no AMC contract; otherwise the app sends a request to a Lead Manager or Supervisor (a reason is always required). **Management:** can ask for a rename of any account (Accounts list → Ask to rename). AMC: no change. The name changes on the account, all its leads and its contracts; the old name stays searchable; everything is in the audit trail. Enforced in the database. Known small gap: a Sales person can still edit the account name text on their own single lead through a hand-made request; it relabels only that lead (not the account or colleagues' leads) and is audited.

**20 Nov 2026: Register closed orders, a Sales person registers only under their own name.** Run `supabase/43_register_own_name.sql` (after 42; safe to run again, no order, lead or account is changed). Replace **both** `public/index.html` and `public/adapter.js` in GitHub.

- **What changed.** The "These orders were won by" list used to appear for anyone whose permissions looked like a manager's, so a Sales login with extra rights (for example Prajwal) could pick any engineer. It now follows the role: only a **Lead Manager** or **Supervisor** sees the list of engineers. Every other login sees "Registered for <their own name>" and cannot change it. A login not linked to an engineer name is told to ask a Supervisor.
- **Database.** The same rule is enforced in the database (the insert rule on `reg_orders` now checks the role, not the permission `lead.edit_all`). Tested: a Sales role holding `lead.edit_all` is still refused when registering for another engineer; Lead Manager and Supervisor are accepted; Management and AMC are refused.
- **If a Sales person still sees other people's sales**, check **Settings → Roles and permissions** for that role: `lead.view_all`, `lead.view_won` or `lead.edit_all` give a role access to everyone's leads, orders or edits by design.

**19 Nov 2026 (night, 3): Register closed orders.** Run `supabase/42_register_orders.sql` (after 41; safe to run again, no lead, account or order data is changed). Replace **both** `public/index.html` and `public/adapter.js` in GitHub.

- **What it is.** A way to record orders a salesperson already won this year, from their approved Salesforce quotation PDFs, so each person's 2026 closed total is complete. These are Won orders but **not leads**: they are left out of lead counts, conversion, submitted, pipeline, forecast and lead-generator credit, and counted in revenue, targets, per-engineer closed totals, products, accounts, World view, Installed base and renewals. No incentive changes. They carry a "Registered" chip.
- **Who can use it.** A Supervisor can always register. Anyone else needs access for a period of time: **Settings → People & access → Register closed orders** (Supervisor), choose the user, start and end dates (default 14 days, at most 120). The database refuses uploads outside those dates. Sales register for themselves only. A Lead Manager or Supervisor can register for a named engineer. Approving needs the new permission `order.register_approve` (default Lead Manager and Supervisor; change it under Roles and permissions).
- **Upload.** Focus → **Registered orders** → Register orders. Up to 20 quotation PDFs. They are read in the browser and never stored. Each row shows quote number, client, country, contact, products and lines, amount and AED, and the order date (must be in the registration year, default the current year; change it with "Year being registered" in the same Settings panel). Status is Ready, Needs a detail or Skipped (a quote number already on a lead, or already registered or waiting, is skipped). If a similar account already exists you choose the existing one or a new one. **Submit for approval** sends them; nothing is counted until approved.
- **Check and approve.** Up to 3 small page pictures per quote are kept only while the order waits. **To approve** opens each order with the picture on the left and the values read on the right (on a phone, a Picture / Values toggle). The approver can correct values (a reason is required and kept on the record), tick **Verified**, then Approve or Reject (a reason is required). "Approve all ticked" only works on orders that were opened and ticked Verified. The person who uploaded a batch cannot approve it (a Supervisor can). Approving creates the account if new, the contact, country, products and a Won order whose value equals the quotation value. PMS may be "Unknown" (it appears in Data issues).
- **Pictures are deleted** by the database when the order is approved, rejected, withdrawn, or after 30 days waiting (it then expires). Only the uploader, Lead Managers and Supervisors can see them while they exist.
- **Similar accounts.** Back office shows a "check the account" queue (for users with account management) with **Merge accounts** or **Keep separate**. Merging keeps the old name as an alias.
- **Withdraw.** A Supervisor can withdraw an approved order (soft only: it is marked removed, nothing is erased). Revenue falls by that order only.
- **2026 closed orders by salesperson.** Management → **Closed orders** (year selector, Registered vs through leads, "Waiting for approval" kept separate and never in totals, a check line that the total equals Management → Engineers and Revenue per account, click a name to see the orders, **Export to Excel**). Sales also get a "Closed in 2026" tile on Focus.
- **Audit trail.** Every submission, correction, approval, rejection, withdrawal, expiry, access change and picture deletion is recorded.
- **Not built (needs your decision).** "Attach to an open lead": moving an open lead to Won has its own rules (stage flow, order = quotation). A row whose client has an open lead shows a warning; choose Register separately or Skip.
- **Tested.** About 85 database checks and about 120 app checks across all five roles at 320 / 390 / 768 / 1024 / 1440 px (no horizontal scroll, no errors), plus the full earlier test set.

**19 Nov 2026 (late night, 2): Version label.** No SQL. Replace `public/index.html` in GitHub. A small grey line at the bottom of every page now reads "Lead Desk · version 19 Nov 2026 · build 906f492" (the date the file was built and a short code of its content). If you can see a newer date or a different build code after a deployment, the new file is live; if not, reload with Ctrl+F5 (Cmd+Shift+R on a Mac) or check that the Vercel deployment is Ready. `build.py` adds it automatically; nothing to maintain by hand. Not printed.

**19 Nov 2026 (late night): Salesforce PDF reader fixes.** No SQL. Replace `public/index.html` in GitHub (nothing else changes). Checked against three real quotes (Hilton Brussels QT-2026/18670, Warwick Brussels QT-2026/18473 Check-out Box, Warwick Brussels QT-2025/14084). Amounts, quantities, totals, discounts and dates were already right; four things were wrong and are fixed: (1) **item names that wrap onto a second line were cut** ("...Software Solution - Annual" lost "Subscription"; "eREG Web based Document Management System" lost "(On-Premise)"), the reader now takes the whole name (bold text) and the description starts after it; (2) **Check-out Box items were given the wrong product** (Hardware (iPad / Tablet) and OHIP Integration / Migration) because "Check-Out-Box" with hyphens was not recognised, now they map to Check-out Box; (3) **the contact's designation was cut** ("Regional Project Manager -", "Director of Business"), now complete; (4) price-book **line rules** are matched on the full name, and rules taught earlier from the shortened name still work (nothing in saved data changes). Not read on purpose: the "Optional Item(s)" below the net price (they are not in the quote value).

**19 Nov 2026 (night): Line rules view fixed.** No SQL. Replace `public/index.html` in GitHub (nothing else changes). Management → Price book → Line rules was wider than the screen (long quote wording could not wrap, so "Matched to" and the Switch button were cut off). Now the table fits the screen with wrapping text and a fixed header, there is a **search box** (wording, price item or who taught it) and a **Switched on / Switched off filter** with a count, the panel **stays open** after you switch a rule, and on phones each rule is a card with a large Switch button. Rules themselves are unchanged.

**19 Nov 2026 (evening): Voice to text for notes.** No SQL. Replace `public/index.html` in GitHub (nothing else changes). A **Speak** button (microphone) now sits under: Requirement / notes and Meeting notes on the New lead form, Requirement / notes in Edit details, Meeting notes and Requirement note in Meeting done, What happened and Next step in Log contact / Log update. Tap Speak, talk, tap Stop; the words appear in the box as you speak and are added after anything already typed. You can still edit before saving, and the text is saved like typed text. A language box next to the button (English UK or US, Arabic, Hindi, French, Spanish, German, Russian, Turkish, Chinese) is remembered per browser. It uses the speech recognition built into the browser, so nothing is installed or loaded: it works in Chrome, Edge and Safari (phones and computers) and the button is not shown in browsers without it (such as Firefox). It needs an internet connection and the browser asks once for permission to use the microphone. **Privacy:** the browser, not Lead Desk, turns speech into text, and depending on the browser the audio may be processed by its provider (Google for Chrome, Apple for Safari); Lead Desk stores only the text. The Log contact box "What happened" is now a two-line box (limit still 300 characters) so spoken sentences stay visible.

**19 Nov 2026 (afternoon): Won leads without a quotation now show in Focus.** No SQL. Replace `public/index.html` in GitHub (nothing else changes). Focus has a new first section, **Won, upload the quotation**, and a tile **Won, quote missing** (count and order value). A Sales engineer sees only their own won leads without an uploaded quotation (oldest first, the 5 oldest with **Show all**), each with an **Upload quotation** button that opens the same upload form as the banner on the Leads page. Lead Manager, Supervisor and Management see the whole team (or one engineer chosen in the Engineer box) and can open each lead; the buttons to remind engineers stay in Back office → Data issues. It is the same list and the same rules as before (won on or after the start date, no PDF or e-mail quotation), so the numbers match Back office and Management → Pipeline health. Phones show cards instead of a table.

**19 Nov 2026: World view (Management → World view) and Market outlook.** Run `supabase/41_world_view.sql` (after 40; safe to run again, no lead or account data is changed). Replace `public/index.html` in GitHub **and add the new file `public/world-map.js`** (the country outlines, about 135 KB; it is only downloaded when someone opens World view; `adapter.js` is unchanged). Management and Supervisor get a new **World view** tab: a real world map with the actual country outlines (Natural Earth, public domain; no map service or tiles loaded from outside; very small countries and islands such as Bahrain, Singapore or Maldives are shown as dots) with a **Map / Tiles** switch (Tiles is a simple one-square-per-country fallback, also shown if the outline file cannot load), coloured by revenue, orders won, win rate, growth vs last year, pipeline value or opportunity score; zoom by region; a country panel (a bottom sheet on phones) with our numbers, the market outlook, hotel chains and "Open leads for this country"; the region list; "Where to focus" groups; an all-countries list; and a whitespace list (hotels we know that have never bought, with Excel export). Figures follow the same rules as the other Management views and add up to them. **Market outlook** (hotel pipeline, tourist arrivals growth, regulation) starts **empty**: nothing is pre-filled or fetched live. Management types it or imports it from an Excel template, and every figure needs a source name, a web link and a date (checked in the database too); figures older than 12 months are tagged "may be out of date". New permissions: `report.world` (open the view) and `outlook.manage` (enter or import outlook data and set the score weights); both are on for Management by default, the Supervisor can change this in Users → Roles & permissions. Sales, Lead Manager and AMC do not see the view. The Leads page also gets a "Country" filter chip when opened from the World view.

**18 Nov 2026 (evening): Won leads without a quotation, with reminders.** Run `supabase/40_won_without_quote.sql` (after 39; safe to run again, no lead data is changed). Replace **both** `public/index.html` and `public/adapter.js` in GitHub. For the emails, also redeploy the `lead-mailer` function from `supabase/functions/lead-mailer/index.ts` (Supabase → Edge Functions → lead-mailer → paste the new code → Deploy; keep "Verify JWT" off). Without the emails set up, the list and the banner still work.

- **The list.** A lead counts when it is Won, won on or after 1 January of this year (change it with `wonQuoteFrom` in settings if needed), and has no quotation read from a PDF or e-mail and no hand-entered quotation confirmed by a Lead Manager or Supervisor. It is calculated, so nothing is stored on the leads.
- **Back office → Data issues → "Won without quotation"** (Lead Manager, Supervisor): lead, property, engineer, order value, won date, days, last reminder, status (Not reminded / Reminded / Quote uploaded). Filters for engineer, month and status, **Export Excel**, **Remind** per lead and **Remind all**. On phones each lead is a card.
- **Management → Pipeline health:** the same list, read only, with the same count and AED total.
- **Sales:** a "need the quotation uploaded" banner at the top of **Leads**, a "Quote needed" chip on each lead, and an **Upload quotation** button that opens the lead at the upload form. Sales see only their own leads.
- **Closing it with the right value.** The form shows the old and new value side by side ("AED 6,327 → AED 4,000 (−AED 2,327)"). The order value becomes the quotation value (before tax). Sales can do this on their own older Won leads too (outside the 30-day window), only for a lead that has no uploaded quotation. The change goes to "Changes after Won" and the audit trail.
- **Emails.** One email per sales engineer listing their leads, every Monday 08:00 Dubai time (set up by the SQL file when the automatic emails are installed), and when a Lead Manager or Supervisor presses Remind. The same lead is never reminded twice within 3 days. Each reminder is in the audit trail and the lead shows "last reminder".
- **Database.** The new Sales rule and the reminder permissions are enforced in the database (`guard_lead_update`, `remind_won_quotes`). Only a Lead Manager or Supervisor can remind or enter a quotation by hand.
- **Not changed.** Revenue, targets, incentives and allocation change only when an engineer saves a corrected value.

**18 Nov 2026: valid-only totals, duplicate contact check, remove a wrong quote, and "Leads I created for others".** Run `supabase/38_remove_quote.sql`, then `supabase/39_created_for_others.sql` (after 37; both are safe to run again and change no existing data), then replace `public/index.html` in GitHub (`adapter.js` is unchanged).

- **Totals count valid leads only.** On Management, "Submitted", pipeline health and Lead generators leave out Duplicate and Rejected leads. They are shown on their own line ("86 duplicate and 0 rejected not counted") and tapping it opens that list.
- **Duplicate contact check.** When a contact on the same account has the same email, phone or name, the form says so and offers **Use existing contact**, **Update the contact** or **Add anyway**. It never blocks saving. It works in New lead, Edit details, Excel import and quote import (the last two fill blank details from the existing contact and warn).
- **Remove a wrong quote.** The lead's own Sales engineer can remove a quote read from a Salesforce PDF while the lead is at Quotation sent (reason required). The lead goes back to Meeting done, the quote no longer counts in revenue, and the history and audit trail record it. Lead Manager and Supervisor can do it on any open lead; a confirmed manual quote is Lead Manager or Supervisor only.
- **Who created a lead for me.** Sales see a **Created by** chip (name and team: Sales, AMC, Support) on lists and lead details, a **Created for me** switch, and Created by / Team filters. The Excel export has the same columns.
- **Leads I created for others** (new tab for Sales, AMC and Support). Read-only list with status, summary tiles (Created, Assigned, Meetings, Quotations, Won, Lost, Value won), a date filter and Excel export. It is separate from the person's own leads. Management sees the same numbers per creator and team under Lead generators, and the totals match.
- **Database.** AMC gets the "view leads I generated" permission once (`lead.view_generated`); a new read rule lets a creator see, but never change, leads they generated. The remove-quote rule lives in `guard_lead_update`.
- **Not changed.** Revenue, targets, incentives and allocation. Created-for-others gives no incentive or revenue credit.

**17 Nov 2026 (guided stage flow): Assigned → Accept → Attended → Meeting done → Quotation sent → Won / Lost / On hold.** Run `supabase/37_stage_flow.sql` (after 36; safe to run again, no lead data is changed), then replace `public/index.html` and `public/adapter.js` in GitHub.

- **Accept.** An assigned lead shows only its details to the sales engineer until they press **Accept lead** (or **Decline** with a reason, which sends it back to the Lead Manager queue as New). Their own outbound leads skip Accept.
- **Attended.** Logging a call, email, WhatsApp or visit (the **Log update** form) moves the lead to the new **Attended** stage. The form asks for **Where it stands** (one tap) and a **Next step on** date, with quick buttons.
- **Meeting done.** Needs a **Requirement note** (at least 30 characters) and the hotel's PMS integration, shown inside the same form.
- **Every update needs a next follow-up date** until the lead is Won or Lost. **On hold** needs a reason and a "bring it back on" date. **Lost** keeps its reason list.
- **Overrides.** Lead Manager and Supervisor (`lead.status_override`) can skip a step (**Mark attended (override)** needs a reason) and it goes to the audit trail. Imported quotations are exempt.
- **Settings → Sales rules → Lead flow rules** (Supervisor): switch on/off, go-live date, minimum note length, PMS at Meeting done, the "Where it stands" labels, decline reasons and hold reasons. SQL 37 switches it on from the day it is run: leads assigned earlier keep the old way of working (the requirement note applies to every Meeting done).
- **Database.** The same rules are enforced in the database (`guard_lead_update`), plus `lead_decline()` for the Decline button. The follow-up emails, new-lead email and product lock lists now include Attended.
- **Phones.** The six stage boxes fit down to 320 px wide. The pipeline board has a new Attended column.
- **Not changed.** Revenue, targets, incentives, allocation and permissions.

**17 Nov 2026 (night): the quote reader also reads project proposals.** No SQL. Replace `public/index.html` in GitHub (`adapter.js` unchanged).

- A PDF that is a project proposal (has a "Document Number" and a "Budgetary Proposal" table, for example the Central Group e-invoicing proposal) is now read: document number as the quote number, customer, date, currency, the one-time lines and the yearly subscription line, total before VAT, VAT and total.
- The **quote value is the total before VAT**, including the yearly subscription. The yearly part is marked "/ year", shown as a note, and written in the quotation notes. Revenue, targets and incentives work as before.
- The screen says "Read as a project proposal" so the person checks the client, lines and amounts. Salesforce quotes are read exactly as before. The PDF is still not stored.

**17 Nov 2026 (evening): standard PMS per hotel chain.** Run `supabase/36_chain_standard_pms.sql` (after 35; safe to run again, no data is changed), then replace `public/index.html` in GitHub (`adapter.js` is unchanged).

- **Set it.** Supervisor: Settings → Hotel chains → **Standard PMS per chain**. Type the PMS for each chain (more than one allowed, separated by commas; names must be in the PMS list).
- **New leads.** The Hotel PMS is filled in when the hotel belongs to a chain with one standard PMS (by the New lead form, and by Excel import when the PMS column is empty). With two or more, Sales can only pick from that list.
- **Existing leads and accounts.** In the same panel, **Check leads with no PMS** shows how many can be filled; **Fill them in** sets it (only where the PMS is empty, and not where a product is not supported on that PMS). Written to each lead's history and the audit trail.
- **Changing one hotel.** Only a Lead Manager or Supervisor can change the PMS of a hotel that carries the chain standard (the change is logged). Sales see "Chain standard PMS" and no Edit button. The database enforces this too.
- **Not changed.** Revenue, targets, incentives and the product/PMS compatibility rules.

**17 Nov 2026 (later): upload leads from Excel.** No new SQL file. Replace `public/index.html` in GitHub (`adapter.js` is unchanged).

- **Who.** Lead Manager and Supervisor see **Leads → Import leads** (new permission "Import new leads from an Excel sheet", `lead.import`; the Supervisor can switch it on for others who can already create leads). Sales, Management and AMC cannot, and the database refuses them too.
- **Steps.** Download the template (sheets: Leads, How to fill in, Lists), fill it in, upload it (up to 500 rows, .xlsx or .csv). Each row is checked with the same rules as the New lead form and shown as Ready, Check or Fix.
- **Duplicate accounts.** An exact or alias match uses the existing account. A similar name asks "the existing account / a new account". The same hotel and product twice in the file, or already open in the system, is blocked; same-email-other-account and earlier-year history are warnings you can accept with "Import anyway".
- **Result.** Imported leads land as **New**, unassigned, in Back office for the usual verification and assignment. A "not imported" Excel lists each row with the reason. Every import is written to the audit trail. No file is stored.
- **Note.** The template has a Lists sheet instead of drop-downs (the Excel library used cannot write drop-downs).

**17 Nov 2026: manual quote items (items that are not in Salesforce).** Run `supabase/35_manual_quote_items.sql` (after 34; safe to run again), then replace `public/index.html` in GitHub (`adapter.js` is unchanged).

- **Add item not in Salesforce.** On "Quotation sent" and "Upload revised quote", under the Salesforce PDF, Sales can add items with a description, product, quantity, unit price and discount. The total before tax is the Salesforce total plus these items, calculated automatically and shown in words. A revised quote starts from the earlier manual items.
- **Whole quote outside Salesforce.** The same form works with no PDF. The currency can then be chosen and a quote number (MQ-year-lead-n) is suggested.
- **Confirmation.** Manual items are marked "waiting for confirmation". A Lead Manager or Supervisor confirms them with one click, in Back office ("Manual quote items to confirm") or on the lead. The order cannot be marked Won until they are confirmed (enforced in the database too). A revised quote with the same manual items stays confirmed; changing an item asks for confirmation again.
- **Price book.** Each manual item is also saved as a quote line and goes through the normal price-item review. Sales never see the price book.
- **Reports.** Management → Pipeline health lists quotes with manual items and how many still wait. Revenue, targets and incentives are unchanged.

**14 Nov 2026 (evening): AMC contract corrections, project sign-off date, cloud hosting, account rename.** Run `supabase/34_amc_lines_signoff_cloud.sql` (after 33; safe to run again), then replace `public/index.html` **and** `public/adapter.js` in GitHub.

- **Edit contract lines.** On an uploaded AMC contract, the AMC team and the approver can click "Edit lines" to correct wording and amounts, add a missing line or remove a wrong one. Every change by hand is listed for the approver, and a warning shows if the lines no longer add up to the contract total. On a phone each line is shown as a card.
- **Pick the line item by name.** The AMC team chooses the right line item from the product line items (names only, no prices), or marks it "new line item". The Supervisor sets or adds the price item at approval, as before.
- **Picture of the commercial page.** At upload a small picture of the page(s) with the price table is kept (up to 3) so the approver can open "View commercial page". It is deleted automatically when the contract is approved, rejected or taken back. The PDF itself is still never stored.
- **Project sign-off date.** AMC team, Supervisor and Lead Manager can enter the sign-off date on each won order. The AMC start now counts from that date. Orders without one keep using the order date and are flagged in Renewals.
- **Cloud hosting.** A separate yearly charge: not AMC, no Sales share, outside the renewal totals. New view "Cloud hosting" under Renewals and Management lists the hotels by region and country, with Excel export. "Cloud Hosting" is also added as a product. It is read from AMC contract lines.
- **Account rename.** Supervisor and Lead Manager can rename an account (the name changes on its leads and contracts; the old name stays searchable). A sales person with a lead on the account can ask; the request waits in Back office for Supervisor or Lead Manager to approve or reject.

**14 Nov 2026 (afternoon): joint meetings with an agreed share, and events.** Run `supabase/33_joint_events.sql` (after 32; safe to run again), then replace `public/index.html` **and** `public/adapter.js` in GitHub.

- **Joined by.** When logging a meeting, the sales person can add colleagues who took part ("Joined by"). The colleague gets the meeting on their activity record: the Meetings page has a "Joined (helping)" column and each meeting shows who joined. The lead, its revenue, target and incentive stay with the lead's own engineer.
- **The colleague can read that lead** (not change it). Sales see these under Meetings → "Leads I joined".
- **Optional agreed share.** On a lead where a colleague joined, the lead's engineer can offer that colleague a share of the order (1 to 90%). Nothing is divided until the colleague clicks **Agree** (or Decline). Once agreed, the order's revenue credit is divided: with 30%, the colleague's results show 30% of the order and the engineer's show 70%. Company totals do not change. Management → Engineers, monthly forecast and Targets all use the same split.
- **Locked at Won.** After the order is won, only a Lead Manager or Supervisor can change the share, with a reason, and it is listed under Management → "Changes after Won".
- **Events.** Leads → **Events**: a Supervisor or Lead Manager registers an event (name, place, dates, who attended). On the new-lead form, "Event" can then be picked:
  - A sales engineer sees only events they attended and is always the named person on the leads they enter.
  - Back office picks one of the attendees as the person who got the lead.
  - That person becomes the lead generator. Allocation is unchanged: the lead still goes to the engineer who owns the country, and the revenue is theirs.
  - The Events page reports, per event: leads, countries, quotations, orders won, revenue, open pipeline, and how many leads each attendee brought. Everyone who can see leads can read it.
- **Generator incentive on event leads.** The existing "Lead generator incentive %" (Products & settings → Sales rules → Rates and targets) pays the named person on the first order. A new tick box under it, "Pay the lead generator incentive on leads from events", switches this on or off (on by default).
- New permission "Register events" (Supervisor and Lead Manager by default) in Roles and permissions.
- Database: the colleague's read access, the "only the colleague can agree" rule, the lock at Won and event registration are all enforced there too.
- Tests: 67 new checks (34 joint work, 33 events) as Supervisor, Lead Manager, Management, two Sales users and AMC; screens checked at 320, 390, 768, 1024 and 1440 px wide; database rules tested per role on a local Postgres copy; all earlier tests re-run.

**14 Nov 2026: the Salesforce quotation is required, the order value comes from the quotation, and a won order's value changes only with a revised quote.** Run `supabase/32_order_from_quote.sql` (after 31; safe to run again), then replace `public/index.html` in GitHub. `adapter.js` is unchanged. This zip also contains everything from 13 Nov below, so if you have not installed those yet, run 30, 31 and 32 in order.

- **Quotation sent needs the Salesforce quote.** When Sales marks a lead "Quotation sent" (or revises a quotation), they must upload the quotation PDF from Salesforce. The app reads the amount, the product line items and the charges (freight, discount, VAT) and saves them with the lead. The amount box cannot be typed by Sales. As before, the PDF itself is read on the device only and is not stored.
- **The amount is the total before tax**: after discount, including freight or delivery charges, without VAT. The VAT and the final total are kept with the quotation for reference.
- **If the PDF cannot be read** (scanned copy, not a Salesforce quote), Sales cannot continue. A Lead Manager or Supervisor can type the amount with a reason; the reason is saved on the quotation.
- **Order won takes its value from the quotation.** The form no longer asks for an amount: it shows the value of the latest quotation and asks only for the PO number, order date and notes. If the client ordered a different amount, revise the quotation first by uploading the new quote. A lead with no quotation is asked for the quotation first.
- **Changing a won order's value: "Upload revised quote".** This replaces "Correct order value" from 13 Nov. The value can no longer be typed: the new quote is uploaded and a reason is always required. The lead stays Won and keeps its order date; the old value and old quotation stay in the lead's history; Management sees it under "Changes after Won" with the quote number and reason. Sales can do this on their own leads for 30 days after Won; Lead Manager and Supervisor at any time (and by hand with a reason if the PDF cannot be read).
- **Moving a won lead back a stage** is unchanged: Sales can still do it within 30 days without a reason.
- **OHIP amount** comes from the uploaded quotation's lines; the hand-typed "Of which OHIP" box from 13 Nov is removed.
- **Price book builder**: for Sales it is now a calculator only (the quotation still has to be uploaded). For Lead Manager and Supervisor it fills the amount and the reason "Built from the price book".
- **Older leads** are left as they are. The rule applies from the next quotation, revision or order.
- **Database**: without Lead Manager or Supervisor rights, an order can only be saved when its value equals the value of the lead's quotation.
- Tests: 29 new checks with two real Salesforce quotations (one with 0% VAT, one with freight and a discount), as Supervisor, Lead Manager, Management, Sales and AMC, desktop and phone; the database rule tested per role on a local Postgres copy; all earlier tests re-run.

**13 Nov 2026 (late): OHIP shown separately inside revenue.** No SQL. Replace `public/index.html` in GitHub (this file also contains the evening changes below, which need `31_won_own.sql`).

- OHIP is billed yearly and is part of the order value, revenue and targets, as before. Nothing in those figures changes. What is new is that Management sees how much of the revenue is OHIP: "of which OHIP AED …" under the Revenue tile on Management → Overview, next to each engineer's revenue (and the team total), next to each region's revenue, and on the account rows in Accounts.
- The OHIP amount of a won order comes from its quotation lines (lines matched to a per-room or OHIP price item). The lead shows it as "Of which OHIP" under the order.
- An order that has only a total and no quotation lines shows no OHIP split. (The box for typing the OHIP amount was removed on 14 Nov; upload the quotation instead.)
- Year 2 onward is unchanged: OHIP stays its own line in Renewals and in the OHIP charges view of AMC contracts, outside the AMC and subscription totals.
- Tests: 18 new checks (the OHIP total is the same by engineer, region and account; revenue is unchanged); all earlier tests re-run.

**13 Nov 2026 (evening): lead view as a popup, Sales can change their own won leads for 30 days, names A to Z.** Run `supabase/31_won_own.sql` (after 30; safe to run again), then replace `public/index.html` in GitHub. `adapter.js` is unchanged.

- **Lead view is now a large popup.** On a computer the lead opens in the centre of the screen in two columns: the lead on the left (details, PMS, products and pricing), what to do next and the history on the right (update stage, follow-up, activity, delete). The lead number, status, hotel name, stage steps and Close button stay in view while scrolling. It closes only with the Close button: clicking outside and the Esc key no longer close it, so typed notes are not lost by accident. On a phone it stays full screen in one column. No field, button or permission has changed.
- **Sales can change their own won leads for 30 days.** New permission "Change their own won leads for a limited number of days" (Sales by default; switch it per role in Roles and permissions). For 30 days after a lead was marked Won, its own sales engineer can:
  - **Correct order value** (replaced on 14 Nov by "Upload revised quote", which needs the new quote and a reason; see above): the lead stays Won and keeps its order date; the old value is kept in the lead's history.
  - **Move back a stage** to Quotation Sent, Meeting Done or Assigned, without a reason. The order is kept in the lead's history and stops counting as revenue until the lead is won again.
  - After 30 days, and for On Hold or Lost, it stays with Lead Manager and Supervisor as before (they still give a reason; they can now also correct an order value directly).
  - The number of days is set in Products & settings → Sales rules → Activity rules and forecast ("Sales can change their own won lead for (days)"); 0 switches it off.
  - The database enforces all of it, and now also refuses any other change to the order of a won lead.
- **Management sees every such change.** A lead that was changed shows a "Changed after Won" mark and its order corrections. Management → Revenue per account has a new list, "Changes after Won" (last 12 months): date, lead, engineer, what changed, value before and after, who, and the reason if one was given. Revenue, targets and incentives use the new figures straight away. Everything is also in the audit trail.
- **People's names A to Z.** Sales engineers and lead generators are listed alphabetically wherever they can be picked (assign, reassign, filters, territories, chain owners, targets, settings), whatever order they were added in.
- Tests: 39 new checks as Supervisor, Lead Manager, Management, Sales and AMC, desktop and phone; the database rule tested per role on a local Postgres copy (inside and outside the 30 days, permission switched off, days changed); all earlier tests re-run.

**13 Nov 2026: settings in sections, Tap & Smile PMS rule (blocked on other PMS), lead list status filter, and price items on AMC contract approval.** Run `supabase/30_pms_strict.sql` (after 29; safe to run again), then replace `public/index.html` in GitHub. `adapter.js` is unchanged.

- **Products & settings in sections.** The 17 blocks are grouped into six sections with a menu on the left (a swipe row on a phone): People & access, Territories & accounts, Products & PMS, Sales rules, AMC & contracts, Backup. "Find a setting" jumps to a block by name; "Jump to" links sit at the top of each section; the last section used is remembered on the device. Nothing about the settings themselves or how they save has changed.
- **Tap & Smile PMS rule.** OPERA 5 / V5 through OWS or OPP_KSK, OPERA Cloud through OHIP, any other PMS not supported. The SQL file adds the rule only if Tap & Smile has no rule yet.
- **"Block if not supported"** is a new tick per product in PMS integrations (ticked for Tap & Smile by the SQL file). For a ticked product a lead cannot be saved when the hotel's PMS is marked "—": on the new-lead form, when products or the PMS are changed on a lead, on the quotation and order forms, and in the quotation import. The database refuses it as well. "Not known yet" never blocks, so a lead can still be logged before the PMS is known; the block then applies when the PMS is entered. Existing leads are untouched until someone changes their products or PMS. Products without the tick keep the warning only.
- **Lead list status filter** now lists the same statuses a lead shows: New, Info Needed, Assigned, Meeting Done, Quotation Sent, On Hold, Won, Lost, Duplicate, Rejected, plus All and "Open (all)" (which matches the Open tile).
- **Price items on AMC contract approval** (the same review a quotation gets). In Renewals → To approve, each contract line now has a "price item" choice under its product: pick the matching item from the Lead Desk price book, "Not a product", or "+ New price item from this line…", which adds a draft entry to the price book (name, product, type and the contract's unit price in AED, marked "from AMC contract …") for the Supervisor to check later. A contract cannot be approved until every line has one. The choice is remembered with the reading rule, so the same wording arrives already allocated on later uploads. Only people who may approve contracts and can open the price book see the choice (AMC uploaders do not see prices); everyone else sees the chosen item's name on the line. Draft entries do not change standard prices until approved in the price book, and nothing here changes pipeline, revenue, targets or incentives.
- **Approving AMC contracts** stays as it was: Supervisor only by default, and the Supervisor can give it to another role in Roles and permissions.
- Tests: 40 new checks (sections, PMS block, status filter) and 23 for the price item review, each as Supervisor, Lead Manager, Management, Sales and AMC, desktop and phone; the database check tested on a local Postgres copy; all earlier tests re-run.

**12 Nov 2026: who prepared each contract (Customer Success), and choose-then-process upload.** No SQL. Replace `public/index.html` in GitHub.
- **Prepared by (Customer Success).** The name on the contract is read from the cover page ("AMC Sender"), with the email, phone and designation; without a cover page, from the "For Samsotech" signature block. The contract belongs to that person. The name is required before sending for approval and can be corrected by the uploader or the Supervisor. "Uploaded by" stays a separate record.
- **Contracts list**: new "Prepared by" column and filter; the Excel export has the preparer's name and email.
- **Contracts by Customer Success person** (top of Renewals → Contracts, and Management → Customer Success): contracts approved, clients, yearly value, in force, expiring soon, expired and not renewed, and the last approval date, for all time, this year or this month. The AMC team and Supervisor also see waiting and rejected counts. Click a person to see only their contracts. Excel export.
- **Upload**: choose or drop up to 10 PDFs, check the list, remove any, then click **Process**. More than 10 are left out with a message. Progress shows "Reading 3 of 10…". The same contract twice in one batch is caught.

**12 Nov 2026: contract clients on Accounts, the product matrix and the customer footprint.** No SQL. Replace `public/index.html` in GitHub.
- **Accounts → Overview**: a new section "Clients added from AMC contracts" lists existing clients that have no lead in Lead Desk, with engineer, PMS, solutions in use, contract and yearly value. They are not counted in the leads, orders or revenue figures above it.
- **Accounts → Product matrix**: these clients appear as hotels (status Client) under their region and country. Each solution on the contract is marked "In use · on an AMC contract" (outlined green). A client that also has leads keeps its purchased marks and gains the contract's solutions. Clicking a contract mark opens the contract. Product totals and the "Purchased" filter include them.
- **Management → Customer footprint**: contract clients count as clients, with their solutions, labelled "AMC contract". Won revenue is unchanged.
- Only approved contracts are used. Sales see their own clients.

**12 Nov 2026: OHIP check on every contract, and OHIP not charged.** Run `supabase/29_ohip_rules.sql` (after 28; safe to run again), then replace `public/index.html` in GitHub.
- **Hotel PMS is required on every contract.** The AMC person chooses it before sending for approval ("Send for approval" stays off until every contract has one). It is suggested when the contract has an OHIP line, or from the client's PMS in Lead Desk. The number of rooms can be entered beside it.
- **OHIP check.** When the PMS is OPERA Cloud, each solution on the contract needs its own yearly OHIP line:
  - eREG Plus (subscription) → Annual OHIP charges (eREG Plus)
  - eREG → Annual OHIP charges (eREG)
  - Passport / ID scanning PMS interface → Annual OHIP charges (ID scanning)
  - VICAS (UAE, Dubai, Italy and so on) → Annual OHIP charges (VICAS)
  - "Samsotech Diamond interface", Dubai only → Annual OHIP charges (VICAS-Diamond)
  - easyKiosk → Annual OHIP charges (easyKiosk); Mirror → Annual OHIP charges (Mirror)
  The check is shown on upload, on approval and on the contract in the register. A missing line never blocks approval, and the app never adds a charge by itself.
- **What is not charged.** Each missing line gets a yearly estimate: rooms × the solution's price per room, at least its minimum price. Renewals → OHIP charges (and Management → OHIP charges) shows the total not charged, by solution, by region and country, and client by client, with Excel export.
- **Interface name.** When the OHIP line for ID scanning is on the contract, "VICAS Opera PMS Interface" is shown as "VICAS PMS interface (Opera Cloud-OHIP)"; the contract's own wording stays underneath.
- **PMS sanity check.** eREG Plus (subscription) is sold with OPERA Cloud, DayLight PMS or HotelKey PMS; eREG Plus (On-premise) with OPERA V5. Another choice shows a warning, not a block.
- **Products & settings → OHIP rules** (Supervisor): which PMS the check applies to, the solutions, their price per room and minimum, and "Add solution". **Prices start empty**: until they are entered a missing line shows "price not set".
- DayLight PMS and HotelKey PMS are added to the PMS list. The view also counts clients on a PMS being retired (OPERA V5).
- A contract without a PMS is not checked; the OHIP view counts such contracts.

**12 Nov 2026: line categories, learning from approvals, and OHIP charges.** No SQL. Replace `public/index.html` in GitHub.
- **Category on every contract line**: Hardware, Software licence, PMS interface · one-time, PMS interface · subscription (switched off for now), OHIP, Cloud / hosting, Services. A category can fix how the line is treated: PMS interface · one-time → AMC, Cloud / hosting → Subscription, OHIP → OHIP. The Type can still be changed for a single line.
- **The system learns from the Supervisor.** On approval, each line's wording is remembered with its product, category and type. The next contract with the same wording is filled in by itself and marked "Learned"; contracts still waiting pick the rule up straight away. Lines the system only guessed say "Best guess, please check"; unknown wording says "Not recognised". Untick "Remember…" on a contract to approve it without teaching.
- **Products & settings (Supervisor)**: "Contract line categories" (add, rename, switch on or off, set how a category is treated) and "Contract reading rules" (every learned wording, how often it has been used, Edit and Remove). Changing a rule affects future uploads only; approved contracts stay as approved. A Supervisor can also correct the lines of an approved contract from Contracts.
- **OHIP charges** (Renewals → OHIP charges, and Management → OHIP charges): yearly OHIP by region and by country, hotels in each, the accounts behind every figure, Excel export. From OHIP lines on approved contracts, or on won orders where the client has no contract. OHIP stays out of AMC, the Sales share and the renewal totals. The figure is what the client is charged; what is paid to the vendor is not held in Lead Desk.
- **Client record** now groups solutions and prices by category.
- A guessed category never changes a line's type; only a learned rule or a person does.

**12 Nov 2026: client record, solutions used and prices by contract year.** No SQL. Replace `public/index.html` in GitHub.
- **Click a hotel** in Renewals → Installed base (or open a contract in Contracts) to see its record.
- **Solutions used**: every product the client has, with units and the year it first appears, from its won orders and approved contracts.
- **Prices given to the client, by contract year**: one column per approved contract. Each item shows the product's price and quantity, what the client pays for that year, the AMC rate, and the change against the contract before (▲ / ▼). Yearly totals in the contract's currency and in AED, split into AMC, subscription and OHIP.
- Earlier years appear when the client's earlier contracts are uploaded and approved; each contract is kept, the newest one drives renewals.
- **Export price history** (Contracts): one Excel row per client, contract year and item, with order ref, product, quantity, unit price, yearly charge, rate, currency and serial numbers.
- Same access as contracts: Sales see their own clients only.

**12 Nov 2026: AMC contracts of existing clients (bulk upload, approval, installed base).** Run `supabase/28_contracts.sql` (after 27; safe to run again), then replace `public/index.html` and `public/adapter.js` in GitHub.
- **Renewals now has five views**: Renewals, Contracts, Installed base, Upload contracts (AMC and Supervisor), To approve (Supervisor approves; AMC sees what is waiting).
- **Upload contracts**: choose many AMC contract PDFs at once. Each is read on the device (the PDF is not stored): contract number, client and address, country, period, currency, every covered line (order ref, item, quantity, unit price, yearly charge, months), scanner serial numbers, the client's signatory, signed date, payment terms and the price revision clause. A file that is not a contract, or a scanned copy, is listed as "could not read" and the rest carry on.
- **Existing or new client**: each contract is checked against the clients already in Lead Desk and marked Existing client, Possible match or New client. The uploader or the Supervisor can pick the right client from a list.
- **Sales engineer**: an existing client keeps its engineer (the territory owner is shown if different). A new client gets the owner of its country or region from Territories. It can be changed before approval.
- **Approval**: uploaded contracts wait as pending and are visible only to the AMC team and the Supervisor. The Supervisor checks the match, the engineer and each line's type (AMC, Subscription, OHIP) and product, then approves or rejects with a reason. "Approve the N without warnings" approves the clean ones in one go.
- **These are not leads.** A contract never creates or changes a lead, and pipeline, won revenue, targets and incentives are unchanged.
- **Renewals** uses the contract's own figures for a client that has an approved contract (instead of the estimate from its order), due the day after the contract ends. AMC goes to the AMC department, the Sales share applies to subscriptions, OHIP stays separate. The client's sales engineer and the AMC team update the same status and notes.
- **Contracts** (register): in force, expiring soon, expired, renewed by a newer contract; the actual AMC rate is flagged when it differs from the standard (for example 22% against 18%). Excel export.
- **Installed base** (also under Management): how many hotels use each product, from won orders and approved contracts together, by product, region and country, and which hotels have no AMC contract in force. Excel export.
- **Who sees what**: AMC and Supervisor upload; Supervisor approves; Management, Lead Manager and AMC see every approved contract; Sales see the contracts of their own clients. All switchable in Roles & permissions, and enforced in the database.
- A new client added from a contract is found by the duplicate check when a lead is entered for it later.
- The same contract number cannot be uploaded twice. A newer contract for the same client marks the older one as renewed.
- Tested on two real contracts (a signed hotel contract and an unsigned university contract). Other templates may need adjusting.

**10 Nov 2026: fix 2, AMC users still saw no orders.** Run `supabase/27_lead_read_rules.sql` (safe to run again). No files to replace.
- Cause: the rule for who can read a lead was one database policy that older SQL files (09, 11, 12, 23) re-create. Running one of them after `24` put back a version without the AMC part, so the AMC role had its permissions but received no orders.
- Now the AMC rule and the "Generated by me" rule are separate policies. Re-running an older file can no longer remove them. `23` and `24` in this zip do the same.
- The last step of `27` lists the read rules; three rows are expected: `leads_select`, `leads_select_generated`, `leads_select_won`.

**10 Nov 2026: fix, AMC users saw an empty Renewals page.** Run `supabase/26_amc_access_fix.sql` (safe to run again), then replace `public/adapter.js` and `public/index.html` in GitHub.
- Cause: the app showed the Renewals page to the AMC role, but the database had no permissions saved for that role, so it returned no orders. `24_amc_renewals.sql` only added them when the permission table had never seen "Renewals"; it now always does, and `26` repairs installs where it didn't.
- The last step of `26` shows the AMC role's permissions; it must list `lead.view_won`.
- Devices now take a fresh copy when a user gains access to rows the device never received, so AMC users don't need to clear anything.
- Browsers could keep using an old `adapter.js`: the page now asks for it by version, so a new one is always picked up. Every device takes one fresh copy of the leads after this update.
- When Renewals is empty it now says why: no orders reached the sign-in (a database permission), no AMC rates set, or no orders with something to renew.
- The name at the top right stays at the right for roles with a single page (AMC).

**10 Nov 2026: design review (navigation and finish).** No SQL. Replace `public/index.html` in GitHub.
- **Top menu never cuts off.** Pages that don't fit on one row move under **More** (with their counts added up on the button). The page you are on always stays in the row. Same on phone, so no more sideways swiping to find a page.
- **Management sub-tabs** keep the chosen one in view and fade at the edge when there are more to scroll to.
- **Phone**: filter bars fold into a "Filters" row so the figures come first; bigger buttons and inputs (no zoom-in when typing on iPhone); KPI cards two per row; long rows in Back office and Products & settings wrap instead of running off the screen.
- **Finish**: hover, pressed and focus states on buttons, inputs, tabs and table rows; softer card edges; disabled fields look disabled; readable count badges in dark mode; the Inbound/Outbound switch on the lead form no longer stretches across the form.
- Nothing changed in data, permissions, figures or page layouts.

**10 Nov 2026: AMC, subscriptions and renewals.** Run `supabase/24_amc_renewals.sql` (after 23; safe to run again), then replace `public/index.html` and `public/adapter.js` in GitHub. Optional, only if you use the automatic emails: run `supabase/25_renewal_emails.sql` and redeploy the `lead-mailer` function from `supabase/functions/lead-mailer/index.ts`.
- **New role: AMC.** In Users, give the AMC team's sign-ins the role AMC. They see one page, Renewals, with won orders only. They cannot edit leads, and see no pipeline, price book or management pages.
- **Renewals page** (AMC, Management, Lead Manager, Supervisor; Sales for their own orders): expected 2nd- and 3rd-year revenue of every won order, AMC and annual subscription shown separately, what is due by month, and the list of renewals due with status (Not started, Contacted, Quoted, Renewed, Lost), notes and a corrected amount. Excel export.
- **How the amounts are worked out**
  - AMC = a % a year of hardware + software licences + the one-time PMS interface. Standard 18% on Passport / ID Scanner. Rates can be added per region and per hotel chain: chain beats region beats standard. Products without a rate have no AMC.
  - AMC starts 12 months after the order (changeable). AMC goes 100% to the AMC department.
  - Annual subscriptions: the Sales share % is set by the Supervisor (Products & settings → AMC and renewals) and applies every year from the 2nd year; the rest goes to the AMC department. It starts empty, so the Sales share shows as "not set" until entered.
  - Annual OHIP charges are shown on their own line. They are not AMC, carry no Sales share and are kept out of the totals, because they are paid on to the PMS vendor.
  - Orders with approved quotation lines use the lines. Older orders without lines are estimated from the order value and marked "estimated"; the AMC team can correct the amount.
- **On each won order**: a "Recurring revenue" table with Year 1, 2 and 3.
- **Alerts**: a count on the Renewals tab and a notice on Focus for renewals due within 90 days. The sales engineer of the order and the AMC team both update the same status and notes. With the optional emails, both get one email a day listing orders that have just come within 90, 60 or 30 days.
- A price-free list of price book items is now kept beside the line rules, so AMC and Sales can class quotation lines without seeing prices.

**10 Nov 2026: "Generated by me" for sales engineers.** Run `supabase/23_generated_view.sql` (after 22; safe to run again), then replace `public/index.html` and `public/adapter.js` in GitHub.
- Sales engineers get a **Generated by me** tab: the same dashboard as Marketing's My leads, for leads they generated themselves, whoever works on them now. Leads with another engineer open read-only and stay out of their pipeline, Focus and counts. Company averages and incentive are not shown to sales.
- New permission "See leads I generated" (on for Sales, switchable in Roles & permissions), enforced in the database: read only, never edit.
- Management → Lead generators: choose department **Sales** to see each engineer's own leads; click a name for their dashboard. Management → Targets: a monthly lead target can be set per engineer too.
- Every device reloads a fresh full copy once after this update.

**9 Nov 2026 (night): lead generator dashboard.** Replace `public/index.html` in GitHub (no SQL).
- My leads now shows: this month's lead target with a progress bar, leads by month for the last 6 months (coloured by where they are today), how far the leads get (meeting, quotation, won) against the company average, and what moved in the last 7 days. The lead list shows 25 at a time.
- Management → Lead generators: clicking a name opens the same dashboard for that person.
- Management → Targets: new "Lead generators · leads per month" table, set with Edit targets (Management and Supervisor).

**9 Nov 2026 (later evening): who generated a lead.** Replace `public/index.html` in GitHub (no SQL).
- For people in the Lead generators list (Pratibha, Nazreen), the lead form asks "Whose lead is this?": **My own lead** (Generated by = their name, department Marketing, counted for them by their sign-in) or **Entered for someone else** (type the name). It no longer pre-fills the last name typed on that computer, which is how a lead could be credited to the wrong person.
- Wrongly credited leads: open the lead → Edit details → Generated by.

**9 Nov 2026 (evening): Lead generators and "My leads".** Run `supabase/22_generators.sql` (after 21; safe to run again), then replace `public/index.html` in GitHub.
- Management → **Lead generators** (Management, Supervisor): leads per person who generated them, by department (Marketing by default): waiting approval, assigned, meeting, quoted, won, lost/duplicate, conversion, revenue and incentive. Click a name for a monthly trend and each lead. Excel export. Follows the period, region and lead-source filters.
- **My leads** tab for anyone linked to a lead generator: their own leads with status, engineer and amount, won revenue and incentive this year, conversion against the company, and + New lead.
- Products & settings → **Lead generators** (Supervisor): name, department, other spellings, linked sign-in. Starts with Pratibha and Nazreen (Marketing). Leads are matched by "Generated by", so past leads count without being changed. New leads by a listed person get their department automatically.

**9 Nov 2026 (fix): newest leads disappearing.** Replace `public/adapter.js` in GitHub (no SQL).
- Once there were more than 1,000 leads, each device dropped the newest ones from its copy every 30 minutes (Supabase returns at most 1,000 rows per request, and the check for deleted leads stopped there). New leads appeared, then vanished.
- Fixed: all lists are now read page by page until the end. Every device starts with a fresh full copy once after the update.

**9 Nov 2026 (price book): Price book and quote-line learning.** Run `supabase/21_pricing.sql` (after 20; safe to run again), then replace `public/index.html` and `public/adapter.js` in GitHub.
- Management → **Price book**: items for each product (Software, Hardware, Interface, Service) with a pricing unit (per front-desk PC, per user, per property, per unit, one-time per property, per room with a yearly minimum and optional room bands), Onsite and Remote prices, valid-from date. Starts with Passport / ID scanning (3 licence options and the 8 scanner models), eREG (standalone, with PMS), OPERA V5 OPP_KSK / OWS (one-time per property), OPERA Cloud OHIP (yearly, per product, from rooms), installation, and the 9 SamsoSuite subscriptions, all without prices.
- Prices are drafts until Management or a Supervisor approves them; old prices are kept and sent quotes aren't recalculated. **Download / Upload price sheet** (Excel or CSV) shows new, changed, unchanged and error rows before saving them as drafts.
- **Quote lines to approve**: each line read from a quotation PDF or email is matched to a price item (or marked as a discount / not a product). With "Remember", the wording becomes a rule and the next quote with the same wording is matched automatically. A Supervisor can turn a line into a new draft price item.
- Lead → **Products and pricing**: quantities (front-desk PCs, users, rooms, Onsite/Remote), the quote's lines split into one-time and yearly, with standard price and discount for those who can see prices. **Build quote from price book** fills the quotation amount (one scanner per PC by default, PMS interface from the hotel's PMS, OHIP minimum applied).
- Management → Products: a lead with several products is now split by its approved quote lines (equally when there are none), so product amounts add up to company revenue.
- Permissions (Users → Roles & permissions, can be switched off): see prices = Management and Lead Manager; approve = Management; edit and upload = Supervisor. Sales see their quoted lines but not the price book. Enforced in the database.

**9 Nov 2026 (theme): Light / Dark / Device switch.** Replace `public/index.html` in GitHub (no SQL).
- Account menu (your initial or name, top right) → Theme: Light, Dark or Device (follows the phone's or computer's setting; the default).
- The choice is remembered on each device, for every role, on desktop and phone.

**9 Nov 2026 (later): PMS integrations.** Run `supabase/20_pms.sql` (after 19; safe to run again), then replace `public/index.html` in GitHub.
- Adds the 9 SamsoSuite products (Passport / ID Scanning, eREG, eREG Plus, F&B, Mailer, Samso Sign, Online Check-in, Kiosk on Payment Device, House Keeping) as separate products. Existing products stay as the on-premise versions; old "SamsoSuite Solutions" leads are unchanged.
- Products & settings → **PMS integrations** (Supervisor): which PMS each product works with and the interface. Loaded: SamsoSuite products = OPERA Cloud via OHIP only; eREG = OPERA Cloud via OHIP, OPERA V5 Standalone / OPP_KSK / OWS, any other PMS Standalone. Other products are "not set" until the Supervisor fills them in. Tick "Not PMS-related" for products that aren't hotel solutions.
- Each lead records the hotel's PMS (one per hotel; suggested from the hotel's other leads, and can be applied to them) and the interface per product. Required on new leads, and from Quotation Sent and Won onwards (also in Import quotations). A warning shows if a product isn't listed for the hotel's PMS.
- Back office → Data issues: **Won leads without a PMS**, to fill in past orders.
- Management → Products: **By PMS and interface** (leads, won, win rate, revenue, average order, open) and won orders by product × PMS, with the share of leads that have a PMS recorded.

**9 Nov 2026: Import quotations from saved emails.** Replace `public/index.html` in GitHub (no SQL).
- Focus → **Import quotations**: drop saved Outlook emails (.msg), .eml files or quote PDFs, several at once. They're read on the device and never uploaded or stored.
- Each quote is matched: quote number already in Lead Desk → skipped; open lead for the same client → quotation added and the lead moves to Quotation Sent; no open lead → a new outbound lead waiting for Lead Manager approval, with the quote on it. Approving such a lead takes it straight to Quotation Sent.
- The email is logged as a contact on its sent date, and a follow-up is set. Target date is required ("Apply to all" sets it for every row).
- Engineers import their own quotes; Lead Managers and Supervisors import for anyone and choose the engineer for new leads. Management doesn't see the button.

**8 Nov 2026 (night): read a Salesforce quotation PDF.** Replace `public/index.html` in GitHub (no SQL).
In the quotation form (Quotation sent / Revise quotation) click **Read from Salesforce PDF** and pick the quote. Lead Desk reads the quote number, date and validity, client, contact and designation, every product line (unit price, qty, total, list price), freight, discount, VAT and net total, currency, payment terms and who prepared it; fills the form and shows the lines with the matching Lead Desk product (changeable). Check, add the target date and next step, and save. The PDF is read in the browser only (pdf.js, loaded on demand) and is never uploaded or stored; only the confirmed figures and lines are saved on the quotation.

**8 Nov 2026 (later): Sales targets.** Run `supabase/19_targets.sql` (after 18; safe to run again), then replace `public/index.html` in GitHub.
Management → **Targets** (Management and Supervisor; permission "Set sales targets"): pick a year, click *Edit targets*, enter the company's yearly target (*Split evenly across months* fills the 12 months, or type each month), and each sales engineer's yearly target, then *Save targets*. The page shows booked vs target for the year, year to date, what's still to book and the monthly rate needed, per engineer and per month. Each engineer sees their own target progress at the top of their Focus tab.

**8 Nov 2026: Focus tab (activity rules, forecast, cross-sell, chains, references).** Run `supabase/18_focus.sql` (safe to run again), then replace `public/index.html` in GitHub.
- **Activity rules** (Products & settings → Activity rules and forecast): first contact within 2 working days, first meeting within 14 days, a next step on every open lead, no lead quiet for more than 14 days. Applies to leads assigned from 1 Nov 2026 (changeable). Broken rules show as red chips on pipeline cards, a "Needs action" box in the lead, and in the Focus tab (engineers: their list; managers: a table per engineer plus the count of older inactive leads).
- **Log contact** (call, email, WhatsApp, visit) on every open lead. Meeting done, Log a meeting, Quotation sent and Log contact now ask for the next step (date and what), so no lead is left without one.
- **Forecast**: engineers mark deals Commit / Best case / Pipeline / Omit for a month in Focus → Forecast call (or in the lead). Management → Pipeline health shows Commit, Best case, weighted pipeline (stage probabilities in settings) and forecast accuracy per engineer (commit as of the 5th vs what closed).
- **Grow clients**: Focus → Cross-sell targets (client hotels and products they don't have yet; one click creates an outbound lead for approval), Hotel chains to win (chain owners are set in Products & settings → Hotel chains), and Reference sites (Lead Managers and Supervisors add them; the lead suggests references with the same product in the same country or region).

**8 Nov 2026: Customer footprint.** Replace `public/index.html` in GitHub (no SQL).
Management → **Customer footprint** (Supervisor and Management; permission "Customer footprint by country and hotel chain"): countries with clients, clients and prospects per country (UAE and USA split by emirate / state), client accounts per country, and hotel chains with their hotels, clients and revenue. A client is an account with a Won lead, or one the 2026 sheet records as bought; each account counts once. Chains are detected from the hotel's brand name; Supervisors edit the brand list and set a hotel's chain by hand in Products & settings → **Hotel chains**. Export to Excel for roles that can export.

**7 Nov 2026 (evening): location editing moved into Edit details.** Replace `public/index.html` in GitHub (no SQL).
The lead details box no longer has *Change country* or *Edit date or region* buttons. *Edit details* now has a **Location and date** section (country, region, emirate / state, requirement date). Supervisors get the full form; Lead Managers and the lead's engineer get only the Location and date section (only Supervisors and Lead Managers can change the country of an approved lead). Choosing a country sets its region and shows the emirate / state field for UAE and USA.

**7 Nov 2026 (later): merge one product into another** (e.g. "Dropbox" into "Check-out Box"). Run `supabase/17_merge_product.sql` (after 15; safe to run again), then replace `public/index.html` **and** `public/adapter.js` in GitHub.
In Products & settings, click *Rename* on the product to remove (Dropbox), type the name of the one to keep (Check-out Box) and click *Rename*. Because that name exists, Lead Desk offers **Merge "Dropbox" into "Check-out Box"**: every lead and meeting with Dropbox gets Check-out Box (a lead that had both keeps it once), Dropbox leaves the catalog, and one "Merged" entry goes to the audit trail. The same works for two sales engineer names.

**7 Nov 2026 (later): change the status of a Won lead.** Run `supabase/16_won_status.sql` in the SQL Editor (after the earlier files; safe to run again), then replace `public/index.html` in GitHub.
Supervisors and Lead Managers see **Change status** on a Won lead: move it back to Quotation sent (if it has a quotation), Meeting done, Assigned, On hold or Lost, with a required reason (and a lost reason for Lost) and a confirmation window. The order is kept in the lead's history but stops counting as revenue, in the engineer's results and in the lead generator's incentive. The change shows on the lead ("Status changes"), in its activity and in the audit trail. The database refuses it from any other role.

**7 Nov 2026: Data issues and the Products view.** Includes every change from 6 Nov.
1. In the SQL Editor run any of these you haven't run yet, in order: `12_operations.sql`, `13_upsell.sql`, `14_names.sql`, `15_merge.sql` (each is safe to run again).
2. Replace `public/index.html` **and** `public/adapter.js` in GitHub.

- **Back office → Data issues** (Supervisor and Lead Manager only; Management stays statistics only). The "About these numbers" note on Management has a *Fix these in Back office* link for Supervisors.
  - *Won leads without an order amount*: enter the amount, currency, date and PO right in the list (or *Use quoted amount*). The status stays Won and revenue updates at once.
  - *Names not on the Sales engineer list* (e.g. "Raghu"): *Merge into* an engineer (every lead, meeting and record moves in one step, one "Merged" audit entry), *Add to the list*, or open the leads and reassign them one by one. Merging is Supervisor-only.
  - *Leads assigned to two people*: link to the Back office fix.
- **Management → Products** (permission "Product-wise leads, status and revenue", Supervisor only; can be given to Management under Roles and permissions). One row per product with leads, open, meetings, quotes, won, revenue, lost, on hold, conversion, average order, pipeline and upsell revenue; click a product for its leads with status, quotation, target date and order value. A lead with several products is shown in full under each and marked "shared"; the total row counts each lead once and matches the rest of Management. *Export to Excel* (two sheets) for roles that can export.

**6 Nov 2026 (late): display names, renaming products and engineers.** Includes every change below from 6 Nov.
1. In the SQL Editor run, in order, any of these you haven't run yet: `12_operations.sql`, `13_upsell.sql`, `14_names.sql` (each is safe to run again).
2. Replace `public/index.html` **and** `public/adapter.js` in GitHub.

- **Display name:** everyone can set their own from the account menu (top right) → *Change display name*. It's shown instead of the email in the header, the user list and the audit trail. Supervisors can set anyone's in *Users and access*. It doesn't change the sales engineer name used on leads.
- **Rename products and sales engineers (Supervisor):** *Products & settings* → *Rename* next to a product or engineer. The new name replaces the old one on every lead and meeting, in the lists, territories, the linked login and the account history, in one step. Spelling variants of the old name (different capitals or spaces) are unified too. One "Renamed" entry, listing the leads changed, goes to the audit trail.

**6 Nov 2026 (operations and upsell leads) — one update with everything below:**
1. In the SQL Editor run `supabase/12_operations.sql`, then `supabase/13_upsell.sql` (both safe to run again; no lead data is changed).
2. Replace `public/index.html` in GitHub (`adapter.js` is unchanged).

**Upsell leads:** when a product is added to an approved lead at a meeting or after one, Lead Desk creates a separate lead marked **Upsell** (reference like `LD2026-0123-U1`), linked to the original and assigned to the engineer who held the meeting. The original lead keeps its products, engineer and lead generator, so the generator's incentive covers the original products only. More products added while that upsell lead has no quotation yet go onto the same upsell lead. Products added before any meeting still go on the original lead. Lead Managers and Supervisors logging a meeting choose who held it ("Held by"). Supervisors decide in **Products & settings → Rates and targets** whether upsell revenue counts in engineers' results and the upsell incentive % (0 = off). Management → Pipeline health shows **New business and upsell**.

**Operations changes in the same update** (after running 12, the last result shows the Lead Manager's permissions, which should now include `lead.remove` and `lead.edit_country`):
- **Country** is shown in every lead's details. Supervisors and Lead Managers can change it at any stage ("Change country"); only the country (and, if you tick it, the region) changes, and the change is written to the lead's activity and the audit trail.
- **Delete lead** (Supervisor, Lead Manager) on approved leads, with a confirmation window and a required reason (Other needs an explanation). The lead is hidden from every list, count and report but nothing is erased. Back office → **Deleted leads** lists them with reason, who and when, and has **Restore**. The audit trail records each delete and restore with its reason.
- **Quotations need a target date.** Each quotation keeps its own target date; a revised quotation keeps the earlier one with its target date. The target date shows in the lead, on the pipeline card, in Management → Pipeline health ("Open quotations by target date" and "Needs attention" when a target has passed). The engineer, Lead Manager or Supervisor can change it; each change is recorded.
- **Meetings no longer ask for an amount.** Amounts are entered only with the quotation and the order. Amounts already saved on old meetings are kept and still count where they did before.
- **Supervisors can correct meeting dates on Won leads** ("Change date" on the meeting). The original date, new date, who and when are kept; status, values, assignment and incentive don't change. The database refuses this change from anyone else.

**6 Nov 2026 (free-plan mode: low data + backups):**
1. Run `supabase/11_low_data.sql` in the SQL Editor (adds a "last changed" time to leads and accounts).
2. Replace `public/index.html` **and** `public/adapter.js` in GitHub.
Each device now keeps a copy of the leads and downloads only what changed since its last visit (about 98% less data on reopening). The copy is cleared on sign-out. Edits always start from the latest saved version. Supervisors get **Products & settings → Backup → Download full backup** (one file with all leads, accounts, users, settings and the audit trail); the panel shows when the last backup was taken and turns amber after 7 days.

**6 Nov 2026 (stability):** fixes the "render audit: Cannot use 'in' operator" crash on the Audit trail; new Product matrix; lighter data refresh for many simultaneous users (live changes only, a full reload every 15 minutes, 5 for sales, and after a dropped connection). Replace `public/index.html` **and** `public/adapter.js` in GitHub.

**6 Nov 2026 (audit trail fix, faster database rules, new product matrix):**
1. Replace `public/index.html` in GitHub. Fixes the "Cannot use 'in' operator" error on the Audit trail page, and any single unusual audit entry can no longer stop the page from showing. Also includes the redesigned Product matrix on the Accounts tab.
2. Run `supabase/11_performance.sql` in the SQL Editor. Same permissions, but each user's data loads several times faster (the rules are checked once per request instead of once per row).

**5 Nov 2026 (audit trail):** a Supervisor-only **Audit trail** tab: every change to leads, accounts, users and settings (recorded by database triggers, including changes made outside the app), plus sign-ins, sign-outs, password changes, exports and presentations. Read-only and can't be edited or deleted.
1. Run `supabase/10_audit_trail.sql` in the SQL Editor.
2. Edge Functions → `user-admin` → paste the new `supabase/functions/user-admin/index.ts` and Deploy (logs sign-in creation and password resets).
3. Replace `public/index.html` **and** `public/adapter.js` in GitHub.

**5 Nov 2026 (presentation, shared names):** Supervisors get **Create presentation** on the Management tab: a 10-slide PowerPoint of sales performance for the filters selected (loads the PptxGenJS library from jsDelivr the first time). Back office lists leads assigned to two people (e.g. "Vishnu Himani") with a button that moves them back to the queue to choose one engineer. Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (Management views, order breakdown, Supervisor edits):** Management is split into tabs (Overview, Engineers, Inbound vs outbound, Revenue per account, Regions, Pipeline health); on Engineers, ▸ next to a name lists the orders behind that revenue; Supervisors get an "Edit details" button on every lead to correct any field (new permission "Edit every field on a lead"). Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (country list, export rights, meeting notes):** the lead form has a country dropdown (most-used first) instead of free text; a "Meeting notes" section on the lead form saves the first meeting with the lead; exporting leads (Leads tab Excel/CSV, Management CSV, Meetings CSV) is a new permission, on for Lead Manager and Supervisor only (change it under Roles and permissions). Replace `public/index.html` **and** `public/adapter.js` in GitHub (the adapter lets sales engineers create a new property record). Optionally re-run `supabase/09_rbac.sql` so the database's permission table lists the new export permission too.

**5 Nov 2026 (usability pass):** account menu in the header (password and sign-out), scrollable tabs on phones, pipeline columns show 25 cards at a time, quieter "no meeting" warnings on old leads, clear empty states on Meetings with month arrows, keyboard support for tabs and the lead panel, consistent dates (05 Sep 2026), "No region" instead of a second "Unassigned", and the red required-field asterisks restored. Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (Source filter):** on the Leads tab, the Department filter is replaced by a Source filter (Support Team, AMC Team, Apollo, Website / Chat…); the table shows a Source column and the Inbound/Outbound buttons are labelled Category. Export follows the Source filter. Replace `public/index.html` in GitHub.

**5 Nov 2026 (emirates and states):** every UAE emirate and US state (plus DC, Puerto Rico, USVI) can have its own owner under Products & settings → Emirates and states, one at a time or a whole group at once. The lead form asks for the emirate/state when the location is UAE or USA, back office can change it when verifying, and it's a filter on Leads, Accounts and Management. Existing leads are matched from their location and property name. Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (Leads tab filters and export):** Department, Year and Month filters alongside engineer, source, status, region and search; removable filter chips and Clear all; sortable columns; KPI cards; Export to Excel or CSV of every lead matching the filters. Replace `public/index.html` in GitHub; no database changes. (Excel export loads the SheetJS library from cdnjs the first time it's used.)

**5 Nov 2026 (sales analytics):** new Accounts overview (region, engineer, leads, orders, revenue, status, key requirements; engineer filter and summary; sortable) and a rebuilt Management tab (KPIs, sortable engineer table, inbound vs outbound performance, revenue-per-account leaderboard, regional performance, charts). One set of filters (period, region, engineer, source, account status) drives both tabs. Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (first pages and new-lead alerts):** Sales open on Meetings, Management and Supervisors on Management, Lead Managers on Back office. Sales get a red count on My pipeline, a "New leads assigned to you" list and a pop-up when a lead is assigned to them. Replace `public/index.html` in GitHub; no database changes.

**5 Nov 2026 (roles and permissions):** four roles (Supervisor, Lead Manager, Management, Sales) controlled from one permission table that the database enforces.
1. In Supabase SQL Editor, run `supabase/09_rbac.sql` once. Everyone who was **back office** becomes **Supervisor**; sales and management keep their roles. The last query shows how many people have each role.
2. Edge Functions → `user-admin` → replace the code with `supabase/functions/user-admin/index.ts` and **Deploy** (it now checks the *Users, roles and permissions* permission).
3. In GitHub, replace `public/index.html` **and** `public/adapter.js`.
4. Sign in as a Supervisor → **Products & settings → Users and access** and change anyone who should be a **Lead Manager**. Review **Roles and permissions** on the same page.

| Role | Pages | Data |
|---|---|---|
| Supervisor | Everything, including users, roles and settings | All records; can delete |
| Lead Manager | Leads, Back office, Pipelines, Meetings, Accounts | All leads; create, approve, assign, reassign, update; merge accounts |
| Management | Leads (list), Pipelines, Meetings, Management, Accounts | All records, read-only |
| Sales | Leads (own list + outbound form), My pipeline, Meetings, Accounts | Only leads assigned to them, their meetings and accounts |

**4 Nov 2026 (default password; changed 20 Nov: now a random password per person):** back office creates sign-ins from the app with a temporary password; people must choose their own at first sign-in. Deploy the `user-admin` function (see "Creating sign-ins from the app"), then replace `public/index.html` and `public/adapter.js`.

**4 Nov 2026 (hand over):** back office can hand an engineer's open leads and territories to someone else in one step. Replace `public/index.html` in GitHub; no database changes.

**4 Nov 2026 (territories):** each country/city/region belongs to one sales engineer; leads route to the owner; sales can log meetings while a lead waits for approval.
1. Run `supabase/08_territories.sql` once (adds the starting territory list and lets sales submit outbound leads for another engineer's territory).
2. In GitHub, replace `public/index.html` **and** `public/adapter.js`.

**4 Nov 2026 (late):** follow-ups with date and time, a Follow-ups panel on My leads, and automatic emails. Replace `public/index.html` in GitHub; for the emails, follow "Automatic emails" below.

**4 Nov 2026 (evening):** new Meetings tab; each meeting is logged with Online/Onsite, new-lead or follow-up, and products discussed. Replace `public/index.html` in GitHub; no database changes.

**4 Nov 2026 (afternoon):** back office can merge or delete duplicate accounts. Replace `public/index.html` in GitHub; no database changes.

**4 Nov 2026 update:** account search fix, requirement date, regions, and the 67 new Excel leads.
1. In Supabase SQL Editor, run `supabase/06_import_leads_0986_to_1052.sql` once. The Messages tab shows what was added, renumbered or skipped.
2. In GitHub, replace `public/index.html` (and `public/adapter.js` if you haven't updated it since 3 Nov). Vercel redeploys automatically.
No table changes are needed.

If you set up Supabase before 3 Nov 2026 23:50, run `supabase/05_sales_outbound_leads.sql` once in SQL Editor, then replace `public/index.html` in GitHub.

## Creating sign-ins from the app (temporary password)

With this set up, **Users and access → Add user** also creates the person's sign-in with a random temporary password (shown once on screen; give it to the person privately), and each row gets a **Reset password** button that makes a new random temporary password. Anyone signing in with the temporary password must choose their own before they can use Lead Desk.

1. Supabase → **Edge Functions → Deploy a new function → Via Editor**, name it `user-admin`, paste `supabase/functions/user-admin/index.ts`, and **Deploy**. Leave **Verify JWT ON**: only signed-in Supervisors can call it.
2. Optional: add the secret `APP_ORIGIN` (your app address, e.g. `https://your-app.vercel.app`) so only your site can call this function from a browser. There is no `DEFAULT_PASSWORD` secret any more; every temporary password is random.
3. Replace `public/index.html` and `public/adapter.js` in GitHub.

Keep **Authentication → Providers → Email → Leaked password protection** on; the random temporary passwords are not affected by it.

## Automatic emails (new lead assigned, follow-up due)

Lead Desk emails a sales engineer when back office assigns or reassigns a lead to them, and when a follow-up they scheduled is due (checked every 10 minutes; date-only follow-ups are sent at 09:00 Dubai time). The engineer must have a login linked to their engineer name in **Users and access**, because that's where the email address comes from.

**1. Get an email-sending key (Resend)**
1. Sign up at **resend.com**, add your domain (e.g. `samsotech.com`) and add the DNS records it shows you (ask IT if needed). Wait until the domain shows *Verified*.
2. Create an **API key** and copy it.

**2. Create the Edge Function in Supabase**
1. Supabase → **Edge Functions → Deploy a new function → Via Editor**. Name it `lead-mailer`.
2. Replace the sample code with the contents of `supabase/functions/lead-mailer/index.ts` and click **Deploy**.
3. Open the function's **Details / Settings** and turn **Verify JWT** (Enforce JWT verification) **off**. The function checks its own secret instead.
4. Copy the function URL, e.g. `https://abcd1234.supabase.co/functions/v1/lead-mailer`.

**3. Add the function's secrets** (Edge Functions → **Secrets**)
| Name | Value |
|---|---|
| `RESEND_API_KEY` | the key from step 1 |
| `MAIL_FROM` | `Lead Desk <leaddesk@samsotech.com>` (must use the verified domain) |
| `APP_URL` | your Lead Desk address on Vercel |
| `MAILER_SECRET` | any long random text, e.g. 40 letters and numbers |

**4. Switch it on in the database**
Open `supabase/07_email_notifications.sql`, put your function URL and the same `MAILER_SECRET` in the "Your settings" block, then run it in SQL Editor.

**5. Test**
- Assign a lead to an engineer whose login is linked. Within a minute they should get "New lead assigned: LD2026-…".
- On one of their leads, set a follow-up 5 minutes ahead. The reminder arrives within 10 minutes of that time.
- If nothing arrives: Edge Functions → `lead-mailer` → **Logs** shows each run and any error (a wrong API key, or an engineer with no linked login). Integrations → **Cron** shows the 10-minute job.

Leads loaded from Excel don't trigger emails, and neither does an engineer's own outbound lead being verified.

## Good to know

- **Costs.** Supabase Free and Vercel Hobby cost nothing to start. Two limits apply:
  - Supabase pauses free projects after about a week without use. Upgrade to Pro if the team won't use it daily.
  - Vercel's Hobby plan is meant for non-commercial use, so a company tool should run on Vercel Pro. Netlify and Cloudflare Pages also serve the same `public` folder; upload it as-is.
- **Backups.** Supabase Pro includes daily backups. On Free, export the `leads` table now and then (Table Editor → Export to CSV), or use Lead Desk's **Export CSV** on the Management page.
- **Reassigning a lead.** When back office moves a lead from one engineer to another, it drops off the first engineer's screen within two minutes, or as soon as they switch back to the tab.
- **Lead numbers** continue from LD2026-0986 and restart at 0001 each new year.
- **Changing the app.** Edit `app-source/lead-desk.html`, run `python3 build.py app-source/lead-desk.html`, then push to GitHub. Vercel redeploys automatically.
- **Removing someone.** Remove them in Users and access. They lose access to all data straight away. To block their sign-in entirely, also delete them under Supabase → Authentication → Users.
