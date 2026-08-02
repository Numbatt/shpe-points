-- Phase 1a: the new schema, per docs/DESIGN.md.
--
-- Nothing is dropped here. The legacy tables stay untouched and serving the live leaderboard
-- until the view swap in 20260731024941, so this migration is safe to apply on its own.
--
-- Postgres treats public."Attendance" and public.attendance as *different* tables, so the new
-- lowercase tables coexist with the legacy CamelCase ones during the cutover. That is convenient
-- here and a footgun afterwards, which is why the legacy objects move out of `public` entirely
-- at the end of Phase 1 rather than being left around.

begin;

-- Permanent identity. Never deleted; membership is what expires.
create table public.people (
  netid      text primary key check (netid = lower(netid) and netid <> ''),
  -- Nullable, deviating from the design doc: 86 of the 303 legacy members have no name on
  -- record. Dropping them would destroy attendance history to satisfy a constraint, so they are
  -- imported as-is and excluded from the *public* view instead of publishing blank rows.
  first_name text,
  last_name  text,
  created_at timestamptz not null default now()
);

create table public.academic_years (
  id        text primary key,          -- '2025-26'
  starts_on date not null,
  ends_on   date not null,
  check (ends_on > starts_on)
);

-- The per-year opt-in. Sliceable attributes live HERE, not on people, because students change
-- major and class level and October deliberation wants that year's answers.
create table public.memberships (
  id                 bigserial primary key,
  netid              text not null references public.people(netid) on update cascade,
  year_id            text not null references public.academic_years(id) on update cascade,
  class_level        text,
  expected_grad_year int,
  gender             text,
  major              text,
  college            text,
  birthday           date,
  submitted_at       timestamptz,
  unique (netid, year_id)
);

create table public.roles (
  netid          text not null references public.people(netid) on update cascade,
  year_id        text not null references public.academic_years(id) on update cascade,
  role           text not null check (role in ('eboard', 'chair')),
  position_title text,
  primary key (netid, year_id, role)
);

create table public.role_bonus_config (
  year_id text not null references public.academic_years(id) on update cascade,
  role    text not null check (role in ('eboard', 'chair')),
  points  numeric not null,
  primary key (year_id, role)
);

create table public.event_types (
  code               text primary key,
  label              text not null,
  default_points     numeric not null default 0,
  is_variable_points boolean not null default false,  -- true only for volunteer
  is_membership_form boolean not null default false,  -- routes to memberships, not attendance
  drive_folder       text                             -- optional auto-classify accelerator
);

create table public.events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  type_code   text references public.event_types(code) on update cascade,  -- NULL = awaiting the tap
  occurred_on date not null,
  points      numeric,                                 -- defaults from type; overridable
  source      text not null check (source in ('form', 'manual', 'backfill')),
  created_by  text,
  created_at  timestamptz not null default now()
);

-- Discovered Google Forms. The poller works from this table, which is why a 'manual' volunteer
-- event is invisible to it: no row here means nothing to poll.
create table public.forms (
  form_id          text primary key,
  event_id         uuid not null references public.events(id) on delete cascade,
  last_response_at timestamptz,                        -- high-water mark for polling
  discovered_at    timestamptz not null default now(),
  -- Set when FormApp.openById() fails for lack of edit access. Surfaces in "Needs attention"
  -- rather than being skipped quietly — per docs/DESIGN.md this must fail loudly.
  unreadable_since timestamptz,
  last_error       text
);

-- The ledger. One row per person per event; points are SNAPSHOT at recording time so that
-- changing a type's value next year never rewrites last year's history.
create table public.attendance (
  id             bigserial primary key,
  event_id       uuid not null references public.events(id) on delete cascade,
  netid          text not null references public.people(netid) on update cascade,
  points_awarded numeric not null default 0,
  hours          numeric,                              -- volunteering only
  source         text not null check (source in ('form', 'manual', 'backfill')),
  recorded_at    timestamptz not null default now(),
  unique (event_id, netid)
);

create table public.adjustments (
  id           bigserial primary key,
  netid        text not null references public.people(netid) on update cascade,
  year_id      text not null references public.academic_years(id) on update cascade,
  points       numeric not null,
  kind         text not null check (kind in ('role_bonus', 'manual')),
  reason       text not null,
  -- Not in the design doc, added deliberately: `leaderboard_window_start` filters the ledger by
  -- date, and a row carrying only a year_id has no date to filter on — role bonuses would leak
  -- past every window an officer sets. Defaults to the academic year's start.
  effective_on date not null,
  created_by   text,
  created_at   timestamptz not null default now()
);

-- Makes "apply role bonuses" idempotent: re-running it updates one row per person per year
-- instead of stacking duplicates.
--
-- One row per person per year, not per role. Two people in the legacy data hold Chair AND Eboard
-- in the same term and are paid for both (3 + 5). A per-role index would allow that naturally but
-- would break idempotency; instead the single row carries the SUM, so the person still receives 8
-- and re-applying stays a no-op. Per-role detail remains in `roles`.
create unique index adjustments_one_role_bonus_per_person_year
  on public.adjustments (netid, year_id) where kind = 'role_bonus';

create table public.unmatched_signins (
  id             bigserial primary key,
  event_id       uuid references public.events(id) on delete cascade,
  raw_identifier text,
  raw_payload    jsonb,
  resolved_netid text references public.people(netid) on update cascade,
  resolved_at    timestamptz,
  created_at     timestamptz not null default now()
);

create table public.officers (
  email        text primary key check (email = lower(email)),
  display_name text,
  active       boolean not null default true
);

create table public.app_config (
  key   text primary key,
  value text
);

-- Indexes for the aggregation paths the views and dashboard actually walk.
create index attendance_netid_idx    on public.attendance (netid);
create index attendance_event_idx    on public.attendance (event_id);
create index adjustments_netid_idx   on public.adjustments (netid);
create index events_occurred_on_idx  on public.events (occurred_on);
create index events_untyped_idx      on public.events (created_at) where type_code is null;
create index memberships_year_idx    on public.memberships (year_id);

-- Belt and braces alongside the default-privilege revoke in the lockdown migration: no new table
-- is reachable by the public anon key. Read access is granted per-object with the views.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

commit;
