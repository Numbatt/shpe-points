#!/usr/bin/env node
/**
 * One-time historical importer.
 *
 * Runs locally, by someone technical, never from the dashboard. It exists because Spring 2026 (and
 * most of Fall 2025) must count toward the October 2026 convention, and that data lives in
 * spreadsheets rather than in this database.
 *
 * It reads the two shapes that history actually comes in:
 *
 *   wide       member rows x event columns — the `Fall 2025 Member Points.xlsx` shape:
 *              First Name, Last Name, Net ID, Total Points, GBM #1, Block Party, Recruiting 101
 *              A non-empty cell under an event column means that person attended.
 *
 *   responses  a form-response export, one row per sign-in, with a timestamp column and a netID
 *              or Rice email column.
 *
 * DRY RUN BY DEFAULT. Nothing is written without --commit, and --commit prints the same summary
 * first. Every row it writes is tagged source='backfill', so historical data stays permanently
 * distinguishable from anything the live pipeline produced.
 *
 * Identity resolution is imported from the Edge Function's module rather than reimplemented —
 * if the importer and live ingestion disagree by one rule, historical and live rows stop joining.
 *
 * Usage:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
 *     node scripts/backfill.ts wide      <file.csv> --meta <events.json> [--commit]
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
 *     node scripts/backfill.ts responses <file.csv> --event "GBM 3" --date 2026-02-11 --type gbm [--commit]
 *
 * `events.json` for the wide mode maps each event column to its date and type:
 *   { "GBM #1": { "date": "2025-08-28", "type": "gbm" },
 *     "Block Party": { "date": "2025-08-29", "type": "social" } }
 */

import { readFileSync } from 'node:fs';
import { normalizeNetid, resolveIdentity } from '../supabase/functions/_shared/netid.ts';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

interface PlannedEvent {
  name: string;
  occurredOn: string;
  typeCode: string;
  points: number | null;
  attendees: string[];
}

interface Plan {
  events: PlannedEvent[];
  /** netIDs not already in `people`. */
  newPeople: Set<string>;
  /** Raw values that never resolved — these become unmatched_signins, never guesses. */
  unresolved: { event: string; raw: string }[];
}

// ---------------------------------------------------------------------------
// CSV parsing (RFC 4180 — quoted fields, embedded commas and newlines)
// ---------------------------------------------------------------------------

function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (inQuotes) {
      if (char === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else field += char;
      continue;
    }
    if (char === '"') { inQuotes = true; continue; }
    if (char === ',') { row.push(field); field = ''; continue; }
    if (char === '\r') continue;
    if (char === '\n') { row.push(field); rows.push(row); row = []; field = ''; continue; }
    field += char;
  }
  if (field !== '' || row.length > 0) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((c) => c.trim() !== ''));
}

/** Find a column whose header matches a pattern; -1 when absent. */
const findColumn = (headers: string[], re: RegExp) =>
  headers.findIndex((h) => re.test((h ?? '').trim()));

// ---------------------------------------------------------------------------
// Readers
// ---------------------------------------------------------------------------

/** Columns that describe the person or a precomputed total rather than an event. */
const NON_EVENT_COLUMN = /^(first\s*name|last\s*name|net\s*id|netid|rice\s*email|email|total(\s*points)?|name|timestamp)$/i;

