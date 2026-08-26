# SHPE Points System — Design & Implementation Plan

> ## Current status — read this first
>
> *Last updated: 2026-08-25.*
>
> **The system is live end to end.** The poller runs under the shared Gmail, the Edge Function
> ingests, points flow, and the dashboard is deployed. The live database holds 331 people, 1245
> attendance rows and 42 events spanning 2024-08-28 to 2026-04-16.
>
> ### What changed on 2026-08-25
>
> - **The 2025-08-28 duplicate is reconciled.** The legacy spreadsheet import and the poller both
>   produced an event for that GBM (the poller pulls a form's *entire* history on first discovery,
>   and the backfill range reached to 2025-09-02). 72 people appeared on both. The form-backed event
>   survives; see `migrations/20260825210000_reconcile_aug28_duplicate.sql` for the audit trail.
> - **The membership template is no longer exact-match.** It now accepts normalized title aliases,
>   and recovers `class_level` from the *answer* against a closed vocabulary. See "Where the line is
>   drawn" in `functions/_shared/membership-template.ts` — the previous rule would have left class
>   level blank for the entire chapter, because every real form asks "Year", not "Class Level".
> - **Sign-in forms now gap-fill demographics**, filling only NULL columns on membership rows that
>   already exist. A sign-in can never create a member: membership stays something you opt into by
>   filling the form, so the Roster chase-list stays meaningful.
> - **Standings takes a date range**, computed by `member_totals_between(from, to)` in SQL rather
>   than in the browser — PostgREST caps responses at 1000 rows and the ledger is already past that,
>   so client-side aggregation would silently under-report.
> - **New Edge Function `directory-lookup`**, JWT-gated *and* `is_officer()`-gated. `verify_jwt`
>   alone is not a gate: the anon key embedded in the dashboard is itself a valid project JWT.
>   Verified live — anon key → 401, valid non-officer JWT → 403.
>
> ### Still outstanding
>
> - **2026-27 has no `forms_folder_id`.** The poller is watching nothing for the current year.
>   This blocks the first GBM and is the single most urgent item.
> - **The officer allowlist holds one person.** Adding this year's eboard is still a SQL insert;
>   an Officers section in the dashboard is the highest-value remaining piece of the
>   no-manual-changes rule.
> - **`memberships` is empty** until the 2025-26 form is moved into a polled folder and typed.
> - **`app_config.leaderboard_window_start` is `''`**, so the public leaderboard mixes 2024-25 and
>   current-year points. The reset policy is still officers' to decide.
>
> **Context on the author:** Diego built the current system but is no longer an officer. This is
> explicitly a handoff artifact for the next VP, who is not necessarily technical. When trading off
> cleverness against something a non-technical successor can operate, the successor wins.

## Context

Rice SHPE awards members points for attending events. Those points are the main input to deciding who the chapter sponsors for the SHPE National Convention (~Oct 30 each year) — roughly $800/person covering flight, housing, and registration. The stakes make accuracy and auditability non-negotiable.

**Today's workflow:** an officer opens Supabase, pastes a column of netIDs from a Google Form response sheet into a staging table, creates an event row, runs the increment, then clears staging. Everything happens inside the Supabase UI.

**Three problems with that:**

