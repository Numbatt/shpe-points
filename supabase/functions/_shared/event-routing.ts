/**
 * Where a resolved sign-in goes: does it pay points, does it declare membership, or both?
 *
 * This is four lines of boolean logic and it lives in its own file on purpose. It is the single
 * decision this system has gotten wrong twice, in two different places, and both times the bug was
 * invisible in review because the code READ correctly — an if/else that routes to one table or the
 * other looks obviously right until you meet an event that is genuinely both.
 *
 * The history worth knowing before you edit this:
 *
 *   1. ingest-checkin routed with `if (isMembershipForm) { ...; continue; }`. The `continue`
 *      returned to the top of the response loop before ever reaching the attendance write, so a
 *      membership-typed event could not record attendance no matter what else was true.
 *   2. resolve_unmatched_signin (20260802195206) had the identical either/or shape, so rescuing a
 *      sign-in from the queue silently dropped the point the same response would have earned had it
 *      matched on the way in.
 *
 * Both were correct while membership and attendance were mutually exclusive. Then Fall GBM 1 -
 * 08/28/25 turned out to be BOTH the GBM sign-in and the 2025-26 membership form — one form,
 * because that is what students actually fill out — and either answer destroyed real data: routed
 * to attendance, the year got no demographics at all; routed to memberships, 73 people lost the
 * point they showed up for.
 *
 * So: two independent questions, never one fork. The SQL side spells the same rule out inline
 * (resolve_unmatched_signin's `v_is_membership or v_collects`); if you change the rule here, change
 * it there in the same commit.
 */

export interface EventRoutingInput {
  /** events.collects_membership — the officer-set overlay. */
  collects_membership?: boolean | null;
  /** The joined event_types row, as PostgREST embeds it. */
  event_types?: { is_membership_form?: boolean | null } | null;
}

export interface EventRouting {
  /** Record an `attendance` row worth the event's points. */
  paysAttendance: boolean;
  /** Upsert a full `memberships` row from this response's demographics. */
  collectsMembership: boolean;
}

/**
 * A membership TYPE pays nothing: filling out a form asking your major and t-shirt size is not
 * attendance (docs/DESIGN.md, "Phase 3b: the membership gap"). Everything else pays, including an
 * untyped event — at 0 points for now, restamped when the type is finally tapped, which is the
 * "forgetting the type delays points, it never loses them" guarantee.
 *
 * `is_membership_form ||` in the second line is a backstop, not the mechanism. The database keeps
 * the two in sync — events_membership_guard (20260826120000) sets collects_membership whenever an
 * event is typed as a membership form, because being the membership form is what that type means —
 * so in a healthy database the OR never changes the answer. It is here because the failure it
 * guards is silent and expensive: a membership-typed event whose flag somehow is not set would pay
 * no attendance AND collect no demographics, discarding the responses entirely. Falling back to the
 * type costs nothing and makes that unreachable from this side.
 */
export function routeEvent(event: EventRoutingInput | null | undefined): EventRouting {
  const isMembershipForm = event?.event_types?.is_membership_form === true;
  return {
    paysAttendance: !isMembershipForm,
    collectsMembership: isMembershipForm || event?.collects_membership === true,
  };
}
