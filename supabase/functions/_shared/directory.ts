/**
 * Rice directory lookup — netID to name, so officers stop typing names by hand.
 *
 * Shared by live ingestion (ingest-checkin) and the name backfill script, for the same reason
 * netid.ts is shared: two copies of a resolution rule drift, and then the same netID gets a
 * different name depending on which path filled it in.
 *
 * Uses only global `fetch`, no imports. That is deliberate — this file has to run unchanged under
 * Deno (the Edge Function) and under bare `node` with type-stripping (scripts/), exactly like
 * netid.ts. Do not add a dependency here.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT THIS TALKS TO
 *
 * `https://search.rice.edu/json/people/p/0/0/?q=<query>` is the JSON backend behind Rice's public
 * people search at search.rice.edu. It needs no authentication, no API key, no VPN, and no campus
 * network. A response looks like:
 *
 *   {"stats": {"count": "1", "error": false},
 *    "results": [{"netid": "dr56", "name": "Diego Rico", "email": "Diego.Rico@rice.edu",
 *                 "college": "Wiess College", "major": "Computer Science", "year": "Senior", ...}]}
 *
 * It is UNDOCUMENTED and not a contract Rice owes us. It can change shape or disappear without
 * notice. Everything below is written so that when it does, the system degrades to exactly the
 * behavior it had before this file existed — a person with a netID and no name, visible in the
 * dashboard and fixable by hand — and never to a person with the WRONG name.
 *
 * Two operational notes for whoever maintains this next:
 *
 *   - search.rice.edu/robots.txt disallows /json/, /people/, /html/ and /*?q=. That is aimed at
 *     crawlers, and a lookup fired the first time a specific netID appears is not crawling. Keep it
 *     that way: cache the answer permanently in `people` (a person with a name is never looked up
 *     again), and throttle any bulk pass. Do not build anything that walks the directory.
 *   - Students can suppress their directory listing through ESTHER under FERPA. Those return zero
 *     results forever. That is correct behavior on Rice's part, not a bug to work around, and it is
 *     why manual name entry in the dashboard has to stay.
 * ---------------------------------------------------------------------------------------------
 */

const DIRECTORY_ENDPOINT = 'https://search.rice.edu/json/people/p/0/0/';

/** One directory hit, already verified to belong to the netID that was asked for. */
export interface DirectoryName {
  netid: string;
  firstName: string;
  /** Null for a single-token name. `people.last_name` is nullable, and display joins the two. */
  lastName: string | null;
}

/** Shape of the fields this module reads. The endpoint returns ~20 more that we deliberately ignore. */
interface DirectoryResult {
  netid?: string;
  name?: string;
}

/**
 * Split a directory name string into first and last.
 *
 * The rule is: FIRST token is the given name, EVERYTHING ELSE is the surname.
 *
 * That is the right rule for this organization specifically. Rice's directory returns compound
 * Hispanic surnames as plain space-separated tokens — "Ana Rosas Rodríguez", "Areli Garcia
 * Hernandez", "Carlos Garcia Rios" — where the correct split is Ana / Rosas Rodríguez. The
 * opposite rule (last token is the surname) would shear those into "Ana Rosas" / "Rodríguez",
 * and for a SHPE roster that is the common case, not the edge case.
 *
 * It is wrong for "First Middle Last", which becomes First / "Middle Last". That is an acceptable
 * trade here because of how these two columns are actually consumed: every reader joins them back
 * together with a space. The public leaderboard view selects first_name and last_name, and
 * dashboard/index.html renders `[first_name, last_name].filter(Boolean).join(' ')` everywhere it
 * shows a person. Nothing sorts or groups by last_name. So a misplaced boundary still displays the
 * person's full name correctly, which makes this a cosmetic risk rather than a correctness one.
 *
 * Do NOT try to be cleverer than this by parsing the `email` field. The alias looks authoritative
 * ("Diego.Rico@rice.edu") but is not: the same directory returns "ag352@rice.edu" (just the netID),
 * "Areli.Garcia.Hernandez@rice.edu" (dotted on every token, so it marks no boundary either),
 * "blanca.munoz@rice.edu" for "Blanca Munoz Garcia" (truncated), "None", and at least one alias
 * belonging to an unrelated string. It carries no split information this function doesn't already
 * have.
 */
