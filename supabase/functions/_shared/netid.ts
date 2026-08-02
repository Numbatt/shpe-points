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
  value = value.replace(/[​-‍﻿ ]/g, '').trim();
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
 * docs/DESIGN.md: match the question title first, then fall back to any answer that simply looks
 * like a netID or Rice address.
 */
export function resolveIdentity(answers: FormAnswer[]): IdentityResolution {
  // 1. A question that says it wants a netID or email.
  for (const { question, answer } of answers) {
    if (IDENTITY_QUESTION_RE.test(question ?? '')) {
      const netid = normalizeNetid(answer);
      if (netid) return { netid, via: 'question-title', raw: answer ?? null };
    }
  }

  // 2. Otherwise, any answer shaped like one. Deliberately second: a form asking "who referred
  //    you?" could hold a netID too, and the labelled question is the more trustworthy source.
  for (const { answer } of answers) {
    const netid = normalizeNetid(answer);
    if (netid) return { netid, via: 'answer-shape', raw: answer ?? null };
  }

  // 3. Unresolvable. The caller routes this to unmatched_signins — never silently dropped, and
  //    never a phantom person.
  const firstAnswered = answers.find((a) => (a.answer ?? '').trim() !== '');
  return { netid: null, via: null, raw: firstAnswered?.answer ?? null };
}
