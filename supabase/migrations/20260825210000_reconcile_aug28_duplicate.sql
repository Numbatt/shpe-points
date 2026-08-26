-- Reconcile the two events that both represent the 28 August 2025 GBM.
--
-- WHAT HAPPENED. The chapter's 2025-26 attendance arrived twice by two different routes. The
-- legacy spreadsheet import (Phase 1, `source='backfill'`) covered events through 2025-09-02. The
-- Apps Script poller's first real run on 2026-08-10 then discovered the live Google Forms and,
-- having no high-water mark for any of them, ingested each form's ENTIRE response history — which
-- reaches back to 2025-08-28. The two routes overlap on exactly one date, and produced:
--
--   786172d7-139f-46cd-ae3b-62e272568cf2  "Fall 2025 GBM 1"        backfill  typed 'gbm'  74 rows, 74 pts
--   e0feb9ac-1da9-4b69-a693-a00c1e71816c  "Fall GBM 1 - 08/28/25"  form      UNTYPED      73 rows,  0 pts
--
-- 72 netids appear on both. `pa30` and `sam35` are only on the spreadsheet row; `mg236` is only on
-- the form row (so the current state SHORTS Melanie a point, which is why the club-wide total is
-- expected to rise by exactly 1 when this is done, not stay flat).
--
-- WHY THIS WAS INVISIBLE. The dashboard's "Needs attention" screen queries
-- `events?type_code=is.null`, so the typed spreadsheet event never appeared beside the untyped form
-- event. An officer looking at that screen sees one "Fall GBM 1" and has no way to know a second
-- row for the same meeting is already paying points. Tapping a type on the form event would have
-- silently paid those 72 people twice for one meeting, into the number that decides an ~$800
-- sponsorship.
--
-- WHICH ONE SURVIVES, AND WHY IT MUST BE THE FORM. The form event is the one with a `forms` row,
-- which means it is the one the poller will keep updating as late responses arrive. Retiring it
-- instead would strand the form: `forms.event_id` is ON DELETE CASCADE, so deleting a form-backed
-- event destroys the poller's bookkeeping and the next pass rediscovers the form as brand new,
-- forever (this is the exact hazard 20260809221613_events_ignored.sql was written to avoid, and
-- why "Not an event" is a tombstone rather than a delete). The spreadsheet event has NO `forms`
-- row, so deleting it is inert: nothing polls it, nothing will recreate it.
--
-- BEFORE-STATE, captured 2026-08-25 against the live database. This migration IS the audit record
-- for a destructive change, in the same spirit as 20260731024919_seed_and_migrate_legacy.sql:
--
--   attendance on 786172d7 : 74 rows, 74.0 points
--   attendance on e0feb9ac : 73 rows,  0.0 points
--   union of both netid sets: 75
--   only on backfill: pa30, sam35     only on form: mg236
--   select sum(total_points) from v_member_totals  ->  1013.0   across 331 people
--
-- EXPECTED AFTER this migration AND after the officer taps 'gbm' on e0feb9ac: 1014.0.
-- The +1 is mg236. Any other delta means something else changed and you should stop and look.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. Carry across anyone the form event is missing.
--
-- Written as a set operation over the source rows rather than as a hand-typed list of
-- (pa30, sam35): a literal list encodes an audit taken at one moment and is silently wrong if the
-- data moved between the audit and the migration running. This version cannot be wrong about who
-- those people are.
--
-- points_awarded reads the FORM event's CURRENT points rather than a hardcoded 0. This is the
-- subtle one. If the officer has not yet tapped the type, events.points is null, these rows land
-- at 0, and events_restamp_attendance (20260731024951_event_point_sync.sql) pays them the moment
-- the type is tapped. But if the type was ALREADY tapped, that trigger has already fired and will
-- not fire again for these rows — a hardcoded 0 would leave sam35 permanently unpaid on a 1-point
-- event, with nothing to surface it. Reading events.points makes this migration correct in either
-- order, which matters because the officer is tapping types on 13 other events in the same sitting.
-- ---------------------------------------------------------------------------------------------
insert into public.attendance (event_id, netid, points_awarded, source, recorded_at)
select 'e0feb9ac-1da9-4b69-a693-a00c1e71816c'::uuid,
       a.netid,
       coalesce((select e.points from public.events e
                  where e.id = 'e0feb9ac-1da9-4b69-a693-a00c1e71816c'::uuid), 0),
       -- Provenance stays honest: these two rows came off the spreadsheet, not off the form.
       -- Anyone auditing later can tell which route recorded which attendance.
       'backfill',
       a.recorded_at
  from public.attendance a
 where a.event_id = '786172d7-139f-46cd-ae3b-62e272568cf2'::uuid
   and not exists (select 1
                     from public.attendance f
                    where f.event_id = 'e0feb9ac-1da9-4b69-a693-a00c1e71816c'::uuid
                      and f.netid = a.netid)
    on conflict (event_id, netid) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 2. Assert the safety property rather than assuming step 1 achieved it.
--
-- Deliberately count-free: it holds no matter how many people attended, and no matter whether
-- unmatched sign-in #9 (pa30@rice.ede, a typo of pa30@rice.edu, attached to the FORM event) was
-- resolved before or after this runs. The delete below is irreversible; this is the last chance to
-- refuse it.
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1
      from public.attendance b
     where b.event_id = '786172d7-139f-46cd-ae3b-62e272568cf2'::uuid
       and not exists (select 1
                         from public.attendance f
                        where f.event_id = 'e0feb9ac-1da9-4b69-a693-a00c1e71816c'::uuid
                          and f.netid = b.netid)
  ) then
    raise exception
      'refusing to retire the spreadsheet event: some of its attendees are not on the form event';
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. Retire the spreadsheet event. attendance.event_id is ON DELETE CASCADE
--    (20260731024857_new_schema.sql), so its 74 rows go with it in the same statement.
--
--    A tombstone (ignored_at) would be wrong here. That mechanism exists so the poller stops
--    re-creating an event for a form it keeps finding; this event has no form and nothing will
--    ever recreate it. Leaving it as a zero-point tombstone would just leave a second "Fall 2025
--    GBM 1" in the events table forever for the next VP to puzzle over.
-- ---------------------------------------------------------------------------------------------
delete from public.events
 where id = '786172d7-139f-46cd-ae3b-62e272568cf2'::uuid;

commit;

-- Idempotent by construction: re-running against an already-reconciled database inserts nothing
-- (the not-exists finds no rows because the source event is gone), asserts vacuously, and deletes
-- nothing. That matters because `supabase db push` may replay it against a branch or a restore.
--
-- STILL TO DO BY HAND, in the dashboard, immediately after this runs: tap 'gbm' on
-- e0feb9ac. It is deliberately not done here so the officer exercises the same code path used for
-- the other 13 untyped events. Between this migration and that tap, 28 Aug 2025 pays nobody.
