-- Let an officer dismiss a discovered form that was never an event sign-in.
--
-- The poller (apps-script/poller.js) walks a Drive folder and turns every Google Form it finds
-- into an `events` row with type_code null — "awaiting the tap" — which is exactly what Needs
-- attention is for when the form really is a sign-in nobody has categorized yet. But the folder
-- also picks up forms that are not sign-ins at all: an officer application, a t-shirt survey, a
-- social RSVP. Those show up in the same queue with the same 0-point, untyped, needs-a-decision
-- look, and today there is no decision an officer can make that gets one out of the queue. It sits
-- there forever, re-surfacing every time someone opens the dashboard.
--
-- The obvious fix — delete the event — does not work, and will not work, no matter how tempting
-- it looks later. `forms.event_id` references `events(id) on delete cascade`
-- (20260731024857_new_schema.sql), so deleting the event also deletes the `forms` row that is the
-- ONLY record that this form has already been discovered. On the next poll, the poller walks the
-- same Drive folder, finds the same form, sees no `forms` row for it, and creates a brand new
-- event for it — untyped, right back in Needs attention. Deleting an ignored event doesn't dismiss
-- it, it resets it, forever, on every poll. This is why the flag below lives on `events` and not
-- on `forms`: `forms` is the poller's bookkeeping for what it has already seen, and anything that
-- can make that bookkeeping disappear recreates the exact loop this migration exists to stop.
--
-- So instead of deleting, an ignored event is marked and kept — a tombstone, not a grave. The event
-- row stays exactly where it is, still untyped, still pointed at by its `forms` row, still visible
-- to the poller as "already discovered, nothing to do." The only change is that Needs attention
-- stops showing it. Because the row survives, dismissing a form is auditable (ignored_by/ignored_at
-- say who decided this wasn't a sign-in, and when) and reversible (an officer who dismissed the
-- wrong form by mistake can simply clear the two columns back to null — no re-poll, no data loss,
-- no cascade to worry about).

begin;

alter table public.events add column ignored_at timestamptz;
alter table public.events add column ignored_by text;

comment on column public.events.ignored_at is
  'Set when an officer dismisses a discovered form that is not an event sign-in (an application, survey, RSVP, ...). Null means the event is not dismissed. The event row and its forms row are kept, never deleted -- forms.event_id cascades on delete, and deleting the event would delete the forms bookkeeping too, making the poller rediscover the same form as brand new on its next pass. Clearing this column back to null un-dismisses the event.';
comment on column public.events.ignored_by is
  'Officer email that set ignored_at, for the same audit reason attendance/adjustments record created_by. Null exactly when ignored_at is null.';

-- Needs attention's query is (and after this migration, should become) "untyped and not dismissed"
-- -- events?type_code=is.null&ignored_at=is.null in dashboard/index.html. The old events_untyped_idx
-- (20260731024857_new_schema.sql) only narrowed on `type_code is null`, which is still a superset-
-- correct index for that query -- Postgres can use it and filter the small remainder -- but it is
-- no longer the right index to keep, for two reasons. First, the two columns are conceptually one
-- predicate now ("belongs in the queue"), not two, so one purpose-built partial index says that
-- more honestly than an index-plus-filter. Second, and more concretely: every event an officer ever
-- dismisses stays in `events` forever as a tombstone by design (see header comment above), so a
-- `type_code is null`-only index accumulates a permanent, ever-growing set of index entries for
-- rows that will never again be useful to this query -- dead weight that only grows, never shrinks.
-- Narrowing the index's own where-clause to match the query's actual predicate keeps it sized to
-- what Needs attention actually needs to scan, indefinitely, instead of to every form anyone has
-- ever dismissed since the club started using this system.
drop index public.events_untyped_idx;
create index events_untyped_idx on public.events (created_at)
  where type_code is null and ignored_at is null;

commit;
