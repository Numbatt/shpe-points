/**
 * SHPE points — form poller.
 *
 * ONE time-driven trigger, every 15 minutes, owned by the club's shared Gmail account.
 *
 * Why polling instead of onFormSubmit triggers: Apps Script caps installable triggers at 20 per
 * script per user. With ~40 events a year, per-form triggers would silently stop being installable
 * partway through the fall — exactly the quiet failure that kills a system between officer
 * generations. One time-driven trigger has no such ceiling.
 *
 * Polling is also self-healing. The high-water mark lives in Supabase and only advances after a
 * successful write, so an outage means the next pass re-sends. A dropped onFormSubmit is gone
 * forever.
 *
 * Which folder(s) to watch is likewise not this script's problem. Per the no-manual-changes rule
 * (docs/DESIGN.md): "nobody should ever have to edit code, run a migration, or touch Apps Script
 * to keep this system running." A chapter that keeps one Drive folder per academic year would
 * otherwise need a human to update a FORMS_FOLDER_ID script property every fall — exactly the
 * kind of step a handoff loses. Instead this script asks the Edge Function which folders to walk
 * (GET returns one entry per academic_years row with a non-null forms_folder_id) and walks all of
 * them every pass. A year rolled forward without a folder yet, or rolled past on purpose, simply
 * isn't in that list — that's the entire mechanism for a folder stopping being watched, and it
 * requires a dashboard click, not an Apps Script edit. Re-walking an old year's folder every pass
 * is cheap: each form there already has a high-water mark, so a caught-up folder costs one Drive
 * listing plus a near-empty getResponses() call per form.
 *
 * ---------------------------------------------------------------------------
 * SETUP (do all of this while signed in as the shared Gmail, never a personal account)
 *
 *   1. script.google.com → New project → paste this file.
 *   2. Project Settings → Script Properties, add:
 *        INGEST_URL        https://<project-ref>.supabase.co/functions/v1/ingest-checkin
 *        INGEST_SECRET     the same value as the function's INGEST_SHARED_SECRET
 *      That's it — no folder ID. Which folders to watch comes from the database (see above), and
 *      is set from the dashboard when an officer creates or edits an academic year.
 *   3. Run `installTrigger` once and grant the permissions it asks for.
 *   4. Confirm under Triggers that exactly one 15-minute trigger exists.
 *
 * Triggers are owned by the account that installs them and stop firing silently when that account
 * is deprovisioned. Installing this as a personal Rice account is how this system would die the
 * summer after you graduate.
 * ---------------------------------------------------------------------------
 */

/** Apps Script kills a run at ~6 minutes; stop well short and let the next pass continue. */
var TIME_BUDGET_MS = 4 * 60 * 1000;

/**
 * How deep to walk below a configured folder. A year folder holding term subfolders is depth 1,
 * so 4 leaves plenty of room for whatever nesting a future officer invents while still bounding
 * the damage if someone pastes a Drive root ID into the Years screen.
 */
var MAX_FOLDER_DEPTH = 4;

function config_() {
  var props = PropertiesService.getScriptProperties();
  var cfg = {
    ingestUrl: props.getProperty('INGEST_URL'),
    secret: props.getProperty('INGEST_SECRET'),
  };
  if (!cfg.ingestUrl || !cfg.secret) {
    throw new Error('Missing script properties. Set INGEST_URL and INGEST_SECRET.');
  }
  return cfg;
}

/** Run once, as the shared Gmail. Safe to re-run: it clears its own duplicates first. */
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'pollForms') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('pollForms').timeBased().everyMinutes(15).create();
  Logger.log('Installed one 15-minute trigger for pollForms.');
}

