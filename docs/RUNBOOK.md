# SHPE Points — Runbook

**For the VP who inherits this.** You do not need to be technical to run it. If you can create a
Google Form and open a web page, you can run this system.

---

## The whole job, in one paragraph

Create a Google Form for an event **while signed in as the club's shared Gmail**, put it in the
shared forms folder, and share it with members. Within 15 minutes the event shows up in the
dashboard under **Needs attention**. Tap what kind of event it was. That's it — points are awarded
to everyone who signed in, and the leaderboard on shpe.rice.edu updates itself.

Everything else in this document is either once a year or something going wrong.

---

## The one rule

> **Create forms while signed in as the shared Gmail account.**

A form made under your personal Rice account and merely link-shared **cannot be read** by the
system. It will appear in **Needs attention** under "Forms the poller cannot read" rather than
failing silently — but no attendance is recorded until you fix it.

To fix one: open the form → Share → add the shared Gmail as an **Editor**. It ingests on the next
pass, including every response already submitted.

The same rule is why everything — the Supabase project, the Apps Script, the Vercel deploy, the
Drive folder — must live under the shared account. Google triggers are owned by whoever installed
them and **stop firing silently** when that person's Rice account is deprovisioned. That is how
systems like this normally die: not with an error, but with a quiet stop the summer after someone
graduates.

---

## Weekly rhythm

Open the dashboard. Look at **Needs attention**. It usually has one row per new event.

**Events awaiting a type.** Tap the type. Takes about ten seconds.

You cannot break anything by being slow here. Attendance is recorded the moment someone submits
the form, at zero points. Tapping the type later awards points to everyone already recorded,
including people who signed in weeks earlier. Forgetting delays points; it never loses them.

**Unmatched sign-ins.** Someone typed something that isn't a Rice netID or Rice email — a personal
Gmail, a typo, a phone number. The system refuses to guess, because guessing creates a fake person
who then collects points. Type the correct netID and press Attach.

**Forms the poller cannot read.** See "The one rule" above.

---

## Volunteering

The only thing you enter by hand. Volunteer sign-up sheets have no consistent format, so the
system never tries to read them — a parser that half-works on spreadsheets would fail quietly, and
quiet failure is the worst outcome for something that converts into money.

1. **Volunteering** tab → create the event with a name and date.
2. Open whatever sheet you used, select the two columns (netID and hours), and copy.
3. Paste into the box. It understands tabs and commas, so Google Sheets, Excel, and Numbers all
   work as-is.
4. **Preview.** Every row is checked against a real person before anything is written. Typos are
   flagged here rather than becoming a problem later.
5. **Commit.**

Points equal hours, so two people at the same event can earn different amounts. Editing someone's
hours later rewrites their points automatically.

---

## Once a year

**After elections — the Roles tab.** Add each eboard member and chair, then press **Apply role
bonuses**. That button is safe to press as many times as you like: it recomputes rather than
stacking, and removing someone withdraws their bonus.

Someone who studies abroad may hold a chair position one semester and an eboard position the
other. Add both. Each is earned separately and pays separately.

**The membership form.** Make it like any other form; tap its type as **Membership**. Its answers
become that year's membership records — class level, major, gender, grad year — automatically.

**The roster matters more than it looks.** A member with no membership record still earns points,
but has no major or gender on file, so **they cannot be placed in the October deliberation grid**.
The Roster tab shows exactly who that is. Chasing those people down in September is much easier
than reconstructing it in October.

---

## October — choosing who to sponsor

The **Standings** tab is a lens, not an answer. It slices by major, gender, and class level, and
lets you exclude eboard members or role bonuses to see the underlying picture.

**It does not and will not recommend anyone.** That's deliberate. Sponsorship depends on things
points cannot see: housing is rooms of four of the same gender, and the chapter wants at least one
student per major so it can ask each department to share the cost. Members effectively compete
within their own gender-and-major cohort, and a single ranked list would quietly misrepresent
that. The tool gives you the numbers; the conversation is yours.

---

## Things that will eventually come up

**"A member says their points are wrong."** Standings shows the breakdown per person: events, role
bonuses, manual adjustments. If an event is missing, check whether it's still awaiting a type. If a
person is missing from an event, look for their sign-in under unmatched.

**"Someone needs points for something with no form."** Adjustments tab. A reason is required and
your email is recorded against it — these decide real money, so every point that didn't come from a
sign-in has to be explainable a year later.

