-- Year lifecycle + the membership gap (docs/DESIGN.md, "The no-manual-changes rule" and
-- "Phase 3b: the membership gap").
--
-- Two unrelated-looking problems, one migration, because both are instances of the same rule
-- added 2026-08-02: nobody should ever have to touch SQL or Apps Script to keep this system
-- running.
--
-- 1. Rolling the academic year currently means writing a migration (see
--    20260731024919_seed_and_migrate_legacy.sql, which hand-inserts three years and their bonus
--    config). `create_academic_year` replaces that with a dashboard button. Its `forms_folder_id`
--    column also replaces the Apps Script `FORMS_FOLDER_ID` script property named in the design
--    doc as violation #3 of the no-manual-changes rule — the poller stops holding a folder ID at
--    all and asks the Edge Function, which answers from this column.
--
-- 2. `resolve_unmatched_signin` unconditionally inserts into `attendance`. For a membership form,
--    that pays attendance points for filling out a form asking for your major and t-shirt size —
--    a real bug, not a hypothetical one, and it feeds an ~$800 sponsorship decision. Fixed here to
--    route membership-form sign-ins into `memberships` instead.

begin;

-- ---------------------------------------------------------------------------
-- 1. Per-year forms folder
-- ---------------------------------------------------------------------------

-- The chapter keeps one Drive folder per academic year holding that year's forms. This column
-- becomes the ONLY source of truth for what the poller watches — Apps Script keeps just
-- INGEST_URL and INGEST_SECRET, neither of which ever changes. Null means "not configured yet",
-- which is also how the Edge Function tells the poller to stop watching a folder: a year rolled
-- over without a folder ID yet is not silently watched forever under the old year's folder.
alter table public.academic_years add column forms_folder_id text;

-- ---------------------------------------------------------------------------
-- 2. Roll the year from the dashboard, no SQL required
-- ---------------------------------------------------------------------------

-- The whole point of this function is that a non-technical officer clicks a button in the
-- dashboard and the new year exists — the same event that today requires someone who can write
-- and apply a migration (see the hand-authored inserts in 20260731024919).
--
-- Deliberately copies ONLY role_bonus_config. `roles` and `memberships` are NOT carried forward:
-- a new eboard is elected every year and every member fills out the form again, so last year's
-- role holders and membership roster have no business existing in a year nobody has elected or
-- signed up for yet. Do not "fix" this by adding roles/memberships copying — it would silently
-- hand this year's eboard permissions and last year's roster to a year that hasn't happened.
create function public.create_academic_year(
  p_id text,
  p_starts_on date,
  p_ends_on date,
  p_forms_folder_id text default null,
  p_copy_bonuses_from text default null,
  p_make_current boolean default false
) returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_source_year text;
begin
  if not public.is_officer() then
    raise exception 'not authorized';
  end if;

  -- Safe to re-run: an officer double-clicking "create year" (or the dashboard retrying a timed
  -- out request) must not error, duplicate the row, or duplicate role_bonus_config rows. If the
  -- year already exists, its row and bonus config are left exactly as they are — changing an
  -- existing year's dates or folder is a separate, explicit edit, not an implied side effect of
  -- calling create again.
  if exists (select 1 from public.academic_years where id = p_id) then
    raise notice 'academic year % already exists; leaving its row and bonus config unchanged', p_id;
  else
    if p_copy_bonuses_from is not null
       and not exists (select 1 from public.academic_years where id = p_copy_bonuses_from) then
      raise exception 'source year % does not exist', p_copy_bonuses_from;
    end if;

    -- Resolve the copy source BEFORE inserting p_id below, so "the most recent prior year" can
    -- never resolve to the row this call is in the middle of creating.
    if p_copy_bonuses_from is not null then
      v_source_year := p_copy_bonuses_from;
    else
      select id into v_source_year
      from public.academic_years
      order by starts_on desc
      limit 1;
    end if;

    insert into public.academic_years (id, starts_on, ends_on, forms_folder_id)
    values (p_id, p_starts_on, p_ends_on, p_forms_folder_id);

    if v_source_year is not null then
      insert into public.role_bonus_config (year_id, role, points)
      select p_id, role, points
      from public.role_bonus_config
      where year_id = v_source_year
      on conflict (year_id, role) do nothing;
    else
      -- No prior year exists at all — there is nothing to copy from. Seed the established values
      -- (see the seed migration, 20260731024919_seed_and_migrate_legacy.sql) rather than leaving
      -- role_bonus_config empty, which would silently zero out this year's role bonuses.
      insert into public.role_bonus_config (year_id, role, points) values
        (p_id, 'eboard', 5),
        (p_id, 'chair', 3);
    end if;
  end if;

  -- Independent of the branch above: making a year current is idempotent on its own (it's a
  -- single-row UPDATE), so it's safe to honor even when the year already existed — an officer
  -- re-running create with make_current on an existing year still gets the switch they asked for.
  if p_make_current then
    update public.app_config set value = p_id where key = 'current_year_id';
  end if;
