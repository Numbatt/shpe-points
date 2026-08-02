-- Move the legacy objects out of `public`, BEFORE the new schema is created.
--
-- This ordering is not cosmetic. Postgres treats public."Attendance" and public.attendance as
-- different tables, but their indexes and constraints are just NAMES in a single schema
-- namespace. Legacy already owns `attendance_pkey`, `events_pkey`, `adjustments_pkey` and
-- `attendance_event_idx`, so creating the new tables while the old ones sat in `public` failed
-- on the first collision and would have failed on several more.
--
-- Moving the tables carries their indexes and constraints with them and frees every name.
--
-- The public leaderboard is unaffected by this migration. `public.member_totals_all_time` stays
-- in place and keeps returning the same totals, because a view holds OID references to its base
-- tables rather than schema-qualified names. It is replaced later, in the cutover migration.
--
-- Legacy is kept rather than dropped: `scripts/legacy-export/` is the durable snapshot, but
-- leaving the tables live in another schema is a far cheaper rollback than reloading CSVs, and it
-- costs nothing. Nothing reads them after the cutover.

begin;

create schema legacy;

alter view  public.attendance_with_details  set schema legacy;
alter table public."Attendance"             set schema legacy;
alter table public."Adjustments"            set schema legacy;
alter table public."E-board and Chairs"     set schema legacy;
alter table public."Events"                 set schema legacy;
alter table public."Event Categories"       set schema legacy;
alter table public."Members"                set schema legacy;

-- PostgREST only exposes `public`, but revoke explicitly so the guarantee does not depend on
-- that configuration staying as it is.
revoke all on all tables in schema legacy from anon, authenticated;
revoke usage on schema legacy from anon, authenticated;

commit;
