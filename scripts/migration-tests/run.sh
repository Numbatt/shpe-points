#!/usr/bin/env bash
#
# Apply every migration to a throwaway Postgres and assert how the schema BEHAVES.
#
# Why this exists: the Supabase CLI cannot apply migrations against this project (it fails
# provisioning its own login role -- "permission denied to alter role cli_login_postgres"), so
# migrations get pasted into the SQL editor by hand. Pasting DDL into production is a bad place to
# discover a typo, and a worse place to discover that a trigger deletes attendance it should have
# kept. This runs the same files, in the same order, first.
#
# Usage:  scripts/migration-tests/run.sh
# Needs:  docker. Nothing else -- no local psql, no Supabase CLI, no network.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CONTAINER="shpe-migration-tests"
IMAGE="postgres:17"

# The three legacy migrations import a spreadsheet-era database that exists nowhere anymore. They
# cannot run here and they are not what we are testing; substrate.sql supplies the handful of
# objects the later migrations expect them to have left behind.
SKIP='20260731024609_|20260731024821_|20260731024919_'

psql_run() { docker exec -i "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q "${@:2}"; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -f "${ERRLOG:-}"
  else
    echo "KEEP=1 -- container '$CONTAINER' left running on port 55433"
  fi
}
trap cleanup EXIT

echo "==> starting $IMAGE"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=postgres \
  -p 55433:5432 "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U postgres >/dev/null

docker cp "$REPO/supabase/migrations" "$CONTAINER:/tmp/migrations" >/dev/null
docker cp "$HERE" "$CONTAINER:/tmp/tests" >/dev/null

MIGRATIONS=$(ls "$REPO/supabase/migrations" | grep -Ev "$SKIP")
MIGRATION_COUNT=$(printf '%s\n' $MIGRATIONS | wc -l | tr -d ' ')
ERRLOG=$(mktemp)

# Builds a database with the full chain applied. Optionally stops before a given migration, so a
# test can seed the pre-migration state and then watch that one migration run.
build_db() {
  local db="$1" stop_before="${2:-}"
  docker exec "$CONTAINER" psql -U postgres -q \
    -c "drop database if exists $db;" -c "create database $db;" >/dev/null 2>&1
  psql_run "$db" -f /tmp/tests/substrate.sql >/dev/null
  for m in $MIGRATIONS; do
    [ -n "$stop_before" ] && [ "$m" = "$stop_before" ] && return 0
    if ! psql_run "$db" -f "/tmp/migrations/$m" >/dev/null 2>"$ERRLOG"; then
      echo "MIGRATION FAILED: $m"; cat "$ERRLOG"; exit 1
    fi
  done
}

fail=0

echo "==> applying every migration in order"
build_db main
echo "    $MIGRATION_COUNT files applied cleanly"

echo
echo "==> behaviour: dual-role events"
psql_run main -f /tmp/tests/dual-role.sql | tail -40
psql_run main -t -c "select count(*) from _t where not ok" | grep -q '^ *0$' || fail=1

echo
echo "==> behaviour: dedupe unmatched_signins"
DEDUPE=20260827000000_dedupe_unmatched_signins.sql

# Seed the pre-existing-duplicate shape BEFORE the dedupe migration runs (it needs the table in its
# pre-migration state, with no response_id column yet), then apply that one migration and assert.
build_db dedupe "$DEDUPE"
psql_run dedupe -f /tmp/tests/dedupe-seed.sql >/dev/null
if ! psql_run dedupe -f "/tmp/migrations/$DEDUPE" >/dev/null 2>"$ERRLOG"; then
  echo "MIGRATION FAILED: $DEDUPE"; cat "$ERRLOG"; exit 1
fi
psql_run dedupe -f /tmp/tests/dedupe-assert.sql | tail -40
psql_run dedupe -t -c "select count(*) from _t where not ok" | grep -q '^ *0$' || fail=1

echo
echo "==> behaviour: general officer audit log"
build_db audit
psql_run audit -f /tmp/tests/audit-log.sql | tail -60
psql_run audit -t -c "select count(*) from _t where not ok" | grep -q '^ *0$' || fail=1

echo
echo "==> behaviour: the collects_membership backfill"
DUAL=20260826120000_dual_role_events.sql

# One membership event per year is legal, and both must come out true.
build_db bf "$DUAL"
psql_run bf -f /tmp/tests/backfill-seed.sql >/dev/null
psql_run bf -f "/tmp/migrations/$DUAL" >/dev/null
got=$(psql_run bf -t -A -c "select string_agg(name || '=' || collects_membership, ', ' order by name) from events;")
want="A normal GBM=false, Membership 25-26=true, Membership 26-27=true"
if [ "$got" = "$want" ]; then echo "  ok   membership-typed events are backfilled, ordinary ones are not"
else echo " FAIL  backfill: got [$got]"; fail=1; fi

# Two in ONE year is the state a human has to resolve. The migration must refuse, and refusing must
# leave nothing behind -- if the column survived an aborted run, a re-run would skip the backfill.
build_db bf2 "$DUAL"
psql_run bf2 -f /tmp/tests/backfill-seed.sql >/dev/null
psql_run bf2 -c "update events set occurred_on='2025-10-01' where name='Membership 26-27';" >/dev/null
if psql_run bf2 -f "/tmp/migrations/$DUAL" >/dev/null 2>"$ERRLOG"; then
  echo " FAIL  two membership events in one year: migration should have aborted"; fail=1
else
  grep -q "already has more than one membership-collecting event" "$ERRLOG" \
    && echo "  ok   two membership events in one year aborts with a message naming the year" \
    || { echo " FAIL  aborted, but not with the expected message"; fail=1; }
  left=$(psql_run bf2 -t -A -c "select count(*) from information_schema.columns where table_name='events' and column_name='collects_membership';")
  [ "$left" = "0" ] && echo "  ok   the aborted migration left nothing behind" \
    || { echo " FAIL  collects_membership survived an aborted migration"; fail=1; }
fi

echo
if [ "$fail" = "0" ]; then echo "All migration tests passed."; else echo "FAILURES -- see above."; fi
exit "$fail"
