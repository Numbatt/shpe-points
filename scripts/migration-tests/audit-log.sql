\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------------
-- Harness (same shape as dual-role.sql)
-- ---------------------------------------------------------------------------
create table if not exists _t (n serial, label text, ok boolean, detail text);
truncate _t;
grant all on _t to public;
grant all on _t_n_seq to public;

create or replace function t(p_label text, p_ok boolean, p_detail text default null)
returns void language sql as $$ insert into _t(label, ok, detail) values (p_label, p_ok, p_detail) $$;

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
-- Seed
-- ---------------------------------------------------------------------------
\o /dev/null

insert into academic_years (id, starts_on, ends_on) values ('2025-26', '2025-08-01', '2026-07-31');
insert into event_types (code, label, default_points) values ('gbm', 'GBM', 1);
insert into people (netid) values ('dr56'), ('zz99');
insert into officers (email, display_name, active) values ('dr56@rice.edu', 'Diego', true);
insert into role_bonus_config (year_id, role, points) values ('2025-26', 'eboard', 5), ('2025-26', 'chair', 3);
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000001', 'Fall GBM 1', null, '2025-08-28', null, 'manual');
insert into unmatched_signins (event_id, raw_identifier, raw_payload) values
  ('e0000000-0000-0000-0000-000000000001', 'zz99@rice.edu', '{"responseId":"resp-a"}'::jsonb),
  ('e0000000-0000-0000-0000-000000000001', 'ghost@rice.edu', '{"responseId":"resp-b"}'::jsonb);

-- ---------------------------------------------------------------------------
-- 1. officers: insert (add), update of active (activate/deactivate); display_name alone is not logged
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"email":"dr56@rice.edu"}', false);

insert into officers (email, display_name, active) values ('newofficer@rice.edu', 'New Officer', true);
select t('adding an officer is logged, with the actor from the JWT',
  (select summary = 'added as officer' and changed_by = 'dr56@rice.edu'
     from audit_log where table_name = 'officers' and record_id = 'newofficer@rice.edu'
     order by id desc limit 1));

update officers set active = false where email = 'newofficer@rice.edu';
select t('deactivating an officer is logged',
  (select summary = 'deactivated' from audit_log
     where table_name = 'officers' and record_id = 'newofficer@rice.edu' order by id desc limit 1));

update officers set active = true where email = 'newofficer@rice.edu';
select t('re-activating an officer is logged as activated',
  (select summary = 'activated' from audit_log
     where table_name = 'officers' and record_id = 'newofficer@rice.edu' order by id desc limit 1));

update officers set display_name = 'Renamed' where email = 'newofficer@rice.edu';
select t('a display_name-only edit is not logged (still exactly 3 rows: add, deactivate, activate)',
  (select count(*) = 3 from audit_log where table_name = 'officers' and record_id = 'newofficer@rice.edu'));

-- ---------------------------------------------------------------------------
-- 2. people: first_name/last_name changes
-- ---------------------------------------------------------------------------
update people set first_name = 'Zed', last_name = 'Zeta' where netid = 'zz99';
select t('a name save is logged with the new full name',
  (select summary = 'name set to Zed Zeta'
     from audit_log where table_name = 'people' and record_id = 'zz99' order by id desc limit 1));

update people set first_name = 'Zed' where netid = 'zz99';
select t('re-setting the same first_name value logs nothing new',
  (select count(*) = 1 from audit_log where table_name = 'people' and record_id = 'zz99'));

-- ---------------------------------------------------------------------------
-- 3. roles: insert (assigned), delete (removed)
-- ---------------------------------------------------------------------------
insert into roles (netid, year_id, role, position_title) values ('zz99', '2025-26', 'chair', 'VP Something');
select t('assigning a role is logged with a composite record_id',
  (select summary = 'assigned role chair for 2025-26'
     from audit_log where table_name = 'roles' and record_id = 'zz99|2025-26|chair' order by id desc limit 1));

delete from roles where netid = 'zz99' and year_id = '2025-26' and role = 'chair';
select t('removing a role is logged',
  (select summary = 'role chair removed for 2025-26'
     from audit_log where table_name = 'roles' and record_id = 'zz99|2025-26|chair' order by id desc limit 1));

-- ---------------------------------------------------------------------------
-- 4. role_bonus_config: update of points
-- ---------------------------------------------------------------------------
update role_bonus_config set points = 6 where year_id = '2025-26' and role = 'eboard';
select t('a bonus change is logged with old and new amounts',
  (select summary = 'eboard bonus changed from 5 to 6 for 2025-26'
     from audit_log where table_name = 'role_bonus_config' and record_id = '2025-26|eboard' order by id desc limit 1));

