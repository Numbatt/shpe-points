-- Phase 1d: make the one tap actually pay out.
--
-- The design doc asserts two things that pull against each other:
--
--   Principle 3: points are SNAPSHOT on the attendance row, never looked up from the event — so
--                next year's point-value changes cannot rewrite last year's history.
--   Principle 4: assigning a type later retroactively awards points to everyone already recorded.
--
-- A snapshot that never updates cannot pay retroactively, so something has to restamp the rows at
-- the moment the type is tapped. That is this trigger. It is the mechanism behind "forgetting
-- delays points, it never loses them" — and it is why ingestion is free to record at 0 points
-- without waiting for a human.
--
-- The snapshot property still holds where it matters: nothing here reacts to a change in
-- `event_types.default_points`. Editing the value of `career` next year leaves every historic
-- career event exactly as it was recorded.

begin;

-- When a type is tapped and no explicit override was given, the event inherits that type's value.
create function public.events_default_points() returns trigger
language plpgsql as $$
begin
  if new.type_code is not null and new.points is null then
    select default_points into new.points
    from public.event_types where code = new.type_code;
  end if;
  return new;
end
$$;

create trigger events_default_points
before insert or update of type_code, points on public.events
for each row execute function public.events_default_points();

-- Restamp attendance when the event's value changes — this is the retroactive award.
create function public.events_restamp_attendance() returns trigger
language plpgsql as $$
declare
  is_variable boolean;
begin
  select coalesce(et.is_variable_points, false) into is_variable
  from public.event_types et where et.code = new.type_code;

  -- Volunteering is deliberately exempt: two people at one event earn different amounts, so their
  -- points come from their own `hours`, not from any event-level value.
  if is_variable then
    update public.attendance
       set points_awarded = coalesce(hours, 0)
     where event_id = new.id;
  else
    update public.attendance
       set points_awarded = coalesce(new.points, 0)
     where event_id = new.id;
  end if;

  return null;
end
$$;

create trigger events_restamp_attendance
after update of points, type_code on public.events
for each row
when (new.points is distinct from old.points or new.type_code is distinct from old.type_code)
execute function public.events_restamp_attendance();

-- Keep volunteer rows self-consistent: editing someone's hours rewrites their points, and totals
-- recompute with no reconciliation step. Per docs/DESIGN.md hours are never self-reported, so this
-- only ever fires from an officer's edit in the dashboard.
create function public.attendance_hours_to_points() returns trigger
language plpgsql as $$
begin
  if new.hours is not null then
    new.points_awarded := new.hours;
  end if;
  return new;
end
$$;

create trigger attendance_hours_to_points
before insert or update of hours on public.attendance
for each row execute function public.attendance_hours_to_points();

commit;
