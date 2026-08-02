# Handoff: dashboard rework (for the next coding agent)

> **Audience note.** `docs/DESIGN.md` and `docs/RUNBOOK.md` are written for a non-technical
> incoming VP. **This file is not.** It is a continuation note for a coding agent picking up
> mid-task, and it should be deleted once the work below is finished and folded into the
> other docs. It is not part of the officer handoff.

*Written 2026-08-01. Updated 2026-08-02: items 1-5 are implemented.*

## What this task is

The officer dashboard (`dashboard/index.html`) was redesigned into a visual direction called
"Crisp". That work is **done**. The follow-up list the user gave after seeing it on their own
machine (force light mode, embed the real logo, rework the Volunteering screen, harden the
paste parser, make the empty Standings dropdowns legible) is **also done as of 2026-08-02**,
and verified against fixtures. What remains is verification against real data, which needs a
human at the Google sign-in prompt. See "Verification" below.

## Already done this session. Do not redo or undo.

- **Visual redesign to "Crisp".** Full-bleed sections separated by hairline rules instead of
  cards. Uppercase letter-spaced column labels. Tabular figures so points columns align.
  Navy (`--accent`, Rice's `#00205b`) appears in exactly three places: the active tab
  underline, primary buttons, and a count that is waiting on someone. This was chosen from
  four generated mockups.
- **All descriptive subtext under section headings was removed at the user's explicit
  request** ("that should be self-explanatory"). Three `p.hint` uses survive and are
  deliberate:
  - the volunteer preview tally ("5 ready · 2 need fixing"),
  - the Standings "N people shown" count,
  - the not-recognised-as-an-officer error, which without its text is a blank screen with
    no way to act.

  If you are tempted to add explanatory paragraphs back, don't. The user removed them on
  purpose.
- **Em dashes removed from all user-visible text**, including `<title>`. Eleven remain in
  code comments only; the user has not asked for those to go.
- **Empty table cells** now render a muted "not set" / "never" instead of a dash, so absence
  does not look like data.
- **`CLAUDE.md` created and committed** (`37891a6`). It carries a Hard constraints section
  recording the single-file rule, the `member_totals_all_time` external contract, and the
  never-rank-sponsorship rule. **This is the repository's only commit.** Everything else,
  including the entire redesign, is still untracked.
- **Verified with fixtures only.** Every screen was rendered in a headless browser against
  injected fixture data, with no console errors on any of the six. It has **never** been
  run against real data.

## Project state (wider than this task)

| Thing | State |
|---|---|
| Phases 0-1 (schema, migrations, RLS) | Applied and verified on the live database |
| Google sign-in | **Now configured.** `google: true`, `email: false`, signup enabled |
| Edge Function `ingest-checkin` | Written, **not deployed** (endpoint returns 404) |
| Apps Script poller | Written, never run. Needs the Drive folder ID |
| Backfill | Written, dry-run tested, never run for real |
| `memberships` table | **Empty.** Nothing has ever written to it. See "Landmine" below |

Live database sanity check, no auth needed:

```bash
curl -s "https://jzxxchjjhkbvfazrbeom.supabase.co/rest/v1/member_totals_all_time?select=rank,first_name,last_name,total_points&order=total_points.desc&limit=3" \
  -H "apikey: <anon key from dashboard/index.html>"
```

Should return three named people with 29, 24 and 22 points, in that order. Anon `SELECT` on
`people` must return 401. If either of those changes, something broke in RLS.

## Landmine: the empty Standings dropdowns are not a bug

The major / gender / class-level filters on Standings open to nothing. This is **a data gap,
not a UI defect**, and it is easy to waste an hour rediscovering.

Those three fields live on the `memberships` table and reach the dashboard through
`v_member_totals` (`supabase/migrations/20260731024941_views_rls_and_public_cutover.sql:82`).
Nothing has ever inserted into `memberships`: no migration does, `scripts/backfill.ts` does
not touch it, and the legacy export only carried `Net ID, First Name, Last Name, status`.
Every value is therefore NULL, and the dashboard's `filter(Boolean)` correctly yields zero
options.

It fills only when the annual membership Google Form is ingested, which requires Phase 3 to
be running: poller live, then an officer tapping "Membership" on that form.

**Consequence worth escalating:** the October deliberation view, which is the entire reason
Standings exists and the thing that decides roughly $800 per sponsored member, cannot slice
by anything until that happens. This is the highest-value blocker in the project and is
worth scheduling ahead of further dashboard polish.

## The work, as approved and as built

Items 1-5 below are the approved plan, verbatim, each followed by what was actually done.

### 1. Light mode only

The user's Mac is in dark mode, and the stylesheet has an `@media (prefers-color-scheme: dark)`
block, so the whole tool renders dark for them. Nothing is broken; the dark palette just exists.

- Delete the entire `@media (prefers-color-scheme: dark)` block from `<style>`.
- Add `color-scheme: light` to `:root`. **This matters more than the block deletion.**
  Without it the browser still renders native `<select>` and `<input type="date">` widgets
  in dark chrome on a light page, because the OS preference is unchanged. Volunteering and
  Adjustments both have date inputs, so it would be visible.
- Leave `--bg: #fff`. The logo's background is transparent (palette index 0 has alpha 0), so
  it is built to sit on white and matches with no further change.

**Built as specified.** Confirmed by rendering with the browser context forced to
`colorScheme: dark`: `body` background stays `rgb(255,255,255)` and the computed
`color-scheme` on `:root` is `light`, so the native date pickers come back light too.

### 2. Real logo, embedded

- Move `SHPE_logo_horiz_Rice-University_CMYK-1.png` (repo root) to `dashboard/logo.png`.
  It stays in the repo as the re-encoding source; the page will not reference it.
- Encode into the existing `LOGO` constant: `base64 -i dashboard/logo.png`.
  ~25KB becomes ~34KB base64; `index.html` goes from ~36KB to ~70KB.
  A data URI was chosen over `<img src="logo.png">` specifically to preserve the
  single-dependency-free-file rule, so do not "simplify" it back to a file reference.
- Delete `LOGO_FALLBACK` and simplify `logoMark()`. Once the real logo is embedded the SVG
  placeholder is dead code.
- Header shows **the logo alone**, no wordmark. Remove `<h1>SHPE Points</h1>` from the header.
  The lockup already reads "SHPE … Rice University", so a wordmark repeats it. Keep an
  accessible name via `alt="SHPE Rice"` plus a visually-hidden `<h1>`.
- CSS: `.logo` goes from a 26×26 square to `height: 26px; width: auto`. At the lockup's
  1920×388 aspect that lands around 129px wide. Sign-in uses ~180px, centered.

**Built as specified.** The header logo measures 129×26 and sign-in 180×36, both as predicted.
The accessible name is `alt="SHPE Rice"` plus an `.sr-only` `<h1>` on both the header and the
sign-in screen, so the document still has a heading.

*Added 2026-08-02:* the **favicon** is the SHPE emblem, inlined the same way from
`dashboard/shpe-emblem-transparent.png`. It is downscaled to 64px first, which draws sharply
on a retina tab (32 physical pixels) for 6KB, rather than embedding the 709px original for
73KB. With both images inlined `index.html` is 85KB.

### 3. Volunteering screen rework

`renderVolunteering()` already fetches
`events?type_code=eq.volunteer&select=id,name,occurred_on&order=occurred_on.desc&limit=25`
and then uses it only to populate a `<select>`. The history is fetched and discarded.

- **Section 1, Create a volunteer event.** Unchanged. Stays visible; it is three controls.
- **Section 2, Volunteer events.** Render the history as a table: date, name, people
  recorded, total hours. Clicking a row selects that event.
  - Fetch the counts in **one** query: `attendance?event_id=in.(...)&select=event_id,hours`,
    then aggregate client-side. The Needs-attention screen uses a per-row `Promise.all`
    pattern for its counts. **Do not copy it here** — this list runs to 25 rows.
- **Section 3, Enter hours.** Hidden until an event is selected. Selection happens by
  clicking a history row, or automatically after creating a new event. This replaces the
  `<select>` entirely. Show which event is active plus a way to deselect.
  - *Revised 2026-08-02:* deselecting is clicking the selected row again, not a button. The
    active event is named beside the "Enter hours" heading. There is no "Change event"
    control; the row is the toggle.
- Keep the selection in `state` (e.g. `state.volunteerEventId`), not a local, so it survives
  the `show('volunteering')` re-render after Commit. Keep it selected after committing so
  the officer can confirm and add more.

**Built as specified, with three things worth knowing:**

- Selecting an event is a DOM update, not a re-render, so a paste already in the textarea
  survives clicking a different event. A full re-render would have thrown it away.
- The selected row is marked with weight and a sunken fill rather than colour. Navy is spent
  on the active tab, the primary button and a waiting count; a fourth use would dilute it.
- If the selected event falls outside the 25 most recent (an officer backfilling something
  from last semester), it is fetched by id so hours entry still works. The table is left
  alone rather than having an out-of-order row prepended to it.

### 4. Paste hardening

Pasting two columns from Google Sheets **already works today** — confirmed by reading the
parser. It splits on newline, then on tab or comma, and Sheets puts tab-separated text on the
clipboard. Three edge cases need fixing, two of which produce a silently wrong number rather
than an error. For data that converts to money, wrong is far worse than rejected.

Current parser: `value.split('\n')` → `line.split(/[\t,]/)` → `[rawId, rawHours]`.

- **Split on tab when a tab is present; fall back to comma only when there is none.** Fixes
  `1,5` silently becoming `1`. Sheets always uses tabs, so the comma path only serves
  hand-typed input.
- **Handle three or more columns** (e.g. name, netid, hours). Pick the field matching the
  netid/email shape and the last field that parses as a number, instead of blindly taking
  fields one and two.
- **Skip an obvious header row** (`/^net\s*id/i`, or a second field of `hours`) rather than
  showing it as an error the officer deletes by hand.
- Everything still routes through the existing Preview. **Do not weaken Preview** — it
  resolving every netID before any write is what makes these parser changes safe.

  *Superseded 2026-08-02 at the user's request: "remove the preview option, it doesn't really
  serve any purpose."* The **button** is gone; the **check is not**. Rows are now resolved
  against `people` as they are typed, debounced 300ms, and Commit stays disabled until every
  row passes. The safety property the instruction above was protecting is intact and now costs
  no clicks. **Do not remove the check itself.** Without it a typo either fails the whole batch
  or writes an orphan row, and these numbers turn into an $800 sponsorship decision.

**Built as specified.** The parser is now a named `parsePaste()` with `NETID_LIKE`,
`isHeaderRow()` and `hoursValue()` beside it, rather than four lines inside the Preview
handler, because these are the rules that decide whether a number is right. Two decisions the
plan left open:

- **`1,5` is read as 1.5, not rejected.** Once the row is split on tabs, `1,5` in an hours
  column has no other plausible meaning: it is a Sheet in a European locale. Only one or two
  digits may follow the comma, so `1,500` stays ambiguous and is still rejected.
- **netIDs may contain dots.** `NETID_LIKE` allows `.`, `-` and `_` after the first letter.
  Without it, a real dotted identifier on this roster failed the shape test and its row lost its
  identifier. This was caught in testing and is the reason the shape test is not stricter.

The identifier is taken from an email if the row has one, otherwise from the netID-shaped
field **closest to** the hours, which is what makes `Diego,Rico,dr56,3` resolve to `dr56`
rather than `Diego`.

### 5. Standings: make the empty dropdowns legible

- When a facet has zero options, disable that `<select>` and give it one option reading
  "No membership data yet".
- This is a control label, not the descriptive subtext that was deliberately stripped. It sits
  close to that instruction, so it was flagged to the user and approved. Easy to drop.

**Built as specified.** The placeholder option carries `value=""`, so `draw()` reads an empty
string from a disabled facet and filters nothing out. Giving it a visible value instead would
have quietly hidden every person on the screen.

## Also fixed along the way

`api()` called `res.json()` on every response that was not a 204. PostgREST answers a write
with **201 and an empty body** unless asked for a representation, so `JSON.parse` threw on
success and `guard()` showed the officer a red toast after an insert that had actually
worked. It now returns `null` for an empty body. This affected every write on every screen:
creating an event, committing hours, adding a role, recording an adjustment. It had not been
noticed because nothing had ever been run against the live API.

## Verification

**Done, against fixtures.** All six screens render with no console errors or page errors, with
the browser forced to dark. Checked mechanically: light mode holds, logo geometry, the
volunteer counts arriving in one `attendance?event_id=in.(...)` request rather than 25, the
select/deselect/paste-survives-reselect flow, the three disabled facets, and no horizontal
overflow at 1440px. `parsePaste()` was unit-tested over 17 cases including header rows,
three- and four-column pastes, emails, `1,5`, `1,500` and the three long real netIDs.

**Not done: anything against real data.** Every step below needs a human at the Google
sign-in prompt. Google sign-in works now, so this can meet real data for the first time.

1. Serve `dashboard/` on :8080 (`python3 -m http.server 8080 --bind 127.0.0.1`) and sign in
   as `dr56@rice.edu`, which is already on the `officers` allowlist.
   - `http://localhost:8080/**` must be in Supabase → Authentication → URL Configuration →
     Redirect URLs, or the OAuth round trip lands somewhere else.
2. **With the Mac still in dark mode**, confirm the page is light, including the native date
   pickers on Volunteering and Adjustments. This is the actual reported bug.
3. Confirm the logo renders sharp at header size and sits flush on white.
4. Walk all six screens against the real 302 people / 840 attendance rows. Watch for layout
   breaks on the three long personal-email identities described in DESIGN.md, which the
   fixtures did not cover. Sort Standings by netID length to find them.
5. Volunteering: create an event, confirm it appears in history, click a row, paste two
   columns from a real Google Sheet, Preview, Commit, re-check the counts.
6. Paste regressions: a header row, a three-column paste, and a `1,5` value. First is
   skipped, second parses correctly, third yields 1.5.
7. Standings dropdowns read "No membership data yet" rather than opening empty.

## Where things live

- `dashboard/index.html` — the whole dashboard. One file, no build step, no dependencies.
  This is a documented hard constraint, not an accident. See `CLAUDE.md`.
- `~/.gstack/projects/shpe-points/designs/needs-attention-20260801/` — the four generated
  mockups plus `approved.json` recording variant B ("Crisp") as chosen. Useful if you need
  to see the intended look.
- `/Users/diego/.claude/plans/why-is-it-all-distributed-plum.md` — the approved plan this
  file was generated from.

## User preferences observed this session

- Wants questions asked during design rather than structure proposed early.
- Wants simple, plain, clean, polished, with only a slight touch of Rice or SHPE color.
- Dislikes explanatory subtext in the UI. Things should be self-evident.
- Dislikes em dashes.
