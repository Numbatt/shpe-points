# Handoff — 2026-08-26

> ## Update, later the same day
>
> **The "Next phase" section below is now built, on branch `membership-dual-role`.** Dual-role
> events, the reworked replay trigger, the audit trail, the ingest rewrite, the Events screen and
> the docs are all committed and tested. `scripts/migration-tests/run.sh` applies all 14 migrations
> to a throwaway Postgres and asserts 29 behaviours; the three node suites pass.
>
> One design point changed while building it. The membership flag is **not** a per-event toggle
> shown on every row — a year has one membership form, usually the first GBM's sign-in, and asking
> twenty-odd events a year is asking a question with one answer. It is a card in Needs attention
> that disappears once set, and moves to the Events screen where it can be cleared. Typing an event
> as a membership form claims the same slot implicitly, enforced by `events_membership_guard`.
>
> **Nothing has been applied to production.** Every warning below is still live, in particular the
> one about `Fall GBM 1 - 08/28/25`. Once `20260826120000_dual_role_events.sql` lands, tapping
> Membership stops being able to destroy that event's attendance — until then it can.
>
> Still blocked on: Supabase access to apply the migrations, the 2026-27 Drive folder ID, and this
> year's eboard emails.

Written at the end of a working session that ran out of budget mid-stream. Everything below is
either **already done**, **written but not applied**, or **designed but not built**. Read the
"Do this first" section before touching anything.

---

## ⚠️ Do this first — two ways to lose data right now

**1. Do NOT tap "Membership Form" on `Fall GBM 1 - 08/28/25` in the dashboard.**
That event (`e0feb9ac-1da9-4b69-a693-a00c1e71816c`) is the 2025-26 membership form *and* a GBM
sign-in. Tapping Membership today fires `events_membership_retype_replays`
(`supabase/migrations/20260809212826_*.sql`), which **deletes all 73 attendance rows** on it. The
whole "dual-role events" design below exists to make that safe. Until it ships, leave the event
untyped or type it `gbm` only.

**2. Remove `2025 Membership Form` from the Drive folder BEFORE deleting its database row.**
If the row is deleted while the form is still in the polled folder, the poller rediscovers it on
the next pass and recreates the event — forever. Order: Drive first, database second.

---

## Where things actually stand

Live project `jzxxchjjhkbvfazrbeom`. As of 2026-08-26 03:45 UTC:

| | |
|---|---|
| people | 331 (91 with no name) |
| attendance | 1245 rows, 1013 points |
| events | 43 (15 untyped) |
| memberships | **0** |
| unmatched sign-ins | 3 (all recoverable) |
| `current_year_id` | `2025-26` — **switch back to `2026-27` before the GBM** |
| `leaderboard_window_start` | `''` (public leaderboard shows all-time, mixing years) |
| officers allowlist | `dr56@rice.edu` only |
| `2026-27.forms_folder_id` | **NULL — the poller is watching nothing for this year** |

### The discovery that reframed everything

`Fall GBM 1 - 08/28/25` was **both** the GBM 1 sign-in and the 2025-26 membership form — one form,
so students didn't fill out two. Its questions confirm it: `Gender`, `College`, `Year`, `Major`,
plus `New or returning member`, `What do you hope to get out of SHPE this year?`,
`Have you attended SHPE Nationals/Career Fair before?`.

The schema cannot express that. `events.type_code` is a single FK, and the ingest function's
membership branch `continue`s before ever reaching `attendanceRows.push`
(`supabase/functions/ingest-checkin/index.ts:363-396`), so a membership-typed event can never also
record attendance. That is the gap the next phase closes.

A separate empty `2025 Membership Form` (`fd68b16e-1015-4ea1-987f-1f5c794ae87c`) was moved into the
folder by mistake — it has **0 responses** and is not the real form. Delete it (see warning 2).

---

## Already done

### Deployed to production
- **`directory-lookup` Edge Function** (v1, `verify_jwt=true`). Proxies Rice's people directory,
  which the browser cannot call (no CORS headers). Auth verified empirically: no header → 401,
  **anon key → 401**, valid non-officer JWT → **403**. `verify_jwt` alone is not a gate — the anon
  key embedded in the dashboard is itself a valid project JWT.
- **`ingest-checkin` redeployed** (v14, `verify_jwt=false` — *must stay false*, the poller
  authenticates with `x-ingest-secret`). Carries the class-level alias fix and the gap-fill hook.

### Written, tested, NOT committed (working tree is dirty)
- `supabase/functions/_shared/membership-template.ts` — normalized title aliases + closed-vocabulary
  class level. `Year: "Sophomore"` → class level; `Year: "2028"` → graduation year;
  `Class: "COMP 322"` → nothing. Major/gender stay strict, never inferred.
