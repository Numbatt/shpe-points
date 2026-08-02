-- Hardening pass, prompted by the Supabase security linter run straight after the cutover.
--
-- THE REAL DEFECT this fixes, and it was mine: `v_member_totals` and `v_points_ledger` were
-- created as ordinary views — which in Postgres means SECURITY DEFINER — and then granted to
-- `authenticated`. A non-`security_invoker` view reads its base tables with the OWNER's rights,
-- so RLS never applied to them. Any signed-in Google account, not just an allowlisted officer,
-- could have read every member's netID, gender, major and points straight through the two views
-- the dashboard uses. The officer policies were being bypassed by the views meant to respect them.
--
-- Verified after applying: a signed-in non-officer now sees 0 rows from v_member_totals, people
-- and attendance; an allowlisted officer sees 302 / 302 / 840.

begin;

alter view public.v_points_ledger set (security_invoker = true);
alter view public.v_member_totals set (security_invoker = true);

-- member_totals_all_time must STAY security definer — that is precisely what lets `anon` read
-- totals while having no access whatsoever to `people` or `attendance`. It therefore can no
-- longer be built on top of v_member_totals, which now applies RLS and would return zero rows to
-- anon. It reads the base tables directly instead.
--
-- The Supabase linter still reports this view as SECURITY DEFINER. That report is expected and
-- must not be "fixed": adding security_invoker here would break the public leaderboard, and the
-- view exposes only names and totals by construction.
drop view public.member_totals_all_time;

create view public.member_totals_all_time as
with ledger as (
  select a.netid, e.occurred_on, a.points_awarded as points
  from public.attendance a
  join public.events e on e.id = a.event_id
  union all
  select adj.netid, adj.effective_on, adj.points
  from public.adjustments adj
),
windowed as (
  select l.netid, sum(l.points) as total
  from ledger l
  where (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start') is null
     or l.occurred_on >= (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start')
  group by l.netid
)
select rank() over (order by coalesce(w.total, 0) desc) as "rank",
       p.first_name,
       p.last_name,
       coalesce(w.total, 0) as total_points
from public.people p
left join windowed w on w.netid = p.netid
where p.first_name is not null or p.last_name is not null;

grant select on public.member_totals_all_time to anon;

-- Pin search_path on every function we own. Without it a caller can prepend a schema and have the
-- function body resolve `public.attendance` to a table they control.
alter function public.is_officer()                           set search_path = public;
alter function public.events_default_points()                set search_path = public;
alter function public.events_restamp_attendance()            set search_path = public;
alter function public.attendance_hours_to_points()           set search_path = public;
alter function public.apply_role_bonuses(text)               set search_path = public;
alter function public.resolve_unmatched_signin(bigint, text) set search_path = public;

-- Legacy leftovers. `process_event_from_staging` implements the paste-into-staging ritual this
-- rebuild replaces and references a table that no longer exists — dead code.
drop function if exists public.process_event_from_staging(text, date, text, integer);

-- `clean_netid` is still the BEFORE trigger on legacy."Members"; the table changed schema but the
-- function did not. Move it so nothing legacy is left in `public`.
alter function public.clean_netid() set schema legacy;

commit;
