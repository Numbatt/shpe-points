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
 *   - PAYING POINTS AND COLLECTING MEMBERSHIP ARE SEPARATE QUESTIONS. A form typed `Membership`
 *     (event_types.is_membership_form) pays no attendance — filling out a form asking your major
 *     is not showing up, see docs/DESIGN.md, "Phase 3b: the membership gap". Independently, any
 *     event with `events.collects_membership` upserts its resolved responses into `memberships`
 *     keyed on (netid, year_id). An event can do both: Fall GBM 1 - 08/28/25 was the GBM sign-in
 *     AND the 2025-26 membership form, because one form is what students actually fill out.
 *     `year_id` is resolved from the *event's* occurred_on against academic_years, never from
 *     app_config.current_year_id, so a form filled out near a year boundary lands in the year it
 *     was actually filled out in. Demographics (class_level, major, gender, expected_grad_year,
 *     college, birthday) are populated only by exact question-title match against the template in
 *     ../_shared/membership-template.ts — see that file's header before editing it.
 *   - A MEMBERSHIP ROW IS A DECLARATION; A SIGN-IN IS A SCRAP. The membership upsert REPLACES a
 *     person's demographics wholesale (the latest submission wins, in full). An ordinary sign-in's
 *     demographic answers go through gapfill_membership_demographics instead, which can only fill
 *     nulls on a row that already exists — it can never create a member. Do not unify them.
 *   - NAMES ARE FILLED IN, NEVER REQUIRED. A sign-in carries a netID and usually nothing else, so
 *     a first-time attendee lands as a `people` row with no name. After the upsert, anyone in the
 *     batch still missing a name gets one looked up from Rice's public directory via
 *     ../_shared/directory.ts. That lookup is best-effort in the strict sense: it cannot fail a
 *     pass, it never overwrites a name a human typed, and when it finds nothing the person stays
 *     exactly as they were — nameless, visible, and editable in the dashboard.
 */

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';
import { resolveIdentity, type FormAnswer } from '../_shared/netid.ts';
import { extractMembershipDemographics, MEMBERSHIP_DEMOGRAPHIC_COLUMNS } from '../_shared/membership-template.ts';
import { lookupNetids } from '../_shared/directory.ts';
import { routeEvent } from '../_shared/event-routing.ts';

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

/**
 * Fill in first/last name from Rice's public directory for anyone in this batch who has none.
 *
 * Best-effort by construction. Every failure path — the directory being down, a suppressed
 * listing, an ambiguous result, a write error — leaves the person exactly as they are today: a
 * netID with no name, shown as "no name on file" in the dashboard and one text field from fixed.
 * Nothing here is allowed to fail an ingestion pass; attendance is the thing that must land.
 *
 * Reads before it looks anything up, for two reasons. It keeps the outbound request count equal to
 * the number of people who genuinely need a name (a normal pass needs zero, and makes zero
 * requests), and it means a name only ever gets fetched once per person in practice — the answer
 * is cached by virtue of being written to `people`.
 */