- `supabase/functions/_shared/directory.ts` — added `searchDirectoryByName()` (returns *candidates*
  for a human, the deliberate inverse of `lookupNetid`) and `parseDirectoryBody()`.
- `dashboard/index.html` — form links on event names, unmatched sign-ins show name/context + "Find
  netID" + soft Dismiss, "Look up 25 names" button, Standings date range with presets, confirm
  dialog on the Membership button, `convention_on` in the year dialog.
- `scripts/test-membership-template.ts` (new, 39 checks) and `scripts/test-directory.ts` (extended).
- `README.md`, `docs/RUNBOOK.md`, `docs/DESIGN.md` status sections corrected.

Run both suites with `node scripts/test-membership-template.ts` and
`node scripts/test-directory.ts` (add `--offline` to skip the live canary). All pass.

### A real upstream bug found and worked around
Rice's directory returns **malformed JSON** for some queries — a staff record with
`"title": "["Head Coach Women's Soccer"]"` has unescaped quotes that break `JSON.parse` on the
*entire* response. `?q=garcia` (84 people) and `?q=rodriguez` (80) both fail; `?q=martinez` doesn't.
For a SHPE chapter those are exactly the surnames that matter. `parseDirectoryBody()` falls back to
salvaging records by text-scanning. The safety rule is unchanged — a salvaged record still must pass
the same exact-netID verification.

---

## Written but NOT applied — three migrations

Nobody has run these. The Supabase CLI **cannot** apply them: it fails provisioning its login role
(`permission denied to alter role cli_login_postgres`). Apply via the Supabase SQL editor, or with a
DB password / access token.

A ready-to-paste bundle was generated at
`/private/tmp/claude-501/-Users-diego-dev/62698bd1-e666-450d-86c5-b2018de3db29/scratchpad/apply-all.sql`
— **regenerate it if that scratchpad is gone**, by concatenating the three files below in order.

1. `20260825210000_reconcile_aug28_duplicate.sql` — 2025-08-28 exists as two events. The legacy
   spreadsheet import (`786172d7`, typed, 74 attendees, paid) and the poller's form-backed event
   (`e0feb9ac`, untyped, 73 attendees). 72 netids overlap; `pa30`/`sam35` only on the first,
   `mg236` only on the second. Carries the two missing people onto the form event, asserts nobody
   is lost, deletes the spreadsheet event. Idempotent.
2. `20260825210100_ranged_standings.sql` — adds `year_id` to `v_points_ledger`, filters
   `events.ignored_at`, adds `academic_years.convention_on`, documents the unmatched-sign-in
   tombstone, and creates `member_totals_between(from, to)`.
3. `20260825210200_membership_gapfill.sql` — `gapfill_membership_demographics(jsonb)`: an UPDATE
   with `coalesce`, never an INSERT, so a sign-in can complete an existing member's blanks but can
   never create a member.

### These were validated against a real Postgres

A local PostgreSQL 17.9 container was built with the production schema and seeded with the **real**
Aug 28 attendance. All three applied cleanly and:

- Events on 2025-08-28: 2 → **1**; attendance on the survivor: **75**; `pa30`/`sam35`/`mg236` all present.
- `sum(total_points)`: 79 → **80** after tapping `gbm`. Exactly +1 (that is `mg236`, currently shorted).
- **`sam35` paid 1, not 0** — the migration reads `events.points` rather than hardcoding `0`. Had it
  hardcoded, he would have been silently stuck at zero if the type was tapped first.
- Re-running the reconcile migration changed nothing (idempotent).
- `member_totals_between(null,null)` is **byte-identical** to `v_member_totals` in both directions.
  That equality is the correctness proof for the whole date-range feature.
- Role bonus kept in a window overlapping its year, dropped for a different year.
- Gap-fill: created nothing for a non-member, filled blanks for a member, refused to overwrite.
- RLS: officer sees 75, signed-in non-officer sees **0**, anon denied on function and base tables,
  public leaderboard contract unchanged.
- `ignored_at` fix moves **no numbers in production** — verified there are zero ignored events.

**Expected production result:** `sum(total_points)` stays 1013 immediately after the migrations,
then becomes **1014** once `gbm` is tapped on `e0feb9ac`. Any other number — stop and investigate.

---

## Next phase: dual-role events + an event history

### The design (user-approved, 2026-08-26)

**One point-paying type, plus membership as a separate overlay.** Membership pays 0 points, so it
is purely additive — two point-paying types would make "what is this worth?" ambiguous, which is why
only membership gets this treatment.

Concretely:

- Add **`events.collects_membership boolean not null default false`**. Backfill it true for events
  whose `type_code` is a membership type. It becomes the single source of truth; ingest routing
  stops reading `event_types.is_membership_form`.
- The dashboard keeps the **dashed-outline Membership button exactly as it looks now**, but it
  becomes a **toggle** rather than a type. An event can be `gbm` + membership, or membership alone.
