# SHPE Rice — Points System

Tracks member event attendance and awards points. Points are the main input to deciding
who the chapter sponsors for the SHPE National Convention each October.

**Start here:** [`docs/DESIGN.md`](docs/DESIGN.md) — full architecture and rationale.
**Running it day to day:** [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — written for the VP, not a developer.

## How it works, in one paragraph

Officers create a Google Form for an event while signed in as the club's shared Gmail account and
share it with members. An Apps Script poller running under that same account discovers the form,
reads its responses directly — no spreadsheet involved — and pushes them into Supabase every 15
minutes. The officer taps the event's type once in the dashboard (GBM, workshop, social, …), which
is the one thing the system can't infer on its own, and points flow to everyone who signed in,
retroactively if the tap comes late. The shpe.rice.edu webmasters read totals from a public,
read-only API and build the leaderboard themselves — this project doesn't own that page.

## What the system actually does

### Turning a sign-in into a point

1. **A member signs in** on a Google Form with their Rice netID (or Rice email).
2. **The poller** (a script under the shared Gmail, not a person) checks every Google Drive folder
   the dashboard has told it to watch, every 15 minutes. It reads new form responses directly from
   Google — there's no spreadsheet step, and nothing needs a human to run it.
3. **Each response becomes an attendance row** in the database, at zero points, the moment it's
   read. Nothing is lost by an officer being slow to react.
4. **An officer taps the event's type** in the dashboard (General Body Meeting, workshop, social,
   etc.) exactly once. Every event type has a default point value; an officer can override it per
   event. The tap pays everyone already recorded, including people who signed in weeks earlier.
5. **The public leaderboard on shpe.rice.edu** reads a read-only summary view and updates itself —
   this system never talks to that page directly, it only publishes numbers for it to read.

A sign-in that can't be matched to a real Rice person (a personal email, a typo) never becomes a
silent guess — it lands in a queue for a human to resolve. See "Needs attention" below.

### Points come from three places

- **Attendance.** The event's point value, paid once per person per event.
- **Role bonuses.** Holding an eboard or chair position for an academic year pays a bonus, set once
  per role per year and re-appliable any time roles change (adding or removing someone recomputes
  rather than stacking).
- **Manual adjustments.** For anything that never had a form — most often volunteering hours,
  entered from a pasted spreadsheet column, but also one-off corrections. Every adjustment records
  who made it and why.

Every one of those is visible per-person on the **Standings** screen, broken into events, role
bonuses and adjustments, so "why does this person have this many points" always has an answer.

### The officer dashboard

One page (`dashboard/index.html`), signed into with a Rice Google account, restricted to an
explicit allowlist of officer emails. Eight screens:

| Screen | What it's for |
|---|---|
| **Needs attention** | The weekly to-do list: events with no type yet, sign-ins that couldn't be matched to a real person, forms the poller can't read (usually a permissions fix), people with no name on record, and — once a year — telling the system which form is the membership form. |
| **Events** | Every event there has ever been, newest first, grouped by academic year. Set or change a type, see how many people it recorded and how many points it paid, restore something dismissed by mistake. |
| **Volunteering** | The one thing entered by hand. Volunteer sheets have no consistent format, so rather than a parser that half-works, an officer pastes a netID/hours column straight from a spreadsheet; every row is checked against a real person and previewed before anything is written. |
| **Standings** | The leaderboard officers actually use to deliberate: filterable by major, gender, class level, and by date range ("since the last convention," a semester, all-time), with eboard members and role bonuses optionally excluded to see the underlying picture. Exports to CSV. **It never ranks or recommends who to sponsor** — see below. |
| **Roles** | Who held which eboard/chair position, per academic year. Assigning or removing a role and pressing "Apply role bonuses" is the entire mechanism for role points. |
| **Adjustments** | Manual point changes with a required reason, for anything that isn't an event or a role. |
| **Officers** | Who can sign into this dashboard at all — the access allowlist itself, editable without touching the database directly. |
| **Audit Log** | Who changed what and when — attaching or dismissing a sign-in, correcting a name, granting or revoking access, changing a role or a role's bonus. Every consequential write in the system is attributed to a real signed-in officer, never silent. |