function readWide(path: string, metaPath: string): Plan {
  const rows = parseCsv(readFileSync(path, 'utf8'));
  if (rows.length < 2) throw new Error(`${path}: needs a header row and at least one data row.`);

  const headers = rows[0].map((h) => h.trim());
  const meta = JSON.parse(readFileSync(metaPath, 'utf8')) as Record<string, { date: string; type: string; points?: number }>;

  const idCol = findColumn(headers, /net\s*id|netid|rice\s*email|email/i);
  if (idCol === -1) throw new Error(`${path}: no Net ID / email column found.`);

  const eventCols = headers
    .map((h, i) => ({ name: h, index: i }))
    .filter(({ name }) => name !== '' && !NON_EVENT_COLUMN.test(name));

  const missing = eventCols.filter(({ name }) => !meta[name]).map(({ name }) => name);
  if (missing.length > 0) {
    // Refusing here rather than guessing: an event with the wrong date lands in the wrong
    // window, and an event with the wrong type is mispriced.
    throw new Error(
      `${metaPath} is missing date/type for: ${missing.join(', ')}\n` +
      `Add an entry for each, e.g. { "${missing[0]}": { "date": "2026-02-11", "type": "gbm" } }`,
    );
  }

  const plan: Plan = { events: [], newPeople: new Set(), unresolved: [] };

  for (const { name, index } of eventCols) {
    const attendees: string[] = [];
    for (const row of rows.slice(1)) {
      if ((row[index] ?? '').trim() === '') continue; // blank cell = did not attend
      const raw = row[idCol] ?? '';
      const netid = normalizeNetid(raw);
      if (netid) attendees.push(netid);
      else if (raw.trim() !== '') plan.unresolved.push({ event: name, raw });
    }
    plan.events.push({
      name,
      occurredOn: meta[name].date,
      typeCode: meta[name].type,
      points: meta[name].points ?? null,
      attendees: [...new Set(attendees)],
    });
  }
  return plan;
}

function readResponses(path: string, name: string, date: string, type: string): Plan {
  const rows = parseCsv(readFileSync(path, 'utf8'));
  if (rows.length < 2) throw new Error(`${path}: needs a header row and at least one data row.`);

  const headers = rows[0].map((h) => h.trim());
  const plan: Plan = { events: [], newPeople: new Set(), unresolved: [] };
  const attendees: string[] = [];

  for (const row of rows.slice(1)) {
    // Reuse the live resolver so a hand-made form's odd column layout is handled identically
    // here and in the Edge Function.
    const { netid, raw } = resolveIdentity(headers.map((q, i) => ({ question: q, answer: row[i] ?? '' })));
    if (netid) attendees.push(netid);
    else if (raw && raw.trim() !== '') plan.unresolved.push({ event: name, raw });
  }

  plan.events.push({ name, occurredOn: date, typeCode: type, points: null, attendees: [...new Set(attendees)] });
  return plan;
}

// ---------------------------------------------------------------------------
// Supabase
// ---------------------------------------------------------------------------

