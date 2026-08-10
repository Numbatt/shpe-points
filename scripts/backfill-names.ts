#!/usr/bin/env node
/**
 * One-time (and occasionally repeated) name backfill.
 *
 * Live ingestion fills names in as people arrive — see the NAMES ARE FILLED IN note in
 * supabase/functions/ingest-checkin/index.ts. This script exists for the people who arrived
 * *before* that was true, and for the ones created by paths ingestion doesn't own: a sign-in
 * attached by hand through resolve_unmatched_signin, a netID typed into the volunteer-hours grid,
 * a person added when an officer awarded an adjustment.
 *
 * It reuses the Edge Function's directory module rather than reimplementing the lookup, for the
 * same reason backfill.ts imports netid.ts: if the two disagree by one rule, the same netID gets a
 * different name depending on which path happened to fill it in.
 *
 * DRY RUN BY DEFAULT, matching backfill.ts. Nothing is written without --commit, and --commit
 * prints the same table first.
 *
 * Usage:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
 *     node scripts/backfill-names.ts [--limit N] [--commit]
 *
 *   --limit N   stop after N lookups (default 200). Raise it deliberately, not reflexively; see
 *               the robots.txt note in supabase/functions/_shared/directory.ts.
 *   --commit    actually write. Without it, nothing is modified.
 *
 * Safe to re-run. It only ever considers rows where BOTH first_name and last_name are null, and it
 * only ever writes rows that are still null at write time, so a name typed by an officer between
 * two runs is never clobbered.
 */

import { lookupNetid } from '../supabase/functions/_shared/directory.ts';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY!,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'content-type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
}

async function main(): Promise<void> {
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.');
    process.exit(1);
  }

  const args = process.argv.slice(2);
  const commit = args.includes('--commit');
  const limitFlag = args.indexOf('--limit');
  const limit = limitFlag !== -1 ? Number(args[limitFlag + 1]) : 200;
  if (!Number.isFinite(limit) || limit <= 0) {
    console.error('--limit must be a positive number.');
    process.exit(1);
  }

  const res = await rest(`people?select=netid&first_name=is.null&last_name=is.null&order=netid&limit=${limit}`);
  if (!res.ok) {
    console.error(`Could not read people: ${res.status} ${await res.text()}`);
    process.exit(1);
  }
  const nameless: { netid: string }[] = await res.json();

  if (nameless.length === 0) {
    console.log('No people are missing a name. Nothing to do.');
    return;
  }

  console.log(`${nameless.length} ${nameless.length === 1 ? 'person is' : 'people are'} missing a name.`);
  console.log(commit ? 'Mode: COMMIT (writes will happen)\n' : 'Mode: DRY RUN (nothing will be written)\n');

  const resolved: { netid: string; firstName: string; lastName: string | null }[] = [];
  const unresolved: string[] = [];

  for (let i = 0; i < nameless.length; i++) {
    // Sequential with a pause, same courtesy as the Edge Function path. This is a bulk pass
    // against a university service, which is the one shape of traffic most likely to get a
    // student club's access reconsidered. Do not parallelize it to save ninety seconds.
    if (i > 0) await new Promise((r) => setTimeout(r, 200));
    const hit = await lookupNetid(nameless[i].netid);
    if (hit) resolved.push(hit);
    else unresolved.push(nameless[i].netid);
  }

  for (const p of resolved) {
    console.log(`  ${p.netid.padEnd(10)} -> ${p.firstName} ${p.lastName ?? ''}`.trimEnd());
  }
  if (unresolved.length > 0) {
    // Not an error. The most likely reason is a FERPA directory suppression, which is a choice the
    // student made and which this system should simply respect.
    console.log(`\n  ${unresolved.length} not found in the directory (suppressed listing, alum, or typo):`);
    console.log(`  ${unresolved.join(', ')}`);
  }

  if (!commit) {
    console.log(`\nDry run. Re-run with --commit to write ${resolved.length} name(s).`);
    return;
  }

  let written = 0;
  for (const p of resolved) {
    // Still guarded on both columns being null, exactly as in the Edge Function: a name typed by
    // an officer wins over the registrar's, because the officer heard it from the person.
    const patch = await rest(
      `people?netid=eq.${encodeURIComponent(p.netid)}&first_name=is.null&last_name=is.null`,
      { method: 'PATCH', body: JSON.stringify({ first_name: p.firstName, last_name: p.lastName }) },
    );
    if (patch.ok) written++;
    else console.error(`  ! ${p.netid}: ${patch.status} ${await patch.text()}`);
  }

  console.log(`\nWrote ${written} name(s).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
