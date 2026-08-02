# SHPE Rice — Points System

Tracks member event attendance and awards points. Points are the main input to deciding
who the chapter sponsors for the SHPE National Convention each October.

**Start here:** [`docs/DESIGN.md`](docs/DESIGN.md) — full architecture and rationale.

## How it works, in one paragraph

Officers create a Google Form for an event and share it. An Apps Script poller running
under the club's shared Gmail account discovers the form, reads its responses directly
(no spreadsheet involved), and pushes them into Supabase. The officer taps the event's
type once in the dashboard — the only thing the system can't infer — and points flow.
The shpe.rice.edu webmasters read totals from a public API and build the leaderboard
themselves.

## What lives where

| Path | What |
|---|---|
| `supabase/migrations/` | Schema as versioned SQL |
| `supabase/functions/ingest-checkin/` | Edge Function that validates and writes attendance |
| `apps-script/` | The poller. Deploys by pasting into the shared account's script editor |
| `dashboard/index.html` | Officer dashboard — one file, no build step, no dependencies |
| `scripts/backfill.ts` | One-time importer for historical points |
| `scripts/legacy-export/` | CSV snapshot of the old schema, taken before anything was dropped |
| `docs/RUNBOOK.md` | For the next VP. Non-technical |
| `docs/API.md` | For the webmasters |

## Status

*2026-07-30.* **Phases 0–1 are applied and verified on the live database.** Phases 3–7 are written
and committed; the ingestion pipeline has not yet run against a real Google Form.

**Done and verified**

- Legacy schema audited and exported to CSV; counts asserted against the audit, invariant recorded
  in `scripts/legacy-export/MANIFEST.md`.
- Eight migrations applied. The new schema holds **302 people, 840 attendance rows, 1013 points** —
  identical to the legacy totals, asserted by the migration itself.
- Public access locked down. With the published anon key, every base table and internal view
  returns 401 and the `legacy` schema returns 404; only `member_totals_all_time` is readable, and
  it exposes just `rank, first_name, last_name, total_points`.
- RLS proven by query: a signed-in non-officer sees 0 rows from `v_member_totals`, `people` and
  `attendance`; an allowlisted officer sees 302 / 302 / 840.
- Behaviour tested: dedup on repeat sign-in, untyped events ingesting at 0 points, tapping a type
  paying retroactively, volunteer hours driving per-person points, and the configurable date window.
- Backfill importer dry-run against the legacy data reproduces it exactly (837 rows imported,
  3 correctly refused).

**Outstanding**

- **Google sign-in is not finished.** Cloud project `SHPE Rice` exists; still to do — create the
  OAuth client (redirect URI `https://jzxxchjjhkbvfazrbeom.supabase.co/auth/v1/callback`), publish
  the consent screen, paste the credentials into Supabase → Authentication → Providers → Google,
  and **disable the Email provider** so Google is genuinely the only way in. Leave public signup
  enabled — Supabase creates the auth user on first OAuth sign-in, so disabling it would reject
  every officer's first login. `dr56@rice.edu` is already on the `officers` allowlist.
- **No backfill has been run.** The database holds events through 2025-09-02; Fall 2025 from
  September onward and all of Spring 2026 are still missing, and their source files have not been
  located. The importer is written and dry-run tested — it needs the sheets, plus a date and type
  for each event.
- **The poller has never run against a real form** — that needs the shared Drive folder ID, and
  the Edge Function needs deploying with its shared secret.
- The dashboard is not deployed anywhere yet (it is one static file; any free host works).
- Postgres has security patches available (platform-level upgrade).

**Handoff still open:** the Supabase project's ownership is unverified and likely a personal
account. That is the single biggest risk to this system surviving; see the ownership checklist in
`docs/DESIGN.md`.

## Setup

Requires the Supabase MCP scoped to project `jzxxchjjhkbvfazrbeom`. Run Claude Code from
this directory so `.mcp.json` is picked up, then `/mcp` to authenticate. The project must
be un-paused first — MCP cannot query a paused project.

`.mcp.json` is scoped to the one project and no longer pins `read_only=true` — Phase 1 writes
migrations. Re-authenticate with `/mcp` after changing that URL, or the old read-only token is
reused.

## The one rule that matters for handoff

Everything — the Supabase project, the Vercel deploy, the Apps Script triggers, the Drive
folder — must be owned by the club's **shared Gmail account**, never a personal Rice
account. Apps Script triggers stop firing silently when the account that installed them is
deprovisioned, which is how systems like this usually die. See the ownership checklist in
`docs/DESIGN.md`.
