# Legacy export manifest

Snapshot of the pre-rebuild schema, taken **2026-07-30** before any destructive change.
Produced by `scripts/export-legacy.mjs` against project `jzxxchjjhkbvfazrbeom`.

The CSVs themselves are **not committed** — they contain member PII (netIDs and names) and are
excluded by `.gitignore`. This manifest and `invariant.json` are committed, because they are what
lets a future reader tell whether the snapshot they hold is complete and untampered.

## Contents

| File | Relation | Rows |
|---|---|---|
| `members.csv` | `Members` | 303 |
| `events.csv` | `Events` | 28 |
| `attendance.csv` | `Attendance` | 840 |
| `event-categories.csv` | `Event Categories` | 3 |
| `e-board-and-chairs.csv` | `E-board and Chairs` | 30 |
| `adjustments.csv` | `Adjustments` | 0 (empty file — the table was genuinely empty) |
| `attendance_staging.csv` | `attendance_staging` | 0 (empty file — the table was genuinely empty) |
| `member_totals_all_time.csv` | view | 303 |
| `attendance_with_details.csv` | view | 840 |

Every count was asserted by the export script against the Phase 0 audit; a mismatch aborts the run
before the lockdown migration.

## The cutover invariant

The rebuilt `member_totals_all_time` must reproduce these numbers **exactly**. Any drift means the
migration is wrong — stop and diff against these CSVs rather than adjusting the target.

```json
{
  "members": 303,
  "total_points": 1013,
  "points_from_events": 901,
  "points_from_adjustments": 0,
  "points_from_role": 112,
  "max_total": 29,
  "zero_point_members": 7
}
```

## Known defects in this data

Carried forward deliberately — the migration preserves them rather than silently fixing them, so
that totals stay reconcilable against this snapshot.

- **86 of 303 members have no first or last name.** They rendered as blank rows on the public
  leaderboard. The rebuilt public view excludes nameless people instead of publishing blanks; they
  remain in `people` with their points intact and surface in the dashboard's Roster screen.
  **85 of the 86 carry into the new schema** — the 86th is the empty-netID junk row described
  below, which is dropped. Elsewhere in the docs the current-system figure is therefore 85.
- **One junk row with an empty-string netID**, no name, and no attendance — it survived only
  because an empty string is a legal primary key. It is the single row the migration drops, which
  is why the new `people` table holds 302 rows rather than 303. It carries 0 points, so the
  1013-point invariant is unaffected.
- **Three "netIDs" are personal-email local parts**, each holding exactly one attendance row. Two
  contain a dot, one ends in digits. The values are not reproduced here, for the same reason the
  CSVs are not committed. They are preserved as recorded. Live
  ingestion will not re-match them — the normalizer rejects non-Rice addresses on purpose — so a
  repeat sign-in lands in `unmatched_signins` for one-click resolution rather than silently
  creating a second identity for the same person.
- **Role bonuses were term-blind.** The old `member_totals_all_time` summed *every* `E-board and
  Chairs` row for a person regardless of term, so the 2 people holding rows in both `F24-S25` and
  `F25-F26` received stacked bonuses. The migration reproduces this (it is part of the 112) by
  writing one `adjustments` row per term, which is also the correct per-year model going forward.

## Data coverage — read before backfilling

The newest event in this snapshot is **`Recruiting 101`, 2025-09-02**. The final three events
(`Fall 2025 GBM 1`, `NSBE x SHPE x SWE Block Party`, `Recruiting 101`) match the columns of
`Fall 2025 Member Points.xlsx`, so that spreadsheet was the last thing imported and was itself
incomplete.

**The gap is roughly a year, not one semester:** Fall 2025 from ~September 2025 onward, plus all of
Spring 2026. Both must be located before `scripts/backfill.ts` is run in anger.

## Reproducing this export

`scripts/export-legacy.mjs` reads through PostgREST with the anon key, which worked only because
the legacy schema granted `anon` SELECT on every base table. **The lockdown migration removes that
access, so this script no longer runs** — that is the intended end state. To re-export after
lockdown, use the service role key or the Supabase SQL editor.
