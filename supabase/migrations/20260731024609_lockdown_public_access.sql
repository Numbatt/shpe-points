-- Lockdown: close public read/write access to the legacy schema.
--
-- Context (audited 2026-07-30, before any rebuild work):
--   The anon key is published in plaintext on the shpe.rice.edu leaderboard page. Against that
--   key, all of the following were live:
--
--     1. `anon` held SELECT on every base table — netIDs, names, and the full attendance ledger.
--     2. `attendance_with_details` is owned by `postgres` and is NOT `security_invoker`, so it
--        bypasses RLS entirely and returned all 840 attendance rows joined to member names.
--     3. `attendance_staging` had RLS *disabled* plus anon INSERT/UPDATE/DELETE — an open write
--        door into `public`, reachable through PostgREST.
--     4. `member_totals_all_time` exposed `netid` and `status`, beyond the intended public
--        contract of name + points.
--
--   Items 1 and 2 were confirmed empirically: `scripts/export-legacy.mjs` pulled every row using
--   nothing but the anon key.
--
-- This migration closes 1-3. Item 4 is fixed in the Phase 1 view rebuild, which needs the new
-- schema underneath it.
--
-- The public leaderboard keeps working throughout. `member_totals_all_time` is owned by `postgres`
-- and is not `security_invoker`, so it reads its base tables with the *owner's* rights regardless
-- of what `anon` can reach directly. That property is load-bearing: do not add `security_invoker`
-- to the public view without also granting `anon` read on the tables underneath it, which would
-- undo this entire migration.

begin;

-- 1. Drop the blanket-read policies added by 20260206192008. Each was `USING (true)` for `anon`.
drop policy if exists "Allow public read access to members"          on public."Members";
drop policy if exists "Allow public read access to events"           on public."Events";
drop policy if exists "Allow public read access to attendance"       on public."Attendance";
drop policy if exists "Allow public read access to event categories" on public."Event Categories";
drop policy if exists "Allow public read access to leadership"       on public."E-board and Chairs";
drop policy if exists "Allow public read access to adjustments"      on public."Adjustments";

-- 2. Remove the staging table outright. It is empty, it had RLS disabled with full anon writes,
--    and the paste-into-staging ritual it existed for is precisely what this rebuild replaces.
drop table if exists public.attendance_staging;

-- 3. Revoke every standing grant. This covers views as well as tables, so it also closes
--    `attendance_with_details`. Sequences and functions are included because Supabase's defaults
--    grant those to anon too.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- 4. Stop the hole from reopening. Supabase's default privileges auto-grant anon full rights on
--    every newly created table, which is how this happened in the first place — so revoking the
--    current grants alone would last exactly until the Phase 1 migration creates its first table.
--    Default ACLs exist for both `postgres` and `supabase_admin` in this project.
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;

-- `postgres` is generally not a member of `supabase_admin`, so this may not be permitted. It is
-- not required for correctness: our migrations run as `postgres`, so objects they create follow
-- the `postgres` default ACL revoked above. Phase 1 additionally revokes explicitly on each table
-- it creates, so this is the third layer of the same guarantee, not the only one.
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon, authenticated';
exception when insufficient_privilege or invalid_grant_operation then
  raise notice 'Could not alter supabase_admin default privileges (expected); postgres defaults are revoked and Phase 1 revokes per-table.';
end
$$;

-- 5. Re-grant the single intended public surface: the leaderboard view the shpe.rice.edu
--    webmasters query. This is the only object `anon` can reach in `public`.
grant select on public.member_totals_all_time to anon;

commit;
