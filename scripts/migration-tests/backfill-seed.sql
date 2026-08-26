\set ON_ERROR_STOP on
\o /dev/null
insert into academic_years (id, starts_on, ends_on) values
  ('2025-26', '2025-08-01', '2026-07-31'),
  ('2026-27', '2026-08-01', '2027-07-31');
insert into event_types (code, label, default_points, is_membership_form) values
  ('gbm', 'GBM', 1, false),
  ('membership', 'Membership form', 0, true);
-- Two membership-typed events, one per year: legal, and both must be backfilled to true.
insert into events (id, name, type_code, occurred_on, points, source) values
  ('a0000000-0000-0000-0000-000000000001', 'Membership 25-26', 'membership', '2025-09-01', 0, 'form'),
  ('a0000000-0000-0000-0000-000000000002', 'Membership 26-27', 'membership', '2026-09-01', 0, 'form'),
  ('a0000000-0000-0000-0000-000000000003', 'A normal GBM',     'gbm',        '2025-09-15', 1, 'form');
\o
