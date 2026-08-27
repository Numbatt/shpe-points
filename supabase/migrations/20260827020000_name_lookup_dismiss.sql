-- "No name on file" dismiss, so an officer can drop a permanently-unfillable person out of that
-- queue instead of it sitting there forever.
--
-- WHY. A senior whose Rice account has lapsed no longer has a directory listing at all -- not
-- hidden under FERPA (that at least still returns a confirmed zero, which the dashboard already
-- greys the "Look up" button for), just gone. Nobody is ever going to type that name in either;
-- the officer's actual decision is "stop asking me about this person," and there was no way to
-- record that decision. It would otherwise sit in "No name on file" next to people worth chasing,
-- forever.
--
-- THE FIX. One nullable timestamp on `people`, modeled exactly on unmatched_signins.resolved_at
-- (see its comment in 20260825210100_ranged_standings.sql): soft, changes nothing about the
-- person or their points, and un-dismissing is a plain `update ... set ... = null` with no
-- restore UI. That is a deliberate, precedented choice in this codebase, not an oversight.
--
-- v_member_totals and member_totals_between must keep returning the IDENTICAL shape -- enforced
-- by dual-role.sql's `except`-based correctness test, which fails loudly if the two ever drift by
-- even one column -- so the new column goes on both, in the same position.

begin;

alter table public.people
  add column name_lookup_dismissed_at timestamptz;

comment on column public.people.name_lookup_dismissed_at is
  'Set when an officer dismisses this person from the "No name on file" queue -- typically a '
  'senior whose directory listing is gone for good. Soft on purpose: nothing about the person or '
  'their points changes, this only drops them out of the dashboard queue. Un-dismissing is '
  '`update people set name_lookup_dismissed_at = null`.';

-- ---------------------------------------------------------------------------------------------
-- v_member_totals: CREATE OR REPLACE VIEW permits appending a column at the end (it does not
-- permit reordering or removing one), so every existing column stays exactly where it was.
-- security_invoker is reasserted rather than trusted to survive the replace, per the same caution
-- 20260825210100_ranged_standings.sql already documents for v_points_ledger, and because this
-- specific property is the one 20260731025444_harden_views_and_functions.sql exists to guarantee:
-- dropping it silently would let any signed-in Google account read every member's data again.
-- ---------------------------------------------------------------------------------------------
create or replace view public.v_member_totals as
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
       max(l.occurred_on) filter (where l.kind = 'attendance') as last_activity,
       p.name_lookup_dismissed_at
from public.people p
left join public.v_points_ledger l
       on l.netid = p.netid
      and (
        (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start') is null
        or l.occurred_on >= (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start')
      )
left join public.memberships m
       on m.netid = p.netid
      and m.year_id = (select value from public.app_config where key = 'current_year_id')
group by p.netid, p.first_name, p.last_name,
         m.netid, m.gender, m.major, m.class_level, m.expected_grad_year, m.college,
         p.name_lookup_dismissed_at;

alter view public.v_member_totals set (security_invoker = true);

-- ---------------------------------------------------------------------------------------------
-- member_totals_between(from, to): unlike a view, CREATE OR REPLACE FUNCTION cannot widen a
-- RETURNS TABLE shape -- Postgres rejects any change to a function's return type that way, table
-- columns included. It has to be dropped and recreated, which drops its grants too; both are
-- re-applied at the bottom exactly as 20260825210100_ranged_standings.sql originally set them.
-- ---------------------------------------------------------------------------------------------
drop function public.member_totals_between(date, date);

create function public.member_totals_between(p_from date, p_to date)
returns table (
  netid                    text,
  first_name               text,
  last_name                text,
  gender                   text,
  major                    text,
  class_level              text,
  expected_grad_year       int,
  college                  text,
  is_current_member        boolean,
  points_from_events       numeric,
  points_from_role         numeric,
  points_from_adjustments  numeric,
  total_points             numeric,
  last_activity            date,
  name_lookup_dismissed_at timestamptz
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
         max(l.occurred_on) filter (where l.kind = 'attendance') as last_activity,
         p.name_lookup_dismissed_at
    from public.people p
    left join public.v_points_ledger l
           on l.netid = p.netid
          and case
                when l.kind = 'role_bonus' then
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
            m.netid, m.gender, m.major, m.class_level, m.expected_grad_year, m.college,
            p.name_lookup_dismissed_at;
$$;

revoke all on function public.member_totals_between(date, date) from public, anon;
grant execute on function public.member_totals_between(date, date) to authenticated;

commit;
