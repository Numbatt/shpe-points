-- Phase 1b: seed reference data, then move the legacy rows into the new shape.
--
-- This is a deterministic SQL migration rather than a run of scripts/backfill.ts. The legacy data
-- is already in this database, already normalized (all netIDs lowercase, no duplicate
-- (event, person) pairs, no orphans), and its correct answer is known: 302 people holding 1013
-- points. That makes a SQL migration verifiable in one query, which a CSV round-trip is not.
--
-- Reads from the `legacy` schema, where 20260731024821 moved the old tables.
--
-- The migration ASSERTS its own result at the end and aborts on any drift. It must never be
-- "fixed" by adjusting the expected numbers — they come from scripts/legacy-export/MANIFEST.md,
-- taken before anything was touched.

begin;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

insert into public.academic_years (id, starts_on, ends_on) values
  ('2024-25', '2024-08-01', '2025-07-31'),
  ('2025-26', '2025-08-01', '2026-07-31'),
  ('2026-27', '2026-08-01', '2027-07-31');

-- Point values per docs/DESIGN.md. These are the values for events recorded FROM NOW ON; historic
-- attendance keeps whatever it was recorded at (see the snapshot note below).
insert into public.event_types (code, label, default_points, is_variable_points, is_membership_form) values
  ('gbm',        'General Body Meeting', 1, false, false),
  ('career',     'Career Event',         2, false, false),
  ('social',     'Social',               2, false, false),
  ('company',    'Company Event',        2, false, false),
  ('volunteer',  'Volunteering',         0, true,  false),  -- 1 pt per hour, entered manually
  ('membership', 'Membership Form',      0, false, true);   -- routes to memberships, not attendance

insert into public.role_bonus_config (year_id, role, points) values
  ('2024-25', 'eboard', 5), ('2024-25', 'chair', 3),
  ('2025-26', 'eboard', 5), ('2025-26', 'chair', 3),
  ('2026-27', 'eboard', 5), ('2026-27', 'chair', 3);

insert into public.app_config (key, value) values
  -- Empty string = all-time accumulation. The reset/cycle policy is deferred to current officers;
  -- when they decide, this becomes a date and both the dashboard and the public API follow it
  -- with no code change and no migration.
  ('leaderboard_window_start', ''),
  ('current_year_id', '2026-27');

-- ---------------------------------------------------------------------------
-- Legacy rows
-- ---------------------------------------------------------------------------

-- People. The 86 rows with no name come across as-is; they hold real attendance and dropping
-- them to satisfy a NOT NULL would destroy history. They are excluded from the public view.
--
-- One row is skipped: a legacy row whose netID is the empty string, with no name and no
-- attendance. It is junk that only survived because an empty string is a legal primary key. It
-- carries 0 points, so the 1013-point invariant is unaffected — but the person count drops from
-- 303 to 302, which is why the assertion below expects 302.
--
-- Three rows are kept despite not looking like netIDs at all: they are the local parts of
-- *personal* email addresses, stored as netIDs by the old hand-entry process. Two contain a dot
-- and one ends in digits, which is why the dashboard's netID shape test allows both. Each is a
-- real person holding one attendance row, so they are preserved exactly as recorded. The actual
-- values are deliberately not written here: a netID is a Rice identifier, and this file is in
-- version control. Query `people` if you need to see them. Live ingestion will NOT match them again — the
-- normalizer rejects non-Rice addresses by design, so a repeat sign-in lands in
-- `unmatched_signins` for an officer to resolve in one click. That is the intended behaviour:
-- guessing that a Gmail local part is a netID is how this mess started.
insert into public.people (netid, first_name, last_name)
select m."Net ID", nullif(trim(m."First Name"), ''), nullif(trim(m."Last Name"), '')
from legacy."Members" m
where m."Net ID" <> '';

-- Events. Legacy had three categories; they map onto the new six with no loss because the point
-- value travels with the row rather than being re-derived from the type.
insert into public.events (id, name, type_code, occurred_on, points, source, created_by)
select e.id,
       e.name,
       case ec.code
         when 'COMPANY'          then 'company'
         when 'VOLUNTEER'        then 'volunteer'
         when 'GBM/SOCIAL/OTHER' then 'gbm'
       end,
       e.event_date,
       e.base_points,
       'backfill',
       'legacy-migration'
