-- Dual-role events: one event can pay points AND collect membership demographics.
--
-- The discovery that forces this: `Fall GBM 1 - 08/28/25` was BOTH the GBM 1 sign-in and the
-- 2025-26 membership form. One form, so students did not have to fill out two. Its questions
-- confirm it — Gender, College, Year, Major, plus "New or returning member", "What do you hope to
-- get out of SHPE this year?", "Have you attended SHPE Nationals/Career Fair before?".
--
-- The schema cannot express that today. `events.type_code` is a single FK, and the Edge Function's
-- membership branch (supabase/functions/ingest-checkin/index.ts) `continue`s before ever reaching
-- attendanceRows.push, so a membership-typed event can never also record attendance. The officer's
-- only two choices are both wrong: type it `gbm` and 2025-26 has no membership data at all (the
-- state production is in — 331 people with points, ZERO membership rows), or tap Membership and
-- the retype trigger deletes all 73 attendance rows and everyone loses their GBM point.
--
-- The shape of the fix: ONE point-paying type, plus membership as a separate overlay.
--
-- Membership is the only role that gets this treatment, and the reason is that it pays 0 points.
-- That makes it purely additive — an event's worth is still answered by exactly one thing, its
-- type. Two point-paying types would make "what is this event worth?" ambiguous, and points here
-- feed an ~$800 sponsorship decision, so ambiguity is not affordable. A boolean overlay that
-- cannot pay points can never create that ambiguity.
--
-- Why a column on `events` rather than reading event_types.is_membership_form: the flag has to be
-- settable independently of the type, which is the entire point.
--
-- The two still answer different questions, and neither replaces the other:
--
--   is_membership_form   -> this TYPE pays no attendance. Still a real thing: a standalone
--                           membership drive that is not also a meeting.
--   collects_membership  -> this EVENT's form declares who you are this year.
--
-- But the first IMPLIES the second, and the trigger below enforces that rather than leaving it to
-- every reader to remember. Being the membership form is what the membership type means; an officer
-- who taps it has already answered the question, and asking again would be asking twice. So
-- `collects_membership` is the single column anything downstream needs to read.
--
-- Framed the way an officer actually thinks about it: a year has ONE membership form. Usually it is
-- the first GBM's sign-in, because one form is what students fill out. Occasionally it is a
-- standalone drive, which is what the membership type is for. It is not a property you re-decide
-- for each of the twenty-odd events that follow -- it is one slot per year, and this column records
-- which event fills it.
--
-- Why at most one per ACADEMIC YEAR: `memberships` is keyed `unique (netid, year_id)`. Two
-- membership-collecting events in one year write to the same row, and the second one wins
-- wholesale (the ingest upsert is a full replace, deliberately — a membership form is a complete
-- statement). That is a silent overwrite, not a merge. Per-year exclusivity is the constraint the
-- table already implies; enforcing it here just makes the implication visible at the point of the
-- mistake instead of at read time.

begin;

-- ---------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------

alter table public.events add column collects_membership boolean not null default false;

comment on column public.events.collects_membership is
  'True on the ONE event per academic year whose form collects membership demographics (major, class level, gender, ...). Usually the first GBM''s sign-in, because one form is what students actually fill out; the event still pays whatever its type_code pays. False means an ordinary sign-in, whose demographic answers can only gap-fill membership rows that already exist, never create one. Set either by designating the event in the dashboard or, implicitly, by typing it as a membership form -- events_membership_guard keeps those in sync and enforces the one-per-year limit. Clearing it back to false frees the year for another event; setting it forces the poller to replay the form''s full history so demographics already submitted are not stranded.';

-- Backfill: an event typed as a membership form was, by definition, already collecting membership.
-- This must run BEFORE the guard trigger exists, or the trigger fires once per backfilled row and
-- rejects the second event in any year that legitimately has one today.
update public.events e
   set collects_membership = true
  from public.event_types et
 where et.code = e.type_code
   and et.is_membership_form;

-- ...which means the backfill itself could produce a state the new constraint forbids. Assert it
-- did not, while we can still abort cheaply. If this raises, two events in one year are both typed
-- as membership forms and a human has to decide which one is real -- there is no safe automatic
-- answer, because picking wrong silently discards a year of demographics.
do $$
declare
  v_year text;
