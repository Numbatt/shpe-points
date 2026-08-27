\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------------
-- Harness (same shape as dual-role.sql)
-- ---------------------------------------------------------------------------
create table if not exists _t (n serial, label text, ok boolean, detail text);
truncate _t;

create or replace function t(p_label text, p_ok boolean, p_detail text default null)
returns void language sql as $$ insert into _t(label, ok, detail) values (p_label, p_ok, p_detail) $$;

-- Records whether a statement raised, and with what message (same as dual-role.sql's t_raises).
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

-- 1. The one-time cleanup of the pre-existing duplicate pair.
select t('exactly one row of the known-duplicate pair survives',
  (select count(*) = 1 from unmatched_signins where raw_payload ->> 'responseId' = 'resp-dup-1'));

select t('the surviving row is the EARLIER one (2026-08-10, not 2026-08-27)',
  (select created_at = '2026-08-10 12:00:00+00'
     from unmatched_signins where raw_payload ->> 'responseId' = 'resp-dup-1'),
  (select created_at::text from unmatched_signins where raw_payload ->> 'responseId' = 'resp-dup-1'));

select t('rows with no responseId are left alone, not treated as duplicates of each other',
  (select count(*) = 2 from unmatched_signins where response_id is null));

select t('an unrelated single response on the same event is untouched',
  (select count(*) = 1 from unmatched_signins where raw_payload ->> 'responseId' = 'resp-solo'));

-- 2. The generated column itself.
select t('response_id is generated from raw_payload->>responseId',
  (select response_id = 'resp-solo' from unmatched_signins where raw_payload ->> 'responseId' = 'resp-solo'));

-- 3. The unique index behaves the way the Edge Function's new upsert needs it to.
insert into unmatched_signins (event_id, raw_identifier, raw_payload)
values ('e0000000-0000-0000-0000-000000000001', 'pa30@rice.ede',
        '{"responseId":"resp-dup-1","submittedAt":"2025-08-28T20:00:00Z","answers":[]}'::jsonb)
on conflict (event_id, response_id) do nothing;

select t('re-polling an already-seen response no-ops (mirrors the Edge Function''s new upsert)',
  (select count(*) = 1 from unmatched_signins where raw_payload ->> 'responseId' = 'resp-dup-1'));

insert into unmatched_signins (event_id, raw_identifier, raw_payload)
values ('e0000000-0000-0000-0000-000000000001', 'newperson@rice.edu',
        '{"responseId":"resp-new","submittedAt":"2025-08-28T20:10:00Z","answers":[]}'::jsonb)
on conflict (event_id, response_id) do nothing;

select t('a genuinely new response still inserts normally',
  (select count(*) = 1 from unmatched_signins where raw_payload ->> 'responseId' = 'resp-new'));

-- A plain insert with no ON CONFLICT clause must still fail loudly against a real duplicate --
-- confirms this is a real unique index, not just something the upsert path happens to avoid
-- tripping.
select t_raises('a plain insert (no ON CONFLICT) against an existing (event_id, response_id) is rejected',
  $$insert into unmatched_signins (event_id, raw_identifier, raw_payload)
    values ('e0000000-0000-0000-0000-000000000001', 'someone-else@rice.edu',
            '{"responseId":"resp-new","submittedAt":"2025-08-28T20:10:00Z","answers":[]}'::jsonb)$$,
  'duplicate key value violates unique constraint');

\o
select case when ok then '  ok  ' else ' FAIL ' end as "res", label as "check",
       case when ok then null else detail end as "detail"
  from _t order by n;
\o
select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' as result from _t;
