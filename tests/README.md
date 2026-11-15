# Lead Desk tests (added 15 Nov 2026)

These run in a development sandbox, not on the live site. Paths inside the scripts point to `/home/claude/ld/...`; change them if the folders differ.

| File | What it checks |
|---|---|
| `fakesb.js`, `h.py` | A stand-in for Supabase in the browser (tables, simplified role rules, two-step sign-in) and the Playwright harness. |
| `r68.py` | Clickable stage boxes: every status, every role, 320 / 390 / 768 / 1024 / 1440 px (44 checks). |
| `r69.py` | Full export: backup file and Excel workbook, paging, secrets, audit trail, every role (35 checks). |
| `r70.py` | Two-step sign-in: rule, set-up, code, reset, overrides, every role and width (63 checks). |
| `regr.py` | Every page of every role, desktop and phone: run once on the previous build (`LD_ROOT=<old public folder>`), once on the new one, and compare the two result files. |
| `pg/stub.sql`, `pg/run.sh` | Build a local Postgres database with stand-ins for Supabase's roles and sign-in tables, then run every SQL file. |
| `pg/parta.py` | Database rules for export and two-step sign-in, as every role (59 checks). |
| `shots.py` | The review screenshots. |

Seed data: `seed.json` is made from the SQL seed files (see the query at the top of the Part A notes in the technical reference); it is not kept in the zip because it is a copy of the lead sheet.
