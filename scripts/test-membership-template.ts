/**
 * Tests for membership-template.ts. No framework, no credentials, no network — same reasoning as
 * test-directory.ts: a file with no dependencies has nothing to rot, and the next VP can run it.
 *
 *   node scripts/test-membership-template.ts
 *
 * These pin the exact boundary the module's header argues for, because that boundary is the whole
 * safety story and it is not self-evident from reading the code:
 *
 *   - class_level is ALWAYS gated on a closed vocabulary, whether the title matched or not.
 *   - major and gender are NEVER inferred and NEVER canonicalized.
 *   - a bare "Year" question is disambiguated by its ANSWER, not by its title.
 *
 * If someone later "simplifies" the gate away, these fail loudly rather than the chapter
 * discovering it in October with a half-empty deliberation grid.
 */

import {
  extractMembershipDemographics,
  canonicalClassLevel,
  inferClassLevel,
  TITLE_ALIASES,
} from '../supabase/functions/_shared/membership-template.ts';

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

const ans = (pairs: [string, string][]) => pairs.map(([question, answer]) => ({ question, answer }));

console.log('\ncanonicalClassLevel — the closed vocabulary');
check('Sophomore', canonicalClassLevel('Sophomore'), 'Sophomore');
check('lowercase sophomore', canonicalClassLevel('sophomore'), 'Sophomore');
check('2nd Year', canonicalClassLevel('2nd Year'), 'Sophomore');
check('first-year', canonicalClassLevel('first-year'), 'Freshman');
check('PhD', canonicalClassLevel('PhD'), 'Graduate');
check('whitespace and case', canonicalClassLevel('  SENIOR  '), 'Senior');
// Not class levels. Each of these is a real answer some form somewhere collects.
check('alumni is not a class level', canonicalClassLevel('Alumni'), null);
check('faculty is not a class level', canonicalClassLevel('Faculty'), null);
check('a course number is not a class level', canonicalClassLevel('COMP 322'), null);
check('a grad year is not a class level', canonicalClassLevel('2028'), null);
check('blank', canonicalClassLevel(''), null);

console.log('\nthe "Year" ambiguity — resolved by the ANSWER, never by the title');
check(
  'Year + Sophomore -> class_level',
  extractMembershipDemographics(ans([['Year', 'Sophomore']])),
  { class_level: 'Sophomore' },
);
check(
  'Year + 2028 -> expected_grad_year, NOT class_level',
  extractMembershipDemographics(ans([['Year', '2028']])),
  { expected_grad_year: 2028 },
);
check(
  'an explicit grad-year question outranks the Year fallback',
  extractMembershipDemographics(ans([['Year', '2028'], ['Expected Graduation Year', '2027']])),
  { expected_grad_year: 2027 },
);
check(
  'order does not matter for that precedence',
  extractMembershipDemographics(ans([['Expected Graduation Year', '2027'], ['Year', '2028']])),
  { expected_grad_year: 2027 },
);
check(
  'Class + COMP 322 -> nothing (gate applies to matched titles too)',
  extractMembershipDemographics(ans([['Class', 'COMP 322']])),
  {},
);

console.log('\ntitle aliases and normalization');
check(
  'the 2025-26 sign-in form shape',
  extractMembershipDemographics(ans([
    ['Email', 'jd1@rice.edu'],
    ['First Name', 'Jane'],
    ['Gender', 'Female'],
    ['College', 'Wiess'],
    ['Year', 'Freshman'],
    ['Major', 'Chemical and Biomolecular Engineering'],
  ])),
  { gender: 'Female', college: 'Wiess', class_level: 'Freshman', major: 'Chemical and Biomolecular Engineering' },
);
check('case-insensitive title', extractMembershipDemographics(ans([['MAJOR', 'CS']])), { major: 'CS' });
check('trailing question mark', extractMembershipDemographics(ans([['Major?', 'CS']])), { major: 'CS' });
check('trailing required asterisk', extractMembershipDemographics(ans([['Major *', 'CS']])), { major: 'CS' });
check('collapsed whitespace', extractMembershipDemographics(ans([['Class   Level', 'Junior']])), { class_level: 'Junior' });
check('unrecognised title contributes nothing', extractMembershipDemographics(ans([['T-shirt size', 'M']])), {});

console.log('\nmajor and gender are verbatim and never inferred');
check(
  'major is stored exactly as typed, not canonicalized',
  extractMembershipDemographics(ans([['Major', 'chemE']])),
  { major: 'chemE' },
);
check(
  'gender is stored exactly as typed',
  extractMembershipDemographics(ans([['Gender', 'nonbinary']])),
  { gender: 'nonbinary' },
);
check(
  'a bare major-looking answer with no matching title is NOT captured',
  extractMembershipDemographics(ans([['Something else', 'Computer Science']])),
  {},
);
check(
  'a bare gender-looking answer with no matching title is NOT captured',
  extractMembershipDemographics(ans([['Something else', 'Female']])),
  {},
);

console.log('\nclass-level inference — the one narrow exception');
check(
  'inferred from an unrecognised title, since the value is unambiguous',
  extractMembershipDemographics(ans([['What year are you?', 'Junior']])),
  { class_level: 'Junior' },
);
check('inferClassLevel finds one', inferClassLevel(ans([['whatever', 'senior']])), 'Senior');
check(
  'refuses when two answers disagree',
  inferClassLevel(ans([['now', 'Junior'], ['next year', 'Senior']])),
  null,
);
check(
  'agreeing duplicates are fine',
  inferClassLevel(ans([['a', 'Junior'], ['b', 'junior']])),
  'Junior',
);
check('nothing to infer', inferClassLevel(ans([['a', 'purple']])), null);
check(
  'a matched title beats inference',
  extractMembershipDemographics(ans([['Class Level', 'Senior'], ['stray', 'Freshman']])),
  { class_level: 'Senior' },
);

console.log('\nvalidation of typed fields');
check('grad year must be 4 digits', extractMembershipDemographics(ans([['Expected Graduation Year', 'Class of 2027']])), {});
check('birthday must be ISO', extractMembershipDemographics(ans([['Birthday', '6/15/05']])), {});
check('birthday ISO passes', extractMembershipDemographics(ans([['Birthday', '2005-06-15']])), { birthday: '2005-06-15' });
check('blank answer leaves the column null', extractMembershipDemographics(ans([['Major', '   ']])), {});

console.log('\nstructural');
check(
  'no alias maps to a column outside the six',
  [...new Set(Object.values(TITLE_ALIASES))].sort(),
  ['birthday', 'class_level', 'college', 'expected_grad_year', 'gender', 'major'],
);

console.log(failures === 0 ? '\nAll checks passed.\n' : `\n${failures} check(s) FAILED.\n`);
if (failures > 0) process.exit(1);