- **At most one membership event per academic year.** Once one is designated, the Membership button
  disappears from other events' rows. Clearing it on the Events screen frees it up again. Enforce
  with a trigger comparing `occurred_on` against `academic_years` (a partial unique index can't work
  — `events` has no `year_id` and the lookup isn't immutable).
  - *Open question for the user:* they said "at most 1 per semester". `memberships` is keyed
    `(netid, year_id)`, so per-**year** is the natural scope. Confirm before enforcing per-semester.

**The retype trigger must be reworked.** Today it deletes attendance whenever an event becomes a
membership form. New behaviour:
- Flipping `collects_membership` **true** → reset `forms.last_response_at` to null (forces the
  poller to replay the full history and harvest demographics) but **keep attendance**.
- Only delete attendance when the event is a *pure* membership form (a membership type, 0 points).
- Note the current trigger is `after update of type_code`, so it will **not fire at all** on a new
  column — replay has to be wired deliberately.

**Ingest change** (`supabase/functions/ingest-checkin/index.ts`): replace the `if (isMembershipForm)
{ … continue; }` fork at `:363-396` with two independent writes — always record attendance unless
the event's type is a membership type, and *additionally* write a `memberships` row when
`collects_membership` is set. Keep the full-replace upsert for membership rows (a membership form
response is a complete statement); keep gap-fill's coalesce semantics for ordinary sign-ins.

**Also update `resolve_unmatched_signin`** (`20260802195206_*.sql:131-199`) — it has the same
either/or fork and needs the same both-paths treatment.

### New Events screen

There is currently **no screen that lists all events** — once typed, an event vanishes from the
dashboard entirely. That invisibility is exactly why the Aug 28 duplicate went unnoticed.

Add a tab showing every event, filterable by year: date, name linked to its Google Form, type
(changeable), membership toggle, attendee count, points paid, and dismissed events shown so they can
be **un-dismissed**. Adding a screen is three edits: a `TABS` entry, a `SCREENS` key, and an
`async function renderEvents(root)`.

Reuse: `renderVolunteering` (`dashboard/index.html:727-806`) is the closest pattern — note it fetches
all counts in **one** aggregate query rather than the N+1 that Needs attention uses. Also reuse
`detailsCard` / `wireCollapsibles` (`:442-468`), `countTag` (`:397`), and the standard
`.scroll > table` markup.

### Audit trail

Today the type-setting write records **nothing** about who did it
(`dashboard/index.html:633`). Add a small log table recording event, old value, new value, officer
email, timestamp — for both type and membership-flag changes. Precedent to follow:
`events.ignored_at`/`ignored_by` (`20260809221613_events_ignored.sql:31-37`), which pairs a nullable
timestamp with a `_by text` officer email and documents both in column comments. `session.email` is
already available in the dashboard and used at `:646`, `:814`, `:1295`.

### Data fixes to run alongside

- `e0feb9ac` → `type_code='gbm'`, `collects_membership=true`. This replays the form and finally
  populates 2025-26 demographics **while keeping everyone's GBM point**.
- Delete `fd68b16e` (the empty `2025 Membership Form`) — *after* removing the form from Drive.
- The other 13 untyped events can be typed freely; none has a backfill counterpart.

---

## Still blocked on the user

1. **The 2026-27 Sign-In Forms Drive folder ID.** Until it is set, the poller watches nothing for
   this year and any GBM form will be invisible. This is the most urgent item.
2. **Rice emails of this year's eboard** for the `officers` allowlist. There is no UI for this — it
   is a SQL insert, and it is the last real violation of the repo's no-manual-changes rule. An
   Officers section in `renderRoles` is the highest-value follow-up not yet built.
3. **A way to apply migrations** (SQL editor access, DB password, or an access token).
4. **Confirm "one membership form per semester vs per year"** before enforcing exclusivity.
5. **Officer-token test** of `directory-lookup` — rejection of non-officers is proven; acceptance of
   a real officer is not.

## Verification once the next phase lands

- Type `gbm` + membership on `e0feb9ac`; within one poller pass (15 min) expect `memberships` rows
  for 2025-26 **and** all 75 attendance rows still present at 1 point each.
- Confirm `class_level` is populated — that is what proves the alias work, since the form asks
  "Year", not "Class Level".
- Confirm the Membership toggle disappears from other events once one is designated, and reappears
  when cleared.
- Confirm a wrongly dismissed event can be restored from the Events screen and its points come back
  (the `ignored_at` ledger fix makes that true for the first time).
- Re-run both test suites; re-confirm `member_totals_between(null,null)` equals `v_member_totals`.

## Housekeeping

Nothing is committed. `git status` shows 8 modified files and 5 new paths (three migrations,
`scripts/test-membership-template.ts`, `supabase/functions/directory-lookup/`). Branch before
committing — the working tree is on `main`.
