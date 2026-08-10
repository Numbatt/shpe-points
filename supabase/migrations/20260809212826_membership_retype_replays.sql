-- Self-heal the membership gap: retyping an event to a membership form must not leave its
-- earlier responses stranded in the wrong table forever.
--
-- The bug this closes: a Google Form is discovered by the poller before any officer has looked at
-- it. The Edge Function (supabase/functions/ingest-checkin/index.ts) can only route a response
-- into `memberships` if the event is ALREADY typed as a membership form at the moment that
-- response is ingested — the type lives on `events.type_code`, and nobody can tap it before the
-- event exists. So the realistic sequence is: form gets discovered, poller ingests its first batch
-- of responses as ordinary (0-point) `attendance` rows because the event is still untyped, THEN an
-- officer opens the dashboard and taps "Membership". By that point `forms.last_response_at` — the
-- high-water mark the poller uses to ask Google Forms for only what's new — has already moved past
-- those responses. Apps Script's poller.js never re-requests anything older than the high-water
-- mark (see apps-script/poller.js:193), so the demographics on those first responses (major,
-- class level, gender, t-shirt size, ...) are gone. Not delayed — gone.
--
-- That silently breaks a promise the rest of the system keeps everywhere else: "forgetting to tap
-- the type delays points, it never loses them." events_restamp_attendance (see
-- 20260731024951_event_point_sync.sql) is the mechanism for ordinary events — it rewrites the
-- points on rows already sitting in `attendance` the moment a type is tapped, no data was ever
-- discarded, so tapping late just costs time. A membership form has no equivalent, because its
-- rows were never *rows* to restamp — they were dropped by the routing check on the way in and
-- never landed in `memberships` at all. Restamping can't fix a write that never happened.
--
-- The fix has to happen on the ingest side, not the read side: force those responses to be
-- re-ingested now that the event is correctly typed. That means undoing the two things ingest did
-- while the event was still untyped:
--   1. The (wrong, but the only option at the time) attendance rows it wrote — 0-point rows for a
--      membership form are not real attendance and would double-count if left in place once the
--      real membership rows land too.
--   2. The high-water mark it advanced — resetting forms.last_response_at to null tells the next
--      poller pass "you've never successfully read this form," so poller.js calls getResponses()
--      with no timestamp (apps-script/poller.js:193) and resends the FULL response history. With
--      the event now typed as a membership form, the Edge Function's routing check
--      (index.ts:~208-240) sends every one of those responses into `memberships` this time.
--
-- Recoverability is exactly why the DELETE below is safe rather than reckless: nothing is actually
-- lost the instant these rows disappear, because step 2 guarantees the poller will re-fetch and
-- re-insert equivalent (correctly-routed) history within one polling interval. The dangerous
-- version of this migration would be one that reset the high-water mark WITHOUT deleting the stale
-- attendance rows (leaves duplicates) or deleted attendance WITHOUT resetting the mark (loses the
-- data for real, recreating the exact bug this migration exists to close). They have to happen
-- together, in the same trigger, so there is no window where one has run and not the other.
--
-- Why this can't be a cheap `WHEN` clause: the condition we actually care about — "the new type is
-- a membership form and the old one wasn't" — depends on `event_types.is_membership_form`, a
-- lookup against another table. Postgres trigger WHEN clauses cannot contain subqueries, so the
-- WHEN clause here only does the cheap part (did type_code actually change at all?) and the
-- membership-form lookup happens inside the function body, in plain SQL, before anything runs.
--
-- Why the body's guard is "new is a membership form AND old was not" rather than just "new is a
-- membership form": a membership event can be retyped to a *different* membership type code (rare,
-- but not impossible — an officer fixing a miscategorized form), and an ordinary event can be
-- edited for reasons that have nothing to do with this bug once it already has a type. Neither of
-- those should nuke attendance or force a full re-poll:
--   * membership -> membership: responses are already correctly sitting in `memberships`. There is
--     nothing to replay and nothing in `attendance` to clean up (the routing check would have sent
--     them to `memberships` from the first response onward).
--   * membership -> non-membership, or non-membership -> non-membership: not this bug at all.
-- Only the non-membership-or-untyped -> membership transition is the moment data was ever at risk,
-- so it is the only transition that fires.

begin;

-- SECURITY DEFINER, pinned search_path — same reasoning as is_officer() in
-- 20260731024941_views_rls_and_public_cutover.sql: the delete/update below must succeed exactly
-- the same way no matter which authenticated officer's UPDATE on `events` fired it, rather than
-- depending on whatever RLS policy happens to govern attendance/forms for that particular session
-- at the time. Pinning search_path stops a caller from shadowing public.attendance or
-- public.forms with an object earlier in their own search_path.
create function public.events_membership_retype_replays() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_new_is_membership boolean;
  v_old_is_membership boolean;
  v_has_form boolean;
begin
  -- coalesce around a scalar subquery, not a plain SELECT ... INTO join, so that an old.type_code
  -- of null (an event retyped for the very first time) resolves to "not a membership form" rather
  -- than to sql null — the same trick resolve_unmatched_signin uses via its left join, applied
  -- here because there is no join to left-outer in a bare lookup.
  select coalesce((select is_membership_form from public.event_types where code = new.type_code), false)
    into v_new_is_membership;
  select coalesce((select is_membership_form from public.event_types where code = old.type_code), false)
    into v_old_is_membership;

  -- The DELETE below is only safe because the poller can replay what it removes. That is true for
  -- an event discovered from a Google Form, and false for anything else. An event with no `forms`
  -- row has no replay source: nothing will ever re-send its attendance, so deleting it would be
  -- exactly the permanent data loss this migration exists to prevent.
  --
  -- This is not hypothetical. `source='manual'` events can sit untyped in Needs attention — the
  -- dashboard renders a "manual" pill for them precisely because that state is expected — and an
  -- officer reaching for a type there could tap Membership by mistake. Without this guard that
  -- mis-tap silently destroys every attendance row on the event with no way to get it back.
  select exists (select 1 from public.forms where event_id = new.id) into v_has_form;

  if v_new_is_membership and not v_old_is_membership and v_has_form then
    -- These rows are recoverable, not lost: resetting the high-water mark below guarantees the
    -- poller re-sends this form's entire response history on its next pass, and the event is now
    -- typed correctly so it lands in `memberships` instead of back in here. See the header comment
    -- for why both statements must run together.
    delete from public.attendance where event_id = new.id;
    update public.forms set last_response_at = null where event_id = new.id;
  end if;

  return null;
end
$$;

create trigger events_membership_retype_replays
after update of type_code on public.events
for each row
when (new.type_code is distinct from old.type_code)
execute function public.events_membership_retype_replays();

commit;
