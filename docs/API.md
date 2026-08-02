# SHPE Points — public read API

For the shpe.rice.edu webmasters. **You build the leaderboard; we just expose the numbers.**

There is one endpoint. It is public, read-only, and refreshes itself as points are awarded, so a
page built against it stays current with no involvement from us.

## Endpoint

```
GET https://jzxxchjjhkbvfazrbeom.supabase.co/rest/v1/member_totals_all_time
      ?select=rank,first_name,last_name,total_points
      &order=total_points.desc
```

Send the public key in both headers:

```
apikey:        <anon key>
Authorization: Bearer <anon key>
```

The anon key is the same public value already embedded in the current leaderboard page. It is
safe to publish: it grants read access to this view and to nothing else in the database.

## Worked example

```html
<script>
const SUPABASE_URL = 'https://jzxxchjjhkbvfazrbeom.supabase.co';
const ANON_KEY = '<anon key>';

async function loadLeaderboard() {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/member_totals_all_time` +
    `?select=rank,first_name,last_name,total_points&order=total_points.desc`,
    { headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` } }
  );
  if (!res.ok) throw new Error(`Leaderboard unavailable: ${res.status}`);
  return res.json();
}

loadLeaderboard().then(rows => {
  document.querySelector('#leaderboard tbody').innerHTML = rows.map(r => `
    <tr>
      <td>${r.rank}</td>
      <td>${[r.first_name, r.last_name].filter(Boolean).join(' ')}</td>
      <td>${r.total_points}</td>
    </tr>`).join('');
});
</script>
```

## Fields

| Field | Type | Notes |
|---|---|---|
| `rank` | integer | 1 = most points. Ties share a rank, so ranks can skip (1, 2, 2, 4). |
| `first_name` | string | May be null for a member whose name we don't hold. |
| `last_name` | string | Same. |
| `total_points` | number | Attendance plus role bonuses plus manual adjustments. |

**Nothing else is exposed.** No netID, email, birthday, gender, major, or college is reachable
through this endpoint or any other public path. Please don't design the page around fields that
aren't in the table above — they aren't coming.

## Things worth knowing

**Rows can appear and disappear.** Members who have no name recorded are omitted, and they show up
once an officer fills the name in. Don't key your DOM on array position; use the netID-free
combination of name and rank, or just re-render the list.

**Totals can change retroactively, by design.** Attendance is ingested as soon as a form is
submitted, but an event is worth 0 points until an officer classifies it. When they do, everyone
who attended gains points at once. A member's total going up hours after an event is the system
working, not a bug.

**The window is ours to move.** The chapter has not settled whether points reset each year. The
view honours a configurable start date, so if officers later decide on an annual reset, this
endpoint starts returning windowed totals with no change on your side and no new URL.

**`total_points` may be fractional.** Volunteering awards one point per hour and half-hours are
recorded, so `2.5` is a legal value. Format defensively.

## Caching and CORS

CORS is open, so you can call this directly from the browser — no proxy needed.

Please cache for **5–15 minutes** rather than fetching per page view. The data changes a few times
a week at most, the underlying project is on a free tier, and the ingestion poller shares that
budget. A simple `sessionStorage` cache or a build-time fetch is plenty.

## Stability promise, and the one thing that would break you

The view name `member_totals_all_time` and the fields `first_name`, `last_name`, `total_points` are
a **contract**. We won't rename or remove them without talking to you first.

`rank` is new as of the July 2026 rebuild. If your page predates it, nothing broke — the old three
fields behave exactly as before.

Two fields were **removed** in that rebuild: `netid` and `status`. A netID is a Rice identifier and
had no business on a public endpoint. If your page reads either one, that's the only change you
need to make.

## If it stops working

| Symptom | Cause |
|---|---|
| `401` | The key header is missing or malformed. Both `apikey` and `Authorization` are required. |
| `404` | Wrong view name. It is `member_totals_all_time`, exactly. |
| Empty array | Query succeeded and there is genuinely nothing to show — check with an officer. |
| Timeout / `503` | The free-tier project may have paused. Tell an officer; a poller runs every 15 minutes and normally keeps it awake. |

Questions go to whoever currently holds the SHPE VP role — see `docs/RUNBOOK.md` in the points
system repository.
