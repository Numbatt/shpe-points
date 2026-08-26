/**
 * Membership form demographics — curated title aliases, and closed-vocabulary values for the one
 * field whose vocabulary is actually closed.
 *
 * Read "Why Phase 2's template is load-bearing" in docs/DESIGN.md before touching this file.
 * Short version: `resolveIdentity()` (netid.ts) can afford to pattern-match a question title
 * because a wrong netID guess is caught downstream by the unique constraint on
 * (event_id, netid) and by FK failures. There is no equivalent safety net for a guessed major,
 * gender, or class level — a silently wrong one corrupts the exact number that decides an ~$800
 * sponsorship. So this module is deliberately stricter than netid.ts.
 *
 * ---------------------------------------------------------------------------------------------
 * WHERE THE LINE IS DRAWN — this replaces the stricter rule this file carried until 2026-08-25.
 *
 * The original rule was "exact, case-SENSITIVE title match, never loosened". It was correct about
 * the danger and wrong about the cost. It was written before any real membership form had been
 * ingested; when the first one was, every 2025-26 sign-in form turned out to ask "Year" rather
 * than "Class Level", so class level would have silently stayed null for the entire chapter — the
 * precise failure the strictness existed to prevent, arrived at from the other direction. A rule
 * that yields no data is not safer than one that yields correct data.
 *
 * The line now sits in three places instead of one:
 *
 *   1. TITLE MATCHING IS NORMALIZED AND ALIASED, NOT FUZZY.  Titles are trimmed, internally
 *      whitespace-collapsed, lowercased, and stripped of a trailing "?" or "*", then compared for
 *      EXACT EQUALITY against a curated list of literals. Case-folding a *title* cannot invent a
 *      value — it can only widen which question maps to a fixed column, and "MAJOR" is not a
 *      different question from "Major". Substring matching, regex matching, and fuzzy/edit-distance
 *      matching remain forbidden: those are what let a question meaning something else capture a
 *      column. Widen this by adding a literal to TITLE_ALIASES, never by loosening the comparison.
 *
 *   2. VALUES ARE TRUSTED VERBATIM — EXCEPT class_level.  major, gender and college are open
 *      vocabularies. Whatever the member typed is what they meant, and this module writes it
 *      unchanged. It never infers them, never canonicalizes them, and never repairs them.
 *
 *   3. class_level IS GATED ON A CLOSED VOCABULARY, ALWAYS.  Every class_level write — whether it
 *      came from a matched title or from inference — must normalize to one of five canonical
 *      values. This is the only place in the system that stores a value the respondent did not
 *      literally type, and it is justified by exactly one property that major and gender do not
 *      have: the set of valid answers is closed, tiny, and independently verifiable. "Sophomore",
 *      "sophomore" and "2nd year" are the same fact; "Chemical Engineering" and "ChemE" are a
 *      judgement call nobody authorized this file to make.
 *
 * The gate is what makes the aliases safe. "Year" is genuinely ambiguous — it means class standing
 * on most sign-in forms and graduation year on some — so it cannot be resolved by title alone. It
 * is resolved by the ANSWER: "Sophomore" is a class level, "2028" is not, and a four-digit answer
 * to a bare "Year" question is re-routed to expected_grad_year rather than discarded. A "Class"
 * question answered "COMP 322" contributes nothing at all.
 *
 * DO NOT extend inferClassLevel()'s technique to another column. It is a function, not a pattern.
 * ---------------------------------------------------------------------------------------------
 */

import type { FormAnswer } from './netid.ts';

/**
 * Normalized question title -> memberships column. The one place this mapping is allowed to live.
 *
 * Keys must be written already-normalized (lowercase, single-spaced, no trailing punctuation) —
 * they are compared against normalizeTitle()'s output, so an unnormalized key here would simply
 * never match anything. The assertion at the bottom of this file enforces that.
 */