update role_bonus_config set points = 6 where year_id = '2025-26' and role = 'eboard';
select t('setting the same points value again logs nothing new',
  (select count(*) = 1 from audit_log where table_name = 'role_bonus_config' and record_id = '2025-26|eboard'));

-- ---------------------------------------------------------------------------
-- 5. unmatched_signins: Attach and Dismiss
-- ---------------------------------------------------------------------------
update unmatched_signins set resolved_netid = 'zz99', resolved_at = now()
 where raw_payload ->> 'responseId' = 'resp-a';
select t('attaching a sign-in is logged with the destination netid',
  (select summary = 'attached to zz99' from audit_log
     where table_name = 'unmatched_signins'
       and record_id = (select id::text from unmatched_signins where raw_payload ->> 'responseId' = 'resp-a')
     order by id desc limit 1));

update unmatched_signins set resolved_at = now()
 where raw_payload ->> 'responseId' = 'resp-b';
select t('dismissing a sign-in is logged',
  (select summary = 'dismissed' from audit_log
     where table_name = 'unmatched_signins'
       and record_id = (select id::text from unmatched_signins where raw_payload ->> 'responseId' = 'resp-b')
     order by id desc limit 1));

update unmatched_signins set resolved_at = null where raw_payload ->> 'responseId' = 'resp-b';
select t('un-dismissing (clearing resolved_at back to null) is not logged',
  (select count(*) = 1 from audit_log
     where table_name = 'unmatched_signins'
       and record_id = (select id::text from unmatched_signins where raw_payload ->> 'responseId' = 'resp-b')));

-- ---------------------------------------------------------------------------
-- 6. changed_by falls back to 'system' with no authenticated user
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '', false);
update people set first_name = 'Zoe' where netid = 'zz99';
select t('a change with no authenticated user is logged as system',
  (select changed_by = 'system' from audit_log
     where table_name = 'people' and record_id = 'zz99' order by id desc limit 1));

select set_config('request.jwt.claims', '{"email":"dr56@rice.edu"}', false);

-- ---------------------------------------------------------------------------
-- 7. v_audit_log unions all three sources with the target column shape
-- ---------------------------------------------------------------------------
update events set type_code = 'gbm' where id = 'e0000000-0000-0000-0000-000000000001';
insert into adjustments (netid, year_id, points, kind, reason, effective_on, created_by)
values ('zz99', '2025-26', 5, 'manual', 'test bonus', '2025-09-01', 'dr56@rice.edu');

select t('v_audit_log has exactly the target column list, in order',
  (select array_agg(column_name::text order by ordinal_position)
            = array['changed_at', 'changed_by', 'summary', 'table_name', 'record_id']
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_audit_log'));

select t('v_audit_log includes an audit_log-sourced row',
  (select exists (select 1 from v_audit_log where table_name = 'people' and record_id = 'zz99')));

select t('v_audit_log includes an event_changes-sourced row',
  (select exists (select 1 from v_audit_log where table_name = 'events' and summary like 'type_code:%')));

select t('v_audit_log includes an adjustments-sourced row',
  (select exists (select 1 from v_audit_log
     where table_name = 'adjustments' and summary = 'manual: test bonus (5 pts)')));

-- ---------------------------------------------------------------------------
-- 8. RLS: officers-only, enforced through the view (security_invoker), not just the table
-- ---------------------------------------------------------------------------
select t_raises('anon cannot read audit_log directly',
  $$set local role anon; select count(*) from audit_log$$,
  'permission denied');

select t_raises('anon cannot read v_audit_log',
  $$set local role anon; select count(*) from v_audit_log$$,
  'permission denied');

select set_config('request.jwt.claims', '{"email":"nobody@rice.edu"}', false);
set role authenticated;
select t('a signed-in non-officer sees zero rows through v_audit_log (RLS applies through the view)',
  (select count(*) = 0 from v_audit_log));
reset role;

select set_config('request.jwt.claims', '{"email":"dr56@rice.edu"}', false);
set role authenticated;
select t('an officer sees audit rows through v_audit_log',
  (select count(*) > 0 from v_audit_log));
reset role;

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
\o
select case when ok then '  ok  ' else ' FAIL ' end as "res", label as "check",
       case when ok then null else detail end as "detail"
  from _t order by n;
\o
select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' as result from _t;