begin
  select ay.id into v_year
  from public.events e
  join public.academic_years ay on e.occurred_on between ay.starts_on and ay.ends_on
  where e.collects_membership
  group by ay.id
  having count(*) > 1
  limit 1;

  if v_year is not null then
    raise exception 'academic year % already has more than one membership-collecting event; resolve by hand before applying this migration', v_year;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. One membership form per academic year, and a type that implies it
-- ---------------------------------------------------------------------------

-- Two rules, in one BEFORE trigger:
--
--   1. A membership TYPE implies collecting membership. Being the membership form is what that
--      type MEANS -- an officer who taps it has already said the thing the flag says, and making
--      them also tick a box would be asking the same question twice.
--   2. At most one event per academic year collects membership.
--
-- They live in the same function deliberately. Rule 1 writes the column that rule 2 checks, so as
-- two separate BEFORE triggers the outcome would depend on Postgres firing them in name order --
-- an invariant held together by a coincidence of spelling. One function, one pass, no ordering.
--
-- Rule 1 is also what closes the gap the backfill above cannot: the backfill sets the flag for
-- membership-typed events that exist TODAY, and it runs exactly once. Without this, an event typed
-- `membership` for the first time next season would carry the type and not the flag, claim no
-- year's slot, and slip straight past rule 2 -- two membership forms in one year, silently
-- overwriting each other's demographics, which is the whole failure this migration exists to stop.
--
-- The reverse is NOT automatic: retyping away from `membership` leaves the flag set, because the
-- form did collect those demographics and the event should keep the year's slot rather than
-- silently vacate it. Giving the slot up is an explicit act on the Events screen.
--
-- Why a trigger and not a partial unique index: an index needs the year as a stored, immutable
-- expression, and `events` has no year_id column (see 20260731024857_new_schema.sql) -- an event
-- belongs to a year ONLY by its occurred_on falling inside academic_years.starts_on/ends_on. That
-- lookup is a subquery against another table, so it is neither immutable nor indexable. The same
-- reasoning is why v_points_ledger derives year_id rather than storing it.
--
-- BEFORE, not AFTER: this should reject the write, not undo it.
create function public.events_membership_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_year_id text;
  v_existing text;