/** The scheduled entry point. */
function pollForms() {
  var startedAt = Date.now();
  var cfg = config_();

  var state = fetchState_(cfg); // { forms: {form_id: last_response_at}, folders: [{yearId, folderId}] }

  if (state.folders.length === 0) {
    // Every academic year either has no folder configured yet or has been rolled past on
    // purpose. That's an expected, normal state right after a fresh academic_years row is
    // created and before an officer points it at a folder from the dashboard — not an error.
    Logger.log('No academic year has a forms_folder_id set. Nothing to watch this pass.');
    return;
  }

  var batch = [];
  var skippedFolders = 0;
  var skippedFiles = 0;

  // Breadth-first over subfolders, because the chapter files sign-in forms by term: a year's
  // folder holds "Fall 2025" and "Spring 2026" and no forms of its own. An officer sets ONE
  // folder ID per year and both terms are found, however they choose to nest things later.
  //
  // Two guards. MAX_FOLDER_DEPTH stops a mis-set ID (someone pastes the whole Drive root) from
  // walking the world. `seen` stops a loop: Drive lets a folder appear under several parents,
  // and a shortcut back to an ancestor would otherwise recurse forever.
  //
  // The queue is seeded deduped, so two years pointing at the same folder walk it once.
  var queue = [];
  var seen = {};
  for (var s = 0; s < state.folders.length; s++) {
    var seedId = state.folders[s].folderId;
    if (seen[seedId]) continue;
    seen[seedId] = true;
    queue.push({ id: seedId, yearId: state.folders[s].yearId, depth: 0 });
  }

  // One shared TIME_BUDGET_MS across every folder, not one budget per folder — a chapter with
  // several years' folders (last year re-walked for late submissions, this year live) must not
  // let an early folder consume the whole pass and starve the rest. Whatever isn't reached keeps
  // its existing high-water mark and is picked up on the next pass; nothing is lost by stopping.
  var foldersWalked = 0;

  while (queue.length > 0) {
    var folderInfo = queue.shift();

    if (Date.now() - startedAt > TIME_BUDGET_MS) {
      skippedFolders++;
      continue;
    }

    var folder;
    try {
      folder = DriveApp.getFolderById(folderInfo.id);
    } catch (err) {
      // A bad or deleted folder ID for one year (e.g. it was moved to the trash) must not take
      // down polling for every other year. Logged, not thrown, so the loop continues.
      Logger.log(
        'Could not open forms folder %s for year %s: %s',
        folderInfo.id,
        folderInfo.yearId,
        err
      );
      continue;
    }

    foldersWalked++;

    // Enqueue children before reading files, so a shallow folder holding nothing but subfolders
    // still contributes its terms even if the budget runs out partway through this pass.
    if (folderInfo.depth < MAX_FOLDER_DEPTH) {
      var subs = folder.getFolders();
      while (subs.hasNext()) {
        var sub = subs.next();
        var subId = sub.getId();
        if (seen[subId]) continue;
        seen[subId] = true;
        queue.push({ id: subId, yearId: folderInfo.yearId, depth: folderInfo.depth + 1 });
      }
    }

    var files = folder.getFilesByType(MimeType.GOOGLE_FORMS);

    while (files.hasNext()) {
      var file = files.next();

      if (Date.now() - startedAt > TIME_BUDGET_MS) {
        // Out of budget. Everything not reached keeps its high-water mark, so the next pass picks
        // it up. Nothing is lost by stopping here.
        skippedFiles++;
        continue;
      }

      var formId = file.getId();
      var since = state.forms[formId] ? new Date(state.forms[formId]) : null;

      var form;
      try {
        // Needs EDIT access for the owning account. A form created under an officer's personal
        // account and merely link-shared throws here.
        form = FormApp.openById(formId);
      } catch (err) {
        batch.push({
          formId: formId,
          title: file.getName(),
          unreadable: true,
          error:
            'Could not open this form. It was probably created under a personal account — the ' +
            'shared Gmail needs EDIT access. Original error: ' + err,
          responses: [],
        });
        continue;
      }

      // getResponses(timestamp) returns only what is newer, so a steady state pass is nearly
      // free. With no timestamp it returns the full history, which is why a form created a year
      // ago is ingested completely on first discovery.
      var responses = since ? form.getResponses(since) : form.getResponses();

      var payloadResponses = responses.map(function (r) {
        var answers = r.getItemResponses().map(function (ir) {
          var answer = ir.getResponse();
          return {
            question: ir.getItem().getTitle(),
            // Checkbox questions answer with an array; flatten so the netID resolver sees strings.
            answer: Array.isArray(answer) ? answer.join(', ') : String(answer),
          };
        });

        // Google's built-in "Collect email addresses" setting is NOT a form item, so it never
        // appears in getItemResponses() above. This is not a hypothetical gap: on 2026-08-09 the
        // first live pass ingested four GBM forms that relied on it instead of adding their own
        // netID question, and every one of them reached the resolver with no identity in the
        // payload at all. The answer-shape fallback in _shared/netid.ts then attributed each
        // response to the first question that looked like a netID -- on a form opening with
        // "First Name", that is a first name recorded as a person. 155 rows, 0 correct.
        //
        // Prepended rather than appended so it is also the first thing the shape fallback would
        // reach, and titled "Email" so it matches the resolver's existing question-title regex
        // with no change needed on that side.
        var respondentEmail = '';
        try {
          respondentEmail = r.getRespondentEmail();
        } catch (err) {
          // A form not collecting email returns '' rather than throwing, but this is wrapped
          // anyway: an identity the poller cannot read must degrade to the added questions
          // speaking for themselves, never to a thrown pass that records no attendance at all.
        }
        if (respondentEmail) {
          answers.unshift({ question: 'Email', answer: respondentEmail });
        }

        return {
          responseId: r.getId(),
          submittedAt: r.getTimestamp().toISOString(),
          answers: answers,
        };
      });

      // Send even when there are no new responses: that is how a brand-new empty form gets
      // discovered and shows up in "Needs attention" awaiting its type tap.
      batch.push({
        formId: formId,
        title: file.getName(),
        createdAt: file.getDateCreated().toISOString(),
        responses: payloadResponses,
      });
    }
  }

  if (batch.length === 0) {
    Logger.log(
      'No forms found. Walked %s folder(s) below %s configured root(s).',
      foldersWalked,
      state.folders.length
    );
    return;
  }

  var result = push_(cfg, batch);
  Logger.log(
    'Polled %s form(s) across %s folder(s) below %s configured root(s); skipped %s folder(s) and ' +
      '%s file(s) for time budget. Response: %s',
    batch.length,
    foldersWalked,
    state.folders.length,
    skippedFolders,
    skippedFiles,
    result
  );
}