### What the system refuses to do

**It will never rank or recommend who to sponsor.** Sponsorship depends on constraints the points
system can't see — convention housing needs rooms of four of the same gender, and the chapter wants
at least one student per major so each department can be asked to help cover the cost. A single
ranked list would misrepresent a decision that's really several separate cohorts. Standings slices
the data every way an officer needs; the conversation is theirs.

**It will never guess who a sign-in belongs to.** A sign-in that doesn't carry a clean Rice netID
sits in "Needs attention" until a human confirms it, even when a name search makes the match
obvious. Inventing a match is the one failure this system is built to never commit — the roster
that October's sponsorship conversation reads from has to be trustworthy.

**It will never overwrite a name Rice's directory disagrees with.** If an officer has typed a
name in by hand, directory lookups only ever fill a *blank* — never a name someone already entered.

## Where the numbers are public

`member_totals_all_time` is the one thing anyone with the site's public key can read — first name,
last name, total points, nothing else. No netIDs, no demographics, no way to see who's an officer.
Every other table refuses even a signed-in Google account that isn't on the officer allowlist.
That view is what shpe.rice.edu's leaderboard queries; its name and columns are a stable contract
this project doesn't change without warning (see [`docs/API.md`](docs/API.md)).

## What lives where

| Path | What |
|---|---|
| `supabase/migrations/` | Schema as versioned SQL — the full history of every table, view and rule |
| `supabase/functions/ingest-checkin/` | Edge Function the poller calls to write attendance |
| `supabase/functions/directory-lookup/` | Edge Function the dashboard calls to search Rice's people directory |
| `apps-script/poller.js` | The poller's source. Deploys by pasting into the shared Gmail's Apps Script editor at script.google.com — see the setup comment at the top of the file |
| `dashboard/index.html` | The entire officer dashboard — one file, no build step, no framework, no dependency. Deliberate: the next VP is not necessarily technical, and a file with nothing to install has nothing to rot |
| `scripts/` | One-time importers, the name-backfill script, and local test suites |
| `scripts/migration-tests/` | Applies every migration to a throwaway Postgres and asserts real behavior before anything touches production |
| `docs/RUNBOOK.md` | For the next VP. Non-technical, week-by-week |
| `docs/DESIGN.md` | Full architecture and the reasoning behind every hard decision |
| `docs/API.md` | For the shpe.rice.edu webmasters |
| `docs/HOW-IT-WORKS.md` | A deeper technical walkthrough, for whoever maintains the code |

## Status

*As of 2026-08-27.* The system is live end to end for the 2026-27 academic year: the poller is
watching this year's Drive folder, membership records exist, and the officer allowlist has three
active officers.

| | |
|---|---|
| People on record | 334 |
| Attendance rows | 1,177 |
| Events | 42 (0 untyped) |
| Membership records | 73 |
| Unmatched sign-ins waiting on a human | 0 |
| People with no name on file | 40 (30 already dismissed as unresolvable — see below) |
| Current academic year | 2026-27 |
| Public leaderboard window | all-time (no reset date set yet — a deliberate open decision, see `docs/RUNBOOK.md`) |

"No name on file" isn't a broken pipeline — it's almost always a student who's hidden their Rice
directory listing under FERPA, which is their right and never resolves automatically. Those rows
can be dismissed from the queue (their points are completely unaffected) once an officer decides
chasing the name further isn't worth it.

## Setup

Requires the Supabase MCP scoped to project `jzxxchjjhkbvfazrbeom`. Run Claude Code from
this directory so `.mcp.json` is picked up, then `/mcp` to authenticate. The project must
be un-paused first — MCP cannot query a paused project.

## The one rule that matters for handoff

Everything — the Supabase project, the Vercel deploy, the Apps Script triggers, the Drive
folder — must be owned by the club's **shared Gmail account**, never a personal Rice
account. Apps Script triggers stop firing silently when the account that installed them is
deprovisioned, which is how systems like this usually die. See the ownership checklist in
`docs/DESIGN.md`.
