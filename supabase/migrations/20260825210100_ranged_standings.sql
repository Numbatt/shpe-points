-- Arbitrary date-range standings, plus two corrections the range work exposed.
--
-- WHY. Officers need to ask "how many points has each member earned SINCE the last convention?"
-- The system has always had exactly one date window: `app_config.leaderboard_window_start`, read
-- inline by v_member_totals and member_totals_all_time. It is global, single-ended, and shared with
-- the public leaderboard, so it cannot answer a per-question range and must not be repurposed to.
--
-- WHY THIS IS SQL AND NOT A FILTER IN THE BROWSER. The obvious implementation is to fetch
-- v_points_ledger once and re-aggregate in the dashboard: it is per-dated-row, ~1273 rows, and the
-- file already does client-side filtering on the Standings screen. That is a trap. PostgREST caps
-- a response at `max-rows` (1000 by default, and confirmed 1000 on this project on 2026-08-25:
-- `content-range: 0-999/1245` for a bare select on attendance). Past that limit the API does not
-- error — it returns a short array with a 200. The dashboard would silently render a leaderboard
-- missing whichever rows fell off the end, and nobody would find out until the numbers were
-- already in front of the sponsorship discussion. Aggregating server-side returns one row per
-- person (~331) and cannot hit the cap.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. v_points_ledger: exclude dismissed events.
--
-- The view has always joined `events` without checking `ignored_at`. That has been harmless only
-- by accident: the dashboard's "Not an event" handler DELETEs the event's attendance rows before
-- setting the tombstone, so no rows survive to be counted. Nothing enforced it, though, and
-- 20260809221613_events_ignored.sql promises that dismissal is undoable by clearing two columns —
-- a promise this view currently breaks, because restoring ignored_at to null would not restore any
-- points if the attendance had been deleted, and would double-count if it had not.
--
-- Fixing it at the source means every consumer (v_member_totals, member_totals_all_time, and the
-- new function below) inherits the correct definition of "a point" instead of each re-deriving it.
--
-- Numbers must not move today. That is the verification: sum(total_points) before and after this
-- migration must be byte-identical, because the dismiss handler already deleted those rows.
-- ---------------------------------------------------------------------------------------------
create or replace view public.v_points_ledger as
select a.netid,
       e.occurred_on,
       a.points_awarded as points,
       'attendance'::text as kind,
       e.name as label,
       e.id as event_id,
       e.type_code,
       -- Appended column (legal for CREATE OR REPLACE VIEW, which permits adding at the end).
       -- Null for attendance: an event belongs to a year only by its date, and the ledger
       -- deliberately keeps dates as the one way to place a point in time.
       null::text as year_id
from public.attendance a
join public.events e on e.id = a.event_id
                    and e.ignored_at is null
union all
select adj.netid,
       adj.effective_on,
       adj.points,
       adj.kind,
       adj.reason,
       null::uuid,
       null::text,
       -- adjustments.year_id is NOT NULL and is the authoritative year for a role bonus, which
       -- is what lets member_totals_between() below scope bonuses by year without re-deriving
       -- the year from effective_on.
       adj.year_id
from public.adjustments adj;

-- CREATE OR REPLACE preserves the column list but is not guaranteed to preserve reloptions, and
-- this one is load-bearing: without security_invoker the view would read base tables with the
-- owner's rights and leak every member's points to any authenticated user, which is exactly the
-- defect 20260731025444_harden_views_and_functions.sql was written to close. Re-assert it rather
-- than trust the replace.
alter view public.v_points_ledger set (security_invoker = true);

-- ---------------------------------------------------------------------------------------------
-- 2. academic_years.convention_on
--
-- The SHPE National Convention is the reason this whole system exists, and "since the last
-- convention" is the window officers actually deliberate over. It is at the end of October most
-- years but it moves, so it is data, not a constant in the dashboard.
--
-- Null means "not recorded"; the dashboard falls back to 30 October of the year's fall semester.
-- A column rather than a parameter on create_academic_year(), deliberately: adding a parameter
-- would create a second overload of that function and PostgREST cannot disambiguate overloads by
-- argument list, so the year dialog would start failing. The blanket officers_all policy already
-- permits the dashboard to PATCH academic_years directly, which is how forms_folder_id is edited.
-- ---------------------------------------------------------------------------------------------
alter table public.academic_years add column if not exists convention_on date;

comment on column public.academic_years.convention_on is
  'Date of the SHPE National Convention for this academic year. Null means not recorded, and the '
  'dashboard falls back to 30 October of the fall semester. Drives the "since last convention" '
  'preset on the Standings screen.';