**"Do points reset each year?"** Undecided as of July 2026, deliberately left to you. Today the
system accumulates all-time. Whenever you decide, it is a one-field change
(`app_config.leaderboard_window_start`) with no code change, no migration, and it is reversible.

Worth knowing before you decide: all-time accumulation on a public leaderboard means seniors sit
permanently on top and freshmen see a board they can't win. That's a motivation problem rather than
a technical one, but it should inform the choice.

**"The leaderboard on the website is stale."** The webmasters own that page; we only publish the
numbers (see `docs/API.md`). Check the dashboard first — if Standings is right, the issue is on
their side or in their cache.

**"Nothing has ingested in days."** Sign in as the shared Gmail → script.google.com → open the
poller project → **Executions**. Failures are visible there. Most common cause is an expired
authorization after a Google account change; re-running `installTrigger` fixes it.

---

## Adding next year's officers

**Adding someone is one step:** add their Google address to the `officers` table with
`active = true`. That's it. They press "Sign in with Google" and they're in.

**Removing someone is one step:** set `active = false`. Access is revoked immediately and
completely — there is no second place to clean up.

Anyone signing in with an address that isn't on the list gets a clear "not recognised as an
officer" message and sees no data at all. Signing in grants nothing by itself; the allowlist is
what grants access.

**Google is the only way in — on purpose.** There is no password option and no shared club
passcode, and neither should be added:

- A shared passcode destroys the audit trail. `adjustments` records *who* awarded manual points,
  and those points decide an $800 sponsorship. "Whoever had the code" is not an author.
- A shared passcode can't really be revoked. The correct response to an officer graduating is
  "change the code and tell everyone", which nobody ever does — so the 2026 code still works in
  2030, held by people who left.
- Google accounts already have Rice's MFA behind them, there is no password for the club to store
  or hand over, and there is no reset flow to maintain (this project has no mail server, so a
  forgotten password could only be fixed by someone with database access).

**Changing which address someone uses** is just adding the new one and deactivating the old one.
No data is attached to a login, so there is nothing to migrate.

---

## Handover checklist

Everything below must sit under the **shared club Gmail**, never a personal Rice account. This
list is the difference between a system that survives and one that dies quietly.

- [ ] Supabase project owned by the shared Gmail
- [ ] Git repository pushed somewhere the club controls, not just one laptop
- [ ] Vercel (or whatever hosts the dashboard) under the shared Gmail
- [ ] Apps Script project owned by the shared Gmail, with its trigger installed **while signed in
      as that account**
- [ ] Shared Drive forms folder, with all officers holding edit access
- [ ] Officer allowlist updated for this year's eboard
- [ ] Webmasters confirmed the leaderboard still renders

---

## What's already working

As of 30 July 2026, the database side is live and checked:

- All historical points are migrated — **302 people, 840 attendance records, 1013 points**,
  matching the old system exactly.
- The public leaderboard on shpe.rice.edu keeps working, and now shows only names and totals.
  NetIDs used to be readable by anyone on the internet; they aren't any more.
- Only people on the officer list can see or change anything. Someone signing in with a Google
  account that isn't on the list sees nothing at all — this was tested, not assumed.

## What's still unfinished

Written honestly, so you know what you're inheriting:

- **Sign-in isn't finished.** Google sign-in needs an OAuth client created in the Google Cloud
  project `SHPE Rice` and its credentials pasted into Supabase. Until that's done, nobody can open
  the dashboard. The Email provider should be switched off at the same time so Google is the only
  way in.
- **Backfill is not done.** The database holds events through **2 September 2025**. Fall 2025 from
  that point on, and all of Spring 2026, still need importing before they count toward a convention
  decision. The importer exists (`scripts/backfill.ts`) and has been tested against the old data;
  it just hasn't been pointed at the real spreadsheets because they hadn't been found yet. Each
  event needs a date and a type alongside its attendance.
- **The ingestion pipeline has never run against a real form.** The Edge Function and the poller
  are written, and the database side is tested, but nobody has created a real form in the real
  folder and watched it flow through. Do this once with a throwaway event before relying on it.
- **The dashboard isn't hosted anywhere.** It's a single file; any free static host works.
- **Three people are identified by a personal email** rather than a netID, inherited from the old
  spreadsheets. They keep their points, but if they sign in again they'll land in unmatched
  sign-ins for you to attach.
- **85 people have no name on record.** They're hidden from the public leaderboard rather than
  shown as blank rows. The Roster tab lets you fill names in.
