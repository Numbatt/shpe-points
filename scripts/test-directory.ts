#!/usr/bin/env node
/**
 * Checks for the Rice directory lookup — and a canary for the endpoint itself.
 *
 * Run it with no arguments and no setup:  node scripts/test-directory.ts
 *
 * There is no test framework here on purpose, for the same reason the dashboard has no build step:
 * a file with no dependencies has nothing to rot. This runs on bare node, hits no database, and
 * needs no credentials.
 *
 * Two jobs:
 *
 *   1. Pin the verification rule in ../supabase/functions/_shared/directory.ts. That rule — one
 *      result, matched on its own netid field, never by position — is the only thing standing
 *      between this system and attaching a stranger's name to a netID. The stubbed cases below
 *      are the ones that would break it.
 *
 *   2. Tell you when Rice changes the endpoint. The live checks at the end query search.rice.edu
 *      for real. If they start failing while the stubbed checks still pass, the lookup's contract
 *      with Rice has changed, not our logic. That is a documented, expected, non-urgent event:
 *      names simply stop auto-filling and officers type them in, exactly as before this existed.
 *      See "Getting a name from a netID" in docs/DESIGN.md.
 *
 * Pass --offline to skip the live checks (on a plane, or when Rice is down and you only want to
 * know whether your own change is sound).
 */

import { lookupNetid, lookupNetids, splitDirectoryName } from '../supabase/functions/_shared/directory.ts';

let passed = 0;
let failed = 0;

function check(label: string, actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed++;
    console.log(`  ok   ${label}`);
  } else {
    failed++;
    console.log(`  FAIL ${label}\n         got      ${a}\n         expected ${e}`);
  }
}

/** A fetch that returns a fixed body, so the parsing rules can be checked without the network. */
const stubFetch = (body: unknown, ok = true) =>
  (async () => ({ ok, json: async () => body })) as unknown as typeof fetch;

async function main(): Promise<void> {
  const offline = process.argv.includes('--offline');

  console.log('\nsplitDirectoryName');
  check('two tokens', splitDirectoryName('Diego Rico'), { firstName: 'Diego', lastName: 'Rico' });
  // The case this rule exists for. Rice returns compound Hispanic surnames as bare tokens, and for
  // a SHPE roster that is the common shape, not an edge case.
  check('compound surname stays whole', splitDirectoryName('Ana Rosas Rodríguez'), { firstName: 'Ana', lastName: 'Rosas Rodríguez' });
  check('four tokens', splitDirectoryName('Areli Garcia Hernandez Lopez'), { firstName: 'Areli', lastName: 'Garcia Hernandez Lopez' });
  check('hyphenated surname', splitDirectoryName('Claudia Garcia-Rueda'), { firstName: 'Claudia', lastName: 'Garcia-Rueda' });
  check('single token', splitDirectoryName('Cher'), { firstName: 'Cher', lastName: null });
  // The endpoint spells "no value" as the literal string "None" on several fields. Writing a
  // person called None into the roster would be worse than leaving them blank.
  check('literal "None" is not a name', splitDirectoryName('None'), null);
  check('blank', splitDirectoryName('   '), null);
  check('null', splitDirectoryName(null), null);
  check('collapses runs of whitespace', splitDirectoryName('  Diego   Rico  '), { firstName: 'Diego', lastName: 'Rico' });

  console.log('\nverification rule (no network)');
  check(
    'matches on the netid field, not on position',
    await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [{ netid: 'zzz9', name: 'Wrong Person' }, { netid: 'abc1', name: 'Right Person' }] }) }),
    { netid: 'abc1', firstName: 'Right', lastName: 'Person' },
  );
  check('no netid match yields nothing', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [{ netid: 'zzz9', name: 'Wrong Person' }] }) }), null);
  check('two matches is ambiguous, yields nothing', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [{ netid: 'abc1', name: 'One Person' }, { netid: 'abc1', name: 'Two Person' }] }) }), null);
  check('empty results', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [] }) }), null);
  check('body missing results', await lookupNetid('abc1', { fetchImpl: stubFetch({ nope: true }) }), null);
  check('results not an array', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: 'oops' }) }), null);
  check('non-200', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [{ netid: 'abc1', name: 'X Y' }] }, false) }), null);
  check('result named "None"', await lookupNetid('abc1', { fetchImpl: stubFetch({ results: [{ netid: 'abc1', name: 'None' }] }) }), null);
  check('netid comparison is case-insensitive', await lookupNetid('ABC1', { fetchImpl: stubFetch({ results: [{ netid: 'abc1', name: 'Right Person' }] }) }), { netid: 'abc1', firstName: 'Right', lastName: 'Person' });
  check('blank netid', await lookupNetid('   ', { fetchImpl: stubFetch({ results: [] }) }), null);

  const throwingFetch = (async () => { throw new Error('network down'); }) as unknown as typeof fetch;
  check('network failure returns null rather than throwing', await lookupNetid('abc1', { fetchImpl: throwingFetch }), null);

  if (offline) {
    console.log('\nlive directory: skipped (--offline)');
  } else {
    console.log('\nlive directory (canary — hits search.rice.edu)');
    // A netID whose owner has a public listing. If this one ever goes stale, swap in any current
    // officer's netID; the point is only that some known netID resolves.
    check('a real netid resolves', await lookupNetid('dr56'), { netid: 'dr56', firstName: 'Diego', lastName: 'Rico' });
    check('a nonexistent netid resolves to nothing', await lookupNetid('zzq99xyz'), null);
    // "lee" is nobody's netID but matches ~300 people by surname. The endpoint is a fuzzy search,
    // so this is the shape of query that would attach a stranger's name if we trusted results[0].
    check('a mass fuzzy match is rejected', await lookupNetid('lee'), null);

    console.log('\nlookupNetids');
    const found = await lookupNetids(['dr56', 'zzq99xyz', 'dr56'], { delayMs: 50 });
    check('dedups input and omits misses', [...found.keys()], ['dr56']);
    const capped = await lookupNetids(['dr56', 'zzq99xyz'], { limit: 1, delayMs: 0 });
    check('honours the request ceiling', capped.size, 1);
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
