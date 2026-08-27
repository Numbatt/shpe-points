-- Dedupe `unmatched_signins`, the way `attendance` has always deduped.
--
-- THE BUG. `attendance` upserts with `onConflict: 'event_id,netid', ignoreDuplicates: true`
-- (supabase/functions/ingest-checkin/index.ts, the write right above the one this migration is
-- about), so re-sending the same response never creates a second attendance row. `unmatched_signins`
-- never got the same treatment -- it has no netid to key on (that is the whole reason a row lands
-- there), so it has always been a plain `.insert(unmatchedRows)`. Every re-poll of a form that still
-- has an unresolved sign-in re-inserts that response as a brand new row.
--
-- That is exactly what produced the "duplicate Fall GBM 1" an officer saw on the dashboard: two
-- `unmatched_signins` rows, id 9 (2026-08-10) and id 13 (2026-08-27), both `pa30@rice.ede` (the
-- known typo of pa30@rice.edu) against the same event. Not a duplicate event -- the event-level
-- duplicate was already reconciled by 20260825210000_reconcile_aug28_duplicate.sql -- a duplicate
-- unmatched sign-in, produced by the poller re-sending a response nobody had attached or dismissed
-- yet.
--
-- THE FIX. Every unmatched row's `raw_payload` carries the Google Form's own `responseId`
-- (ingest-checkin/index.ts:375-378, :398-401) -- a stable, never-reused per-submission key, which is
-- precisely the kind of key `onConflict` needs and which `unmatched_signins` doesn't otherwise have.
-- A generated column exposes it as a normal, indexable text column without duplicating the write
-- path; the unique index gives the Edge Function's `onConflict: 'event_id,response_id'` upsert an
-- arbiter to target, the same way `attendance_event_id_netid_key` (implied by its own upsert) does
-- for attendance.
--
-- Deliberately NOT a partial index (`where response_id is not null`): PostgREST's `onConflict`
-- option compiles to a plain `ON CONFLICT (event_id, response_id) DO NOTHING`, with no predicate.
-- Postgres can only infer a partial index as the arbiter when the ON CONFLICT clause repeats that
-- same predicate, which the Supabase client has no way to add here. A full (non-partial) unique
-- index is what makes the upsert actually work -- and it costs nothing: Postgres already treats
-- every NULL as distinct from every other NULL in a unique index, so rows with no responseId (none
-- exist today, but nothing guarantees that forever) can still coexist without tripping it.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------------------------
alter table public.unmatched_signins
  add column response_id text generated always as (raw_payload ->> 'responseId') stored;

comment on column public.unmatched_signins.response_id is
  'The submitting Google Form response''s own id, lifted out of raw_payload for indexing. Stable '
  'and never reused per submission, which is what lets (event_id, response_id) dedupe re-polled '
  'sign-ins the same way (event_id, netid) already dedupes attendance. Null for any row whose '
  'raw_payload predates this field or omits it, which is harmless -- see the unique index below.';

-- ---------------------------------------------------------------------------------------------
-- 2. Clean up the duplicates that already exist, BEFORE the unique index below -- a duplicate row
--    still on disk would make that index creation fail.
--
-- Written as "keep the earliest row per (event_id, response_id), delete the rest" rather than as a
-- hand-typed `delete ... where id = 13`: a general rule is correct for the one known pair (id 9 and
-- id 13, both pa30@rice.ede against e0feb9ac-1da9-4b69-a693-a00c1e71816c) without having to assume
-- nothing else duplicated between the audit that found that pair and this migration running -- the
-- same reasoning 20260825210000_reconcile_aug28_duplicate.sql used for its own cleanup.
--
-- "Earliest" is (created_at, id) ascending, so a tie on created_at still resolves deterministically.
-- Rows with response_id null are excluded from the ranking entirely -- GROUP BY / PARTITION BY
-- treats all NULLs as one group, and this table's own NULLs are unrelated submissions that merely
-- lack a responseId, not duplicates of one another.
-- ---------------------------------------------------------------------------------------------

-- Safety check first, in the same spirit as the Aug 28 reconciliation: refuse to silently discard
-- an officer's decision. If a "duplicate" being deleted was itself the one that got Attached or
-- Dismissed while its earlier twin sat untouched, deleting it would erase that decision with no
-- record of it happening. Nothing in the known pair (both still unresolved, per the screenshot that
-- surfaced this) trips this, so it is expected to pass vacuously today.
do $$
declare
  v_bad_id bigint;
begin
  select u.id into v_bad_id
    from public.unmatched_signins u
    join lateral (
      select k.id
        from public.unmatched_signins k
       where k.event_id = u.event_id
         and k.response_id = u.response_id
       order by k.created_at, k.id
       limit 1
    ) keep on true
   where u.response_id is not null
     and u.id <> keep.id
     and (u.resolved_netid is not null or u.resolved_at is not null)
   limit 1;

  if v_bad_id is not null then
    raise exception
      'unmatched_signins id % is a duplicate response but carries resolution state (resolved_netid '
      'or resolved_at set); resolve this by hand before the dedupe migration can run', v_bad_id;
  end if;
end
$$;

delete from public.unmatched_signins u
 using (
   select id,
          row_number() over (partition by event_id, response_id order by created_at, id) as rn
     from public.unmatched_signins
    where response_id is not null
 ) ranked
 where u.id = ranked.id
   and ranked.rn > 1;

-- ---------------------------------------------------------------------------------------------
-- 3. The unique index the Edge Function's upsert targets.
-- ---------------------------------------------------------------------------------------------
create unique index unmatched_signins_event_response_idx
  on public.unmatched_signins (event_id, response_id);

commit;

-- The dedupe DELETE is idempotent by construction: re-running it finds no row with rn > 1, because
-- every surviving group already has exactly one member. The DDL around it (the new column, the new
-- index) is not guarded with `if not exists` and would fail loudly on a second run against an
-- already-migrated database -- the same as every other migration in this repo, none of which guard
-- their DDL either. That is the desired failure mode: a replay should stop and be looked at, not
-- silently no-op past a step that mattered.