async function api(path: string, init: RequestInit = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY!,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'content-type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
  if (!res.ok) throw new Error(`${path}: ${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

// ---------------------------------------------------------------------------
// Preview and commit
// ---------------------------------------------------------------------------

function printPreview(plan: Plan, existingPeople: Set<string>, existingEvents: Map<string, string>) {
  console.log('\n=== BACKFILL PREVIEW ===\n');
  let totalRows = 0;

  for (const event of plan.events) {
    const already = existingEvents.has(`${event.name}|${event.occurredOn}`);
    console.log(
      `${already ? 'EXISTS' : 'NEW   '}  ${event.occurredOn}  ${event.name}` +
      `  [${event.typeCode}]  ${event.attendees.length} attendee(s)`,
    );
    totalRows += event.attendees.length;
    const unknown = event.attendees.filter((n) => !existingPeople.has(n));
    unknown.forEach((n) => plan.newPeople.add(n));
    if (unknown.length > 0) console.log(`         new people: ${unknown.join(', ')}`);
  }

  console.log(`\nEvents:          ${plan.events.length}`);
  console.log(`Attendance rows: ${totalRows}`);
  console.log(`New people:      ${plan.newPeople.size}`);
  console.log(`Unresolved:      ${plan.unresolved.length}`);

  if (plan.unresolved.length > 0) {
    console.log('\nThese will NOT be imported — fix them at the source and re-run, or resolve');
    console.log('them in the dashboard afterwards. They are never guessed at:');
    for (const { event, raw } of plan.unresolved.slice(0, 25)) {
      console.log(`  ${event}: ${JSON.stringify(raw)}`);
    }
    if (plan.unresolved.length > 25) console.log(`  ... and ${plan.unresolved.length - 25} more`);
  }
}

async function commit(plan: Plan, existingEvents: Map<string, string>) {
  console.log('\n=== COMMITTING ===\n');

  if (plan.newPeople.size > 0) {
    await api('people?on_conflict=netid', {
      method: 'POST',
      headers: { Prefer: 'resolution=ignore-duplicates' },
      body: JSON.stringify([...plan.newPeople].map((netid) => ({ netid }))),
    });
    console.log(`people: +${plan.newPeople.size}`);
  }

  for (const event of plan.events) {
    const key = `${event.name}|${event.occurredOn}`;
    let eventId = existingEvents.get(key);

    if (!eventId) {
      const [created] = await api('events', {
        method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({
          name: event.name,
          occurred_on: event.occurredOn,
          type_code: event.typeCode,
          points: event.points,
          source: 'backfill',
          created_by: 'backfill-script',
        }),
      });
      eventId = created.id;
    }

    // points_awarded is left to the database: the events_default_points trigger fills the event's
    // value from its type, and events_restamp_attendance stamps the rows. Recomputing it here
    // would be a second implementation of the same rule.
    const [{ points }] = await api(`events?id=eq.${eventId}&select=points`);

    if (event.attendees.length > 0) {
      await api('attendance?on_conflict=event_id,netid', {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates' },
        body: JSON.stringify(
          event.attendees.map((netid) => ({
            event_id: eventId,
            netid,
            points_awarded: points ?? 0,
            source: 'backfill',
          })),
        ),
      });
    }
    console.log(`${event.name}: ${event.attendees.length} row(s)`);
  }
  console.log('\nDone.');
}

// ---------------------------------------------------------------------------

async function main() {
  const argv = process.argv.slice(2);
  const mode = argv[0];
  const file = argv[1];
  const flag = (name: string) => {
    const i = argv.indexOf(`--${name}`);
    return i === -1 ? undefined : argv[i + 1];
  };
  const isCommit = argv.includes('--commit');

  if (!mode || !file || !['wide', 'responses'].includes(mode)) {
    console.error('Usage: backfill.ts <wide|responses> <file.csv> [options] [--commit]');
    console.error('  wide      --meta <events.json>');
    console.error('  responses --event <name> --date <YYYY-MM-DD> --type <code>');
    process.exit(1);
  }

  let plan: Plan;
  if (mode === 'wide') {
    const meta = flag('meta');
    if (!meta) throw new Error('wide mode needs --meta <events.json>');
    plan = readWide(file, meta);
  } else {
    const [name, date, type] = [flag('event'), flag('date'), flag('type')];
    if (!name || !date || !type) throw new Error('responses mode needs --event, --date and --type');
    plan = readResponses(file, name, date, type);
  }

  if (!SUPABASE_URL || !SERVICE_KEY) {
    // Still useful without credentials: parsing and identity resolution can be checked offline.
    console.log('No SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — parse-only preview.\n');
    printPreview(plan, new Set(), new Map());
    return;
  }

  const people: { netid: string }[] = await api('people?select=netid');
  const events: { id: string; name: string; occurred_on: string }[] =
    await api('events?select=id,name,occurred_on');

  const existingPeople = new Set(people.map((p) => p.netid));
  const existingEvents = new Map(events.map((e) => [`${e.name}|${e.occurred_on}`, e.id]));

  printPreview(plan, existingPeople, existingEvents);

  if (!isCommit) {
    console.log('\nDry run. Re-run with --commit to write.');
    return;
  }
  await commit(plan, existingEvents);
}

main().catch((err) => {
  console.error(`\nFailed: ${err.message}`);
  process.exit(1);
});
