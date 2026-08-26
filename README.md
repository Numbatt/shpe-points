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

*2026-08-25.* **The system is live end to end.** The poller runs, forms ingest, points flow, and
the dashboard is deployed. What remains before the first GBM of 2026-27 is listed under
"Before the first GBM" below, and one of those items blocks this year's data entirely.

**Working and verified on the live database**

- **Ingestion is real.** The Apps Script poller discovered 14 Google Forms on 2026-08-10 and
  pulled each one's full response history. The database holds **331 people, 1245 attendance rows,
  42 events**, spanning 2024-08-28 to 2026-04-16.
- **Backfill is complete for 2024-25.** The legacy spreadsheet import covers 2024-08-28 through
  2025-09-02, typed and paid. Everything after that arrived through the live pipeline.
- Security is unchanged and still holds: with the published anon key every base table returns 401
  and only `member_totals_all_time` is readable. Officers see everything; non-officers see nothing.
- Google sign-in is finished (`google: true`, `email: false`).

**Known gaps, in the order they bite**

- **14 events are still untyped**, so every GBM since 2025-08-28 is currently worth 0 points.
  Tapping a type pays retroactively, so nothing is lost — but read the warning below first.
- **`memberships` is empty.** No membership form has ever been ingested: the 2025-26 one was filed
  outside the polled Drive folder, so the poller never saw it. This is why major, gender and class
  level are blank everywhere, and why nobody can be placed in the October deliberation grid yet.
  Moving that form into the year's folder recovers it with no code changes.
- **91 people have no name on record.** They are hidden from the public leaderboard rather than
  shown blank. The "No name on file" card now fills these from the Rice directory in batches.
- **3 unmatched sign-ins**, all recoverable — two resolve by directory name search, one is a typo
  of a real netID.
- `app_config.leaderboard_window_start` is empty, so the **public leaderboard shows all-time
  totals**, mixing 2024-25 legacy points with the current year. That is a deliberate open decision,
  not an oversight — set it when the chapter decides its reset policy.

**Before the first GBM**

1. **Set 2026-27's Drive folder ID** (year pill → gear). It is currently null, which means the
   poller is watching **nothing** for this year and any form made for the GBM would be invisible.
2. **Add this year's eboard to the `officers` allowlist.** Only `dr56@rice.edu` can sign in today.
   There is no UI for this yet; it is a SQL insert.
3. **Put the membership form in the polled folder** this time, and keep its question wording.

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
