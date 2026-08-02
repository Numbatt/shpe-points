/**
 * ingest-checkin — the only door attendance data comes through.
 *
 * The Apps Script poller POSTs everything it found on a pass. This function is the narrow write
 * path referred to in docs/DESIGN.md: it validates, normalizes, and records, and it is the only
 * thing besides a migration that writes `attendance`.
 *
 * Design properties that the poller depends on:
 *
 *   - IDEMPOTENT. Attendance is upserted on (event_id, netid) and ignored on conflict, so replaying
 *     a pass writes nothing new. This is what lets the poller advance its high-water mark only on
 *     success and simply resend on the next pass after a failure.
 *   - NEVER BLOCKS ON CLASSIFICATION. A newly discovered form creates an event with type_code NULL
 *     and records attendance at 0 points immediately. Tapping the type later restamps those rows
 *     (see the events_restamp_attendance trigger), so forgetting delays points, never loses them.
 *   - NEVER DROPS AN IDENTITY. Anything that doesn't resolve to a netID goes to unmatched_signins
 *     with its raw payload attached. No phantom people, no silent losses.
 *   - MEMBERSHIP FORMS LAND IN `memberships`, NEVER `attendance`. A form typed `Membership`
 *     (event_types.is_membership_form) upserts its resolved responses into `memberships` keyed on
 *     (netid, year_id) instead of paying attendance points for filling out a form — see
 *     docs/DESIGN.md, "Phase 3b: the membership gap". `year_id` is resolved from the *event's*
 *     occurred_on against academic_years, never from app_config.current_year_id, so a form filled
 *     out near a year boundary lands in the year it was actually filled out in. Demographics
 *     (class_level, major, gender, expected_grad_year, college, birthday) are populated only by
 *     exact question-title match against the template in ../_shared/membership-template.ts — see
 *     that file's header before editing it.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { resolveIdentity, type FormAnswer } from '../_shared/netid.ts';
import { extractMembershipDemographics, MEMBERSHIP_DEMOGRAPHIC_COLUMNS } from '../_shared/membership-template.ts';

interface IncomingResponse {
  /** Google's response ID — stable per submission, used to make replays cheap to spot. */
  responseId: string;
  submittedAt: string;
  answers: FormAnswer[];
}

interface IncomingForm {
  formId: string;
  title: string;
  /** Fallback event date when a form has no responses yet. */
  createdAt?: string;
  responses: IncomingResponse[];
  /**
   * Set by the poller when FormApp.openById() failed — almost always because the form was made
   * under a personal account and merely link-shared, so the shared Gmail has no edit access.
   * Recorded rather than skipped: this is the most likely way an officer breaks ingestion, and
   * docs/DESIGN.md requires it to fail loudly in "Needs attention".
   */
  unreadable?: boolean;
  error?: string;
}

const SHARED_SECRET = Deno.env.get('INGEST_SHARED_SECRET');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
// service_role: this function must write past RLS. It is never exposed to a browser.
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

