-- Phase 1e: the two officer actions that need to be one atomic step.
--
-- Both could almost be done from the dashboard with plain REST calls, and both would be subtly
-- wrong that way. Keeping them in the database means the dashboard stays a thin client and the
-- rules have exactly one implementation.

begin;

-- Apply this year's role bonuses. Idempotent: run it after every elections change, as often as
-- you like, and the result is the same.
--
-- Why this is not a REST upsert: the uniqueness rule is a PARTIAL index
-- (`... where kind = 'role_bonus'`), and PostgREST's on_conflict only emits a column list, which
-- Postgres cannot match against a partial index. It would fail at best and stack duplicate bonus
-- rows at worst.
--
-- Points are SUMMED across a person's roles for the year. Someone who studies abroad for a
-- semester can be a chair for one half and on eboard for the other; each role is earned
-- separately and pays separately (3 + 5 = 8).
create function public.apply_role_bonuses(p_year_id text)
returns table (netid text, points numeric)
language plpgsql security invoker as $$
begin
  if not public.is_officer() then
    raise exception 'not authorized';
  end if;

  return query
  with computed as (
    select r.netid as person,
           sum(cfg.points) as total,
           string_agg(coalesce(r.position_title, r.role), ' + ' order by r.role) as roles
    from public.roles r
    join public.role_bonus_config cfg
      on cfg.year_id = r.year_id and cfg.role = r.role
    where r.year_id = p_year_id
    group by r.netid
  ),
  upserted as (
    insert into public.adjustments (netid, year_id, points, kind, reason, effective_on, created_by)
    select c.person,
           p_year_id,
           c.total,
           'role_bonus',
           'Role bonus (' || c.roles || ')',
           (select starts_on from public.academic_years where id = p_year_id),
           coalesce(auth.jwt() ->> 'email', 'dashboard')
    from computed c
    on conflict (netid, year_id) where kind = 'role_bonus'
    do update set points = excluded.points,
                  reason = excluded.reason,
                  created_by = excluded.created_by
    returning adjustments.netid, adjustments.points
  )
  select u.netid, u.points from upserted u;

  -- Someone removed from `roles` should lose the bonus, not keep it forever.
  delete from public.adjustments a
  where a.year_id = p_year_id
    and a.kind = 'role_bonus'
    and not exists (select 1 from public.roles r where r.netid = a.netid and r.year_id = p_year_id);
end
$$;

-- Attach an unmatched sign-in to a real person.
--
-- Atomic on purpose: creating the attendance row and marking the sign-in resolved must happen
-- together, or a failure between them leaves a sign-in that looks handled but awarded nothing.
-- Points are read from the event, so resolving a sign-in on an untyped event correctly awards 0
-- and gets restamped when the type is finally tapped.
create function public.resolve_unmatched_signin(p_id bigint, p_netid text)
returns void
language plpgsql security invoker as $$
declare
  v_event uuid;
  v_points numeric;
begin
  if not public.is_officer() then
    raise exception 'not authorized';
  end if;

  select event_id into v_event from public.unmatched_signins where id = p_id;
  if v_event is null then
    raise exception 'unmatched sign-in % not found, or it has no event', p_id;
  end if;

  insert into public.people (netid) values (p_netid) on conflict (netid) do nothing;

  select points into v_points from public.events where id = v_event;

  insert into public.attendance (event_id, netid, points_awarded, source)
  values (v_event, p_netid, coalesce(v_points, 0), 'form')
  on conflict (event_id, netid) do nothing;

  update public.unmatched_signins
     set resolved_netid = p_netid, resolved_at = now()
   where id = p_id;
end
$$;

revoke all on function public.apply_role_bonuses(text) from public, anon;
revoke all on function public.resolve_unmatched_signin(bigint, text) from public, anon;
grant execute on function public.apply_role_bonuses(text) to authenticated;
grant execute on function public.resolve_unmatched_signin(bigint, text) to authenticated;

commit;
