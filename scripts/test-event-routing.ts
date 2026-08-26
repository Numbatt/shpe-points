/**
 * Tests for event-routing.ts. No framework, no credentials, no network — same reasoning as
 * test-directory.ts and test-membership-template.ts.
 *
 *   node scripts/test-event-routing.ts
 *
 * These pin one property above all others: paysAttendance and collectsMembership are INDEPENDENT.
 * The bug this module exists to close was an if/else — two answers that could never both be true —
 * and it cost either 73 people their GBM point or an entire year its demographics, depending on
 * which branch an officer picked. If someone later "simplifies" this back into a single fork, the
 * dual-role case below fails loudly.
 */

import { routeEvent } from '../supabase/functions/_shared/event-routing.ts';

let failures = 0;
function check(name: string, actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}\n         expected ${e}\n         actual   ${a}`);
  }
}

/** The shape PostgREST hands back for the embedded event_types join. */
const ev = (type: { is_membership_form?: boolean } | null, collects?: boolean) => ({
  event_types: type,
  collects_membership: collects,
});

console.log('\nthe ordinary cases, unchanged');
check('an untyped event pays and collects nothing',
  routeEvent(ev(null)), { paysAttendance: true, collectsMembership: false });
check('a plain GBM pays and collects nothing',
  routeEvent(ev({ is_membership_form: false })), { paysAttendance: true, collectsMembership: false });
check('a pure membership form collects and pays nothing',
  routeEvent(ev({ is_membership_form: true })), { paysAttendance: false, collectsMembership: true });

console.log('\nthe dual-role case — the whole point');
check('a GBM that is also the membership form does BOTH',
  routeEvent(ev({ is_membership_form: false }, true)), { paysAttendance: true, collectsMembership: true });
check('an untyped event with the flag still pays',
  routeEvent(ev(null, true)), { paysAttendance: true, collectsMembership: true });

console.log('\nthe backfill-ran-once hole');
// A backfill sets collects_membership on the membership-typed events that exist the day it runs.
// An event typed `membership` for the first time AFTER that has the type and not the flag. Reading
// the column alone would route its responses nowhere at all — no attendance, no memberships.
check('a newly membership-typed event collects even without the flag',
  routeEvent(ev({ is_membership_form: true }, false)), { paysAttendance: false, collectsMembership: true });

console.log('\nnulls, missing keys, and other things PostgREST actually returns');
check('a null event routes as ordinary rather than throwing',
  routeEvent(null), { paysAttendance: true, collectsMembership: false });
check('undefined routes as ordinary rather than throwing',
  routeEvent(undefined), { paysAttendance: true, collectsMembership: false });
check('an empty object routes as ordinary',
  routeEvent({}), { paysAttendance: true, collectsMembership: false });
check('a null event_types embed (no type_code) routes as ordinary',
  routeEvent({ event_types: null }), { paysAttendance: true, collectsMembership: false });
check('null flags are false, never truthy',
  routeEvent({ event_types: { is_membership_form: null }, collects_membership: null }),
  { paysAttendance: true, collectsMembership: false });

// Strict === true throughout, so a string or a number can never turn on a write path.
check('a truthy non-boolean does NOT enable membership collection',
  routeEvent({ collects_membership: 'true' as unknown as boolean }),
  { paysAttendance: true, collectsMembership: false });
check('a truthy non-boolean does NOT disable attendance',
  routeEvent({ event_types: { is_membership_form: 1 as unknown as boolean } }),
  { paysAttendance: true, collectsMembership: false });

console.log(`\n${failures === 0 ? 'All checks passed.' : `${failures} failed.`}`);
process.exit(failures === 0 ? 0 : 1);
