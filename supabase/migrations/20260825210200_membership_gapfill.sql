-- Let a sign-in form COMPLETE an existing membership record, without ever creating one.
--
-- THE GAP THIS CLOSES. Every GBM sign-in form the chapter has ever used asks Gender, College,
-- Year and Major alongside the netID — the demographics the October deliberation slices by. The
-- ingest function throws all of it away for anyone it can match to a netID, because only an event
-- typed as a membership form routes into `memberships`; every other response becomes an
-- attendance row and the answers are discarded. So a member who filled the membership form but
-- left Major blank, and then answered Major on six sign-in forms across the year, still has a null
-- major in the grid that decides an ~$800 sponsorship.
--
-- THE RULE, AND WHY IT IS DELIBERATELY NARROW.
--
--   A sign-in may fill a column that is NULL. It may never overwrite one, and it may never create
--   a membership row.
--
-- The second half is the important half, and it was a product decision rather than a technical
-- one. `v_member_totals.is_current_member` is literally `(m.netid is not null)`
-- (20260731024941_views_rls_and_public_cutover.sql), so inserting a row here would silently
-- promote "attended one GBM" to "is a member this year" — quietly emptying the Roster screen's
-- "has points but no membership form" chase-list, which is the tool officers use in September to
-- go get those people. Membership stays something a person opts into by filling the form, and a
-- member is someone the chapter has complete information about. Anyone who skips the form gets no
-- demographics and stays off the deliberation grid; that is the intended pressure, not a gap.
--
-- The consequence to be honest about: with zero membership rows in the database today, this
-- function writes NOTHING until the 2026-27 membership form is ingested at the first GBM. It is
-- inert and then it activates. That is correct, not a bug to work around.
--
-- WHY THIS IS A FUNCTION AND NOT A READ-MODIFY-WRITE IN TYPESCRIPT. Three independent reasons,
-- any one sufficient: the 15-minute poller races an officer editing the Roster in the dashboard,
-- and a read-then-write loses whichever one read first; a single poller pass can carry two forms
-- touching the same (netid, year_id), and Postgres rejects an ON CONFLICT DO UPDATE that affects
-- one row twice in a statement; and a data rule living in the Edge Function is a rule a future
-- backfill script does not inherit, which is exactly how `mac50` ended up next to `dea7@rice.edu`
-- in the legacy spreadsheet. Same argument as 20260731025006_officer_rpcs.sql makes for the RPCs.

begin;

create or replace function public.gapfill_membership_demographics(p_rows jsonb)
returns integer
language sql
security definer
set search_path = public
as $$
  with incoming as (
    select *
      from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb)) as r(
        netid              text,
        year_id            text,
        class_level        text,
        expected_grad_year int,
        gender             text,
        major              text,
        college            text,
        birthday           date
      )
  ),
  updated as (
    update public.memberships m
       set class_level        = coalesce(m.class_level,        i.class_level),
           expected_grad_year = coalesce(m.expected_grad_year, i.expected_grad_year),
           gender             = coalesce(m.gender,             i.gender),
           major              = coalesce(m.major,              i.major),
           college            = coalesce(m.college,            i.college),
           birthday           = coalesce(m.birthday,           i.birthday)
      from incoming i
     where m.netid = i.netid
       and m.year_id = i.year_id
       -- Only touch rows that actually gain something. Without this, every poller pass rewrites
       -- every membership row of every member who signed in, for no change.
       and (
            (m.class_level        is null and i.class_level        is not null)
         or (m.expected_grad_year is null and i.expected_grad_year is not null)
         or (m.gender             is null and i.gender             is not null)
         or (m.major              is null and i.major              is not null)
         or (m.college            is null and i.college            is not null)
         or (m.birthday           is null and i.birthday           is not null)
       )
    returning 1
  )
  select count(*)::int from updated;
$$;

-- UPDATE ... FROM with no INSERT is what enforces "never creates a member" at the database level
-- rather than by the caller remembering to. A future caller cannot get this wrong.
--
-- `submitted_at` is deliberately never written here. It records that a person DECLARED membership
-- on a date, it is set only by the membership-form path in ingest-checkin, and a sign-in is not a
-- declaration. It is also the column to reach for if is_current_member is ever redefined to mean
-- "actually filled the form" independently of row existence.
--
-- NOTE the inversion versus the membership-form path (ingest-checkin/index.ts, the
-- `memberships.upsert(...)` call): that one REPLACES every demographic column outright, including
-- with blanks, because a membership form response is a complete statement of this year's answers
-- and the newest one wins in full. This one only ever fills nulls, because a sign-in is a scrap.
-- The two rules must differ, and they compose in either order: form-then-signin leaves the form's
-- answers untouched (coalesce keeps the non-null), and signin-then-form is overwritten wholesale
-- by the authoritative path. Do not "unify" them.

-- security definer because the caller is the ingest Edge Function running as service_role, and the
-- write must not depend on whatever RLS context happens to apply. Locked to service_role only:
-- officers edit memberships directly through PostgREST under officers_all, and nothing in the
-- browser should be able to drive a bulk demographic write.
revoke all on function public.gapfill_membership_demographics(jsonb) from public, anon, authenticated;
grant execute on function public.gapfill_membership_demographics(jsonb) to service_role;

commit;