async function fillMissingNames(db: SupabaseClient, netids: string[]): Promise<void> {
  try {
    if (netids.length === 0) return;

    const { data: nameless, error } = await db
      .from('people')
      .select('netid')
      .in('netid', netids)
      .is('first_name', null)
      .is('last_name', null);

    if (error || !nameless || nameless.length === 0) return;

    const found = await lookupNetids(
      (nameless as { netid: string }[]).map((p) => p.netid),
      // A pass with more than 25 brand-new nameless people is a backfill, not a sign-in sheet.
      // The rest stay nameless and get picked up on a later pass, which is the same outcome as a
      // failed lookup and needs no extra handling.
      { limit: 25 },
    );

    for (const person of found.values()) {
      // Guarded on both columns still being null rather than a plain update. An officer can be
      // typing a name into the dashboard at the same moment the 15-minute poller runs, and a
      // hand-typed name is the more authoritative one: a person may go by something other than
      // what the registrar has, and they told an officer which. Directory data fills a blank, it
      // never overwrites a human.
      await db
        .from('people')
        .update({ first_name: person.firstName, last_name: person.lastName })
        .eq('netid', person.netid)
        .is('first_name', null)
        .is('last_name', null);
    }
  } catch {
    // Deliberately swallowed. See the header comment: a directory outage must not be able to turn
    // a pass that successfully recorded attendance into a failed one, because a failed pass leaves
    // the high-water mark unadvanced and re-sends the whole batch next time.
  }
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

    // --- Discover: has this form been seen before? ---
    // Read before branching on `unreadable`. The unreadable path below must UPDATE an existing row
    // rather than upsert one: an upsert that omits event_id could clear the link between a form
    // that has gone unreadable and the event it already created, and the next readable pass would
    // then create a *second* event for the same form.
    const { data: known } = await db
      .from('forms')
      .select('form_id, event_id, last_response_at, last_error')
      .eq('form_id', form.formId)
      .maybeSingle();

    // --- A form the script cannot read. Surface it; do not skip it. ---
    if (form.unreadable) {
      const flag = {
        unreadable_since: new Date().toISOString(),
        last_error: form.error ?? 'Form could not be opened. The shared account likely lacks edit access.',
        // Recorded so Needs attention can name the form. Without it the officer sees a bare Drive
        // file ID and has no way to tell which form is broken.
        title: form.title || null,
      };

      // event_id stays null for a form that has never been readable — we can't know its date or
      // its responses. forms.event_id is nullable for exactly this case; see the migration
      // 20260802_forms_allow_unreadable_before_event.
      const { error } = known
        ? await db.from('forms').update(flag).eq('form_id', form.formId)
        : await db.from('forms').insert({ form_id: form.formId, ...flag });

      if (error) {
        // Never swallow this. That row IS the loud failure docs/DESIGN.md verification #10
        // requires; a silent write failure here is indistinguishable from the form being fine.
        summary.push({ formId: form.formId, status: 'error', error: error.message });
        continue;
      }

      summary.push({ formId: form.formId, status: 'unreadable' });
      continue;
    }

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
        {
          form_id: form.formId,
          event_id: eventId,
          title: form.title || null,
          unreadable_since: null,
          last_error: null,
        },
        { onConflict: 'form_id' },
      );
    } else {
      // Keep the event's name mirroring Drive's current title on every pass, not just at
      // discovery. An officer routinely creates a form as "Untitled form", fills it in over the
      // following days, and retitles it once — the dashboard's Event column must show whatever
      // it's titled now, not what it was titled the moment the poller first saw it. Nothing else
      // writes events.name, so there's no hand-typed value here to protect.
      const titleFields: Record<string, unknown> = { title: form.title || null };
      if (known?.last_error) {
        // A previously unreadable form that now opens — clear the flag so it leaves the queue.
        titleFields.unreadable_since = null;
        titleFields.last_error = null;
      }
      await db.from('forms').update(titleFields).eq('form_id', form.formId);
      await db.from('events').update({ name: form.title || 'Untitled form' }).eq('id', eventId);
    }

    // The event's current value. Null type means 0 points for now, restamped when tapped.
    const { data: event } = await db
      .from('events')
      .select('points, type_code, occurred_on, ignored_at, collects_membership, event_types(is_membership_form)')
      .eq('id', eventId)
      .single();

    // --- A form an officer has marked "not an event". ---
    // The poller walks a whole Drive folder, so it also finds forms that were never sign-ins: an
    // officer application, a t-shirt survey, a social RSVP. Dismissing one sets events.ignored_at
    // (see the migration 20260809221613_events_ignored.sql). From then on its responses are read
    // and thrown away rather than recorded.
    //
    // The high-water mark is still advanced. That is the whole point of doing this here rather
    // than simply skipping the form: leaving the mark alone would make every 15-minute pass
    // re-download this form's entire response history forever, and a survey with a few hundred
    // responses would quietly eat the poller's 4-minute budget and starve the real sign-in forms
    // behind it. Advancing the mark costs one near-empty getResponses() call per pass instead.
    //
    // Nothing is written and nothing is deleted here, so un-dismissing is just clearing the two
    // columns; responses submitted while it was dismissed are the only ones not recoverable, which
    // is the correct trade for a form that isn't an event.
    if ((event as Record<string, any>)?.ignored_at) {
      const latestIgnored = form.responses.map((r) => r.submittedAt).sort().at(-1);
      if (latestIgnored) {
        await db.from('forms').update({ last_response_at: latestIgnored }).eq('form_id', form.formId);
      }
      summary.push({
        formId: form.formId,
        eventId,
        status: 'ignored',
        received: form.responses?.length ?? 0,
      });
      continue;
    }

    // --- Two independent questions, not one fork. ---
    //
    // These used to be the same decision: a membership form's answers belong in `memberships`, an
    // ordinary sign-in's belong in `attendance`, pick one. That was wrong, and Fall GBM 1 -
    // 08/28/25 is the proof — it was BOTH the GBM sign-in and the 2025-26 membership form, because
    // one form is what students actually fill out. Either answer lost real data: routed to
    // attendance, the year got no demographics at all; routed to memberships, 73 people lost the
    // point they showed up for.
    //
    //   paysAttendance      — does showing up here earn the event's points?
    //   collectsMembership  — does this form also declare who you are this year?
    //
    // A membership TYPE still pays nothing: filling out a form asking your major and t-shirt size
    // is not attendance (docs/DESIGN.md, "Phase 3b: the membership gap"). What changed is that an
    // event can now say yes to the second question without saying no to the first.
    // Both answers come from ../_shared/event-routing.ts, which carries the full history of why
    // this is two booleans and not one fork, and is unit-tested by scripts/test-event-routing.ts.
    const { paysAttendance, collectsMembership } = routeEvent(event as Record<string, any>);

    // Resolved once per form, not per response: an event has exactly one occurred_on, so it maps
    // to exactly one academic year. Deliberately NOT app_config.current_year_id — a membership
    // form filled out near a year boundary (or polled late, after officers have already moved the
    // "current year" pointer forward) must land in the year it was actually filled out in. This
    // mirrors resolve_unmatched_signin's logic exactly (see the migration
    // 20260802150000_year_lifecycle_and_membership.sql) so a response landed live and one dragged
    // out of unmatched_signins by hand resolve to the same year.
    //
    // Resolved for EVERY event, not only membership forms: an ordinary sign-in form's demographic
    // answers are used to gap-fill an existing membership row (see the gap-fill block below), and
    // that write needs the same year_id resolved by the same rule. One extra query per form.
    let membershipYearId: string | null = null;
    {
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
    // Demographics harvested from an ORDINARY sign-in form, to fill blanks on membership rows that
    // already exist. Keyed and deduped for the same reason as membershipByKey above: one statement
    // must not touch the same (netid, year_id) twice. Kept in a separate map because the two have
    // opposite write semantics — see gapfill_membership_demographics' migration.
    const gapfillByKey = new Map<string, Record<string, unknown>>();

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

      if (collectsMembership && !membershipYearId) {
        // No academic year covers this event's date — most likely a year nobody has created in
        // the dashboard yet. There is nowhere to write a membership row without a year_id, and
        // silently discarding the response would violate the NEVER DROPS AN IDENTITY guarantee
        // in the header comment, so it surfaces as an unmatched sign-in instead: an officer
        // creates the missing academic year and this becomes attachable by hand.
        //
        // This no longer skips the attendance write below. Only the demographics are stranded; the
        // point is not, and losing a point to a missing year row would be a new bug of exactly the
        // kind this file exists to avoid. Recovering it later is safe because
        // resolve_unmatched_signin inserts attendance `on conflict do nothing`, so attaching this
        // by hand adds the membership row without ever double-paying.
        //
        // Reaching this at all takes deleting an academic_years row out from under a live event:
        // events_membership_is_exclusive refuses to set the flag when no year covers the date.
        unmatchedRows.push({
          event_id: eventId,
          raw_identifier: netid,
          raw_payload: { responseId: response.responseId, submittedAt: response.submittedAt, answers },
        });
      } else if (collectsMembership) {
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
      }

      // ...and, independently, the attendance write. No `continue` above any more: that `continue`
      // WAS the bug. It returned to the top of the loop before ever reaching this push, which is
      // why a membership-typed event could never also record attendance no matter what else changed.
      if (!paysAttendance) continue;

      attendanceRows.push({
        event_id: eventId,
        netid,
        points_awarded: event?.points ?? 0,
        source: 'form',
        recorded_at: response.submittedAt,
      });

      // Gap-fill. Ordinary sign-in forms ask Gender/College/Year/Major too, and until now those
      // answers were read and thrown away for every matched netID. They can only ever COMPLETE a
      // membership row that already exists — never create one, never overwrite a non-null column.
      // The database enforces both halves (the function is an UPDATE with coalesce), so this side
      // just has to hand over what it saw.
      //
      // Unlike the membership path above, only the keys that actually resolved are sent: an
      // explicit null here would be indistinguishable from "no answer" and coalesce would ignore
      // it anyway, but sending it invites a future reader to add an INSERT and reintroduce the
      // is_current_member problem.
      //
      // Skipped entirely when the event collects membership: that path already wrote a COMPLETE
      // membership row from this very response, so coalescing the same answers back over it is
      // pure work. The two are not alternatives in general — an ordinary sign-in still gap-fills —
      // they just have nothing to add to each other on the same response.
      if (membershipYearId && !collectsMembership) {
        const demographics = extractMembershipDemographics(answers);
        if (Object.keys(demographics).length > 0) {
          const key = `${netid}|${membershipYearId}`;
          const row = { netid, year_id: membershipYearId, ...demographics, submittedAt: response.submittedAt };
          const existing = gapfillByKey.get(key);
          if (!existing || String(response.submittedAt) > String(existing.submittedAt)) {
            gapfillByKey.set(key, row);
          }
        }
      }
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
      await fillMissingNames(db, newPeople.map((p) => p.netid));
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

    // Fill blanks on membership rows that already exist, from ordinary sign-in answers.
    //
    // Swallows every failure, exactly like fillMissingNames above: attendance is the thing that
    // has to land. A demographics write is a convenience, and it must never be able to fail a pass
    // that has already recorded who showed up — nor stop the high-water mark from advancing, which
    // would make the next pass re-send everything.
    let demographicsFilled = 0;
    const gapfillRows = [...gapfillByKey.values()].map(({ submittedAt: _drop, ...row }) => row);
    if (gapfillRows.length > 0) {
      try {
        const { data, error } = await db.rpc('gapfill_membership_demographics', { p_rows: gapfillRows });
        if (!error && typeof data === 'number') demographicsFilled = data;
      } catch { /* never fails a pass */ }
    }

    // Dedup, mirroring the attendance upsert above: a re-polled response that is still unattached
    // must not create a second row every time the poller sees it again. Keyed on responseId rather
    // than netid (unmatchedRows has none, by definition) via the generated `response_id` column and
    // its unique index added in 20260827000000_dedupe_unmatched_signins.sql.
    if (unmatchedRows.length > 0) {
      await db
        .from('unmatched_signins')
        .upsert(unmatchedRows, { onConflict: 'event_id,response_id', ignoreDuplicates: true });
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
      demographicsFilled,
      unmatched: unmatchedRows.length,
      awaitingType: event?.type_code == null,
    });
  }

  return json({ ok: true, forms: summary });
});
