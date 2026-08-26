\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
create table if not exists _t (n serial, label text, ok boolean, detail text);
truncate _t;
grant all on _t to public;
grant all on _t_n_seq to public;

create or replace function t(p_label text, p_ok boolean, p_detail text default null)
returns void language sql as $$ insert into _t(label, ok, detail) values (p_label, p_ok, p_detail) $$;

-- Records whether a statement raised, and with what message.
create or replace function t_raises(p_label text, p_sql text, p_expect text)
returns void language plpgsql as $$
declare v_msg text;
begin
  execute p_sql;
  perform t(p_label, false, 'expected a rejection, statement succeeded');
exception when others then
  v_msg := sqlerrm;
  perform t(p_label, position(lower(p_expect) in lower(v_msg)) > 0, v_msg);
end $$;

-- ---------------------------------------------------------------------------
\o /dev/null
-- Seed: the real Aug 28 shape, shrunk. One form-backed event that is both the
-- GBM sign-in and the membership form, with attendance already ingested.
-- ---------------------------------------------------------------------------
insert into academic_years (id, starts_on, ends_on) values
  ('2025-26', '2025-08-01', '2026-07-31'),
  ('2026-27', '2026-08-01', '2027-07-31');

insert into event_types (code, label, default_points, is_membership_form) values
  ('gbm', 'GBM', 1, false),
  ('volunteer', 'Volunteering', 0, false),
  ('membership', 'Membership form', 0, true);

insert into people (netid) values ('dr56'), ('mg236'), ('pa30'), ('sam35'), ('zz99');

insert into officers (email, active) values ('dr56@rice.edu', true);

-- e0: the dual-role event. Form-backed, typed gbm, attendance already recorded.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000001', 'Fall GBM 1', 'gbm', '2025-08-28', 1, 'form');
insert into forms (form_id, event_id, last_response_at) values
  ('form-e0', 'e0000000-0000-0000-0000-000000000001', '2025-08-28 20:00Z');
insert into attendance (event_id, netid, points_awarded, source) values
  ('e0000000-0000-0000-0000-000000000001', 'dr56',  1, 'form'),
  ('e0000000-0000-0000-0000-000000000001', 'mg236', 1, 'form'),
  ('e0000000-0000-0000-0000-000000000001', 'pa30',  1, 'backfill');

-- e1: another form-backed event in the SAME year, for exclusivity tests.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000002', 'Fall GBM 2', 'gbm', '2025-09-25', 1, 'form');
insert into forms (form_id, event_id, last_response_at) values
  ('form-e1', 'e0000000-0000-0000-0000-000000000002', '2025-09-25 20:00Z');

-- e2: a form-backed event in a DIFFERENT year.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000003', 'Fall GBM 1 (26-27)', 'gbm', '2026-08-27', 1, 'form');
insert into forms (form_id, event_id, last_response_at) values
  ('form-e2', 'e0000000-0000-0000-0000-000000000003', '2026-08-27 20:00Z');

-- e3: a MANUAL event, no forms row. The mis-tap guard.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000004', 'Hand-entered social', null, '2025-10-10', null, 'manual');
insert into attendance (event_id, netid, points_awarded, source) values
  ('e0000000-0000-0000-0000-000000000004', 'sam35', 0, 'manual');

-- e4: an event whose date no academic year covers.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000005', 'Orphan', null, '2020-01-01', null, 'manual');