end
$$;

revoke all on function public.create_academic_year(text, date, date, text, text, boolean) from public, anon;
grant execute on function public.create_academic_year(text, date, date, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Fix resolve_unmatched_signin: membership forms must not pay attendance
-- ---------------------------------------------------------------------------

-- Same signature, same gating, same atomicity guarantee as the original (20260731025006) — only
-- the body changes, so no grant/revoke needed here; CREATE OR REPLACE preserves both the existing
-- grants to `authenticated` and the `search_path` pin applied in 20260731025444.
--
-- The bug: this function always inserted into `attendance`. When the unmatched row's event is a
-- membership form (`event_types.is_membership_form`), that pays attendance points for submitting
-- the membership form — the exact phantom-attendance the Edge Function's own routing comment
-- (supabase/functions/ingest-checkin/index.ts) says it exists to avoid. The routing was written;
-- the landing side wasn't. Points from this table feed an ~$800 sponsorship decision, so this is
-- a correctness fix, not a cosmetic one.
create or replace function public.resolve_unmatched_signin(p_id bigint, p_netid text)
returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_event uuid;
  v_points numeric;
  v_occurred_on date;
  v_is_membership boolean;
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

  -- left join event_types: an untyped event (type_code is null, still awaiting the one tap) must
  -- behave exactly as it does today — v_is_membership false, attendance recorded at 0 points and
  -- restamped later by events_restamp_attendance when the type is finally set.
  select e.points, e.occurred_on, coalesce(et.is_membership_form, false)
    into v_points, v_occurred_on, v_is_membership
  from public.events e
  left join public.event_types et on et.code = e.type_code
  where e.id = v_event;

  if v_is_membership then
    -- Route to memberships instead of attendance. year_id is resolved from the event's date
    -- against academic_years, per docs/DESIGN.md Phase 3b, rather than from app_config's
    -- current_year_id — a membership form submitted near a year boundary, or resolved late from
    -- the queue, must land in the year it was actually filled out in, not whatever year happens
    -- to be current when an officer gets around to clicking Attach.
    select ay.id into v_year_id
    from public.academic_years ay
    where v_occurred_on between ay.starts_on and ay.ends_on;

    if v_year_id is null then
      raise exception 'no academic year covers %', v_occurred_on;
    end if;

    -- netid + year_id ONLY. The design doc lists class_level, major, gender, expected_grad_year,
    -- college and birthday as coming from the form, but raw_payload (see
    -- supabase/functions/ingest-checkin/index.ts and _shared/netid.ts) is a free-text
    -- {question, answer}[] array — whatever wording the officer who built that particular form
    -- happened to use, with no fixed key for "major" or "gender" the way there is for identity.
    -- resolveIdentity() can afford to pattern-match question titles for netID because a wrong
    -- match just gets caught by dedup and FK constraints; there is no equivalent safety net for a
    -- guessed major or gender, and a silently wrong one corrupts a number that decides an $800
    -- sponsorship. A membership row with null demographics is visible on the Roster screen and
    -- correct; an invented demographic is neither. If this ever changes, it should be a
    -- deliberate, reviewed mapping added here — not a guess.
    insert into public.memberships (netid, year_id)
    values (p_netid, v_year_id)
    on conflict (netid, year_id) do nothing;
  else
    insert into public.attendance (event_id, netid, points_awarded, source)
    values (v_event, p_netid, coalesce(v_points, 0), 'form')
    on conflict (event_id, netid) do nothing;
  end if;

  update public.unmatched_signins
     set resolved_netid = p_netid, resolved_at = now()
   where id = p_id;
end
$$;

commit;