export const TITLE_ALIASES: Record<string, string> = {
  // class_level. Every one of these is gated on CLASS_LEVELS below, so a wrongly-captured
  // question contributes nothing rather than garbage.
  'class level': 'class_level',
  'class': 'class_level',
  'classification': 'class_level',
  'class standing': 'class_level',
  'grade': 'class_level',
  'grade level': 'class_level',
  'year': 'class_level',
  'academic year': 'class_level',
  'year in school': 'class_level',
  'school year': 'class_level',

  'major': 'major',
  "what's your major": 'major',
  'what is your major': 'major',
  'major(s)': 'major',
  'intended major': 'major',

  'gender': 'gender',
  'gender identity': 'gender',

  'expected graduation year': 'expected_grad_year',
  'graduation year': 'expected_grad_year',
  'expected grad year': 'expected_grad_year',
  'grad year': 'expected_grad_year',

  'college': 'college',
  'residential college': 'college',

  'birthday': 'birthday',
  'birth date': 'birthday',
  'date of birth': 'birthday',
};

/**
 * Retained under its original name because docs/DESIGN.md and docs/RUNBOOK.md both cite it as the
 * spec the copyable membership-form template must satisfy. These are the titles the template
 * should USE; TITLE_ALIASES is what the parser will ACCEPT. The template stays the narrow one so
 * that officers copying last year's form keep producing unambiguous input.
 */
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
 * The closed vocabulary. Normalized answer -> the canonical value stored in memberships.class_level.
 *
 * Canonical rather than verbatim because class_level feeds the Standings facet dropdown, which is
 * built with `new Set(...)` (dashboard/index.html, facet()). Storing "Sophomore" and "sophomore"
 * would put the same cohort in the deliberation grid twice, which is a worse failure than a
 * slightly-reworded label: officers filtering by one would silently miss the other.
 *
 * "alumni", "faculty" and "staff" are deliberately absent. They are real answers a stray form
 * might collect and they are not class levels, so they must fall through to nothing.
 */
const CLASS_LEVELS: Record<string, string> = {
  'freshman': 'Freshman',
  'freshmen': 'Freshman',
  'first year': 'Freshman',
  'first-year': 'Freshman',
  '1st year': 'Freshman',
  'frosh': 'Freshman',
  'fresh': 'Freshman',

  'sophomore': 'Sophomore',
  '2nd year': 'Sophomore',
  'second year': 'Sophomore',

  'junior': 'Junior',
  '3rd year': 'Junior',
  'third year': 'Junior',

  'senior': 'Senior',
  '4th year': 'Senior',
  'fourth year': 'Senior',
  '5th year': 'Senior',
  'super senior': 'Senior',

  'grad': 'Graduate',
  'graduate': 'Graduate',
  'grad student': 'Graduate',
  'graduate student': 'Graduate',
  'masters': 'Graduate',
  "master's": 'Graduate',
  'ms': 'Graduate',
  'meng': 'Graduate',
  'mba': 'Graduate',
  'phd': 'Graduate',
  'doctoral': 'Graduate',
};

/**
 * Titles that are ambiguous between class standing and graduation year on real forms. A four-digit
 * answer to one of these is a graduation year, not a class level. Any other title mapped to
 * class_level that fails the vocabulary gate contributes nothing — we only re-route where the
 * ambiguity is genuine and the evidence (a bare 4-digit answer) is unambiguous.
 */
const YEAR_AMBIGUOUS_TITLES = new Set(['year', 'academic year', 'school year']);

/**
 * Trim, collapse internal whitespace, lowercase, and drop a trailing "?" or "*" (Google Forms
 * appends "*" to required questions in some exports). Deliberately does NOT strip other
 * punctuation or stopwords: that would start collapsing genuinely different questions together.
 */
function normalizeTitle(raw: string | null | undefined): string {
  return String(raw ?? '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[?*]+$/, '')
    .trim()
    .toLowerCase();
}

/** Normalize an answer for vocabulary comparison. Same rules, plus surrounding punctuation. */
function normalizeValue(raw: string | null | undefined): string {
  return String(raw ?? '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[('"\[]+|[)'"\].,;:]+$/g, '')
    .trim()
    .toLowerCase();
}

/** The vocabulary gate. Returns a canonical class level, or null for anything not in the set. */
export function canonicalClassLevel(raw: string | null | undefined): string | null {
  const value = normalizeValue(raw);
  if (value === '') return null;
  return CLASS_LEVELS[value] ?? null;
}