-- ---------------------------------------------------------------------------
-- 1. Backfill + column defaults
-- ---------------------------------------------------------------------------
select t('new events default to collects_membership = false',
  (select not collects_membership from events where id = 'e0000000-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------------
-- 2. Dual role: toggling membership on KEEPS attendance and forces a replay
-- ---------------------------------------------------------------------------
update events set collects_membership = true where id = 'e0000000-0000-0000-0000-000000000001';

select t('dual-role toggle keeps every attendance row',
  (select count(*) = 3 from attendance where event_id = 'e0000000-0000-0000-0000-000000000001'),
  (select count(*)::text from attendance where event_id = 'e0000000-0000-0000-0000-000000000001'));

select t('dual-role toggle keeps the hand-carried backfill row',
  (select exists (select 1 from attendance
     where event_id = 'e0000000-0000-0000-0000-000000000001' and netid = 'pa30')));

select t('dual-role toggle resets the high-water mark so the poller replays',
  (select last_response_at is null from forms where form_id = 'form-e0'));

select t('the event still pays its GBM point',
  (select points_awarded = 1 from attendance
    where event_id = 'e0000000-0000-0000-0000-000000000001' and netid = 'dr56'));

-- ---------------------------------------------------------------------------
-- 3. Exclusivity, scoped per academic year
-- ---------------------------------------------------------------------------
select t_raises('a second membership event in the same year is rejected',
  $$update events set collects_membership = true where id = 'e0000000-0000-0000-0000-000000000002'$$,
  'is already the membership form');

select t('...and the rejected event was not modified',
  (select not collects_membership from events where id = 'e0000000-0000-0000-0000-000000000002'));

update events set collects_membership = true where id = 'e0000000-0000-0000-0000-000000000003';
select t('a membership event in a DIFFERENT year is allowed',
  (select collects_membership from events where id = 'e0000000-0000-0000-0000-000000000003'));

-- Clearing frees the slot again.
update events set collects_membership = false where id = 'e0000000-0000-0000-0000-000000000001';
update events set collects_membership = true  where id = 'e0000000-0000-0000-0000-000000000002';
select t('clearing the flag frees the year for another event',
  (select collects_membership from events where id = 'e0000000-0000-0000-0000-000000000002'));

-- Put it back the way it was.
update events set collects_membership = false where id = 'e0000000-0000-0000-0000-000000000002';
update events set collects_membership = true  where id = 'e0000000-0000-0000-0000-000000000001';

select t_raises('an event no academic year covers is refused, not silently accepted',
  $$update events set collects_membership = true where id = 'e0000000-0000-0000-0000-000000000005'$$,
  'no academic year covers');

-- The collision can also arrive by moving a date into an occupied year.
select t_raises('moving an event into an occupied year is caught too',
  $$update events set occurred_on = '2025-10-01' where id = 'e0000000-0000-0000-0000-000000000003'$$,
  'is already the membership form');

-- ---------------------------------------------------------------------------
-- 3b. A membership TYPE implies collecting membership, and obeys the same limit
-- ---------------------------------------------------------------------------

-- The backfill runs once. An event typed `membership` for the first time AFTER it must still claim
-- its year's slot, or two membership forms could coexist and silently overwrite each other.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000010', 'Late-typed drive', null, '2027-09-01', null, 'form');
insert into academic_years (id, starts_on, ends_on) values ('2027-28', '2027-08-01', '2028-07-31');
update events set type_code = 'membership' where id = 'e0000000-0000-0000-0000-000000000010';

select t('typing an event as a membership form sets collects_membership',
  (select collects_membership from events where id = 'e0000000-0000-0000-0000-000000000010'));

insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000011', 'A second drive, same year', null, '2027-10-01', null, 'form');
select t_raises('...so a SECOND membership-typed event in that year is rejected',
  $$update events set type_code = 'membership' where id = 'e0000000-0000-0000-0000-000000000011'$$,
  'is already the membership form');

select t_raises('...and inserting one already typed is rejected too',
  $$insert into events (name, type_code, occurred_on, points, source)
    values ('Straight in', 'membership', '2027-11-01', 0, 'form')$$,
  'is already the membership form');

-- Retyping away leaves the slot claimed: the form did collect those demographics, and giving the
-- slot up is an explicit act rather than a side effect of fixing a type.
update events set type_code = 'gbm' where id = 'e0000000-0000-0000-0000-000000000010';
select t('retyping away from membership keeps the year''s slot claimed',
  (select collects_membership from events where id = 'e0000000-0000-0000-0000-000000000010'));

-- ---------------------------------------------------------------------------
-- 4. Pure membership form still deletes, and the manual-event guard still holds
-- ---------------------------------------------------------------------------
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000006', 'Standalone membership drive', null, '2026-09-05', null, 'form');
insert into forms (form_id, event_id, last_response_at) values
  ('form-e5', 'e0000000-0000-0000-0000-000000000006', '2026-09-05 20:00Z');
insert into attendance (event_id, netid, points_awarded, source) values
  ('e0000000-0000-0000-0000-000000000006', 'zz99', 0, 'form');

-- 2026-27 already has e2 collecting membership, so clear it first: a pure membership TYPE also
-- sets the flag, and must obey the same one-per-year rule.
update events set collects_membership = false where id = 'e0000000-0000-0000-0000-000000000003';
update events set type_code = 'membership' where id = 'e0000000-0000-0000-0000-000000000006';

select t('a PURE membership form still clears its 0-point rows',
  (select count(*) = 0 from attendance where event_id = 'e0000000-0000-0000-0000-000000000006'));
select t('...and still resets its high-water mark',
  (select last_response_at is null from forms where form_id = 'form-e5'));

-- Needs a year whose slot is free, because typing `membership` now claims one (rule 1 above).
-- The point of this check is the OTHER guard: an event with no forms row has no replay source, so
-- its attendance must survive a mis-tap that would delete a form-backed event's.
insert into academic_years (id, starts_on, ends_on) values ('2028-29', '2028-08-01', '2029-07-31');
update events set occurred_on = '2028-09-01' where id = 'e0000000-0000-0000-0000-000000000004';
update events set type_code = 'membership' where id = 'e0000000-0000-0000-0000-000000000004';
select t('a MANUAL event with no form keeps its attendance (nothing could replay it)',
  (select count(*) = 1 from attendance where event_id = 'e0000000-0000-0000-0000-000000000004'));
update events set type_code = null, collects_membership = false
 where id = 'e0000000-0000-0000-0000-000000000004';

-- ---------------------------------------------------------------------------
-- 5. Audit trail
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"email":"dr56@rice.edu"}', false);

