-- Phase 1c: views, RLS, and the cutover.
--
-- Everything happens in ONE transaction, because the middle of it is the moment the public
-- leaderboard's view is replaced. Postgres DDL is transactional, so an outside reader sees either
-- the old view or the new one and never a missing object.
--
-- Order matters: the legacy objects move out of `public` only after the new views exist, and the
-- new public view is granted to anon last.

begin;

-- ---------------------------------------------------------------------------
-- Officer identity
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER on purpose. A policy on `officers` that queries `officers` recurses infinitely;
-- routing the check through a definer-rights function breaks the cycle. `search_path` is pinned so
-- the function body cannot be redirected at a shadowed table.
create function public.is_officer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.officers o
    where o.active and o.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.is_officer() from public, anon;
grant execute on function public.is_officer() to authenticated;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- The ledger: attendance and adjustments as one stream of dated, signed point events.
-- Everything downstream aggregates this, so there is exactly one definition of "a point".
create view public.v_points_ledger as
select a.netid,
       e.occurred_on,
       a.points_awarded as points,
       'attendance'::text as kind,
       e.name as label,
       e.id as event_id,
       e.type_code
from public.attendance a
join public.events e on e.id = a.event_id
union all
select adj.netid,
       adj.effective_on,
       adj.points,
       adj.kind,
       adj.reason,
       null::uuid,
       null::text
from public.adjustments adj;

-- Totals joined to this year's membership, which is what makes the October deliberation view
-- sliceable by gender and major. The date window is read inline from app_config rather than
-- through a helper function: an inline subquery is checked against the VIEW OWNER's privileges,
-- so anon never needs read access to app_config.
create view public.v_member_totals as
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
      and (
        (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start') is null
        or l.occurred_on >= (select nullif(value, '')::date from public.app_config where key = 'leaderboard_window_start')
      )
left join public.memberships m
       on m.netid = p.netid
      and m.year_id = (select value from public.app_config where key = 'current_year_id')
group by p.netid, p.first_name, p.last_name,
         m.netid, m.gender, m.major, m.class_level, m.expected_grad_year, m.college;

-- ---------------------------------------------------------------------------
-- The cutover
-- ---------------------------------------------------------------------------

-- Replace the public contract. DROP + CREATE rather than CREATE OR REPLACE because the column
-- list changes (netid and status come out, rank goes in) and REPLACE can only append columns.
drop view public.member_totals_all_time;

-- PUBLIC. This is a live external contract: the shpe.rice.edu leaderboard queries it by name for
-- first_name, last_name, total_points. Those three columns must keep their names and meaning.
-- `rank` is added per docs/DESIGN.md. netid and status are deliberately REMOVED — a netID is a
-- Rice identifier and has no business on a public endpoint.
--
-- Nameless people are filtered out. 86 of the 303 legacy members have no name on record and were
-- rendering as blank rows on the live leaderboard; they keep their points and appear in the
-- dashboard's Roster screen so an officer can chase the gap.
create view public.member_totals_all_time as
select rank() over (order by t.total_points desc) as "rank",
       t.first_name,
       t.last_name,
       t.total_points
from public.v_member_totals t
where t.first_name is not null or t.last_name is not null;

-- The legacy tables were already moved to the `legacy` schema by 20260731024821 — that had to
-- happen before the new tables were created, because index and constraint names collide across
-- case-differing table names. Nothing further is needed here.

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.people            enable row level security;
alter table public.academic_years    enable row level security;
alter table public.memberships       enable row level security;
alter table public.roles             enable row level security;
alter table public.role_bonus_config enable row level security;
alter table public.event_types       enable row level security;
alter table public.events            enable row level security;
alter table public.forms             enable row level security;
alter table public.attendance        enable row level security;
alter table public.adjustments       enable row level security;
alter table public.unmatched_signins enable row level security;
alter table public.officers          enable row level security;
alter table public.app_config        enable row level security;

-- Officers get full read/write on everything through the dashboard; nobody else gets anything.
-- The Edge Function writes as `service_role`, which bypasses RLS entirely and needs no policy.
-- `anon` has no policy on any table, and no grant either — two independent reasons it is shut out.
do $$
declare t text;
begin
  foreach t in array array[
    'people', 'academic_years', 'memberships', 'roles', 'role_bonus_config',
    'event_types', 'events', 'forms', 'attendance', 'adjustments',
    'unmatched_signins', 'officers', 'app_config'
  ] loop
    execute format(
      'create policy officers_all on public.%I for all to authenticated
         using (public.is_officer()) with check (public.is_officer())', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end
$$;

grant usage, select on all sequences in schema public to authenticated;

-- The dashboard reads its standings through the aggregate view.
grant select on public.v_points_ledger, public.v_member_totals to authenticated;

-- The single public surface. This view is owned by `postgres` and is NOT `security_invoker`, so it
-- reads its base tables with the owner's rights — which is the only reason anon can see totals
-- while being unable to touch `people` or `attendance`. Do not add `security_invoker` here.
grant select on public.member_totals_all_time to anon;

commit;
