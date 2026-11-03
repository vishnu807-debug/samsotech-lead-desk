# Lead Desk: hosting on Supabase + Vercel

Lead Desk runs as a static website on **Vercel**, with its database and sign-in on **Supabase**. Staff sign in with a link emailed to their work address. The database decides what each person can see and change:

| Role | Sees | Can change |
|---|---|---|
| Back office | Everything | New leads, verification and assignment, products, engineers, users, settings |
| Sales engineer | Only leads assigned to their linked engineer name | Stages, amounts, products, follow-ups and notes on their own leads |
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
  02_add_yourself.sql      makes you the first back-office user (edit the email first)
  03_seed_settings.sql     products, engineers, sources, rates, 2026 history, account registry
  04_seed_leads_part1-3    the 976 leads from the 2026 Excel sheet
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

1. Open your Vercel address, enter your email and click the link you receive.
2. Go to **Products & settings → Users and access**. For each person, type their work email and choose a role. For sales engineers, also choose their engineer name, which is what links them to their leads.
3. Tell them the address. They sign in the same way.

---

## Good to know

- **Costs.** Supabase Free and Vercel Hobby cost nothing to start. Two limits apply:
  - Supabase pauses free projects after about a week without use. Upgrade to Pro if the team won't use it daily.
  - Vercel's Hobby plan is meant for non-commercial use, so a company tool should run on Vercel Pro. Netlify and Cloudflare Pages also serve the same `public` folder; upload it as-is.
- **Backups.** Supabase Pro includes daily backups. On Free, export the `leads` table now and then (Table Editor → Export to CSV), or use Lead Desk's **Export CSV** on the Management page.
- **Reassigning a lead.** When back office moves a lead from one engineer to another, it drops off the first engineer's screen within two minutes, or as soon as they switch back to the tab.
- **Lead numbers** continue from LD2026-0986 and restart at 0001 each new year.
- **Changing the app.** Edit `app-source/lead-desk.html`, run `python3 build.py app-source/lead-desk.html`, then push to GitHub. Vercel redeploys automatically.
- **Removing someone.** Remove them in Users and access. They lose access to all data straight away. To block their sign-in entirely, also delete them under Supabase → Authentication → Users.