update events set type_code = 'volunteer' where id = 'e0000000-0000-0000-0000-000000000002';
select t('a type change is logged with the officer from the JWT',
  (select changed_by = 'dr56@rice.edu' and old_value = 'gbm' and new_value = 'volunteer'
     from event_changes where event_id = 'e0000000-0000-0000-0000-000000000002'
      and field = 'type_code' order by id desc limit 1));

update events set ignored_at = now(), ignored_by = 'dr56@rice.edu'
 where id = 'e0000000-0000-0000-0000-000000000002';
select t('dismissing an event is logged',
  (select count(*) = 1 from event_changes
    where event_id = 'e0000000-0000-0000-0000-000000000002' and field = 'ignored_at'));

select set_config('request.jwt.claims', '', false);
update events set type_code = 'gbm' where id = 'e0000000-0000-0000-0000-000000000002';
select t('a change with no authenticated user is logged as system',
  (select changed_by = 'system' from event_changes
    where event_id = 'e0000000-0000-0000-0000-000000000002' and field = 'type_code'
    order by id desc limit 1));

select t('the membership toggle was logged too',
  (select count(*) >= 1 from event_changes where field = 'collects_membership'));

-- ---------------------------------------------------------------------------
-- 6. resolve_unmatched_signin writes BOTH on a dual-role event
-- ---------------------------------------------------------------------------
update events set ignored_at = null, ignored_by = null where id = 'e0000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claims', '{"email":"dr56@rice.edu"}', false);
set role authenticated;

insert into unmatched_signins (event_id, raw_identifier, raw_payload) values
  ('e0000000-0000-0000-0000-000000000001', 'Sam Martinez', '{}'::jsonb);

select resolve_unmatched_signin((select id from unmatched_signins order by id desc limit 1), 'sam35');

select t('resolving on a dual-role event records ATTENDANCE',
  (select exists (select 1 from attendance
     where event_id = 'e0000000-0000-0000-0000-000000000001' and netid = 'sam35')));
select t('...and pays the event''s points, not zero',
  (select points_awarded = 1 from attendance
     where event_id = 'e0000000-0000-0000-0000-000000000001' and netid = 'sam35'));
select t('...and ALSO records a membership row',
  (select exists (select 1 from memberships where netid = 'sam35' and year_id = '2025-26')));

reset role;

-- A pure membership form must still record membership ONLY, never attendance.
insert into unmatched_signins (event_id, raw_identifier, raw_payload) values
  ('e0000000-0000-0000-0000-000000000006', 'Zed Zeta', '{}'::jsonb);
set role authenticated;
select resolve_unmatched_signin((select id from unmatched_signins order by id desc limit 1), 'zz99');
reset role;
select t('a PURE membership form still records no attendance',
  (select count(*) = 0 from attendance where event_id = 'e0000000-0000-0000-0000-000000000006'));
select t('...but does record the membership',
  (select exists (select 1 from memberships where netid = 'zz99' and year_id = '2026-27')));

-- ---------------------------------------------------------------------------
-- 7. The ranged-standings equality still holds
-- ---------------------------------------------------------------------------
select t('member_totals_between(null,null) == v_member_totals, both directions',
  not exists (select * from member_totals_between(null,null) except select * from v_member_totals)
  and not exists (select * from v_member_totals except select * from member_totals_between(null,null)));

-- ---------------------------------------------------------------------------
-- 8. RLS on the audit log
-- ---------------------------------------------------------------------------
select t_raises('anon cannot read the audit log',
  $$set local role anon; select count(*) from event_changes$$,
  'permission denied');

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
\o
select case when ok then '  ok  ' else ' FAIL ' end as "res", label as "check",
       case when ok then null else detail end as "detail"
  from _t order by n;
\o
select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' as result from _t;