from legacy."Events" e
join legacy."Event Categories" ec on ec.id = e.category_id;

-- Attendance. points_awarded is copied from the legacy event's base_points and NOT recomputed
-- from event_types. This is design principle 3 and it is what makes the type mapping above
-- harmless: `social` is worth 2 under the new scheme, but legacy socials were recorded inside
-- GBM/SOCIAL/OTHER at 1 point, and snapshotting keeps those totals exactly as they were.
insert into public.attendance (event_id, netid, points_awarded, source, recorded_at)
select a.event_id, a.member_netid, e.base_points, 'backfill', a.attended_at
from legacy."Attendance" a
join legacy."Events" e on e.id = a.event_id;

-- Roles, preserving the per-role detail.
insert into public.roles (netid, year_id, role, position_title)
select ec.member_netid,
       case ec.term_label when 'F24-S25' then '2024-25' else '2025-26' end,
       case when ec.role ilike '%eboard%' then 'eboard' else 'chair' end,
       ec.role
from legacy."E-board and Chairs" ec
on conflict (netid, year_id, role) do nothing;

-- Role bonuses become adjustments rows: visible, auditable, filterable, and excludable from the
-- deliberation view — which a computed column could never be.
--
-- Summed per person per year. `dea7` and `mg236` each hold Chair AND Eboard in the same year and
-- are paid for both (3 + 5 = 8), which is correct and intended: nobody holds two roles at once,
-- but someone who studies abroad for a semester can be a chair for one semester and on eboard for
-- the other. Each role is earned separately and counts separately.
--
-- This is why the bonus is one summed row per person per year rather than one row per role: it
-- keeps "apply role bonuses" idempotent while still paying both. The per-role breakdown stays in
-- `roles`, and the reason string records which roles were combined.
insert into public.adjustments (netid, year_id, points, kind, reason, effective_on, created_by)
select ec.member_netid,
       yr.id,
       sum(ec.points),
       'role_bonus',
       'Role bonus (' || string_agg(ec.role, ' + ' order by ec.role) || ')',
       yr.starts_on,
       'legacy-migration'
from legacy."E-board and Chairs" ec
join public.academic_years yr
  on yr.id = case ec.term_label when 'F24-S25' then '2024-25' else '2025-26' end
group by ec.member_netid, yr.id, yr.starts_on;

-- ---------------------------------------------------------------------------
-- Assertions — abort rather than leave a half-migrated database behind
-- ---------------------------------------------------------------------------

do $$
declare
  n_people      int := (select count(*) from public.people);
  n_events      int := (select count(*) from public.events);
  n_attendance  int := (select count(*) from public.attendance);
  n_adjustments int := (select count(*) from public.adjustments);
  pts_events    numeric := (select coalesce(sum(points_awarded), 0) from public.attendance);
  pts_role      numeric := (select coalesce(sum(points), 0) from public.adjustments where kind = 'role_bonus');
  untyped       int := (select count(*) from public.events where type_code is null);
begin
  -- 303 legacy members minus the one empty-netID junk row.
  if n_people <> 302 then
    raise exception 'people: expected 302, got %', n_people;
  end if;
  if n_events <> 28 then
    raise exception 'events: expected 28, got %', n_events;
  end if;
  if n_attendance <> 840 then
    raise exception 'attendance: expected 840, got %', n_attendance;
  end if;
  -- 30 legacy role rows collapse to 28 person-years (two people hold two roles in one term).
  if n_adjustments <> 28 then
    raise exception 'adjustments: expected 28, got %', n_adjustments;
  end if;
  if pts_events <> 901 then
    raise exception 'attendance points: expected 901, got %', pts_events;
  end if;
  if pts_role <> 112 then
    raise exception 'role bonus points: expected 112, got %', pts_role;
  end if;
  if pts_events + pts_role <> 1013 then
    raise exception 'total points: expected 1013, got %', pts_events + pts_role;
  end if;
  if untyped <> 0 then
    raise exception 'every legacy event should have mapped to a type, but % are untyped', untyped;
  end if;
  raise notice 'Legacy migration verified: 302 people, 840 attendance rows, 1013 points.';
end
$$;

commit;