/** Read every known form's high-water mark, and the Drive folders to watch, from Supabase. */
function fetchState_(cfg) {
  var res = UrlFetchApp.fetch(cfg.ingestUrl, {
    method: 'get',
    headers: { 'x-ingest-secret': cfg.secret },
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() !== 200) {
    throw new Error('Could not read poller state: ' + res.getResponseCode() + ' ' + res.getContentText());
  }
  var body = JSON.parse(res.getContentText());

  var formMap = {};
  body.forms.forEach(function (f) {
    if (f.last_response_at) formMap[f.form_id] = f.last_response_at;
  });

  // Per the no-manual-changes rule (docs/DESIGN.md), this script no longer holds a folder ID in
  // script properties at all — it asks the Edge Function, which answers from
  // academic_years.forms_folder_id. `body.folders` is already filtered to years with a non-null
  // folder; an empty array here is what "watch nothing" looks like.
  var folders = body.folders || [];

  return { forms: formMap, folders: folders };
}

function push_(cfg, forms) {
  var res = UrlFetchApp.fetch(cfg.ingestUrl, {
    method: 'post',
    contentType: 'application/json',
    headers: { 'x-ingest-secret': cfg.secret },
    payload: JSON.stringify({ forms: forms }),
    muteHttpExceptions: true,
  });
  var code = res.getResponseCode();
  if (code !== 200) {
    // Throwing makes the failure visible in the Apps Script execution log and leaves the
    // high-water marks untouched, so the next pass retries the same work.
    throw new Error('Ingest failed: ' + code + ' ' + res.getContentText());
  }
  return res.getContentText();
}

/**
 * Manual smoke test. Run from the editor after setup; logs what a pass would do without needing
 * to wait 15 minutes for the trigger.
 */
function testPollNow() {
  pollForms();
}
