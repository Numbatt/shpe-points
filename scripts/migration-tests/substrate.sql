-- The minimum Supabase-shaped substrate the real migrations need in order to run unmodified
-- against a plain Postgres container.
--
-- Everything here is a STAND-IN, never a reimplementation. The point of the harness is to run the
-- migrations exactly as production will run them, so nothing in this file may change what a
-- migration does -- it only supplies the objects Supabase would already have provided.

-- Roles are cluster-wide, so these fail harmlessly on a second run against the same container.
do $$
begin
  create role anon nologin;                exception when duplicate_object then null;
end $$;
do $$
begin
  create role authenticated nologin;       exception when duplicate_object then null;
end $$;
do $$
begin
  create role service_role nologin;        exception when duplicate_object then null;
end $$;
do $$
begin
  create role supabase_admin superuser nologin; exception when duplicate_object then null;
end $$;

create schema if not exists auth;
create schema if not exists extensions;

-- Same contract as Supabase's: read the verified JWT claims off the request GUC. This is also the
-- test seam -- `select set_config('request.jwt.claims', '{"email":"..."}', false)` impersonates an
-- officer, and clearing it impersonates "no authenticated user".
create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;

-- Legacy artifacts the early migrations relocate or replace. Only their EXISTENCE matters: the
-- cutover drops this view and builds the real one, and the hardening migration moves this function
-- into the legacy schema. The three legacy migrations themselves are skipped by run.sh, because
-- they import a spreadsheet-era database that no longer exists anywhere.
create schema if not exists legacy;

create or replace function public.clean_netid() returns trigger
language plpgsql as $$ begin return new; end $$;

do $$
begin
  create view public.member_totals_all_time as select 1::int as placeholder;
exception when duplicate_table then null;
end $$;