/**
 * Last-resort class level recovery: find a class level by the SHAPE OF THE ANSWER when no question
 * title identified one.
 *
 * This exists because form wording is the least stable thing in the system — it changes every time
 * an officer rewrites the form — while the set of answers does not. It is safe here and nowhere
 * else because CLASS_LEVELS is closed: an answer either is one of five known values or it is not,
 * and there is no third outcome where we guess.
 *
 * Refuses to answer when two questions yield DIFFERENT class levels. That means the form asked
 * something this function doesn't understand (e.g. "class level now" and "class level next year"),
 * and picking one would be a coin flip on a number that decides money.
 *
 * DO NOT generalize this to major, gender, or college. Their vocabularies are open, so "is this
 * value a major?" has no answer, and a wrong guess is both undetectable and unrecoverable.
 */
export function inferClassLevel(answers: FormAnswer[]): string | null {
  const found = new Set<string>();
  for (const { answer } of answers) {
    const canonical = canonicalClassLevel(answer);
    if (canonical) found.add(canonical);
  }
  return found.size === 1 ? [...found][0] : null;
}

/**
 * Pull whatever demographics a response's answers contain. Returns only the keys it found and could
 * validate — never a key with a guessed or coerced value.
 *
 * The caller (index.ts) fills any column this function didn't return with an explicit `null`
 * before writing, rather than relying on PostgREST to leave an omitted key untouched on conflict —
 * that behavior isn't something this codebase has verified against a live Supabase instance, and
 * guessing wrong about it would risk silently keeping stale demographics instead of the latest
 * submission's honest answer. So the rule there is simpler and doesn't depend on upsert internals:
 * the most recent submission for a (netid, year_id) wins outright, including its blanks.
 *
 * Note that the gap-fill path (gapfill_membership_demographics) deliberately inverts that rule.
 * See its migration for why the two must differ.
 */
export function extractMembershipDemographics(answers: FormAnswer[]): Record<string, string | number> {
  const out: Record<string, string | number> = {};

  for (const { question, answer } of answers) {
    const column = TITLE_ALIASES[normalizeTitle(question)];
    if (!column) continue; // unrecognised title — contributes nothing, per the header comment above

    const value = String(answer ?? '').trim();
    if (value === '') continue; // answered but blank; leave the column null rather than write ''

    if (column === 'class_level') {
      // The gate, applied to a title match exactly as it is applied to inference below. A "Class"
      // question answered "COMP 322" lands here and is dropped.
      const canonical = canonicalClassLevel(value);
      if (canonical) {
        out.class_level = canonical;
      } else if (YEAR_AMBIGUOUS_TITLES.has(normalizeTitle(question)) && FOUR_DIGIT_YEAR_RE.test(value)) {
        // A bare "Year" answered "2028" is a graduation year. Only ever fills a blank: an explicit
        // "Expected Graduation Year" question on the same form is the better source and must win
        // regardless of which order the answers happen to arrive in.
        if (!('expected_grad_year' in out)) out.expected_grad_year = Number(value);
      }
    } else if (column === 'expected_grad_year') {
      // Reject anything that isn't cleanly a 4-digit year (a stray "Class of 2027", a typo, a
      // form using a different question type than intended) rather than parseInt-ing best-effort
      // and possibly landing a nonsense number in a field that feeds cohort counts.
      if (!FOUR_DIGIT_YEAR_RE.test(value)) continue;
      out.expected_grad_year = Number(value); // an explicit title outranks the "Year" fallback above
    } else if (column === 'birthday') {
      // Google Forms DATE items answer with an ISO "yyyy-mm-dd" string. Anything else means the
      // template question isn't actually a DATE item, and a hand-typed birthday is not worth
      // guessing at — Postgres would happily misparse "6/15/05" in a way nobody would catch.
      if (!ISO_DATE_RE.test(value)) continue;
      out.birthday = value;
    } else {
      // major, gender, college: verbatim, uncanonicalized, exactly as the member typed it.
      out[column] = value;
    }
  }

  // Inference runs only when no title produced a class level, so a matched title always wins.
  if (!('class_level' in out)) {
    const inferred = inferClassLevel(answers);
    if (inferred) out.class_level = inferred;
  }

  return out;
}

// A key written un-normalized would never match normalizeTitle()'s output and would fail silently,
// which is the one failure mode this module exists to avoid. Fail at import time instead.
for (const key of Object.keys(TITLE_ALIASES)) {
  if (key !== normalizeTitle(key)) {
    throw new Error(`TITLE_ALIASES key is not normalized: ${JSON.stringify(key)}`);
  }
}