export function splitDirectoryName(raw: string | null | undefined): { firstName: string; lastName: string | null } | null {
  if (raw == null) return null;

  // The endpoint spells an absent value as the literal string "None" on several fields (title,
  // email, department all do it), so an empty name arrives as "None" rather than "" or null.
  // Treating that as a real name would write a person called "None" into the roster.
  const value = String(raw).trim().replace(/\s+/g, ' ');
  if (value === '' || value === 'None') return null;

  const tokens = value.split(' ');
  const firstName = tokens[0];
  const lastName = tokens.length > 1 ? tokens.slice(1).join(' ') : null;
  return { firstName, lastName };
}

export interface LookupOptions {
  /** Per-request timeout. The endpoint answers in ~250ms; this is a stall guard, not a budget. */
  timeoutMs?: number;
  /** Injected in tests. Defaults to global fetch. */
  fetchImpl?: typeof fetch;
}

/**
 * Look up one netID. Returns null for "no confident answer", never throws.
 *
 * The verification rule below is the entire safety story of this module, so it gets its own
 * paragraph. The endpoint is a FUZZY FULL-TEXT SEARCH, not a key lookup: `?q=lee` returns 302
 * results because it matches the surname Lee, and results are ordered by the directory's own
 * relevance, not by how well they match a netID. Taking `results[0]` would therefore attach a
 * stranger's name to a netID whenever the netID happens to look like part of somebody's name.
 *
 * So this function never trusts position. It filters for a result whose own `netid` field equals
 * the netID we asked for, and requires exactly one such result. Zero matches, two matches, a
 * malformed body, a non-200, a network failure, a timeout: all of them return null, which the
 * caller turns into "leave the name blank", which is what the dashboard already handles today.
 *
 * This mirrors the posture in netid.ts: the failure this codebase is built to never commit is
 * inventing a match. A netID with no name is visible and one click from fixed. A netID with
 * somebody else's name is invisible and wrong, and it flows straight into the roster that the
 * sponsorship conversation reads off.
 */
export async function lookupNetid(netid: string, options: LookupOptions = {}): Promise<DirectoryName | null> {
  const { timeoutMs = 8000, fetchImpl = fetch } = options;

  const wanted = String(netid ?? '').trim().toLowerCase();
  if (wanted === '') return null;

  const url = `${DIRECTORY_ENDPOINT}?q=${encodeURIComponent(wanted)}`;

  // AbortSignal.timeout() exists in Deno and in Node 18+, but constructing the controller by hand
  // keeps this working on any runtime that has fetch at all, which is the bar the rest of this
  // file is written to.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let body: unknown;
  try {
    const res = await fetchImpl(url, {
      signal: controller.signal,
      headers: { accept: 'application/json' },
    });
    if (!res.ok) return null;
    body = await res.json();
  } catch {
    // Network error, abort, or a body that isn't JSON. All of these mean "we don't know", and
    // "we don't know" is a supported, already-handled state. Never rethrow: a directory outage
    // must not be able to fail an ingestion pass that would otherwise have recorded attendance.
    return null;
  } finally {
    clearTimeout(timer);
  }

  const results = (body as { results?: unknown })?.results;
  if (!Array.isArray(results)) return null;

  // The verification described above.
  const matches = (results as DirectoryResult[]).filter(
    (r) => String(r?.netid ?? '').trim().toLowerCase() === wanted,
  );
  if (matches.length !== 1) return null;

  const split = splitDirectoryName(matches[0]?.name);
  if (!split) return null;

  return { netid: wanted, firstName: split.firstName, lastName: split.lastName };
}

/**
 * Look up several netIDs, one request at a time with a pause between them.
 *
 * Sequential on purpose. This is a courtesy call against a university service that never asked to
 * be an API, on behalf of a student club that wants to keep being allowed to use it. The volume is
 * tiny either way — a normal ingestion pass has a handful of genuinely new people — so there is
 * nothing to gain from parallelism and something to lose.
 *
 * `limit` is a hard ceiling on requests per call so that no single invocation can turn into a walk
 * of the directory, however this gets called in future. Netids beyond the limit are simply absent
 * from the returned map, which the caller treats the same as an unresolved lookup: they stay
 * nameless and get picked up next time.
 */
export async function lookupNetids(
  netids: string[],
  options: LookupOptions & { limit?: number; delayMs?: number } = {},
): Promise<Map<string, DirectoryName>> {
  const { limit = 50, delayMs = 150, ...lookupOptions } = options;

  const found = new Map<string, DirectoryName>();
  const queue = [...new Set(netids.map((n) => String(n ?? '').trim().toLowerCase()).filter(Boolean))].slice(0, limit);

  for (let i = 0; i < queue.length; i++) {
    if (i > 0 && delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
    const hit = await lookupNetid(queue[i], lookupOptions);
    if (hit) found.set(hit.netid, hit);
  }

  return found;
}
