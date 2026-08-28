-- The audit log's "name set to X" entry (people_log_changes(), 20260827010000) already carries
-- the netid in audit_log.record_id, but that column isn't rendered anywhere in the dashboard's
-- Audit log table (dashboard/index.html only shows Time/Actor/Summary/Table) — an officer reading
-- "name set to Diego Rodriguez" has no way to tell which netid that was without cross-referencing
-- Roster. Putting the netid in the summary text itself fixes that with no dashboard change needed.

begin;

create or replace function public.people_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'system');
begin
  if new.first_name is distinct from old.first_name or new.last_name is distinct from old.last_name then
    insert into public.audit_log (table_name, record_id, summary, detail, changed_by)
    values ('people', new.netid,
            'name set to ' || trim(concat_ws(' ', new.first_name, new.last_name)) || ' (' || new.netid || ')',
            jsonb_build_object('old_first_name', old.first_name, 'old_last_name', old.last_name,
                                'new_first_name', new.first_name, 'new_last_name', new.last_name),
            v_who);
  end if;

  return null;
end
$$;

revoke all on function public.people_log_changes() from public, anon, authenticated;

commit;
