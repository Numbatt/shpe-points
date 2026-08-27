-- General officer action log.
--
-- `event_changes` (20260826120000_dual_role_events.sql) already logs one narrow slice of officer
-- activity -- an event's type, membership flag, and dismissal -- with a schema + trigger + RLS, and
-- it is applied in production. It has never had a UI, which is a separate, already-tracked gap.
-- `adjustments` separately records `created_by` per manual point change and has its own screen.
-- Neither generalizes: every OTHER consequential write in this system -- attaching or dismissing an
-- unmatched sign-in, correcting a member's name, granting or revoking dashboard access, changing who
-- holds a role or what a role bonus pays -- happens with no author and no record. An officer asking
-- "who did this" has exactly one answer today (event type changes) and none for everything else.
--
-- This is that general log: one table, `audit_log`, written to by a small `after` trigger per table
-- rather than by every dashboard code path remembering to log itself. Same shape and same reasoning
-- as `event_changes` -- `changed_by` is read from `auth.jwt() ->> 'email'` *inside* a SECURITY
-- DEFINER trigger function, not supplied by the client, specifically so nothing holding the anon key
-- (or a bug in the dashboard's JS) can put a false name on a row. 'system' covers a write with no
-- authenticated user behind it -- a migration, a SQL editor session, a service-role Edge Function
-- call -- the same convention `event_changes.changed_by` already uses.
--
-- Rather than duplicating `event_changes` and `adjustments` into this table too (which would mean
-- writing every consequential change twice, once to each table pattern, forever), `v_audit_log` at
-- the bottom unions all three into one shape the dashboard queries once.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------------------------
create table public.audit_log (
  id         bigserial primary key,
  table_name text not null,
  record_id  text not null,
  summary    text not null,
  detail     jsonb,
  changed_by text not null,
  changed_at timestamptz not null default now()
);

create index audit_log_changed_at_idx on public.audit_log (changed_at desc);

comment on table public.audit_log is
  'Append-only log of officer actions across every table that does not already have its own audit '
  'trail (event_changes and adjustments cover their own tables and are unioned in via v_audit_log '
  'instead of duplicated here). Written only by the per-table triggers below, all SECURITY DEFINER '
  '-- there is no insert policy, so nothing with the anon or authenticated role can write a row '
  'directly, including a false changed_by.';
comment on column public.audit_log.record_id is
  'The primary key of the row that changed, as text, from whichever table table_name names. Composite '
  'keys (roles, role_bonus_config) are joined with "|" -- there is no single id column to point at.';
comment on column public.audit_log.changed_by is
  'Officer email taken from auth.jwt() inside the database, not supplied by the caller, so it cannot '
  'be forged by anything holding the anon key. ''system'' when there is no authenticated user -- a '
  'migration or a SQL editor session -- the same convention event_changes.changed_by uses.';

alter table public.audit_log enable row level security;

create policy audit_log_officer_read on public.audit_log
  for select using (public.is_officer());

revoke all on public.audit_log from public, anon;
grant select on public.audit_log to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. unmatched_signins -- an Attach (resolved_netid newly set) or a Dismiss (resolved_at newly set
--    with resolved_netid still null; see 20260825210100_ranged_standings.sql's comment on
--    resolved_at for that pair's meaning). Other updates to this table (re-editing raw_identifier,
--    an un-dismiss that clears resolved_at back to null) are not logged -- they are not the
--    officer decision this log exists to capture.
-- ---------------------------------------------------------------------------------------------
create function public.unmatched_signins_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  if new.resolved_netid is not null and old.resolved_netid is null then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('unmatched_signins', new.id::text, 'attached to ' || new.resolved_netid,
            jsonb_build_object('event_id', new.event_id, 'resolved_netid', new.resolved_netid), v_who);
  elsif new.resolved_at is not null and old.resolved_at is null and new.resolved_netid is null then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('unmatched_signins', new.id::text, 'dismissed',
            jsonb_build_object('event_id', new.event_id), v_who);
  end if;

  return null;
end
$$;

revoke all on function public.unmatched_signins_log_changes() from public, anon, authenticated;

create trigger unmatched_signins_log_changes
after update of resolved_netid, resolved_at on public.unmatched_signins
for each row
execute function public.unmatched_signins_log_changes();

-- ---------------------------------------------------------------------------------------------
-- 3. people -- a name correction. Nothing else on this table is logged; there is nothing else on
--    it worth an audit trail (created_at never changes, netid is the primary key).
-- ---------------------------------------------------------------------------------------------
create function public.people_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  if new.first_name is distinct from old.first_name or new.last_name is distinct from old.last_name then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('people', new.netid, 'name set to ' || trim(concat_ws(' ', new.first_name, new.last_name)),
            jsonb_build_object('old_first_name', old.first_name, 'old_last_name', old.last_name,
                                'new_first_name', new.first_name, 'new_last_name', new.last_name),
            v_who);
  end if;

  return null;
end
$$;

revoke all on function public.people_log_changes() from public, anon, authenticated;

create trigger people_log_changes
after update of first_name, last_name on public.people
for each row
execute function public.people_log_changes();

-- ---------------------------------------------------------------------------------------------
-- 4. officers -- add (insert) and activate/deactivate (update of active). A display_name-only edit
--    is not logged; it is not the access-control decision this log exists to capture.
-- ---------------------------------------------------------------------------------------------
create function public.officers_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('officers', new.email, 'added as officer',
            jsonb_build_object('email', new.email, 'display_name', new.display_name, 'active', new.active),
            v_who);
  elsif tg_op = 'UPDATE' and new.active is distinct from old.active then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('officers', new.email, case when new.active then 'activated' else 'deactivated' end,
            jsonb_build_object('email', new.email, 'active', new.active), v_who);
  end if;

  return null;
end
$$;

revoke all on function public.officers_log_changes() from public, anon, authenticated;

create trigger officers_log_changes
after insert or update of active on public.officers
for each row
execute function public.officers_log_changes();

-- ---------------------------------------------------------------------------------------------
-- 5. roles -- insert (assigned) and delete (removed). No update path exists for this table today
--    (the dashboard's Roles screen adds and removes rows; it does not edit one in place), so only
--    those two operations are covered.
-- ---------------------------------------------------------------------------------------------
create function public.roles_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
  v_row public.roles;
  v_verb text;
begin
  if tg_op = 'INSERT' then
    v_row := new;
    v_verb := 'assigned role ' || new.role || ' for ' || new.year_id;
  else
    v_row := old;
    v_verb := 'role ' || old.role || ' removed for ' || old.year_id;
  end if;

  insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
  values ('roles', v_row.netid || '|' || v_row.year_id || '|' || v_row.role, v_verb,
          jsonb_build_object('netid', v_row.netid, 'year_id', v_row.year_id, 'role', v_row.role,
                              'position_title', v_row.position_title),
          v_who);

  return null;
end
$$;

revoke all on function public.roles_log_changes() from public, anon, authenticated;

create trigger roles_log_changes
after insert or delete on public.roles
for each row
execute function public.roles_log_changes();

-- ---------------------------------------------------------------------------------------------
-- 6. role_bonus_config -- a bonus amount change. Insert of a new (year_id, role) config is not
--    logged: it is the year-setup step (create_academic_year seeds these), not an officer editing
--    an existing bonus, which is the action worth an audit trail.
-- ---------------------------------------------------------------------------------------------
create function public.role_bonus_config_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
  values ('role_bonus_config', new.year_id || '|' || new.role,
          new.role || ' bonus changed from ' || old.points || ' to ' || new.points || ' for ' || new.year_id,
          jsonb_build_object('year_id', new.year_id, 'role', new.role, 'old_points', old.points,
                              'new_points', new.points),
          v_who);

  return null;
end
$$;

revoke all on function public.role_bonus_config_log_changes() from public, anon, authenticated;

create trigger role_bonus_config_log_changes
after update of points on public.role_bonus_config
for each row
when (new.points is distinct from old.points)
execute function public.role_bonus_config_log_changes();

-- ---------------------------------------------------------------------------------------------
-- 7. v_audit_log -- one reverse-chronological shape over audit_log, event_changes, and adjustments,
--    so the dashboard queries one view instead of three tables with three different column sets.
--
--    security_invoker, same treatment as v_member_totals / v_points_ledger
--    (20260731025444_harden_views_and_functions.sql): without it this view would read all three
--    base tables with the OWNER's rights and hand every signed-in Google account (not just
--    allowlisted officers) the full action log, RLS or no RLS on the tables underneath. With it, a
--    non-officer querying this view gets zero rows from all three unions, because is_officer() is
--    what every one of those tables' RLS policies already checks.
-- ---------------------------------------------------------------------------------------------
create view public.v_audit_log as
  select changed_at, changed_by, summary, table_name, record_id
    from public.audit_log
  union all
  select changed_at, changed_by,
         field || ': ' || coalesce(old_value, '—') || ' → ' || coalesce(new_value, '—'),
         'events'::text,
         event_id::text
    from public.event_changes
  union all
  select created_at,
         coalesce(created_by, 'system'),
         kind || ': ' || reason || ' (' || points || ' pts)',
         'adjustments'::text,
         id::text
    from public.adjustments;

alter view public.v_audit_log set (security_invoker = true);

comment on view public.v_audit_log is
  'One reverse-chronological shape over audit_log, event_changes, and adjustments: (changed_at, '
  'changed_by, summary, table_name, record_id). security_invoker so RLS on all three base tables is '
  'actually enforced through this view -- see 20260731025444_harden_views_and_functions.sql for why '
  'that matters.';

revoke all on public.v_audit_log from public, anon;
grant select on public.v_audit_log to authenticated;

commit;
