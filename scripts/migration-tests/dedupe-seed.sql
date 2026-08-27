-- Seed for the #2 dedupe migration test. Run against a database built with the migration chain
-- STOPPED BEFORE 20260827000000_dedupe_unmatched_signins.sql, so `unmatched_signins` still has no
-- `response_id` column yet -- these are plain inserts, no harness assertions here.
--
-- Shape mirrors the real bug: two rows for the same event, same Google Forms responseId, different
-- created_at -- exactly id 9 (2026-08-10) and id 13 (2026-08-27), both pa30@rice.ede against
-- e0feb9ac. Plus two other cases the dedupe logic has to get right: rows with NO responseId (must
-- not be treated as duplicates of each other), and a genuinely distinct response (must survive).

insert into academic_years (id, starts_on, ends_on) values ('2025-26', '2025-08-01', '2026-07-31');
insert into event_types (code, label, default_points) values ('gbm', 'GBM', 1);
insert into events (id, name, type_code, occurred_on, points, source) values
  ('e0000000-0000-0000-0000-000000000001', 'Fall GBM 1', 'gbm', '2025-08-28', 1, 'form');

-- The known-shape duplicate pair.
insert into unmatched_signins (event_id, raw_identifier, raw_payload, created_at) values
  ('e0000000-0000-0000-0000-000000000001', 'pa30@rice.ede',
   '{"responseId":"resp-dup-1","submittedAt":"2025-08-28T20:00:00Z","answers":[]}'::jsonb,
   '2026-08-10 12:00:00+00'),
  ('e0000000-0000-0000-0000-000000000001', 'pa30@rice.ede',
   '{"responseId":"resp-dup-1","submittedAt":"2025-08-28T20:00:00Z","answers":[]}'::jsonb,
   '2026-08-27 09:00:00+00');

-- Two rows with no responseId at all (predates the field). Must both survive -- they are unrelated
-- submissions that merely lack a key, not duplicates of one another.
insert into unmatched_signins (event_id, raw_identifier, raw_payload, created_at) values
  ('e0000000-0000-0000-0000-000000000001', 'legacy1@rice.edu', '{}'::jsonb, '2026-01-01 00:00:00+00'),
  ('e0000000-0000-0000-0000-000000000001', 'legacy2@rice.edu', '{}'::jsonb, '2026-01-02 00:00:00+00');

-- A genuinely distinct single response on the same event. Confirms dedupe doesn't touch non-dupes.
insert into unmatched_signins (event_id, raw_identifier, raw_payload, created_at) values
  ('e0000000-0000-0000-0000-000000000001', 'someone@rice.edu',
   '{"responseId":"resp-solo","submittedAt":"2025-08-28T20:05:00Z","answers":[]}'::jsonb,
   '2026-08-11 00:00:00+00');
