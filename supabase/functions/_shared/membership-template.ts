/**
 * Membership form demographics — exact question-title match only, never inference.
 *
 * Read "Why Phase 2's template is load-bearing" in docs/DESIGN.md before touching this file.
 * Short version: `resolveIdentity()` (netid.ts) can afford to pattern-match a question title
 * because a wrong netID guess is caught downstream by the unique constraint on
 * (event_id, netid) and by FK failures. There is no equivalent safety net for a guessed major,
 * gender, or class level — a silently wrong one corrupts the exact number that decides an ~$800
 * sponsorship. So this module does the opposite of netid.ts: it matches question titles
 * *exactly*, against a fixed template, and contributes nothing for anything it doesn't
 * recognise. A membership row with a null `major` is correct and visible on the Roster screen; an
 * invented one is neither.
 *
 * ---------------------------------------------------------------------------------------------
 * THE SPEC — this is the contract the copyable membership-form template (Phase 2, not yet built)
 * must satisfy. If Phase 2 changes a question's wording, this map must change in the same commit,
 * or that field silently stops populating for every response collected after the mismatch.
 *
 * Expected question titles, matched verbatim (whitespace-trimmed, case-SENSITIVE — this is
 * deliberately not case-insensitive matching; see the note below):
 *
 *   "Class Level"                -> memberships.class_level         (free text, e.g. "Sophomore")
 *   "Major"                      -> memberships.major               (free text)
 *   "Gender"                     -> memberships.gender              (free text)
 *   "Expected Graduation Year"   -> memberships.expected_grad_year  (must be exactly 4 digits)
 *   "College"                    -> memberships.college             (Rice residential college)
 *   "Birthday"                   -> memberships.birthday            (must be a Google Forms DATE
 *                                                                     item, which answers with an
 *                                                                     ISO "yyyy-mm-dd" string)
 *
 * Any question title not in this list — including a differently-worded version of one of the six
 * above, e.g. "What's your major?" or "major" (lowercase) — contributes nothing. That is
 * intentional, not a bug: exact-match is what makes this module safe to leave unattended. Widen it
 * only by adding a new literal string here after confirming the template actually uses it, never
 * by loosening the comparison (no case-folding, no substring, no regex).
 * ---------------------------------------------------------------------------------------------
 */

import type { FormAnswer } from './netid.ts';

/** Verbatim question title -> memberships column. The one place this mapping is allowed to live. */
export const MEMBERSHIP_QUESTION_TITLES: Record<string, string> = {
  'Class Level': 'class_level',
  'Major': 'major',
  'Gender': 'gender',
  'Expected Graduation Year': 'expected_grad_year',
  'College': 'college',
  'Birthday': 'birthday',
};

/**
 * Every memberships column this module ever writes, derived from the map above rather than typed
 * out a second time so the two can't drift apart. Used by the ingest function to build a
 * uniformly-shaped row (see the call site in index.ts) rather than one whose keys vary
 * response-to-response depending on what happened to be answered.
 */
export const MEMBERSHIP_DEMOGRAPHIC_COLUMNS: readonly string[] = [
  ...new Set(Object.values(MEMBERSHIP_QUESTION_TITLES)),
];

const FOUR_DIGIT_YEAR_RE = /^\d{4}$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Pull whatever demographics a response's answers contain, by exact title match against
 * MEMBERSHIP_QUESTION_TITLES above. Returns only the keys it found and could parse — never a key
 * with a guessed or coerced value, and never a key for a title outside the map.
 *
 * The caller (index.ts) fills any column this function didn't return with an explicit `null`
 * before writing, rather than relying on PostgREST to leave an omitted key untouched on conflict —
 * that behavior isn't something this codebase has verified against a live Supabase instance, and
 * guessing wrong about it would risk silently keeping stale demographics instead of the latest
 * submission's honest answer. So the rule here is simpler and doesn't depend on upsert internals:
 * the most recent submission for a (netid, year_id) wins outright, including its blanks.
 */
export function extractMembershipDemographics(answers: FormAnswer[]): Record<string, string | number> {
  const out: Record<string, string | number> = {};

  for (const { question, answer } of answers) {
    const column = MEMBERSHIP_QUESTION_TITLES[(question ?? '').trim()];
    if (!column) continue; // unrecognised title — contributes nothing, per the header comment above

    const value = (answer ?? '').trim();
    if (value === '') continue; // answered but blank; leave the column null rather than write ''

    if (column === 'expected_grad_year') {
      // Reject anything that isn't cleanly a 4-digit year (a stray "Class of 2027", a typo, a
      // form using a different question type than intended) rather than parseInt-ing best-effort
      // and possibly landing a nonsense number in a field that feeds cohort counts.
      if (!FOUR_DIGIT_YEAR_RE.test(value)) continue;
      out[column] = Number(value);
    } else if (column === 'birthday') {
      // Google Forms DATE items answer with an ISO "yyyy-mm-dd" string. Anything else means the
      // template question isn't actually a DATE item, and a hand-typed birthday is not worth
      // guessing at — Postgres would happily misparse "6/15/05" in a way nobody would catch.
      if (!ISO_DATE_RE.test(value)) continue;
      out[column] = value;
    } else {
      out[column] = value;
    }
  }

  return out;
}