1. **It doesn't survive handoff.** The next VP is not necessarily technical. Pasting into staging tables and clearing them is a SQL-adjacent ritual nobody will want to inherit, and there is no artifact documenting it.
2. **The roster goes stale.** Members graduate every year; some return as grad students. Nothing expires membership or handles return, so the roster drifts and has to be manually corrected.
3. **Identity is never normalized.** Every attendance form asks for a netID *or* a Rice email, and either answer yields the netID (it's the local part of the address). But nothing normalizes them, so `Fall 2025 Member Points.xlsx` holds `mac50` next to `dea7@rice.edu` in one column. The data is recoverable, not corrupt — but every join and dedup re-derives it by hand, and typos have nothing catching them.

## The goal

**Officers should not think about points at all.** Their job is to create a Google Form for an event and distribute it. Everything downstream — attendance ingestion, point awards, the public leaderboard — updates itself.

This is the organizing constraint of the whole design. The system does everything it can infer on its own, and asks an officer for exactly one thing it cannot: **the event's type.** That single tap happens in the dashboard on an event the system already found by itself.

Critically, that tap is never blocking. Attendance ingests immediately at 0 points; assigning the type later retroactively awards points to everyone already recorded. Forgetting delays points, it never loses them.

**We do not build a leaderboard.** The webmasters who run shpe.rice.edu build and own that. Our deliverable is a documented, stable, public read API they can point at so their leaderboard refreshes itself.

### Decisions already made (from discovery)

| Question | Decision |
|---|---|
| Point values | GBM = 1; career = 2; social = 2; company = 2; volunteering = 1 pt per hour |
| Volunteer hours | Entered manually by officers in the dashboard (netID + hours table). Sign-up sheets are never parsed — no standard format exists |
| Reset / cycle policy | **Deferred.** Ship all-time accumulation with a configurable date-window filter |
| Retroactive membership | Yes — record attendance for anyone; compute eligibility separately |
| Roles | Manually set once a year after elections; bonuses apply only to that year |
| Role bonuses | eboard +5, chairs +3 (approximate — must be configurable) |
| Sponsorship | System must **not** recommend anyone. Officers deliberate by gender × major |
| Public leaderboard | Built by webmasters. We expose name + points via API. Nothing else public |
| Officer auth | Google sign-in, allowlist of officer emails |
| Hosting | Static host (Vercel) under the shared Gmail |
| Forms | Shared Gmail account, shared Drive, all officers have access |
| Backfill | Spring 2026 must count toward the Oct 2026 convention; source uncertain |

### Explicit non-goal

**The system must never rank or suggest who to sponsor.** Sponsorship depends on constraints points can't see: housing is rooms of 4 same-gender, and the chapter wants at least one student per major so it can apply to each department for cost-sharing. Members effectively compete within gender × major cohorts. The tool gives officers a *lens* — sliceable standings — and gets out of the way.

---

## Architecture

```
  Officer                Student                    Webmasters
     │                      │                            │
     │ creates form,        │ fills it out               │ build leaderboard
     │ shares it            │                            │ at shpe.rice.edu
     ▼                      ▼                            │
┌─────────────────────────────────┐                      │
│   Shared Google Drive           │                      │
│   SHPE Forms/  (one flat folder,│                      │
│                as today)        │                      │
└───────────────┬─────────────────┘                      │
                │                                        │
        ┌───────▼────────┐                               │
        │  Apps Script   │  ONE time-driven trigger      │
        │  (shared Gmail)│  every 15 min:                │
        │                │  · discover new forms         │
        │  poller        │  · pull new responses         │
        └───────┬────────┘  · push to Supabase           │
                │                                        │
                │ POST + shared secret                   │
                ▼                                        │
   ┌──────────────────────────────────────┐              │
   │  Supabase (jzxxchjjhkbvfazrbeom)     │◄─────────────┘
   │  Edge Function → immutable ledger    │  documented public
   │  RLS: anon reads ONLY the public view│  read API (anon key)
   └──────────────┬───────────────────────┘
                  │ authenticated, allowlisted
                  ▼
        ┌──────────────────────┐
        │  Officer Dashboard   │  one tap per event
        │  static HTML, Vercel │  (set type), plus
        └──────────────────────┘  exceptions & standings
```

**Why Supabase stays the system of record rather than moving to Sheets + Apps Script:** spreadsheets are human-editable, and one careless column sort scrambles a roster irrecoverably. For data that decides $800 awards, writes should go through a narrow door. Supabase also already serves the existing public read path, and Postgres views give the webmasters a stable contract.

**Why the dashboard is a single dependency-free HTML file:** the legitimate objection to a custom dashboard is "who maintains it when nobody is technical?" A file with no npm, no build step, and no framework has nothing to rot. `SHPE_Leaderboard_Setup_Instructions.md` already proves the pattern — vanilla `fetch` against Supabase's REST API. A file that worked in 2026 works identically in 2031.

---

## Core design principles

**1. Nobody is ever deleted; membership is a per-year opt-in that expires by default.**
`people` is permanent. `memberships` is one row per person per academic year. Someone who doesn't fill this year's form simply isn't active this year — no officer removes them. A grad student returning in 2028 fills the form and reappears with history intact. *Graduation stops being an event anyone processes.*

**2. Points are never reset; "reset" is a date filter.**
Nothing is mutated or cleared. Every total is `SUM(points) WHERE date BETWEEN x AND y`. This is what lets the reset policy stay undecided at zero cost — the active window is a config row, so when officers settle it, it's a one-field change with no migration, reversible.

**3. Points are snapshotted on the attendance row, never looked up from the event.**
Required by volunteering (two people at one event earn different amounts), and it stops next year's point-value changes from rewriting last year's history.

**4. Because totals are derived, guessing wrong is cheap.**
This is what makes full automation safe. The system never increments a stored total, so if it misclassifies an event, an officer changes the type later and every affected total recomputes instantly. That means ingestion never has to block on human confirmation — it can act on its best guess immediately and let corrections happen asynchronously. *A system that must be confirmed is a system that stalls when nobody confirms.*

---

## Input pipeline — the heart of this design

### Officer workflow, end state

1. Create a Google Form **while signed in as the shared Gmail**, in the shared Drive folder — one flat folder, exactly as today. Title it the event name.
2. Share it with members.
3. Within 15 minutes it appears in the dashboard as a detected event. **Tap its type once.**

Points then flow forever without further attention. No response spreadsheet, no export, no linking — see below.

Volunteering is the sole exception, and it doesn't involve a form at all.

### Detect-then-classify

The poller finds new forms on its own — the officer never registers anything, pastes a link, files into a subfolder, or follows a title convention. The system infers everything it can:

| Field | Source |
|---|---|
| Event name | Form title |
| Event date | First response timestamp (falls back to form creation date) |
| Attendees | Form responses |
| **Event type** | **The one thing an officer supplies — one tap** |

Type genuinely cannot be inferred. Title keywords can't distinguish a career event from a social one, and a wrong guess silently misprices an event that feeds an $800 decision. So the system doesn't guess: it asks once, in the one place an officer can answer in a second.

**Classification never blocks ingestion.** A detected event starts with `type_code = NULL`; attendance ingests immediately at 0 points. Assigning the type retroactively awards points to everyone already recorded, because totals are derived rather than incremented (principle 4). An officer who goes three weeks without opening the dashboard loses nothing — the points simply materialize when they do.

**Optional accelerator:** if the club ever wants to skip even that tap, `event_types.drive_folder` lets a typed subfolder auto-classify anything filed inside it. Off by default — documented in the runbook, not required, and the flat folder stays the supported path.

#### Rejected alternatives (do not re-propose without new information)

| Approach | Why not |
|---|---|
| **Guess type from form title keywords** | Rejected outright by Diego. Titles are freeform, and career vs. social is frequently indistinguishable from a title. A silent misclassification misprices an event feeding an $800 decision. |
| **Typed Drive subfolders as the primary mechanism** | The club deliberately keeps all forms in one flat folder and prefers to keep it that way. Survives only as the optional accelerator above. |
| **Title prefix convention** (`[CAREER] …`) | Deterministic, but the title is member-facing, and it's forgettable in a place nothing catches. |
| **Template-per-type with an embedded marker** | Markers are destroyed by ordinary form editing, and after the fact there's no way to tell which template a form came from. |
| **Officer pastes the form link into the dashboard** | Diego's own suggestion, superseded: the poller already discovers forms, so asking an officer to supply the link is work the system can do itself. Only the type is genuinely un-inferrable. |
| **Registry spreadsheet of form links + types** | A second surface competing with the dashboard, and it reintroduces spreadsheet fragility for no gain. |

### How Google Form responses are actually read (no spreadsheets involved)

Worth stating explicitly, because it determines what officers have to do:

- **Google Forms store responses inside the form itself.** A response *spreadsheet is not created automatically.* One exists only if someone manually clicks **Responses → Link to Sheets**, and many forms never get one.
- **This pipeline never touches a spreadsheet.** Apps Script reads responses directly from the form:
  ```js
  const form = FormApp.openById(formId);
  const newOnes = form.getResponses(lastSeenTimestamp);  // only what's new
  newOnes.forEach(r => {
    r.getTimestamp();
    r.getItemResponses().forEach(ir => {
      ir.getItem().getTitle();   // question text
      ir.getResponse();          // the answer
    });
  });
  ```
- Forms are discovered in Drive by MIME type:
  ```js
  DriveApp.getFolderById(FOLDER_ID).getFilesByType(MimeType.GOOGLE_FORMS)
  ```
- **Consequences:** officers never link, export, or standardize a sheet. Existing forms work retroactively, since `getResponses()` returns the full history — a form created a year ago yields all its responses on first poll. And if someone *does* link a sheet for their own convenience, it's harmless; we ignore it.

> **Requirement worth flagging:** `FormApp.openById()` needs the script's owning account to have **edit** access to the form. Forms must therefore be created while signed in as the shared Gmail (or explicitly shared with it as an editor). A form created under an officer's personal account and merely link-shared will be silently unreadable. The poller must detect this case and surface it in "Needs attention" rather than skipping quietly — this is the most likely way an officer accidentally breaks ingestion, and it must fail loudly.

### One poller, not per-form triggers

A standalone Apps Script project owned by the shared Gmail runs **a single time-driven trigger every 15 minutes**:

1. **Discover** — scan the shared forms folder for Google Forms. Register any new one: `form_id`, title → event name, first response → event date. Create the event row with `type_code = NULL`, awaiting one tap.
2. **Poll** — for each registered form, `FormApp.openById(id).getResponses(afterTimestamp)` using the stored high-water mark, so each pass only fetches what's new.
3. **Push** — POST new responses to the Supabase Edge Function with a shared secret.

> **Why polling instead of `onFormSubmit` triggers:** Apps Script caps installable triggers at **20 per script per user**. With ~40 events a year, per-form triggers would silently stop being installable partway through the fall — the exact kind of quiet failure that kills a system between officer generations. One time-driven trigger scales to unlimited forms and has no ceiling.
>
> A second benefit: polling is *self-healing*. If Supabase is down or the script errors, the high-water mark doesn't advance, and the next pass picks up everything it missed. A dropped `onFormSubmit` event is gone forever.

The same trigger pings Supabase each pass, which incidentally prevents free-tier auto-pause. The project *had* auto-paused before this work began — precisely the silent decay this avoids.

### Finding the identity answer in an arbitrary form

Officers write their own forms, so the script can't assume a fixed question. Resolution order:

1. Question title matches `/net\s*id|netid|rice email|email/i`.
2. Otherwise, any answer matching `^[a-z0-9]+$` or `^[a-z0-9._%+-]+@rice\.edu$`.
3. Normalize: lowercase, trim, strip `@rice.edu`. `mac50` and `dea7@rice.edu` both resolve to clean netIDs.
4. Unresolvable → `unmatched_signins`, fixable in one dashboard click. Never silently dropped, never a phantom person.

A **template form** lives in the Drive folder for officers to copy, which guarantees a well-formed netID question. Ingestion stays tolerant of hand-made forms so nothing breaks when someone forgets.

### Getting a name from a netID

A sign-in carries a netID and usually nothing else, so a first-time attendee lands in `people` with a netID and no name. Every one of those used to be manual work: an officer looked the person up and typed first and last into the dashboard.

Rice already answers this question. `search.rice.edu` — the public people search — has a JSON backend that takes a netID and returns the person:

```
GET https://search.rice.edu/json/people/p/0/0/?q=dr56
→ {"stats": {"count": "1"},
   "results": [{"netid": "dr56", "name": "Diego Rico", "college": "Wiess College",
                "major": "Computer Science", "year": "Senior", ...}]}
```

No authentication, no API key, no VPN, no campus network. `supabase/functions/_shared/directory.ts` wraps it, and `ingest-checkin` calls it for anyone in a batch who has no name. Read that module's header before touching it; the important parts:

- **The endpoint is a fuzzy full-text search, not a key lookup.** `?q=lee` returns 302 people because it matches the surname. So the module never takes `results[0]`. It requires exactly one result whose own `netid` field equals the netID asked for, and returns nothing otherwise. This is the same posture as netID resolution itself: a person with no name is visible and one click from fixed, a person with *someone else's* name is invisible and wrong.
- **It fills blanks, it never overwrites a human.** Both the Edge Function and the backfill script guard their write on `first_name` and `last_name` still being null. A name an officer typed wins over the registrar's, because someone may go by a name the registrar doesn't have and they told an officer which.
- **It cannot fail a pass.** Every error path — outage, timeout, malformed body, ambiguity, write failure — is swallowed and leaves the person nameless. Attendance is the thing that has to land.
- **Not everyone resolves.** Students can suppress their directory listing through ESTHER under FERPA, and those return zero results permanently. Manual name entry in the dashboard stays for exactly this reason. Deleting it would strand those members.
- **The endpoint is undocumented and `robots.txt` disallows `/json/`.** That directive is aimed at crawlers, and a lookup fired the first time a netID appears is not crawling — but keep it that way. Answers are cached permanently by being written to `people`, so nobody is ever looked up twice, and bulk passes are sequential and capped. Do not build anything that walks the directory. If Rice changes or removes the endpoint, the system degrades to the manual entry it had before, which is why nothing depends on it succeeding.

`node scripts/test-directory.ts` checks the verification rule and doubles as a canary on the endpoint — no framework, no credentials, no database. If its live checks start failing while the stubbed ones pass, Rice changed something, not us.

The existing pile of nameless people is cleared with `node scripts/backfill-names.ts` (dry run by default, `--commit` to write). That script also covers the paths ingestion doesn't own — a sign-in attached by hand, a netID typed into the volunteer grid — so it is worth re-running occasionally rather than once.

The same payload also carries `college`, `major`, and `year`, which are three of the six fields `membership-template.ts` collects. Those are deliberately **not** read. That module's whole design is exact-match-or-nothing because a wrong major corrupts the number behind an ~$800 sponsorship decision, and sourcing demographics from the registrar instead of the member's own form is a separate decision that should be made on purpose, not inherited from a name lookup.

### Volunteering — fully manual, entered in the dashboard

Volunteer sign-ups live in ad-hoc sheets with no consistent format, so the system does **not** try to read them. Parsing arbitrary spreadsheets would fail unpredictably and quietly, which is the worst possible failure mode for data that converts to money.

Instead, volunteering is the one place an officer creates the event directly:

1. **Create volunteer event** in the dashboard — name and date. Marked `source = 'manual'`, so the poller ignores it.
2. **Enter hours in a table** — two columns, netID and hours. The grid accepts typed rows *and* **pasted tabular data**: an officer can select two columns in whatever sheet they used and paste. The grid parses TSV, so it works from Google Sheets, Excel, or Numbers without any standard format.
3. **Preview** — every row resolves to a person by netID before anything is written. Unrecognized entries are shown inline and can be corrected in place, so a typo is caught at entry rather than becoming an unmatched row later.
4. **Commit** — writes attendance rows with `points_awarded = hours`, `source = 'manual'`.

Hours are never self-reported, per your decision. Editing a row later rewrites that attendance row and totals recompute — no reconciliation needed.

### Membership form

Detected like any other form. The officer taps its type as **Membership**, which routes it to `memberships` instead of attendance — the annual form's answers (class level, grad year, gender, major, college, birthday) become that year's membership records automatically. Once a year, one tap.

---

## Public read API (deliverable for webmasters)

We expose data; the webmasters build the UI.

- **Endpoint:** `GET https://jzxxchjjhkbvfazrbeom.supabase.co/rest/v1/member_totals_all_time?select=rank,first_name,last_name,total_points&order=total_points.desc`
- **Auth:** anon key in the `apikey` header (public by design, safe only because RLS is correct).
- **Fields:** `rank`, `first_name`, `last_name`, `total_points`. Nothing else — no netid, email, birthday, gender, major, or college.
- **Honors** `app_config.leaderboard_window_start`, so the deferred reset policy applies to the public leaderboard automatically with no webmaster involvement.

> **Compatibility constraint:** the existing page (`SHPE_Leaderboard_Setup_Instructions.md:118`) already queries `member_totals_all_time` selecting exactly `first_name,last_name,total_points`. Rebuilding that view on the new ledger is fine; renaming it or dropping those columns silently breaks the live site. Keep the name and superset the columns.

**Deliverable:** a short API doc for the webmasters — endpoint, key, field list, caching guidance, CORS notes, and a worked `fetch` example. Not a leaderboard.

---

## Schema

All new tables in `public`. Net IDs normalized on write.

```sql
people                      -- permanent. never deleted.
  netid              text primary key
  first_name         text not null
  last_name          text not null
  created_at         timestamptz default now()

academic_years
  id                 text primary key      -- '2025-26'
  starts_on          date not null
  ends_on            date not null

memberships                 -- the per-year opt-in. attributes live HERE, not on people.
  id                 bigserial primary key
  netid              text references people
  year_id            text references academic_years
  class_level        text
  expected_grad_year int
  gender             text
  major              text
  college            text
  birthday           date
  submitted_at       timestamptz
  unique (netid, year_id)

roles                       -- manually set once a year after elections
  netid              text references people
  year_id            text references academic_years
  role               text not null          -- 'eboard' | 'chair'
  position_title     text
  primary key (netid, year_id, role)

role_bonus_config           -- configurable, NOT hardcoded
  year_id            text, role text, points numeric not null
  primary key (year_id, role)

event_types
  code               text primary key       -- gbm|career|social|company|volunteer|membership
  default_points     numeric
  is_variable_points boolean default false  -- true only for volunteer
  is_membership_form boolean default false  -- routes to memberships, not attendance
  drive_folder       text                   -- OPTIONAL auto-classify accelerator; null by default

forms                       -- discovered Google Forms
  form_id            text primary key
  event_id           uuid references events
  last_response_at   timestamptz            -- high-water mark for polling
  discovered_at      timestamptz default now()

events                      -- auto-created on form discovery, or manual for volunteering
  id                 uuid primary key default gen_random_uuid()
  name               text not null          -- from form title, or typed for manual
  type_code          text references event_types   -- NULL = awaiting the type tap
  occurred_on        date not null
  points             numeric                -- defaults from type; overridable
  source             text not null          -- 'form' | 'manual'  (manual = poller ignores)
  created_by         text
  created_at         timestamptz default now()

attendance                  -- immutable ledger. one row per person per event.
  id                 bigserial primary key
  event_id           uuid references events
  netid              text references people
  points_awarded     numeric not null default 0   -- SNAPSHOT at recording
  hours              numeric                       -- volunteering only
  source             text                          -- 'form' | 'manual' | 'backfill'
  recorded_at        timestamptz default now()
  unique (event_id, netid)

adjustments                 -- role bonuses AND manual corrections
  id                 bigserial primary key
  netid              text references people
  year_id            text references academic_years
  points             numeric not null
  kind               text not null           -- 'role_bonus' | 'manual'
  reason             text not null           -- REQUIRED
  created_by         text
  created_at         timestamptz default now()

unmatched_signins
  id                 bigserial primary key
  event_id           uuid references events
  raw_identifier     text
  raw_payload        jsonb
  resolved_netid     text references people
  resolved_at        timestamptz

officers                    -- dashboard access allowlist
  email              text primary key
  display_name       text
  active             boolean default true

app_config
  key text primary key, value text
-- 'leaderboard_window_start' -> '' (all-time) or a date
-- 'current_year_id'          -> '2026-27'
```

### Design notes

- **Role bonuses are `adjustments` rows, not a computed column.** Visible, auditable, filterable, and *excludable*. You want to see whether eboard members are consistently missing events; you can't if a +5 is baked into an opaque total. A unique index on `(netid, year_id)` where `kind='role_bonus'` makes re-applying idempotent.
- **Gender, major, and class level live on `memberships`.** People change majors. Deliberating in October 2027, you want the 2027 form's answers.
- **Attendance is recorded for anyone who signs in,** member or not. Eligibility is computed at query time. Nobody is turned away at the door; retroactive membership backfills automatically.
- **`events.type_code` is nullable on purpose.** Unclassified events still ingest attendance at 0 points. Data is never lost waiting on a human.

### Views

```sql
v_points_ledger      -- attendance ∪ adjustments (netid, occurred_on, points, kind, label)
v_member_totals      -- ledger aggregated, joined to current membership for slicing
member_totals_all_time  -- PUBLIC. preserve existing contract. window-aware.
```

### RLS

Currently unaudited — **first thing to check.** The anon key is published in plaintext on a public page, so RLS is the only thing between the internet and member PII. Once memberships carry gender, birthday, and major, the exposure gets materially worse.

- Revoke `anon` from every base table.
- `anon` gets `SELECT` on `member_totals_all_time` only.
- Officer policies gate on `(auth.jwt() ->> 'email') IN (SELECT email FROM officers WHERE active)`.
- Only the Edge Function writes `attendance`, via `service_role`.

---

## Officer dashboard — supervision, not data entry

Since discovery and ingestion are automatic, the dashboard is not a data-entry surface. It exists to collect the one un-inferrable field per event, handle exceptions, and support the one conversation that actually matters in October.

| Screen | Purpose | Frequency |
|---|---|---|
| **Needs attention** | Newly detected events awaiting a type tap, unmatched sign-ins, forms the script can't open for lack of edit access. The only screen anyone routinely opens. | Per event, ~10 sec |
| **Volunteering** | Create a volunteer event, then a netID + hours table accepting typed rows or a paste from any spreadsheet. Preview resolves every netID before committing. | Per volunteer event |
| **Standings** | Deliberation view: date-range filter, slice by major / gender / class year, toggles for exclude-eboard and exclude-role-bonuses. **Presents data; recommends nobody.** | October |
| **Roster** | This year's memberships; who hasn't filled the form. | Occasional |
| **Roles** | Set eboard/chairs after elections; edit bonus values; apply bonuses (idempotent). | Once a year |
| **Adjustments** | Manual points. Reason required, author recorded. | Rare |

Success looks like: "Needs attention" holds one row per new event, an officer taps a type in about ten seconds, and the queue is empty again. Nothing else demands attention until October.

The Roster screen surfaces form-completion gaps deliberately: anyone without a membership record has points but **no gender or major**, so they can't be placed in the deliberation grid. That gives the next VP a self-interested reason to chase form completion — far more durable than a documented instruction to keep the roster clean.

---

## Backfill (one-time)

Spring 2026 must count toward the Oct 2026 convention. Source is uncertain — some mix of Drive form responses, existing Supabase rows, and spreadsheets.

A **local script** (`scripts/backfill.ts`), not dashboard UI — it runs once, by someone technical.

- Accepts **wide spreadsheets** (member rows × event columns — the `Fall 2025 Member Points.xlsx` shape: `First Name, Last Name, Net ID, Total Points, GBM #1, Block Party, Recruiting 101`) and unpivots them into attendance rows.
- Accepts **form-response CSVs** (one row per sign-in).
- Reuses the same netID normalizer as live ingestion, so historical and live data agree.
- **Preview → confirm → commit.** Prints a full diff before writing.
- Tags every row `source = 'backfill'`, permanently distinguishable from live data.

---

## Repository location

New folder: **`/Users/diego/dev/shpe-points`**, its own git repo.

*Not* reusing `dev/shpe-automation` — despite the name, that folder holds the resume-book tooling (`merge_resume_with_formatted.py`, `merge_resumes.py`, `Resumes/`, two generated PDFs), which is a separate, still-useful annual workflow. Nothing there is stale points code, so there's nothing to delete. Keeping them apart matters here because the points system gets its own deploy, its own secrets, and a handoff doc written for a non-technical VP — mixing it with resume tooling makes that doc harder to write and the handoff harder to explain.

```
shpe-points/
  .mcp.json            # scoped Supabase MCP
  supabase/migrations/  # schema as versioned SQL
  supabase/functions/ingest-checkin/
  apps-script/          # poller source, kept in git even though it deploys by paste
  dashboard/index.html  # the single dependency-free file
  scripts/backfill.ts
  docs/RUNBOOK.md       # for the next VP
  docs/API.md           # for the webmasters
```

Apps Script lives in git even though deployment is a copy-paste into the shared account's script editor — otherwise the only copy of the ingestion logic sits in a Google account nobody thinks to look in.

## Schema approach: redesign freely, but export first

Per your call, the existing schema is not sacred — tables get redesigned, renamed, and dropped to fit this architecture rather than contorted into it.

One hard rule: **export every existing table to versioned CSV in `scripts/legacy-export/` before dropping anything.** Past semesters' attendance is irreplaceable — it exists nowhere else once dropped, and no amount of schema elegance is worth losing it. The backfill importer then reloads that history into the new shape, which doubles as a real test of the importer before it's pointed at Spring 2026.

The one external contract to respect is the public view. The webmasters' page currently queries `member_totals_all_time` for `first_name,last_name,total_points`. We can absolutely design a better view — but renaming or dropping that one silently breaks the live site, so either keep it as a compatibility alias or coordinate the cutover with the webmasters. It should not just disappear.

## The no-manual-changes rule

*Added 2026-08-02, at the user's direction. This is a constraint on every phase below.*

**Nobody should ever have to edit code, run a migration, or touch Apps Script to keep this
system running.** A new VP in 2029 opens the dashboard, clicks through a form, and the new
academic year exists. That is the whole bar.

Concretely, an officer must be able to do all of this from the dashboard:

- **Create a new academic year** — its ID, start and end dates.
- **Point that year at its Drive folder.** The chapter keeps a separate folder per year holding
  that year's sign-up and attendance forms, so the watched folder changes annually.
- **Carry over what should carry over.** Role bonus values (eboard 5, chair 3) are copied from
  the outgoing year as the starting point, editable before saving.
- **Start fresh where it should start fresh.** Role holders, memberships and events do not carry
  over: a new eboard is elected and everybody signs up again.
- **Make it the current year**, which is what every screen and both views key off.

Three things in the system violate this today and are fixed in the phases below:

1. `academic_years` is seeded by a migration. Creating 2027-28 currently means writing SQL.
2. `role_bonus_config` is likewise seeded per-year by migration.
3. The Apps Script poller reads one `FORMS_FOLDER_ID` script property. Rolling the year means a
   human editing an Apps Script setting, which is exactly the kind of hidden step that gets lost
   in a handoff.

The fix for (3) is that **the database becomes the only source of truth for what to watch.** The
poller stops holding a folder ID at all; it asks the Edge Function which folders to walk, and the
Edge Function answers from `academic_years.forms_folder_id`. Apps Script keeps only `INGEST_URL`
and `INGEST_SECRET`, neither of which ever changes.

**The poller walks subfolders**, because the chapter files sign-in forms by term: the year's
"Sign In Forms" folder holds "Fall 2025" and "Spring 2026" and no forms of its own. An officer
sets one folder ID per year and both terms are found, whatever nesting a future officer invents.
Depth is capped at 4 so a mis-pasted Drive root cannot walk the whole account, and visited folders
are tracked so a shortcut back to an ancestor cannot loop. Folder IDs are deduplicated, so two
years pointing at the same folder walk it once.

Note that the folder never decides *which* year a response counts for. That comes from the event's
date, resolved against `academic_years`. Folders only decide what gets discovered.

## Phases

Status verified against the live project and the repository on 2026-08-02.

| # | Phase | State | Notes |
|---|---|---|---|
| 0 | Audit + export existing Supabase | **Done** | 9 CSVs in `scripts/legacy-export/`. |
| 1 | Schema, views, RLS | **Done** | 8 migrations, applied and verified live. |
| 2 | Per-year forms folder + **standard membership template** | **Done** | 2025-26 points at its Drive folder (set from the dashboard). The template's six exact question titles are specified in `_shared/membership-template.ts` and written up for officers in `docs/RUNBOOK.md`; the Google Form itself is copied from last year's by an officer, not generated. |
| 3a | Deploy Edge Function + poller | **Function deployed 2026-08-02.** Poller not yet installed | `ingest-checkin` is live (v1, `verify_jwt` off, authenticates on `x-ingest-secret`). Remaining: set `INGEST_SHARED_SECRET`, then paste `apps-script/poller.js` into a project owned by the shared Gmail. |
| 3b | **Membership form ingestion** | **Done** | Edge Function upserts `memberships` on (netid, year_id); `resolve_unmatched_signin` is membership-aware, so Attach no longer pays attendance points for a membership form. Never run against a real form. |
| 3c | **Poller reads its folders from the database** | **Done** | `FORMS_FOLDER_ID` is gone; the poller GETs its folder list and walks subfolders to depth 4. |
| 4 | Backfill importer + run Spring 2026 | Written, dry-run only | Preview first. |
| 5 | Officer dashboard | **Core done** | Remaining: the academic-year lifecycle screen, the year-grouped roster, and collapsible Needs attention. |
| 6 | Public API doc → webmasters | Written | `docs/API.md`. Verify the live site still renders first. |
| 7 | Runbook + handoff doc | Written | Must be re-checked once 3b, 3c and 5 land, since they change the officer's routine. |

Phase 5 was built ahead of 3 and 4. That was harmless, but it means the dashboard has never met
data that the ingestion pipeline produced.

### Phase 3b: the membership gap

**Nothing in this repository writes to `memberships`.** Not a migration, not `backfill.ts`, not
the dashboard, and not the Edge Function. Nothing anywhere parses `class_level`, `major`,
`gender`, `expected_grad_year`, `college` or `birthday` out of a form response.

What the Edge Function does with a membership form (`ingest-checkin/index.ts:175`) is route
*every* response into `unmatched_signins`. Its own comment says those answers "belong in
`memberships`" — the code diverting them was written, the code landing them was not.

The consequence is worse than an empty table. Those rows surface on Needs attention under
"Unmatched sign-ins", and tapping **Attach** calls `resolve_unmatched_signin`, which
unconditionally inserts into `attendance`. It never checks whether the event is a membership
form. An officer working that queue would **award attendance points for filling out the
membership form** — the phantom attendance the Edge Function comment says it is avoiding. These
points decide an $800 sponsorship, so this is a correctness bug, not a cosmetic one.

Phase 3b therefore covers three things:

1. Parse the membership form's demographic answers and upsert into `memberships` on
   `(netid, year_id)`, with `year_id` resolved from the event's date against `academic_years`.
2. Make `resolve_unmatched_signin` membership-aware, so Attach writes a membership row rather
   than attendance when the event's type is a membership form.
3. A one-time reconciliation for any membership responses already sitting in
   `unmatched_signins` when this ships.

Until 3b lands, the Standings facets (major, gender, class level) and the year-grouped roster
have no data to show. This is the highest-value blocker in the project: October deliberation is
the reason Standings exists, and it cannot slice by anything without it.

### Why Phase 2's template is load-bearing

*Learned 2026-08-02 while building 3b.*

`unmatched_signins.raw_payload` holds `{ responseId, submittedAt, answers: [{question, answer}] }`
— free text, in whatever wording the officer who built that form happened to use. Identity
resolution can afford to pattern-match question titles, because a wrong netID match is caught by
the dedup and foreign key constraints. **There is no equivalent safety net for a guessed major,
gender or class level**, and a silently wrong one corrupts the exact number that decides an $800
sponsorship.

So the pipeline will not guess. A membership row written from a non-standard form gets `netid` and
`year_id` and nothing else: correct, visible on the Roster, and honest about what it does not know.

The way to actually get demographics is therefore **not** a smarter parser, it is Phase 2. The
copyable template must fix the exact question titles for major, gender, class level, expected
graduation year and college, and the chapter must use it every year. Then the mapping is an exact
title match, reviewed once, with no inference. A form that does not use the template still ingests
memberships; it just contributes no facets, and Standings will show the officer that gap rather
than inventing values.

This is the one place where a process convention, not code, is what makes the feature work. It
belongs in the runbook (Phase 7) as a step the incoming VP must not skip.

## Implementation notes (2026-07-30)

Things learned or decided while building, which a future reader could easily undo by accident.

**`member_totals_all_time` must stay SECURITY DEFINER.** The Supabase linter reports it as an
ERROR and it should be left alone. That property is the only reason `anon` can read totals while
having no access whatsoever to `people` or `attendance`. Adding `security_invoker` would return
zero rows to the public leaderboard. For the same reason the view reads base tables directly
rather than sitting on top of `v_member_totals`.

**`v_member_totals` and `v_points_ledger` must stay `security_invoker = true`.** They were
originally created without it, which meant they bypassed RLS while being granted to
`authenticated` — any signed-in Google account could have read every member's netID, gender, major
and points. Fixed in `20260731025444`; do not revert.

**The legacy tables had to move schemas *before* the new ones were created.** Postgres treats
`public."Attendance"` and `public.attendance` as different tables, but their indexes and
constraints share one namespace, so `attendance_pkey`, `events_pkey` and `adjustments_pkey` all
collided. Moving legacy to its own schema frees the names. The leaderboard is unaffected because a
view holds OID references to its tables, not schema-qualified names.

**A trigger reconciles principles 3 and 4.** Points are snapshotted on the attendance row, yet
tapping a type must pay retroactively — so something has to restamp existing rows at the moment of
the tap. `events_restamp_attendance` does this. It deliberately does *not* react to changes in
`event_types.default_points`, so editing the value of `career` next year cannot rewrite last
year's history.

**Role bonuses are one summed row per person per year, not per role.** Two people in the legacy
data hold chair *and* eboard in the same year, and are correctly paid for both (3 + 5 = 8): nobody
holds two roles at once, but someone who studies abroad for a semester can hold one in each half.
Summing keeps "apply role bonuses" idempotent while still paying both; `roles` retains the
per-role detail.

**`people` holds 302, not the legacy 303.** One legacy row had an empty-string netID, no name and
no attendance — junk that survived only because an empty string is a legal primary key. It carried
0 points, so the 1013 invariant is unaffected.

**Three identities are personal-email local parts**, preserved exactly as recorded. Two contain a
dot and one ends in digits, which is why the dashboard's netID shape test allows both; the values
themselves are kept out of version control, since a netID is a Rice identifier. Query `people` if
you need them. Live ingestion will not re-match them — the
normalizer rejects non-Rice addresses by design — so a repeat sign-in lands in `unmatched_signins`
for one-click resolution rather than creating a second identity for the same person.

**Auth is Google sign-in only.** No password option, no shared club passcode; neither should be
added. A shared passcode destroys the audit trail `adjustments` depends on — it records *who*
awarded manual points, and those points decide an $800 sponsorship, so "whoever had the code" is
not an author. It also cannot be revoked in practice. Google accounts inherit Rice's MFA, leave no
password for the club to store or hand over, and need no reset flow (this project has no mail
server). **Leave public signup enabled**: Supabase creates the auth user on first OAuth sign-in, so
disabling it would reject every officer's first login. The `officers` allowlist is the gate, and a
stranger who signs in sees nothing.

## Supabase MCP setup

**Done.** `.mcp.json` in this repo scopes the Supabase MCP to project `jzxxchjjhkbvfazrbeom` with
`read_only=true`. Running Claude Code from this directory picks it up; `/mcp` then authenticates
against that one project rather than the whole account.

`read_only=true` is deliberate for Phase 0 — the audit only reads, and a scoped read-only token
can't damage live data holding real points history. **Remove that parameter when Phase 1 starts
writing migrations**, and re-authenticate.

### Two gotchas worth knowing

- A separate, **unscoped** Supabase MCP entry exists for `/Users/diego` (no `project_ref`). It
  sends OAuth to a generic account-level consent page and requests account-wide *write* scopes.
  Prefer running from this repo. Cleaning up that stale entry is optional but avoids confusion.
- Authenticating from that unscoped entry failed with **"unrecognized client id"** — a dynamic
  client registration Supabase had invalidated. Fix is `/mcp` → select the server → clear its
  authentication → authenticate again, which forces a fresh registration.

## Ownership checklist (the actual handoff)

Every item must sit under the shared club Gmail, not a personal account. This list is the difference between a system that survives and one that dies quietly the summer after you leave.

- [ ] **Supabase project transferred** to the shared Gmail (currently unverified — likely personal). Also stops the project from being paused or deleted by an account nobody has access to.
- [ ] **Git repo** pushed somewhere the club controls, not only this laptop
- [ ] **Vercel account** created under the shared Gmail
- [ ] **Apps Script project owned and its trigger installed** while signed in as the shared Gmail — triggers are owned by the installing account and stop firing silently when it goes away
- [ ] Watched forms folder identified in the shared Drive, all officers with edit access
- [ ] Runbook states clearly: **create event forms while signed in as the shared Gmail**, or the poller cannot read them
- [ ] Officer allowlist seeded; adding next year's eboard documented
- [ ] Webmaster API doc delivered; leaderboard confirmed working against it

## Verification

1. **RLS proof:** with only the public anon key, `SELECT` from `people`, `memberships`, `attendance`, `adjustments` — all must fail. `member_totals_all_time` must succeed and leak no netid, email, birthday, gender, major, or college.
2. **One-tap end to end:** create a Google Form in the shared folder, submit two responses, wait one poll cycle. The event appears in "Needs attention" with its name and date already filled and attendance already ingested at 0 points. Tap `Career` → both attendees immediately show 2 points and the public API reflects it. This is the single most important test.
3. **Delayed classification:** leave an event untyped for several days while responses keep arriving. Every response still ingests. Tapping the type then awards points to *all* of them at once, including those recorded before the tap.
4. **Poller resilience:** stop the Edge Function, submit a response, restart. The next pass ingests it — nothing lost.
5. **Idempotency:** run the poller twice with no new responses → zero new rows.
6. **Bad identity:** submit a malformed netID → lands in `unmatched_signins`, no phantom person, resolvable in one click.
7. **Dedup:** same person submits twice → exactly one attendance row.
8. **Retroactive membership:** record attendance for a netID with no membership, then add the membership → points appear in the deliberation view unaided.
9. **Volunteering:** create a manual volunteer event, paste two columns copied straight out of a Google Sheet, confirm the preview resolves every netID and flags a deliberately bad one. Commit → each person's points equal their hours, with different attendees at the same event holding different values. Confirm the poller ignores the manual event.
10. **Unreadable form:** share a form with the shared account as *viewer only* → it appears in "Needs attention" with a clear explanation, rather than being silently skipped.
11. **Role bonuses:** apply, then apply again → still one adjustment row. Toggle exclude → totals drop by exactly the bonus.
12. **Date window:** change `app_config.leaderboard_window_start` → dashboard and public API both reflect it, no code change.
13. **Backward compatibility:** load the real shpe.rice.edu leaderboard and confirm it still renders after migration.
14. **Backfill:** spot-check ~5 members' Spring 2026 totals against source.

## Open items

- **Reset/cycle policy** — deferred to current officers. Ships all-time with a configurable window. Worth telling them: all-time accumulation on a public leaderboard means seniors sit permanently on top and freshmen see a board they can't win. A motivation problem, not a technical one, but it should inform the decision.
- **Chair bonus value** — "+3, I think." Configurable, so confirm at leisure.
- **Backfill coverage** — how complete Spring 2026 records are is unknown until Phase 0.
- **Which folder to watch** — need the actual shared Drive folder that holds attendance forms today. Anything already in it gets discovered on first run and appears as untyped events, which doubles as a convenient way to classify historical Spring 2026 forms during backfill.
- **Notifying officers of pending taps** — a weekly email digest from the poller ("2 events awaiting a type") would remove the need to remember to check the dashboard. Cheap to add in Apps Script; worth deciding before Phase 5.