/** Constant-time compare so a wrong secret can't be recovered by timing the response. */
function secretMatches(provided: string | null): boolean {
  if (!SHARED_SECRET || !provided) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(SHARED_SECRET);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (!secretMatches(req.headers.get('x-ingest-secret'))) return json({ error: 'unauthorized' }, 401);

  // GET returns each known form's high-water mark, and the Drive folders the poller should walk.
  // The poller reads both at the start of every pass instead of keeping its own copy of either in
  // PropertiesService: two stores of the same fact drift, and the database's copy is the one the
  // writes are actually keyed against. It also means the Apps Script project needs only the
  // shared secret, never the service role key or a folder ID.
  if (req.method === 'GET') {
    const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

    const { data: forms, error: formsError } = await db.from('forms').select('form_id, last_response_at');
    if (formsError) return json({ error: formsError.message }, 500);

    // The no-manual-changes rule (docs/DESIGN.md) puts the watched folder in the database, not in
    // an Apps Script property, so rolling the academic year is a dashboard action rather than an
    // Apps Script edit. A year with forms_folder_id null is simply not returned — that is how a
    // rolled-over year stops being watched, with no code change and no human touching the script.
    const { data: years, error: yearsError } = await db
      .from('academic_years')
      .select('id, forms_folder_id')
      .not('forms_folder_id', 'is', null);
    if (yearsError) return json({ error: yearsError.message }, 500);

    const folders = (years ?? []).map((y: { id: string; forms_folder_id: string }) => ({
      yearId: y.id,
      folderId: y.forms_folder_id,
    }));
    return json({ ok: true, forms: forms ?? [], folders });
  }

  if (req.method !== 'POST') return json({ error: 'GET or POST only' }, 405);

  let payload: { forms: IncomingForm[] };
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'invalid JSON' }, 400);
  }
  if (!Array.isArray(payload?.forms)) return json({ error: 'expected { forms: [...] }' }, 400);

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const summary: Record<string, unknown>[] = [];

  for (const form of payload.forms) {
    if (!form?.formId) continue;

    // --- A form the script cannot read. Surface it; do not skip it. ---
    if (form.unreadable) {
      await db.from('forms').upsert(
        {
          form_id: form.formId,
          unreadable_since: new Date().toISOString(),
          last_error: form.error ?? 'Form could not be opened. The shared account likely lacks edit access.',
        },
        { onConflict: 'form_id', ignoreDuplicates: false },
      );
      summary.push({ formId: form.formId, status: 'unreadable' });
      continue;
    }

    // --- Discover: has this form been seen before? ---
    const { data: known } = await db
      .from('forms')
      .select('form_id, event_id, last_response_at')
      .eq('form_id', form.formId)
      .maybeSingle();

    let eventId = known?.event_id as string | undefined;

    if (!eventId) {
      // The event date is the first response's timestamp, falling back to the form's creation
      // date for a form nobody has filled in yet.
      const firstResponse = form.responses
        .map((r) => r.submittedAt)
        .sort()[0];
      const occurredOn = (firstResponse ?? form.createdAt ?? new Date().toISOString()).slice(0, 10);

      const { data: created, error } = await db
        .from('events')
        .insert({
          name: form.title || 'Untitled form',
          type_code: null, // awaiting the one tap
          occurred_on: occurredOn,
          source: 'form',
          created_by: 'poller',
        })
        .select('id')
        .single();

      if (error || !created) {
        summary.push({ formId: form.formId, status: 'error', error: error?.message });
        continue;
      }
      eventId = created.id;

      await db.from('forms').upsert(
        { form_id: form.formId, event_id: eventId, unreadable_since: null, last_error: null },
        { onConflict: 'form_id' },
      );
    } else if (known?.last_error) {
      // A previously unreadable form that now opens — clear the flag so it leaves the queue.
      await db
        .from('forms')
        .update({ unreadable_since: null, last_error: null })
        .eq('form_id', form.formId);
    }

    // The event's current value. Null type means 0 points for now, restamped when tapped.
    const { data: event } = await db
      .from('events')
      .select('points, type_code, occurred_on, event_types(is_membership_form)')
      .eq('id', eventId)
      .single();

    // A membership form's answers belong in `memberships`, not the attendance ledger. Routing a
    // membership form's sign-ins into attendance would pay points for filling out a form asking
    // for your major and t-shirt size — see the header comment above and docs/DESIGN.md, "Phase
    // 3b: the membership gap".
    const isMembershipForm = (event as Record<string, any>)?.event_types?.is_membership_form === true;

    // Resolved once per form, not per response: an event has exactly one occurred_on, so it maps
    // to exactly one academic year. Deliberately NOT app_config.current_year_id — a membership
    // form filled out near a year boundary (or polled late, after officers have already moved the
    // "current year" pointer forward) must land in the year it was actually filled out in. This
    // mirrors resolve_unmatched_signin's logic exactly (see the migration
    // 20260802150000_year_lifecycle_and_membership.sql) so a response landed live and one dragged
    // out of unmatched_signins by hand resolve to the same year.
    let membershipYearId: string | null = null;
    if (isMembershipForm) {
      const occurredOn = (event as Record<string, any>)?.occurred_on as string | undefined;
      if (occurredOn) {
        const { data: years } = await db
          .from('academic_years')
          .select('id')
          .lte('starts_on', occurredOn)
          .gte('ends_on', occurredOn)
          .order('starts_on', { ascending: false })
          .limit(1);
        membershipYearId = years?.[0]?.id ?? null;
      }
    }

    const attendanceRows: Record<string, unknown>[] = [];
    const unmatchedRows: Record<string, unknown>[] = [];
    // Keyed on `${netid}|${year_id}` rather than pushed to an array: two responses from the same
    // person in one pass (a resubmission correcting a typo) must not appear twice in one upsert
    // call, because Postgres rejects an ON CONFLICT DO UPDATE that would touch the same row twice
    // in a single statement. Keeping only the latest by submittedAt also gives a resubmission the
    // behavior an officer would expect: the correction wins.
    const membershipByKey = new Map<string, Record<string, unknown>>();

    for (const response of form.responses ?? []) {
      const answers = Array.isArray(response.answers) ? response.answers : [];
      const { netid, raw } = resolveIdentity(answers);

      if (!netid) {
        unmatchedRows.push({
          event_id: eventId,
          raw_identifier: raw,
          raw_payload: { responseId: response.responseId, submittedAt: response.submittedAt, answers },
        });
        continue;
      }

      if (isMembershipForm) {
        if (!membershipYearId) {
          // No academic year covers this event's date — most likely a year nobody has created in
          // the dashboard yet. There is nowhere to write a membership row without a year_id, and
          // silently discarding the response would violate the NEVER DROPS AN IDENTITY guarantee
          // in the header comment, so it surfaces as an unmatched sign-in instead: an officer
          // creates the missing academic year and this becomes attachable by hand.
          unmatchedRows.push({
            event_id: eventId,
            raw_identifier: netid,
            raw_payload: { responseId: response.responseId, submittedAt: response.submittedAt, answers },
          });
          continue;
        }

        const key = `${netid}|${membershipYearId}`;
        const demographics = extractMembershipDemographics(answers);
        // Every row gets the SAME set of top-level keys — every column in
        // MEMBERSHIP_DEMOGRAPHIC_COLUMNS is present, explicitly null when this response didn't
        // exact-match a question for it. Two reasons: (1) it keeps the batch upsert below
        // unambiguous regardless of exactly how PostgREST treats an omitted key on conflict,
        // which isn't verified here; (2) it means "the latest submission for this person this
        // year wins, in full" — consistent with memberships representing this year's *current*
        // declared answers (docs/DESIGN.md: "you want the 2027 form's answers"), rather than a
        // patchwork where an old submission's leftover values quietly survive a newer one.
        const row: Record<string, unknown> = { netid, year_id: membershipYearId, submitted_at: response.submittedAt };
        for (const column of MEMBERSHIP_DEMOGRAPHIC_COLUMNS) {
          row[column] = column in demographics ? demographics[column] : null;
        }
        const existing = membershipByKey.get(key);
        if (!existing || String(response.submittedAt) > String(existing.submitted_at)) {
          membershipByKey.set(key, row);
        }
        continue;
      }

      attendanceRows.push({
        event_id: eventId,
        netid,
        points_awarded: event?.points ?? 0,
        source: 'form',
        recorded_at: response.submittedAt,
      });
    }

    const membershipRows = [...membershipByKey.values()];

    // Both attendance and memberships reference people, so anyone new has to exist first.
    // Recording attendance for a non-member is intentional per docs/DESIGN.md — eligibility is
    // computed at query time, and a retroactive membership backfills automatically.
    const newPeople = [
      ...new Set([
        ...attendanceRows.map((r) => r.netid as string),
        ...membershipRows.map((r) => r.netid as string),
      ]),
    ].map((netid) => ({ netid }));
    if (newPeople.length > 0) {
      await db.from('people').upsert(newPeople, { onConflict: 'netid', ignoreDuplicates: true });
    }

    // Dedup: one row per person per event, so a member submitting twice counts once.
    let inserted = 0;
    if (attendanceRows.length > 0) {
      const { data, error } = await db
        .from('attendance')
        .upsert(attendanceRows, { onConflict: 'event_id,netid', ignoreDuplicates: true })
        .select('id');
      if (error) {
        summary.push({ formId: form.formId, status: 'error', error: error.message });
        continue;
      }
      inserted = data?.length ?? 0;
    }

    // Upsert, not insert-or-ignore: unlike attendance (an immutable ledger where the first row
    // wins), a membership row represents the member's *current* declared demographics, so a
    // resubmission should update it. Every row above carries every demographic column explicitly
    // (null where unresolved), so this UPDATE fully replaces the previous row's demographics with
    // the latest submission's — no dependence on how PostgREST would otherwise treat a key a row
    // happened to omit.
    let membershipsWritten = 0;
    if (membershipRows.length > 0) {
      const { data, error } = await db
        .from('memberships')
        .upsert(membershipRows, { onConflict: 'netid,year_id' })
        .select('id');
      if (error) {
        summary.push({ formId: form.formId, status: 'error', error: error.message });
        continue;
      }
      membershipsWritten = data?.length ?? 0;
    }

    if (unmatchedRows.length > 0) {
      await db.from('unmatched_signins').insert(unmatchedRows);
    }

    // Advance the high-water mark only after everything above succeeded. If this function throws
    // partway, the mark stays put and the next pass re-sends — which is safe precisely because
    // the writes above are idempotent.
    const latest = form.responses.map((r) => r.submittedAt).sort().at(-1);
    if (latest) {
      await db.from('forms').update({ last_response_at: latest }).eq('form_id', form.formId);
    }

    summary.push({
      formId: form.formId,
      eventId,
      received: form.responses?.length ?? 0,
      recorded: inserted,
      membershipsRecorded: membershipsWritten,
      unmatched: unmatchedRows.length,
      awaitingType: event?.type_code == null,
    });
  }

  return json({ ok: true, forms: summary });
});