begin
  -- Rule 1.
  if coalesce((select is_membership_form from public.event_types where code = new.type_code), false) then
    new.collects_membership := true;
  end if;

  -- Rule 2 only has something to say about events that collect.
  if not new.collects_membership then
    return new;
  end if;

  select ay.id into v_year_id
  from public.academic_years ay
  where new.occurred_on between ay.starts_on and ay.ends_on;

  -- No year covers this date. Refuse rather than allow it: demographics harvested from this form
  -- would have no year_id to land under, so every response would pile up in unmatched_signins
  -- (the Edge Function's own behaviour when membershipYearId is null). Silently accepting the
  -- toggle would look like it worked and quietly collect nothing.
  if v_year_id is null then
    raise exception 'no academic year covers %; create the year before marking this event as collecting membership', new.occurred_on;
  end if;

  select e.name into v_existing
  from public.events e
  join public.academic_years ay on e.occurred_on between ay.starts_on and ay.ends_on
  where e.collects_membership
    and ay.id = v_year_id
    and e.id is distinct from new.id
  limit 1;

  if v_existing is not null then
    raise exception '% is already the membership form for %; clear it on the Events screen first', v_existing, v_year_id;
  end if;

  return new;
end
$$;

revoke all on function public.events_membership_guard() from public, anon, authenticated;

-- type_code is in the column list because rule 1 reads it. occurred_on is there because moving an
-- event's date can carry it into a year that already has a membership form -- the same collision
-- arriving by a different door.
--
-- No WHEN clause: rule 1 has to run in order to SET collects_membership, so a WHEN that tested the
-- flag would skip exactly the case the rule exists for.
create trigger events_membership_guard
before insert or update of type_code, collects_membership, occurred_on on public.events
for each row
execute function public.events_membership_guard();

-- ---------------------------------------------------------------------------
-- 3. Rework the replay trigger so it stops destroying attendance
-- ---------------------------------------------------------------------------

-- The old trigger (20260809212826_membership_retype_replays.sql) had exactly one behaviour: when an
-- event became a membership form, delete all its attendance and reset the form's high-water mark so
-- the poller replays everything into `memberships`. That was correct when membership and attendance
-- were mutually exclusive. It is now actively wrong for the dual-role case, where the whole point is
-- that the attendance stays.
--
-- Splitting it in two:
--
--   collects_membership false -> true : reset the high-water mark, KEEP attendance. The replay is
--     still required -- forms.last_response_at has already moved past the responses whose
--     demographics we want, and apps-script/poller.js never re-requests anything older than it, so
--     without the reset those demographics are gone, not delayed. Replaying is safe for attendance
--     because the Edge Function's attendance upsert uses ignoreDuplicates, so re-sent responses
--     no-op against rows that already exist and their points_awarded is never rewritten.
--
--   -> a membership TYPE (a pure membership form) : unchanged from the old behaviour, delete and
--     replay. A membership type still does not pay attendance, so 0-point rows written while the
--     event was untyped are not real attendance and would double-count.
--
-- Note the old trigger was `after update of type_code`, so it would not have fired on a new column
-- at ALL. The replay on the boolean has to be wired deliberately; adding the column alone would
-- have produced a toggle that silently harvested nothing from any response already ingested.
create or replace function public.events_membership_retype_replays() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_new_is_membership boolean;
  v_old_is_membership boolean;
  v_has_form boolean;
begin
  select coalesce((select is_membership_form from public.event_types where code = new.type_code), false)
    into v_new_is_membership;
  select coalesce((select is_membership_form from public.event_types where code = old.type_code), false)
    into v_old_is_membership;

  -- Unchanged and still load-bearing: an event with no `forms` row has no replay source. Nothing
  -- will ever re-send its attendance, so deleting it would be permanent loss. `source='manual'`
  -- events sit untyped in Needs attention and an officer can mis-tap Membership on one.
  select exists (select 1 from public.forms where event_id = new.id) into v_has_form;

  if not v_has_form then
    return null;
  end if;

  if v_new_is_membership and not v_old_is_membership then
    -- Pure membership form. Recoverable, not lost: the high-water reset re-sends the full history
    -- and the event is now typed so it lands in `memberships`. Both statements must run together.
    delete from public.attendance where event_id = new.id;
    update public.forms set last_response_at = null where event_id = new.id;
  elsif new.collects_membership and not old.collects_membership then
    -- Dual-role. Replay to harvest demographics; attendance is exactly what we are protecting.
    update public.forms set last_response_at = null where event_id = new.id;
  end if;

  return null;
end
$$;

drop trigger events_membership_retype_replays on public.events;

create trigger events_membership_retype_replays
after update of type_code, collects_membership on public.events
for each row
when (new.type_code is distinct from old.type_code
   or new.collects_membership is distinct from old.collects_membership)
execute function public.events_membership_retype_replays();

-- ---------------------------------------------------------------------------
-- 4. Audit trail for classification changes
-- ---------------------------------------------------------------------------

-- Today the type-setting write records nothing about who did it. Typing an event is the single
-- most consequential thing an officer can do in the dashboard -- it decides what every attendee
-- earned -- and it was the one write with no author.
--
-- Captured by a trigger reading auth.jwt() ->> 'email' rather than by the dashboard passing
-- session.email in the payload. Both patterns exist in this repo (ignored_by and created_by are
-- client-supplied; is_officer() and create_academic_year() read the JWT), and the JWT is the
-- stronger of the two here: it cannot be forged by anything holding the anon key, and it also
-- records changes made from the SQL editor or a migration, which a client-supplied column never
-- sees. 'system' covers exactly that case -- a write with no authenticated user behind it.
create table public.event_changes (
  id         bigserial primary key,
  event_id   uuid not null references public.events(id) on delete cascade,
  field      text not null check (field in ('type_code', 'collects_membership', 'ignored_at')),
  old_value  text,
  new_value  text,
  changed_by text not null,
  changed_at timestamptz not null default now()
);

create index event_changes_event_idx on public.event_changes (event_id, changed_at desc);

comment on table public.event_changes is
  'Append-only log of officer changes to an event''s classification: its type, whether it collects membership, and whether it is dismissed. Written by the events_log_changes trigger, never by a client -- there is no insert policy. Cascades on event delete: this records who classified a live event, it is not a permanent record of events that no longer exist.';
comment on column public.event_changes.changed_by is
  'Officer email taken from auth.jwt() inside the database, not supplied by the caller, so it cannot be forged by anything holding the anon key. ''system'' when there is no authenticated user -- a migration or a SQL editor session.';

create function public.events_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  if new.type_code is distinct from old.type_code then
    insert into public.event_changes (event_id, field, old_value, new_value, changed_by)
    values (new.id, 'type_code', old.type_code, new.type_code, v_who);
  end if;

  if new.collects_membership is distinct from old.collects_membership then
    insert into public.event_changes (event_id, field, old_value, new_value, changed_by)
    values (new.id, 'collects_membership', old.collects_membership::text, new.collects_membership::text, v_who);
  end if;

  if new.ignored_at is distinct from old.ignored_at then
    insert into public.event_changes (event_id, field, old_value, new_value, changed_by)
    values (new.id, 'ignored_at', old.ignored_at::text, new.ignored_at::text, v_who);
  end if;

  return null;
end
$$;

revoke all on function public.events_log_changes() from public, anon, authenticated;

create trigger events_log_changes
after update of type_code, collects_membership, ignored_at on public.events
for each row
execute function public.events_log_changes();

-- Officers read it; nobody writes it but the trigger, which is SECURITY DEFINER and so bypasses
-- RLS. No insert/update/delete policy exists, which is what makes the log append-only in practice.
alter table public.event_changes enable row level security;

create policy event_changes_officer_read on public.event_changes
  for select using (public.is_officer());

revoke all on public.event_changes from public, anon;
grant select on public.event_changes to authenticated;

-- ---------------------------------------------------------------------------
-- 5. resolve_unmatched_signin: the same either/or fork, given the same fix
-- ---------------------------------------------------------------------------

-- This function had the identical shape of bug as the Edge Function -- an if/else that routes a
-- resolved sign-in to EITHER memberships OR attendance. On a dual-role event both must happen, or
-- an officer rescuing a sign-in from the queue silently drops the attendance point that the same
-- response would have earned had it matched on the way in.
create or replace function public.resolve_unmatched_signin(p_id bigint, p_netid text)
returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_event uuid;
  v_points numeric;
  v_occurred_on date;
  v_is_membership boolean;
  v_collects boolean;
  v_year_id text;
begin
  if not public.is_officer() then
    raise exception 'not authorized';
  end if;

  select event_id into v_event from public.unmatched_signins where id = p_id;
  if v_event is null then
    raise exception 'unmatched sign-in % not found, or it has no event', p_id;
  end if;

  insert into public.people (netid) values (p_netid) on conflict (netid) do nothing;

  select e.points, e.occurred_on, coalesce(et.is_membership_form, false), e.collects_membership
    into v_points, v_occurred_on, v_is_membership, v_collects
  from public.events e
  left join public.event_types et on et.code = e.type_code
  where e.id = v_event;

  -- Attendance unless the TYPE is a membership form. Untyped still records at 0 and is restamped
  -- later by events_restamp_attendance, exactly as before.
  if not v_is_membership then
    insert into public.attendance (event_id, netid, points_awarded, source)
    values (v_event, p_netid, coalesce(v_points, 0), 'form')
    on conflict (event_id, netid) do nothing;
  end if;

  -- ...and ADDITIONALLY a membership row when the event collects membership. Independent of the
  -- branch above, which is the whole change: these are no longer alternatives.
  if v_is_membership or v_collects then
    select ay.id into v_year_id
    from public.academic_years ay
    where v_occurred_on between ay.starts_on and ay.ends_on;

    if v_year_id is null then
      raise exception 'no academic year covers %', v_occurred_on;
    end if;

    -- Still netid + year_id ONLY, and still deliberately. raw_payload is a free-text
    -- {question, answer}[] with no fixed key for "major" or "gender". A membership row with null
    -- demographics is visible on the Roster and correct; an invented demographic is neither, and
    -- it corrupts a number that decides an $800 sponsorship. `do nothing` so rescuing a sign-in
    -- can never clobber demographics the form itself already delivered.
    insert into public.memberships (netid, year_id)
    values (p_netid, v_year_id)
    on conflict (netid, year_id) do nothing;
  end if;

  update public.unmatched_signins
     set resolved_netid = p_netid, resolved_at = now()
   where id = p_id;
end
$$;

commit;
