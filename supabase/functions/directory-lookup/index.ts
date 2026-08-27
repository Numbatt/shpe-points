/**
 * directory-lookup — the dashboard's only route to Rice's people directory.
 *
 * WHY THIS EXISTS AT ALL. `dashboard/index.html` cannot call search.rice.edu itself: the endpoint
 * returns no `Access-Control-Allow-Origin` header (verified 2026-08-25), so the browser blocks the
 * response before any of our code sees it. That is not something we can work around client-side,
 * and it is not something Rice owes us. So the lookup happens server-side and the browser talks to
 * this function instead.
 *
 * WHY IT IS NOT PART OF ingest-checkin. That function is authenticated by a shared secret in the
 * `x-ingest-secret` header, because its caller is an Apps Script running unattended under the
 * club's Gmail. A browser cannot hold that secret — shipping it to `index.html` would publish it to
 * anyone who opens devtools, and it is the only thing standing between the internet and the write
 * path for attendance. This function is authenticated the other way: by the officer's own Supabase
 * session, which the dashboard already has.
 *
 * ---------------------------------------------------------------------------------------------
 * THE AUTH GATE, WHICH IS SUBTLER THAN IT LOOKS
 *
 * Supabase's `verify_jwt` setting is NOT sufficient here, and assuming it is would leave this
 * function open to the world. `verify_jwt` checks that the bearer token is a valid JWT signed by
 * this project. The publishable anon key is exactly that — a valid, project-signed JWT — and it is
 * embedded in `dashboard/index.html` in plain text, as it is designed to be. So anyone who views
 * source has a token that passes `verify_jwt`.
 *
 * The real gate is the `is_officer()` call below, made with the CALLER's token so that Postgres
 * evaluates `auth.jwt() ->> 'email'` against the officers allowlist. That reuses the single
 * definition of "officer" that RLS already uses everywhere else, rather than re-reading the
 * `officers` table here and letting the two drift.
 * ---------------------------------------------------------------------------------------------
 *
 * Two modes:
 *
 *   { mode: 'search', q: 'Jasmine Godoy' }
 *     Read-only. Returns candidate people for an officer to choose between when a sign-in carried
 *     a personal email instead of a netID. Writes nothing, ever — see searchDirectoryByName's
 *     header for why its results must always pass through a human.
 *
 *   { mode: 'fill-names', limit: 25, excludeNetids: ['ab12'] }
 *     Finds people with no name on record, looks each up by netID, and fills in what it finds.
 *     This is scripts/backfill-names.ts, moved to where the officer already is. It keeps that
 *     script's two load-bearing properties: bounded per call, and it can only ever fill a blank.
 *     `excludeNetids` lets the dashboard loop this call across a whole pass without the query
 *     re-serving the same unfillable people every round (see the comment at its read below).
 *     The response's `noMatchNetids` is what lets the dashboard grey out a "Look up" button for
 *     someone it already knows the directory has nothing for.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { lookupNetids, searchDirectoryByName } from '../_shared/directory.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

/**
 * `*` is correct here, and is not the lazy choice. The access control on this function is the
 * officer's session, not the page's origin — a request without a valid officer token gets nothing
 * regardless of where it came from, and one with a valid officer token is legitimate wherever the
 * dashboard happens to be hosted. Pinning an origin would instead hardcode the current Vercel URL
 * into a deployed function, so the day the dashboard moves (or someone opens it from a preview
 * deploy, or from a file:// copy during a handoff) it breaks with an error that looks nothing like
 * its cause.
 */
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...CORS },
  });

/** How many directory requests one invocation may make. See lookupNetids' header. */
const MAX_FILL = 25;

