-- events_membership_retype_replays() is a TRIGGER function. It is never meant to be called
-- directly, but Postgres grants EXECUTE to PUBLIC on every newly created function, so it appeared
-- at /rest/v1/rpc/events_membership_retype_replays for both anon and authenticated. The lockdown
-- migration (20260731024609) revoked function privileges as a one-time sweep, which by definition
-- could not cover a function created afterwards.
--
-- A direct call would fail anyway -- Postgres refuses to run a trigger function outside a trigger --
-- but a SECURITY DEFINER function reachable from the public API is exactly the shape of the bug
-- 20260731025444_harden_views_and_functions.sql was written to close, and it should not be
-- reintroduced just because this one happens to be inert.
--
-- Caught by the Supabase security advisor (lints 0028/0029) immediately after the trigger landed.
-- If you add another function to this schema, check the advisor again: the default grant is on
-- PUBLIC every time, and nothing in this repo revokes it automatically.
--
-- Note for whoever reads this next: the three older trigger functions (events_default_points,
-- events_restamp_attendance, attendance_hours_to_points) are still EXECUTE-able by anon for the
-- same reason. They are SECURITY INVOKER rather than DEFINER, and a direct call still fails
-- because they are trigger functions, so they are not flagged and are left alone here rather than
-- changed as a drive-by.

begin;

revoke all on function public.events_membership_retype_replays() from public, anon, authenticated;

commit;
