#!/usr/bin/env node
/**
 * One-time export of the pre-rebuild ("legacy") schema to CSV.
 *
 * Run BEFORE the security lockdown migration. It reads through PostgREST using the
 * anon key, which works only because the legacy schema grants `anon` SELECT on every
 * base table — the very exposure the lockdown removes. After lockdown this script
 * stops working, which is the intended outcome, not a regression.
 *
 * Usage:
 *   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=<key> node scripts/export-legacy.mjs
 *
 * Output lands in scripts/legacy-export/ (git-ignored — it contains member PII).
 */

import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), 'legacy-export');
const PAGE_SIZE = 1000;

const BASE_URL = process.env.SUPABASE_URL;
const ANON_KEY = process.env.SUPABASE_ANON_KEY;

if (!BASE_URL || !ANON_KEY) {
  console.error('Set SUPABASE_URL and SUPABASE_ANON_KEY.');
  process.exit(1);
}

/** Relations to export, with the row count Phase 0 observed. Mismatch = stop. */
const RELATIONS = [
  { name: 'Members', expected: 303 },
  { name: 'Events', expected: 28 },
  { name: 'Attendance', expected: 840 },
  { name: 'Event Categories', expected: 3 },
  { name: 'E-board and Chairs', expected: 30 },
  { name: 'Adjustments', expected: 0 },
  { name: 'attendance_staging', expected: 0 },
  { name: 'member_totals_all_time', expected: 303 },
  { name: 'attendance_with_details', expected: 840 },
];

/** Filename-safe slug: "E-board and Chairs" -> "e-board-and-chairs". */
const slugify = (name) => name.toLowerCase().replace(/\s+/g, '-');

async function fetchAll(relation) {
  const rows = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const url = `${BASE_URL}/rest/v1/${encodeURIComponent(relation)}?select=*`;
    const res = await fetch(url, {
      headers: {
        apikey: ANON_KEY,
        Authorization: `Bearer ${ANON_KEY}`,
        Range: `${offset}-${offset + PAGE_SIZE - 1}`,
      },
    });
    if (!res.ok) {
      throw new Error(`${relation}: ${res.status} ${res.statusText} — ${await res.text()}`);
    }
    const page = await res.json();
    rows.push(...page);
    if (page.length < PAGE_SIZE) return rows;
  }
}

/** RFC 4180: quote when the value contains a comma, quote, or newline; double inner quotes. */
function toCsvField(value) {
  if (value === null || value === undefined) return '';
  const str = typeof value === 'object' ? JSON.stringify(value) : String(value);
  return /[",\r\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
}

function toCsv(rows) {
  if (rows.length === 0) return '';
  // Union the keys rather than trusting the first row — PostgREST omits nothing, but
  // an empty-table export should still be obvious rather than silently headerless.
  const headers = [...new Set(rows.flatMap(Object.keys))];
  const lines = [headers.join(',')];
  for (const row of rows) lines.push(headers.map((h) => toCsvField(row[h])).join(','));
  return lines.join('\n') + '\n';
}

await mkdir(OUT_DIR, { recursive: true });

const results = [];
let mismatch = false;

for (const { name, expected } of RELATIONS) {
  const rows = await fetchAll(name);
  const ok = rows.length === expected;
  if (!ok) mismatch = true;
  await writeFile(join(OUT_DIR, `${slugify(name)}.csv`), toCsv(rows), 'utf8');
  results.push({ relation: name, exported: rows.length, expected, ok });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${rows.length} rows (expected ${expected})`);
}

// The cutover invariant: the rebuilt view must reproduce these exactly.
const totals = await fetchAll('member_totals_all_time');
const sum = (key) => totals.reduce((acc, r) => acc + Number(r[key] ?? 0), 0);
const invariant = {
  members: totals.length,
  total_points: sum('total_points'),
  points_from_events: sum('points_from_events'),
  points_from_adjustments: sum('points_from_adjustments'),
  points_from_role: sum('points_from_role'),
  max_total: Math.max(...totals.map((r) => Number(r.total_points ?? 0))),
  zero_point_members: totals.filter((r) => Number(r.total_points ?? 0) === 0).length,
};

console.log('\nCutover invariant:', JSON.stringify(invariant, null, 2));
await writeFile(
  join(OUT_DIR, 'invariant.json'),
  JSON.stringify({ exported_at: new Date().toISOString(), invariant, results }, null, 2) + '\n',
  'utf8',
);

if (mismatch) {
  console.error('\nRow counts do not match the Phase 0 audit. Do not proceed to the lockdown.');
  process.exit(1);
}
console.log('\nExport complete.');