Deno.serve(async (req) => {
  // The preflight. Without this the browser never sends the real request and the failure surfaces
  // as an opaque network error with no status to read.
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization) return json({ error: 'unauthorized' }, 401);

  // Bound to the caller's token, so is_officer() sees the caller's email. Anon key as the API key
  // plus the officer's JWT as the bearer is the same pairing the dashboard uses for PostgREST.
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  const { data: isOfficer, error: gateError } = await asCaller.rpc('is_officer');
  if (gateError) return json({ error: 'unauthorized' }, 401);
  if (isOfficer !== true) return json({ error: 'forbidden' }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'body must be JSON' }, 400);
  }

  const mode = String(body?.mode ?? '');

  // -------------------------------------------------------------------------------------------
  // search — read-only, returns candidates for a human to pick from
  // -------------------------------------------------------------------------------------------
  if (mode === 'search') {
    const found = await searchDirectoryByName(String(body?.q ?? ''));
    return json(found);
  }

  // -------------------------------------------------------------------------------------------
  // fill-names — bounded, and can only ever fill a blank
  // -------------------------------------------------------------------------------------------
  if (mode === 'fill-names') {
    const requested = Number(body?.limit ?? MAX_FILL);
    const limit = Number.isFinite(requested) ? Math.min(Math.max(Math.trunc(requested), 1), MAX_FILL) : MAX_FILL;

    // The dashboard loops this call to cover more than one batch of MAX_FILL. Without excluding
    // what earlier rounds in the SAME loop already tried, `order by netid limit N` would just
    // hand back the identical alphabetically-first rows every round: a netid the directory has no
    // match for never gets a name, so it never leaves this query's result, and the loop would spin
    // on it forever without ever reaching anyone who sorts after it. Sanitized to the netid shape
    // used everywhere else (see normalizeNetid) before it goes anywhere near a filter string.
    const excludeNetids = Array.isArray(body?.excludeNetids)
      ? [...new Set((body.excludeNetids as unknown[])
          .map((v) => String(v ?? '').trim().toLowerCase())
          .filter((v) => /^[a-z0-9]{1,20}$/.test(v)))]
      : [];

    // The write needs service_role: `people` is officer-writable under RLS, but doing the update
    // as the caller would make the guarded filter below depend on the caller's policy evaluation
    // rather than on the filter itself. Same reasoning as the SECURITY DEFINER functions.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

    let nameQuery = admin
      .from('people')
      .select('netid')
      .is('first_name', null)
      .is('last_name', null)
      .order('netid')
      .limit(limit);
    if (excludeNetids.length > 0) nameQuery = nameQuery.not('netid', 'in', `(${excludeNetids.join(',')})`);
    const { data: nameless, error: readError } = await nameQuery;
    if (readError) return json({ error: readError.message }, 500);

    const netids = (nameless ?? []).map((p: { netid: string }) => p.netid);
    if (netids.length === 0) return json({ attempted: 0, filled: 0, remaining: 0, attemptedNetids: [], noMatchNetids: [] });

    const found = await lookupNetids(netids, { limit, delayMs: 150 });

    // Walk every netid asked for, not just the ones found: the dashboard's per-row "Look up"
    // button greys itself out for a netid once it knows the directory has nothing for it, and
    // noMatchNetids is how the bulk pass reports that same fact for a whole batch at once.
    // lookupNetids collapses "confirmed zero directory results" and "transient failure/timeout/
    // ambiguous match" into the same "absent from the map" case (see its own header) -- there is
    // no way to tell those apart here, and marking a transient miss the same as a confirmed one is
    // no new risk: an officer re-running this pass already retries it exactly the way a fresh page
    // load would.
    let filled = 0;
    const noMatchNetids: string[] = [];
    for (const netid of netids) {
      const name = found.get(netid);
      if (!name) {
        noMatchNetids.push(netid);
        continue;
      }
      // The guard, carried over verbatim in spirit from scripts/backfill-names.ts: re-assert that
      // BOTH names are still null at write time. An officer may have typed a name into the
      // dashboard in the seconds since the read above, and a person who goes by a name the
      // registrar does not have is precisely the case where the human is right and Rice is wrong.
      // Directory data fills a blank; it never overwrites a person.
      const { data: updated, error } = await admin
        .from('people')
        .update({ first_name: name.firstName, last_name: name.lastName })
        .eq('netid', netid)
        .is('first_name', null)
        .is('last_name', null)
        .select('netid');
      if (!error && (updated?.length ?? 0) > 0) filled++;
      // else: a human already typed a name in the seconds since the read above. That is not a
      // directory failure, so it does not go in noMatchNetids -- the person just isn't nameless
      // anymore.
    }

    // What's left overall, so the dashboard can say "66 still missing" honestly rather than
    // implying the queue is empty.
    const { count } = await admin
      .from('people')
      .select('netid', { count: 'exact', head: true })
      .is('first_name', null)
      .is('last_name', null);

    return json({ attempted: netids.length, filled, remaining: count ?? 0, attemptedNetids: netids, noMatchNetids });
  }

  return json({ error: `unknown mode: ${mode}` }, 400);
});