-- ---------------------------------------------------------------------------------------------
-- 3. Document the unmatched-sign-in tombstone convention.
--
-- The dashboard's new "Dismiss" action marks a sign-in handled without attaching it to anybody, by
-- setting resolved_at while leaving resolved_netid null. That reuses two existing columns and
-- needs no schema change, but it makes the pair's meaning positional, and nothing in the schema
-- said so. Without this comment the next reader reasonably assumes resolved_at implies a
-- resolution, and writes a query that counts dismissals as successful attaches.
-- ---------------------------------------------------------------------------------------------
comment on column public.unmatched_signins.resolved_at is
  'When this sign-in stopped needing attention. Read together with resolved_netid: both set means '
  'it was attached to that person; resolved_at set with resolved_netid NULL means an officer '
  'dismissed it (a personal email that is not a Rice identity, a test submission). Null means it '
  'is still in the queue. Dismissal is soft on purpose - raw_payload is retained for audit, and '
  'un-dismissing is `update unmatched_signins set resolved_at = null`.';

-- ---------------------------------------------------------------------------------------------
-- 4. member_totals_between(from, to)
--
-- Returns v_member_totals' exact shape for an arbitrary window, so the dashboard can swap one for
-- the other without a client-side join: the facet columns (gender, major, class_level) and
-- last_activity come along already scoped to the range. Joining a ranged aggregate to
-- v_member_totals in the browser to recover those columns would drop anyone with zero points in
-- range, which is precisely who an officer scanning a window wants to see.
--
-- NULL bounds mean open-ended, so "all time" is member_totals_between(null, null) travelling the
-- identical code path as every other range. One implementation, no special case to keep in sync -
-- and it gives a free correctness test: with leaderboard_window_start unset, that call must return
-- exactly what v_member_totals returns, per netid.
--
-- ROLE BONUSES ARE WINDOWED BY YEAR, NOT BY DATE, AND THAT IS DELIBERATE.
-- apply_role_bonuses() stamps every bonus with effective_on = the academic year's starts_on
-- (20260731025006_officer_rpcs.sql), i.e. 1 August. A literal date filter would therefore drop
-- every role bonus from any window that starts later than that - so "since the last convention"
-- would show each eboard member 5 to 8 points lighter than the same screen shows today, silently.
-- A role bonus is not earned on a day; it is earned by holding the position for the year. So it is
-- counted whenever the requested window overlaps the academic year it belongs to. Manual
-- adjustments keep the plain date rule: those DO happen on a day, and the officer who entered one
-- chose that date.
--
-- security invoker, so RLS still applies and a non-officer gets nothing - matching the views
-- rather than is_officer()'s definer posture. Explicitly revoked from anon: the public leaderboard
-- has its own definer view (member_totals_all_time) and must not gain a range parameter.
-- ---------------------------------------------------------------------------------------------
create or replace function public.member_totals_between(p_from date, p_to date)
returns table (
  netid                   text,
  first_name              text,
  last_name               text,
  gender                  text,
  major                   text,
  class_level             text,
  expected_grad_year      int,
  college                 text,
  is_current_member       boolean,
  points_from_events      numeric,
  points_from_role        numeric,
  points_from_adjustments numeric,
  total_points            numeric,
  last_activity           date
)
language sql
stable
security invoker
set search_path = public
as $$
  select p.netid,
         p.first_name,
         p.last_name,
         m.gender,
         m.major,
         m.class_level,
         m.expected_grad_year,
         m.college,
         (m.netid is not null) as is_current_member,
         coalesce(sum(l.points) filter (where l.kind = 'attendance'), 0) as points_from_events,
         coalesce(sum(l.points) filter (where l.kind = 'role_bonus'), 0) as points_from_role,
         coalesce(sum(l.points) filter (where l.kind = 'manual'), 0)     as points_from_adjustments,
         coalesce(sum(l.points), 0) as total_points,
         max(l.occurred_on) filter (where l.kind = 'attendance') as last_activity
    from public.people p
    left join public.v_points_ledger l
           on l.netid = p.netid
          and case
                when l.kind = 'role_bonus' then
                  -- Scoped by the bonus's OWN year_id (not-null on adjustments, and what
                  -- apply_role_bonuses sets), counted whenever the requested window overlaps that
                  -- academic year at all. exists() rather than a join so a bonus pointing at a
                  -- year that somehow has no row is simply not counted, instead of multiplying or
                  -- erasing the person's other ledger rows.
                  exists (
                    select 1
                      from public.academic_years ay
                     where ay.id = l.year_id
                       and (p_from is null or ay.ends_on   >= p_from)
                       and (p_to   is null or ay.starts_on <= p_to)
                  )
                else
                  (p_from is null or l.occurred_on >= p_from)
                  and (p_to is null or l.occurred_on <= p_to)
              end
    left join public.memberships m
           on m.netid = p.netid
          and m.year_id = (select value from public.app_config where key = 'current_year_id')
   group by p.netid, p.first_name, p.last_name,
            m.netid, m.gender, m.major, m.class_level, m.expected_grad_year, m.college;
$$;

-- Postgres grants EXECUTE on a new function to PUBLIC by default, and nothing in this repo revokes
-- it automatically - see 20260809213021_revoke_execute_on_membership_retype_trigger_fn.sql, which
-- exists solely because that was missed once already.
revoke all on function public.member_totals_between(date, date) from public, anon;
grant execute on function public.member_totals_between(date, date) to authenticated;

commit;
