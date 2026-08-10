/**
 * netID resolution, shared by live ingestion and the backfill importer.
 *
 * Both paths MUST use this module. The whole reason `mac50` and `dea7@rice.edu` sat in one column
 * of `Fall 2025 Member Points.xlsx` is that every consumer re-derived the netID by hand; if the
 * importer and the Edge Function disagree by even one rule, historical and live rows stop joining.
 */

/** A Rice netID: letters and digits, at least one letter, e.g. `dr56`, `mac50`, `iaf1`. */
const NETID_RE = /^(?=.*[a-z])[a-z0-9]{2,12}$/;

/** Question titles that identify the netID field. Matches "NetID", "Net ID", "Rice email", "Email". */
const IDENTITY_QUESTION_RE = /net\s*id|netid|rice\s*email|email/i;

/**
 * Normalize one raw answer to a netID, or null if it isn't one.
 *
 * Accepts a bare netID or a Rice email and yields the netID either way, because the netID is the
 * local part of the address. A non-Rice address returns null rather than its local part — a
 * personal Gmail's local part is not a netID and inventing one would create a phantom person.
 */
export function normalizeNetid(raw: string | null | undefined): string | null {
  if (raw == null) return null;

  let value = String(raw).trim().toLowerCase().replace(/^mailto:/, '');
  // Forms sometimes carry a zero-width or non-breaking space from a paste.
  //
  // Written as \u escapes, NOT as the literal characters. Do not "simplify" this back to literal
  // glyphs. They are invisible, so any tool that copies this file -- a deploy that re-types its
  // contents, an editor normalizing whitespace, a paste through a chat window -- can silently swap
  // U+00A0 for a plain space with nothing on screen to show it happened. That exact corruption
  // occurred during a 2026-08-09 redeploy and is not theoretical.
  //
  // The failure it causes is worse than losing the cleanup: a class containing a literal space
  // strips real spaces too, so "dr 56" would be rewritten to "dr56" and silently attributed to
  // whoever actually owns that netID. Getting this wrong invents a match rather than missing one,
  // which is the one outcome the resolver is built to never do.
  value = value.replace(/[\u200b-\u200d\ufeff\u00a0]/g, '').trim();
  if (value === '') return null;

  const at = value.indexOf('@');
  if (at !== -1) {
    const domain = value.slice(at + 1);
    if (domain !== 'rice.edu') return null;
    value = value.slice(0, at);
  }

  return NETID_RE.test(value) ? value : null;
}

export interface FormAnswer {
  question: string;
  answer: string;
}

export interface IdentityResolution {
  netid: string | null;
  /** How it was found — useful when explaining an unmatched row to an officer. */
  via: 'question-title' | 'answer-shape' | null;
  /** The answer text that was tried, so unmatched_signins can show what was actually submitted. */
  raw: string | null;
}

/**
 * Find the netID in an arbitrary form response.
 *
 * Officers write their own forms, so there is no fixed question to rely on. Resolution order per
 * docs/DESIGN.md: match the question title first, then fall back to any answer that carries a
 * Rice ADDRESS. The fallback deliberately does not accept a bare netID-shaped word — see the
 * comment on step 2 below, which is the load-bearing one in this file.
 */
export function resolveIdentity(answers: FormAnswer[]): IdentityResolution {
  // 1. A question that says it wants a netID or email.
  for (const { question, answer } of answers) {
    if (IDENTITY_QUESTION_RE.test(question ?? '')) {
      const netid = normalizeNetid(answer);
      if (netid) return { netid, via: 'question-title', raw: answer ?? null };
    }
  }

  // 2. Otherwise, a Rice ADDRESS in any answer, whatever that question happened to be called.
  //    Deliberately second: a form asking "who referred you?" could hold one too, and the
  //    labelled question is the more trustworthy source.
  //
  //    Note what this branch does NOT accept, because that restriction is the entire point of it
  //    and must not be relaxed: a bare netID-shaped word. NETID_RE matches any 2-12 character run
  //    of letters and digits containing at least one letter, which is also the shape of most first
  //    names — "aaron", "paulina", "jr", and the gender answer "male" all satisfy it.
  //
  //    This is not hypothetical. Before the `@` guard existed, four sign-in forms carried identity
  //    only in Google's auto-collected email, which is not a form item and so never reached this
  //    function at all (see the getRespondentEmail() comment in apps-script/poller.js). Every
  //    response on those forms fell through to here, and this loop attributed each one to whatever
  //    the first question happened to be — on forms opening with "First Name", that produced 97
  //    phantom people out of 180 identities on 2026-08-09. It also silently destroyed real data:
  //    two distinct attendees both named Aaron collapsed into a single `aaron` row under
  //    unique (event_id, netid), and the second person's attendance was discarded as a duplicate.
  //
  //    Requiring the '@' makes that class of failure structurally impossible rather than merely
  //    unlikely. normalizeNetid already rejects every domain except rice.edu, so this branch can
  //    now only return an identity the respondent actually typed as a Rice address. A response
  //    carrying no address falls through to (3) and becomes an unmatched_signins row: visible,
  //    attributable to a specific event, and one click from fixed. That is the failure mode this
  //    module is supposed to have — missing a match, never inventing one.
  for (const { answer } of answers) {
    if (!String(answer ?? '').includes('@')) continue;
    const netid = normalizeNetid(answer);
    if (netid) return { netid, via: 'answer-shape', raw: answer ?? null };
  }

  // 3. Unresolvable. The caller routes this to unmatched_signins — never silently dropped, and
  //    never a phantom person.
  const firstAnswered = answers.find((a) => (a.answer ?? '').trim() !== '');
  return { netid: null, via: null, raw: firstAnswered?.answer ?? null };
}
