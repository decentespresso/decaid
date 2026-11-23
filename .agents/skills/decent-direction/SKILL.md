---
name: decent-direction
description: Answer where Decaid is going from maintainer-authored milestone descriptions and recorded decisions, with a decision-first approved/candidate/unknown snapshot and exactly one prioritized human action; chart an optional decision map when one initiative has a named destination and an unclear route. Use for product direction or Now/Next/Later questions, a milestone's stated intent, revising or ruling out a theme, or an initiative's open decisions. A maintainer decides strategy; this skill recommends.
---

# Decaid product direction

Two modes. The **product compass** is the standing snapshot of approved direction, candidates and
unknowns. A **decision map** is the optional situational chart for one bounded initiative whose
destination is named and whose route is not. Both label every statement as observed fact, recorded
maintainer direction, candidate option or unknown, and both end in exactly one prioritized human
action.

Direction is read, not invented. A maintainer-authored milestone description is direction within its
stated scope; a milestone title, its issue membership, labels, counts and assignment are delivery
facts. Strategy, issue acceptance, release scope and publication belong to a maintainer. This skill
researches, compares and recommends; it never decides, and it never treats its own recommendation as
authorization.

## Route

| Task | File |
| --- | --- |
| Compass snapshot, direction provenance, theme revision or rejection | [`contracts.md#product-compass`](contracts.md#product-compass) |
| Optional map with fog, frontier and cleared-map handoff | [`contracts.md#decision-map`](contracts.md#decision-map) |
| Worked live-milestone example and scenario checks | [`pilot.md`](pilot.md) |

## Boundaries

- An `approved` line names its maintainer source and the date it was read. A milestone description
  counts; its edit or approval date stays `unknown` unless a maintainer states it, and `updated_at`
  proves neither.
- Delivery facts seat candidates and conflicts; they never approve direction or an issue.
- Broad and conditional wording keeps its scope. "API hardening" is not an issue list; "if needed"
  stays conditional until a maintainer resolves it. Only a maintainer widens either.
- Reread the live description on every run. Add a row only for observed text, name the row it
  supersedes, and leave unchanged text alone. Never reconstruct unobserved history.
- A theme changes by recording a new dated row that supersedes the old one. Rejected and ruled-out
  options stay linked and readable.
- Draft questions stay in the answer or a local file. Creating issues, labels, milestones or plans
  needs explicit maintainer authorization, and the reply records the before and after.
- A map's Notes carry domain context and standing preferences. Build authority lives with a
  maintainer and an accepted issue, never in Notes. A map session produces decisions and stops.
- An unresolved human decision is listed with its owner. The agent's own answer never stands in for
  it.

## Output contract

Layer 1 first, per the shared report-writing contract in
[`doc/AGENT_WORKFLOW.md`](../../../doc/AGENT_WORKFLOW.md#shared-report-writing-contract): at most
150 words, at most three blockers, exactly one **Next action** naming one owner and one prioritized
action (or **None — no action required**), and status terms `ready`, `hold`,
`needs human validation`, `not tested`, `unknown`. Layer 2 behind a details block or durable link
holds the sources with path or link and date, the per-line status, and every unmeasured metric as
`not measured`.

## Compass run

1. Read the live milestone descriptions and the repository sources. Record each with its link or
   path and the date read. Complete when every statement has a source and an observation date.
2. Write the snapshot to [`contracts.md#product-compass`](contracts.md#product-compass). Complete
   when approved, candidate and unknown direction are separate, every approved row names a
   maintainer source, no delivery fact sits in the approved rows, and every conditional phrase still
   reads as a condition.
3. Name where delivery facts disagree with an approved row, and which decisions only a maintainer
   can take. Complete when each conflict has a source and an owner.
4. Finish with one prioritized human action. Complete when the brief answers "which single decision
   unblocks this" and the agent has chosen no strategy.

## Map run

1. **Name the destination** with the maintainer, in their words. Complete when one or two lines fix
   the scope, marked `confirmed by <owner>, <date>` or `proposed — awaiting confirmation`. A map
   fits an effort larger than one session whose route is unclear; a well-scoped single-session task
   goes straight to G1. A milestone neither requires a map nor supplies a destination on its own.
2. **Survey breadth-first**: the decisions and investigations visible now, plus the fog. Complete
   when the fog is written down or its absence is reported.
3. **Write the map** to [`contracts.md#decision-map`](contracts.md#decision-map). Complete when
   every open item is a decision question, an investigation, or a fog line, and no item is an
   implementation slice.
4. **Resolve one decision per session**, research excepted: record the answer with owner, source and
   date, then move its line into Decisions so far. Graduating a fog patch moves that text out of fog
   into a sharp question. Complete when fog shrank, or the reason it could not is stated. An empty
   fog section alone does not make the effort single-session.
5. **Hand off only when every map item is closed** — no in-scope fog, decision question or
   investigation left open; each item is resolved, ruled out of scope or superseded with a decider, or
   carried as a named residual unknown with an owner. Supply the G1 fields and human acceptance gate
   in [`contracts.md#cleared-map-handoff`](contracts.md#cleared-map-handoff). `decent-refine` is
   optional; the handoff stands alone and authorizes no implementation.

## Measurement

Report pilot effort that exists: maintainer minutes, extra questions or rounds, incorrect
dispositions, unnecessary issues. Absent data stays `not measured`.
